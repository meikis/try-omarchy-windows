$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'bridge-preflight.psm1') -Force
$passed = 0
foreach ($ids in @(@('ms_implat'), @('ms_bridge'), @('ms_tcpip','ms_implat'))) {
    if (-not (Test-BridgeBinding $ids)) { throw 'Native occupied bridge binding missed' }; $passed++
}
if (Test-BridgeBinding @('ms_tcpip','ms_tcpip6')) { throw 'Ordinary network binding treated as a bridge' }; $passed++
$listing = "GUID Bridge Name`r`n{ACD0934C-8612-44E9-904A-472DA15252A7} Network Bridge`r`n"
$guids = @(Get-BridgeGuidsFromListing $listing)
if ($guids.Count -ne 1 -or $guids[0] -ne 'acd0934c-8612-44e9-904a-472da15252a7') { throw 'Native bridge listing not identified by GUID' }; $passed++
if (@(Get-BridgeGuidsFromListing 'GUID Bridge Name').Count) { throw 'Empty listing produced a bridge' }; $passed++
foreach ($bad in "{broken} Bridge", ($listing + $listing), '', 'Unexpected inventory error') {
    $failed=$false; try { Get-BridgeGuidsFromListing $bad | Out-Null } catch { $failed=$true }
    if (-not $failed) { throw 'Malformed bridge inventory accepted' }; $passed++
}
function New-Fixture {
    [pscustomobject]@{
        Architecture = 'AMD64'; RemoteSession = $false; BridgeCommands = $true; ExistingBridge = $false
        Driver = [pscustomobject]@{ Valid = $true; Version = '9.27.0'; Problems = @() }
        Adapters = @(
            [pscustomobject]@{Name='Ethernet';Guid='wired';Hardware=$true;Media='802.3';PhysicalMedia='802.3';Status='Up';Dhcp=$true;IPv4Ready=$true;DefaultRoute=$true;BridgeBound=$false;HyperVBound=$false;ComponentId='pci'},
            [pscustomobject]@{Name='Dedicated TAP';Guid='tap';Hardware=$false;Media='802.3';PhysicalMedia='Unspecified';Status='Disconnected';Dhcp=$true;IPv4Ready=$false;DefaultRoute=$false;BridgeBound=$false;HyperVBound=$false;ComponentId='tap0901'}
        )
    }
}
function Assert-Blocked($snapshot, [string]$reason) {
    $result = Get-BridgeLabAssessment $snapshot -WiredGuid wired -TapGuid tap -DisposableLab -LocalConsole -DedicatedTap
    if ($result.CanStartDisposableLab -or $reason -notin $result.Blockers -or $result.BridgeAccepted) { throw "Did not block $reason" }
    $script:passed++
}
$good = Get-BridgeLabAssessment (New-Fixture) -WiredGuid wired -TapGuid tap -DisposableLab -LocalConsole -DedicatedTap
if (-not $good.CanStartDisposableLab -or $good.BridgeAccepted) { throw 'Invalid lab assessment' }
$passed++
$default = Get-BridgeLabAssessment (New-Fixture)
foreach ($reason in 'disposable-lab-required','local-console-required','dedicated-tap-required','select-present-wired-adapter','select-present-tap-adapter') {
    if ($reason -notin $default.Blockers) { throw "Missing default blocker $reason" }; $passed++
}
$s=New-Fixture; $s.Architecture='ARM64'; Assert-Blocked $s 'x64-windows-required'
$s=New-Fixture; $s.RemoteSession=$true; Assert-Blocked $s 'local-console-required'
$s=New-Fixture; $s.Adapters[0].Media='Native 802.11'; Assert-Blocked $s 'wired-ethernet-required'
$s=New-Fixture; $s.Adapters[0].PhysicalMedia='BlueTooth'; Assert-Blocked $s 'wired-ethernet-required'
$s=New-Fixture; $s.Adapters[0].Hardware=$false; Assert-Blocked $s 'wired-ethernet-required'
$s=New-Fixture; $s.Adapters[0].Status='Disconnected'; Assert-Blocked $s 'wired-link-down'
$s=New-Fixture; $s.Adapters[0].Dhcp=$false; Assert-Blocked $s 'dhcp-baseline-required'
$s=New-Fixture; $s.Adapters[0].IPv4Ready=$false; Assert-Blocked $s 'host-connectivity-baseline-missing'
$s=New-Fixture; $s.Adapters[0].DefaultRoute=$false; Assert-Blocked $s 'host-connectivity-baseline-missing'
$s=New-Fixture; $s.Adapters[0].HyperVBound=$true; Assert-Blocked $s 'wired-bindings-in-use'
$s=New-Fixture; $s.Adapters[1].BridgeBound=$true; Assert-Blocked $s 'tap-bindings-in-use'
$s=New-Fixture; $s.Adapters[1].ComponentId='wintun'; Assert-Blocked $s 'tap-windows6-required'
$s=New-Fixture; $s.Adapters[1].Status='Up'; Assert-Blocked $s 'tap-not-idle'
$s=New-Fixture; $s.Adapters[1].Status='Disabled'; Assert-Blocked $s 'tap-not-idle'
$s=New-Fixture; $s.Adapters=@($s.Adapters[0]); Assert-Blocked $s 'select-present-tap-adapter'
$s=New-Fixture; $s.Adapters=@($s.Adapters[1]); Assert-Blocked $s 'select-present-wired-adapter'
$s=New-Fixture; $s.Adapters+= $s.Adapters[0]; Assert-Blocked $s 'select-present-wired-adapter'
$s=New-Fixture; $s.ExistingBridge=$true; Assert-Blocked $s 'existing-bridge'
$s=New-Fixture; $s.BridgeCommands=$false; Assert-Blocked $s 'bridge-commands-unavailable'
$s=New-Fixture; $s.Driver.Valid=$false; Assert-Blocked $s 'driver-package-unverified'
# GUID spelling and distinct selections are checked independently of aliases.
$s=New-Fixture; $s.Adapters[0].Guid='{ABC}'; $s.Adapters[1].Guid='{DEF}'
$r=Get-BridgeLabAssessment $s -WiredGuid abc -TapGuid def -DisposableLab -LocalConsole -DedicatedTap
if (-not $r.CanStartDisposableLab) { throw 'Equivalent GUID spelling rejected' };$passed++
$r=Get-BridgeLabAssessment (New-Fixture) -WiredGuid wired -TapGuid wired -DisposableLab -LocalConsole -DedicatedTap
if ('distinct-adapters-required' -notin $r.Blockers) { throw 'Same adapter accepted twice' };$passed++
# Missing or substituted files fail before any trust check. No installation.
$temp=Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $temp | Out-Null
try {
    $missing=Test-BridgeDriverPackage $temp
    if ($missing.Valid -or $missing.Problems.Count -ne 4) { throw 'Missing package accepted' };$passed++
    foreach ($name in 'OemVista.inf','tap0901.cat','tap0901.sys','devcon.exe') { Set-Content -LiteralPath (Join-Path $temp $name) -Value 'substituted' }
    $bad=Test-BridgeDriverPackage $temp
    if ($bad.Valid -or @($bad.Problems | Where-Object { $_ -like 'hash:*' }).Count -ne 4) { throw 'Substituted package accepted' };$passed++
} finally { Remove-Item -LiteralPath $temp -Recurse -Force }
Write-Output "$passed bridge preflight checks passed"
