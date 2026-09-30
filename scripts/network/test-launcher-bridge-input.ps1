$ErrorActionPreference='Stop'
Add-Type -Path (Join-Path $PSScriptRoot 'OwnedBridgeInput.cs')
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Threading;
public sealed class BlockingBridgeReader : TextReader {
 public readonly ManualResetEventSlim Release = new ManualResetEventSlim(false);
 private int calls;
 public override string ReadLine() { Release.Wait(); return Interlocked.Increment(ref calls) == 1 ? "attach" : null; }
}
'@
$count=0
function Assert($ok,$message){if(-not $ok){throw $message};$script:count++}
$original=[Console]::In
try {
    $blocking=[BlockingBridgeReader]::new();[Console]::SetIn($blocking)
    $timer=[Diagnostics.Stopwatch]::StartNew();$reader=[OwnedBridgeInput]::new()
    Assert ($timer.ElapsedMilliseconds -lt 1000) 'constructor blocked on input'
    Assert (-not $reader.Ended) 'input ended before release'
    $blocking.Release.Set()
    for($i=0;$i -lt 100 -and -not $reader.Ended;$i++){[Threading.Thread]::Sleep(10)}
    Assert $reader.Ended 'EOF did not finish input'
    Assert ($reader.Next() -eq 'attach') 'command not retained'
    Assert ($null -eq $reader.Next()) 'command read twice'
    Assert ($null -eq $reader.Failure) 'normal EOF failed'
    [Console]::SetIn([IO.StringReader]::new((('x'*8193)+"`n")));$reader=[OwnedBridgeInput]::new()
    for($i=0;$i -lt 100 -and -not $reader.Ended;$i++){[Threading.Thread]::Sleep(10)}
    Assert ($null -ne $reader.Failure) 'oversized command accepted'
    Assert ($null -eq $reader.Next()) 'oversized command queued'
    [Console]::SetIn([IO.StringReader]::new(("x`n"*9)));$reader=[OwnedBridgeInput]::new()
    for($i=0;$i -lt 100 -and -not $reader.Ended;$i++){[Threading.Thread]::Sleep(10)}
    Assert ($null -ne $reader.Failure) 'unbounded command queue accepted'
    Assert $reader.Ended 'failed input did not end'
} finally {[Console]::SetIn($original)}
Write-Host "$count launcher input checks passed"
