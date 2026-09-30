# Invoked only from the launcher's embedded, protected payload.
param([Parameter(Mandatory)]$Request,[Parameter(Mandatory)][string]$Directory)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$native=Import-Module (Join-Path $PSScriptRoot 'bridge-native.psm1') -Force -PassThru
Import-Module (Join-Path $PSScriptRoot 'bridge-preflight.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'launcher-bridge-transaction.psm1') -Force
$p=$Request.Plan
if ($p.version -ne 1 -or -not $p.disposableLab -or -not $p.localConsole -or -not $p.dedicatedTap -or -not $p.guestNetworkPrepared -or $env:SSH_CONNECTION -or $env:SSH_CLIENT -or $env:SESSIONNAME -like 'RDP-*') { throw 'Explicit disposable wired lab, independent local console, dedicated TAP and prepared guest routes are required.' }
$principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'The bridge broker requires explicit elevation.' }
$journal=Join-Path $Directory 'operation.json'
$ownedBindings=@('ms_tcpip','ms_tcpip6','ms_msclient','ms_server','ms_netbios','ms_netbt')
$machine=(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Cryptography').MachineGuid
function Set-OwnedBinding($Binding,[bool]$Enabled) {
    try { $Binding | Set-NetAdapterBinding -Enabled $Enabled -Confirm:$false | Out-Null }
    catch { throw [TimeoutException]::new("TAP binding command did not complete reliably: $($_.Exception.Message)") }
}
function Get-Exact($Guid,$Pnp) { & $native { param($g,$p) Get-SelectedAdapter $g $p } $Guid $Pnp }
function Get-Bindings($Adapter) { & $native { param($a) Get-SelectedBindings $a } $Adapter }
function Assert-Npcap {
    $lock=Get-Content (Join-Path $PSScriptRoot 'npcap-1.89.lock.json') -Raw | ConvertFrom-Json
    foreach ($entry in $lock.files.PSObject.Properties) {
        $path=Join-Path ([Environment]::SystemDirectory) $entry.Name
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $entry.Value -or (Get-AuthenticodeSignature -LiteralPath $path).Status -ne 'Valid') { throw 'Npcap installed files are not pinned and signed.' }
    }
    $drivers=@(Get-CimInstance Win32_SystemDriver -Filter "Name='npcap'")
    if ($drivers.Count -ne 1 -or $drivers[0].State -ne 'Running' -or [IO.Path]::GetFullPath(([string]$drivers[0].PathName).Trim('"')) -ne (Join-Path ([Environment]::SystemDirectory) 'drivers\npcap.sys')) { throw 'Pinned Npcap kernel service is not running at its expected path.' }
    $options=Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\npcap\Parameters'
    if ($options.AdminOnly -ne 1 -or $options.Dot11Support -ne 0 -or $options.WinPcapCompatible -ne 0) { throw 'Npcap requires administrator-only capture, without wireless or WinPcap compatibility.' }
}
function Assert-Selection($r,[switch]$Opened) {
    $snapshot=Get-BridgeHostSnapshot $r.driverDirectory
    $assessment=Get-BridgeLabAssessment $snapshot $r.wiredGuid $r.tapGuid -DisposableLab -LocalConsole -DedicatedTap
    $blockers=@($assessment.Blockers | Where-Object { -not ($Opened -and $_ -eq 'tap-not-idle') })
    if ($blockers.Count) { throw ('Bridge preflight failed: '+($blockers -join ', ')) }
    $wired=Get-Exact $r.wiredGuid $r.wiredPnp; $tap=Get-Exact $r.tapGuid $r.tapPnp
    & $native { param($a) Assert-InstalledTapDriver $a } $tap
    Assert-Npcap
    if (([string]$wired.MacAddress).Replace('-',':') -ieq $r.lanMac -or ([string]$wired.MacAddress).Replace('-',':') -ieq $r.privateMac) { throw 'Guest and host MACs must differ.' }
    if (@(Get-NetIPAddress -AddressFamily IPv4 | Where-Object IPAddress -eq $r.probeAddress).Count) { throw 'The wired probe must be a separate peer, not this Windows host.' }
    $other=@(Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and ([guid]$_.InterfaceGuid) -notin @([guid]$r.wiredGuid,[guid]$r.tapGuid) })
    if (-not $other.Count) { throw 'An independent management adapter must remain up.' }
    foreach ($a in $wired,$tap) { if ('nmap_npcap' -notin @(Get-Bindings $a | Where-Object Enabled | Select-Object -ExpandProperty ComponentID)) { throw 'Npcap is not attached to the selected adapter.' } }
}
$backend=@{
 Capture={ param($r) Assert-Selection $r; [pscustomobject]@{ MachineGuid=$machine; Tap=(& $native { param($g) Get-AdapterBaseline $g } $r.tapGuid); Wired=(& $native { param($g) Get-AdapterBaseline $g } $r.wiredGuid) } }
 ValidateMachine={ param($j) if ($j.Before.MachineGuid -ne $machine) { throw 'Journal belongs to a different Windows installation.' } }
 Probe={ param($r) & $native { param($g,$r) Test-WiredProbe $g ([pscustomobject]@{ProbeName=$r.probeName;ProbeAddress=$r.probeAddress;ProbePort=$r.probePort}) 5 } $r.wiredGuid $r }
 ValidateBefore={ param($before,$r)
    Assert-Selection $r
    foreach ($saved in $before.Tap,$before.Wired) {
        if (-not (& $native { param($s) Test-AdapterRestored $s } $saved)) { throw 'Adapter baseline changed before setup.' }
    }
 }
 Prepare={ param($j)
    foreach ($id in $ownedBindings) {
        $tap=Get-Exact $j.Request.tapGuid $j.Request.tapPnp
        $binding=@(Get-Bindings $tap | Where-Object ComponentID -eq $id)
        if ($binding.Count -eq 0 -and $id -notin @('ms_tcpip','ms_tcpip6')) { continue };if ($binding.Count -ne 1) { throw 'TAP binding inventory is ambiguous.' }
        if ($binding[0].Enabled) { Set-OwnedBinding $binding[0] $false }
    }
 }
 ValidateRecovery={ param($j)
    $tap=@(Get-NetAdapter -IncludeHidden | Where-Object { ([string]$_.InterfaceGuid).Trim('{}') -eq $j.Before.Tap.Guid })
    if ($tap.Count -gt 1 -or ($tap.Count -eq 1 -and [string]$tap[0].PnPDeviceID -ne $j.Before.Tap.Pnp)) { throw 'Owned TAP identity changed.' }
    if ($tap.Count -eq 1) {
        $current=@(Get-Bindings $tap[0]);$saved=@($j.Before.Tap.Bindings)
        if ($current.Count -ne $saved.Count) { throw 'TAP binding inventory changed.' }
        foreach ($b in $current) {
            $old=@($saved | Where-Object ComponentID -eq $b.ComponentID)
            if ($old.Count -ne 1 -or ($b.ComponentID -notin $ownedBindings -and [bool]$b.Enabled -ne [bool]$old[0].Enabled)) { throw 'Unrelated TAP bindings changed. Inspect locally before recovery.' }
        }
    }
 }
 VerifyRestored={ param($j)
    $tap=@(Get-NetAdapter -IncludeHidden | Where-Object { ([string]$_.InterfaceGuid).Trim('{}') -eq $j.Before.Tap.Guid })
    if ($tap.Count -eq 0) { return $true }
    $current=@(Get-Bindings $tap[0] | Sort-Object ComponentID | Select-Object ComponentID,Enabled)
    $saved=@($j.Before.Tap.Bindings | Sort-Object ComponentID | Select-Object ComponentID,Enabled)
    return (($current | ConvertTo-Json -Compress) -eq ($saved | ConvertTo-Json -Compress))
 }
 Restore={ param($j)
    $tap=@(Get-NetAdapter -IncludeHidden | Where-Object { ([string]$_.InterfaceGuid).Trim('{}') -eq $j.Before.Tap.Guid })
    if ($tap.Count -eq 1) {
        foreach ($id in $ownedBindings) {
            $a=Get-Exact $j.Before.Tap.Guid $j.Before.Tap.Pnp
            $binding=@(Get-Bindings $a | Where-Object ComponentID -eq $id)
            $saved=@($j.Before.Tap.Bindings | Where-Object ComponentID -eq $id)
            if ($binding.Count -eq 0 -and $saved.Count -eq 0 -and $id -notin @('ms_tcpip','ms_tcpip6')) { continue };if ($binding.Count -ne 1 -or $saved.Count -ne 1) { throw 'TAP recovery binding inventory is ambiguous.' }
            if ([bool]$binding[0].Enabled -ne [bool]$saved[0].Enabled) { Set-OwnedBinding $binding[0] ([bool]$saved[0].Enabled) }
        }
    }
 }
}
$held=$null;$prepared=$false;$failure=$null;$mutex=$null;$mutexHeld=$false;$tapReady=$null
try {
    $held=[IO.File]::Open((Join-Path $Directory 'operation.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    if ($Request.Action -notin @('Start','Recover')) { throw 'Unknown broker action.' }
    if ($Request.Action -eq 'Recover') {
        $previous=Get-Content -LiteralPath $journal -Raw|ConvertFrom-Json
        foreach ($field in 'tapGuid','tapPnp','wiredGuid','wiredPnp') { if ($previous.Request.$field -ne $p.$field) { throw 'Use the exact saved plan for recovery.' } }
    }
    $created=$false
    $mutex=[Threading.Mutex]::new($false,('Global\TryOmarchyNpcapLab-'+([guid]$p.tapGuid).ToString()),[ref]$created)
    try { $mutexHeld=$mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $mutexHeld=$true }
    if (-not $mutexHeld) { throw 'Another frame pump owns this TAP.' }
    if ($Request.Action -eq 'Recover') { Restore-LauncherBridge $backend $journal | Out-Null; [Console]::WriteLine('{"state":"complete"}');return }
    $nativeJournal=Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'TryOmarchyBridgeLab\operation.json'
    if ((Test-Path -LiteralPath $nativeJournal) -and (Get-Content -LiteralPath $nativeJournal -Raw|ConvertFrom-Json).Phase -ne 'Complete') { throw 'Recover the native Windows bridge journal first.' }
    $active=Start-LauncherBridge $backend $journal $p;$prepared=$true
    $tap=Get-Exact $p.tapGuid $p.tapPnp;$wired=Get-Exact $p.wiredGuid $p.wiredPnp
    $wiredMac=([string]$wired.MacAddress).Replace('-',':').ToLowerInvariant()
    Add-Type -Path @((Join-Path $PSScriptRoot 'NpcapFramePump.cs'),(Join-Path $PSScriptRoot 'HostTcpSegmentation.cs'),(Join-Path $PSScriptRoot 'OwnedBridgeInput.cs'))
    $tapReady=[Threading.ManualResetEventSlim]::new($false)
    $state=@{ Input=[OwnedBridgeInput]::new(); Qemu=$null; Stop=$false; TapOpened=$false; Deadline=[DateTime]::UtcNow.AddSeconds(90) }
    $guard=[Action]{
        if ($state.Input.Failure) { throw 'Bridge input failed or exceeded its command limits.' }
        if ($state.Input.Ended) { $state.Stop=$true;return }
        $line=$state.Input.Next()
        if ($null -ne $line) {
            $command=$line | ConvertFrom-Json
            if ($command.action -eq 'stop') { $state.Stop=$true;return }
            if ($command.action -ne 'attach' -or $state.Qemu) { throw 'Unexpected broker command.' }
            $q=Get-CimInstance Win32_Process -Filter "ProcessId=$([int]$command.pid)"
            if (-not $q -or $q.ExecutablePath -ne $command.executable -or $q.Name -notmatch '^qemu-system-x86_64w?\.exe$') { throw 'QEMU identity does not match.' }
            $argument='-netdev\s+"?tap,[^\s]*ifname="?'+[regex]::Escape(([string]$tap.Name).Replace(',',',,'))+'(?:"|\s|$)'
            if ($q.CommandLine -notmatch $argument -or $q.CommandLine -notmatch ('mac='+[regex]::Escape($p.lanMac)) -or $q.CommandLine -notmatch ('mac='+[regex]::Escape($p.privateMac))) { throw 'QEMU does not own the selected dual-network configuration.' }
            $state.Qemu=$q;$state.Deadline=[DateTime]::UtcNow.AddSeconds(20)
        }
        if ($state.Stop) { return }
        $w=Get-Exact $p.wiredGuid $p.wiredPnp;$t=Get-Exact $p.tapGuid $p.tapPnp
        if ($w.Status -ne 'Up' -or ([string]$w.MacAddress).Replace('-',':').ToLowerInvariant() -ne $wiredMac) { throw 'Selected wired link or MAC changed.' }
        foreach ($a in $w,$t) {
            $ids=@(Get-Bindings $a | Where-Object Enabled | Select-Object -ExpandProperty ComponentID)
            if ('nmap_npcap' -notin $ids -or 'vms_pp' -in $ids -or (Test-BridgeBinding $ids)) { throw 'Selected adapter bindings changed.' }
        }
        if (@(Get-Bindings $t | Where-Object { $_.Enabled -and $_.ComponentID -in $ownedBindings }).Count) { throw 'Owned TAP bindings changed.' }
        $currentWired=@(Get-Bindings $w|Sort-Object ComponentID|Select-Object ComponentID,Enabled)
        $savedWired=@($active.Before.Wired.Bindings|Sort-Object ComponentID|Select-Object ComponentID,Enabled)
        if (($currentWired|ConvertTo-Json -Compress) -ne ($savedWired|ConvertTo-Json -Compress)) { throw 'Selected wired bindings changed.' }
        if ($state.Qemu) {
            $q=Get-CimInstance Win32_Process -Filter "ProcessId=$($state.Qemu.ProcessId)"
            if (-not $q -or $q.CreationDate -ne $state.Qemu.CreationDate -or $q.ExecutablePath -ne $state.Qemu.ExecutablePath) { $state.Stop=$true;return }
            if ($t.Status -eq 'Up' -and -not $state.TapOpened) {
                $state.TapOpened=$true;$tapReady.Set();Set-LauncherBridgeRunning $journal
                [Console]::WriteLine('{"state":"running"}')
            } elseif ($t.Status -ne 'Up' -and ($state.TapOpened -or [DateTime]::UtcNow -gt $state.Deadline)) { throw 'Owned TAP did not open or lost its link.' }
        } elseif ([DateTime]::UtcNow -gt $state.Deadline) { throw 'Launcher did not attach QEMU in time.' }
    }
    $ready=[Action]{ [Console]::WriteLine((@{state='forwarding';tapName=[string]$tap.Name} | ConvertTo-Json -Compress)) }
    $keep=[Func[bool]]{ -not $state.Stop }
    try {
        [NpcapFramePump]::RunOwned($p.wiredGuid,$p.tapGuid,$p.lanMac,$wiredMac,$guard,$ready,$keep,$tapReady) | Out-Null
    } catch {
        # QEMU closes TAP before the periodic guard can observe process exit.
        # Accept only that disconnect error after independently checking the
        # original process identity. Recovery below must still succeed.
        $ended=$false
        if ($state.Qemu -and $_.Exception.Message -match 'Transmit injection failed:.*network media is disconnected') {
            $current=Get-CimInstance Win32_Process -Filter "ProcessId=$($state.Qemu.ProcessId)"
            $ended=(-not $current -or $current.CreationDate -ne $state.Qemu.CreationDate -or $current.ExecutablePath -ne $state.Qemu.ExecutablePath)
        }
        if (-not $ended) { throw }
    }
} catch { $failure=$_.Exception.Message }
finally {
    if ($prepared) { try { Restore-LauncherBridge $backend $journal | Out-Null } catch { $failure="$failure Recovery is pending: $($_.Exception.Message)" } }
    if ($tapReady) { $tapReady.Dispose() }
    if ($mutexHeld) { $mutex.ReleaseMutex() };if ($mutex) { $mutex.Dispose() }
    if ($held) { $held.Dispose() }
}
if ($failure) { [Console]::WriteLine((@{state='error';error=$failure} | ConvertTo-Json -Compress));exit 1 }
[Console]::WriteLine('{"state":"complete"}')
