$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'launcher-bridge-transaction.psm1') -Force
$count=0
function Assert($ok,$message) { if (-not $ok) { throw $message };$script:count++ }
$dir=Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString());[IO.Directory]::CreateDirectory($dir)|Out-Null
$path=Join-Path $dir 'operation.json'
$state=@{Events=[Collections.Generic.List[string]]::new();Probe=$true;PrepareFails=$false;RestoreFails=$false;Foreign=$false;BeforeChanged=$false}
$backend=@{
 Capture={param($r) $state.Events.Add('capture');@{MachineGuid='machine';Tap=@{Guid='tap';Pnp='owned'}}}
 Probe={param($r) $state.Events.Add('probe');$state.Probe}
 ValidateMachine={param($j) if($j.Before.MachineGuid -ne 'machine'){throw 'foreign machine'}}
 ValidateBefore={param($b,$r) $state.Events.Add('recheck');if($state.BeforeChanged){throw 'changed'}}
 Prepare={param($j) $state.Events.Add('prepare');if($state.PrepareFails){throw 'partial setup'}}
 ValidateRecovery={param($j) $state.Events.Add('identity');if($state.Foreign){throw 'foreign identity'}}
 VerifyRestored={param($j) $true}
 Restore={param($j) $state.Events.Add('restore');if($state.RestoreFails){throw 'restore failed'}}
}
function Reset { if(Test-Path $path){Remove-Item $path};$state.Events.Clear();$state.Probe=$true;$state.PrepareFails=$false;$state.RestoreFails=$false;$state.Foreign=$false;$state.BeforeChanged=$false }
function Throws($action) { $thrown=$false;try { &$action | Out-Null } catch {$thrown=$true};Assert $thrown 'expected failure' }
function Phase { (Get-Content $path -Raw|ConvertFrom-Json).Phase }
try {
 Reset;$j=Start-LauncherBridge $backend $path @{};Assert ($j.Phase -eq 'Ready') 'not ready'
 Assert (($state.Events -join ',') -eq 'capture,probe,recheck,prepare,probe') 'setup order'
 Set-LauncherBridgeRunning $path;Assert ((Phase) -eq 'Running') 'not running'
 Throws { Start-LauncherBridge $backend $path @{} };Assert ((Phase) -eq 'Running') 'pending journal overwritten'
 Restore-LauncherBridge $backend $path|Out-Null;Assert ((Phase) -eq 'Complete') 'not cleaned'
 $before=$state.Events.Count;Restore-LauncherBridge $backend $path|Out-Null;Assert ($state.Events.Count -eq $before) 'duplicate cleanup mutated'
 Start-LauncherBridge $backend $path @{}|Out-Null;Assert ((Phase) -eq 'Ready') 'repeat setup failed'
 Reset;$state.Probe=$false;Throws {Start-LauncherBridge $backend $path @{}};Assert (-not (Test-Path $path)) 'failed baseline journaled';Assert ('prepare' -notin $state.Events) 'baseline mutated'
 Reset;$state.BeforeChanged=$true;Throws {Start-LauncherBridge $backend $path @{}};Assert (-not (Test-Path $path)) 'changed baseline journaled';Assert ('prepare' -notin $state.Events) 'changed baseline mutated'
 Reset;$state.PrepareFails=$true;Throws {Start-LauncherBridge $backend $path @{}};Assert ((Phase) -eq 'Complete') 'partial setup not recovered';Assert ('restore' -in $state.Events) 'no partial undo'
 Reset;$state.PrepareFails=$true;$state.RestoreFails=$true;Throws {Start-LauncherBridge $backend $path @{}};Assert ((Phase) -eq 'RecoveryRequired') 'failed undo not pending'
 $state.PrepareFails=$false;$state.RestoreFails=$false;Restore-LauncherBridge $backend $path|Out-Null;Assert ((Phase) -eq 'Complete') 'retry recovery failed'
 Reset;Start-LauncherBridge $backend $path @{}|Out-Null;$state.Foreign=$true;$state.Events.Clear();Throws {Restore-LauncherBridge $backend $path};Assert ((Phase) -eq 'RecoveryRequired') 'foreign identity not pending';Assert ('restore' -notin $state.Events) 'foreign identity mutated'
 $state.Foreign=$false;$state.Probe=$false;Throws {Restore-LauncherBridge $backend $path};Assert ((Phase) -eq 'RecoveryRequired') 'failed host probe accepted'
 $state.Probe=$true;Restore-LauncherBridge $backend $path|Out-Null;Assert ((Phase) -eq 'Complete') 'host recovery retry failed'
 Reset;$savedPrepare=$backend.Prepare;$backend.Prepare={param($j) $state.Events.Add('uncertain');throw [TimeoutException]::new('reply lost')}
 Throws {Start-LauncherBridge $backend $path @{}};Assert ((Phase) -eq 'RecoveryRequired') 'uncertain command not pending';Assert ('restore' -notin $state.Events) 'undo raced an uncertain command'
 $backend.Prepare=$savedPrepare;Restore-LauncherBridge $backend $path|Out-Null;Assert ((Phase) -eq 'Complete') 'explicit uncertain recovery failed'
 Reset;Assert ($null -eq (Get-LauncherBridgeRecovery $backend $path @{})) 'missing journal cannot return to NAT'
 $request=@{tapGuid='tap';tapPnp='owned';wiredGuid='wired';wiredPnp='wired-pnp'}
 Start-LauncherBridge $backend $path $request|Out-Null
 $wrong=@{tapGuid='tap';tapPnp='replacement';wiredGuid='wired';wiredPnp='wired-pnp'}
 Throws {Get-LauncherBridgeRecovery $backend $path $wrong};Assert ((Phase) -eq 'Ready') 'recovery selection changed pending journal'
 $before=$state.Events.Count;$j=Get-LauncherBridgeRecovery $backend $path $request
 Assert ($j.Phase -eq 'Ready' -and $state.Events.Count -eq $before) 'recovery preflight mutated'
 Restore-LauncherBridge $backend $path|Out-Null
 Assert ((Get-LauncherBridgeRecovery $backend $path $wrong).Phase -eq 'Complete') 'completed journal required missing adapter'
 $j=Get-Content $path -Raw|ConvertFrom-Json;$j.Before.MachineGuid='foreign';$j|ConvertTo-Json -Depth 10|Set-Content $path
 Throws {Get-LauncherBridgeRecovery $backend $path $request}
 Write-Host "$count launcher bridge transaction checks passed"
} finally {Remove-Item $dir -Recurse -Force}
