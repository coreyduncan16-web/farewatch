# Registers a Windows Scheduled Task that runs the FareWatch sweep.
# Run this yourself from an elevated-or-normal PowerShell prompt:
#   powershell -ExecutionPolicy Bypass -File .\register-schedule.ps1
# Optional: -Time '06:45'      pick the first run time of the day.
# Optional: -EveryHours 1      repeat the sweep every N hours through the day
#                              (pair with "minRefreshHours" in config.json so the
#                               re-runs actually refresh prices).

param([string]$Time = '07:30', [int]$EveryHours = 0)

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

Register-ScheduledTask -TaskName 'FareWatch daily sweep' -Action $action `
    -Trigger $trigger -Settings $settings `
    -Description 'FareWatch: sweep Frontier fares and re-render dashboard.html'

if ($EveryHours -gt 0) {
    Write-Output ('Registered "FareWatch daily sweep" starting {0}, repeating every {1}h. Remove with: Unregister-ScheduledTask -TaskName "FareWatch daily sweep"' -f $Time, $EveryHours)
} else {
    Write-Output ('Registered "FareWatch daily sweep" at {0} daily. Remove with: Unregister-ScheduledTask -TaskName "FareWatch daily sweep"' -f $Time)
}
