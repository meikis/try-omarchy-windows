Set-StrictMode -Version Latest

function Get-BridgeGuidsFromListing {
    param([string]$Listing)
    $rowPattern = '^\s*\{([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\}[ \t]+[^\r\n]+$'
    $lines = @($Listing -split '\r?\n')
    if (@($lines | Where-Object { $_ -match '^\s*GUID[ \t]+\S' }).Count -ne 1) { throw 'Unrecognized Windows bridge listing.' }
    foreach ($line in $lines) {
        if ($line -notmatch '^\s*$|^\s*-+\s*$|^\s*GUID[ \t]+\S' -and $line -notmatch $rowPattern) {
            throw 'Unrecognized Windows bridge listing.'
        }
    }
    $rows = @($lines | ForEach-Object {
        $row = [regex]::Match($_, $rowPattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($row.Success) { $row }
    })
    $guids = @($rows | ForEach-Object { ([guid]$_.Groups[1].Value).ToString() })
    if (@($guids | Select-Object -Unique).Count -ne $guids.Count -or
        (@([regex]::Matches($Listing, '\{')).Count -ne $guids.Count)) { throw 'Unrecognized Windows bridge listing.' }
    $guids
}

function Test-BridgePrivateSubnetConflict {
    param($Addresses)
    # Use subnet ranges, not a 10.0.2 string prefix. A /8 also overlaps.
    $privateStart=[uint64]167772672
    $privateEnd=$privateStart+255
    foreach ($entry in $Addresses) {
        $ip=[Net.IPAddress]::Parse([string]$entry.IPAddress)
        if ($ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { continue }
        $prefix=[int]$entry.PrefixLength
        if ($prefix -lt 0 -or $prefix -gt 32) { throw 'Invalid wired prefix.' }
        $b=$ip.GetAddressBytes()
        $number=([uint64]$b[0] -shl 24)+([uint64]$b[1] -shl 16)+([uint64]$b[2] -shl 8)+[uint64]$b[3]
        $size=[uint64]1 -shl (32-$prefix)
        $start=$number-($number % $size)
        if ($start -le $privateEnd -and ($start+$size-1) -ge $privateStart) { return $true }
    }
    return $false
}

function Test-BridgeBinding {
    param([string[]]$EnabledComponents)
    # Current Windows members use the multiplexor protocol; ms_bridge is on
    # the composite bridge adapter. Older bridge bindings are also occupied.
    ('ms_implat' -in $EnabledComponents -or 'ms_bridge' -in $EnabledComponents)
}

# These functions inspect only. No driver install, elevation, network binding
# changes or QEMU startup belongs in the preflight.
function Test-BridgeDriverPackage {
    param([string]$Directory)
    $lock = Get-Content (Join-Path $PSScriptRoot 'tap-windows6.lock.json') -Raw | ConvertFrom-Json
    $problems = [System.Collections.Generic.List[string]]::new()
    foreach ($file in $lock.files.PSObject.Properties) {
        $path = Join-Path $Directory $file.Name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            $problems.Add("missing:$($file.Name)")
            continue
        }
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $file.Value) {
            $problems.Add("hash:$($file.Name)")
            continue
        }
        if ($file.Name -ne 'OemVista.inf') {
            $signature = Get-AuthenticodeSignature -LiteralPath $path
            if ($signature.Status -ne 'Valid') {
                $problems.Add("signature:$($file.Name)")
            }
        }
    }
    [pscustomobject]@{ Valid = ($problems.Count -eq 0); Version = $lock.version; Problems = @($problems.ToArray()) }
}

function Get-BridgeLabAssessment {
    param(
        [Parameter(Mandatory)]$Snapshot,
        [string]$WiredGuid,
        [string]$TapGuid,
        [switch]$DisposableLab,
        [switch]$LocalConsole,
        [switch]$DedicatedTap
    )
    $blockers = [System.Collections.Generic.List[string]]::new()
    if ($Snapshot.Architecture -ne 'AMD64') { $blockers.Add('x64-windows-required') }
    if (-not $DisposableLab) { $blockers.Add('disposable-lab-required') }
    if (-not $LocalConsole -or $Snapshot.RemoteSession) { $blockers.Add('local-console-required') }
    if (-not $DedicatedTap) { $blockers.Add('dedicated-tap-required') }
    if (-not $Snapshot.BridgeCommands) { $blockers.Add('bridge-commands-unavailable') }
    if ($Snapshot.ExistingBridge) { $blockers.Add('existing-bridge') }
    if (-not $Snapshot.Driver.Valid) { $blockers.Add('driver-package-unverified') }
    $wired = @($Snapshot.Adapters | Where-Object { $WiredGuid -and ([string]$_.Guid).Trim('{}') -eq $WiredGuid.Trim('{}') })
    $tap = @($Snapshot.Adapters | Where-Object { $TapGuid -and ([string]$_.Guid).Trim('{}') -eq $TapGuid.Trim('{}') })
    if ($wired.Count -ne 1) {
        $blockers.Add('select-present-wired-adapter')
    } else {
        $adapter = $wired[0]
        if (-not $adapter.Hardware -or $adapter.Media -ne '802.3' -or $adapter.PhysicalMedia -ne '802.3') {
            $blockers.Add('wired-ethernet-required')
        }
        if ($adapter.Status -ne 'Up') { $blockers.Add('wired-link-down') }
        if (-not $adapter.Dhcp) { $blockers.Add('dhcp-baseline-required') }
        if (-not $adapter.IPv4Ready -or -not $adapter.DefaultRoute) { $blockers.Add('host-connectivity-baseline-missing') }
        if ($adapter.BridgeBound -or $adapter.HyperVBound) { $blockers.Add('wired-bindings-in-use') }
    }
    if ($tap.Count -ne 1) {
        $blockers.Add('select-present-tap-adapter')
    } else {
        $adapter = $tap[0]
        if ($adapter.ComponentId -ne 'tap0901' -or $adapter.Hardware) { $blockers.Add('tap-windows6-required') }
        if ($adapter.Status -ne 'Disconnected') { $blockers.Add('tap-not-idle') }
        if ($adapter.BridgeBound -or $adapter.HyperVBound) { $blockers.Add('tap-bindings-in-use') }
    }
    if ($WiredGuid -and $TapGuid -and $WiredGuid.Trim('{}') -eq $TapGuid.Trim('{}')) { $blockers.Add('distinct-adapters-required') }
    [pscustomobject]@{
        CanStartDisposableLab = ($blockers.Count -eq 0)
        BridgeAccepted = $false
        Blockers = @($blockers.ToArray())
        Driver = $Snapshot.Driver
        Adapters = @($Snapshot.Adapters | Select-Object Name, Guid, Hardware, Media, PhysicalMedia, Status, ComponentId)
    }
}

function Get-BridgeHostSnapshot {
    param([string]$DriverDirectory)
    # Registry component IDs avoid identifying VPN devices by a display name.
    $class = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}'
    $components = @{}
    $classKey = Get-Item -LiteralPath $class -ErrorAction Stop
    $classKey.GetSubKeyNames() | Where-Object { $_ -match '^\d{4}$' } | ForEach-Object {
        $entry = Get-ItemProperty -LiteralPath (Join-Path $class $_) -ErrorAction Stop
        if ($entry.PSObject.Properties['NetCfgInstanceId'] -and $entry.PSObject.Properties['ComponentId']) {
            $components[[string]$entry.NetCfgInstanceId] = [string]$entry.ComponentId
        }
    }
    $adapters = @(Get-NetAdapter -IncludeHidden | ForEach-Object {
        $adapter = $_
        $guid = [string]$adapter.InterfaceGuid
        $ip = @(Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.AddressState -eq 'Preferred' -and $_.IPAddress -notmatch '^(169\.254\.|127\.|0\.)' })
        $dhcp = @(Get-NetIPInterface -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.Dhcp -eq 'Enabled' })
        $routes = @(Get-NetRoute -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue)
        $bindings = @(Get-NetAdapterBinding -Name '*' -IncludeHidden -AllBindings -ErrorAction Stop |
            Where-Object { $_.Name -eq $adapter.Name } |
            Where-Object { $_.Enabled })
        $boundIds = @($bindings | Select-Object -ExpandProperty ComponentID)
        [pscustomobject]@{
            Name = $adapter.Name; Guid = $guid; Hardware = [bool]$adapter.HardwareInterface
            Media = [string]$adapter.MediaType; PhysicalMedia = [string]$adapter.PhysicalMediaType
            Status = [string]$adapter.Status; ComponentId = [string]$components[$guid]
            Dhcp = ($dhcp.Count -gt 0); IPv4Ready = ($ip.Count -gt 0); DefaultRoute = ($routes.Count -gt 0)
            BridgeBound = (Test-BridgeBinding $boundIds); HyperVBound = ('vms_pp' -in $boundIds)
        }
    })
    $remote = [bool]($env:SSH_CONNECTION -or $env:SSH_CLIENT -or $env:SESSIONNAME -like 'RDP-*')
    $commands = (& netsh.exe bridge help | Out-String)
    $bridgeCommands = ($LASTEXITCODE -eq 0 -and $commands -match '(?m)^create\s' -and $commands -match '(?m)^destroy\s')
    $bridges = (& netsh.exe bridge list | Out-String)
    $bridgeCommands = ($bridgeCommands -and $LASTEXITCODE -eq 0)
    $architecture = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    $driver = if ($DriverDirectory) { Test-BridgeDriverPackage $DriverDirectory } else {
        [pscustomobject]@{ Valid = $false; Version = ''; Problems = @('package-directory-required') }
    }
    [pscustomobject]@{
        Adapters = $adapters; RemoteSession = $remote; BridgeCommands = $bridgeCommands; Architecture = $architecture
        ExistingBridge = (('ms_bridgemp' -in $adapters.ComponentId) -or ('COMPOSITEBUS\MS_IMPLAT_MP' -in $adapters.ComponentId) -or @(Get-BridgeGuidsFromListing $bridges).Count -gt 0); Driver = $driver
    }
}

Export-ModuleMember -Function Test-BridgePrivateSubnetConflict, Test-BridgeDriverPackage, Get-BridgeLabAssessment, Get-BridgeHostSnapshot, Get-BridgeGuidsFromListing, Test-BridgeBinding
