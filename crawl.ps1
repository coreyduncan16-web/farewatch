# FareWatch rolling crawler: works through the ENTIRE Frontier network
# (every bookable pair x next 10 days), oldest-data-first, a small batch at a
# time. Run frequently (scheduled every ~4 min) it refreshes the whole
# ~68k route-date network on a rotation, so the local database always has
# something to show for any route. It updates data\history.json silently;
# the hourly run renders + publishes what it has gathered.
#
#   .\crawl.ps1              one batch (config.crawlBatch route-dates)
#   .\crawl.ps1 -Batch 100   bigger one-off batch
#
# Windows PowerShell 5.1 compatible. Keep this file ASCII-only.

[CmdletBinding()]
param([int]$Batch = 0, [switch]$NoLock)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$cfg = Read-FwConfig
if (-not [bool]$cfg.crawlEnabled) { return }

$net = Get-FwNetwork
if ($null -eq $net) { Write-Output 'crawl: no network.json - run network-discover.ps1 first.'; return }

# -NoLock: caller already holds the run lock (e.g. quick-check).
$ownLock = $false
if (-not $NoLock) {
    if (-not (Get-FwLock 10)) { return }   # another sweep is running; try next tick
    $ownLock = $true
}
try {
    $today = (Get-Date).Date
    $todayStr = $today.ToString('yyyy-MM-dd')
    $horizon = [Math]::Min(10, [int]$cfg.horizonDays)
    $cap = if ($Batch -gt 0) { $Batch } else { [int]$cfg.crawlBatch }

    $hist = Read-FwHistory
    # prune departed route-dates so the database only holds today..+10
    foreach ($k in @($hist.Keys)) {
        $dep = [datetime]::ParseExact($k.Split('|')[1], 'yyyy-MM-dd', $null)
        if ($dep -lt $today) { $hist.Remove($k) }
    }

    # no-flights memo (per day): skip pairs a route does not fly today
    $nullsPath = Get-FwPath 'data\noflights.json'
    $nulls = @{}
    if (Test-Path $nullsPath) {
        $nj = Get-Content -Raw -Encoding UTF8 $nullsPath | ConvertFrom-Json
        foreach ($p in $nj.PSObject.Properties) {
            if ([string]$p.Value -eq $todayStr) { $nulls[$p.Name] = $todayStr }
        }
    }

    # rolling cursor so successive batches march through the network instead
    # of always re-scoring the same 68k list (cheap + deterministic coverage)
    $origins = @($net.stations.PSObject.Properties.Name | Where-Object { @($net.stations.$_.markets).Count -gt 0 } | Sort-Object)
    $curPath = Get-FwPath 'data\crawl-cursor.json'
    $ci = 0
    if (Test-Path $curPath) {
        try { $ci = [int](Get-Content -Raw -Encoding UTF8 $curPath | ConvertFrom-Json).i } catch { $ci = 0 }
    }

    $usage = Read-FwUsage
    $picked = New-Object System.Collections.ArrayList
    $scanned = 0
    # walk origins from the cursor, collecting stale/never-seen route-dates
    for ($step = 0; $step -lt $origins.Count -and $picked.Count -lt $cap; $step++) {
        $o = $origins[(($ci + $step) % $origins.Count)]
        $scanned++
        foreach ($d in @($net.stations.$o.markets)) {
            if ($picked.Count -ge $cap) { break }
            for ($i = 0; $i -le $horizon; $i++) {
                if ($picked.Count -ge $cap) { break }
                $dep = $today.AddDays($i)
                $key = '{0}-{1}|{2}' -f $o, $d, $dep.ToString('yyyy-MM-dd')
                if ($nulls.ContainsKey($key)) { continue }
                if ($hist.ContainsKey($key)) {
                    $obs = $hist[$key]
                    if ([string]$obs[$obs.Count - 1].d -eq $todayStr) { continue }  # already fresh today
                }
                [void]$picked.Add(@{ key = $key; o = $o; d = $d; dep = $dep })
            }
        }
    }
    # advance cursor past the origins we consumed
    $newCi = ($ci + $scanned) % $origins.Count
    Write-FwUtf8 $curPath (@{ i = $newCi } | ConvertTo-Json -Compress)

    $got = 0
    foreach ($rd in $picked) {
        if ($script:FwBlocked) { break }
        $flights = Get-FrontierFlightData $rd.o $rd.d $rd.dep
        $usage.calls = [int]$usage.calls + 1
        Start-Sleep -Milliseconds ([int]$cfg.frontierSleepMs)
        if ($null -eq $flights) { $nulls[$rd.key] = $todayStr; continue }
        $cash = $null; $gwBest = $null; $gwCount = 0; $gwNonstop = 0
        foreach ($fl in $flights) {
            if ($fl.cash -gt 0 -and ($null -eq $cash -or $fl.cash -lt $cash)) { $cash = $fl.cash }
            if ($fl.gwOn -and $fl.gw -gt 0) {
                $gwCount++
                if ($fl.stops -eq 0) { $gwNonstop = 1 }
                if ($null -eq $gwBest -or $fl.gw -lt $gwBest) { $gwBest = $fl.gw }
            }
        }
        if ($null -eq $cash) { $nulls[$rd.key] = $todayStr; continue }
        $f = @{ cash = $cash; gw = $gwBest; gwCount = $gwCount; flightCount = @($flights).Count; gwNonstop = $gwNonstop }
        $g = -1.0
        if ($null -ne $f.gw) { $g = [Math]::Round([double]$f.gw, 2) }
        $obs2 = $null
        if ($hist.ContainsKey($rd.key)) { $obs2 = $hist[$rd.key] }
        else { $obs2 = New-Object System.Collections.ArrayList; $hist[$rd.key] = $obs2 }
        for ($j = $obs2.Count - 1; $j -ge 0; $j--) { if ([string]$obs2[$j].d -eq $todayStr) { $obs2.RemoveAt($j) } }
        [void]$obs2.Add(@{ d = $todayStr; p = [Math]::Round([double]$f.cash, 0); g = $g; gc = [int]$f.gwCount; fc = [int]$f.flightCount; gn = [int]$f.gwNonstop })
        while ($obs2.Count -gt 8) { $obs2.RemoveAt(0) }   # crawl keeps shallow history to stay small
        $got++
    }

    Save-FwHistory $hist
    Save-FwUsage $usage
    Write-FwUtf8 $nullsPath ($nulls | ConvertTo-Json -Compress)
    Write-Output ('crawl: {0} route-dates refreshed ({1} in database, cursor {2}/{3}, month usage {4}).' -f $got, $hist.Count, $newCi, $origins.Count, $usage.calls)
} finally {
    if ($ownLock) { Release-FwLock }
}
