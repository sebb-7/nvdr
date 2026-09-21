[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('beta', 'stable')]
    [string]$Channel,

    [Parameter(Mandatory = $true)]
    [string]$DistributionDirectory,

    [string]$Repository = 'sebb-7/farrelay-releases'
)

$ErrorActionPreference = 'Stop'
$dist = (Resolve-Path -LiteralPath $DistributionDirectory).Path
$manifest = Join-Path $dist "update-$Channel.json"

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw 'GitHub CLI (gh) is required.'
}
gh auth status | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw 'GitHub CLI is not authenticated. Run gh auth login first.'
}
gh repo view $Repository | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Public release repository $Repository is unavailable."
}
if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) {
    throw "Missing channel manifest: $manifest"
}

$data = Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json
$version = [string]$data.version
if ([string]::IsNullOrWhiteSpace($version)) {
    throw 'Update manifest has no version.'
}

$required = @(
    "FarRelay-Windows-Update-$version.zip",
    "FarRelay-Setup-$version.exe",
    "update-$Channel.json",
    'update-manifest.json',
    'SHA256SUMS.txt'
)
foreach ($name in $required) {
    if (-not (Test-Path -LiteralPath (Join-Path $dist $name) -PathType Leaf)) {
        throw "Missing release asset: $name"
    }
}

$tag = "farrelay-$Channel"
gh release view $tag --repo $Repository 2>$null
if ($LASTEXITCODE -ne 0) {
    if ($Channel -eq 'beta') {
        gh release create $tag --repo $Repository --title 'FarRelay beta channel' --notes 'Rolling public beta channel for FarRelay Windows distribution.' --prerelease
    } else {
        gh release create $tag --repo $Repository --title 'FarRelay stable channel' --notes 'Rolling public stable channel for FarRelay Windows distribution.'
    }
    if ($LASTEXITCODE -ne 0) { throw "Unable to create $tag release." }
}

gh release upload $tag "$dist\*" --repo $Repository --clobber
if ($LASTEXITCODE -ne 0) { throw "Unable to publish assets to $Repository." }

Write-Output "Published FarRelay $version to public $Channel channel in $Repository."
