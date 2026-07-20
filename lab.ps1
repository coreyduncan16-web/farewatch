# The $16 lab: figures out WHEN Frontier drops GoWild fares to the tax floor.
#
# Every hourly run logs every flight on the study routes (config.json ->
# labRoutes) departing in the next ~36 hours: GoWild price, availability,
# and hours-until-takeoff. Over a few days the pattern falls out.
#
#   .\lab.ps1          log one round of observations (run-hourly does this)
#   .\lab.ps1 -Report  crunch everything logged so far
#
# Windows PowerShell 5.1 compatible. Keep this file ASCII-only.

[CmdletBinding()]
param([switch]$Report)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$cfg = Read-FwConfig
$labPath = Get-FwPath 'data\lab.jsonl'
$floor = [double]$cfg.labFloorGw

if ($Report) {
    if (-not (Test-Path $labPath)) { Write-Output 'lab: no observations yet - let the hourly runs collect for a day or two.'; return }
    $obs = New-Object System.Collections.ArrayList
    foreach ($line in (Get-Content $labPath -Encoding UTF8)) {
        if ($line.Trim() -eq '') { continue }
        [void]$obs.Add(($line | ConvertFrom-Json))
    }
    Write-Output ('lab report - {0} observations of {1} distinct flights' -f $obs.Count, (@($obs | ForEach-Object { $_.r + $_.fn + $_.dep } | Sort-Object -Unique)).Count)
    Write-Output ''
    Write-Output 'GoWild price vs hours before takeoff:'
    Write-Output ('{0,-9} {1,5} {2,7} {3,10} {4,10}' -f 'hrs out', 'obs', 'seat%', 'median gw', ('<=${0} %' -f $floor))
    $bins = @(@(0,2),@(2,4),@(4,6),@(6,9),@(9,12),@(12,18),@(18,24),@(24,30),@(30,40))
    foreach ($b in $bins) {
        $inBin = @($obs | Where-Object { $_.h -ge $b[0] -and $_.h -lt $b[1] })
        if ($inBin.Count -eq 0) { continue }
        $on = @($inBin | Where-Object { $_.on -and $_.gw -gt 0 })
        $medGw = '-'
        $floorPct = '-'
        if ($on.Count -gt 0) {
            $sortedGw = @($on | ForEach-Object { [double]$_.gw } | Sort-Object)
            $medGw = '{0:0.00}' -f $sortedGw[[int][Math]::Floor(($sortedGw.Count - 1) / 2)]
            $floorPct = '{0:0}%' -f (100.0 * @($on | Where-Object { [double]$_.gw -le $floor }).Count / $on.Count)
        }
        Write-Output ('{0,-9} {1,5} {2,7} {3,10} {4,10}' -f ('{0}-{1}' -f $b[0], $b[1]), $inBin.Count, ('{0:0}%' -f (100.0 * $on.Count / $inBin.Count)), $medGw, $floorPct)
    }

    # per-flight: earliest hours-out at which the floor price was seen
    $byFlight = @{}
    foreach ($o in $obs) {
        $k = $o.r + '|' + $o.fn + '|' + $o.dep
        if (-not $byFlight.ContainsKey($k)) { $byFlight[$k] = New-Object System.Collections.ArrayList }
        [void]$byFlight[$k].Add($o)
    }
    $firstFloor = New-Object System.Collections.ArrayList
    $neverFloor = 0; $tracked = 0
    foreach ($k in $byFlight.Keys) {
        $fobs = $byFlight[$k]
        if ($fobs.Count -lt 3) { continue }
        $tracked++
        $floorObs = @($fobs | Where-Object { $_.on -and $_.gw -gt 0 -and [double]$_.gw -le $floor })
        if ($floorObs.Count -eq 0) { $neverFloor++; continue }
        $earliest = (@($floorObs | ForEach-Object { [double]$_.h }) | Measure-Object -Maximum).Maximum
        [void]$firstFloor.Add($earliest)
    }
    Write-Output ''
    if ($firstFloor.Count -gt 0) {
        $s = @($firstFloor | Sort-Object)
        Write-Output ('Of {0} well-tracked flights, {1} hit the <=${2} floor.' -f $tracked, $firstFloor.Count, $floor)
        Write-Output ('Floor first seen (hours before takeoff): median {0:0.0}h, range {1:0.0}h - {2:0.0}h' -f $s[[int][Math]::Floor(($s.Count - 1) / 2)], $s[0], $s[$s.Count - 1])
        Write-Output ('{0} of {1} tracked flights never showed the floor price.' -f $neverFloor, $tracked)
    } else {
        Write-Output ('No flight has hit the <=${0} floor yet ({1} flights tracked so far). Keep collecting.' -f $floor, $tracked)
    }
    return
}

# ---- logging mode ----
$routes = @($cfg.labRoutes)
if ($routes.Count -eq 0) { Write-Output 'lab: no labRoutes configured - skipping.'; return }
$now = Get-Date
$usage = Read-FwUsage
$lines = New-Object System.Collections.ArrayList
foreach ($rt in $routes) {
    if ($script:FwBlocked) { break }
    $parts = $rt.ToUpper().Split('-')
    foreach ($off in @(0, 1)) {
        $day = $now.Date.AddDays($off)
        $fl = Get-FrontierFlightData $parts[0] $parts[1] $day
        $usage.calls = [int]$usage.calls + 1
        Start-Sleep -Milliseconds ([int]$cfg.frontierSleepMs)
        if ($null -eq $fl) { continue }
        foreach ($f in $fl) {
            $hrs = [Math]::Round(($f.depTime - $now).TotalHours, 1)
            if ($hrs -lt -0.5 -or $hrs -gt 40) { continue }
            $rec = @{
                ts = $now.ToString('yyyy-MM-ddTHH:mm'); r = $rt.ToUpper(); fn = $f.flightNums
                dep = $f.depTime.ToString('yyyy-MM-ddTHH:mm'); h = $hrs
                gw = $f.gw; on = [bool]$f.gwOn; cash = $f.cash
            }
            [void]$lines.Add(($rec | ConvertTo-Json -Compress))
        }
    }
}
Save-FwUsage $usage
if ($lines.Count -gt 0) {
    Ensure-FwDataDir
    Add-Content -Path $labPath -Value $lines -Encoding UTF8
}
Write-Output ('lab: logged {0} flight observations across {1} routes.' -f $lines.Count, $routes.Count)
