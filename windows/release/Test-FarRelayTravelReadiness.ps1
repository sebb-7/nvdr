[CmdletBinding()]
param(
    [int]$SshPort = 22,
    [switch]$StaticOnly,
    [switch]$RequireLidClosedReady
)

$ErrorActionPreference = 'Stop'
$failures = [System.Collections.Generic.List[string]]::new()
$warnings = [System.Collections.Generic.List[string]]::new()

function Pass([string]$Message) { Write-Host "PASS: $Message" }
function Fail([string]$Message) { $script:failures.Add($Message); Write-Host "FAIL: $Message" }
function Warn([string]$Message) { $script:warnings.Add($Message); Write-Host "WARN: $Message" }

$repoVersionPath = Join-Path (Join-Path $PSScriptRoot '..\..') 'VERSION'
$installedConfigPath = Join-Path $env:ProgramData 'FarRelay\install.json'
if (Test-Path -LiteralPath $repoVersionPath -PathType Leaf) {
    $expectedVersion = (Get-Content $repoVersionPath -Raw).Trim()
} elseif (Test-Path -LiteralPath $installedConfigPath -PathType Leaf) {
    try {
        $expectedVersion = (Get-Content $installedConfigPath -Raw | ConvertFrom-Json).installed_version
    } catch {
        throw "Could not read installed FarRelay version from $installedConfigPath. $($_.Exception.Message)"
    }
} else {
    throw "Could not determine the expected FarRelay version from the repository or installed configuration."
}
if ([string]::IsNullOrWhiteSpace($expectedVersion)) {
    throw "Expected FarRelay version is empty."
}

function Resolve-Tailscale {
    $command = Get-Command tailscale.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }
    $candidate = 'C:\Program Files\Tailscale\tailscale.exe'
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    return $null
}

function Test-CommandInvariant {
    param(
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [string]$ExpectedPrefix
    )

    $commands = @(Get-Command "$Name.exe" -CommandType Application -All -ErrorAction SilentlyContinue)
    if ($commands.Count -eq 0) {
        Fail "$Name is not available on PATH."
        return $null
    }

    if ($commands.Count -gt 1) {
        $paths = ($commands | ForEach-Object Source) -join '; '
        Fail "$Name has multiple PATH-visible copies: $paths"
    }

    $resolved = $commands[0].Source
    try {
        $reported = (& $resolved --version | Out-String).Trim()
    } catch {
        Fail "$Name could not report its version from $resolved. $($_.Exception.Message)"
        return $resolved
    }

    $expected = "$ExpectedPrefix $expectedVersion"
    if ($reported -ne $expected) {
        Fail "$Name resolved to $resolved and reported '$reported'; expected '$expected'."
    } else {
        Pass "$Name resolves unambiguously to $resolved and reports $expectedVersion."
    }
    return $resolved
}

$farrelayPath = Test-CommandInvariant -Name 'farrelay' -ExpectedPrefix 'farrelay'
$hostPath = Test-CommandInvariant -Name 'farrelay-host' -ExpectedPrefix 'farrelay-host'

if ($StaticOnly) {
    if ($failures.Count -gt 0) {
        throw "FarRelay static readiness failed: $($failures -join ' | ')"
    }
    Pass "Static FarRelay readiness checks passed."
    exit 0
}

try {
    $sshd = Get-CimInstance Win32_Service -Filter "Name='sshd'"
    if ($null -eq $sshd) {
        Fail "OpenSSH Server service (sshd) is not installed."
    } else {
        if ($sshd.State -ne 'Running') { Fail "sshd is $($sshd.State), not Running." }
        else { Pass "sshd is running." }

        if ($sshd.StartMode -ne 'Auto') { Fail "sshd start mode is $($sshd.StartMode), not Automatic." }
        else { Pass "sshd is configured to start automatically." }
    }
} catch {
    Fail "Could not inspect sshd. $($_.Exception.Message)"
}

try {
    $listener = Get-NetTCPConnection -State Listen -LocalPort $SshPort -ErrorAction Stop | Select-Object -First 1
    if ($null -eq $listener) { Fail "Nothing is listening on SSH port $SshPort." }
    else { Pass "SSH port $SshPort is listening." }
} catch {
    Fail "Nothing is listening on SSH port $SshPort."
}

try {
    $tailscalePath = Resolve-Tailscale
    if (-not $tailscalePath) {
        Fail "Tailscale CLI is not installed."
    } else {
        $tailscaleService = Get-Service -Name Tailscale -ErrorAction SilentlyContinue
        if (-not $tailscaleService) {
            Fail "Tailscale Windows service is not installed."
        } elseif ($tailscaleService.Status -ne 'Running') {
            Fail "Tailscale service is $($tailscaleService.Status), not Running."
        } else {
            Pass "Tailscale service is running."
        }

        $tailscaleIp = (& $tailscalePath ip -4 2>$null | Select-Object -First 1)
        if ($LASTEXITCODE -eq 0 -and $tailscaleIp -match '^100\.\d{1,3}\.\d{1,3}\.\d{1,3}$') {
            Pass "Tailscale is signed in with IPv4 $($tailscaleIp.Trim())."
        } else {
            Fail "Tailscale is installed but no tailnet IPv4 address is available."
        }
    }
} catch {
    Fail "Could not validate Tailscale readiness. $($_.Exception.Message)"
}

if ($hostPath) {
    try {
        $request = '{"version":1,"request_id":"travel-readiness","operation":"recovery.nvda.status","params":{}}'
        $raw = $request | & $hostPath
        if ($LASTEXITCODE -ne 0) {
            Fail "farrelay-host exited with code $LASTEXITCODE during recovery status."
        } else {
            $response = ($raw | Select-Object -Last 1 | ConvertFrom-Json)
            if (-not $response.ok) {
                Fail "farrelay-host recovery status returned an error."
            } else {
                Pass "farrelay-host recovery protocol is responding."
                if ($response.result.nvda_running) { Pass "NVDA is currently running." }
                else { Warn "NVDA is not currently running; recovery must still be tested before travel." }

                if ($response.result.recovery_task_ready) { Pass "Fixed NVDA recovery task is ready." }
                else { Fail "Fixed NVDA recovery task is not ready." }
            }
        }
    } catch {
        Fail "farrelay-host recovery status failed. $($_.Exception.Message)"
    }
}

if ($hostPath) {
    try {
        $statusRequest = '{"version":1,"request_id":"travel-remsound-status","operation":"remsound.status","params":{}}'
        $statusRaw = $statusRequest | & $hostPath
        if ($LASTEXITCODE -ne 0) {
            Fail "farrelay-host exited with code $LASTEXITCODE during RemSound status."
        } else {
            $statusResponse = ($statusRaw | Select-Object -Last 1 | ConvertFrom-Json)
            if (-not $statusResponse.ok) {
                Fail "farrelay-host RemSound status returned an error."
            } else {
                $remSoundStatus = $statusResponse.result
                if (-not $remSoundStatus.platform_supported) {
                    Fail "RemSound orchestration is not supported on this host."
                } elseif (-not $remSoundStatus.installed) {
                    Fail "RemSound is not installed in a FarRelay-managed or standard location."
                } else {
                    Pass "RemSound is installed."
                    if ($remSoundStatus.manageable) {
                        Pass "RemSound sender is controllable by FarRelay Host."
                    } else {
                        Fail "RemSound is installed but FarRelay Host cannot safely manage it."
                    }
                    if ($remSoundStatus.running) {
                        Pass "RemSound sender is currently running."
                    } else {
                        Warn "RemSound sender is stopped; the session test will request a safe start."
                    }
                }
            }
        }
    } catch {
        Fail "farrelay-host RemSound status failed. $($_.Exception.Message)"
    }

    try {
        $sessionRequest = '{"version":1,"request_id":"travel-remsound-session","operation":"remsound.session","params":{}}'
        $sessionRaw = $sessionRequest | & $hostPath
        if ($LASTEXITCODE -ne 0) {
            Fail "farrelay-host exited with code $LASTEXITCODE during RemSound session negotiation."
        } else {
            $sessionResponse = ($sessionRaw | Select-Object -Last 1 | ConvertFrom-Json)
            if (-not $sessionResponse.ok) {
                Fail "RemSound session negotiation returned an error."
            } else {
                $session = $sessionResponse.result
                $codecs = @($session.codecs)
                $contractReady =
                    $session.transport -eq 'direct_udp' -and
                    [int]$session.audio_port -gt 0 -and
                    [int]$session.discovery_port -gt 0 -and
                    [int]$session.sample_rate_hz -eq 48000 -and
                    [int]$session.channels -eq 2 -and
                    ($codecs -contains 'opus' -or $codecs -contains 'pcm') -and
                    [bool]$session.shared_password_required -and
                    $session.sender_state -in @('running', 'starting')
                if ($contractReady) {
                    Pass "RemSound audio session contract passed: direct UDP, 48 kHz stereo, sender $($session.sender_state)."
                    Warn "Windows readiness cannot prove end-to-end iPhone packet reception; confirm Remote Audio reaches Playing before travel."
                } else {
                    Fail "RemSound session descriptor is incompatible with the FarRelay iOS receiver contract."
                }
            }
        }
    } catch {
        Fail "farrelay-host RemSound session negotiation failed. $($_.Exception.Message)"
    }
}

try {
    $task = Get-ScheduledTask -TaskName 'FarRelay Recover NVDA' -ErrorAction Stop
    $action = @($task.Actions)[0]
    $logonType = [string]$task.Principal.LogonType
    if ($logonType -notin @('Interactive', 'InteractiveToken')) {
        Fail "Recovery task LogonType is $logonType; expected Interactive."
    } else { Pass "Recovery task uses Interactive logon." }

    if ($task.Principal.RunLevel -ne 'Limited') {
        Fail "Recovery task RunLevel is $($task.Principal.RunLevel); expected Limited."
    } else { Pass "Recovery task uses Limited run level." }

    if (-not $action.Execute.EndsWith('nvda_slave.exe', [System.StringComparison]::OrdinalIgnoreCase)) {
        Fail "Recovery task action is not NVDA's signed launcher helper: $($action.Execute)"
    } else { Pass "Recovery task uses NVDA's signed launcher helper." }

    $actionArguments = if ($null -eq $action.Arguments) { '' } else { [string]$action.Arguments }
    if ($actionArguments.Trim() -ne 'launchNVDA') {
        Fail "Recovery task arguments are not the fixed NVDA launch action: $($action.Arguments)"
    } else { Pass "Recovery task arguments are fixed to launchNVDA." }
} catch {
    Fail "Could not validate the fixed NVDA recovery task. $($_.Exception.Message)"
}

function Get-AcPowerIndex {
    param([string]$Subgroup, [string]$Setting)
    $output = & powercfg.exe /query SCHEME_CURRENT $Subgroup $Setting 2>&1
    $match = $output | Select-String -Pattern 'Current AC Power Setting Index:\s+0x([0-9a-fA-F]+)' | Select-Object -First 1
    if (-not $match) { return $null }
    return [Convert]::ToInt32($match.Matches[0].Groups[1].Value, 16)
}

try {
    $sleep = Get-AcPowerIndex -Subgroup 'SUB_SLEEP' -Setting 'STANDBYIDLE'
    if ($null -eq $sleep) { Warn "Could not read AC sleep timeout." }
    elseif ($sleep -ne 0) { Fail "AC sleep timeout is enabled ($sleep seconds). Set it to Never for unattended access." }
    else { Pass "AC sleep timeout is Never." }

    $hibernate = Get-AcPowerIndex -Subgroup 'SUB_SLEEP' -Setting 'HIBERNATEIDLE'
    if ($null -eq $hibernate) { Warn "Could not read AC hibernate timeout." }
    elseif ($hibernate -ne 0) { Fail "AC hibernate timeout is enabled ($hibernate seconds). Set it to Never for unattended access." }
    else { Pass "AC hibernate timeout is Never." }

    $lid = Get-AcPowerIndex -Subgroup 'SUB_BUTTONS' -Setting 'LIDACTION'
    if ($null -eq $lid) {
        $lid = Get-AcPowerIndex -Subgroup '4f971e89-eebd-4455-a8de-9e59040e7347' -Setting '5ca83367-6e45-459f-a27b-476b1d01c936'
    }
    if ($null -eq $lid) {
        Warn "Could not read AC lid-close action."
    } elseif ($lid -ne 0) {
        if ($RequireLidClosedReady) {
            Fail "Closing the lid on AC is not configured to Do nothing (index $lid)."
        } else {
            Warn "Closing the lid on AC may suspend the G14 (index $lid). Leave the lid open or rerun with -RequireLidClosedReady."
        }
    } else {
        Pass "Closing the lid on AC is configured to Do nothing."
    }
} catch {
    Warn "Power policy could not be fully validated. $($_.Exception.Message)"
}

Write-Output ""
Write-Output "FarRelay travel-readiness summary: $($failures.Count) failure(s), $($warnings.Count) warning(s)."
if ($warnings.Count -gt 0) {
    $warnings | ForEach-Object { Write-Output "WARN: $_" }
}
if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Output "FAIL: $_" }
    exit 1
}
Pass "Machine is ready for the automated checks covered by this script."
exit 0
