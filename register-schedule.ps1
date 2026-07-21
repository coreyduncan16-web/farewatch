# Registers the FareWatch scheduled tasks:
#   1. "FareWatch daily sweep"  - full fare sweep once a day (default 07:30)
#   2. "FareWatch hourly watch" - light watched-routes check, every hour on
#      the hour (only touches routes people are watching)
# Run it yourself:
#   powershell -ExecutionPolicy Bypass -File .\register-schedule.ps1
# Re-running replaces the existing tasks.

param([string]$Time = '07:30')

$root = Split-Path -Parent $MyInvocation.MyCommand.Path

foreach ($name in @('FareWatch daily sweep', 'FareWatch hourly watch', 'FareWatch quick queue')) {
    try { Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction Stop } catch { }
}

$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopOnIdleEnd

# Prefer S4U (fully windowless, cannot be closed by accident) - needs admin.
# Fall back to the normal interactive principal with a hidden window.
$principal = $null
try {
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType S4U -RunLevel Limited
} catch { }

function Register-FwTask($name, $scriptFile, $trigger, $desc) {
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}\{1}"' -f $root, $scriptFile) `
        -WorkingDirectory $root
    try {
        Register-ScheduledTask -TaskName $name -Action $action -Trigger $trigger `
            -Settings $settings -Principal $principal -Description $desc -ErrorAction Stop | Out-Null
        Write-Output ('{0}: registered windowless (S4U)' -f $name)
    } catch {
        Register-ScheduledTask -TaskName $name -Action $action -Trigger $trigger `
            -Settings $settings -Description $desc | Out-Null
        Write-Output ('{0}: registered with hidden window (run register-schedule.ps1 from an admin PowerShell for fully windowless)' -f $name)
    }
}

$dailyTrigger = New-ScheduledTaskTrigger -Daily -At $Time
Register-FwTask 'FareWatch daily sweep' 'run-daily.ps1' $dailyTrigger 'FareWatch: full daily fare sweep + dashboard + publish'

$now = Get-Date
$nextHour = $now.Date.AddHours($now.Hour + 1)
$hourlyTrigger = New-ScheduledTaskTrigger -Once -At $nextHour `
    -RepetitionInterval (New-TimeSpan -Hours 1) -RepetitionDuration (New-TimeSpan -Days 3650)
Register-FwTask 'FareWatch hourly watch' 'run-hourly.ps1' $hourlyTrigger 'FareWatch: hourly GoWild price check for watched routes + alerts'

# quick queue: every 2 minutes, sweeps website searches the moment they land
$quickTrigger = New-ScheduledTaskTrigger -Once -At ($now.AddMinutes(2)) `
    -RepetitionInterval (New-TimeSpan -Minutes 2) -RepetitionDuration (New-TimeSpan -Days 3650)
Register-FwTask 'FareWatch quick queue' 'quick-check.ps1' $quickTrigger 'FareWatch: near-instant sweep of routes searched on the website'

Write-Output ('Registered: "FareWatch daily sweep" daily at {0}, and "FareWatch hourly watch" every hour on the hour starting {1}.' -f $Time, $nextHour.ToString('HH:mm'))
Write-Output 'Remove with: Unregister-ScheduledTask -TaskName "FareWatch daily sweep","FareWatch hourly watch"'
