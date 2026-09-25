Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-FarRelaySetupStatus {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$State,
        [Parameter(Mandatory)][string]$Step,
        [Parameter(Mandatory)][string]$Message,
        [hashtable]$Data
    )
    $directory = Split-Path -Parent $Path
    if ($directory) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    $payload = [ordered]@{
        schema_version = 1
        state = $State
        step = $Step
        message = $Message
        updated_at = (Get-Date).ToUniversalTime().ToString('o')
        data = if ($Data) { $Data } else { @{} }
    }
    $temp = "$Path.tmp"
    $payload | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $temp -Encoding UTF8
    Move-Item -LiteralPath $temp -Destination $Path -Force
}

function Test-FarRelayIsElevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Resolve-FarRelayOpenSshTool {
    param([Parameter(Mandatory)][ValidateSet('ssh','ssh-keygen')][string]$Name)
    $command = Get-Command "$Name.exe" -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }
    $candidate = Join-Path $env:WINDIR "System32\OpenSSH\$Name.exe"
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    return $null
}

function Resolve-FarRelayTailscale {
    $command = Get-Command tailscale.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }
    $candidate = 'C:\Program Files\Tailscale\tailscale.exe'
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    return $null
}

function Get-FarRelayPublicKeyCore {
    param([Parameter(Mandatory)][string]$Line)
    $parts = @($Line.Trim() -split '\s+')
    if ($parts.Count -lt 2) { return '' }
    return "$($parts[0]) $($parts[1])"
}

function Ensure-FarRelayOpenSshServer {
    if (-not (Test-FarRelayIsElevated)) {
        throw 'Administrator approval is required to configure Windows OpenSSH.'
    }

    $capabilityName = 'OpenSSH.Server~~~~0.0.1.0'
    $capability = Get-WindowsCapability -Online -Name $capabilityName -ErrorAction Stop
    if ($capability.State -ne 'Installed') {
        Add-WindowsCapability -Online -Name $capabilityName | Out-Null
    }

    $service = Get-Service -Name sshd -ErrorAction Stop
    Set-Service -Name sshd -StartupType Automatic
    if ($service.Status -ne 'Running') { Start-Service -Name sshd }

    $rule = Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue
    if ($rule) {
        Enable-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' | Out-Null
    } else {
        New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
    }

    $listener = Get-NetTCPConnection -State Listen -LocalPort 22 -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $listener) {
        Restart-Service -Name sshd
        Start-Sleep -Milliseconds 500
        $listener = Get-NetTCPConnection -State Listen -LocalPort 22 -ErrorAction SilentlyContinue | Select-Object -First 1
    }
    if (-not $listener) { throw 'OpenSSH was configured but port 22 is not listening.' }
}

function Ensure-FarRelayTailscale {
    param([switch]$TravelMode)

    if (-not (Test-FarRelayIsElevated)) {
        throw 'Administrator approval is required to configure Tailscale.'
    }

    $tailscale = Resolve-FarRelayTailscale
    if (-not $tailscale) {
        $winget = Get-Command winget.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $winget) {
            throw 'Tailscale is not installed and Windows Package Manager is unavailable.'
        }
        & $winget.Source install --id Tailscale.Tailscale --exact --silent --accept-package-agreements --accept-source-agreements
        if ($LASTEXITCODE -ne 0) { throw "Tailscale installation failed with exit code $LASTEXITCODE." }
        Start-Sleep -Seconds 2
        $tailscale = Resolve-FarRelayTailscale
    }
    if (-not $tailscale) { throw 'Tailscale installation completed but tailscale.exe could not be found.' }

    $service = Get-Service -Name Tailscale -ErrorAction SilentlyContinue
    if ($service -and $service.Status -ne 'Running') { Start-Service -Name Tailscale }

    if ($TravelMode) {
        $policy = 'HKLM:\SOFTWARE\Policies\Tailscale'
        New-Item -Path $policy -Force | Out-Null
        New-ItemProperty -Path $policy -Name UnattendedMode -PropertyType String -Value 'always' -Force | Out-Null
    }

    $ip = $null
    try {
        $candidate = (& $tailscale ip -4 2>$null | Select-Object -First 1)
        if ($LASTEXITCODE -eq 0 -and $candidate -match '^100\.\d{1,3}\.\d{1,3}\.\d{1,3}$') {
            $ip = $candidate.Trim()
        }
    } catch {}
    return [pscustomobject]@{ Path = $tailscale; Ip = $ip; SignedIn = [bool]$ip }
}

function Ensure-FarRelayNvdaRecovery {
    $script = Join-Path $PSScriptRoot 'Install-FarRelayNvdaRecoveryTask.ps1'
    if (-not (Test-Path -LiteralPath $script -PathType Leaf)) {
        throw "NVDA recovery installer is missing: $script"
    }
    & $script -AllowMissingNvda
}

function Test-FarRelayUsesSharedAdministratorKeys {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $isAdminMember = @($identity.Groups | ForEach-Object { $_.Value }) -contains 'S-1-5-32-544'
    if (-not $isAdminMember) { return $false }

    $configPath = Join-Path $env:ProgramData 'ssh\sshd_config'
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { return $false }
    $text = Get-Content -LiteralPath $configPath -Raw
    return [regex]::IsMatch(
        $text,
        '(?ims)^\s*Match\s+Group\s+administrators\s*$.*?^\s*AuthorizedKeysFile\s+__PROGRAMDATA__/ssh/administrators_authorized_keys\s*$'
    )
}

function Add-FarRelayAuthorizedKey {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$PublicLine,
        [switch]$AdministratorFile
    )
    $directory = Split-Path -Parent $Path
    if ($directory) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }

    $publicCore = Get-FarRelayPublicKeyCore $PublicLine
    if (-not $publicCore) { throw 'The generated SSH public key is invalid.' }

    $existing = @()
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $existing = @(Get-Content -LiteralPath $Path -ErrorAction Stop)
    }
    $present = $existing | Where-Object { (Get-FarRelayPublicKeyCore $_) -eq $publicCore } | Select-Object -First 1
    if (-not $present) {
        Add-Content -LiteralPath $Path -Value $PublicLine -Encoding ascii
    }

    if ($AdministratorFile) {
        & icacls.exe $Path /inheritance:r | Out-Null
        & icacls.exe $Path /grant:r '*S-1-5-18:F' '*S-1-5-32-544:F' | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw 'Windows could not set the required permissions on administrators_authorized_keys.'
        }
    }
}

function New-FarRelayVerifiedSshKey {
    $sshKeygen = Resolve-FarRelayOpenSshTool -Name 'ssh-keygen'
    if (-not $sshKeygen) { throw 'ssh-keygen.exe is unavailable after OpenSSH setup.' }

    $directory = Join-Path $env:LOCALAPPDATA 'FarRelay\ssh'
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $base = Join-Path $directory 'farrelay_iphone_ed25519'

    for ($index = 1; $index -le 50; $index++) {
        $privatePath = if ($index -eq 1) { $base } else { "$base-$index" }
        $publicPath = "$privatePath.pub"

        if (Test-Path -LiteralPath $privatePath -PathType Leaf) {
            $derived = (& $sshKeygen -y -f $privatePath 2>$null | Select-Object -First 1)
            if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($derived)) { continue }
            $derivedCore = Get-FarRelayPublicKeyCore $derived
            if (-not $derivedCore) { continue }

            if (Test-Path -LiteralPath $publicPath -PathType Leaf) {
                $stored = (Get-Content -LiteralPath $publicPath -Raw).Trim()
                if ((Get-FarRelayPublicKeyCore $stored) -ne $derivedCore) {
                    continue
                }
                return [pscustomobject]@{
                    PrivatePath = $privatePath
                    PublicPath = $publicPath
                    PublicLine = $stored
                    Reused = $true
                }
            }

            $publicLine = "$derivedCore farrelay-iphone@$env:COMPUTERNAME"
            Set-Content -LiteralPath $publicPath -Value $publicLine -Encoding ascii
            return [pscustomobject]@{
                PrivatePath = $privatePath
                PublicPath = $publicPath
                PublicLine = $publicLine
                Reused = $true
            }
        }

        if (Test-Path -LiteralPath $publicPath -PathType Leaf) { continue }

        $comment = "farrelay-iphone@$env:COMPUTERNAME"
        & $sshKeygen -q -t ed25519 -N '' -C $comment -f $privatePath
        if ($LASTEXITCODE -ne 0) { throw 'Windows OpenSSH could not generate the FarRelay SSH key.' }

        $stored = (Get-Content -LiteralPath $publicPath -Raw).Trim()
        $derived = (& $sshKeygen -y -f $privatePath 2>$null | Select-Object -First 1)
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($derived)) {
            throw 'FarRelay generated an SSH private key but could not derive its public key.'
        }
        if ((Get-FarRelayPublicKeyCore $stored) -ne (Get-FarRelayPublicKeyCore $derived)) {
            throw 'FarRelay generated an SSH keypair that failed its own public/private consistency check.'
        }

        return [pscustomobject]@{
            PrivatePath = $privatePath
            PublicPath = $publicPath
            PublicLine = $stored
            Reused = $false
        }
    }

    throw 'FarRelay could not find a safe verified SSH key path. Existing mismatched key files were left untouched.'
}

function Install-FarRelayVerifiedSshKey {
    if (-not (Test-FarRelayIsElevated)) {
        throw 'Administrator approval is required to authorize the FarRelay SSH key.'
    }

    $key = New-FarRelayVerifiedSshKey
    if (Test-FarRelayUsesSharedAdministratorKeys) {
        $target = Join-Path $env:ProgramData 'ssh\administrators_authorized_keys'
        Add-FarRelayAuthorizedKey -Path $target -PublicLine $key.PublicLine -AdministratorFile
    } else {
        $target = Join-Path $env:USERPROFILE '.ssh\authorized_keys'
        Add-FarRelayAuthorizedKey -Path $target -PublicLine $key.PublicLine
    }

    return [pscustomobject]@{
        PrivatePath = $key.PrivatePath
        PublicPath = $key.PublicPath
        AuthorizedKeysPath = $target
        Reused = $key.Reused
    }
}

function Test-FarRelayLocalSshAuthentication {
    param([Parameter(Mandatory)][string]$PrivateKeyPath)

    $ssh = Resolve-FarRelayOpenSshTool -Name 'ssh'
    if (-not $ssh) { throw 'ssh.exe is unavailable after OpenSSH setup.' }
    if (-not (Test-Path -LiteralPath $PrivateKeyPath -PathType Leaf)) { throw 'FarRelay private key is missing.' }

    $arguments = @(
        '-i', $PrivateKeyPath,
        '-p', '22',
        '-o', 'BatchMode=yes',
        '-o', 'PasswordAuthentication=no',
        '-o', 'KbdInteractiveAuthentication=no',
        '-o', 'StrictHostKeyChecking=no',
        '-o', 'UserKnownHostsFile=NUL',
        '-o', 'ConnectTimeout=5',
        "$env:USERNAME@127.0.0.1",
        'echo FARRELAY_SSH_OK'
    )
    $output = & $ssh @arguments 2>&1
    $exitCode = $LASTEXITCODE
    $text = ($output | Out-String).Trim()
    if ($exitCode -ne 0 -or $text -notmatch 'FARRELAY_SSH_OK') {
        throw "FarRelay SSH verification failed. The generated key was not accepted by localhost OpenSSH. $text"
    }
    return $true
}

function Set-FarRelayTravelPowerPolicy {
    if (-not (Test-FarRelayIsElevated)) { throw 'Administrator approval is required to configure travel power settings.' }
    & powercfg.exe /change standby-timeout-ac 0 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not set AC sleep timeout to Never.' }
    & powercfg.exe /change hibernate-timeout-ac 0 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not set AC hibernate timeout to Never.' }
}

function Get-FarRelaySetupSnapshot {
    $configPath = Join-Path $env:ProgramData 'FarRelay\install.json'
    $credentialPath = Join-Path $env:ProgramData 'FarRelay\device.credential'
    $installDir = Split-Path -Parent $PSScriptRoot
    $sshd = Get-Service -Name sshd -ErrorAction SilentlyContinue
    $tailscale = Resolve-FarRelayTailscale
    $tailscaleIp = $null
    if ($tailscale) {
        try {
            $candidate = (& $tailscale ip -4 2>$null | Select-Object -First 1)
            if ($LASTEXITCODE -eq 0 -and $candidate -match '^100\.') { $tailscaleIp = $candidate.Trim() }
        } catch {}
    }
    $nvda = @(
        'C:\Program Files\NVDA\nvda.exe',
        'C:\Program Files (x86)\NVDA\nvda.exe'
    ) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1

    [ordered]@{
        Installed = Test-Path -LiteralPath (Join-Path $installDir 'farrelay.exe') -PathType Leaf
        Activated = (Test-Path -LiteralPath $configPath -PathType Leaf) -and (Test-Path -LiteralPath $credentialPath -PathType Leaf)
        OpenSshInstalled = $null -ne $sshd
        OpenSshRunning = [bool]($sshd -and $sshd.Status -eq 'Running')
        TailscaleInstalled = [bool]$tailscale
        TailscaleIp = $tailscaleIp
        NvdaInstalled = [bool]$nvda
        RecoveryTaskReady = $null -ne (Get-ScheduledTask -TaskName 'FarRelay Recover NVDA' -ErrorAction SilentlyContinue)
        ComputerName = $env:COMPUTERNAME
        UserName = $env:USERNAME
    }
}

function Invoke-FarRelaySetup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Recommended','Travel','Custom')][string]$Mode,
        [Parameter(Mandatory)][string]$StatusPath,
        [switch]$SkipOpenSsh,
        [switch]$SkipTailscale,
        [switch]$SkipNvda,
        [switch]$SkipSshKey,
        [switch]$EnableTravelHardening
    )

    if (-not (Test-FarRelayIsElevated)) {
        throw 'The setup worker must run with administrator approval.'
    }

    $result = [ordered]@{
        mode = $Mode
        ssh_private_key_path = $null
        tailscale_ip = $null
        warnings = @()
    }

    try {
        Write-FarRelaySetupStatus -Path $StatusPath -State running -Step Starting -Message 'Starting FarRelay setup.' -Data @{}

        if (-not $SkipOpenSsh) {
            Write-FarRelaySetupStatus -Path $StatusPath -State running -Step OpenSSH -Message 'Installing and validating Windows OpenSSH.' -Data $result
            Ensure-FarRelayOpenSshServer
        }

        if (-not $SkipTailscale) {
            Write-FarRelaySetupStatus -Path $StatusPath -State running -Step Tailscale -Message 'Installing and validating Tailscale.' -Data $result
            $tail = Ensure-FarRelayTailscale -TravelMode:($Mode -eq 'Travel' -or $EnableTravelHardening)
            $result.tailscale_ip = $tail.Ip
            if (-not $tail.SignedIn) {
                $result.warnings += 'Tailscale is installed but not signed in. Sign in once, then rerun verification.'
            }
        }

        if (-not $SkipNvda) {
            Write-FarRelaySetupStatus -Path $StatusPath -State running -Step NVDA -Message 'Configuring NVDA recovery.' -Data $result
            Ensure-FarRelayNvdaRecovery
        }

        if (-not $SkipSshKey) {
            Write-FarRelaySetupStatus -Path $StatusPath -State running -Step SSHKey -Message 'Creating and authorizing a verified FarRelay SSH key.' -Data $result
            $key = Install-FarRelayVerifiedSshKey
            $result.ssh_private_key_path = $key.PrivatePath

            Write-FarRelaySetupStatus -Path $StatusPath -State running -Step SSHVerify -Message 'Testing the generated key with a real localhost SSH login.' -Data $result
            [void](Test-FarRelayLocalSshAuthentication -PrivateKeyPath $key.PrivatePath)
        }

        if ($Mode -eq 'Travel' -or $EnableTravelHardening) {
            Write-FarRelaySetupStatus -Path $StatusPath -State running -Step Travel -Message 'Applying unattended travel power settings.' -Data $result
            Set-FarRelayTravelPowerPolicy
        }

        Write-FarRelaySetupStatus -Path $StatusPath -State ready -Step Complete -Message 'FarRelay setup completed and SSH authentication was verified.' -Data $result
        return [pscustomobject]$result
    } catch {
        $result.error = $_.Exception.Message
        Write-FarRelaySetupStatus -Path $StatusPath -State failed -Step Failed -Message $_.Exception.Message -Data $result
        throw
    }
}

Export-ModuleMember -Function @(
    'Get-FarRelaySetupSnapshot',
    'Invoke-FarRelaySetup',
    'Test-FarRelayLocalSshAuthentication',
    'Install-FarRelayVerifiedSshKey'
)
