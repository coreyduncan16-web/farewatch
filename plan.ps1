# FareWatch trip planner: cheapest way to get from A to B on Frontier for a
# GoWild passholder, including "airport hopping" (self-connect via a hub,
# booked as separate tickets).
#
#   .\plan.ps1 -From ATL -To MBJ -Budget 150
#   .\plan.ps1 -From ATL -To SJO -Date 2026-07-29 -Hubs MCO,DEN
#
# Uses GoWild pass fares when a flight has pass seats, cash fare otherwise.
# Windows PowerShell 5.1 compatible. Keep this file ASCII-only.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$From,
    [Parameter(Mandatory = $true)][string]$To,
    [double]$Budget = 0,
    [string]$Date = '',
    [string]$Hubs = '',
    [int]$MaxOptions = 5,
    [int]$MinConnectMinutes = 90,
    [switch]$NoOvernight
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$cfg  = Read-FwConfig
$From = $From.Trim().ToUpper()
$To   = $To.Trim().ToUpper()
$dep  = (Get-Date).Date.AddDays(1)
if ($Date -ne '') { $dep = ([datetime]::Parse($Date)).Date }

$hubList = @($cfg.hubs)
if ($Hubs -ne '') { $hubList = @($Hubs.Split(',') | ForEach-Object { $_.Trim().ToUpper() }) }
$hubList = @($hubList | Where-Object { $_ -ne $From -and $_ -ne $To })

$script:CallCount = 0
$legCache = @{}

# Flights for one leg on one day, each tagged with the effective price for a
# passholder: GoWild total when pass seats exist, cash fare otherwise.
function LegFlights([string]$o, [string]$d, [datetime]$day) {
    $k = ('{0}-{1}-{2}' -f $o, $d, $day.ToString('yyyyMMdd'))
    if ($legCache.ContainsKey($k)) { return $legCache[$k] }
    if ($script:FwBlocked) { return $null }
    $fl = Get-FrontierFlightData $o $d $day
    $script:CallCount++
    Start-Sleep -Milliseconds ([int]$cfg.frontierSleepMs)
    $opts = New-Object System.Collections.ArrayList
    if ($null -ne $fl) {
        foreach ($f in $fl) {
            if ($f.gwOn -and $f.gw -gt 0) { $f.eff = $f.gw; $f.typ = 'GoWild' }
            elseif ($f.cash -gt 0) { $f.eff = $f.cash; $f.typ = 'cash' }
            else { continue }
            [void]$opts.Add($f)
        }
    }
    $result = $null
    if ($opts.Count -gt 0) { $result = @($opts) }
    $legCache[$k] = $result
    $result
}

Write-Output ('Planning {0} -> {1} on {2}' -f $From, $To, $dep.ToString('ddd MMM d, yyyy'))
if ($Budget -gt 0) { Write-Output ('Budget: ${0}' -f $Budget) }
Write-Output ('Checking direct + self-connects via: {0}' -f ($hubList -join ', '))
Write-Output ''

$itins = New-Object System.Collections.ArrayList

# direct
$direct = LegFlights $From $To $dep
if ($direct) {
    foreach ($f in $direct) {
        [void]$itins.Add(@{ total = [double]$f.eff; legs = @(@{ o = $From; d = $To; f = $f }) })
    }
}

# one hop
foreach ($h in $hubList) {
    if ($script:FwBlocked) { break }
    $l1 = LegFlights $From $h $dep
    if (-not $l1) { continue }
    $sameDayCombos = 0
    foreach ($dayOffset in @(0, 1)) {
        if ($dayOffset -eq 1 -and ($NoOvernight -or $sameDayCombos -gt 0)) { break }
        $l2 = LegFlights $h $To ($dep.AddDays($dayOffset))
        if (-not $l2) { continue }
        foreach ($f1 in $l1) {
            foreach ($f2 in $l2) {
                if ($f2.depTime -lt $f1.arrTime.AddMinutes($MinConnectMinutes)) { continue }
                [void]$itins.Add(@{
                    total = [double]$f1.eff + [double]$f2.eff
                    legs  = @(@{ o = $From; d = $h; f = $f1 }, @{ o = $h; d = $To; f = $f2 })
                })
                if ($dayOffset -eq 0) { $sameDayCombos++ }
            }
        }
    }
}

$sorted = @($itins | Sort-Object { $_.total })
if ($sorted.Count -eq 0) {
    Write-Output 'No routings found for that day (no service, or nothing bookable).'
    Write-Output 'Try another date, more hubs (-Hubs), or allow overnight connects.'
    if ($script:FwBlocked) { Write-Output 'NOTE: flyfrontier.com started refusing requests mid-search; try again later.' }
    Write-Output ('({0} site requests used)' -f $script:CallCount)
    return
}

$show = $sorted
$overBudgetNote = $false
if ($Budget -gt 0) {
    $within = @($sorted | Where-Object { $_.total -le $Budget })
    if ($within.Count -gt 0) { $show = $within }
    else { $overBudgetNote = $true; $show = @($sorted | Select-Object -First 3) }
}
$show = @($show | Select-Object -First $MaxOptions)

if ($overBudgetNote) {
    Write-Output ('Nothing fits under ${0}. Cheapest found:' -f $Budget)
}

$rank = 0
foreach ($it in $show) {
    $rank++
    Write-Output ''
    Write-Output ('OPTION {0}   total ${1}' -f $rank, ('{0:0.00}' -f $it.total))
    $prevArr = $null
    foreach ($leg in $it.legs) {
        $f = $leg.f
        if ($null -ne $prevArr) {
            $lay = [int]($f.depTime - $prevArr).TotalMinutes
            Write-Output ('    -- connect {0}h{1:d2}m in {2} (separate booking!)' -f [Math]::Floor($lay / 60), ($lay % 60), $leg.o)
        }
        $stopsTxt = 'nonstop'
        if ($f.stops -gt 0) { $stopsTxt = ('{0} stop(s)' -f $f.stops) }
        Write-Output ('  {0} -> {1}  {2} {3}-{4}  {5} ({6})  ${7} {8}' -f $leg.o, $leg.d,
            $f.depTime.ToString('ddd M/d'), $f.depTime.ToString('h:mmtt').ToLower(), $f.arrTime.ToString('h:mmtt').ToLower(),
            $f.flightNums, $stopsTxt, ('{0:0.00}' -f $f.eff), $f.typ)
        $prevArr = $f.arrTime
    }
}

Write-Output ''
Write-Output ('({0} site requests used)' -f $script:CallCount)
Write-Output 'Self-connects are separate GoWild bookings: if leg 1 is late, leg 2 does'
Write-Output 'not wait and owes you nothing. Leave generous connect time.'
