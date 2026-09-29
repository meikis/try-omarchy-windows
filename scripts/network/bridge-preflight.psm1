Set-StrictMode -Version Latest

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
        $bindings = @(Get-NetAdapterBinding -Name $adapter.Name -IncludeHidden -ErrorAction Stop |
            Where-Object { $_.Enabled })
        $boundIds = @($bindings | Select-Object -ExpandProperty ComponentID)
        [pscustomobject]@{
            Name = $adapter.Name; Guid = $guid; Hardware = [bool]$adapter.HardwareInterface
            Media = [string]$adapter.MediaType; PhysicalMedia = [string]$adapter.PhysicalMediaType
            Status = [string]$adapter.Status; ComponentId = [string]$components[$guid]
            Dhcp = ($dhcp.Count -gt 0); IPv4Ready = ($ip.Count -gt 0); DefaultRoute = ($routes.Count -gt 0)
            BridgeBound = ('ms_bridge' -in $boundIds); HyperVBound = ('vms_pp' -in $boundIds)
        }
    })
    $remote = [bool]($env:SSH_CONNECTION -or $env:SSH_CLIENT -or $env:SESSIONNAME -like 'RDP-*')
    $commands = (& netsh.exe bridge help | Out-String)
    $bridgeCommands = ($LASTEXITCODE -eq 0 -and $commands -match '(?m)^create\s' -and $commands -match '(?m)^destroy\s')
    $driver = if ($DriverDirectory) { Test-BridgeDriverPackage $DriverDirectory } else {
        [pscustomobject]@{ Valid = $false; Version = ''; Problems = @('package-directory-required') }
    }
    [pscustomobject]@{
        Adapters = $adapters; RemoteSession = $remote; BridgeCommands = $bridgeCommands
        ExistingBridge = ('ms_bridgemp' -in $adapters.ComponentId); Driver = $driver
    }
}

Export-ModuleMember -Function Test-BridgeDriverPackage, Get-BridgeLabAssessment, Get-BridgeHostSnapshot
