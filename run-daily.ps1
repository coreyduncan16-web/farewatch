# Daily driver: sweep fares, re-render the dashboard, fire any alerts,
# then publish to the website (if configured). This is what the scheduled
# task runs.

$ErrorActionPreference = 'Continue'
$root = $PSScriptRoot

& (Join-Path $root 'sweep.ps1')
& (Join-Path $root 'publish.ps1') -Message ('fare update ' + (Get-Date -Format 'yyyy-MM-dd HH:mm'))
