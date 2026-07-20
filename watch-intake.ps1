# Pulls new price-alert signups from the website into watches.json.
#
# How signups travel: the website's "Price alerts" box submits to a free
# Google Form you own; Google puts each signup in a linked Sheet; you publish
# that Sheet as CSV (File -> Share -> Publish to web -> CSV) and paste the
# link into config.json -> watchIntake.csvUrl. This script downloads the CSV
# and merges new watches. Runs automatically at the start of every hourly
# check; safe to run by hand.
#
# Windows PowerShell 5.1 compatible. Keep this file ASCII-only.

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$cfg = Read-FwConfig
$csvUrl = [string]$cfg.watchIntake.csvUrl
if ($csvUrl -eq '') { Write-Output 'intake: no csvUrl configured yet (see README) - skipping.'; return }

try {
    $raw = (Invoke-WebRequest -Uri $csvUrl -UseBasicParsing -TimeoutSec 60).Content
} catch {
    Write-Output ('intake: could not fetch signup sheet: ' + $_.Exception.Message)
    return
}
$rows = @($raw | ConvertFrom-Csv)
if ($rows.Count -eq 0) { Write-Output 'intake: no signups yet.'; return }

# Column order from a Google Form sheet: Timestamp, then questions in order:
# email, route, max price. Read by position so renamed questions still work.
$cols = @($rows[0].PSObject.Properties.Name)

$watchPath = Get-FwPath 'watches.json'
$existing = @{ watches = @() }
if (Test-Path $watchPath) {
    $existing = Get-Content -Raw -Encoding UTF8 $watchPath | ConvertFrom-Json
}
$list = New-Object System.Collections.ArrayList
$seen = @{}
foreach ($w in @($existing.watches)) {
    [void]$list.Add($w)
    $key = ((@($w.to) -join ',') + '|' + $w.route).ToLower()
    $seen[$key] = $true
}

$added = 0
foreach ($row in $rows) {
    $email = ([string]$row.($cols[1])).Trim()
    $route = ([string]$row.($cols[2])).Trim().ToUpper()
    $maxRaw = ''
    if ($cols.Count -gt 3) { $maxRaw = ([string]$row.($cols[3])).Trim() -replace '[^0-9.]', '' }
    if ($email -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') { continue }
    if ($route -ne 'ANY' -and $route -notmatch '^[A-Z]{3}-[A-Z]{3}$') { continue }
    $maxGw = 100.0
    if ($maxRaw -ne '') {
        try { $maxGw = [Math]::Max(20.0, [Math]::Min(500.0, [double]$maxRaw)) } catch { }
    }
    $key = ($email + '|' + $route).ToLower()
    if ($seen.ContainsKey($key)) { continue }
    $seen[$key] = $true
    [void]$list.Add(@{ route = $route; maxGw = $maxGw; to = @($email); source = 'website'; added = (Get-Date -Format 'yyyy-MM-dd') })
    $added++
}

if ($added -gt 0) {
    Write-FwUtf8 $watchPath (@{ watches = @($list) } | ConvertTo-Json -Depth 5)
    Write-Output ('intake: added {0} new watch(es) from the website ({1} total).' -f $added, $list.Count)
} else {
    Write-Output ('intake: no new signups ({0} watches active).' -f $list.Count)
}
