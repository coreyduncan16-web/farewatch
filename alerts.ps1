# FareWatch alerts: after a sweep, compare today's GoWild pass fares against
# each route's own trailing average and your watch rules, then email/text.
#
# Watches live in watches.json (copy watches.example.json). Each watch:
#   route   "MCO-PUJ" or "ANY"
#   maxGw   (optional) alert when the GoWild all-in total is at or under this
#   dropPct (optional) alert when it is this % under the route's trailing
#           average GoWild fare (needs a few days of sweep history)
#   to      list of recipients. Texts work via carrier email-to-SMS gateways,
#           e.g. 5551234567@vtext.com (Verizon), @txt.att.net (AT&T),
#           @tmomail.net (T-Mobile).
#
# Email is sent with the SMTP_* settings in .env (see .env.example). With no
# SMTP config (or with -Test), alerts print to the console and append to
# data\alerts-log.txt instead of sending.
#
# GoWild fares only - cash fares never trigger an alert.
# Windows PowerShell 5.1 compatible. Keep this file ASCII-only.

[CmdletBinding()]
param([switch]$Test, [switch]$TestEmail)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

# .\alerts.ps1 -TestEmail  ->  sends one test message so you know SMTP works
if ($TestEmail) {
    $secrets = Read-FwEnv
    if (-not ($secrets['SMTP_HOST'] -and $secrets['SMTP_USER'] -and $secrets['SMTP_PASS'] -and $secrets['SMTP_FROM'])) {
        Write-Output 'TEST FAILED: SMTP settings missing from .env (need SMTP_HOST, SMTP_USER, SMTP_PASS, SMTP_FROM - see .env.example).'
        return
    }
    $port = 587
    if ($secrets['SMTP_PORT']) { $port = [int]$secrets['SMTP_PORT'] }
    $sec = ConvertTo-SecureString $secrets['SMTP_PASS'] -AsPlainText -Force
    $cred = New-Object System.Management.Automation.PSCredential($secrets['SMTP_USER'], $sec)
    try {
        Send-MailMessage -SmtpServer $secrets['SMTP_HOST'] -Port $port -UseSsl -Credential $cred `
            -From $secrets['SMTP_FROM'] -To $secrets['SMTP_FROM'] `
            -Subject 'FareWatch test - your alerts are working' `
            -Body 'This is the FareWatch email test. If you are reading this, price alerts will send just fine.'
        Write-Output ('TEST PASSED: test email sent to {0} - check the inbox.' -f $secrets['SMTP_FROM'])
    } catch {
        Write-Output ('TEST FAILED: ' + $_.Exception.Message)
        Write-Output 'Gmail users: make sure SMTP_PASS is an App Password (myaccount.google.com/apppasswords), not your normal password.'
    }
    return
}

$watchPath = Get-FwPath 'watches.json'
if (-not (Test-Path $watchPath)) { Write-Output 'alerts: no watches.json, nothing to do.'; return }
$wcfg = Get-Content -Raw -Encoding UTF8 $watchPath | ConvertFrom-Json
$watches = @($wcfg.watches)
if ($watches.Count -eq 0) { Write-Output 'alerts: watches.json has no watches.'; return }

$secrets = Read-FwEnv
$hist = Read-FwHistory
$today = (Get-Date).Date
$todayStr = $today.ToString('yyyy-MM-dd')

# trailing average GoWild fare per route, across every observation ever made
$gwSum = @{}; $gwCnt = @{}
foreach ($key in $hist.Keys) {
    $route = $key.Split('|')[0]
    foreach ($o in $hist[$key]) {
        if ($o.ContainsKey('g') -and $o.g -gt 0) {
            $gwSum[$route] = [double]($gwSum[$route]) + [double]$o.g
            $gwCnt[$route] = [int]($gwCnt[$route]) + 1
        }
    }
}

# today's GoWild candidates: fresh observation, departure not in the past
$cands = New-Object System.Collections.ArrayList
foreach ($key in $hist.Keys) {
    $parts = $key.Split('|')
    $dep = [datetime]::ParseExact($parts[1], 'yyyy-MM-dd', $null)
    if ($dep -lt $today) { continue }
    $obs = $hist[$key]
    $last = $obs[$obs.Count - 1]
    if ([string]$last.d -ne $todayStr) { continue }
    if (-not $last.ContainsKey('g') -or $last.g -le 0) { continue }
    [void]$cands.Add(@{ key = $key; route = $parts[0]; depStr = $parts[1]; g = [double]$last.g; gc = [int]$last.gc; fc = [int]$last.fc })
}
if ($cands.Count -eq 0) { Write-Output 'alerts: no fresh GoWild fares today.'; return }

# anti-respam ledger: watch|route-date -> lowest price already alerted
$sentPath = Get-FwPath 'data\alerts-sent.json'
$sent = @{}
if (Test-Path $sentPath) {
    $sj = Get-Content -Raw -Encoding UTF8 $sentPath | ConvertFrom-Json
    foreach ($p in $sj.PSObject.Properties) { $sent[$p.Name] = [double]$p.Value }
}

$MONTHS = @('Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec')
function LiveLink($route, $depStr) {
    $o = $route.Split('-')[0]; $d = $route.Split('-')[1]
    $p = $depStr.Split('-')
    $dd = [uri]::EscapeDataString(('{0} {1}, {2}' -f $MONTHS[[int]$p[1] - 1], [int]$p[2], $p[0]))
    'https://booking.flyfrontier.com/Flight/InternalSelect?s=true&o1={0}&d1={1}&dd1={2}&ADT=1&mon=true' -f $o, $d, $dd
}

$queued = @{}   # recipient-list-key -> ArrayList of lines
$queuedTo = @{}
$wIdx = 0
foreach ($w in $watches) {
    $wIdx++
    $wRoute = ([string]$w.route).ToUpper()
    $hasMax = ($null -ne $w.PSObject.Properties['maxGw'] -and $null -ne $w.maxGw)
    $hasDrop = ($null -ne $w.PSObject.Properties['dropPct'] -and $null -ne $w.dropPct)
    $wFrom = ''; $wTo = ''
    if ($w.PSObject.Properties['dateFrom']) { $wFrom = [string]$w.dateFrom }
    if ($w.PSObject.Properties['dateTo']) { $wTo = [string]$w.dateTo }
    foreach ($c in $cands) {
        if ($wRoute -ne 'ANY' -and $wRoute -ne $c.route) { continue }
        # only alert on departures inside the watcher's travel date range
        if ($wFrom -ne '' -and $c.depStr -lt $wFrom) { continue }
        if ($wTo -ne '' -and $c.depStr -gt $wTo) { continue }
        $reasons = @()
        if ($hasMax -and $c.g -le [double]$w.maxGw) {
            $reasons += ('at/under your ${0} cap' -f [double]$w.maxGw)
        }
        if ($hasDrop -and $gwCnt.ContainsKey($c.route) -and $gwCnt[$c.route] -ge 5) {
            $avg = [Math]::Round($gwSum[$c.route] / $gwCnt[$c.route], 2)
            $threshold = $avg * (1 - [double]$w.dropPct / 100)
            if ($c.g -le $threshold) {
                $reasons += ('{0}% under this route''s trailing avg of ${1}' -f [double]$w.dropPct, $avg)
            }
        }
        if ($reasons.Count -eq 0) { continue }
        $ledgerKey = ('{0}|{1}' -f $wIdx, $c.key)
        if ($sent.ContainsKey($ledgerKey) -and $sent[$ledgerKey] -le $c.g) { continue }
        $sent[$ledgerKey] = $c.g
        $toKey = (@($w.to) -join ';')
        if (-not $queued.ContainsKey($toKey)) {
            $queued[$toKey] = New-Object System.Collections.ArrayList
            $queuedTo[$toKey] = @($w.to)
        }
        [void]$queued[$toKey].Add(('GoWild {0} on {1}: ${2} all-in ({3} of {4} flights) - {5}' -f $c.route.Replace('-', ' -> '), $c.depStr, $c.g, $c.gc, $c.fc, ($reasons -join '; ')))
        [void]$queued[$toKey].Add(('  book: {0}' -f (LiveLink $c.route $c.depStr)))
    }
}

if ($queued.Keys.Count -eq 0) { Write-Output 'alerts: nothing triggered.'; return }

$smtpReady = ($secrets['SMTP_HOST'] -and $secrets['SMTP_USER'] -and $secrets['SMTP_PASS'] -and $secrets['SMTP_FROM'])
$unsubBase = 'https://frontierflight.netlify.app/unsub.html'
if ($secrets['SITE_URL']) { $unsubBase = ([string]$secrets['SITE_URL']).TrimEnd('/') + '/unsub.html' }
Ensure-FwDataDir
foreach ($toKey in $queued.Keys) {
    $unsubEmail = @($queuedTo[$toKey])[0]
    $unsubLink = $unsubBase + '?e=' + [uri]::EscapeDataString([string]$unsubEmail)
    $body = "FareWatch GoWild alert - " + $todayStr + "`r`n`r`n" + (($queued[$toKey]) -join "`r`n") +
        "`r`n`r`nPass inventory moves fast; a shown seat is not a hold." +
        "`r`n`r`n----`r`nStop these alerts (unsubscribe): " + $unsubLink
    $subject = ('FareWatch: {0} GoWild fare drop(s)' -f ($queued[$toKey].Count / 2))
    if ($Test -or -not $smtpReady) {
        $why = 'TEST MODE'
        if (-not $smtpReady) { $why = 'no SMTP settings in .env' }
        Write-Output ('--- alert for {0} ({1}) ---' -f $toKey, $why)
        Write-Output $body
        Add-Content -Path (Get-FwPath 'data\alerts-log.txt') -Value ("[{0}] to={1}`r`n{2}`r`n" -f (Get-Date), $toKey, $body) -Encoding UTF8
    } else {
        $port = 587
        if ($secrets['SMTP_PORT']) { $port = [int]$secrets['SMTP_PORT'] }
        $sec = ConvertTo-SecureString $secrets['SMTP_PASS'] -AsPlainText -Force
        $cred = New-Object System.Management.Automation.PSCredential($secrets['SMTP_USER'], $sec)
        try {
            Send-MailMessage -SmtpServer $secrets['SMTP_HOST'] -Port $port -UseSsl `
                -Credential $cred -From $secrets['SMTP_FROM'] -To $queuedTo[$toKey] `
                -Subject $subject -Body $body
            Write-Output ('alerts: sent to {0}' -f $toKey)
        } catch {
            Write-Output ('alerts: SEND FAILED to {0}: {1}' -f $toKey, $_.Exception.Message)
            Add-Content -Path (Get-FwPath 'data\alerts-log.txt') -Value ("[{0}] SEND FAILED to={1}: {2}`r`n{3}`r`n" -f (Get-Date), $toKey, $_.Exception.Message, $body) -Encoding UTF8
        }
    }
}

# persist the ledger only when we actually alerted (or logged)
if (-not $Test) {
    Write-FwUtf8 $sentPath ($sent | ConvertTo-Json -Compress)
}
