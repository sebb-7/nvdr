[CmdletBinding()]
param()

$taskName = 'FarRelay Recover NVDA'
$candidatePaths = @(
    'C:\Program Files\NVDA\nvda_uiAccess.exe',
    'C:\Program Files (x86)\NVDA\nvda_uiAccess.exe'
)
$nvdaPath = $candidatePaths | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1

if (-not $nvdaPath) {
    throw 'NVDA UIAccess executable was not found in the supported installation locations.'
}

# This task is deliberately fixed and runs only in the current user's
# interactive session. It starts NVDA's UIAccess executable directly (no
# pre-kill and no nvda.exe launcher), stores no password, and accepts no
# remote parameters.
$action = New-ScheduledTaskAction -Execute $nvdaPath
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable
Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Force | Out-Null
Write-Output "Configured fixed recovery task: $taskName"
