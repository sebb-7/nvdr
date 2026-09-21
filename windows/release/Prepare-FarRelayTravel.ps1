[CmdletBinding()]
param(
    [switch]$Repair,
    [switch]$RequireLidClosedReady,
    [string]$OutputPath = "$env:ProgramData\FarRelay\travel-connection.txt"
)

$ErrorActionPreference = 'Stop'
$results = [System.Collections.Generic.List[string]]::new()
$actions = [System.Collections.Generic.List[string]]::new()

function Add-Result([string]$Message) {
    $results.Add($Message)
    Write-Output $Message
}

function Add-Action([string]$Message) {
    $actions.Add($Message)
    Write-Output "ACTION: $Message"
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Resolve-Tailscale {
    $command = Get-Command tailscale.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }
    $candidate = 'C:\Program Files\Tailscale\tailscale.exe'
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    return $null
}

function Ensure-OpenSsh {
    $capabilityName = 'OpenSSH.Server~~~~0.0.1.0'
    $capability = Get-WindowsCapability -Online -Name $capabilityName -ErrorAction Stop
    if ($capability.State -ne 'Installed') {
        if (-not $Repair) {
            Add-Action 'OpenSSH Server is not installed. Rerun this tool as Administrator with -Repair.'
            return
        }
        Add-Result 'Installing OpenSSH Server...'
        Add-WindowsCapability -Online -Name $capabilityName | Out-Null
    }

    $service = Get-Service -Name sshd -ErrorAction SilentlyContinue
    if (-not $service) {
        Add-Action 'OpenSSH Server was installed but the sshd service is unavailable. Restart Windows and rerun the readiness check.'
        return
    }

    if ($Repair) {
        Set-Service -Name sshd -StartupType Automatic
        if ($service.Status -ne 'Running') { Start-Service sshd }
        if (-not (Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
        } else {
            Enable-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' | Out-Null
        }
        $service = Get-Service -Name sshd
    }

    $startMode = (Get-CimInstance Win32_Service -Filter "Name='sshd'").StartMode
    Add-Result "OpenSSH Server: installed; service=$($service.Status); startup=$startMode"
    if ($service.Status -ne 'Running') { Add-Action 'Start the sshd service.' }
    if ($startMode -ne 'Auto') { Add-Action 'Set sshd to Automatic startup.' }

    $listener = Get-NetTCPConnection -State Listen -LocalPort 22 -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($listener) { Add-Result 'SSH port 22: listening' }
    else { Add-Action 'SSH port 22 is not listening.' }
}

function Ensure-Tailscale {
    $tailscale = Resolve-Tailscale

    if (-not $tailscale -and $Repair) {
        $winget = Get-Command winget.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($winget) {
            Add-Result 'Installing Tailscale with Windows Package Manager...'
            & $winget.Source install --id Tailscale.Tailscale --exact --silent --accept-package-agreements --accept-source-agreements
            if ($LASTEXITCODE -ne 0) {
                Add-Action 'Automatic Tailscale installation failed. Install Tailscale from https://tailscale.com/download/windows and rerun this tool.'
            }
            Start-Sleep -Seconds 2
            $tailscale = Resolve-Tailscale
        } else {
            Add-Action 'Tailscale is not installed and Windows Package Manager is unavailable. Install it from https://tailscale.com/download/windows.'
        }
    }

    if (-not $tailscale) {
        Add-Action 'Tailscale is not installed. Rerun with -Repair or install it from https://tailscale.com/download/windows.'
        return $null
    }

    Add-Result "Tailscale CLI: $tailscale"

    $service = Get-Service -Name Tailscale -ErrorAction SilentlyContinue
    if ($service) {
        if ($Repair -and $service.Status -ne 'Running') {
            Start-Service -Name Tailscale
            $service = Get-Service -Name Tailscale
        }
        Add-Result "Tailscale service: $($service.Status)"
    } else {
        Add-Action 'The Tailscale Windows service was not found.'
    }

    if ($Repair) {
        $policy = 'HKLM:\SOFTWARE\Policies\Tailscale'
        New-Item -Path $policy -Force | Out-Null
        New-ItemProperty -Path $policy -Name UnattendedMode -PropertyType String -Value 'always' -Force | Out-Null
        Add-Result 'Tailscale unattended-mode policy: always'
    } else {
        $policyValue = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Tailscale' -Name UnattendedMode -ErrorAction SilentlyContinue).UnattendedMode
        if ($policyValue -eq 'always') { Add-Result 'Tailscale unattended-mode policy: always' }
        else { Add-Action 'Tailscale unattended mode is not enforced. Rerun as Administrator with -Repair before travel.' }
    }

    $ip = (& $tailscale ip -4 2>$null | Select-Object -First 1)
    if ($LASTEXITCODE -eq 0 -and $ip -match '^100\.\d{1,3}\.\d{1,3}\.\d{1,3}$') {
        Add-Result "Tailscale IPv4: $ip"
        return $ip.Trim()
    }

    Add-Action 'Tailscale is installed but this PC is not signed in to a tailnet. Open Tailscale, sign in once, then rerun this tool.'
    return $null
}

function Test-FarRelay {
    $host = Get-Command farrelay-host.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $host) {
        Add-Action 'farrelay-host.exe is not available on PATH.'
        return
    }
    Add-Result "FarRelay Host: $($host.Source)"

    $task = Get-ScheduledTask -TaskName 'FarRelay Recover NVDA' -ErrorAction SilentlyContinue
    if ($task) { Add-Result 'NVDA recovery task: ready' }
    else { Add-Action 'FarRelay Recover NVDA task is missing.' }

    $updateTask = Get-ScheduledTask -TaskName 'FarRelay Update Check' -ErrorAction SilentlyContinue
    if ($updateTask) {
        $info = Get-ScheduledTaskInfo -TaskName 'FarRelay Update Check'
        Add-Result "FarRelay updater task: ready; last result=$($info.LastTaskResult)"
    } else {
        Add-Action 'FarRelay Update Check task is missing.'
    }
}

function Get-AcPowerIndex([string]$Subgroup, [string]$Setting) {
    $output = & powercfg.exe /query SCHEME_CURRENT $Subgroup $Setting 2>&1
    $match = $output | Select-String -Pattern 'Current AC Power Setting Index:\s+0x([0-9a-fA-F]+)' | Select-Object -First 1
    if (-not $match) { return $null }
    return [Convert]::ToInt32($match.Matches[0].Groups[1].Value, 16)
}

function Ensure-PowerReadiness {
    if ($Repair) {
        & powercfg.exe /change standby-timeout-ac 0 | Out-Null
        & powercfg.exe /change hibernate-timeout-ac 0 | Out-Null
    }

    $sleep = Get-AcPowerIndex 'SUB_SLEEP' 'STANDBYIDLE'
    $hibernate = Get-AcPowerIndex 'SUB_SLEEP' 'HIBERNATEIDLE'
    if ($sleep -eq 0) { Add-Result 'AC sleep: Never' } else { Add-Action 'Set AC sleep to Never.' }
    if ($hibernate -eq 0) { Add-Result 'AC hibernate: Never' } else { Add-Action 'Set AC hibernate to Never.' }

    $lid = Get-AcPowerIndex 'SUB_BUTTONS' 'LIDACTION'
    if ($null -eq $lid) {
        $lid = Get-AcPowerIndex '4f971e89-eebd-4455-a8de-9e59040e7347' '5ca83367-6e45-459f-a27b-476b1d01c936'
    }
    if ($null -eq $lid) {
        Add-Action 'Could not determine the AC lid-close action.'
    } elseif ($lid -eq 0) {
        Add-Result 'AC lid close: Do nothing'
    } elseif ($RequireLidClosedReady) {
        Add-Action 'Set AC lid-close action to Do nothing before leaving the laptop closed.'
    } else {
        Add-Result 'AC lid close is not Do nothing; leave the lid open while unattended.'
    }
}

if ($Repair -and -not (Test-IsAdministrator)) {
    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-NoExit',
        '-File', ('"' + $PSCommandPath + '"'),
        '-Repair'
    )
    if ($RequireLidClosedReady) { $arguments += '-RequireLidClosedReady' }
    Start-Process powershell.exe -Verb RunAs -ArgumentList $arguments
    exit 0
}

Write-Output 'FarRelay Prepare for Travel'
Write-Output '==========================='
Write-Output "Computer: $env:COMPUTERNAME"
Write-Output "Windows user: $env:USERNAME"
Write-Output "Mode: $(if ($Repair) { 'Repair and verify' } else { 'Audit only' })"
Write-Output ''

Ensure-OpenSsh
$tailscaleIp = Ensure-Tailscale
Test-FarRelay
Ensure-PowerReadiness

$connection = [System.Collections.Generic.List[string]]::new()
$connection.Add('FarRelay connection card')
$connection.Add('========================')
$connection.Add("Computer: $env:COMPUTERNAME")
$connection.Add("Windows user: $env:USERNAME")
if ($tailscaleIp) {
    $connection.Add("Tailscale IPv4: $tailscaleIp")
    $connection.Add("SSH: ssh $env:USERNAME@$tailscaleIp")
    $connection.Add("FarRelay host test: ssh $env:USERNAME@$tailscaleIp farrelay-host")
    $connection.Add('')
    $connection.Add('From iPhone/iPad:')
    $connection.Add('1. Install Tailscale and sign in to the same tailnet.')
    $connection.Add("2. In FarRelay, create/select this Windows computer using host $tailscaleIp and Windows user $env:USERNAME.")
    $connection.Add('3. Keep OpenSSH and Tailscale enabled; FarRelay host components start on demand over SSH.')
} else {
    $connection.Add('Tailscale IPv4: pending sign-in')
    $connection.Add('Next step: sign in to Tailscale on this PC, then rerun FarRelay Prepare for Travel.')
}

$connection.Add('')
if ($actions.Count -eq 0) {
    $connection.Add('READINESS: READY FOR REMOTE TRAVEL')
} else {
    $connection.Add("READINESS: $($actions.Count) ACTION(S) REQUIRED")
    foreach ($action in $actions) { $connection.Add("- $action") }
}

$directory = Split-Path -Parent $OutputPath
if ($directory) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
$connection | Set-Content -LiteralPath $OutputPath -Encoding UTF8

Write-Output ''
$connection
Write-Output ''
Write-Output "Saved connection card: $OutputPath"

if ($actions.Count -gt 0) { exit 2 }
exit 0
