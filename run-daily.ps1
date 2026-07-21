# Daily driver: sweep fares, re-render the dashboard, fire any alerts,
# then publish to the website (if configured). This is what the scheduled
# task runs.

$ErrorActionPreference = 'Continue'
$root = $PSScriptRoot
try { Start-Transcript -Path (Join-Path $root 'data\last-daily.log') -Force | Out-Null } catch { }

& (Join-Path $root 'watch-intake.ps1')
& (Join-Path $root 'sweep.ps1')
& (Join-Path $root 'publish.ps1') -Message ('fare update ' + (Get-Date -Format 'yyyy-MM-dd HH:mm'))

try { Stop-Transcript | Out-Null } catch { }
