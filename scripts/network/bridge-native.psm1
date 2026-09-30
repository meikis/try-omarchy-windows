Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'bridge-preflight.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'bridge-datapath.psm1') -Force

function Get-SelectedAdapter {
    param([string]$Guid, [string]$Pnp = '')
    $adapters = @(Get-NetAdapter -IncludeHidden | Where-Object { ([string]$_.InterfaceGuid).Trim('{}') -eq $Guid.Trim('{}') })
    if ($adapters.Count -ne 1 -or ($Pnp -and [string]$adapters[0].PnPDeviceID -ne $Pnp)) {
        throw "Selected adapter identity is missing or changed: $Guid"
    }
    $adapters[0]
}

function Get-SelectedBindings {
    param($Adapter)
    # Select exact aliases after enumeration. Never pass a user-controlled alias
    # as a wildcard to a binding mutation.
    @(Get-NetAdapterBinding -Name '*' -IncludeHidden -AllBindings | Where-Object { $_.Name -eq $Adapter.Name })
}

function Get-AdapterBaseline {
    param([string]$Guid)
    $adapter = Get-SelectedAdapter $Guid
    $interfaces = @(Get-NetIPInterface -InterfaceIndex $adapter.ifIndex | Select-Object AddressFamily, Dhcp, RouterDiscovery, AutomaticMetric, InterfaceMetric)
    $addresses = @(Get-NetIPAddress -InterfaceIndex $adapter.ifIndex | Select-Object AddressFamily, IPAddress, PrefixLength, PrefixOrigin)
    if (@($addresses | Where-Object { $_.PrefixOrigin -eq 'Manual' }).Count) { throw 'Lab setup requires DHCP without manual IP addresses.' }
    $staticRoutes = @(Get-NetRoute -InterfaceIndex $adapter.ifIndex -PolicyStore PersistentStore -ErrorAction SilentlyContinue)
    if ($staticRoutes.Count) { throw 'Lab setup does not support persistent static routes.' }
    $dns = @()
    foreach ($service in 'Tcpip','Tcpip6') {
        $key = "HKLM:\SYSTEM\CurrentControlSet\Services\$service\Parameters\Interfaces\{$($Guid.Trim('{}'))}"
        $entry = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
        if ($entry -and $entry.PSObject.Properties['NameServer'] -and $entry.NameServer) {
            $dns += @(([string]$entry.NameServer -split '[,; ]+') | Where-Object { $_ })
        }
    }
    [pscustomobject]@{
        Guid = ([string]$adapter.InterfaceGuid).Trim('{}'); Pnp = [string]$adapter.PnPDeviceID
        Name = [string]$adapter.Name; Interfaces = $interfaces; StaticDns = $dns; Addresses = $addresses
        Bindings = @(Get-SelectedBindings $adapter | Select-Object ComponentID, Enabled)
        Routes = @(Get-NetRoute -InterfaceIndex $adapter.ifIndex | Select-Object AddressFamily, DestinationPrefix, NextHop, RouteMetric, Protocol)
    }
}

function Get-NativeBridgeInventory {
    param([string]$DriverDirectory)
    $snapshot = Get-BridgeHostSnapshot $DriverDirectory
    $listing = (& netsh.exe bridge list | Out-String)
    if ($LASTEXITCODE -ne 0) { throw 'Windows bridge inventory failed.' }
    $guids = @(Get-BridgeGuidsFromListing $listing)
    $bridges = @($snapshot.Adapters | Where-Object { ([string]$_.Guid).Trim('{}') -in $guids })
    if ($bridges.Count -ne $guids.Count) { throw 'Windows bridge adapter inventory is not ready.' }
    [pscustomobject]@{
        Bridges = $bridges
        Bound = @($snapshot.Adapters | Where-Object { $_.BridgeBound -and ([string]$_.Guid).Trim('{}') -notin $guids })
    }
}

function Assert-InstalledTapDriver {
    param($Adapter)
    $drivers = @(Get-CimInstance Win32_PnPSignedDriver | Where-Object { $_.DeviceID -eq $Adapter.PnPDeviceID })
    if ($drivers.Count -ne 1 -or -not $drivers[0].IsSigned -or $drivers[0].DriverVersion -ne '9.27.0.0') {
        throw 'The selected TAP does not report the pinned signed driver version.'
    }
    $systemDrivers = @(Get-CimInstance Win32_SystemDriver | Where-Object { $_.Name -eq 'tap0901' -and $_.State -eq 'Running' })
    if ($systemDrivers.Count -ne 1) { throw 'The pinned TAP kernel service is not running.' }
    $path = ([string]$systemDrivers[0].PathName).Trim('"') -replace '^\\SystemRoot', $env:SystemRoot
    if (-not [IO.Path]::IsPathRooted($path)) { $path = Join-Path $env:SystemRoot $path }
    $lock = Get-Content (Join-Path $PSScriptRoot 'tap-windows6.lock.json') -Raw | ConvertFrom-Json
    if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $lock.files.'tap0901.sys' -or
        (Get-AuthenticodeSignature -LiteralPath $path).Status -ne 'Valid') {
        throw 'The installed TAP kernel file does not match the verified package.'
    }
}

function Assert-BridgeMachine {
    param($Journal)
    $machine = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Cryptography').MachineGuid
    if ($machine -ne $Journal.Before.MachineGuid) { throw 'The journal belongs to a different Windows installation.' }
}

function Assert-BridgeIdentity {
    param($Journal)
    Assert-BridgeMachine $Journal
    Get-SelectedAdapter $Journal.Before.Wired.Guid $Journal.Before.Wired.Pnp | Out-Null
    # An absent TAP can be cleaned up. A replacement with another PNP identity cannot.
    $tap = @(Get-NetAdapter -IncludeHidden | Where-Object { ([string]$_.InterfaceGuid).Trim('{}') -eq $Journal.Before.Tap.Guid })
    if ($tap.Count -gt 1 -or ($tap.Count -eq 1 -and [string]$tap[0].PnPDeviceID -ne $Journal.Before.Tap.Pnp)) {
        throw 'The dedicated TAP identity changed.'
    }
}

function Find-OwnedBridge {
    param($Journal)
    Assert-BridgeIdentity $Journal
    $current = Get-NativeBridgeInventory $Journal.Request.DriverDirectory
    if ($current.Bridges.Count -eq 0 -and $current.Bound.Count -eq 0) { return $null }
    if ($current.Bridges.Count -ne 1) { throw 'Bridge ownership is ambiguous. Use the local console to inspect it.' }
    $bridge = $current.Bridges[0]
    $guid = ([string]$bridge.Guid).Trim('{}')
    if ($guid -in @($Journal.Before.Bridges) -or ($Journal.BridgeGuid -and $guid -ne $Journal.BridgeGuid)) {
        throw 'An unrelated bridge is present. No network changes made.'
    }
    $expected = @($Journal.Before.Wired.Guid, $Journal.Before.Tap.Guid | Sort-Object)
    $actual = @($current.Bound | ForEach-Object { ([string]$_.Guid).Trim('{}') } | Sort-Object)
    # If the owned TAP was removed, the surviving wired member can be detached.
    $tapPresent = @(Get-NetAdapter -IncludeHidden | Where-Object { ([string]$_.InterfaceGuid).Trim('{}') -eq $Journal.Before.Tap.Guid }).Count -eq 1
    if (-not $tapPresent -and $Journal.BridgeGuid) { $expected = @($Journal.Before.Wired.Guid) }
    if (@(Compare-Object $expected $actual).Count) { throw 'Bridge membership changed. No bridge will be destroyed.' }
    $guid
}

function Invoke-BridgeCommand {
    param([string[]]$Arguments)
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = Join-Path ([Environment]::SystemDirectory) 'netsh.exe'
    $info.Arguments = 'bridge ' + ($Arguments -join ' ')
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    $process = [Diagnostics.Process]::new(); $process.StartInfo = $info
    try {
        if (-not $process.Start()) { throw 'Windows bridge command did not start.' }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(30000)) {
            $process.Kill(); $process.WaitForExit()
            # The network configuration service may still finish an RPC after
            # its caller exits. Retain intent instead of racing an automatic undo.
            throw [TimeoutException]::new('Windows bridge command timed out. Inspect the local console, then recover from the journal.')
        }
        if ($process.ExitCode -ne 0) { throw "Windows bridge command failed ($($process.ExitCode)): $($stdout.Result.Trim()) $($stderr.Result.Trim())" }
    } finally { $process.Dispose() }
}

function Test-WiredProbe {
    param([string]$Guid, $Request, [int]$Seconds = 45)
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        try {
            $adapter = Get-SelectedAdapter $Guid
            if ($adapter.Status -ne 'Up') { throw 'Selected wired link is down.' }
            $ip = @(Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 |
                Where-Object { $_.AddressState -eq 'Preferred' -and $_.PrefixOrigin -eq 'Dhcp' -and $_.IPAddress -notmatch '^(169\.254\.|127\.|0\.)' })
            $dhcp = @(Get-NetIPInterface -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 | Where-Object { $_.Dhcp -eq 'Enabled' })
            $route = @(Get-NetRoute -InterfaceIndex $adapter.ifIndex -DestinationPrefix '0.0.0.0/0' -AddressFamily IPv4)
            $dns = @((Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4).ServerAddresses)
            if ($ip.Count -ne 1 -or $dhcp.Count -ne 1 -or $route.Count -eq 0 -or $dns.Count -eq 0) { throw 'DHCP, DNS or route is not ready.' }
            # Query the selected interface's DNS and bind TCP to its actual DHCP
            # address. A separate management NIC cannot satisfy the TCP probe.
            $answers = @(Resolve-DnsName -Name $Request.ProbeName -Server $dns[0] -Type A -DnsOnly -QuickTimeout -ErrorAction Stop |
                Where-Object { $_.PSObject.Properties['IPAddress'] -and $_.IPAddress -eq $Request.ProbeAddress })
            if ($answers.Count -eq 0) { throw 'Selected DNS probe did not return the expected peer.' }
            $local = [Net.IPEndPoint]::new([Net.IPAddress]::Parse($ip[0].IPAddress), 0)
            $tcp = [Net.Sockets.TcpClient]::new($local)
            try {
                $connect = $tcp.ConnectAsync($Request.ProbeAddress, $Request.ProbePort)
                if (-not $connect.Wait(2000) -or -not $tcp.Connected) { throw 'Selected TCP probe failed.' }
            } finally { $tcp.Dispose() }
            return $true
        } catch { Start-Sleep -Milliseconds 500 }
    } while ([DateTime]::UtcNow -lt $deadline)
    return $false
}

function Test-NativeBridgeDataPath {
    param($Journal)
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = Join-Path ([Environment]::SystemDirectory) 'pktmon.exe'
    $info.Arguments = 'list --json'
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    $process = [Diagnostics.Process]::new(); $process.StartInfo = $info
    try {
        if (-not $process.Start()) { throw 'Component inventory did not start.' }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(10000)) {
            $process.Kill(); $process.WaitForExit()
            throw 'Component inventory timed out.'
        }
        if ($process.ExitCode -ne 0) { throw 'Component inventory failed.' }
        $assessment = Get-BridgeDataPathAssessment -Groups @($stdout.Result | ConvertFrom-Json) `
            -AdapterGuids @($Journal.Before.Wired.Guid, $Journal.Before.Tap.Guid)
        if (-not $assessment.Attached) {
            Write-Warning ("Bridge data path is unavailable: " + ($assessment.Blockers -join ', '))
        }
        return $assessment.Attached
    } catch {
        Write-Warning 'Bridge component inventory is unavailable. Host connectivity alone cannot verify the data path.'
        return $false
    } finally { $process.Dispose() }
}

function Restore-AdapterBaseline {
    param($Baseline, [switch]$AllowAbsent)
    $present = @(Get-NetAdapter -IncludeHidden | Where-Object { ([string]$_.InterfaceGuid).Trim('{}') -eq $Baseline.Guid })
    if ($AllowAbsent -and $present.Count -eq 0) { return }
    $adapter = Get-SelectedAdapter $Baseline.Guid $Baseline.Pnp
    $renew = $false
    foreach ($binding in Get-SelectedBindings $adapter) {
        $saved = @($Baseline.Bindings | Where-Object { $_.ComponentID -eq $binding.ComponentID })
        if ($saved.Count -ne 1) { throw 'Binding inventory changed; recovery needs local inspection.' }
        if ([bool]$binding.Enabled -ne [bool]$saved[0].Enabled) {
            Get-SelectedAdapter $Baseline.Guid $Baseline.Pnp | Out-Null
            Set-NetAdapterBinding -InputObject $binding -Enabled ([bool]$saved[0].Enabled) -Confirm:$false | Out-Null
            $renew = $true
        }
    }
    foreach ($saved in $Baseline.Interfaces) {
        $adapter = Get-SelectedAdapter $Baseline.Guid $Baseline.Pnp
        $interface = Get-NetIPInterface -InterfaceIndex $adapter.ifIndex -AddressFamily $saved.AddressFamily
        if ([int]$interface.Dhcp -ne [int]$saved.Dhcp -or [int]$interface.RouterDiscovery -ne [int]$saved.RouterDiscovery) {
            $interface | Set-NetIPInterface -Dhcp $saved.Dhcp -RouterDiscovery $saved.RouterDiscovery -Confirm:$false | Out-Null
            $renew = $true
            $interface = Get-NetIPInterface -InterfaceIndex $adapter.ifIndex -AddressFamily $saved.AddressFamily
        }
        # An explicit InterfaceMetric disables automatic metrics even when
        # AutomaticMetric is passed in the same call. Restore them separately.
        if ([int]$saved.AutomaticMetric -eq 1) {
            if ([int]$interface.AutomaticMetric -ne 1) { $interface | Set-NetIPInterface -AutomaticMetric Enabled -Confirm:$false | Out-Null }
        } else {
            if ([int]$interface.AutomaticMetric -ne 0 -or $interface.InterfaceMetric -ne $saved.InterfaceMetric) {
                $interface | Set-NetIPInterface -AutomaticMetric Disabled -InterfaceMetric $saved.InterfaceMetric -Confirm:$false | Out-Null
            }
        }
    }
    $adapter = Get-SelectedAdapter $Baseline.Guid $Baseline.Pnp
    $currentDns = (Get-AdapterBaseline $Baseline.Guid).StaticDns
    if (($currentDns -join '|') -ne ($Baseline.StaticDns -join '|')) {
        if (@($Baseline.StaticDns).Count) { Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses $Baseline.StaticDns }
        else { Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ResetServerAddresses }
        $renew = $true
    }
    if ($renew -and -not $AllowAbsent) {
        $config = Get-CimInstance Win32_NetworkAdapterConfiguration | Where-Object { ([string]$_.SettingID).Trim('{}') -eq $Baseline.Guid }
        if (-not $config) { throw 'DHCP recovery configuration is missing.' }
        $result = Invoke-CimMethod -InputObject $config -MethodName RenewDHCPLease
        # Windows may reject renewal while NDIS is rebinding. Success is decided
        # by the restored configuration and bound DHCP/DNS/TCP probe, not this API.
        if ($result.ReturnValue -notin @(0,1)) { Write-Warning "DHCP renewal returned $($result.ReturnValue); verifying actual wired recovery." }
    }
}

function Test-AdapterRestored {
    param($Baseline, [switch]$AllowAbsent)
    $present = @(Get-NetAdapter -IncludeHidden | Where-Object { ([string]$_.InterfaceGuid).Trim('{}') -eq $Baseline.Guid })
    if ($AllowAbsent -and $present.Count -eq 0) { return $true }
    try {
        $actual = Get-AdapterBaseline $Baseline.Guid
        if ($actual.Pnp -ne $Baseline.Pnp -or $actual.Bindings.Count -ne $Baseline.Bindings.Count) { return $false }
        foreach ($binding in $Baseline.Bindings) {
            $matches = @($actual.Bindings | Where-Object { $_.ComponentID -eq $binding.ComponentID -and $_.Enabled -eq $binding.Enabled })
            if ($matches.Count -ne 1) { return $false }
        }
        foreach ($interface in $Baseline.Interfaces) {
            $matches = @($actual.Interfaces | Where-Object { [int]$_.AddressFamily -eq [int]$interface.AddressFamily })
            if ($matches.Count -ne 1) { return $false }
            $found = $matches[0]
            if ([int]$found.Dhcp -ne [int]$interface.Dhcp -or [int]$found.RouterDiscovery -ne [int]$interface.RouterDiscovery -or
                [int]$found.AutomaticMetric -ne [int]$interface.AutomaticMetric -or
                ([int]$interface.AutomaticMetric -eq 0 -and $found.InterfaceMetric -ne $interface.InterfaceMetric)) { return $false }
        }
        if (($actual.StaticDns -join '|') -ne ($Baseline.StaticDns -join '|')) { return $false }
        return $true
    } catch { return $false }
}

function New-NativeBridgeBackend {
    @{
        Capture = {
            param($request)
            $snapshot = Get-BridgeHostSnapshot $request.DriverDirectory
            $assessment = Get-BridgeLabAssessment $snapshot -WiredGuid $request.WiredGuid -TapGuid $request.TapGuid -DisposableLab -LocalConsole -DedicatedTap
            if (-not $assessment.CanStartDisposableLab) { return [pscustomobject]@{Assessment=$assessment} }
            Assert-InstalledTapDriver (Get-SelectedAdapter $request.TapGuid)
            [pscustomobject]@{
                Assessment = $assessment; MachineGuid = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Cryptography').MachineGuid
                Wired = Get-AdapterBaseline $request.WiredGuid; Tap = Get-AdapterBaseline $request.TapGuid
                Bridges = @((Get-NativeBridgeInventory $request.DriverDirectory).Bridges | ForEach-Object { ([string]$_.Guid).Trim('{}') })
            }
        }
        ValidateIdentity = { param($j) Assert-BridgeIdentity $j }
        ValidateMachine = { param($j) Assert-BridgeMachine $j }
        ProbeBaseline = { param($before, $request) Test-WiredProbe $before.Wired.Guid $request -Seconds 5 }
        Create = {
            param($j)
            try {
                Assert-BridgeIdentity $j
                Assert-InstalledTapDriver (Get-SelectedAdapter $j.Before.Tap.Guid $j.Before.Tap.Pnp)
                $snapshot = Get-BridgeHostSnapshot $j.Request.DriverDirectory
                $assessment = Get-BridgeLabAssessment $snapshot -WiredGuid $j.Before.Wired.Guid -TapGuid $j.Before.Tap.Guid -DisposableLab -LocalConsole -DedicatedTap
                if (-not $assessment.CanStartDisposableLab -or -not (Test-AdapterRestored $j.Before.Wired) -or -not (Test-AdapterRestored $j.Before.Tap)) {
                    throw 'Adapter state changed after the baseline. Run preflight again.'
                }
            } catch { throw [OperationCanceledException]::new($_.Exception.Message) }
            # TAP must be first. Wired-first creation reports both members but
            # leaves the virtual TAP's NDIS bridge protocol unattached.
            Invoke-BridgeCommand @('create', "{$($j.Before.Tap.Guid)}", "{$($j.Before.Wired.Guid)}")
        }
        FindOwned = { param($j) Find-OwnedBridge $j }
        ProbeBridge = {
            param($j)
            if (-not (Test-WiredProbe $j.BridgeGuid $j.Request)) { return $false }
            Test-NativeBridgeDataPath $j
        }
        Destroy = {
            param($j)
            if ((Find-OwnedBridge $j) -ne $j.BridgeGuid) { throw 'Owned bridge changed before removal.' }
            Invoke-BridgeCommand @('destroy', "{$($j.BridgeGuid)}")
        }
        Restore = { param($j) Restore-AdapterBaseline $j.Before.Wired; Restore-AdapterBaseline $j.Before.Tap -AllowAbsent }
        ProbeOriginal = {
            param($j)
            if (-not (Test-AdapterRestored $j.Before.Wired) -or -not (Test-AdapterRestored $j.Before.Tap -AllowAbsent)) { return $false }
            Test-WiredProbe $j.Before.Wired.Guid $j.Request
        }
    }
}

Export-ModuleMember -Function New-NativeBridgeBackend
