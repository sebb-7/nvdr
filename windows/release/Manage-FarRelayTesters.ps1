[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('invite', 'list-devices', 'list-invites', 'revoke-device', 'revoke-invite')]
    [string]$Action,
    [Parameter(Mandatory = $true)]
    [string]$GatewayUrl,
    [string]$Label,
    [ValidateSet('beta', 'stable')]
    [string]$Channel = 'beta',
    [int]$MaxActivations = 1,
    [int]$ExpiresInHours = 168,
    [string]$Id
)

$ErrorActionPreference = 'Stop'
$token = $env:FARRELAY_ADMIN_TOKEN
if ([string]::IsNullOrWhiteSpace($token)) { throw 'Set FARRELAY_ADMIN_TOKEN in this PowerShell session.' }
$gateway = $GatewayUrl.TrimEnd('/')
$headers = @{ Authorization = "Bearer $token" }

switch ($Action) {
    'invite' {
        if ([string]::IsNullOrWhiteSpace($Label)) { throw '-Label is required for invite.' }
        $body = @{ label = $Label; channel = $Channel; max_activations = $MaxActivations; expires_in_hours = $ExpiresInHours } | ConvertTo-Json
        $result = Invoke-RestMethod -Method Post -Uri "$gateway/admin/invites" -Headers $headers -ContentType 'application/json' -Body $body
        Write-Output "Tester: $($result.label)"
        Write-Output "Channel: $($result.channel)"
        Write-Output "Activation code: $($result.activation_code)"
        Write-Output "Installer link: $($result.installer_url)"
        Write-Output "Expires: $($result.expires_at)"
    }
    'list-devices' { Invoke-RestMethod -Method Get -Uri "$gateway/admin/devices" -Headers $headers | ConvertTo-Json -Depth 5 }
    'list-invites' { Invoke-RestMethod -Method Get -Uri "$gateway/admin/invites" -Headers $headers | ConvertTo-Json -Depth 5 }
    'revoke-device' {
        if ([string]::IsNullOrWhiteSpace($Id)) { throw '-Id is required.' }
        Invoke-RestMethod -Method Post -Uri "$gateway/admin/devices/$Id/revoke" -Headers $headers | ConvertTo-Json
    }
    'revoke-invite' {
        if ([string]::IsNullOrWhiteSpace($Id)) { throw '-Id is required.' }
        Invoke-RestMethod -Method Post -Uri "$gateway/admin/invites/$Id/revoke" -Headers $headers | ConvertTo-Json
    }
}
