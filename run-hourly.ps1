# Hourly driver (runs on the hour via the scheduled task):
# pull new website signups -> re-check watched GoWild fares -> alert -> publish.

$ErrorActionPreference = 'Continue'
$root = $PSScriptRoot

& (Join-Path $root 'watch-intake.ps1')
& (Join-Path $root 'sweep.ps1') -WatchOnly
& (Join-Path $root 'lab.ps1')
& (Join-Path $root 'publish.ps1') -Message ('hourly watch update ' + (Get-Date -Format 'yyyy-MM-dd HH:mm'))
