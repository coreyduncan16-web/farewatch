# Discovers Frontier's FULL route network from their own booking page:
# every station (with city name, state, country), every bookable market from
# it, and Frontier's "MAC" metro groups (nearby-airport clusters like the
# Southeast group CLT/MYR/ORF/RDU/RIC/TYS). Writes data\network.json.
# Re-run monthly-ish; the network changes seasonally.
# Windows PowerShell 5.1 compatible. Keep this file ASCII-only.

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$dd = [uri]::EscapeDataString((Get-Date).AddDays(20).ToString('MMM d, yyyy', $script:FwInv))
$uri = 'https://booking.flyfrontier.com/Flight/InternalSelect?s=true&o1=ATL&d1=MCO&dd1=' + $dd + '&ADT=1&mon=true'
$r = Invoke-WebRequest -Uri $uri -UserAgent $script:FwUA -UseBasicParsing -TimeoutSec 60

$t = $r.Content
$i = $t.IndexOf('"json":[{"code":')
if ($i -lt 0) { throw 'station JSON not found on booking page - page format may have changed' }
$start = $i + 7   # position of the opening [
$depth = 0; $end = -1
for ($p = $start; $p -lt $t.Length; $p++) {
    $ch = $t[$p]
    if ($ch -eq '[') { $depth++ }
    elseif ($ch -eq ']') { $depth--; if ($depth -eq 0) { $end = $p; break } }
}
if ($end -lt 0) { throw 'could not find end of station JSON' }

$countries = $t.Substring($start, $end - $start + 1) | ConvertFrom-Json

$stations = @{}
$routePairs = 0
foreach ($country in $countries) {
    foreach ($s in @($country.stations)) {
        $mac = ''; $mates = @()
        if ($s.macs -and $s.macs.PSObject.Properties['codes'] -and $s.macs.codes) {
            $mac = [string]$s.macs.value
            $mates = @($s.macs.codes | ForEach-Object { [string]$_.macStation })
        }
        $markets = @()
        if ($s.markets) { $markets = @($s.markets | ForEach-Object { [string]$_ }) }
        $routePairs += $markets.Count
        $stations[[string]$s.code] = @{
            name    = [string]$s.value
            state   = [string]$s.provinceStateCode
            country = [string]$country.code
            mac     = $mac
            mates   = $mates
            markets = $markets
        }
    }
}

Ensure-FwDataDir
Write-FwUtf8 (Get-FwPath 'data\network.json') (@{
    updated = (Get-Date -Format 'yyyy-MM-dd')
    stations = $stations
} | ConvertTo-Json -Depth 6 -Compress)

$active = @($stations.Keys | Where-Object { @($stations[$_].markets).Count -gt 0 })
Write-Output ('network: {0} stations ({1} with active markets), {2} bookable route pairs. Saved to data\network.json' -f $stations.Count, $active.Count, $routePairs)
