# Registers the FareWatch scheduled tasks:
#   1. "FareWatch daily sweep"  - full fare sweep once a day (default 07:30)
#   2. "FareWatch hourly watch" - light watched-routes check, every hour on
#      the hour (only touches routes people are watching)
# Run it yourself:
#   powershell -ExecutionPolicy Bypass -File .\register-schedule.ps1
# Re-running replaces the existing tasks.

param([string]$Time = '07:30')

$root = Split-Path -Parent $MyInvocation.MyCommand.Path

foreach ($name in @('FareWatch daily sweep', 'FareWatch hourly watch')) {
    try { Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction Stop } catch { }
}

$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopOnIdleEnd

# daily full sweep
$dailyAction = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument ('-NoProfile -ExecutionPolicy Bypass -File "{0}\run-daily.ps1"' -f $root) `
    -WorkingDirectory $root
$dailyTrigger = New-ScheduledTaskTrigger -Daily -At $Time
Register-ScheduledTask -TaskName 'FareWatch daily sweep' -Action $dailyAction `
    -Trigger $dailyTrigger -Settings $settings `
    -Description 'FareWatch: full daily fare sweep + dashboard + publish'

# hourly watch check, on the hour
$now = Get-Date
$nextHour = $now.Date.AddHours($now.Hour + 1)
$hourlyAction = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument ('-NoProfile -ExecutionPolicy Bypass -File "{0}\run-hourly.ps1"' -f $root) `
    -WorkingDirectory $root
$hourlyTrigger = New-ScheduledTaskTrigger -Once -At $nextHour `
    -RepetitionInterval (New-TimeSpan -Hours 1) -RepetitionDuration (New-TimeSpan -Days 3650)
Register-ScheduledTask -TaskName 'FareWatch hourly watch' -Action $hourlyAction `
    -Trigger $hourlyTrigger -Settings $settings `
    -Description 'FareWatch: hourly GoWild price check for watched routes + alerts'

Write-Output ('Registered: "FareWatch daily sweep" daily at {0}, and "FareWatch hourly watch" every hour on the hour starting {1}.' -f $Time, $nextHour.ToString('HH:mm'))
Write-Output 'Remove with: Unregister-ScheduledTask -TaskName "FareWatch daily sweep","FareWatch hourly watch"'
