# Self-contained test for the hourly-refresh fix. No network, no API key.
# Run:  powershell -ExecutionPolicy Bypass -File .\test-refresh.ps1
# Exits non-zero if any assertion fails.

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$fail = 0
function Assert($cond, $msg) {
    if ($cond) { Write-Output ("  PASS  " + $msg) }
    else { Write-Output ("  FAIL  " + $msg); $script:fail++ }
}

# --- 1. Read-FwHistory preserves the 't' timestamp -----------------------
$tmp = Join-Path $env:TEMP ('fw-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
New-Item -ItemType Directory -Path (Join-Path $tmp 'data') | Out-Null
$script:FwRoot = $tmp
$stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
$today = (Get-Date).ToString('yyyy-MM-dd')
$sample = @{ 'ATL-CUN|2026-09-01' = @( @{ d = $today; t = $stamp; p = 149 } ) }
Save-FwHistory $sample
$round = Read-FwHistory
$rec = $round['ATL-CUN|2026-09-01'][0]
Assert ($rec.ContainsKey('t')) "'t' survives the history save/read round-trip"
Assert ([string]$rec.t -eq $stamp) "'t' value is unchanged"

# --- 2. Freshness gate: mirrors sweep.ps1's staleHours logic -------------
function Get-StaleHours($last, $nowLocal) {
    $staleHours = 1000000.0
    if ($null -ne $last) {
        $lastTime = $null
        if ($last.ContainsKey('t') -and [string]$last.t -ne '') {
            try { $lastTime = ([datetimeoffset]::Parse([string]$last.t, [System.Globalization.CultureInfo]::InvariantCulture)).LocalDateTime } catch { $lastTime = $null }
        }
        if ($null -eq $lastTime) {
            try { $lastTime = [datetime]::ParseExact([string]$last.d, 'yyyy-MM-dd', $null) } catch { $lastTime = $null }
        }
        if ($null -ne $lastTime) { $staleHours = ($nowLocal - $lastTime).TotalHours }
    }
    $staleHours
}
$now = Get-Date
$min = 1.0
$halfHrAgo = @{ d = $today; t = ((Get-Date).AddMinutes(-30)).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'); p = 100 }
$twoHrAgo  = @{ d = $today; t = ((Get-Date).AddHours(-2)).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ');  p = 100 }
Assert ((Get-StaleHours $halfHrAgo $now) -lt $min) "route priced 30 min ago is skipped when minRefreshHours=1"
Assert ((Get-StaleHours $twoHrAgo  $now) -ge $min) "route priced 2 h ago is eligible when minRefreshHours=1"
Assert ((Get-StaleHours $null      $now) -ge $min) "never-seen route is always eligible"
$dateOnlyYesterday = @{ d = (Get-Date).AddDays(-1).ToString('yyyy-MM-dd'); p = 100 }
Assert ((Get-StaleHours $dateOnlyYesterday $now) -ge $min) "legacy date-only record from yesterday is eligible"

Remove-Item -Recurse -Force $tmp
Write-Output ''
if ($fail -eq 0) { Write-Output 'ALL TESTS PASSED'; exit 0 }
else { Write-Output ("{0} TEST(S) FAILED" -f $fail); exit 1 }
