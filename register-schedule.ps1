# Registers a Windows Scheduled Task that runs the FareWatch sweep every
# 6 hours (4 times a day). Re-running this script REPLACES the existing task,
# so it also cleans up any earlier schedule that was firing too often.
# Run this yourself from an elevated-or-normal PowerShell prompt:
#   powershell -ExecutionPolicy Bypass -File .\register-schedule.ps1
# Optional: -Time '06:45'      pick the first run time of the day.
# Optional: -EveryHours 12     change the repeat interval (0 = once a day only).
#                              Keep "minRefreshHours" in config.json matched to
#                              it so each run actually refreshes prices.

param([string]$Time = '07:30', [int]$EveryHours = 6)

$taskName = 'FareWatch daily sweep'

# Replace any existing FareWatch task so a stale/misconfigured schedule
# (e.g. one repeating every few seconds) cannot keep running alongside.
$existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($existing) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    Write-Output ('Removed existing "{0}" task.' -f $taskName)
}

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument ('-NoProfile -ExecutionPolicy Bypass -File "{0}\run-daily.ps1"' -f $root) `
    -WorkingDirectory $root
$trigger = New-ScheduledTaskTrigger -Daily -At $Time
if ($EveryHours -gt 0) {
    # Attach a same-day repetition to the daily trigger so it fires every N hours.
    $rep = (New-ScheduledTaskTrigger -Once -At $Time `
        -RepetitionInterval (New-TimeSpan -Hours $EveryHours) `
        -RepetitionDuration (New-TimeSpan -Hours 24)).Repetition
    $trigger.Repetition = $rep
}
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopOnIdleEnd

Register-ScheduledTask -TaskName $taskName -Action $action `
    -Trigger $trigger -Settings $settings `
    -Description 'FareWatch: sweep Frontier fares and re-render dashboard.html'

if ($EveryHours -gt 0) {
    Write-Output ('Registered "{0}" starting {1}, repeating every {2}h ({3} runs/day). Remove with: Unregister-ScheduledTask -TaskName "{0}"' -f $taskName, $Time, $EveryHours, [Math]::Floor(24 / $EveryHours))
} else {
    Write-Output ('Registered "{0}" at {1} daily. Remove with: Unregister-ScheduledTask -TaskName "{0}"' -f $taskName, $Time)
}
