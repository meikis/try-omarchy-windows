# Explicit forwarding experiment. Does not install drivers or mutate networking.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][guid]$WiredGuid,
    [Parameter(Mandatory)][string]$WiredPnp,
    [Parameter(Mandatory)][guid]$TapGuid,
    [Parameter(Mandatory)][string]$TapPnp,
    [Parameter(Mandatory)][ValidatePattern('^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$')][string]$GuestMac,
    [Parameter(Mandatory)][string]$DriverDirectory,
    [Parameter(Mandatory)][int]$QemuProcessId,
    [Parameter(Mandatory)][string]$QemuExecutable,
    [Parameter(Mandatory)][string]$ProbeName,
    [Parameter(Mandatory)][string]$ProbeAddress,
    [Parameter(Mandatory)][ValidateRange(1,65535)][int]$ProbePort,
    [ValidateRange(1,600)][int]$Seconds = 60,
    [switch]$DisposableLab,
    [switch]$LocalConsole,
    [switch]$DedicatedTap
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitProcess) { throw 'Native x64 Windows PowerShell is required.' }
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run explicitly as administrator. This helper never elevates.' }
if (-not $DisposableLab -or -not $LocalConsole -or -not $DedicatedTap -or $env:SSH_CONNECTION -or $env:SSH_CLIENT -or $env:SESSIONNAME -like 'RDP-*') { throw 'A disposable wired lab, independent local console and dedicated TAP are required.' }
if ($WiredGuid -eq $TapGuid -or -not $WiredPnp -or -not $TapPnp) { throw 'Select distinct adapters with exact PNP identities.' }
Import-Module (Join-Path $PSScriptRoot 'bridge-native.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'bridge-preflight.psm1') -Force
$snapshot = Get-BridgeHostSnapshot $DriverDirectory
# The native bridge assessment requires idle TAP. Here QEMU must already own
# and open the dedicated TAP. Every other restriction remains applicable.
$assessment = Get-BridgeLabAssessment -Snapshot $snapshot -WiredGuid $WiredGuid -TapGuid $TapGuid -DisposableLab -LocalConsole -DedicatedTap
$blockers = @($assessment.Blockers | Where-Object { $_ -ne 'tap-not-idle' })
if ($blockers.Count) { throw ('Lab preflight failed: ' + ($blockers -join ', ')) }
$wired = & (Get-Module bridge-native) { param($g,$p) Get-SelectedAdapter $g $p } $WiredGuid.ToString() $WiredPnp
$tap = & (Get-Module bridge-native) { param($g,$p) Get-SelectedAdapter $g $p } $TapGuid.ToString() $TapPnp
& (Get-Module bridge-native) { param($a) Assert-InstalledTapDriver $a } $tap
$wiredMac = ([string]$wired.MacAddress).Replace('-',':').ToLowerInvariant()
if ($wiredMac -eq $GuestMac.ToLowerInvariant()) { throw 'Guest and wired MACs must differ.' }
$bindings = & (Get-Module bridge-native) { param($a) Get-SelectedBindings $a } $tap
if (@($bindings | Where-Object { $_.Enabled -and $_.ComponentID -in @('ms_tcpip','ms_tcpip6') }).Count) { throw 'The dedicated TAP must already have IPv4 and IPv6 unbound, with a saved recovery baseline. This helper will not change bindings.' }
$journal = Join-Path $env:ProgramData 'TryOmarchyBridgeLab\operation.json'
if ((Test-Path -LiteralPath $journal) -and (Get-Content -LiteralPath $journal -Raw | ConvertFrom-Json).Phase -ne 'Complete') { throw 'Recover the native bridge journal first.' }
$other = @(Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and ([guid]$_.InterfaceGuid) -notin @($WiredGuid,$TapGuid) })
if (-not $other.Count) { throw 'An independent management adapter must remain up.' }
$lock = Get-Content (Join-Path $PSScriptRoot 'npcap-1.89.lock.json') -Raw | ConvertFrom-Json
$system = [Environment]::SystemDirectory
foreach ($entry in $lock.files.PSObject.Properties) {
    $path = Join-Path $system $entry.Name
    if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $entry.Value -or (Get-AuthenticodeSignature -LiteralPath $path).Status -ne 'Valid') { throw ('Untrusted or unpinned Npcap file: ' + $entry.Name) }
}
$drivers = @(Get-CimInstance Win32_SystemDriver -Filter "Name='npcap'")
if ($drivers.Count -ne 1 -or $drivers[0].State -ne 'Running' -or ([IO.Path]::GetFullPath(([string]$drivers[0].PathName).Trim('"'))) -ne (Join-Path $system 'drivers\npcap.sys')) { throw 'Pinned Npcap kernel driver is not running at its expected path.' }
$options = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\npcap\Parameters'
if ($options.AdminOnly -ne 1 -or $options.Dot11Support -ne 0 -or $options.WinPcapCompatible -ne 0) { throw 'Npcap requires administrator-only access, without wireless capture or WinPcap compatibility.' }
$probe = [pscustomobject]@{ ProbeName=$ProbeName; ProbeAddress=$ProbeAddress; ProbePort=$ProbePort }
if (-not (& (Get-Module bridge-native) { param($g,$r) Test-WiredProbe $g $r 5 } $WiredGuid.ToString() $probe)) { throw 'Selected host DHCP, DNS or TCP baseline failed.' }
$qemu = Get-CimInstance Win32_Process -Filter "ProcessId=$QemuProcessId"
if (-not $qemu -or $qemu.ExecutablePath -ne $QemuExecutable -or $qemu.Name -notmatch '^qemu-system-x86_64w?\.exe$') { throw 'Selected QEMU process identity does not match.' }
$qemuCreation = $qemu.CreationDate
$tapName = [regex]::Escape([string]$tap.Name)
$tapArgument = '-netdev\s+tap,[^\s]*ifname="?' + $tapName + '(?:"|\s|$)'
if ($qemu.CommandLine -notmatch $tapArgument -or $qemu.CommandLine -notmatch ('mac=' + [regex]::Escape($GuestMac))) { throw 'QEMU must already open the selected TAP with the fixed guest MAC.' }
$guard = [Action]{
    $currentWired = & (Get-Module bridge-native) { param($g,$p) Get-SelectedAdapter $g $p } $WiredGuid.ToString() $WiredPnp
    $currentTap = & (Get-Module bridge-native) { param($g,$p) Get-SelectedAdapter $g $p } $TapGuid.ToString() $TapPnp
    if ($currentWired.Status -ne 'Up' -or $currentTap.Status -ne 'Up' -or ([string]$currentWired.MacAddress).Replace('-',':').ToLowerInvariant() -ne $wiredMac) { throw 'Selected adapter lost its link or identity. Forwarding stopped.' }
    foreach ($adapter in @($currentWired,$currentTap)) {
        $currentBindings = & (Get-Module bridge-native) { param($a) Get-SelectedBindings $a } $adapter
        $ids = @($currentBindings | Where-Object Enabled | Select-Object -ExpandProperty ComponentID)
        if ('nmap_npcap' -notin $ids -or 'vms_pp' -in $ids -or (Test-BridgeBinding $ids)) { throw 'Selected adapter bindings changed. Forwarding stopped.' }
    }
    $currentQemu = Get-CimInstance Win32_Process -Filter "ProcessId=$QemuProcessId"
    if (-not $currentQemu -or $currentQemu.CreationDate -ne $qemuCreation -or $currentQemu.ExecutablePath -ne $QemuExecutable) { throw 'Owned QEMU process ended or changed. Forwarding stopped.' }
}
$created = $false
$mutex = [Threading.Mutex]::new($false, ('Global\TryOmarchyNpcapLab-' + $TapGuid.ToString()), [ref]$created)
$held = $false
try {
    try { $held = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $held = $true }
    if (-not $held) { throw 'Another frame pump owns this TAP.' }
    $guard.Invoke()
    if ('NpcapFramePump' -as [type]) { throw 'Run this helper in a fresh PowerShell process to avoid stale loaded code.' }
    Add-Type -Path (Join-Path $PSScriptRoot 'NpcapFramePump.cs')
    $result = [NpcapFramePump]::Run($WiredGuid.ToString(),$TapGuid.ToString(),$GuestMac,$wiredMac,$Seconds,$guard)
    if (-not (& (Get-Module bridge-native) { param($g,$r) Test-WiredProbe $g $r 5 } $WiredGuid.ToString() $probe)) { throw 'Selected host connectivity failed after forwarding.' }
    [pscustomobject]@{ GuestOut=$result.GuestOut; PeerIn=$result.PeerIn; Raw=$result.Raw; BridgeAccepted=$false }
} finally {
    if ($held) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
