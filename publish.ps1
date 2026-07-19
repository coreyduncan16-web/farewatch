# Publishes the latest dashboard to the docs\ folder (GitHub Pages) and
# pushes if a git remote is configured. Safe to run even before the GitHub
# repo exists - it just commits locally and tells you what is left to do.

[CmdletBinding()]
param([string]$Message = 'fare update')

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
Set-Location $root

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
