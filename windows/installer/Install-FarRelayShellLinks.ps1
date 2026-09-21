[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$InstallDirectory
)

$ErrorActionPreference = 'Stop'
$powerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$scriptDir = Join-Path $InstallDirectory 'scripts'
$startMenu = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\FarRelay'
$desktop = [Environment]::GetFolderPath('CommonDesktopDirectory')
New-Item -ItemType Directory -Path $startMenu -Force | Out-Null

$shell = New-Object -ComObject WScript.Shell

function New-FarRelayShortcut {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Arguments,
        [Parameter(Mandatory = $true)][string]$Description
    )
    $shortcut = $shell.CreateShortcut($Path)
    $shortcut.TargetPath = $powerShell
    $shortcut.Arguments = $Arguments
    $shortcut.WorkingDirectory = $InstallDirectory
    $shortcut.Description = $Description
    $shortcut.Save()
}

$control = Join-Path $scriptDir 'Start-FarRelayControlCenter.ps1'
$prepare = Join-Path $scriptDir 'Prepare-FarRelayTravel.ps1'
foreach ($required in @($control,$prepare)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Required FarRelay control script is missing: $required"
    }
}

$controlArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$control`""
$prepareArgs = "-NoProfile -ExecutionPolicy Bypass -NoExit -File `"$prepare`" -Repair"
$readinessArgs = "-NoProfile -ExecutionPolicy Bypass -NoExit -File `"$prepare`""

New-FarRelayShortcut -Path (Join-Path $startMenu 'FarRelay Control Center.lnk') -Arguments $controlArgs -Description 'Open the FarRelay local status and setup dashboard.'
New-FarRelayShortcut -Path (Join-Path $desktop 'FarRelay Control Center.lnk') -Arguments $controlArgs -Description 'Open the FarRelay local status and setup dashboard.'
New-FarRelayShortcut -Path (Join-Path $startMenu 'FarRelay Prepare for Travel.lnk') -Arguments $prepareArgs -Description 'Install and configure missing FarRelay travel prerequisites.'
New-FarRelayShortcut -Path (Join-Path $startMenu 'FarRelay Travel Readiness.lnk') -Arguments $readinessArgs -Description 'Audit FarRelay remote travel readiness without changing the computer.'

Write-Output 'FarRelay Control Center shortcuts installed.'
