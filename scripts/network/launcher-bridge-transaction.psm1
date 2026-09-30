Set-StrictMode -Version Latest
$store = Import-Module (Join-Path $PSScriptRoot 'bridge-transaction.psm1') -Force -PassThru
function Write-LauncherBridgeJournal($Path,$Journal) {
    & $store { param($p,$j) Write-BridgeJournal $p $j } $Path $Journal
}
function Read-LauncherBridgeJournal($Path) {
    $j = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if ($j.Version -ne 1 -or $j.Kind -ne 'NpcapLauncher' -or $j.Phase -notin @('Preparing','Ready','Running','Restoring','RecoveryRequired','Complete')) { throw 'Unrecognized launcher bridge journal.' }
    $j
}
function Get-LauncherBridgeRecovery($Backend,$Path,$Request) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $j=Read-LauncherBridgeJournal $Path
    & $Backend.ValidateMachine $j
    if ($j.Phase -ne 'Complete') {
        foreach ($field in 'tapGuid','tapPnp','wiredGuid','wiredPnp') {
            if ($j.Request.$field -ne $Request.$field) { throw 'Use the exact saved plan for recovery.' }
        }
    }
    return $j
}
function Restore-LauncherBridge($Backend,$Path) {
    $j = Read-LauncherBridgeJournal $Path
    & $Backend.ValidateMachine $j
    if ($j.Phase -eq 'Complete') { return $j }
    try {
        # Identity/configuration validation is separate from restoration. A
        # foreign PNP device or unrelated binding edit is never undone.
        & $Backend.ValidateRecovery $j
        $j.Phase = 'Restoring'; Write-LauncherBridgeJournal $Path $j
        & $Backend.Restore $j
        if (-not (& $Backend.VerifyRestored $j)) { throw 'TAP bindings did not recover.' }
        if (-not (& $Backend.Probe $j.Request)) { throw 'Host connectivity has not recovered.' }
        $j.Phase = 'Complete'; $j.Error = ''; Write-LauncherBridgeJournal $Path $j
        return $j
    } catch {
        $j.Phase = 'RecoveryRequired'; $j.Error = $_.Exception.Message
        Write-LauncherBridgeJournal $Path $j
        throw
    }
}
function Start-LauncherBridge($Backend,$Path,$Request) {
    if (Test-Path -LiteralPath $Path) {
        $old = Read-LauncherBridgeJournal $Path
        & $Backend.ValidateMachine $old
        if ($old.Phase -ne 'Complete') { throw 'Recover the previous launcher bridge before starting another.' }
    }
    $before = & $Backend.Capture $Request
    if (-not (& $Backend.Probe $Request)) { throw 'Wired host connectivity baseline failed.' }
    # Recheck after the probe, before intent or any mutation.
    & $Backend.ValidateBefore $before $Request
    $j = [pscustomobject]@{ Version=1; Kind='NpcapLauncher'; Phase='Preparing'; Before=$before; Request=$Request; Error='' }
    Write-LauncherBridgeJournal $Path $j
    try {
        & $Backend.Prepare $j
        if (-not (& $Backend.Probe $Request)) { throw 'Host connectivity failed after TAP preparation.' }
        $j.Phase = 'Ready'; Write-LauncherBridgeJournal $Path $j
        return $j
    } catch {
        $failure = $_.Exception.Message
        if ($_.Exception -is [TimeoutException]) {
            $j.Phase='RecoveryRequired';$j.Error=$failure;Write-LauncherBridgeJournal $Path $j
            throw "Binding command completion is uncertain. Inspect locally before recovery: $failure"
        }
        try { Restore-LauncherBridge $Backend $Path | Out-Null }
        catch { throw "Bridge preparation failed: $failure Recovery is pending: $($_.Exception.Message)" }
        throw "Bridge preparation failed: $failure TAP bindings recovered."
    }
}
function Set-LauncherBridgeRunning($Path) {
    $j=Read-LauncherBridgeJournal $Path
    if ($j.Phase -ne 'Ready') { throw 'Bridge is not prepared.' }
    $j.Phase='Running';Write-LauncherBridgeJournal $Path $j
}
Export-ModuleMember -Function Get-LauncherBridgeRecovery, Start-LauncherBridge, Restore-LauncherBridge, Set-LauncherBridgeRunning
