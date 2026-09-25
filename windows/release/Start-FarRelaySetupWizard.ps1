[CmdletBinding()]
param(
    [switch]$Worker,
    [ValidateSet('Recommended','Travel','Custom')][string]$RunSetupMode = 'Recommended',
    [string]$StatusPath,
    [string]$ExpectedUserName,
    [switch]$SkipOpenSsh,
    [switch]$SkipTailscale,
    [switch]$SkipNvda,
    [switch]$SkipSshKey,
    [switch]$EnableTravelHardening
)

$ErrorActionPreference = 'Stop'
$corePath = Join-Path $PSScriptRoot 'FarRelay.Setup.Core.psm1'
if (-not (Test-Path -LiteralPath $corePath -PathType Leaf)) {
    throw "FarRelay setup core is missing: $corePath"
}
Import-Module $corePath -Force

if ($Worker) {
    try {
        $workerParams = @{
            Mode = $RunSetupMode
            StatusPath = $StatusPath
            ExpectedUserName = $ExpectedUserName
            SkipOpenSsh = $SkipOpenSsh
            SkipTailscale = $SkipTailscale
            SkipNvda = $SkipNvda
            SkipSshKey = $SkipSshKey
            EnableTravelHardening = $EnableTravelHardening
        }
        Invoke-FarRelaySetup @workerParams | Out-Null
        exit 0
    } catch {
        Write-Error $_
        exit 1
    }
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$controlCenterPath = Join-Path $PSScriptRoot 'Start-FarRelayControlCenter.ps1'
$statusFile = Join-Path $env:ProgramData 'FarRelay\setup-wizard-status.json'
$snapshot = Get-FarRelaySetupSnapshot
$newLine = [Environment]::NewLine

$form = New-Object System.Windows.Forms.Form
$form.Text = 'FarRelay Setup Wizard'
$form.StartPosition = 'CenterScreen'
$form.Size = New-Object System.Drawing.Size(720,560)
$form.MinimumSize = New-Object System.Drawing.Size(680,520)
$form.MaximizeBox = $false
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Font
$form.KeyPreview = $true

$title = New-Object System.Windows.Forms.Label
$title.Location = New-Object System.Drawing.Point(24,20)
$title.Size = New-Object System.Drawing.Size(650,34)
$title.Font = New-Object System.Drawing.Font($form.Font.FontFamily,15,[System.Drawing.FontStyle]::Bold)
$title.Text = 'FarRelay Setup'
$title.AccessibleName = 'FarRelay Setup'
$form.Controls.Add($title)

$description = New-Object System.Windows.Forms.TextBox
$description.Location = New-Object System.Drawing.Point(24,62)
$description.Size = New-Object System.Drawing.Size(650,250)
$description.Multiline = $true
$description.ReadOnly = $true
$description.ScrollBars = 'Vertical'
$description.TabStop = $true
$description.AccessibleName = 'Setup information'
$form.Controls.Add($description)

$modeGroup = New-Object System.Windows.Forms.GroupBox
$modeGroup.Location = New-Object System.Drawing.Point(24,322)
$modeGroup.Size = New-Object System.Drawing.Size(650,128)
$modeGroup.Text = 'Setup type'
$modeGroup.AccessibleName = 'Setup type'
$form.Controls.Add($modeGroup)

$recommended = New-Object System.Windows.Forms.RadioButton
$recommended.Location = New-Object System.Drawing.Point(18,25)
$recommended.Size = New-Object System.Drawing.Size(610,24)
$recommended.Text = '&Recommended setup - OpenSSH, Tailscale, NVDA recovery, and verified iPhone SSH key'
$recommended.Checked = $true
$modeGroup.Controls.Add($recommended)

$travel = New-Object System.Windows.Forms.RadioButton
$travel.Location = New-Object System.Drawing.Point(18,52)
$travel.Size = New-Object System.Drawing.Size(610,24)
$travel.Text = '&Travel setup - Recommended setup plus unattended Tailscale and AC sleep hardening'
$modeGroup.Controls.Add($travel)

$custom = New-Object System.Windows.Forms.RadioButton
$custom.Location = New-Object System.Drawing.Point(18,79)
$custom.Size = New-Object System.Drawing.Size(610,24)
$custom.Text = '&Custom setup'
$modeGroup.Controls.Add($custom)

$customGroup = New-Object System.Windows.Forms.GroupBox
$customGroup.Location = New-Object System.Drawing.Point(24,322)
$customGroup.Size = New-Object System.Drawing.Size(650,128)
$customGroup.Text = 'Custom components'
$customGroup.Visible = $false
$form.Controls.Add($customGroup)

$checkOpenSsh = New-Object System.Windows.Forms.CheckBox
$checkOpenSsh.Location = New-Object System.Drawing.Point(18,24)
$checkOpenSsh.Size = New-Object System.Drawing.Size(280,24)
$checkOpenSsh.Text = 'Windows &OpenSSH Server'
$checkOpenSsh.Checked = $true
$customGroup.Controls.Add($checkOpenSsh)

$checkTailscale = New-Object System.Windows.Forms.CheckBox
$checkTailscale.Location = New-Object System.Drawing.Point(330,24)
$checkTailscale.Size = New-Object System.Drawing.Size(280,24)
$checkTailscale.Text = '&Tailscale'
$checkTailscale.Checked = $true
$customGroup.Controls.Add($checkTailscale)

$checkNvda = New-Object System.Windows.Forms.CheckBox
$checkNvda.Location = New-Object System.Drawing.Point(18,55)
$checkNvda.Size = New-Object System.Drawing.Size(280,24)
$checkNvda.Text = '&NVDA recovery'
$checkNvda.Checked = $true
$customGroup.Controls.Add($checkNvda)

$checkKey = New-Object System.Windows.Forms.CheckBox
$checkKey.Location = New-Object System.Drawing.Point(330,55)
$checkKey.Size = New-Object System.Drawing.Size(280,24)
$checkKey.Text = 'Verified iPhone SSH &key'
$checkKey.Checked = $true
$customGroup.Controls.Add($checkKey)

$checkTravel = New-Object System.Windows.Forms.CheckBox
$checkTravel.Location = New-Object System.Drawing.Point(18,86)
$checkTravel.Size = New-Object System.Drawing.Size(590,24)
$checkTravel.Text = 'Apply unattended &travel hardening'
$customGroup.Controls.Add($checkTravel)

$backButton = New-Object System.Windows.Forms.Button
$backButton.Location = New-Object System.Drawing.Point(376,466)
$backButton.Size = New-Object System.Drawing.Size(92,32)
$backButton.Text = '&Back'
$backButton.Enabled = $false
$form.Controls.Add($backButton)

$nextButton = New-Object System.Windows.Forms.Button
$nextButton.Location = New-Object System.Drawing.Point(474,466)
$nextButton.Size = New-Object System.Drawing.Size(92,32)
$nextButton.Text = '&Next'
$form.Controls.Add($nextButton)

$cancelButton = New-Object System.Windows.Forms.Button
$cancelButton.Location = New-Object System.Drawing.Point(572,466)
$cancelButton.Size = New-Object System.Drawing.Size(102,32)
$cancelButton.Text = 'Cancel'
$form.Controls.Add($cancelButton)

$copyKeyButton = New-Object System.Windows.Forms.Button
$copyKeyButton.Location = New-Object System.Drawing.Point(24,466)
$copyKeyButton.Size = New-Object System.Drawing.Size(166,32)
$copyKeyButton.Text = 'Copy &Private Key'
$copyKeyButton.Visible = $false
$form.Controls.Add($copyKeyButton)

$controlCenterButton = New-Object System.Windows.Forms.Button
$controlCenterButton.Location = New-Object System.Drawing.Point(196,466)
$controlCenterButton.Size = New-Object System.Drawing.Size(166,32)
$controlCenterButton.Text = 'Open &Control Center'
$controlCenterButton.Visible = $false
$form.Controls.Add($controlCenterButton)

$form.AcceptButton = $nextButton
$form.CancelButton = $cancelButton

$script:page = 0
$script:workerProcess = $null
$script:lastStatus = $null

function Format-Bool([bool]$Value) {
    if ($Value) { return 'Ready' }
    return 'Not ready'
}

function Get-Mode {
    if ($travel.Checked) { return 'Travel' }
    if ($custom.Checked) { return 'Custom' }
    return 'Recommended'
}

function Get-WelcomeText {
    $tail = if ($snapshot.TailscaleIp) { "Ready; address $($snapshot.TailscaleIp)" } elseif ($snapshot.TailscaleInstalled) { 'Installed; sign-in still required' } else { 'Not installed' }
    $lines = @(
        'This wizard configures this Windows computer for FarRelay and verifies that the result actually works.',
        '',
        "Current computer: $($snapshot.ComputerName)",
        "Windows user: $($snapshot.UserName)",
        '',
        "FarRelay installed: $(Format-Bool $snapshot.Installed)",
        "Tester activation: $(Format-Bool $snapshot.Activated)",
        "OpenSSH Server: $(Format-Bool $snapshot.OpenSshRunning)",
        "Tailscale: $tail",
        "NVDA installed: $(Format-Bool $snapshot.NvdaInstalled)",
        "NVDA recovery: $(Format-Bool $snapshot.RecoveryTaskReady)",
        '',
        'The installer remains responsible for installing and activating FarRelay. This wizard handles remote-access setup and verification.'
    )
    return $lines -join $newLine
}

function Get-ReviewText {
    $mode = Get-Mode
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("Setup type: $mode")
    $lines.Add('')
    if ($mode -eq 'Recommended') {
        $lines.Add('Configure Windows OpenSSH Server.')
        $lines.Add('Install or validate Tailscale.')
        $lines.Add('Configure NVDA recovery when NVDA is installed.')
        $lines.Add('Create or reuse a dedicated SSH key, verify its public/private match, authorize it, then perform a real localhost SSH login.')
    } elseif ($mode -eq 'Travel') {
        $lines.Add('Everything in Recommended setup.')
        $lines.Add('Enable Tailscale unattended mode.')
        $lines.Add('Set AC sleep and hibernate timeouts to Never.')
    } else {
        if ($checkOpenSsh.Checked) { $lines.Add('Configure Windows OpenSSH Server.') }
        if ($checkTailscale.Checked) { $lines.Add('Install or validate Tailscale.') }
        if ($checkNvda.Checked) { $lines.Add('Configure NVDA recovery.') }
        if ($checkKey.Checked) { $lines.Add('Create, authorize, and end-to-end verify the dedicated iPhone SSH key.') }
        if ($checkTravel.Checked) { $lines.Add('Apply unattended travel hardening.') }
    }
    $lines.Add('')
    $lines.Add('Administrator approval will be requested when setup begins.')
    $lines.Add('Existing SSH keys are never replaced. A mismatched FarRelay key pair is skipped and a new numbered pair is generated.')
    return $lines -join $newLine
}

function Show-Page([int]$Page) {
    $script:page = $Page
    $copyKeyButton.Visible = $false
    $controlCenterButton.Visible = $false

    switch ($Page) {
        0 {
            $title.Text = 'FarRelay Setup'
            $description.Text = Get-WelcomeText
            $modeGroup.Visible = $false
            $customGroup.Visible = $false
            $backButton.Enabled = $false
            $nextButton.Enabled = $snapshot.Installed -and $snapshot.Activated
            $nextButton.Text = '&Next'
            $cancelButton.Text = 'Cancel'
            $description.Focus()
        }
        1 {
            $title.Text = 'Choose setup type'
            $description.Text = @(
                'Recommended is appropriate for most computers.',
                '',
                'Travel adds unattended settings for a laptop that must remain reachable while you are away.',
                '',
                'Custom lets you choose individual components.',
                '',
                'RemSound is intentionally not included yet because the current Windows release does not package a RemSound installer.'
            ) -join $newLine
            $modeGroup.Visible = $true
            $customGroup.Visible = $false
            $backButton.Enabled = $true
            $nextButton.Enabled = $true
            $nextButton.Text = '&Next'
            if ($custom.Checked) { $checkOpenSsh.Focus() } else { $recommended.Focus() }
        }
        6 {
            $title.Text = 'Choose custom components'
            $description.Text = 'Choose the components FarRelay should configure. The verified SSH key requires OpenSSH Server to be available.'
            $modeGroup.Visible = $false
            $customGroup.Visible = $true
            $backButton.Enabled = $true
            $nextButton.Enabled = $true
            $nextButton.Text = '&Next'
            $checkOpenSsh.Focus()
        }
        2 {
            $title.Text = 'Review setup'
            $description.Text = Get-ReviewText
            $modeGroup.Visible = $false
            $customGroup.Visible = $false
            $backButton.Enabled = $true
            $nextButton.Enabled = $true
            $nextButton.Text = '&Install'
            $description.Focus()
        }
        3 {
            $title.Text = 'Setting up FarRelay'
            $description.Text = 'Waiting for administrator approval...'
            $modeGroup.Visible = $false
            $customGroup.Visible = $false
            $backButton.Enabled = $false
            $nextButton.Enabled = $false
            $cancelButton.Enabled = $false
            $description.Focus()
        }
        4 {
            $title.Text = 'FarRelay setup complete'
            $modeGroup.Visible = $false
            $customGroup.Visible = $false
            $backButton.Enabled = $false
            $nextButton.Enabled = $true
            $nextButton.Text = '&Finish'
            $cancelButton.Enabled = $true
            $cancelButton.Text = 'Close'
            $copyKeyButton.Visible = [bool]($script:lastStatus.data.ssh_private_key_path)
            $controlCenterButton.Visible = Test-Path -LiteralPath $controlCenterPath -PathType Leaf
            $description.Focus()
        }
        5 {
            $title.Text = 'FarRelay setup needs attention'
            $modeGroup.Visible = $false
            $customGroup.Visible = $false
            $backButton.Enabled = $true
            $nextButton.Enabled = $true
            $nextButton.Text = '&Retry'
            $cancelButton.Enabled = $true
            $cancelButton.Text = 'Close'
            $description.Focus()
        }
    }
}

function Start-SetupWorker {
    if (Test-Path -LiteralPath $statusFile) {
        Remove-Item -LiteralPath $statusFile -Force -ErrorAction SilentlyContinue
    }

    $mode = Get-Mode
    $arguments = [System.Collections.Generic.List[string]]::new()
    foreach ($item in @(
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-WindowStyle',
        'Hidden',
        '-File',
        ('"' + $PSCommandPath + '"'),
        '-Worker',
        '-RunSetupMode',
        $mode,
        '-StatusPath',
        ('"' + $statusFile + '"'),
        '-ExpectedUserName',
        $env:USERNAME
    )) { $arguments.Add($item) }

    if ($mode -eq 'Custom') {
        if (-not $checkOpenSsh.Checked) { $arguments.Add('-SkipOpenSsh') }
        if (-not $checkTailscale.Checked) { $arguments.Add('-SkipTailscale') }
        if (-not $checkNvda.Checked) { $arguments.Add('-SkipNvda') }
        if (-not $checkKey.Checked) { $arguments.Add('-SkipSshKey') }
        if ($checkTravel.Checked) { $arguments.Add('-EnableTravelHardening') }
    }

    Show-Page 3
    try {
        $script:workerProcess = Start-Process powershell.exe -Verb RunAs -ArgumentList $arguments -PassThru
    } catch {
        $description.Text = 'Setup did not start. Administrator approval may have been cancelled.' + $newLine + $newLine + $_.Exception.Message
        Show-Page 5
    }
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 500
$timer.Add_Tick({
    if ($script:page -ne 3) { return }
    if (Test-Path -LiteralPath $statusFile -PathType Leaf) {
        try {
            $status = Get-Content -LiteralPath $statusFile -Raw | ConvertFrom-Json
            $script:lastStatus = $status
            $description.Text = "$($status.step)$newLine$newLine$($status.message)"
            if ($status.state -eq 'ready') {
                $timer.Stop()
                $warnings = @($status.data.warnings)
                $summary = [System.Collections.Generic.List[string]]::new()
                $summary.Add('Setup completed.')
                $summary.Add('')
                if ($status.data.ssh_private_key_path) {
                    $summary.Add('The dedicated SSH key passed a real localhost public-key login test.')
                }
                if ($status.data.tailscale_ip) {
                    $summary.Add("Tailscale address: $($status.data.tailscale_ip)")
                }
                if ($warnings.Count -gt 0) {
                    $summary.Add('')
                    $summary.Add('Attention:')
                    foreach ($warning in $warnings) { if ($warning) { $summary.Add("- $warning") } }
                }
                $summary.Add('')
                $summary.Add('Use Copy Private Key only when you are ready to paste it into FarRelay on the iPhone. Do not send the private key through chat or email.')
                $description.Text = $summary -join $newLine
                Show-Page 4
            } elseif ($status.state -eq 'action_required') {
                $timer.Stop()
                $warnings = @($status.data.warnings)
                $lines = [System.Collections.Generic.List[string]]::new()
                $lines.Add($status.message)
                $lines.Add('')
                foreach ($warning in $warnings) { if ($warning) { $lines.Add("- $warning") } }
                $lines.Add('')
                $lines.Add('Complete the action above, then choose Retry.')
                $description.Text = $lines -join $newLine
                Show-Page 5
            } elseif ($status.state -eq 'failed') {
                $timer.Stop()
                $description.Text = "Setup failed during $($status.step).$newLine$newLine$($status.message)$newLine$newLineNo existing SSH key was overwritten."
                Show-Page 5
            }
        } catch {
        }
    }

    if ($script:workerProcess -and $script:workerProcess.HasExited -and $script:page -eq 3) {
        if (-not (Test-Path -LiteralPath $statusFile -PathType Leaf)) {
            $timer.Stop()
            $description.Text = "The setup worker exited with code $($script:workerProcess.ExitCode) before it could write a diagnostic result."
            Show-Page 5
        }
    }
})

$nextButton.Add_Click({
    switch ($script:page) {
        0 { Show-Page 1 }
        1 {
            if ($custom.Checked) { Show-Page 6 } else { Show-Page 2 }
        }
        6 { Show-Page 2 }
        2 {
            Start-SetupWorker
            $timer.Start()
        }
        4 { $form.Close() }
        5 {
            Start-SetupWorker
            $timer.Start()
        }
    }
})

$backButton.Add_Click({
    switch ($script:page) {
        1 { Show-Page 0 }
        6 { Show-Page 1 }
        2 {
            if ((Get-Mode) -eq 'Custom') { Show-Page 6 } else { Show-Page 1 }
        }
        5 { Show-Page 2 }
    }
})

$cancelButton.Add_Click({ $form.Close() })

$copyKeyButton.Add_Click({
    try {
        $path = [string]$script:lastStatus.data.ssh_private_key_path
        if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw 'The verified private key file could not be found.'
        }
        $privateKey = Get-Content -LiteralPath $path -Raw
        [System.Windows.Forms.Clipboard]::SetText($privateKey)
        [System.Windows.Forms.MessageBox]::Show(
            'The verified FarRelay private key is now on the clipboard. Paste it directly into FarRelay on the iPhone, then clear the clipboard when finished.',
            'FarRelay Setup',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
    } catch {
        [System.Windows.Forms.MessageBox]::Show(
            $_.Exception.Message,
            'FarRelay Setup',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
})

$controlCenterButton.Add_Click({
    if (Test-Path -LiteralPath $controlCenterPath -PathType Leaf) {
        $ccArguments = @(
            '-NoProfile',
            '-ExecutionPolicy','Bypass',
            '-WindowStyle','Hidden',
            '-File',('"' + $controlCenterPath + '"')
        )
        Start-Process powershell.exe -ArgumentList $ccArguments
    }
})

$form.Add_Shown({ Show-Page 0 })
[void]$form.ShowDialog()
