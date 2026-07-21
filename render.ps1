# FareWatch renderer: reads data\history.json and writes dashboard.html.
# Windows PowerShell 5.1 compatible. Keep this file ASCII-only
# (city names with accents come from config.json, which is read as UTF-8).

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$cfg   = Read-FwConfig
$hist  = Read-FwHistory
$usage = Read-FwUsage
$meta  = Read-FwMeta
$today = (Get-Date).Date
$inv   = [System.Globalization.CultureInfo]::InvariantCulture

function Ord([int]$n) {
    $mod100 = $n % 100
    if ($mod100 -ge 11 -and $mod100 -le 13) { return ('{0}th' -f $n) }
    switch ($n % 10) {
        1 { return ('{0}st' -f $n) }
        2 { return ('{0}nd' -f $n) }
        3 { return ('{0}rd' -f $n) }
        default { return ('{0}th' -f $n) }
    }
}

function Median($values) {
    $s = @($values | Sort-Object)
    $n = $s.Count
    if ($n -eq 0) { return 0 }
    if ($n % 2 -eq 1) { return [double]$s[($n - 1) / 2] }
    return ([double]$s[$n / 2 - 1] + [double]$s[$n / 2]) / 2
}

function CityOf([string]$code) {
    $a = $cfg.airports.$code
    if ($null -eq $a) { return $code }
    [string]$a.city
}

function PlaceOf([string]$code) {
    $a = $cfg.airports.$code
    if ($null -eq $a) { return $code }
    if ([string]$a.country -ne '') { return ('{0}, {1}' -f $a.city, $a.country) }
    [string]$a.city
}

# ------------------------------------------------------------ build records --

$records = New-Object System.Collections.ArrayList
foreach ($key in $hist.Keys) {
    $parts = $key.Split('|')
    $route = $parts[0]
    $dep   = [datetime]::ParseExact($parts[1], 'yyyy-MM-dd', $null)
    if ($dep -lt $today) { continue }
    $o = $route.Split('-')[0]; $d = $route.Split('-')[1]

    $obs = @($hist[$key] | Sort-Object { [string]$_.d })
    if ($obs.Count -eq 0) { continue }
    $prices = @($obs | ForEach-Object { [double]$_.p })
    $cur = $prices[$prices.Count - 1]
    $min = ($prices | Measure-Object -Minimum).Minimum
    $max = ($prices | Measure-Object -Maximum).Maximum
    $med = Median $prices
    $n   = $prices.Count

    $pct = 0
    if ($max -gt $min) { $pct = [int][Math]::Round((($cur - $min) / ($max - $min)) * 100) }
    if ($pct -lt 0) { $pct = 0 }; if ($pct -gt 100) { $pct = 100 }

    $delta = 0.0
    if ($n -ge 2) { $delta = $cur - $prices[$n - 2] }

    $daysOut = ($dep - $today).Days
    $underMed = [Math]::Round($med - $cur)

    $sig = 'HOLD'
    if ($n -lt [int]$cfg.minObservations) { $sig = 'LEARNING' }
    elseif ($pct -le [int]$cfg.buyZonePct -and $cur -le $med) { $sig = 'BUY' }
    elseif ($pct -ge [int]$cfg.spikePct) { $sig = 'SPIKE' }
    elseif ($pct -le [int]$cfg.watchPct) { $sig = 'WATCH' }

    $why = ''
    $ordPct = Ord ([Math]::Max(1, $pct))
    if ($sig -eq 'BUY') {
        $why = ('{0} pct of its own range, ${1} under median' -f $ordPct, $underMed)
        if ($daysOut -le 14) { $why += ('; {0}d out, so little room left for it to fall' -f $daysOut) }
    } elseif ($sig -eq 'WATCH') {
        if ($underMed -ge 0) { $why = ('{0} pct of its own range, ${1} under median' -f $ordPct, $underMed) }
        else { $why = ('{0} pct of its own range' -f $ordPct) }
    } elseif ($sig -eq 'SPIKE') {
        $why = ('{0} pct of its own range, ${1} over median' -f $ordPct, [Math]::Abs($underMed))
    } elseif ($sig -eq 'LEARNING') {
        $why = ('only {0} sweeps observed so far' -f $n)
    }

    $rec = @{
        key = $key; o = $o; d = $d; dep = $dep; daysOut = $daysOut
        cur = $cur; min = $min; max = $max; med = $med; n = $n
        pct = $pct; delta = $delta; underMed = $underMed; sig = $sig; why = $why
        hasGw = $false; g = -1.0; gc = 0; fc = 0; gn = 0
    }
    $lastObs = $obs[$obs.Count - 1]
    $rec.u = [string]$lastObs.d
    if ($lastObs.ContainsKey('fc')) {
        $rec.hasGw = $true
        $rec.g  = [double]$lastObs.g
        $rec.gc = [int]$lastObs.gc
        $rec.fc = [int]$lastObs.fc
        $rec.gn = [int]$lastObs.gn
    }
    [void]$records.Add($rec)
}

$tally = @{ BUY = 0; WATCH = 0; HOLD = 0; SPIKE = 0; LEARNING = 0 }
foreach ($r in $records) { $tally[$r.sig] = [int]$tally[$r.sig] + 1 }

# ------------------------------------------------------------- cash section --

$sigRank = @{ BUY = 0; WATCH = 1 }
$cashPool = @($records | Where-Object { $_.sig -eq 'BUY' -or $_.sig -eq 'WATCH' } |
    Sort-Object @{ Expression = { $sigRank[$_.sig] } }, @{ Expression = { $_.pct } }, @{ Expression = { $_.underMed }; Descending = $true })
$cashRows = @($cashPool | Select-Object -First ([int]$cfg.cashTableRows))
$cashHeldBack = $records.Count - $cashRows.Count
if ($cashHeldBack -lt 0) { $cashHeldBack = 0 }

# ----------------------------------------------------------- gowild section --

$window = [int]$cfg.goWildWindowDays
$gwPool = New-Object System.Collections.ArrayList
foreach ($r in $records) {
    # each route's own booking window per the GoWild terms:
    # domestic = 1 day before departure, international = 10 days
    $rw = Get-FwGoWildWindow $cfg $r.o $r.d
    if ($r.daysOut -gt $rw) { continue }
    $basis = New-Object System.Collections.ArrayList
    if ($r.hasGw) {
        # Real GoWild data straight from Frontier's booking site.
        if ($r.gc -gt 0) {
            $r.gwGroup = 0; $r.gwSort = $r.g
            [void]$basis.Add(('pass seats on {0} of {1} flights' -f $r.gc, $r.fc))
            if ($r.gn -eq 1) { [void]$basis.Add('includes a nonstop') }
            elseif ($r.fc -gt $r.gc) { [void]$basis.Add('connections only') }
        } else {
            $r.gwGroup = 1; $r.gwSort = $r.daysOut
            [void]$basis.Add(('no pass seats across {0} flights at last sweep' -f $r.fc))
        }
        if ($r.daysOut -le 1) { [void]$basis.Add(('{0}d out &mdash; seats can still clear' -f $r.daysOut)) }
        elseif ($r.daysOut -eq $rw) { [void]$basis.Add('just entered the window') }
        $r.gwScore = -1
    } else {
        # No sweep data yet for this date: fall back to the proxy score.
        $score = 30.0
        if ($r.n -ge [int]$cfg.minObservations) {
            $score += (100 - $r.pct) * 0.25
            if ($r.pct -le 25) { [void]$basis.Add(('cash fare at {0} pct (weak demand)' -f (Ord ([Math]::Max(1, $r.pct))))) }
            if ($r.pct -ge 85) { [void]$basis.Add(('cash fare at {0} pct (selling well)' -f (Ord $r.pct))) }
        } else {
            [void]$basis.Add('limited history (learning)')
        }
        $dow = $r.dep.DayOfWeek
        if ($dow -eq 'Tuesday' -or $dow -eq 'Wednesday') { $score += 8; [void]$basis.Add('Tue/Wed departure') }
        if ($r.daysOut -le 1) { $score += 7; [void]$basis.Add(('{0}d out &mdash; release window' -f $r.daysOut)) }
        elseif ($r.daysOut -eq $rw) { $score += 7; [void]$basis.Add('just released today') }
        $r.gwGroup = 2
        $r.gwScore = [int][Math]::Round([Math]::Max(5, [Math]::Min(95, $score)))
        $r.gwSort = -$r.gwScore
        [void]$basis.Insert(0, 'proxy &mdash; not yet swept')
    }
    $r.gwBasis = ($basis -join '; ')
    [void]$gwPool.Add($r)
}
$gwSorted = @($gwPool | Sort-Object @{ Expression = { $_.gwGroup } }, @{ Expression = { $_.gwSort } })
$gwRows = @($gwSorted | Select-Object -First ([int]$cfg.goWildTableRows))

# ---------------------------------------------------------------- html bits --

function DeltaHtml($r) {
    $dv = [int][Math]::Round([Math]::Abs($r.delta))
    if ($r.n -lt 2 -or $dv -eq 0) { return '<span class="delta">&mdash;</span>' }
    if ($r.delta -lt 0) { return ('<span class="delta dn">&#9662; ${0} prev</span>' -f $dv) }
    return ('<span class="delta up">&#9652; ${0} prev</span>' -f $dv)
}

function CashRowHtml($r, [int]$i) {
    $dotPct = [Math]::Max(1.5, [Math]::Min(97.0, [double]$r.pct))
    $dotCls = ''
    if ($r.sig -eq 'BUY') { $dotCls = ' buy' }
    $tpl = @'
      <tr class="row" style="animation-delay:{0}ms">
        <td><div class="route">{1} <span>&rarr;</span> {2}</div>
            <span class="where hide-sm">{3} &middot; {4}</span></td>
        <td class="num">{5}
            <span class="delta">{6}d out</span></td>
        <td class="num"><span class="price">${7}</span>{8}</td>
        <td class="range hide-sm"><div class="bar"><div class="track"></div><div class="zone" style="width:{9}%"></div><div class="dot{10}" style="left:calc({11}% - 2px)"></div><div class="ends"><span>${12}</span><span>${13}</span></div></div></td>
        <td class="num hide-sm">{14}<span class="delta">pctl</span></td>
        <td><span class="sig {15}">{15}</span>
            <div class="why">{16}</div></td>
      </tr>
'@
    $tpl -f ($i * 14), $r.o, $r.d, (CityOf $r.o), (PlaceOf $r.d),
        $r.dep.ToString('MMM d', $inv), $r.daysOut,
        ([int][Math]::Round($r.cur)), (DeltaHtml $r),
        ([int]$cfg.buyZonePct), $dotCls, $dotPct,
        ([int][Math]::Round($r.min)), ([int][Math]::Round($r.max)),
        ([Math]::Max(1, $r.pct)), $r.sig, $r.why
}

function BookUrl($r) {
    $MONTHS = @('Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec')
    $dd = [uri]::EscapeDataString(('{0} {1}, {2}' -f $MONTHS[$r.dep.Month - 1], $r.dep.Day, $r.dep.Year))
    'https://booking.flyfrontier.com/Flight/InternalSelect?s=true&o1={0}&d1={1}&dd1={2}&ADT=1&mon=true' -f $r.o, $r.d, $dd
}

function GwRowHtml($r, [int]$i) {
    # GoWild fare cell + seats cell
    if ($r.hasGw) {
        if ($r.gc -gt 0) {
            $gwCell = ('<span class="price">${0}</span><span class="delta">all-in</span>' -f ('{0:0.00}' -f $r.g))
        } else {
            $gwCell = '<span class="delta">&mdash; none</span>'
        }
        $filled = 0
        if ($r.fc -gt 0) { $filled = [int][Math]::Ceiling(5.0 * $r.gc / $r.fc) }
        $pipCls = 'on'
        if ($r.gc -eq 0) { $pipCls = 'mid' }
        $seatsNum = ('{0}/{1}' -f $r.gc, $r.fc)
    } else {
        $gwCell = '<span class="delta">proxy</span>'
        $filled = [int][Math]::Round($r.gwScore / 20.0)
        $pipCls = 'mid'
        $seatsNum = [string]$r.gwScore
    }
    $pips = ''
    for ($p = 1; $p -le 5; $p++) {
        if ($p -le $filled) { $pips += ('<i class="pip {0}"></i>' -f $pipCls) }
        else { $pips += '<i class="pip"></i>' }
    }
    if ($r.hasGw -and $r.gc -gt 0) {
        $bookCell = ('<a class="bookbtn" target="_blank" rel="noopener" href="{0}">BOOK &rarr;</a>' -f (BookUrl $r))
    } else {
        $bookCell = ('<a class="bookbtn dim" target="_blank" rel="noopener" href="{0}">check</a>' -f (BookUrl $r))
    }
    $tpl = @'
      <tr class="row" data-o="{1}" style="animation-delay:{0}ms">
        <td><div class="route">{1} <span>&rarr;</span> {2}</div>
            <span class="where hide-sm">{3}</span></td>
        <td class="num">{4}
            <span class="delta">{5}d out</span></td>
        <td class="num hide-sm">${6}<span class="delta">cash</span></td>
        <td class="num">{7}</td>
        <td><div class="score"><span class="pips">{8}</span><span class="num">{9}</span></div></td>
        <td><div class="why">{10}</div></td>
        <td>{11}</td>
      </tr>
'@
    $tpl -f ($i * 14), $r.o, $r.d, (PlaceOf $r.d),
        $r.dep.ToString('MMM d', $inv), $r.daysOut,
        ([int][Math]::Round($r.cur)), $gwCell, $pips, $seatsNum, $r.gwBasis, $bookCell
}

# ------------------------------------------------------------------ assemble --

$sweptTxt = 'never swept'
if ($meta.lastSweepUtc -ne '') {
    $t = [datetime]::Parse($meta.lastSweepUtc, $inv, [System.Globalization.DateTimeStyles]::AdjustToUniversal)
    $sweptTxt = 'swept ' + $t.ToString('dd MMM HH:mm', $inv) + ' UTC'
}
$budget = [int]$cfg.apiMonthlyBudget
$meterPct = 0
if ($budget -gt 0) { $meterPct = [int][Math]::Min(100, [Math]::Round(100.0 * [int]$usage.calls / $budget)) }
$meterCls = ''
if ($meterPct -ge 85) { $meterCls = 'tight' }

$head = @'
<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>FareWatch</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Space+Grotesk:wght@400;500;600;700&family=IBM+Plex+Mono:wght@400;500;600&display=swap" rel="stylesheet">
<style>
:root{
  --ink:#10201a; --paper:#e8ede8; --panel:#fbfcfa; --rule:#c9d2ca;
  --dim:#67766d; --faint:#eef2ee;
  --buy:#0a6b4e; --watch:#9a5b12; --hold:#7b8880; --spike:#8e2f2f;
  --learn:#8b978f;
}
*{box-sizing:border-box}
body{
  margin:0; padding:28px 20px 64px; background:var(--paper); color:var(--ink);
  font-family:"Space Grotesk",-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;
  font-size:15px; line-height:1.45; -webkit-font-smoothing:antialiased;
}
.wrap{max-width:1080px;margin:0 auto}
.mono{font-family:"IBM Plex Mono",ui-monospace,SFMono-Regular,Menlo,monospace}

header{display:flex;align-items:baseline;gap:14px;flex-wrap:wrap;margin-bottom:6px}
h1{
  font-size:31px;font-weight:700;letter-spacing:-.035em;margin:0;
  text-transform:lowercase;
}
h1 em{font-style:normal;color:var(--dim);font-weight:500}
.swept{
  font-family:"IBM Plex Mono",monospace;font-size:11.5px;color:var(--dim);
  letter-spacing:.06em;margin-left:auto;text-align:right;
}
.lede{color:var(--dim);font-size:13.5px;max-width:62ch;margin:0 0 22px}

.tallies{display:flex;gap:8px;flex-wrap:wrap;align-items:center;margin-bottom:26px}
.tally{
  font-family:"IBM Plex Mono",monospace;font-size:11.5px;letter-spacing:.08em;
  padding:5px 11px;border:1px solid var(--rule);background:var(--panel);
  display:flex;gap:8px;align-items:center;
}
.tally b{font-size:14px;font-weight:600}
.tally.buy{border-color:var(--buy);color:var(--buy)}
.tally.watch{border-color:var(--watch);color:var(--watch)}
.budget{margin-left:auto;font-family:"IBM Plex Mono",monospace;font-size:11.5px;
  color:var(--dim);display:flex;align-items:center;gap:9px}
.meter{width:104px;height:7px;background:var(--faint);border:1px solid var(--rule)}
.meter i{display:block;height:100%;background:var(--hold)}
.meter i.tight{background:var(--spike)}

h2{
  font-size:11.5px;font-weight:600;letter-spacing:.16em;text-transform:uppercase;
  color:var(--dim);margin:0 0 2px;font-family:"IBM Plex Mono",monospace;
}
.sub{font-size:12.5px;color:var(--dim);margin:0 0 14px}
section{margin-bottom:44px}

table{width:100%;border-collapse:collapse;background:var(--panel);
  border:1px solid var(--rule)}
th{
  font-family:"IBM Plex Mono",monospace;font-size:10px;font-weight:500;
  letter-spacing:.11em;text-transform:uppercase;color:var(--dim);
  text-align:left;padding:9px 12px;border-bottom:1px solid var(--rule);
  white-space:nowrap;
}
td{padding:11px 12px;border-bottom:1px solid var(--faint);vertical-align:middle}
tr:last-child td{border-bottom:none}
tr.row{opacity:0;animation:in .34s ease forwards}
@keyframes in{to{opacity:1}}
@media (prefers-reduced-motion:reduce){tr.row{opacity:1;animation:none}}

.route{font-family:"IBM Plex Mono",monospace;font-weight:600;font-size:14px;
  letter-spacing:.02em;white-space:nowrap}
.route span{color:var(--dim);font-weight:400}
.where{font-size:11.5px;color:var(--dim);display:block;margin-top:1px;
  font-family:"Space Grotesk",sans-serif}
.num{font-family:"IBM Plex Mono",monospace;font-variant-numeric:tabular-nums;
  white-space:nowrap}
.price{font-size:16px;font-weight:600}
.delta{font-size:11.5px;display:block;color:var(--dim)}
.delta.dn{color:var(--buy)} .delta.up{color:var(--spike)}

/* signature element: where today's price sits inside its own observed range */
.range{width:172px}
.bar{position:relative;height:22px}
.bar .track{position:absolute;top:10px;left:0;right:0;height:2px;
  background:var(--rule)}
.bar .zone{position:absolute;top:5px;left:0;height:12px;background:var(--faint);
  border-left:1px solid var(--rule);border-right:1px dashed var(--buy)}
.bar .dot{position:absolute;top:5px;width:3px;height:12px;background:var(--ink)}
.bar .dot.buy{background:var(--buy);width:5px;top:3px;height:16px}
.bar .ends{position:absolute;top:14px;left:0;right:0;display:flex;
  justify-content:space-between;font-family:"IBM Plex Mono",monospace;
  font-size:10px;color:var(--dim)}

.sig{font-family:"IBM Plex Mono",monospace;font-size:11px;font-weight:600;
  letter-spacing:.1em;white-space:nowrap}
.sig.BUY{color:var(--buy)} .sig.WATCH{color:var(--watch)}
.sig.HOLD{color:var(--hold)} .sig.SPIKE{color:var(--spike)}
.sig.LEARNING{color:var(--learn);font-weight:400}
.why{font-size:11.5px;color:var(--dim);margin-top:2px;max-width:30ch;
  font-family:"Space Grotesk",sans-serif;letter-spacing:0;font-weight:400;
  text-transform:none}

.score{display:flex;align-items:center;gap:9px}
.score .pips{display:flex;gap:2px}
.score .pip{width:7px;height:14px;background:var(--faint);
  border:1px solid var(--rule)}
.score .pip.on{background:var(--buy);border-color:var(--buy)}
.score .pip.mid{background:var(--watch);border-color:var(--watch)}
.blackout{color:var(--spike);font-family:"IBM Plex Mono",monospace;font-size:11px;
  letter-spacing:.08em}

.empty{padding:26px 14px;color:var(--dim);font-size:13.5px;background:var(--panel);
  border:1px solid var(--rule)}

.searchbar{display:flex;gap:10px;flex-wrap:wrap;align-items:flex-end;margin:0 0 14px}
.searchbar label{display:flex;flex-direction:column;gap:4px;
  font-family:"IBM Plex Mono",monospace;font-size:10px;letter-spacing:.11em;
  text-transform:uppercase;color:var(--dim)}
.searchbar select,.searchbar input{font-family:"IBM Plex Mono",monospace;
  font-size:13px;padding:7px 9px;border:1px solid var(--rule);
  background:var(--panel);color:var(--ink);min-width:104px}
.searchbar button{font-family:"IBM Plex Mono",monospace;font-size:12px;
  letter-spacing:.08em;padding:8px 16px;border:1px solid var(--buy);
  background:var(--buy);color:#fff;cursor:pointer}
.searchbar button:hover{opacity:.88}
.searchbar .live{font-size:11.5px;padding-bottom:9px}
.watchbox{display:none;margin-top:12px;padding:12px;background:var(--faint);
  border:1px dashed var(--rule);font-family:"IBM Plex Mono",monospace;
  font-size:11px;white-space:pre-wrap}
.rowbtn{font-family:"IBM Plex Mono",monospace;font-size:10px;letter-spacing:.06em;
  padding:3px 8px;border:1px solid var(--rule);background:var(--panel);
  color:var(--dim);cursor:pointer;text-decoration:none;display:inline-block}
.rowbtn:hover{border-color:var(--buy);color:var(--buy)}
.bookbtn{font-family:"IBM Plex Mono",monospace;font-size:11px;font-weight:600;
  letter-spacing:.09em;padding:7px 14px;border:1px solid var(--buy);
  background:var(--buy);color:#fff;text-decoration:none;display:inline-block;
  white-space:nowrap}
.bookbtn:hover{opacity:.88}
.bookbtn.dim{background:var(--panel);color:var(--dim);border-color:var(--rule)}
.bookbtn.dim:hover{color:var(--buy);border-color:var(--buy);opacity:1}
footer{margin-top:40px;padding-top:16px;border-top:1px solid var(--rule);
  font-size:12px;color:var(--dim);max-width:74ch}
footer b{color:var(--ink);font-weight:600}
a{color:var(--buy)}
@media(max-width:760px){
  .hide-sm{display:none} h1{font-size:25px} .range{width:120px}
  body{padding:20px 12px 48px}
}
</style></head>
<body><div class="wrap">
'@

$sb = New-Object System.Text.StringBuilder
[void]$sb.Append($head)

[void]$sb.Append(@'

<header>
  <h1>farewatch<em>/frontier</em></h1>
'@)
[void]$sb.Append(('  <div class="swept">{0}<br>source: {1} &middot; {2} route-dates</div>' -f $sweptTxt, $meta.provider, $records.Count))
[void]$sb.Append(@'

</header>
<p class="lede">Every price is judged against its own history on that exact
route and departure date, not against other routes. Percentile is where
today sits inside the range this route-date has actually traded in.</p>

'@)

[void]$sb.Append('<div class="tallies">' + "`n")
[void]$sb.Append(('  <div class="tally buy"><b>{0}</b> buy</div>' -f $tally.BUY) + "`n")
[void]$sb.Append(('  <div class="tally watch"><b>{0}</b> watch</div>' -f $tally.WATCH) + "`n")
[void]$sb.Append(('  <div class="tally"><b>{0}</b> hold</div>' -f $tally.HOLD) + "`n")
[void]$sb.Append(('  <div class="tally"><b>{0}</b> spiked</div>' -f $tally.SPIKE) + "`n")
[void]$sb.Append(('  <div class="tally"><b>{0}</b> learning</div>' -f $tally.LEARNING) + "`n")
[void]$sb.Append(('  <div class="budget">api {0}/{1} <span class="meter"><i class="{2}" style="width:{3}%"></i></span></div>' -f $usage.calls, $budget, $meterCls, $meterPct) + "`n")
[void]$sb.Append('</div>' + "`n`n")

# search section (client-side, works on static hosting)
# Use the full Frontier network when data\network.json exists (117 airports),
# otherwise fall back to the tracked routes.
$net = $null
$netPath = Get-FwPath 'data\network.json'
if (Test-Path $netPath) { $net = Get-Content -Raw -Encoding UTF8 $netPath | ConvertFrom-Json }

$fromOpts = ''; $toOpts = ''
if ($null -ne $net) {
    $codes = @($net.stations.PSObject.Properties.Name | Where-Object {
        @($net.stations.$_.markets).Count -gt 0
    })
    $sorted = @($codes | Sort-Object { [string]$net.stations.$_.name })
    foreach ($c in $sorted) {
        $st = $net.stations.$c
        $label = '{0} - {1}' -f $c, $st.name
        if ([string]$st.state -ne '') { $label += ', ' + $st.state }
        $optHtml = ('<option value="{0}"' -f $c)
        if ($c -eq 'ATL') { $optHtml += ' selected' }
        $optHtml += ('>{0}</option>' -f $label)
        $fromOpts += $optHtml
        $toOptHtml = ('<option value="{0}"' -f $c)
        if ($c -eq 'CUN') { $toOptHtml += ' selected' }
        $toOptHtml += ('>{0}</option>' -f $label)
        $toOpts += $toOptHtml
    }
} else {
    $fromCodes = @($records | ForEach-Object { $_.o } | Sort-Object -Unique)
    if ($fromCodes.Count -eq 0) { $fromCodes = @($cfg.origins) }
    $toCodes = @($records | ForEach-Object { $_.d } | Sort-Object -Unique)
    if ($toCodes.Count -eq 0) { $toCodes = @($cfg.destinations) }
    foreach ($c in $fromCodes) { $fromOpts += ('<option value="{0}">{0} - {1}</option>' -f $c, (CityOf $c)) }
    foreach ($c in $toCodes) { $toOpts += ('<option value="{0}">{0} - {1}</option>' -f $c, (CityOf $c)) }
}

$searchHtml = @'
<section id="searchsec">
  <h2>Search a route</h2>
  <p class="sub">Every tracked departure for a route, cheapest GoWild fare
  first. Data is as of the last sweep &mdash; always confirm with the live
  link before booking. &ldquo;GoWild seats only&rdquo; hides dates where no
  pass seats were seen at the last sweep &mdash; leave it off to see every
  tracked date, including cash-only ones.</p>
  <div class="searchbar">
    <label>Trip<select id="sTrip">
      <option value="ow" selected>One way</option>
      <option value="rt">Round trip</option>
    </select></label>
    <label>From<select id="sFrom">__FROMOPTS__</select></label>
    <label>To<select id="sTo">__TOOPTS__</select></label>
    <label>Date (optional)<input type="date" id="sDate"></label>
    <label id="sRetLbl" style="display:none">Return date<input type="date" id="sRet"></label>
    <label style="flex-direction:row;align-items:center;gap:6px;padding-bottom:9px">
      <input type="checkbox" id="sGw"> GoWild seats only</label>
    <button id="sGo">SEARCH</button>
    <a class="live" id="sLive" href="#" target="_blank" rel="noopener">check live on flyfrontier.com &rarr;</a>
  </div>
  <div id="sQueueNote"></div>
  <div id="sLiveRes"></div>
  <div id="sFlex"></div>
  <div id="sResults"></div>
</section>

'@
[void]$sb.Append($searchHtml.Replace('__FROMOPTS__', $fromOpts).Replace('__TOOPTS__', $toOpts))

# price-alert signup section
$routeOpts = '<option value="ANY">ANY route</option>'
foreach ($rt in @($records | ForEach-Object { '{0}-{1}' -f $_.o, $_.d } | Sort-Object -Unique)) {
    $routeOpts += ('<option value="{0}">{0}</option>' -f $rt)
}
$alertHtml = @'
<section id="alertsec">
  <h2>Price alerts</h2>
  <p class="sub">Drop your email and a route &mdash; fares get re-checked
  <strong>every hour on the hour</strong>, and you get one email the moment the
  GoWild all-in price hits your number. No account, no spam, GoWild fares only.</p>
  <div class="searchbar">
    <label>Email<input type="email" id="wEmail" placeholder="you@email.com" style="min-width:230px"></label>
    <label>Route (or ANY)<input id="wRoute" list="routeList" value="ANY"
      placeholder="MCO-PUJ" style="min-width:120px;text-transform:uppercase">
      <datalist id="routeList">__WROUTEOPTS__</datalist></label>
    <label>Alert at/under $<input type="number" id="wMax" value="90" min="20" max="500" style="min-width:84px"></label>
    <label>Travel from<input type="date" id="wFrom"></label>
    <label>Travel to<input type="date" id="wTo"></label>
    <button id="wGo">ALERT ME</button>
  </div>
  <p class="sub" id="wMsg"></p>
</section>

'@
[void]$sb.Append($alertHtml.Replace('__WROUTEOPTS__', $routeOpts))

# cash section
[void]$sb.Append('<section>' + "`n" + '  <h2>Cash fare timing</h2>' + "`n")
[void]$sb.Append(('  <p class="sub">Buy-or-wait for a normal ticket. The bar shows the observed low-to-high range; the marker is today. The shaded band is the bottom {0}% &mdash; the buy zone. Showing the top {1}; {2} quieter route-dates held back.</p>' -f [int]$cfg.buyZonePct, $cashRows.Count, $cashHeldBack) + "`n")
if ($cashRows.Count -eq 0) {
    [void]$sb.Append('  <div class="empty">No buy or watch signals yet. Signals appear once a route-date has ' + [int]$cfg.minObservations + '+ sweeps of history and its price drops into the bottom of its own range. Keep the daily sweep running.</div>' + "`n")
} else {
    [void]$sb.Append('  <table><thead><tr><th>Route</th><th>Departs</th><th>Now</th><th class="hide-sm">Range</th><th class="hide-sm">Pct</th><th>Call</th></tr></thead><tbody>' + "`n")
    $i = 0
    foreach ($r in $cashRows) { [void]$sb.Append((CashRowHtml $r $i)); $i++ }
    [void]$sb.Append('  </tbody></table>' + "`n")
}
[void]$sb.Append('</section>' + "`n`n")

# gowild section
[void]$sb.Append('<section>' + "`n" + '  <h2>GoWild booking window</h2>' + "`n")
[void]$sb.Append(('  <p class="sub">Per the pass terms, GoWild booking opens <strong>1 day before departure for domestic</strong> flights and <strong>{0} days before for international</strong>. Prices and seat counts are read <strong>directly from flyfrontier.com</strong> at sweep time &mdash; all-in one-way totals ($0.01 fare + taxes and fees). A seat shown here can be gone by the time you book; rows marked proxy have not been swept yet. Top {1} of {2} in window.</p>' -f $window, $gwRows.Count, $gwPool.Count) + "`n")
if ($gwRows.Count -eq 0) {
    [void]$sb.Append('  <div class="empty">No departures inside the GoWild window yet &mdash; run a sweep first.</div>' + "`n")
} else {
    [void]$sb.Append('  <table id="gwtable"><thead><tr><th>Route</th><th>Departs</th><th class="hide-sm">Cash</th><th>GoWild</th><th>Pass seats</th><th>Basis</th><th></th></tr></thead><tbody>' + "`n")
    $i = 0
    foreach ($r in $gwRows) { [void]$sb.Append((GwRowHtml $r $i)); $i++ }
    [void]$sb.Append('  </tbody></table>' + "`n")
}
[void]$sb.Append('</section>' + "`n")

[void]$sb.Append(@'

<footer>
<p><b>GoWild figures are a snapshot, not a hold.</b> They are read from
Frontier&#39;s public booking pages at sweep time. Pass inventory moves fast
inside the booking window &mdash; treat a shown seat as &quot;worth checking
now,&quot; and confirm logged in at flyfrontier.com before you count on it.</p>
<p><b>Fares are all-in one-way totals</b> from the pricing API, and exclude bags
and seat assignments, which is where Frontier makes its money. Compare
like for like before calling anything cheap.</p>
</footer>
<form name="watch" method="POST" action="/" netlify netlify-honeypot="bot-field" hidden>
  <input name="email"><input name="route"><input name="maxprice"><input name="datefrom"><input name="dateto"><input name="bot-field">
</form>
<form name="recheck" method="POST" action="/" netlify hidden>
  <input name="route"><input name="date">
</form>
'@)

# embedded data + search logic
$fwItems = New-Object System.Collections.ArrayList
foreach ($r in @($records | Sort-Object @{ Expression = { $_.key } })) {
    [void]$fwItems.Add(@{
        o = $r.o; d = $r.d; dep = $r.dep.ToString('yyyy-MM-dd')
        cash = [Math]::Round($r.cur, 2); g = [Math]::Round($r.g, 2)
        gc = $r.gc; fc = $r.fc; sig = $r.sig; u = $r.u
    })
}
$fwJson = '[]'
if ($fwItems.Count -gt 0) { $fwJson = ConvertTo-Json @($fwItems) -Compress -Depth 3 }

$searchJs = @'
<script>
var FW = __FWDATA__;
var FWFORM = __FWFORM__;
var MONTHS = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
function el(i){ return document.getElementById(i); }
function money(v){ return (v == null || v < 0) ? '&mdash;' : '$' + Number(v).toFixed(2); }
function fmtD(ds){ var p = ds.split('-'); return encodeURIComponent(MONTHS[+p[1]-1] + ' ' + (+p[2]) + ', ' + p[0]); }
function liveUrl(o, d, ds, ret){
  var u = 'https://booking.flyfrontier.com/Flight/InternalSelect?s=true&o1=' + o + '&d1=' + d + '&ADT=1&mon=true';
  if (ds) { u += '&dd1=' + fmtD(ds); }
  if (ret) { u += '&dd2=' + fmtD(ret); }
  return u;
}
function updLive(){
  var rt = el('sTrip').value === 'rt';
  el('sRetLbl').style.display = rt ? '' : 'none';
  el('sLive').href = liveUrl(el('sFrom').value, el('sTo').value, el('sDate').value, rt ? el('sRet').value : '');
}
function showWatch(o, d, g){
  el('wRoute').value = o + '-' + d;
  el('wMax').value = Math.max(20, Math.ceil(g));
  document.getElementById('alertsec').scrollIntoView({ behavior: 'smooth' });
  el('wEmail').focus();
}
function submitWatch(){
  var em = el('wEmail').value.trim();
  var rt = el('wRoute').value.trim().toUpperCase();
  var mx = el('wMax').value;
  var df = el('wFrom').value, dt = el('wTo').value;
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(em)) { el('wMsg').textContent = 'Please enter a valid email address.'; return; }
  if (!/^([A-Z]{3}-[A-Z]{3}|ANY)$/.test(rt)) { el('wMsg').textContent = 'Route must look like MCO-PUJ (airport codes), or ANY.'; return; }
  if (df && dt && df > dt) { el('wMsg').textContent = 'Travel-from date is after travel-to date.'; return; }
  if (FWFORM.action) {
    var fd = new FormData();
    fd.append(FWFORM.emailEntry, em);
    fd.append(FWFORM.routeEntry, rt);
    fd.append(FWFORM.priceEntry, mx);
    fetch(FWFORM.action, { method: 'POST', mode: 'no-cors', body: fd });
    el('wMsg').textContent = 'You are on the list! ' + rt + ' will be checked hourly; one email lands when the GoWild total is $' + mx + ' or less.';
    el('wEmail').value = '';
  } else if (location.protocol !== 'file:') {
    var params = 'form-name=watch&email=' + encodeURIComponent(em) + '&route=' + encodeURIComponent(rt) + '&maxprice=' + encodeURIComponent(mx)
      + '&datefrom=' + encodeURIComponent(df) + '&dateto=' + encodeURIComponent(dt);
    var range = (df || dt) ? (' for travel ' + (df || 'now') + ' to ' + (dt || 'anytime')) : '';
    fetch('/', { method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body: params })
      .then(function(){ el('wMsg').textContent = 'You are on the list! ' + rt + range + ' - checked hourly; one email lands when the GoWild total is $' + mx + ' or less.'; el('wEmail').value = ''; })
      .catch(function(){ el('wMsg').textContent = 'Signup hiccup - try again in a minute.'; });
  } else {
    el('wMsg').textContent = 'Opening your email app - just hit send and you will be added.';
    location.href = 'mailto:' + FWFORM.fallback
      + '?subject=' + encodeURIComponent('FareWatch alert request')
      + '&body=' + encodeURIComponent('Please add me to FareWatch price alerts.\nEmail: ' + em + '\nRoute: ' + rt + '\nAlert at or under: $' + mx);
  }
}
// Auto-queue a fresh sweep when we have NO data at all for the searched
// route. Tracked routes refresh hourly on their own; queueing only the
// unknowns keeps us inside Netlify's 100-submissions/month form allowance.
// Throttled to once per route per browser per 24h.
function autoQueue(o, d, ds, pair){
  if (location.protocol === 'file:') { return; }
  if (pair.length > 0) { el('sQueueNote').innerHTML = ''; return; }
  var key = 'fwq_' + o + d;
  try {
    var last = +localStorage.getItem(key) || 0;
    if (Date.now() - last < 24 * 3600 * 1000) {
      el('sQueueNote').innerHTML = '<p class="sub">Fresh sweep for ' + o + ' &rarr; ' + d + ' is already queued &mdash; prices update within the hour.</p>';
      return;
    }
    localStorage.setItem(key, String(Date.now()));
  } catch (e) { }
  var params = 'form-name=recheck&route=' + encodeURIComponent(o + '-' + d) + '&date=' + encodeURIComponent(ds || '');
  fetch('/', { method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body: params })
    .then(function(){ el('sQueueNote').innerHTML = '<p class="sub">&#10003; Fresh sweep queued for ' + o + ' &rarr; ' + d + (ds ? ' on ' + ds : ' (next 10 days)') + ' &mdash; prices here update within the hour.</p>'; })
    .catch(function(){ });
}

// Flexible dates: rank the next 10 days of this route from local lows to
// local highs. Uses real GoWild fares where the booking window is open,
// otherwise soft-cash as the forecast (soft cash = pass seats usually clear).
function flexPanel(o, d, pair){
  var todayIso = isoDate(new Date());
  var limIso = isoDate(new Date(Date.now() + 10 * 864e5));
  var days = pair.filter(function(r){ return r.dep >= todayIso && r.dep <= limIso; });
  days.sort(function(a, b){ return a.dep < b.dep ? -1 : 1; });
  var withGw = days.filter(function(r){ return r.gc > 0 && r.g > 0; });
  var basis = withGw.length >= 2 ? 'gw' : 'cash';
  var vals = [];
  days.forEach(function(r){
    r._v = basis === 'gw' ? ((r.gc > 0 && r.g > 0) ? r.g : null) : (r.cash > 0 ? r.cash : null);
    if (r._v !== null) { vals.push(r._v); }
  });
  if (vals.length < 2) { el('sFlex').innerHTML = ''; return; }
  var lo = Math.min.apply(null, vals), hi = Math.max.apply(null, vals);
  var best = null;
  days.forEach(function(r){ if (r._v !== null && (best === null || r._v < best._v)) { best = r; } });
  var h = '<p class="sub"><strong>Flexible dates?</strong> Next 10 days of ' + o + ' &rarr; ' + d + ', ranked against this route&rsquo;s own local high/low'
    + (basis === 'cash' ? ' <em>(forecast from cash-fare softness &mdash; domestic GoWild only opens 1 day out)</em>' : '') + ':</p>';
  h += '<table><thead><tr><th>Date</th><th>' + (basis === 'gw' ? 'GoWild' : 'Cash') + '</th><th>Vs. local range</th><th></th></tr></thead><tbody>';
  days.forEach(function(r){
    var verdict = '<span class="delta">no data yet</span>';
    if (r._v !== null) {
      var pos = hi > lo ? (r._v - lo) / (hi - lo) : 0;
      var word, cls;
      if (pos <= 0.2) { word = 'LOW'; cls = 'BUY'; }
      else if (pos <= 0.45) { word = 'GOOD'; cls = 'WATCH'; }
      else if (pos <= 0.7) { word = 'MID'; cls = 'HOLD'; }
      else { word = 'HIGH'; cls = 'SPIKE'; }
      verdict = '<span class="sig ' + cls + '">' + word + '</span>';
      if (best && r.dep === best.dep) { verdict += ' <span class="sig BUY">&#9733; BEST BET</span>'; }
    }
    h += '<tr class="row"><td class="num">' + r.dep + '</td>'
      + '<td class="num">' + (r._v !== null ? money(r._v) : '&mdash;') + '</td>'
      + '<td>' + verdict + '</td>'
      + '<td><a class="rowbtn" target="_blank" rel="noopener" href="' + liveUrl(o, d, r.dep) + '">live</a></td></tr>';
  });
  h += '</tbody></table>';
  el('sFlex').innerHTML = h;
}

// Float the searched departure airport to the top of the GoWild window table.
function floatGwOrigin(o){
  var tb = document.querySelector('#gwtable tbody');
  if (!tb) { return; }
  var rows = Array.prototype.slice.call(tb.rows);
  var mine = rows.filter(function(r){ return r.getAttribute('data-o') === o; });
  var rest = rows.filter(function(r){ return r.getAttribute('data-o') !== o; });
  mine.concat(rest).forEach(function(r){ tb.appendChild(r); });
}
function cachedRowsHtml(rows){
  var h = '<table><thead><tr><th>Route</th><th>Departs</th><th class="hide-sm">Cash</th><th>GoWild</th><th>Pass seats</th><th></th></tr></thead><tbody>';
  rows.slice(0, 30).forEach(function(r){
    h += '<tr class="row"><td><div class="route">' + r.o + ' <span>&rarr;</span> ' + r.d + '</div></td>'
      + '<td class="num">' + r.dep + '</td>'
      + '<td class="num hide-sm">' + money(r.cash) + '</td>'
      + '<td class="num">' + (r.gc > 0 ? '<span class="price">' + money(r.g) + '</span>' : '<span class="delta">&mdash;</span>') + '</td>'
      + '<td class="num">' + (r.fc ? r.gc + '/' + r.fc : '<span class="delta">not swept</span>') + '</td>'
      + '<td><a class="rowbtn" target="_blank" rel="noopener" href="' + liveUrl(r.o, r.d, r.dep) + '">live</a> '
      + '<button class="rowbtn" onclick="showWatch(\'' + r.o + '\',\'' + r.d + '\',' + (r.gc > 0 ? r.g : 60) + ')">watch</button></td></tr>';
  });
  h += '</tbody></table>';
  return h;
}
function doSearch(){
  updLive();
  var o = el('sFrom').value, d = el('sTo').value, ds = el('sDate').value, gwOnly = el('sGw').checked;
  liveFetch(o, d, ds);
  var pair = FW.filter(function(r){ return r.o === o && r.d === d && (!gwOnly || r.gc > 0); });
  autoQueue(o, d, ds, pair);
  flexPanel(o, d, pair);
  floatGwOrigin(o);
  var rows = pair.filter(function(r){ return !ds || r.dep === ds; });
  rows.sort(function(a, b){
    var ag = a.gc > 0 ? a.g : 1e9, bg = b.gc > 0 ? b.g : 1e9;
    return (ag - bg) || (a.cash - b.cash) || (a.dep < b.dep ? -1 : 1);
  });
  var h = '';
  if (el('sTrip').value === 'rt') {
    h += '<p class="sub">Tracked prices are one-way each way (GoWild is booked one-way anyway). The live link above opens the full round-trip search on Frontier.</p>';
  }
  if (rows.length) {
    h += '<p class="sub">From the last sweep (tracked routes only):</p>' + cachedRowsHtml(rows);
  } else {
    // nothing on that exact date: suggest the same route across the next 10 days
    var todayIso = isoDate(new Date());
    var limIso = isoDate(new Date(Date.now() + 10 * 864e5));
    var sugg = pair.filter(function(r){ return r.dep >= todayIso && r.dep <= limIso; });
    sugg.sort(function(a, b){ return a.dep < b.dep ? -1 : 1; });
    if (sugg.length) {
      h += '<p class="sub">Nothing tracked for ' + o + ' &rarr; ' + d + (ds ? ' on ' + ds : '') + ' &mdash; here is the same route over the <strong>next 10 days</strong> instead:</p>' + cachedRowsHtml(sugg);
    } else {
      h += '<div class="empty">No swept data for ' + o + ' &rarr; ' + d + ' yet'
        + (gwOnly ? ' with pass seats (try unchecking the box)' : '')
        + '. A fresh sweep of the next 10 days was queued automatically &mdash; check back within the hour, or open it live with the flyfrontier.com link above.</div>';
    }
  }
  el('sResults').innerHTML = h;
}
function isoDate(dt){ return dt.getFullYear() + '-' + String(dt.getMonth()+1).padStart(2,'0') + '-' + String(dt.getDate()).padStart(2,'0'); }
function fmtT(s){ var t = new Date(s); var h = t.getHours(), m = String(t.getMinutes()).padStart(2,'0'); var ap = h >= 12 ? 'p' : 'a'; h = h % 12; if (h === 0) h = 12; return h + ':' + m + ap; }
function liveFetch(o, d, ds){
  if (location.protocol === 'file:') { return; }
  var dates = ds ? [ds] : [isoDate(new Date()), isoDate(new Date(Date.now() + 864e5))];
  el('sLiveRes').innerHTML = '<div class="empty">checking flyfrontier.com live for ' + o + ' &rarr; ' + d + '...</div>';
  Promise.all(dates.map(function(dt){
    return fetch('/.netlify/functions/fares?o=' + o + '&d=' + d + '&date=' + dt)
      .then(function(r){ return r.json(); })
      .then(function(j){ return { dt: dt, j: j }; })
      .catch(function(){ return { dt: dt, j: null }; });
  })).then(function(results){
    var rows = [];
    var failed = true;
    results.forEach(function(res){
      if (res.j && res.j.flights) { failed = false; res.j.flights.forEach(function(f){ f._dt = res.dt; rows.push(f); }); }
    });
    var blocked = results.some(function(res){ return res.j && res.j.blocked; });
    if (failed || (blocked && !rows.length)) {
      el('sLiveRes').innerHTML = '';
      return;
    }
    if (!rows.length) {
      el('sLiveRes').innerHTML = '<p class="sub"><strong>LIVE</strong> &mdash; checked seconds ago: no ' + o + ' &rarr; ' + d + ' flights on ' + dates.join(' or ') + ' &mdash; see other days for this route below.</p>';
      return;
    }
    rows.sort(function(a, b){
      var ag = (a.gwOn && a.gw > 0) ? a.gw : 1e9, bg = (b.gwOn && b.gw > 0) ? b.gw : 1e9;
      return (ag - bg) || (a.cash - b.cash);
    });
    var h = '<p class="sub"><strong>LIVE</strong> &mdash; checked seconds ago, straight from flyfrontier.com:</p>';
    h += '<table><thead><tr><th>Flight</th><th>Departs</th><th class="hide-sm">Stops</th><th class="hide-sm">Cash</th><th>GoWild</th><th></th></tr></thead><tbody>';
    rows.slice(0, 20).forEach(function(f){
      h += '<tr class="row"><td><div class="route">' + f.fn + '</div></td>'
        + '<td class="num">' + f._dt + '<span class="delta">' + fmtT(f.dep) + ' &rarr; ' + fmtT(f.arr) + '</span></td>'
        + '<td class="num hide-sm">' + (f.stops === 0 ? 'nonstop' : f.stops + ' stop') + '</td>'
        + '<td class="num hide-sm">' + money(f.cash) + '</td>'
        + '<td class="num">' + ((f.gwOn && f.gw > 0) ? '<span class="price">' + money(f.gw) + '</span><span class="delta">pass seat!</span>' : '<span class="delta">&mdash; none</span>') + '</td>'
        + '<td><a class="bookbtn' + ((f.gwOn && f.gw > 0) ? '' : ' dim') + '" target="_blank" rel="noopener" href="' + liveUrl(o, d, f._dt) + '">BOOK &rarr;</a></td></tr>';
    });
    h += '</tbody></table>';
    el('sLiveRes').innerHTML = h;
  });
}
document.addEventListener('DOMContentLoaded', function(){
  el('sGo').onclick = doSearch;
  el('wGo').onclick = submitWatch;
  el('wEmail').addEventListener('keydown', function(e){ if (e.key === 'Enter') submitWatch(); });
  ['sFrom','sTo','sDate','sGw','sTrip','sRet'].forEach(function(i){ el(i).onchange = updLive; });
  updLive();
  doSearch();
});
</script>
'@
$formCfg = @{
    action = [string]$cfg.watchIntake.formAction
    emailEntry = [string]$cfg.watchIntake.emailEntry
    routeEntry = [string]$cfg.watchIntake.routeEntry
    priceEntry = [string]$cfg.watchIntake.priceEntry
    fallback = [string]$cfg.watchIntake.fallbackEmail
}
[void]$sb.Append($searchJs.Replace('__FWDATA__', $fwJson).Replace('__FWFORM__', ($formCfg | ConvertTo-Json -Compress)))
[void]$sb.Append('</div></body></html>')

$outPath = Get-FwPath 'dashboard.html'
Write-FwUtf8 $outPath $sb.ToString()
Write-Output ('Dashboard written: {0} ({1} route-dates, {2} buy / {3} watch)' -f $outPath, $records.Count, $tally.BUY, $tally.WATCH)
