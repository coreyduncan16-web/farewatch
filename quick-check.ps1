# FareWatch quick tick (runs every ~2 minutes, hidden). One lock, three jobs:
#   1. pull new website signups/searches (watch-intake)
#   2. if someone searched, sweep those routes' full 10-day spans NOW
#   3. always advance the rolling network crawl by one batch
# Renders every tick; publishes when there was a search or every ~20 min so
# the site stays fresh without tripping Netlify's deploy rate limit.

$ErrorActionPreference = 'Continue'
$root = $PSScriptRoot
. (Join-Path $root 'common.ps1')

# intake needs no lock (just a Netlify API read + small file writes)
& (Join-Path $root 'watch-intake.ps1') | Out-Null

$hasRecheck = Test-Path (Get-FwPath 'data\recheck.json')

if (-not (Get-FwLock 10)) { return }   # hourly/daily busy; it will cover this
try {
    Start-Transcript -Path (Join-Path $root 'data\last-quick.log') -Force | Out-Null

    # searched routes first (full 10-day spans handled inside sweep -WatchOnly)
    if ($hasRecheck) {
        & (Join-Path $root 'sweep.ps1') -WatchOnly -NoRender
    }

    # always move the whole-network crawl forward one batch
    & (Join-Path $root 'crawl.ps1') -NoLock

    # refresh the page from the updated database
    & (Join-Path $root 'render.ps1') | Out-Null

    # Publish to the web ONLY when someone actually searched (rare, user-driven).
    # Routine crawl data rides out on the hourly publish - this keeps deploy
    # frequency well under Netlify's per-site throttle so it never penalizes.
    if ($hasRecheck) {
        & (Join-Path $root 'publish.ps1') -Message ('live search update ' + (Get-Date -Format 'yyyy-MM-dd HH:mm')) | Out-Null
        Set-Content -Path (Get-FwPath 'data\last-publish.txt') -Value ([string](Get-Date)) -Encoding ASCII
    }
} finally {
    Release-FwLock
    try { Stop-Transcript | Out-Null } catch { }
}
