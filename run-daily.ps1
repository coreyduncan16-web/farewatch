# Daily driver: sweep fares, re-render the dashboard, fire any alerts,
# then publish to the website (if configured). This is what the scheduled
# task runs.

$ErrorActionPreference = 'Continue'
$root = $PSScriptRoot
. (Join-Path $root 'common.ps1')
try { Start-Transcript -Path (Join-Path $root 'data\last-daily.log') -Force | Out-Null } catch { }

$gotLock = $false
for ($i = 0; $i -lt 4; $i++) {
    if (Get-FwLock 10) { $gotLock = $true; break }
    Start-Sleep -Seconds 45
}
try {
    & (Join-Path $root 'watch-intake.ps1')
    & (Join-Path $root 'sweep.ps1')
    & (Join-Path $root 'publish.ps1') -Message ('fare update ' + (Get-Date -Format 'yyyy-MM-dd HH:mm'))
} finally {
    if ($gotLock) { Release-FwLock }
}

try { Stop-Transcript | Out-Null } catch { }
