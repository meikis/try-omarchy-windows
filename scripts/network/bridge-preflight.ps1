# Read-only inventory. A successful assessment is permission to prepare a lab,
# not proof that a bridge works and not a request to install a driver.
[CmdletBinding()]
param(
    [string]$DriverDirectory,
    [string]$WiredGuid,
    [string]$TapGuid,
    [switch]$DisposableLab,
    [switch]$LocalConsole,
    [switch]$DedicatedTap
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'bridge-preflight.psm1') -Force
$snapshot = Get-BridgeHostSnapshot -DriverDirectory $DriverDirectory
Get-BridgeLabAssessment -Snapshot $snapshot -WiredGuid $WiredGuid -TapGuid $TapGuid `
    -DisposableLab:$DisposableLab -LocalConsole:$LocalConsole -DedicatedTap:$DedicatedTap | ConvertTo-Json -Depth 6
