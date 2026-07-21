# FareWatch sweep: fetch Frontier (F9) one-way fares for configured route-dates,
# append them to the local price history, then re-render dashboard.html.
#
#   .\sweep.ps1                  normal budgeted sweep with the configured provider
#   .\sweep.ps1 -Demo            fill history with synthetic data (no API key needed)
#   .\sweep.ps1 -VerifyCoverage  spend ~2 API calls to check the provider returns F9 fares
#   .\sweep.ps1 -MaxCalls 20     cap this run's API calls
#
# Windows PowerShell 5.1 compatible. Keep this file ASCII-only.

[CmdletBinding()]
param(
    [switch]$Demo,
    [switch]$VerifyCoverage,
    [int]$MaxCalls = 0,
    [string]$Provider = '',
    [switch]$NoRender
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$cfg     = Read-FwConfig
$secrets = Read-FwEnv
$today   = (Get-Date).Date
$todayStr = $today.ToString('yyyy-MM-dd')
if ($Provider -eq '') { $Provider = [string]$cfg.provider }

# How long a route-date's price stays "fresh" before it is eligible to be
# re-swept. Lower this (e.g. 1) to let hourly runs refresh prices intra-day;
# leave it near 24 for a once-a-day sweep. Absent from older configs -> 20h.
$minRefreshHours = 20.0
if ($cfg.PSObject.Properties['minRefreshHours']) { $minRefreshHours = [double]$cfg.minRefreshHours }

# ---------------------------------------------------------------- providers --

$script:AmadeusToken = $null
$script:QuotaExhausted = $false
# Set by Get-Observation to the per-departure snapshot for the route-date it just
# priced (frontier provider only); the sweep loop reads it into the deps store.
$script:CurrentDeps = $null

# Aggregates one route-date from flyfrontier.com (via Get-FrontierFlightData
# in common.ps1). Returns @{ cash; gw; gwCount; flightCount; gwNonstop } or
# $null when the route does not fly that day.
function Get-FrontierFares([string]$o, [string]$d, [datetime]$dep) {
    $flights = Get-FrontierFlightData $o $d $dep
    if ($script:FwBlocked) { $script:QuotaExhausted = $true }
    if ($null -eq $flights) { return $null }
    $cash = $null; $gw = $null; $gwCount = 0; $gwNonstop = 0
    foreach ($f in $flights) {
        if ($f.cash -gt 0 -and ($null -eq $cash -or $f.cash -lt $cash)) { $cash = $f.cash }
        if ($f.gwOn -and $f.gw -gt 0) {
            $gwCount++
            if ($f.stops -eq 0) { $gwNonstop = 1 }
            if ($null -eq $gw -or $f.gw -lt $gw) { $gw = $f.gw }
        }
    }
    if ($null -eq $cash) { return $null }
    @{ cash = $cash; gw = $gw; gwCount = $gwCount; flightCount = @($flights).Count; gwNonstop = $gwNonstop; flights = $flights }
}

function Get-AmadeusBase {
    if ([string]$cfg.amadeusEnvironment -eq 'production') { 'https://api.amadeus.com' }
    else { 'https://test.api.amadeus.com' }
}

function Get-AmadeusToken {
    if ($script:AmadeusToken) { return $script:AmadeusToken }
    $id = $secrets['AMADEUS_CLIENT_ID']; $sec = $secrets['AMADEUS_CLIENT_SECRET']
    if (-not $id -or -not $sec) {
        throw 'AMADEUS_CLIENT_ID / AMADEUS_CLIENT_SECRET missing. Copy .env.example to .env and paste your keys (see README).'
    }
    $r = Invoke-RestMethod -Method Post -Uri ((Get-AmadeusBase) + '/v1/security/oauth2/token') `
        -ContentType 'application/x-www-form-urlencoded' `
        -Body @{ grant_type = 'client_credentials'; client_id = $id; client_secret = $sec }
    $script:AmadeusToken = [string]$r.access_token
    $script:AmadeusToken
}

function Get-HttpStatus($err) {
    try { return [int]$err.Exception.Response.StatusCode } catch { return 0 }
}

# Returns cheapest F9 grand total in USD, or $null when no offer / bad request.
function Get-AmadeusFare([string]$o, [string]$d, [string]$date) {
    $tok = Get-AmadeusToken
    $uri = (Get-AmadeusBase) + '/v2/shopping/flight-offers' +
        ('?originLocationCode={0}&destinationLocationCode={1}&departureDate={2}' -f $o, $d, $date) +
        '&adults=1&currencyCode=USD&includedAirlineCodes=F9&max=3'
    try {
        $r = Invoke-RestMethod -Method Get -Uri $uri -Headers @{ Authorization = 'Bearer ' + $tok }
    } catch {
        $status = Get-HttpStatus $_
        if ($status -eq 429) { $script:QuotaExhausted = $true; return $null }
        if ($status -eq 400 -or $status -eq 404) { return $null }
        throw
    }
    $best = $null
    if ($r.PSObject.Properties['data']) {
        foreach ($offer in @($r.data)) {
            $p = [double]$offer.price.grandTotal
            if ($null -eq $best -or $p -lt $best) { $best = $p }
        }
    }
    $best
}

function Get-SerpApiFare([string]$o, [string]$d, [string]$date) {
    $k = $secrets['SERPAPI_KEY']
    if (-not $k) { throw 'SERPAPI_KEY missing from .env (see README).' }
    $uri = 'https://serpapi.com/search.json?engine=google_flights' +
        ('&departure_id={0}&arrival_id={1}&outbound_date={2}' -f $o, $d, $date) +
        '&type=2&currency=USD&include_airlines=F9&api_key=' + $k
    try {
        $r = Invoke-RestMethod -Method Get -Uri $uri
    } catch {
        $status = Get-HttpStatus $_
        if ($status -eq 429) { $script:QuotaExhausted = $true; return $null }
        if ($status -eq 400 -or $status -eq 404) { return $null }
        throw
    }
    $best = $null
    foreach ($group in @('best_flights', 'other_flights')) {
        if ($r.PSObject.Properties[$group]) {
            foreach ($f in @($r.$group)) {
                if ($f.PSObject.Properties['price']) {
                    $p = [double]$f.price
                    if ($null -eq $best -or $p -lt $best) { $best = $p }
                }
            }
        }
    }
    $best
}

function Get-Fare([string]$o, [string]$d, [string]$date) {
    if ($Provider -eq 'serpapi') { Get-SerpApiFare $o $d $date }
    else { Get-AmadeusFare $o $d $date }
}

# One observation for a route-date, shaped for the history store.
function Get-Observation($rd) {
    $script:CurrentDeps = $null
    if ($Provider -eq 'frontier') {
        $f = Get-FrontierFares $rd.o $rd.d $rd.dep
        Start-Sleep -Milliseconds ([int]$cfg.frontierSleepMs)
        if ($null -eq $f) { return $null }
        $g = -1.0
        if ($null -ne $f.gw) { $g = [Math]::Round([double]$f.gw, 2) }
        # Snapshot every departure for the cheapest-first board (latest only).
        $deps = New-Object System.Collections.ArrayList
        foreach ($fl in @($f.flights)) {
            $fgw = -1.0
            if ($fl.gwOn -and [double]$fl.gw -gt 0) { $fgw = [Math]::Round([double]$fl.gw, 2) }
            [void]$deps.Add(@{
                dt   = ([datetime]$fl.depTime).ToString('yyyy-MM-ddTHH:mm:ss')
                at   = ([datetime]$fl.arrTime).ToString('yyyy-MM-ddTHH:mm:ss')
                s    = [int]$fl.stops
                fn   = [string]$fl.flightNums
                cash = [Math]::Round([double]$fl.cash, 0)
                gw   = $fgw
                gwOn = [bool]$fl.gwOn
            })
        }
        $script:CurrentDeps = @($deps)
        return @{
            p = [Math]::Round([double]$f.cash, 0)
            g = $g; gc = [int]$f.gwCount; fc = [int]$f.flightCount; gn = [int]$f.gwNonstop
        }
    }
    $price = Get-Fare $rd.o $rd.d ($rd.dep.ToString('yyyy-MM-dd'))
    if ($null -eq $price) { return $null }
    @{ p = [Math]::Round([double]$price, 0) }
}

# ---------------------------------------------------------- coverage check --

if ($VerifyCoverage) {
    $probeDate = $today.AddDays(30).ToString('yyyy-MM-dd')
    Write-Output ('Coverage check: {0} ATL -> CUN on {1}' -f $Provider, $probeDate)
    if ($Provider -eq 'frontier') {
        $probe = @($cfg.origins)[0]; $dest = @($cfg.destinations)[0]
        $dep = $today.AddDays(2)
        $f = Get-FrontierFares $probe $dest $dep
        if ($null -eq $f) {
            Write-Output ('No flights returned for {0} -> {1} on {2}; trying +1 day...' -f $probe, $dest, $dep.ToString('yyyy-MM-dd'))
            $dep = $today.AddDays(3)
            $f = Get-FrontierFares $probe $dest $dep
        }
        if ($null -eq $f) {
            Write-Output 'FAIL - no fare data from flyfrontier.com (blocked or no service). Try again later or switch provider in config.json.'
        } else {
            Write-Output ('PASS - {0} -> {1} {2}: cheapest cash ${3}; {4} of {5} flights have GoWild pass seats' -f $probe, $dest, $dep.ToString('yyyy-MM-dd'), $f.cash, $f.gwCount, $f.flightCount)
            if ($null -ne $f.gw) { Write-Output ('       cheapest GoWild all-in total: ${0}' -f $f.gw) }
            Write-Output 'No API key needed for this provider.'
        }
        return
    }
    if ($Provider -eq 'serpapi') {
        $p = Get-SerpApiFare 'ATL' 'CUN' $probeDate
        if ($null -ne $p) { Write-Output ('PASS - Frontier fare found: ${0}' -f $p) }
        else { Write-Output 'FAIL - no Frontier fare returned. Google Flights normally lists F9; re-check the key and date.' }
        return
    }
    $tok = Get-AmadeusToken
    $base = Get-AmadeusBase
    $uriAll = $base + '/v2/shopping/flight-offers?originLocationCode=ATL&destinationLocationCode=CUN' +
        ('&departureDate={0}&adults=1&currencyCode=USD&max=20' -f $probeDate)
    $rAll = Invoke-RestMethod -Method Get -Uri $uriAll -Headers @{ Authorization = 'Bearer ' + $tok }
    $carriers = @()
    if ($rAll.PSObject.Properties['data']) {
        $carriers = @($rAll.data | ForEach-Object { $_.validatingAirlineCodes } | ForEach-Object { $_ }) |
            Sort-Object -Unique
    }
    Write-Output ('Carriers returned on this route: ' + ($carriers -join ', '))
    $f9 = Get-AmadeusFare 'ATL' 'CUN' $probeDate
    if ($null -ne $f9) {
        Write-Output ('PASS - Frontier (F9) is covered. Cheapest F9 fare: ${0}' -f $f9)
        Write-Output 'You are good to run .\sweep.ps1 daily with this provider.'
    } else {
        Write-Output 'FAIL - no Frontier (F9) offers from Amadeus in this environment.'
        Write-Output 'Options: set "amadeusEnvironment": "production" in config.json (free quota still applies),'
        Write-Output 'or switch to the SerpAPI fallback: set "provider": "serpapi" and add SERPAPI_KEY to .env.'
    }
    return
}

# ------------------------------------------------------------------- sweep --

$hist = Read-FwHistory

# Drop departed route-dates so the file does not grow forever.
foreach ($k in @($hist.Keys)) {
    $dep = [datetime]::ParseExact($k.Split('|')[1], 'yyyy-MM-dd', $null)
    if ($dep -lt $today) { $hist.Remove($k) }
}

$universe = New-Object System.Collections.ArrayList
foreach ($o in @($cfg.origins)) {
    foreach ($d in @($cfg.destinations)) {
        for ($i = 0; $i -lt [int]$cfg.horizonDays; $i++) {
            $dep = $today.AddDays($i)
            [void]$universe.Add(@{
                key = ('{0}-{1}|{2}' -f $o, $d, $dep.ToString('yyyy-MM-dd'))
                o = $o; d = $d; dep = $dep; daysOut = $i
            })
        }
    }
}

if ($Demo) {
    Write-Output ('Demo mode: generating synthetic history for {0} route-dates...' -f $universe.Count)
    $md5 = [System.Security.Cryptography.MD5]::Create()
    foreach ($rd in $universe) {
        $seedBytes = $md5.ComputeHash([Text.Encoding]::UTF8.GetBytes([string]$rd.key))
        $rnd = New-Object System.Random ([BitConverter]::ToInt32($seedBytes, 0) -band 0x7FFFFFFF)
        $base = 130 + $rnd.Next(0, 170)
        $nObs = 8 + $rnd.Next(0, 26)
        $price = [double]$base * (0.85 + 0.3 * $rnd.NextDouble())
        $list = New-Object System.Collections.ArrayList
        for ($j = $nObs - 1; $j -ge 0; $j--) {
            $sweepDay = $today.AddDays(-$j)
            $price = [Math]::Max(59.0, $price * (0.92 + 0.16 * $rnd.NextDouble()))
            $rec = @{ d = $sweepDay.ToString('yyyy-MM-dd'); p = [Math]::Round($price, 0) }
            # inside the GoWild window, fake pass-fare data on the latest sweep
            if ($j -eq 0 -and $rd.daysOut -le [int]$cfg.goWildWindowDays) {
                $fc = 3 + $rnd.Next(0, 12)
                $gc = [Math]::Max(0, $rnd.Next(-3, $fc + 1))
                $rec.fc = $fc; $rec.gc = $gc
                if ($gc -gt 0) {
                    $rec.g = [Math]::Round(25 + 110 * $rnd.NextDouble(), 2)
                    $rec.gn = $rnd.Next(0, 2)
                } else { $rec.g = -1; $rec.gn = 0 }
            }
            [void]$list.Add($rec)
        }
        $hist[$rd.key] = $list
    }
    Save-FwHistory $hist
    Save-FwMeta @{ lastSweepUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'); provider = 'demo'; note = '' }
    Write-Output 'Demo history written.'
} else {
    $usage = Read-FwUsage

    # Latest per-departure snapshot store (frontier only), pruned of past dates.
    $depStore = @{}
    if ($Provider -eq 'frontier') {
        $depStore = Read-FwDepartures
        foreach ($k in @($depStore.Keys)) {
            $dep = [datetime]::ParseExact($k.Split('|')[1], 'yyyy-MM-dd', $null)
            if ($dep -lt $today) { $depStore.Remove($k) }
        }
    }

    $budget = [int]$cfg.apiCallsPerRun
    if ($MaxCalls -gt 0) { $budget = $MaxCalls }
    # The frontier provider scrapes the public site (no paid quota), so only the
    # per-run cap and frontierSleepMs throttle it - the monthly budget would
    # otherwise choke off hourly refreshes after roughly a day. Paid API
    # providers still honour the monthly budget.
    if ($Provider -ne 'frontier') {
        $monthlyRemaining = [int]$cfg.apiMonthlyBudget - [int]$usage.calls
        if ($budget -gt $monthlyRemaining) { $budget = $monthlyRemaining }
        if ($budget -le 0) {
            Write-Output ('Monthly API budget exhausted ({0}/{1}). Rendering from existing history only.' -f $usage.calls, $cfg.apiMonthlyBudget)
        }
    }

    # Prioritise: stalest first, with big bonuses for the GoWild window and
    # for imminent departures / the release-day edge.
    $window = [int]$cfg.goWildWindowDays
    $nowLocal = Get-Date
    $candidates = New-Object System.Collections.ArrayList
    foreach ($rd in $universe) {
        # Hours since this route-date was last priced. Never-seen route-dates
        # sort to the very top; the 't' timestamp (added below) gives intra-day
        # resolution, older date-only records fall back to that day's midnight.
        $staleHours = 1000000.0
        if ($hist.ContainsKey($rd.key)) {
            $obs = $hist[$rd.key]
            if ($obs.Count -gt 0) {
                $last = $obs[$obs.Count - 1]
                $lastTime = $null
                if ($last.ContainsKey('t') -and [string]$last.t -ne '') {
                    try { $lastTime = ([datetimeoffset]::Parse([string]$last.t, $script:FwInv)).LocalDateTime } catch { $lastTime = $null }
                }
                if ($null -eq $lastTime) {
                    try { $lastTime = [datetime]::ParseExact([string]$last.d, 'yyyy-MM-dd', $null) } catch { $lastTime = $null }
                }
                if ($null -ne $lastTime) { $staleHours = ($nowLocal - $lastTime).TotalHours }
            }
        }
        if ($staleHours -lt $minRefreshHours) { continue }   # refreshed recently enough
        $score = $staleHours
        if ($rd.daysOut -le $window) { $score += 500 }
        if ($rd.daysOut -le 2 -or $rd.daysOut -eq $window) { $score += 250 }
        $rd.score = $score
        [void]$candidates.Add($rd)
    }
    $planned = @($candidates | Sort-Object { $_.score } -Descending | Select-Object -First $budget)

    Write-Output ('Sweeping {0} route-dates via {1} (month usage {2}/{3})...' -f $planned.Count, $Provider, $usage.calls, $cfg.apiMonthlyBudget)
    $got = 0
    foreach ($rd in $planned) {
        if ($script:QuotaExhausted) { break }
        $newObs = Get-Observation $rd
        $usage.calls = [int]$usage.calls + 1
        if ($null -ne $newObs) {
            $newObs.d = $todayStr
            $newObs.t = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            if (-not $hist.ContainsKey($rd.key)) { $hist[$rd.key] = New-Object System.Collections.ArrayList }
            $obs = $hist[$rd.key]
            # replace any same-day observation
            for ($j = $obs.Count - 1; $j -ge 0; $j--) {
                if ([string]$obs[$j].d -eq $todayStr) { $obs.RemoveAt($j) }
            }
            [void]$obs.Add($newObs)
            while ($obs.Count -gt 90) { $obs.RemoveAt(0) }
            if ($Provider -eq 'frontier' -and $null -ne $script:CurrentDeps) {
                $depStore[$rd.key] = @{ t = $newObs.t; deps = $script:CurrentDeps }
            }
            $got++
        }
        if (($usage.calls % 10) -eq 0) {
            Save-FwHistory $hist; Save-FwUsage $usage
            if ($Provider -eq 'frontier') { Save-FwDepartures $depStore }
        }
    }
    Save-FwHistory $hist
    Save-FwUsage $usage
    if ($Provider -eq 'frontier') { Save-FwDepartures $depStore }
    $note = ''
    if ($script:QuotaExhausted) { $note = 'provider returned 429 (quota) mid-sweep' }
    Save-FwMeta @{ lastSweepUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'); provider = $Provider; note = $note }
    Write-Output ('Done: {0} fares recorded, {1} API calls used this month.' -f $got, $usage.calls)
    if ($note) { Write-Output ('NOTE: ' + $note) }
}

if (-not $NoRender) {
    & (Join-Path $PSScriptRoot 'render.ps1')
}

if (-not $Demo) {
    & (Join-Path $PSScriptRoot 'alerts.ps1')
}
