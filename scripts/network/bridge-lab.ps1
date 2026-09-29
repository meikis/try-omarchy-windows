param(
    [Parameter(Mandatory)][ValidateSet('Enable','Disable','Recover')][string]$Action,
    [guid]$WiredGuid, [guid]$TapGuid, [string]$DriverDirectory,
    [string]$ProbeName, [string]$ProbeAddress, [ValidateRange(1,65535)][int]$ProbePort = 443,
    [switch]$DisposableLab, [switch]$LocalConsole, [switch]$DedicatedTap
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $DisposableLab -or -not $LocalConsole -or -not $DedicatedTap -or
    $env:SSH_CONNECTION -or $env:SSH_CLIENT -or $env:SESSIONNAME -like 'RDP-*') {
    throw 'This helper requires a disposable Windows lab, independent local console and dedicated TAP. Remote Wi-Fi hosts are unsuitable.'
}
$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run explicitly in an administrator lab console. This helper never elevates or installs drivers.' }
Import-Module (Join-Path $PSScriptRoot 'bridge-transaction.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'bridge-native.psm1') -Force
$directory = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'TryOmarchyBridgeLab'
$acl = [Security.AccessControl.DirectorySecurity]::new()
$acl.SetAccessRuleProtection($true, $false)
$acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
foreach ($sid in 'S-1-5-18','S-1-5-32-544') {
    $rule = [Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid), 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
    $acl.AddAccessRule($rule)
}
function Assert-TrustedJournalPath([string]$Path) {
    if ((Get-Item -LiteralPath $Path).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Journal paths must not be reparse points.' }
    $current = Get-Acl -LiteralPath $Path
    $owner = $current.GetOwner([Security.Principal.SecurityIdentifier]).Value
    if ($owner -notin @('S-1-5-18','S-1-5-32-544')) { throw 'Journal path has an untrusted owner. No network changes made.' }
    foreach ($rule in $current.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])) {
        if ($rule.IdentityReference.Value -notin @('S-1-5-18','S-1-5-32-544')) { throw 'Journal permissions require local inspection. No network changes made.' }
    }
}
if (-not (Test-Path -LiteralPath $directory)) {
    # Create with the ACL, so an unelevated process cannot plant a journal in
    # the interval between directory creation and permission changes.
    if ($PSVersionTable.PSEdition -eq 'Desktop') { [IO.Directory]::CreateDirectory($directory, $acl) | Out-Null }
    else { [IO.FileSystemAclExtensions]::Create([IO.DirectoryInfo]::new($directory), $acl) }
}
Assert-TrustedJournalPath $directory
$journal = Join-Path $directory 'operation.json'
foreach ($path in $journal, (Join-Path $directory 'operation.lock')) {
    if (Test-Path -LiteralPath $path) { Assert-TrustedJournalPath $path }
}
$lock = [IO.File]::Open((Join-Path $directory 'operation.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
try {
    $backend = New-NativeBridgeBackend
    if ($Action -eq 'Enable') {
        if ($WiredGuid -eq [guid]::Empty -or $TapGuid -eq [guid]::Empty -or -not $DriverDirectory -or -not $ProbeName -or -not $ProbeAddress) { throw 'Select adapter GUIDs, the verified driver directory and a known wired DNS/TCP peer.' }
        $ip = [Net.IPAddress]::Parse($ProbeAddress)
        if ($ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or [Net.IPAddress]::IsLoopback($ip)) { throw 'The probe must be a separate IPv4 wired peer.' }
        $request = [pscustomobject]@{
            WiredGuid=$WiredGuid.ToString(); TapGuid=$TapGuid.ToString(); DriverDirectory=[IO.Path]::GetFullPath($DriverDirectory)
            ProbeName=$ProbeName; ProbeAddress=$ProbeAddress; ProbePort=$ProbePort
        }
        $result = Start-BridgeLabTransaction $backend $journal $request
    } else { $result = Undo-BridgeLabTransaction $backend $journal }
    [pscustomobject]@{ Phase=$result.Phase; BridgeGuid=$result.BridgeGuid; Journal=$journal; BridgeAccepted=$false }
} finally { $lock.Dispose() }
