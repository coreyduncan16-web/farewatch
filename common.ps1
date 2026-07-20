# FareWatch shared helpers. Windows PowerShell 5.1 compatible. Keep this file ASCII-only.

[Net.ServicePointManager]::SecurityProtocol = `
    [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$script:FwRoot = $PSScriptRoot

function Get-FwPath([string]$name) { Join-Path $script:FwRoot $name }

function Read-FwConfig {
    Get-Content -Raw -Encoding UTF8 (Get-FwPath 'config.json') | ConvertFrom-Json
}

function Read-FwEnv {
    $map = @{}
    $envFile = Get-FwPath '.env'
    if (Test-Path $envFile) {
        foreach ($line in (Get-Content $envFile -Encoding UTF8)) {
            $t = $line.Trim()
            if ($t -eq '' -or $t.StartsWith('#')) { continue }
            $i = $t.IndexOf('=')
            if ($i -lt 1) { continue }
            $map[$t.Substring(0, $i).Trim()] = $t.Substring($i + 1).Trim()
        }
    }
    $map
}

function Ensure-FwDataDir {
    $dir = Get-FwPath 'data'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
}

function Write-FwUtf8([string]$path, [string]$text) {
    [IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($false)))
}

# History: hashtable  "ORG-DST|yyyy-MM-dd" -> ArrayList of @{ d = sweep date; p = price }
function Read-FwHistory {
    $h = @{}
    $p = Get-FwPath 'data\history.json'
    if (Test-Path $p) {
        $obj = Get-Content -Raw -Encoding UTF8 $p | ConvertFrom-Json
        foreach ($prop in $obj.PSObject.Properties) {
            $list = New-Object System.Collections.ArrayList
            foreach ($o in @($prop.Value)) {
                $rec = @{ d = [string]$o.d; p = [double]$o.p }
                if ($o.PSObject.Properties['t']) { $rec.t = [string]$o.t }
                if ($o.PSObject.Properties['g']) {
                    $rec.g  = [double]$o.g
                    $rec.gc = [int]$o.gc
                    $rec.fc = [int]$o.fc
                    $rec.gn = [int]$o.gn
                }
                [void]$list.Add($rec)
            }
            $h[$prop.Name] = $list
        }
    }
    $h
}

function Save-FwHistory($hist) {
    Ensure-FwDataDir
    $out = New-Object System.Collections.Specialized.OrderedDictionary
    foreach ($k in ($hist.Keys | Sort-Object)) { $out[$k] = @($hist[$k]) }
    Write-FwUtf8 (Get-FwPath 'data\history.json') ($out | ConvertTo-Json -Depth 6 -Compress)
}

# API usage for the current calendar month
function Read-FwUsage {
    $month = Get-Date -Format 'yyyy-MM'
    $u = @{ month = $month; calls = 0 }
    $p = Get-FwPath 'data\usage.json'
    if (Test-Path $p) {
        $o = Get-Content -Raw -Encoding UTF8 $p | ConvertFrom-Json
        if ([string]$o.month -eq $month) { $u.calls = [int]$o.calls }
    }
    $u
}

function Save-FwUsage($u) {
    Ensure-FwDataDir
    Write-FwUtf8 (Get-FwPath 'data\usage.json') ($u | ConvertTo-Json -Compress)
}

# ---------------------------------------------------------------- frontier --

$script:FwUA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36'
$script:FwBlocked = $false
$script:FwInv = [System.Globalization.CultureInfo]::InvariantCulture

# Fetches one route-date search page from flyfrontier.com and returns an array
# of per-flight hashtables: depTime, arrTime, stops, flightNums, cash, gw
# (all-in GoWild pass total, -1 if none), gwOn. Returns $null when the route
# does not fly that day or the page could not be parsed. Sets $script:FwBlocked
# on 403/429 so callers can stop sweeping.
# The page embeds the results as:  FlightData = '{"journeys":[...]}';
# Two serializer variants with different field orders exist - always parse the
# JSON, never pattern-match field sequences.
function Get-FrontierFlightData([string]$o, [string]$d, [datetime]$dep) {
    $dd = [uri]::EscapeDataString($dep.ToString('MMM d, yyyy', $script:FwInv))
    $uri = ('https://booking.flyfrontier.com/Flight/InternalSelect?s=true&o1={0}&d1={1}&dd1={2}&ADT=1&mon=true' -f $o, $d, $dd)
    try {
        $r = Invoke-WebRequest -Uri $uri -UserAgent $script:FwUA -UseBasicParsing -TimeoutSec 60
    } catch {
        $status = 0
        try { $status = [int]$_.Exception.Response.StatusCode } catch { }
        if ($status -eq 429 -or $status -eq 403) { $script:FwBlocked = $true }
        return $null
    }
    $t = $r.Content -replace '&quot;', '"' -replace '&amp;', '&'
    $m = [regex]::Match($t, "FlightData = '((?s).+?)';")
    if (-not $m.Success) { return $null }
    $fd = $null
    try { $fd = $m.Groups[1].Value.Replace("\'", "'") | ConvertFrom-Json } catch { return $null }
    if ($null -eq $fd -or -not $fd.PSObject.Properties['journeys'] -or @($fd.journeys).Count -eq 0) { return $null }
    $flights = @($fd.journeys[0].flights)
    if ($flights.Count -eq 0) { return $null }
    $out = New-Object System.Collections.ArrayList
    foreach ($f in $flights) {
        $legs = @($f.legs)
        if ($legs.Count -eq 0) { continue }
        $nums = @($legs | ForEach-Object { 'F9 ' + ([string]$_.flightNumber).Trim() }) -join ' / '
        [void]$out.Add(@{
            depTime = [datetime]::Parse([string]$legs[0].departureDate, $script:FwInv)
            arrTime = [datetime]::Parse([string]$legs[$legs.Count - 1].arrivalDate, $script:FwInv)
            stops   = $legs.Count - 1
            flightNums = $nums
            cash = [double]$f.standardFare
            gw   = [double]$f.goWildFare
            gwOn = [bool]$f.isGoWildFareEnabled
        })
    }
    if ($out.Count -eq 0) { return $null }
    ,@($out)
}

function Read-FwMeta {
    $m = @{ lastSweepUtc = ''; provider = 'none'; note = '' }
    $p = Get-FwPath 'data\meta.json'
    if (Test-Path $p) {
        $o = Get-Content -Raw -Encoding UTF8 $p | ConvertFrom-Json
        foreach ($prop in $o.PSObject.Properties) { $m[$prop.Name] = [string]$prop.Value }
    }
    $m
}

function Save-FwMeta($m) {
    Ensure-FwDataDir
    Write-FwUtf8 (Get-FwPath 'data\meta.json') ($m | ConvertTo-Json -Compress)
}
