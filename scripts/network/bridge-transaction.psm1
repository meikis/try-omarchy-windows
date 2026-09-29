Set-StrictMode -Version Latest

# The backend owns Windows calls; the transaction owns durable intent and order.
# This is a disposable-lab helper, not a launcher networking preference.
function Write-BridgeJournal {
    param([string]$Path, $Journal)
    $temporary = "$Path.$([guid]::NewGuid()).tmp"
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes(($Journal | ConvertTo-Json -Depth 20))
        $stream = [IO.FileStream]::new($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
        if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temporary, $Path, [NullString]::Value) }
        else { [IO.File]::Move($temporary, $Path) }
    } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force } }
}

function Set-BridgePhase {
    param($Journal, [string]$Phase, [string]$Path)
    $Journal.Phase = $Phase
    Write-BridgeJournal $Path $Journal
}

function Read-BridgeJournal {
    param([string]$Path)
    $journal = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if ($journal.Version -ne 1 -or $journal.Phase -notin @('Prepared','Creating','Verifying','Active','RollingBack','Restoring','RecoveryRequired','Complete')) {
        throw 'Unrecognized bridge journal. No network changes made.'
    }
    $journal
}

function Undo-BridgeLabTransaction {
    param([hashtable]$Backend, [string]$JournalPath)
    $journal = Read-BridgeJournal $JournalPath
    # Validate even a completed journal before accepting it on another machine.
    & $Backend.ValidateMachine $journal | Out-Null
    if ($journal.Phase -eq 'Complete') { return $journal }
    & $Backend.ValidateIdentity $journal | Out-Null
    try {
        if ($journal.Phase -ne 'Prepared') {
            # Recovery after an interrupted create requires exact membership.
            # An ambiguous or changed bridge is never permission to destroy it.
            $owned = & $Backend.FindOwned $journal
            if ($owned) {
                $journal.BridgeGuid = [string]$owned
                Set-BridgePhase $journal RollingBack $JournalPath
                & $Backend.Destroy $journal | Out-Null
            }
            Set-BridgePhase $journal Restoring $JournalPath
            & $Backend.Restore $journal | Out-Null
        }
        if (-not (& $Backend.ProbeOriginal $journal)) { throw 'Original wired connectivity has not recovered.' }
        Set-BridgePhase $journal Complete $JournalPath
        return $journal
    } catch {
        $journal.Error = $_.Exception.Message
        Set-BridgePhase $journal RecoveryRequired $JournalPath
        throw
    }
}

function Start-BridgeLabTransaction {
    param([hashtable]$Backend, [string]$JournalPath, $Request)
    if (Test-Path -LiteralPath $JournalPath) {
        $previous = Read-BridgeJournal $JournalPath
        if ($previous.Phase -ne 'Complete') { throw 'An existing bridge journal requires disable or recovery first.' }
        & $Backend.ValidateMachine $previous | Out-Null
    }
    $before = & $Backend.Capture $Request
    if (-not $before.Assessment.CanStartDisposableLab) { throw ('Bridge preflight blocked: ' + ($before.Assessment.Blockers -join ', ')) }
    if (-not (& $Backend.ProbeBaseline $before $Request)) { throw 'The selected wired baseline probe failed. No network changes made.' }
    $journal = [pscustomobject]@{
        Version = 1; Operation = [guid]::NewGuid().ToString(); Phase = 'Prepared'
        Before = $before; Request = $Request; BridgeGuid = ''; Error = ''
    }
    Write-BridgeJournal $JournalPath $journal
    try {
        Set-BridgePhase $journal Creating $JournalPath
        & $Backend.Create $journal | Out-Null
        $owned = & $Backend.FindOwned $journal
        if (-not $owned) { throw 'Bridge creation did not produce the selected pair.' }
        $journal.BridgeGuid = [string]$owned
        Set-BridgePhase $journal Verifying $JournalPath
        if (-not (& $Backend.ProbeBridge $journal)) { throw 'Bridge connectivity or protocol attachment failed.' }
        Set-BridgePhase $journal Active $JournalPath
        return $journal
    } catch {
        $uncertain = $_.Exception -is [TimeoutException]
        $untouched = $_.Exception -is [OperationCanceledException]
        $failure = $_.Exception.Message
        $journal.Error = $failure
        if ($untouched) {
            Set-BridgePhase $journal Complete $JournalPath
            throw "Bridge setup stopped before network changes: $failure"
        }
        if ($uncertain) {
            Set-BridgePhase $journal RecoveryRequired $JournalPath
            throw "Bridge command completion is uncertain. Recovery is pending: $failure"
        }
        Write-BridgeJournal $JournalPath $journal
        try { Undo-BridgeLabTransaction $Backend $JournalPath | Out-Null }
        catch { throw "Bridge setup failed: $failure Recovery is pending: $($_.Exception.Message)" }
        throw "Bridge setup failed: $failure Original wired connectivity recovered."
    }
}

Export-ModuleMember -Function Start-BridgeLabTransaction, Undo-BridgeLabTransaction
