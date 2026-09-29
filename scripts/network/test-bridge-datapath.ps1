$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'bridge-datapath.psm1') -Force
$passed = 0
$wired = '11111111-1111-1111-1111-111111111111'
$tap = '22222222-2222-2222-2222-222222222222'

function New-Group([string]$Guid, [int]$Index) {
    [pscustomobject]@{
        Group = 'Localized adapter name'
        Components = @(
            [pscustomobject]@{Type='Miniport'; DriverName='fixture.sys'; Properties=@(
                [pscustomobject]@{Name='ifGuid';Value="{$Guid}"}
                [pscustomobject]@{Name='ifIndex';Value=$Index}
            )}
            [pscustomobject]@{Type='Protocol'; DriverName='NdisImPlatform.sys'; Properties=@(
                [pscustomobject]@{Name='Miniport ifIndex';Value=$Index}
            )}
        )
    }
}
function New-Fixture { @(New-Group $wired 11; New-Group $tap 15) }
function Assert-Assessment($Groups, [bool]$Attached, [string[]]$Guids = @($wired,$tap)) {
    $result = Get-BridgeDataPathAssessment -Groups $Groups -AdapterGuids $Guids
    if ($result.Attached -ne $Attached -or $result.BridgeAccepted) { throw 'Incorrect data path assessment.' }
    if (-not $Attached -and -not $result.Blockers.Count) { throw 'Missing failure reason.' }
    $script:passed++
}

Assert-Assessment (New-Fixture) $true
Assert-Assessment (New-Fixture) $true @("{$wired}","{$tap}")
# An enabled binding or healthy host cannot substitute for a missing TAP protocol.
$groups=New-Fixture; $groups[1].Components=@($groups[1].Components[0])
Assert-Assessment $groups $false
$groups += New-Group '33333333-3333-3333-3333-333333333333' 7
Assert-Assessment $groups $false
$groups=New-Fixture; $groups[0].Components=@($groups[0].Components[0])
Assert-Assessment $groups $false
# Same driver elsewhere in the stack is insufficient.
$groups=New-Fixture; $groups[1].Components[1].Type='Filter'
Assert-Assessment $groups $false
$groups=New-Fixture; $groups[1].Components[1].DriverName='tap0901.sys'
Assert-Assessment $groups $false
$groups=New-Fixture; $groups[1].Components[1].Properties[0].Value=11
Assert-Assessment $groups $false
$groups=New-Fixture; $groups[1].Components[1].Properties[0].Name='ifIndex'
Assert-Assessment $groups $false
# Ambiguous identities, protocols and indices fail closed.
$groups=New-Fixture; $groups += New-Group $tap 16
Assert-Assessment $groups $false
$groups=New-Fixture; $groups[1].Components += $groups[1].Components[1]
Assert-Assessment $groups $false
$groups=New-Fixture; $groups[1].Components[0].Properties += $groups[1].Components[0].Properties[0]
Assert-Assessment $groups $false
$groups=New-Fixture; $groups[1].Components[0].Properties[1].Value=0
Assert-Assessment $groups $false
$groups=New-Fixture; $groups[1].Components[0].Properties[1].Value='unknown'
Assert-Assessment $groups $false
$groups=New-Fixture; $groups[1].Components[1].Properties=@()
Assert-Assessment $groups $false
Assert-Assessment @() $false
Assert-Assessment @([pscustomobject]@{Unexpected='schema'}) $false
Assert-Assessment (New-Fixture) $false @($wired,$wired)
Assert-Assessment (New-Fixture) $false @($wired)
Assert-Assessment (New-Fixture) $false @($wired,'invalid')
Write-Output "$passed bridge data path checks passed"
