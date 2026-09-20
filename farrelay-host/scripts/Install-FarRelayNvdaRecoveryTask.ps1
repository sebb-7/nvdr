[CmdletBinding()]
param()

$taskName = 'FarRelay Recover NVDA'
$nvdaPath = 'C:\Program Files\NVDA\nvda.exe'

if (-not (Test-Path -LiteralPath $nvdaPath -PathType Leaf)) {
    throw "NVDA was not found at the required recovery path: $nvdaPath"
}

# This task is deliberately fixed and runs only in the current user's
# interactive session. It stores no password and accepts no remote parameters.
$action = New-ScheduledTaskAction -Execute $nvdaPath
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable
Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Force | Out-Null
Write-Output "Configured fixed recovery task: $taskName"
