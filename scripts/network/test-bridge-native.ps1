$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'bridge-native.psm1') -Force
try {
    $passed = & (Get-Module bridge-native) {
        # Exercise the actual backend create path without touching host networking.
        $script:commands = [Collections.Generic.List[string]]::new()
        $script:preflight = $true
        function script:Assert-BridgeIdentity { param($Journal) }
        function script:Assert-InstalledTapDriver { param($Adapter) }
        function script:Get-SelectedAdapter { param($Guid,$Pnp) [pscustomobject]@{Guid=$Guid} }
        function script:Get-BridgeHostSnapshot { param($Directory) [pscustomobject]@{} }
        function script:Get-BridgeLabAssessment {
            param($Snapshot,$WiredGuid,$TapGuid,[switch]$DisposableLab,[switch]$LocalConsole,[switch]$DedicatedTap)
            [pscustomobject]@{CanStartDisposableLab=$script:preflight}
        }
        function script:Test-AdapterRestored { param($Baseline) $true }
        function script:Invoke-BridgeCommand {
            param([string[]]$Arguments)
            $script:commands.Add(($Arguments -join ' '))
        }
        $journal = [pscustomobject]@{
            Before=[pscustomobject]@{
                Wired=[pscustomobject]@{Guid='11111111-1111-1111-1111-111111111111';Pnp='wired'}
                Tap=[pscustomobject]@{Guid='22222222-2222-2222-2222-222222222222';Pnp='tap'}
            }
            Request=[pscustomobject]@{DriverDirectory='fixture'}
        }
        $backend = New-NativeBridgeBackend
        & $backend.Create $journal
        if ($script:commands.Count -ne 1 -or $script:commands[0] -ne
            'create {22222222-2222-2222-2222-222222222222} {11111111-1111-1111-1111-111111111111}') {
            throw 'The native backend did not select the exact TAP before Ethernet.'
        }
        $script:preflight = $false
        $canceled = $false
        try { & $backend.Create $journal } catch [OperationCanceledException] { $canceled=$true }
        if (-not $canceled -or $script:commands.Count -ne 1) {
            throw 'Changed preflight reached the native bridge command.'
        }
        2
    }
    Write-Output "$passed native bridge checks passed"
} finally {
    # Module-scoped platform mocks must not escape into later lab operations.
    Remove-Module bridge-native -Force
}
