[CmdletBinding()]
param(
    [switch]$AllowMissingNvda
)

$taskName = 'FarRelay Recover NVDA'
$candidatePaths = @(
    'C:\Program Files\NVDA\nvda_slave.exe',
    'C:\Program Files (x86)\NVDA\nvda_slave.exe'
)
$nvdaLauncherPath = $candidatePaths | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1

if (-not $nvdaLauncherPath) {
    if ($AllowMissingNvda) {
        Write-Warning 'NVDA launcher helper was not found; FarRelay was installed but NVDA recovery was not provisioned.'
        return
    }
    throw 'NVDA launcher helper was not found in the supported installation locations.'
}

# This task is deliberately fixed and runs only in the current user's
# interactive session. NVDA's signed slave helper uses ShellExecute to launch
# the installed nvda.exe, which is the same path NVDA uses for its own launch
# helper. The remote caller cannot select an executable or arguments.
$action = New-ScheduledTaskAction -Execute $nvdaLauncherPath -Argument 'launchNVDA'
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable
Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Force | Out-Null
Write-Output "Configured fixed recovery task: $taskName"
