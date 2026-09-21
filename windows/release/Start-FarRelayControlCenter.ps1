[CmdletBinding()]
param(
    [switch]$InstallAdminAuthorizedKey,
    [string]$PublicKeyPath
)

$ErrorActionPreference = 'Stop'
$installDir = Split-Path -Parent $PSScriptRoot
$prepareScript = Join-Path $PSScriptRoot 'Prepare-FarRelayTravel.ps1'
$configPath = Join-Path $env:ProgramData 'FarRelay\install.json'
$progressPath = Join-Path $env:ProgramData 'FarRelay\travel-progress.json'
$testerProfilePath = Join-Path $env:ProgramData 'FarRelay\tester.json'
$updateStatusPath = Join-Path $env:ProgramData 'FarRelay\update-status.json'

function New-RandomHex([int]$Bytes = 32) {
    $data = New-Object byte[] $Bytes
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($data)
    return (($data | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Resolve-Tailscale {
    $command = Get-Command tailscale.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }
    $candidate = 'C:\Program Files\Tailscale\tailscale.exe'
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    return $null
}

function Test-CurrentUserAdministratorMember {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    return @($identity.Groups | ForEach-Object { $_.Value }) -contains 'S-1-5-32-544'
}

function Test-IsElevatedAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-PublicKeyCore([string]$Line) {
    $parts = @($Line.Trim() -split '\s+')
    if ($parts.Count -lt 2) { return '' }
    return "$($parts[0]) $($parts[1])"
}

function Add-PublicKeyWithoutReplacing([string]$AuthorizedKeysPath, [string]$PublicLine) {
    $directory = Split-Path -Parent $AuthorizedKeysPath
    if ($directory) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }

    $publicCore = Get-PublicKeyCore $PublicLine
    if (-not $publicCore) { throw 'FarRelay generated an invalid SSH public key.' }

    if (Test-Path -LiteralPath $AuthorizedKeysPath -PathType Leaf) {
        $alreadyPresent = Get-Content -LiteralPath $AuthorizedKeysPath -ErrorAction Stop |
            Where-Object { (Get-PublicKeyCore $_) -eq $publicCore } |
            Select-Object -First 1
        if (-not $alreadyPresent) {
            Add-Content -LiteralPath $AuthorizedKeysPath -Value $PublicLine -Encoding ascii
        }
        return $false
    }

    New-Item -ItemType File -Path $AuthorizedKeysPath -Force | Out-Null
    Add-Content -LiteralPath $AuthorizedKeysPath -Value $PublicLine -Encoding ascii
    return $true
}

function Install-FarRelayAdminAuthorizedKey([string]$KeyPath) {
    if (-not (Test-IsElevatedAdministrator)) { throw 'Administrator approval is required to update the shared Windows OpenSSH administrator key file.' }
    if (-not (Test-Path -LiteralPath $KeyPath -PathType Leaf)) { throw 'FarRelay SSH public key file is missing.' }

    $publicLine = (Get-Content -LiteralPath $KeyPath -Raw).Trim()
    $target = Join-Path $env:ProgramData 'ssh\administrators_authorized_keys'
    $created = Add-PublicKeyWithoutReplacing $target $publicLine

    if ($created) {
        & icacls.exe $target /inheritance:r | Out-Null
        & icacls.exe $target /grant:r '*S-1-5-18:F' '*S-1-5-32-544:F' | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Windows could not set the required permissions on administrators_authorized_keys.' }
    }
}

function Test-UsesSharedAdministratorAuthorizedKeys {
    if (-not (Test-CurrentUserAdministratorMember)) { return $false }
    $sshdConfigPath = Join-Path $env:ProgramData 'ssh\sshd_config'
    if (-not (Test-Path -LiteralPath $sshdConfigPath -PathType Leaf)) { return $false }
    try {
        $text = Get-Content -LiteralPath $sshdConfigPath -Raw
        return [regex]::IsMatch(
            $text,
            '(?ims)^\s*Match\s+Group\s+administrators\s*$.*?^\s*AuthorizedKeysFile\s+__PROGRAMDATA__/ssh/administrators_authorized_keys\s*$'
        )
    } catch {
        return $false
    }
}

function Get-OrCreateFarRelayIPhoneKey {
    $sshKeygen = Get-Command ssh-keygen.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $sshKeygen) { throw 'ssh-keygen.exe is unavailable. Run Prepare for Travel first so Windows OpenSSH is installed.' }

    $keyDirectory = Join-Path $env:LOCALAPPDATA 'FarRelay\ssh'
    New-Item -ItemType Directory -Path $keyDirectory -Force | Out-Null
    $base = Join-Path $keyDirectory 'farrelay_iphone_ed25519'

    for ($index = 1; $index -le 20; $index++) {
        $candidate = if ($index -eq 1) { $base } else { "$base-$index" }
        $publicPath = "$candidate.pub"

        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $derived = (& $sshKeygen.Source -y -f $candidate 2>$null | Select-Object -First 1)
            if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($derived)) { continue }

            if (Test-Path -LiteralPath $publicPath -PathType Leaf) {
                $existingPublic = (Get-Content -LiteralPath $publicPath -Raw).Trim()
                if ((Get-PublicKeyCore $existingPublic) -ne (Get-PublicKeyCore $derived)) { continue }
                return [pscustomobject]@{ Private = $candidate; Public = $publicPath; PublicLine = $existingPublic }
            }

            $publicLine = "$($derived.Trim()) farrelay-iphone@$env:COMPUTERNAME"
            Set-Content -LiteralPath $publicPath -Value $publicLine -Encoding ascii
            return [pscustomobject]@{ Private = $candidate; Public = $publicPath; PublicLine = $publicLine }
        }

        if (Test-Path -LiteralPath $publicPath -PathType Leaf) { continue }

        $comment = "farrelay-iphone@$env:COMPUTERNAME"
        & $sshKeygen.Source -q -t ed25519 -N '""' -C $comment -f $candidate
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $candidate -PathType Leaf) -or -not (Test-Path -LiteralPath $publicPath -PathType Leaf)) {
            throw 'Windows OpenSSH could not generate the dedicated FarRelay SSH key.'
        }
        $publicLine = (Get-Content -LiteralPath $publicPath -Raw).Trim()
        return [pscustomobject]@{ Private = $candidate; Public = $publicPath; PublicLine = $publicLine }
    }

    throw 'FarRelay could not find a safe unused path for its dedicated iPhone SSH key. No existing key was changed.'
}

function Prepare-FarRelayIPhoneSshKey {
    $key = Get-OrCreateFarRelayIPhoneKey

    if (Test-UsesSharedAdministratorAuthorizedKeys) {
        if (Test-IsElevatedAdministrator) {
            Install-FarRelayAdminAuthorizedKey $key.Public
        } else {
            $arguments = @(
                '-NoProfile',
                '-ExecutionPolicy', 'Bypass',
                '-File', ('"' + $PSCommandPath + '"'),
                '-InstallAdminAuthorizedKey',
                '-PublicKeyPath', ('"' + $key.Public + '"')
            )
            $process = Start-Process powershell.exe -Verb RunAs -ArgumentList $arguments -Wait -PassThru
            if ($process.ExitCode -ne 0) { throw 'FarRelay could not authorize the SSH key. Administrator approval may have been cancelled.' }
        }
    } else {
        $target = Join-Path $env:USERPROFILE '.ssh\authorized_keys'
        [void](Add-PublicKeyWithoutReplacing $target $key.PublicLine)
    }

    $privateKey = Get-Content -LiteralPath $key.Private -Raw
    Set-Clipboard -Value $privateKey

    return 'FarRelay SSH key ready. The PRIVATE KEY required by the iPhone app is copied to the clipboard. Paste it into FarRelay > Computer > Authentication > Private Key. Do not paste this private key into chat, email, a forum, or feedback. No existing SSH key or authorized_keys entry was removed or overwritten.'
}

function Get-AcPowerIndex([string]$Subgroup, [string]$Setting) {
    try {
        $output = & powercfg.exe /query SCHEME_CURRENT $Subgroup $Setting 2>&1
        $match = $output | Select-String -Pattern 'Current AC Power Setting Index:\s+0x([0-9a-fA-F]+)' | Select-Object -First 1
        if (-not $match) { return $null }
        return [Convert]::ToInt32($match.Matches[0].Groups[1].Value, 16)
    } catch { return $null }
}

function Get-FarRelayStatus {
    $config = $null
    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        try { $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json } catch {}
    }

    $sshd = Get-Service -Name sshd -ErrorAction SilentlyContinue
    $sshdStart = $null
    if ($sshd) {
        try { $sshdStart = (Get-CimInstance Win32_Service -Filter "Name='sshd'").StartMode } catch {}
    }

    $sshListening = $false
    try { $sshListening = $null -ne (Get-NetTCPConnection -State Listen -LocalPort 22 -ErrorAction Stop | Select-Object -First 1) } catch {}

    $tailscale = Resolve-Tailscale
    $tailscaleService = Get-Service -Name Tailscale -ErrorAction SilentlyContinue
    $tailscaleIp = $null
    if ($tailscale) {
        try {
            $candidate = (& $tailscale ip -4 2>$null | Select-Object -First 1)
            if ($LASTEXITCODE -eq 0 -and $candidate -match '^100\.\d{1,3}\.\d{1,3}\.\d{1,3}$') {
                $tailscaleIp = $candidate.Trim()
            }
        } catch {}
    }

    $unattended = $false
    try {
        $unattended = ((Get-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Tailscale' -Name UnattendedMode -ErrorAction Stop).UnattendedMode -eq 'always')
    } catch {}

    $recoveryTask = Get-ScheduledTask -TaskName 'FarRelay Recover NVDA' -ErrorAction SilentlyContinue
    $updateTask = Get-ScheduledTask -TaskName 'FarRelay Update Check' -ErrorAction SilentlyContinue
    $updateInfo = $null
    if ($updateTask) {
        try { $updateInfo = Get-ScheduledTaskInfo -TaskName 'FarRelay Update Check' } catch {}
    }

    $hostReady = Test-Path -LiteralPath (Join-Path $installDir 'farrelay-host.exe') -PathType Leaf
    $nvdaRunning = $null -ne (Get-Process -Name nvda -ErrorAction SilentlyContinue | Select-Object -First 1)

    $sleep = Get-AcPowerIndex 'SUB_SLEEP' 'STANDBYIDLE'
    $hibernate = Get-AcPowerIndex 'SUB_SLEEP' 'HIBERNATEIDLE'
    $lid = Get-AcPowerIndex 'SUB_BUTTONS' 'LIDACTION'
    if ($null -eq $lid) {
        $lid = Get-AcPowerIndex '4f971e89-eebd-4455-a8de-9e59040e7347' '5ca83367-6e45-459f-a27b-476b1d01c936'
    }

    $sshReady = [bool]($sshd -and $sshd.Status -eq 'Running' -and $sshdStart -eq 'Auto' -and $sshListening)
    $tailscaleReady = [bool]($tailscale -and $tailscaleService -and $tailscaleService.Status -eq 'Running' -and $tailscaleIp -and $unattended)
    $farRelayReady = [bool]($hostReady -and $recoveryTask -and $updateTask)
    $powerReady = [bool](($sleep -eq 0) -and ($hibernate -eq 0))
    $ready = [bool]($sshReady -and $tailscaleReady -and $farRelayReady -and $powerReady)

    $progress = $null
    if (Test-Path -LiteralPath $progressPath -PathType Leaf) {
        try { $progress = Get-Content -LiteralPath $progressPath -Raw | ConvertFrom-Json } catch {}
    }

    $testerProfile = $null
    if (Test-Path -LiteralPath $testerProfilePath -PathType Leaf) {
        try { $testerProfile = Get-Content -LiteralPath $testerProfilePath -Raw | ConvertFrom-Json } catch {}
    }

    $updateStatus = $null
    $updateStatusTime = ''
    if (Test-Path -LiteralPath $updateStatusPath -PathType Leaf) {
        try {
            $updateStatus = Get-Content -LiteralPath $updateStatusPath -Raw | ConvertFrom-Json
            $updateStatusTime = (Get-Item -LiteralPath $updateStatusPath).LastWriteTime.ToString('s')
        } catch {}
    }

    $sshCommand = ''
    $hostCommand = ''
    if ($tailscaleIp) {
        $sshCommand = "ssh $env:USERNAME@$tailscaleIp"
        $hostCommand = "ssh $env:USERNAME@$tailscaleIp farrelay-host"
    }

    [ordered]@{
        ready = $ready
        computer = $env:COMPUTERNAME
        windows_user = $env:USERNAME
        version = if ($config) { [string]$config.installed_version } else { 'Unknown' }
        channel = if ($config) { [string]$config.channel } else { 'Unknown' }
        ssh = [ordered]@{
            installed = [bool]$sshd
            service = if ($sshd) { [string]$sshd.Status } else { 'Missing' }
            startup = if ($sshdStart) { [string]$sshdStart } else { 'Unknown' }
            port_22 = if ($sshListening) { 'Listening' } else { 'Not listening' }
            ready = $sshReady
        }
        tailscale = [ordered]@{
            installed = [bool]$tailscale
            service = if ($tailscaleService) { [string]$tailscaleService.Status } else { 'Missing' }
            signed_in = [bool]$tailscaleIp
            ip = if ($tailscaleIp) { $tailscaleIp } else { '' }
            unattended = $unattended
            ready = $tailscaleReady
        }
        farrelay = [ordered]@{
            host = $hostReady
            nvda_recovery = [bool]$recoveryTask
            updater = [bool]$updateTask
            nvda_running = $nvdaRunning
            last_update_result = if ($updateInfo) { [int]$updateInfo.LastTaskResult } else { $null }
            last_update_time = if ($updateInfo -and $updateInfo.LastRunTime.Year -gt 2000) { $updateInfo.LastRunTime.ToString('s') } else { '' }
            ready = $farRelayReady
        }
        power = [ordered]@{
            ac_sleep_never = [bool]($sleep -eq 0)
            ac_hibernate_never = [bool]($hibernate -eq 0)
            lid_do_nothing = [bool]($lid -eq 0)
            ready = $powerReady
        }
        connection = [ordered]@{
            ssh = $sshCommand
            host_test = $hostCommand
        }
        setup = [ordered]@{
            state = if ($progress) { [string]$progress.state } else { 'idle' }
            step = if ($progress) { [string]$progress.step } else { '' }
            message = if ($progress) { [string]$progress.message } else { 'No setup operation is currently recorded.' }
            updated_at = if ($progress) { [string]$progress.updated_at } else { '' }
        }
        beta = [ordered]@{
            tester_name = if ($testerProfile) { [string]$testerProfile.tester_name } else { '' }
            activated_at = if ($testerProfile) { [string]$testerProfile.activated_at } else { '' }
            access_expires_at = if ($testerProfile) { [string]$testerProfile.access_expires_at } else { '' }
            testflight_url = if ($testerProfile) { [string]$testerProfile.testflight_url } else { '' }
            feedback_url = if ($testerProfile) { [string]$testerProfile.feedback_url } else { '' }
            current_release = if ($testerProfile) { [string]$testerProfile.current_release } else { '' }
        }
        update = [ordered]@{
            state = if ($updateStatus) { [string]$updateStatus.state } else { 'not_checked' }
            installed_version = if ($updateStatus) { [string]$updateStatus.installed_version } else { if ($config) { [string]$config.installed_version } else { '' } }
            latest_version = if ($updateStatus) { [string]$updateStatus.latest_version } else { '' }
            update_available = if ($updateStatus) { [bool]$updateStatus.update_available } else { $false }
            message = if ($updateStatus) { [string]$updateStatus.message } else { 'No update check has been recorded yet.' }
            checked_at = $updateStatusTime
        }
    }
}

function Start-ElevatedPowerShell([string]$Command) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-Command', $Command
    ) | Out-Null
}

function Invoke-FixedAction([string]$Action) {
    switch ($Action) {
        'prepare' {
            if (-not (Test-Path -LiteralPath $prepareScript -PathType Leaf)) { throw 'Prepare for Travel script is missing.' }
            $escaped = $prepareScript.Replace("'", "''")
            Start-ElevatedPowerShell "& '$escaped' -Repair"
            return 'Prepare for Travel started. Approve the Windows UAC prompt. Status refreshes automatically.'
        }
        'update' {
            Start-ElevatedPowerShell "Start-ScheduledTask -TaskName 'FarRelay Update Check'"
            return 'FarRelay update check started.'
        }
        'restart-nvda' {
            Start-ScheduledTask -TaskName 'FarRelay Recover NVDA' -ErrorAction Stop
            return 'NVDA recovery task started.'
        }
        'ssh-key' {
            return Prepare-FarRelayIPhoneSshKey
        }
        'tailscale-login' {
            $tailscale = Resolve-Tailscale
            if (-not $tailscale) { throw 'Tailscale is not installed. Use Prepare for Travel first.' }
            Start-Process powershell.exe -ArgumentList @(
                '-NoProfile',
                '-ExecutionPolicy', 'Bypass',
                '-NoExit',
                '-Command', "& '$($tailscale.Replace("'", "''"))' up"
            ) | Out-Null
            return 'Tailscale sign-in started. Complete authentication, then return here.'
        }
        default { throw 'Unsupported control-center action.' }
    }
}

function Get-DashboardHtml {
@'
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>FarRelay Control Center</title>
<style>
body{font-family:system-ui,-apple-system,"Segoe UI",sans-serif;max-width:70rem;margin:0 auto;padding:1.25rem;line-height:1.5}
header,section{margin-bottom:2rem}
button{font:inherit;padding:.6rem .9rem;margin:.2rem}
dl{display:grid;grid-template-columns:minmax(10rem,16rem) 1fr;gap:.35rem 1rem}
dt{font-weight:700} dd{margin:0}
.good,.warn{font-weight:700}
.panel{border:1px solid currentColor;padding:1rem;margin:1rem 0}
textarea{width:100%;min-height:8rem;font:inherit;box-sizing:border-box}
.actions{display:flex;flex-wrap:wrap;gap:.35rem}
</style>
</head>
<body>
<header>
<h1>FarRelay Control Center</h1>
<p id="overall" role="status" aria-live="polite">Checking this computer...</p>
</header>
<main>
<section class="panel" aria-labelledby="beta-heading">
<h2 id="beta-heading">FarRelay beta</h2>
<p id="beta-welcome">Loading beta information...</p>
<p>Please complete onboarding on your own as much as possible. Report anything that does not work, feels confusing, or leaves you unsure what to do next.</p>
<dl>
<dt>Activated</dt><dd id="beta-activated">Checking...</dd>
<dt>Beta access expires</dt><dd id="beta-expires">Checking...</dd>
<dt>Time remaining</dt><dd id="beta-remaining">Checking...</dd>
<dt>TestFlight</dt><dd><a id="testflight-link" href="#">Checking...</a></dd>
<dt>Feedback</dt><dd><a id="feedback-link" href="#" target="_blank" rel="noopener">Checking...</a></dd>
<dt>Installed version</dt><dd id="beta-installed-version">Checking...</dd>
<dt>Latest published version</dt><dd id="beta-latest-version">Checking...</dd>
<dt>Update status</dt><dd id="beta-update-status">Checking...</dd>
<dt>Last update check</dt><dd id="beta-update-checked">Checking...</dd>
</dl>
<p>You need the FarRelay iPhone app from TestFlight to test remote control from your phone.</p>
</section>

<section class="panel" aria-labelledby="computer-heading">
<h2 id="computer-heading">This computer</h2>
<dl>
<dt>Computer</dt><dd id="computer">Checking...</dd>
<dt>FarRelay version</dt><dd id="version">Checking...</dd>
<dt>Release channel</dt><dd id="channel">Checking...</dd>
</dl>
</section>

<section class="panel" aria-labelledby="remote-heading">
<h2 id="remote-heading">Remote access</h2>
<dl>
<dt>OpenSSH</dt><dd id="ssh">Checking...</dd>
<dt>SSH port 22</dt><dd id="ssh-port">Checking...</dd>
<dt>Tailscale</dt><dd id="tailscale">Checking...</dd>
<dt>Tailscale address</dt><dd id="tailscale-ip">Checking...</dd>
<dt>Unattended mode</dt><dd id="unattended">Checking...</dd>
</dl>
</section>

<section class="panel" aria-labelledby="farrelay-heading">
<h2 id="farrelay-heading">FarRelay services</h2>
<dl>
<dt>FarRelay Host</dt><dd id="host">Checking...</dd>
<dt>NVDA recovery</dt><dd id="recovery">Checking...</dd>
<dt>NVDA currently running</dt><dd id="nvda">Checking...</dd>
<dt>Automatic updater</dt><dd id="updater">Checking...</dd>
<dt>Last update result</dt><dd id="update-result">Checking...</dd>
</dl>
</section>

<section class="panel" aria-labelledby="power-heading">
<h2 id="power-heading">Travel power readiness</h2>
<dl>
<dt>AC sleep</dt><dd id="sleep">Checking...</dd>
<dt>AC hibernate</dt><dd id="hibernate">Checking...</dd>
<dt>Lid close</dt><dd id="lid">Checking...</dd>
</dl>
</section>

<section class="panel" aria-labelledby="setup-heading">
<h2 id="setup-heading">Setup activity</h2>
<dl>
<dt>State</dt><dd id="setup-state">Idle</dd>
<dt>Current step</dt><dd id="setup-step">None</dd>
<dt>Latest message</dt><dd id="setup-message">No setup operation is currently recorded.</dd>
<dt>Updated</dt><dd id="setup-updated">Not yet</dd>
</dl>
</section>

<section class="panel" aria-labelledby="connection-heading">
<h2 id="connection-heading">Connect from iPhone</h2>
<p>Three short steps. FarRelay stores SSH credentials in the iPhone Keychain.</p>
<h3>1. Add this computer</h3>
<p id="connect-computer">Waiting for Tailscale address...</p>
<h3>2. SSH authentication</h3>
<p id="connect-auth">Waiting for Tailscale address...</p>
<p><button data-action="ssh-key">Prepare SSH key and copy private key</button></p>
<p>This button creates or reuses FarRelay's dedicated key, authorizes its public half without replacing existing keys, and copies the private half for you to paste into the iPhone app.</p>
<h3>3. NVDA Remote</h3>
<p id="connect-nvda">Waiting for Tailscale address...</p>
<textarea id="connection-copy" readonly tabindex="-1" aria-hidden="true" style="position:absolute;left:-10000px;width:1px;height:1px"></textarea>
<p><button id="copy">Copy connection instructions</button></p>
</section>

<section class="panel" aria-labelledby="actions-heading">
<h2 id="actions-heading">Actions</h2>
<p>Only fixed FarRelay actions are available. Administrative repairs use the normal Windows UAC prompt.</p>
<div class="actions">
<button data-action="prepare">Prepare or repair this PC for travel</button>
<button data-action="tailscale-login">Sign in to Tailscale</button>
<button data-action="update">Check for FarRelay update now</button>
<button data-action="restart-nvda">Restart NVDA</button>
<button id="refresh">Refresh status</button>
<button id="close">Close Control Center</button>
</div>
<p id="activity" role="status" aria-live="polite"></p>
</section>
</main>
<script>
const token=location.hash.slice(1);
history.replaceState(null,"",location.pathname);
let connectionText="";
const get=id=>document.getElementById(id);
const ready=v=>v?"Ready":"Needs attention";
const yes=v=>v?"Yes":"No";
function set(id,value){get(id).textContent=value;}
function remaining(value){
  if(!value)return "Not available";
  const ms=Date.parse(value)-Date.now();
  if(!Number.isFinite(ms))return "Unknown";
  if(ms<=0)return "Expired";
  const days=Math.floor(ms/86400000);
  const hours=Math.floor((ms%86400000)/3600000);
  if(days>0)return days+" day(s), "+hours+" hour(s)";
  const minutes=Math.max(0,Math.floor((ms%3600000)/60000));
  return hours+" hour(s), "+minutes+" minute(s)";
}
function setLink(id,url,label,missing){
  const a=get(id);
  if(url){
    a.href=url;
    a.textContent=label;
  }else{
    a.removeAttribute("href");
    a.textContent=missing;
  }
}
async function api(path,options={}){
  options.headers=Object.assign({},options.headers||{},{"X-FarRelay-Control-Token":token});
  const r=await fetch(path,options);
  if(!r.ok) throw new Error(await r.text());
  return r.json();
}
function render(s){
  set("overall",s.ready?"READY FOR REMOTE TRAVEL":"SETUP OR ATTENTION REQUIRED");
  get("overall").className=s.ready?"good":"warn";
  const tester=s.beta&&s.beta.tester_name?s.beta.tester_name:"Tester";
  set("beta-welcome","Hello "+tester+"! Welcome to the FarRelay beta.");
  set("beta-activated",s.beta&&s.beta.activated_at?s.beta.activated_at:"Not recorded yet");
  set("beta-expires",s.beta&&s.beta.access_expires_at?s.beta.access_expires_at:"Not recorded yet");
  set("beta-remaining",remaining(s.beta&&s.beta.access_expires_at?s.beta.access_expires_at:""));
  setLink("testflight-link",s.beta?s.beta.testflight_url:"","Join the FarRelay iPhone beta in TestFlight","TestFlight link not configured yet");
  let feedbackUrl=s.beta?s.beta.feedback_url:"";
  if(feedbackUrl){
    try{
      const feedbackAddress=new URL(feedbackUrl);
      if(feedbackAddress.pathname.startsWith("/feedback/")){
        feedbackAddress.searchParams.set("source","control-center");
        feedbackUrl=feedbackAddress.toString();
      }
    }catch{}
  }
  setLink("feedback-link",feedbackUrl,"Send beta feedback (opens in new tab)","Feedback link not configured yet");
  set("beta-installed-version",s.update&&s.update.installed_version?s.update.installed_version:s.version);
  set("beta-latest-version",s.update&&s.update.latest_version?s.update.latest_version:"Not checked yet");
  set("beta-update-status",s.update?s.update.message:"No update check has been recorded yet.");
  set("beta-update-checked",s.update&&s.update.checked_at?s.update.checked_at:"Not checked yet");
  set("computer",s.computer+" - Windows user "+s.windows_user);
  set("version",s.version); set("channel",s.channel);
  set("ssh",ready(s.ssh.ready)+" - service "+s.ssh.service+", startup "+s.ssh.startup);
  set("ssh-port",s.ssh.port_22);
  set("tailscale",ready(s.tailscale.ready)+" - service "+s.tailscale.service);
  set("tailscale-ip",s.tailscale.ip||"Not signed in yet");
  set("unattended",yes(s.tailscale.unattended));
  set("host",ready(s.farrelay.host));
  set("recovery",ready(s.farrelay.nvda_recovery));
  set("nvda",yes(s.farrelay.nvda_running));
  set("updater",ready(s.farrelay.updater));
  set("update-result",s.farrelay.last_update_result===null?"Never run":String(s.farrelay.last_update_result)+(s.farrelay.last_update_time?" at "+s.farrelay.last_update_time:""));
  set("sleep",s.power.ac_sleep_never?"Never":"Needs attention");
  set("hibernate",s.power.ac_hibernate_never?"Never":"Needs attention");
  set("lid",s.power.lid_do_nothing?"Do nothing":"Not configured to Do nothing");
  set("setup-state",s.setup.state||"idle");
  set("setup-step",s.setup.step||"None");
  set("setup-message",s.setup.message||"");
  set("setup-updated",s.setup.updated_at||"Not yet");
  if(s.connection.ssh){
    const computer="In FarRelay on iPhone, add a Windows computer. Address: "+s.tailscale.ip+". Port: 22. Username: "+s.windows_user+".";
    const auth="Choose Private Key. Paste the private key matching the public key authorized for this Windows account. Enter its passphrase if it has one.";
    const nvda="Under Accessibility, turn on Configure NVDA Remote and Enable NVDA Remote. Relay host: nvdaremote.com. Port: 6837. Enter the channel key for the NVDA Remote session you want to join. Leave fingerprint blank and Insecure off unless your relay requires otherwise.";
    set("connect-computer",computer);
    set("connect-auth",auth);
    set("connect-nvda",nvda);
    connectionText="1. Add this computer\n"+computer+"\n\n2. SSH authentication\n"+auth+"\n\n3. NVDA Remote\n"+nvda+"\n\nSSH check: "+s.connection.ssh+"\nFarRelay host check: "+s.connection.host_test;
  }else{
    const pending="Tailscale does not have an IPv4 address yet. Use Sign in to Tailscale, complete authentication, then refresh.";
    set("connect-computer",pending);
    set("connect-auth","Complete Tailscale sign-in first.");
    set("connect-nvda","Complete Tailscale sign-in first.");
    connectionText=pending;
  }
  get("connection-copy").value=connectionText;
}
async function refresh(){
  try{render(await api("/api/status"));}catch(e){set("activity","Status error: "+e.message);}
}
document.querySelectorAll("[data-action]").forEach(b=>b.addEventListener("click",async()=>{
  set("activity","Starting "+b.textContent+"...");
  try{
    const r=await api("/api/action",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({action:b.dataset.action})});
    set("activity",r.message);
    setTimeout(refresh,2500);
  }catch(e){set("activity","Action failed: "+e.message);}
}));
get("refresh").addEventListener("click",refresh);
get("copy").addEventListener("click",async()=>{
  try{await navigator.clipboard.writeText(connectionText);set("activity","Connection instructions copied.");}
  catch{const field=get("connection-copy");field.focus();field.select();set("activity","Connection instructions selected. Press Ctrl+C to copy them.");}
});
get("close").addEventListener("click",async()=>{
  try{await api("/api/close",{method:"POST"});}catch{}
  document.body.innerHTML="<main><h1>FarRelay Control Center closed</h1><p>You can close this browser tab.</p></main>";
});
refresh();
setInterval(refresh,5000);
</script>
</body>
</html>
'@
}

function Send-HttpResponse($Stream, [int]$Status, [string]$ContentType, [byte[]]$Body) {
    $reason = switch ($Status) {
        200 {'OK'} 204 {'No Content'} 400 {'Bad Request'} 401 {'Unauthorized'}
        404 {'Not Found'} 405 {'Method Not Allowed'} 500 {'Internal Server Error'}
        default {'OK'}
    }
    $nl = [Environment]::NewLine
    $headers = @(
        "HTTP/1.1 $Status $reason"
        "Content-Type: $ContentType"
        "Content-Length: $($Body.Length)"
        "Cache-Control: no-store"
        "Referrer-Policy: no-referrer"
        "X-Content-Type-Options: nosniff"
        "X-Frame-Options: DENY"
        "Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'self'; form-action 'none'; frame-ancestors 'none'"
        "Connection: close"
        ""
        ""
    ) -join $nl
    $headerBytes = [Text.Encoding]::UTF8.GetBytes($headers)
    $Stream.Write($headerBytes,0,$headerBytes.Length)
    if ($Body.Length -gt 0) { $Stream.Write($Body,0,$Body.Length) }
    $Stream.Flush()
}

function Send-Text($Stream,[int]$Status,[string]$ContentType,[string]$Text) {
    Send-HttpResponse $Stream $Status $ContentType ([Text.Encoding]::UTF8.GetBytes($Text))
}

if ($InstallAdminAuthorizedKey) {
    Install-FarRelayAdminAuthorizedKey $PublicKeyPath
    exit 0
}

$token = New-RandomHex
$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
$listener.Start()
$port = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
Start-Process "http://127.0.0.1:$port/#$token" | Out-Null

$running = $true
$lastRequest = Get-Date

try {
    while ($running) {
        if (-not $listener.Pending()) {
            if (((Get-Date) - $lastRequest).TotalMinutes -ge 30) { break }
            Start-Sleep -Milliseconds 100
            continue
        }

        $client = $listener.AcceptTcpClient()
        $lastRequest = Get-Date
        try {
            $stream = $client.GetStream()
            $reader = [IO.StreamReader]::new($stream,[Text.Encoding]::UTF8,$false,4096,$true)
            $requestLine = $reader.ReadLine()
            if ([string]::IsNullOrWhiteSpace($requestLine)) { continue }

            $parts = $requestLine.Split(' ')
            if ($parts.Count -lt 2) {
                Send-Text $stream 400 'text/plain; charset=utf-8' 'Bad request'
                continue
            }

            $method = $parts[0].ToUpperInvariant()
            $path = ($parts[1] -split '\?')[0]
            $headers = @{}

            while ($true) {
                $line = $reader.ReadLine()
                if ($null -eq $line -or $line -eq '') { break }
                $colon = $line.IndexOf(':')
                if ($colon -gt 0) {
                    $headers[$line.Substring(0,$colon).Trim().ToLowerInvariant()] = $line.Substring($colon+1).Trim()
                }
            }

            $contentLength = 0
            if ($headers.ContainsKey('content-length')) {
                [void][int]::TryParse($headers['content-length'],[ref]$contentLength)
            }

            $body = ''
            if ($contentLength -gt 0) {
                $buffer = New-Object char[] $contentLength
                $read = 0
                while ($read -lt $contentLength) {
                    $count = $reader.Read($buffer,$read,$contentLength-$read)
                    if ($count -le 0) { break }
                    $read += $count
                }
                if ($read -gt 0) { $body = -join $buffer[0..($read-1)] }
            }

            if ($method -eq 'GET' -and $path -eq '/') {
                Send-Text $stream 200 'text/html; charset=utf-8' (Get-DashboardHtml)
                continue
            }

            if ($method -eq 'GET' -and $path -eq '/favicon.ico') {
                Send-HttpResponse $stream 204 'image/x-icon' ([byte[]]@())
                continue
            }

            $provided = if ($headers.ContainsKey('x-farrelay-control-token')) { $headers['x-farrelay-control-token'] } else { '' }
            if ($provided -ne $token) {
                Send-Text $stream 401 'text/plain; charset=utf-8' 'Control token required.'
                continue
            }

            if ($method -eq 'GET' -and $path -eq '/api/status') {
                Send-Text $stream 200 'application/json; charset=utf-8' (Get-FarRelayStatus | ConvertTo-Json -Depth 6 -Compress)
                continue
            }

            if ($method -eq 'POST' -and $path -eq '/api/action') {
                try {
                    $request = $body | ConvertFrom-Json
                    $message = Invoke-FixedAction ([string]$request.action)
                    Send-Text $stream 200 'application/json; charset=utf-8' (@{ok=$true;message=$message} | ConvertTo-Json -Compress)
                } catch {
                    Send-Text $stream 500 'text/plain; charset=utf-8' $_.Exception.Message
                }
                continue
            }

            if ($method -eq 'POST' -and $path -eq '/api/close') {
                Send-Text $stream 200 'application/json; charset=utf-8' '{"ok":true}'
                $running = $false
                continue
            }

            Send-Text $stream 404 'text/plain; charset=utf-8' 'Not found.'
        } finally {
            $client.Close()
        }
    }
} finally {
    $listener.Stop()
}
