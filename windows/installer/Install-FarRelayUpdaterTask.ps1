[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$InstallDirectory
)

$taskName = 'FarRelay Update Check'
$updater = Join-Path -Path $InstallDirectory -ChildPath 'farrelay-updater.exe'
if (-not (Test-Path -LiteralPath $updater -PathType Leaf)) {
    throw "FarRelay updater was not found at $updater"
}

# This is a fixed, machine-owned action. The scheduled task does not accept
# remote input, does not persist credentials, and the updater itself accepts
# only a signed-by-hash release archive from the configured GitHub path.
$action = New-ScheduledTaskAction -Execute $updater -Argument '--check-and-install'
$trigger = New-ScheduledTaskTrigger -Daily -At 3:17am
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
Write-Output "Configured fixed daily update task: $taskName"
