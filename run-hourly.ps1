# Hourly driver (runs on the hour via the scheduled task):
# pull new website signups -> re-check watched GoWild fares -> alert -> publish.

$ErrorActionPreference = 'Continue'
$root = $PSScriptRoot
. (Join-Path $root 'common.ps1')
try { Start-Transcript -Path (Join-Path $root 'data\last-hourly.log') -Force | Out-Null } catch { }

# wait briefly if the quick-queue is mid-sweep, then proceed regardless
$gotLock = $false
for ($i = 0; $i -lt 4; $i++) {
    if (Get-FwLock 10) { $gotLock = $true; break }
    Start-Sleep -Seconds 45
}
try {
    & (Join-Path $root 'watch-intake.ps1')
    & (Join-Path $root 'sweep.ps1') -WatchOnly
    & (Join-Path $root 'lab.ps1')
    & (Join-Path $root 'publish.ps1') -Message ('hourly watch update ' + (Get-Date -Format 'yyyy-MM-dd HH:mm'))
} finally {
    if ($gotLock) { Release-FwLock }
}

try { Stop-Transcript | Out-Null } catch { }
