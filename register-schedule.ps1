# Registers a Windows Scheduled Task that runs the FareWatch sweep once a day.
# Run this yourself from an elevated-or-normal PowerShell prompt:
#   powershell -ExecutionPolicy Bypass -File .\register-schedule.ps1
# Optional: -Time '06:45' to pick a different local run time.

param([string]$Time = '07:30')

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument ('-NoProfile -ExecutionPolicy Bypass -File "{0}\run-daily.ps1"' -f $root) `
    -WorkingDirectory $root
$trigger = New-ScheduledTaskTrigger -Daily -At $Time
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopOnIdleEnd

Register-ScheduledTask -TaskName 'FareWatch daily sweep' -Action $action `
    -Trigger $trigger -Settings $settings `
    -Description 'FareWatch: sweep Frontier fares and re-render dashboard.html'

Write-Output ('Registered "FareWatch daily sweep" at {0} daily. Remove with: Unregister-ScheduledTask -TaskName "FareWatch daily sweep"' -f $Time)
