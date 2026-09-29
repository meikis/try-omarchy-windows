$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'bridge-transaction.psm1') -Force
$passed = 0
$temporary = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $temporary | Out-Null

function New-LabFixture {
    $script:lab = @{Bridge=''; Calls=[Collections.Generic.List[string]]::new(); Fail=''; Foreign=$false; Identity=$true; Machine=$true; Original=$true; Baseline=$true; Preflight=$true}
    @{
        Capture = { param($r) [pscustomobject]@{Assessment=[pscustomobject]@{CanStartDisposableLab=$script:lab.Preflight;Blockers=@('fixture')};MachineGuid='fixture';Wired='wired';Tap='tap';Bridges=@()} }
        ValidateIdentity = { param($j) if (-not $script:lab.Identity) { throw 'Identity changed' } }
        ValidateMachine = { param($j) if (-not $script:lab.Machine) { throw 'Wrong machine' } }
        ProbeBaseline = { param($b,$r) $script:lab.Baseline }
        Create = {
            param($j)
            if ($script:lab.Fail -eq 'cancel') { throw [OperationCanceledException]::new('Fresh preflight rejected the operation') }
            $script:lab.Calls.Add('create')
            # Verify durable intent exists before a destructive backend call.
            if ((Get-Content $script:journal -Raw | ConvertFrom-Json).Phase -ne 'Creating') { throw 'Missing durable create intent' }
            if ($script:lab.Fail -eq 'create-before') { throw 'Create rejected' }
            $script:lab.Bridge='owned'
            if ($script:lab.Fail -eq 'create-after') { throw 'Create reply lost' }
            if ($script:lab.Fail -eq 'timeout') { throw [TimeoutException]::new('Completion uncertain') }
        }
        FindOwned = { param($j) if ($script:lab.Foreign) { throw 'Foreign membership' }; if ($script:lab.Bridge) { $script:lab.Bridge } }
        ProbeBridge = { param($j) $script:lab.Fail -ne 'probe' }
        Destroy = {
            param($j) $script:lab.Calls.Add('destroy')
            if ($j.BridgeGuid -ne 'owned') { throw 'Wrong bridge selected' }
            if ($script:lab.Fail -eq 'destroy') { throw 'Destroy rejected' }
            $script:lab.Bridge=''
        }
        Restore = { param($j) $script:lab.Calls.Add('restore'); if ($script:lab.Fail -eq 'restore') { throw 'Restore failed' } }
        ProbeOriginal = { param($j) $script:lab.Original }
    }
}
function Assert-Equal($actual,$expected) {
    if (($actual | ConvertTo-Json -Compress) -ne ($expected | ConvertTo-Json -Compress)) { throw "Expected $expected, got $actual" }
    $script:passed++
}
function Assert-Fails([scriptblock]$Action) {
    $failed=$false
    try { & $Action | Out-Null } catch { $failed=$true }
    if (-not $failed) { throw 'Expected failure' }; $script:passed++
}
function New-Case {
    $script:journal=Join-Path $temporary "$([guid]::NewGuid()).json"
    New-LabFixture
}
try {
    $backend=New-Case
    $j=Start-BridgeLabTransaction $backend $journal @{}
    Assert-Equal $j.Phase Active
    Assert-Fails { Start-BridgeLabTransaction $backend $journal @{} }
    $j=Undo-BridgeLabTransaction $backend $journal
    Assert-Equal $j.Phase Complete
    Assert-Equal @($lab.Calls.ToArray()) @('create','destroy','restore')
    Undo-BridgeLabTransaction $backend $journal | Out-Null
    Assert-Equal @($lab.Calls.ToArray()) @('create','destroy','restore')
    # Enable after complete is a new operation, never a replayed create.
    Start-BridgeLabTransaction $backend $journal @{} | Out-Null
    Assert-Equal @($lab.Calls.ToArray()) @('create','destroy','restore','create')

    foreach ($failure in 'create-before','create-after','probe') {
        $backend=New-Case; $lab.Fail=$failure
        Assert-Fails { Start-BridgeLabTransaction $backend $journal @{} }
        Assert-Equal (Get-Content $journal -Raw | ConvertFrom-Json).Phase Complete
        Assert-Equal $lab.Bridge ''
        $expected=if ($failure -eq 'create-before') { @('create','restore') } else { @('create','destroy','restore') }
        Assert-Equal @($lab.Calls.ToArray()) $expected
    }
    foreach ($fault in 'Preflight','Baseline') {
        $backend=New-Case; $lab[$fault]=$false
        Assert-Fails { Start-BridgeLabTransaction $backend $journal @{} }
        Assert-Equal $lab.Calls.Count 0
        Assert-Equal (Test-Path $journal) $false
    }
    $backend=New-Case; $lab.Fail='timeout'
    Assert-Fails { Start-BridgeLabTransaction $backend $journal @{} }
    Assert-Equal (Get-Content $journal -Raw | ConvertFrom-Json).Phase RecoveryRequired
    Assert-Equal @($lab.Calls.ToArray()) @('create')
    $lab.Fail=''
    Assert-Equal (Undo-BridgeLabTransaction $backend $journal).Phase Complete
    # Failure to persist intent must precede every mutation.
    $backend=New-Case
    $journal=Join-Path $temporary 'absent\operation.json'
    Assert-Fails { Start-BridgeLabTransaction $backend $journal @{} }
    Assert-Equal $lab.Calls.Count 0
    $backend=New-Case; $lab.Fail='cancel'
    Assert-Fails { Start-BridgeLabTransaction $backend $journal @{} }
    Assert-Equal (Get-Content $journal -Raw | ConvertFrom-Json).Phase Complete
    Assert-Equal $lab.Calls.Count 0
    # Completed cleanup does not require a removed adapter to reappear, but
    # the journal must still belong to this Windows installation.
    $lab.Identity=$false
    Assert-Equal (Undo-BridgeLabTransaction $backend $journal).Phase Complete
    $lab.Machine=$false
    Assert-Fails { Undo-BridgeLabTransaction $backend $journal }
    foreach ($fault in 'destroy','restore') {
        $backend=New-Case
        Start-BridgeLabTransaction $backend $journal @{} | Out-Null
        $lab.Fail=$fault
        Assert-Fails { Undo-BridgeLabTransaction $backend $journal }
        Assert-Equal (Get-Content $journal -Raw | ConvertFrom-Json).Phase RecoveryRequired
        $lab.Fail=''
        Assert-Equal (Undo-BridgeLabTransaction $backend $journal).Phase Complete
        Assert-Equal $lab.Bridge ''
    }
    foreach ($fault in 'Foreign','Identity') {
        $backend=New-Case
        Start-BridgeLabTransaction $backend $journal @{} | Out-Null
        if ($fault -eq 'Foreign') { $lab.Foreign=$true } else { $lab.Identity=$false }
        Assert-Fails { Undo-BridgeLabTransaction $backend $journal }
        Assert-Equal @($lab.Calls.ToArray()) @('create')
        Assert-Equal $lab.Bridge owned
    }
    $backend=New-Case
    Start-BridgeLabTransaction $backend $journal @{} | Out-Null
    $lab.Original=$false
    Assert-Fails { Undo-BridgeLabTransaction $backend $journal }
    Assert-Equal (Get-Content $journal -Raw | ConvertFrom-Json).Phase RecoveryRequired
    $lab.Original=$true
    Assert-Equal (Undo-BridgeLabTransaction $backend $journal).Phase Complete
    # Crash between create and recording its GUID is recovered by exact membership.
    $backend=New-Case
    $j=Start-BridgeLabTransaction $backend $journal @{}
    $j.Phase='Creating'; $j.BridgeGuid=''
    $j | ConvertTo-Json -Depth 20 | Set-Content $journal
    Assert-Equal (Undo-BridgeLabTransaction $backend $journal).Phase Complete
    Assert-Equal @($lab.Calls.ToArray()) @('create','destroy','restore')
    # Prepared means no create was attempted, so cleanup performs no mutations.
    $backend=New-Case
    $j=Start-BridgeLabTransaction $backend $journal @{}
    $j.Phase='Prepared'; $j.BridgeGuid=''; $lab.Bridge=''; $lab.Calls.Clear()
    $j | ConvertTo-Json -Depth 20 | Set-Content $journal
    Assert-Equal (Undo-BridgeLabTransaction $backend $journal).Phase Complete
    Assert-Equal $lab.Calls.Count 0
    # Unknown/corrupt journals never reach the backend.
    $backend=New-Case
    Set-Content $journal '{"Version":999,"Phase":"Active"}'
    Assert-Fails { Undo-BridgeLabTransaction $backend $journal }
    Assert-Equal $lab.Calls.Count 0
    Set-Content $journal '{broken'
    Assert-Fails { Undo-BridgeLabTransaction $backend $journal }
    Assert-Equal $lab.Calls.Count 0
    Write-Output "$passed bridge transaction checks passed"
} finally { Remove-Item -LiteralPath $temporary -Recurse -Force }
