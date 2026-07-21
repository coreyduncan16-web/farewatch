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
$secrets = Read-FwEnv
$watchPath = Get-FwPath 'watches.json'
$existing = @{ watches = @() }
if (Test-Path $watchPath) {
    $existing = Get-Content -Raw -Encoding UTF8 $watchPath | ConvertFrom-Json
}
$list = New-Object System.Collections.ArrayList
$seen = @{}
foreach ($w in @($existing.watches)) {
    [void]$list.Add($w)
    $df = ''; $dt = ''
    if ($w.PSObject.Properties['dateFrom']) { $df = [string]$w.dateFrom }
    if ($w.PSObject.Properties['dateTo']) { $dt = [string]$w.dateTo }
    $key = ((@($w.to) -join ',') + '|' + $w.route + '|' + $df + '|' + $dt).ToLower()
    $seen[$key] = $true
}

$added = 0
function Add-Watch([string]$email, [string]$route, [string]$maxRaw, [string]$dateFrom = '', [string]$dateTo = '') {
    $email = $email.Trim(); $route = $route.Trim().ToUpper()
    if ($email -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') { return }
    if ($route -ne 'ANY' -and $route -notmatch '^[A-Z]{3}-[A-Z]{3}$') { return }
    $maxGw = 100.0
    $maxRaw = ([string]$maxRaw) -replace '[^0-9.]', ''
    if ($maxRaw -ne '') {
        try { $maxGw = [Math]::Max(20.0, [Math]::Min(500.0, [double]$maxRaw)) } catch { }
    }
    if ($dateFrom -notmatch '^\d{4}-\d{2}-\d{2}$') { $dateFrom = '' }
    if ($dateTo -notmatch '^\d{4}-\d{2}-\d{2}$') { $dateTo = '' }
    $key = ($email + '|' + $route + '|' + $dateFrom + '|' + $dateTo).ToLower()
    if ($seen.ContainsKey($key)) { return }
    $seen[$key] = $true
    $w = @{ route = $route; maxGw = $maxGw; to = @($email); source = 'website'; added = (Get-Date -Format 'yyyy-MM-dd') }
    if ($dateFrom -ne '') { $w.dateFrom = $dateFrom }
    if ($dateTo -ne '') { $w.dateTo = $dateTo }
    [void]$list.Add($w)
    $script:added++
}

# --- source 1: Netlify form submissions (watch + recheck + unsub), zero setup ---
$rechecks = New-Object System.Collections.ArrayList
$unsubEmails = @{}
$nToken = $secrets['NETLIFY_TOKEN']; $nSite = $secrets['NETLIFY_SITE_ID']
if ($nToken -and $nSite) {
    try {
        $auth = @{ Authorization = 'Bearer ' + $nToken }
        $subs = @(Invoke-RestMethod -Uri ('https://api.netlify.com/api/v1/sites/{0}/submissions' -f $nSite) -Headers $auth -TimeoutSec 60)
        # PS 5.1 sometimes hands the JSON array back nested one level deep - flatten it
        while ($subs.Count -eq 1 -and $subs[0] -is [System.Array]) { $subs = @($subs[0]) }
        foreach ($s in $subs) {
            $formName = [string]$s.form_name
            if ($formName -eq 'watch') {
                $df = ''; $dt = ''
                if ($s.data.PSObject.Properties['datefrom']) { $df = [string]$s.data.datefrom }
                if ($s.data.PSObject.Properties['dateto']) { $dt = [string]$s.data.dateto }
                Add-Watch ([string]$s.data.email) ([string]$s.data.route) ([string]$s.data.maxprice) $df $dt
            } elseif ($formName -eq 'recheck') {
                $rt = ([string]$s.data.route).Trim().ToUpper()
                if ($rt -match '^[A-Z]{3}-[A-Z]{3}$') {
                    [void]$rechecks.Add(@{ route = $rt; date = ([string]$s.data.date).Trim(); added = (Get-Date -Format 's') })
                }
            } elseif ($formName -eq 'unsub') {
                $ue = ([string]$s.data.email).Trim().ToLower()
                if ($ue -match '^[^@\s]+@[^@\s]+\.[^@\s]+$') { $unsubEmails[$ue] = $true }
            }
            # processed - delete so it is not ingested twice
            try { Invoke-RestMethod -Method Delete -Uri ('https://api.netlify.com/api/v1/submissions/{0}' -f $s.id) -Headers $auth -TimeoutSec 60 | Out-Null } catch { }
        }
        if ($subs.Count -gt 0) { Write-Output ('intake: processed {0} website submission(s) from Netlify.' -f $subs.Count) }
    } catch {
        Write-Output ('intake: Netlify submissions check failed: ' + $_.Exception.Message)
    }
}

# --- source 2: Google Form responses (unlimited free intake, no Netlify) ---
# Published-CSV columns, in order: Timestamp, Email, Route, Max price,
# Travel from, Travel to. Row meaning is inferred:
#   * a valid Email  -> a price-alert signup (watch)
#   * blank Email + valid Route -> a search-triggered fresh-sweep (recheck)
#   * Route = UNSUB (with Email) -> unsubscribe that email
# A row-count cursor (data\intake-cursor.txt) means each response is acted on
# once even though the sheet keeps every response forever.
$csvUrl = [string]$cfg.watchIntake.csvUrl
if ($csvUrl -ne '') {
    try {
        $raw = (Invoke-WebRequest -Uri $csvUrl -UseBasicParsing -TimeoutSec 60).Content
        $rows = @($raw | ConvertFrom-Csv)
        $cursorPath = Get-FwPath 'data\intake-cursor.txt'
        $startAt = 0
        if (Test-Path $cursorPath) { try { $startAt = [int](Get-Content -Raw $cursorPath) } catch { $startAt = 0 } }
        if ($rows.Count -lt $startAt) { $startAt = 0 }   # sheet shrank/reset
        if ($rows.Count -gt 0) {
            $cols = @($rows[0].PSObject.Properties.Name)
            for ($ri = $startAt; $ri -lt $rows.Count; $ri++) {
                $row = $rows[$ri]
                $email = if ($cols.Count -gt 1) { ([string]$row.($cols[1])).Trim() } else { '' }
                $route = if ($cols.Count -gt 2) { ([string]$row.($cols[2])).Trim().ToUpper() } else { '' }
                $maxRaw = if ($cols.Count -gt 3) { [string]$row.($cols[3]) } else { '' }
                $df = if ($cols.Count -gt 4) { [string]$row.($cols[4]) } else { '' }
                $dt = if ($cols.Count -gt 5) { [string]$row.($cols[5]) } else { '' }
                if ($route -eq 'UNSUB' -and $email -match '^[^@\s]+@[^@\s]+\.[^@\s]+$') {
                    $unsubEmails[$email.ToLower()] = $true
                } elseif ($email -match '^[^@\s]+@[^@\s]+\.[^@\s]+$') {
                    Add-Watch $email $route $maxRaw $df $dt
                } elseif ($route -match '^[A-Z]{3}-[A-Z]{3}$') {
                    [void]$rechecks.Add(@{ route = $route; date = ''; added = (Get-Date -Format 's') })
                }
            }
        }
        Write-FwUtf8 $cursorPath ([string]$rows.Count)
    } catch {
        Write-Output ('intake: could not fetch Google Form responses: ' + $_.Exception.Message)
    }
}

# apply unsubscribes: drop the email from each watch's recipients; if a watch
# has no recipients left, remove it entirely
$removed = 0
if ($unsubEmails.Count -gt 0) {
    $kept = New-Object System.Collections.ArrayList
    foreach ($w in @($list)) {
        $newTo = @(@($w.to) | Where-Object { -not $unsubEmails.ContainsKey(([string]$_).Trim().ToLower()) })
        if ($newTo.Count -eq 0) { $removed++; continue }
        if ($newTo.Count -ne @($w.to).Count) { $removed++; $w.to = $newTo }
        [void]$kept.Add($w)
    }
    $list = $kept
    Write-Output ('intake: {0} unsubscribe(s) processed for {1} email(s).' -f $removed, $unsubEmails.Count)
}

if ($added -gt 0 -or $removed -gt 0) {
    Write-FwUtf8 $watchPath (@{ watches = @($list) } | ConvertTo-Json -Depth 5)
}
if ($rechecks.Count -gt 0) {
    # merge with any pending rechecks
    Ensure-FwDataDir
    $rcPath = Get-FwPath 'data\recheck.json'
    $pending = New-Object System.Collections.ArrayList
    if (Test-Path $rcPath) {
        foreach ($p in @((Get-Content -Raw -Encoding UTF8 $rcPath | ConvertFrom-Json))) { [void]$pending.Add($p) }
    }
    foreach ($r in $rechecks) { [void]$pending.Add($r) }
    Write-FwUtf8 $rcPath (ConvertTo-Json @($pending) -Depth 4 -Compress)
    Write-Output ('intake: {0} fresh-check request(s) queued.' -f $rechecks.Count)

    # promote searched routes into the daily rotation for the next 14 days
    $extrasPath = Get-FwPath 'data\routes-extra.json'
    $extras = @{}
    if (Test-Path $extrasPath) {
        $ex = Get-Content -Raw -Encoding UTF8 $extrasPath | ConvertFrom-Json
        foreach ($p in $ex.PSObject.Properties) { $extras[$p.Name] = [string]$p.Value }
    }
    $todayStr = Get-Date -Format 'yyyy-MM-dd'
    foreach ($r in $rechecks) { $extras[[string]$r.route] = $todayStr }
    Write-FwUtf8 $extrasPath ($extras | ConvertTo-Json -Compress)
}
Write-Output ('intake: {0} new watch(es); {1} watches active.' -f $added, $list.Count)
