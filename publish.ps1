# Publishes the latest dashboard:
#   1. copies it to docs\ and commits (GitHub Pages serves this when healthy)
#   2. if NETLIFY_TOKEN + NETLIFY_SITE_ID are in .env, ALSO uploads straight
#      to Netlify - no GitHub involved, so outages there cannot block the site.
# Safe to run anytime.

[CmdletBinding()]
param([string]$Message = 'fare update')

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
Set-Location $root
. (Join-Path $root 'common.ps1')

$git = 'git'
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    $portable = 'D:\CLAUDE\Git\cmd\git.exe'
    if (Test-Path $portable) { $git = $portable }
    else { throw 'git not found on PATH or at D:\CLAUDE\Git\cmd\git.exe' }
}

if (-not (Test-Path (Join-Path $root 'dashboard.html'))) {
    throw 'dashboard.html not found - run sweep.ps1 or render.ps1 first.'
}

$docs = Join-Path $root 'docs'
if (-not (Test-Path $docs)) { New-Item -ItemType Directory -Path $docs | Out-Null }
Copy-Item (Join-Path $root 'dashboard.html') (Join-Path $docs 'index.html') -Force

& $git add docs/index.html
& $git commit -m $Message 2>$null
if ($LASTEXITCODE -ne 0) { Write-Output 'publish: nothing new to commit.' }

$remote = & $git remote
if ($remote) {
    & $git push
    if ($LASTEXITCODE -eq 0) { Write-Output 'publish: pushed to GitHub - the live site updates in about a minute.' }
    else { Write-Output 'publish: push failed - check your GitHub sign-in (GitHub Desktop or git credential manager).' }
} else {
    Write-Output 'publish: committed locally. No GitHub remote configured yet - see README section "Hosting it for everyone".'
}

# --- Netlify direct upload (outage-proof path) ---
$secrets = Read-FwEnv
$nToken = $secrets['NETLIFY_TOKEN']
$nSite  = $secrets['NETLIFY_SITE_ID']
if ($nToken -and $nSite) {
    $zip = Join-Path $env:TEMP 'farewatch-site.zip'
    if (Test-Path $zip) { Remove-Item $zip -Force }
    Compress-Archive -Path (Join-Path $docs '*') -DestinationPath $zip -Force
    try {
        $resp = Invoke-RestMethod -Method Post `
            -Uri ('https://api.netlify.com/api/v1/sites/{0}/deploys' -f $nSite) `
            -Headers @{ Authorization = 'Bearer ' + $nToken } `
            -ContentType 'application/zip' -InFile $zip -TimeoutSec 120
        Write-Output ('publish: deployed to Netlify -> {0}' -f $resp.ssl_url)
    } catch {
        Write-Output ('publish: Netlify deploy failed: ' + $_.Exception.Message)
    }
    Remove-Item $zip -Force -ErrorAction SilentlyContinue
}
