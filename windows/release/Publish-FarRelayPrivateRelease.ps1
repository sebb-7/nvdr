[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('beta', 'stable')]
    [string]$Channel,
    [Parameter(Mandatory = $true)]
    [string]$DistributionDirectory,
    [Parameter(Mandatory = $true)]
    [string]$GatewayUrl,
    [string]$Bucket = 'farrelay-private-releases',
    [string]$GatewayProjectDirectory = 'distribution-gateway'
)

$ErrorActionPreference = 'Stop'
$token = $env:FARRELAY_ADMIN_TOKEN
if ([string]::IsNullOrWhiteSpace($token)) { throw 'Set FARRELAY_ADMIN_TOKEN in this PowerShell session before publishing.' }

$dist = (Resolve-Path -LiteralPath $DistributionDirectory).Path
$gateway = $GatewayUrl.TrimEnd('/')
$manifestPath = Join-Path $dist "update-$Channel.json"
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw "Missing $manifestPath" }

$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$version = [string]$manifest.version
$asset = $manifest.assets.windows_x86_64
$updateName = "FarRelay-Windows-Update-$version.zip"
$installerName = "FarRelay-Setup-$version.exe"
$updateFile = Join-Path $dist $updateName
$installerFile = Join-Path $dist $installerName
if (-not (Test-Path -LiteralPath $updateFile -PathType Leaf)) { throw "Missing $updateFile" }
if (-not (Test-Path -LiteralPath $installerFile -PathType Leaf)) { throw "Missing $installerFile" }

$actualHash = (Get-FileHash -LiteralPath $updateFile -Algorithm SHA256).Hash.ToLowerInvariant()
$actualSize = (Get-Item -LiteralPath $updateFile).Length
if ($actualHash -ne ([string]$asset.sha256).ToLowerInvariant()) { throw 'Update SHA-256 does not match manifest.' }
if ($actualSize -ne [int64]$asset.size) { throw 'Update size does not match manifest.' }

$prefix = "releases/$Channel/$version"
$updateKey = "$prefix/$updateName"
$installerKey = "$prefix/$installerName"
$gatewayDir = (Resolve-Path -LiteralPath $GatewayProjectDirectory).Path

Push-Location $gatewayDir
try {
    npx wrangler r2 object put "$Bucket/$updateKey" --file $updateFile --content-type application/zip --remote
    if ($LASTEXITCODE -ne 0) { throw 'R2 update upload failed.' }
    npx wrangler r2 object put "$Bucket/$installerKey" --file $installerFile --content-type application/vnd.microsoft.portable-executable --remote
    if ($LASTEXITCODE -ne 0) { throw 'R2 installer upload failed.' }
}
finally {
    Pop-Location
}

$body = @{
    channel = $Channel
    version = $version
    update_object_key = $updateKey
    installer_object_key = $installerKey
    sha256 = $actualHash
    size = $actualSize
} | ConvertTo-Json
$headers = @{ Authorization = "Bearer $token" }
$result = Invoke-RestMethod -Method Post -Uri "$gateway/admin/releases" -Headers $headers -ContentType 'application/json' -Body $body
Write-Output "Published private FarRelay $($result.version) to $($result.channel)."
