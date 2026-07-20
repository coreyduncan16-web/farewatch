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

# --- source 1: Netlify form submissions (watch + recheck), zero setup ---
$rechecks = New-Object System.Collections.ArrayList
$nToken = $secrets['NETLIFY_TOKEN']; $nSite = $secrets['NETLIFY_SITE_ID']
if ($nToken -and $nSite) {
    try {
        $auth = @{ Authorization = 'Bearer ' + $nToken }
        $subs = @(Invoke-RestMethod -Uri ('https://api.netlify.com/api/v1/sites/{0}/submissions?per_page=100' -f $nSite) -Headers $auth -TimeoutSec 60)
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
            }
            # processed - delete so it is not ingested twice
            try { Invoke-RestMethod -Method Delete -Uri ('https://api.netlify.com/api/v1/submissions/{0}' -f $s.id) -Headers $auth -TimeoutSec 60 | Out-Null } catch { }
        }
        if ($subs.Count -gt 0) { Write-Output ('intake: processed {0} website submission(s) from Netlify.' -f $subs.Count) }
    } catch {
        Write-Output ('intake: Netlify submissions check failed: ' + $_.Exception.Message)
    }
}

# --- source 2: optional Google Form CSV (legacy path, if configured) ---
$csvUrl = [string]$cfg.watchIntake.csvUrl
if ($csvUrl -ne '') {
    try {
        $raw = (Invoke-WebRequest -Uri $csvUrl -UseBasicParsing -TimeoutSec 60).Content
        $rows = @($raw | ConvertFrom-Csv)
        if ($rows.Count -gt 0) {
            $cols = @($rows[0].PSObject.Properties.Name)
            foreach ($row in $rows) {
                $maxRaw = ''
                if ($cols.Count -gt 3) { $maxRaw = [string]$row.($cols[3]) }
                Add-Watch ([string]$row.($cols[1])) ([string]$row.($cols[2])) $maxRaw
            }
        }
    } catch {
        Write-Output ('intake: could not fetch signup sheet: ' + $_.Exception.Message)
    }
}

if ($added -gt 0) {
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
}
Write-Output ('intake: {0} new watch(es); {1} watches active.' -f $added, $list.Count)
