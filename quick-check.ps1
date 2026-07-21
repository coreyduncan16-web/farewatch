# FareWatch quick queue: runs every 2 minutes (hidden). If somebody searched
# an unswept route on the website, this sweeps it NOW instead of waiting for
# the hourly run - the visitor sees live prices in a couple of minutes.
# Costs nothing when the queue is empty (one small Netlify API read).

$ErrorActionPreference = 'Continue'
$root = $PSScriptRoot
. (Join-Path $root 'common.ps1')

# pull any new website submissions into watches.json / data\recheck.json
& (Join-Path $root 'watch-intake.ps1') | Out-Null

$rcPath = Get-FwPath 'data\recheck.json'
if (-not (Test-Path $rcPath)) { return }   # nothing queued - stay quiet

if (-not (Get-FwLock 10)) { return }        # hourly/daily run is busy; it will handle the queue
try {
    Start-Transcript -Path (Join-Path $root 'data\last-quick.log') -Force | Out-Null
    & (Join-Path $root 'sweep.ps1') -WatchOnly -MaxCalls 22
    & (Join-Path $root 'publish.ps1') -Message ('live search sweep ' + (Get-Date -Format 'yyyy-MM-dd HH:mm'))
} finally {
    Release-FwLock
    try { Stop-Transcript | Out-Null } catch { }
}
