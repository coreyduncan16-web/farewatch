# Friendly one-time email setup for FareWatch alerts.
# Run it by double-clicking setup-email.bat in this folder.
# Asks for your Gmail App Password, writes it into the local .env file
# (which never leaves this computer), then sends a test email.

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$envPath = Join-Path $root '.env'

Write-Host ''
Write-Host '=== FareWatch email setup ===' -ForegroundColor Green
Write-Host ''
Write-Host 'You need a Gmail App Password (16 letters) from:'
Write-Host '  https://myaccount.google.com/apppasswords' -ForegroundColor Cyan
Write-Host '(2-Step Verification must be on first.)'
Write-Host ''

$email = Read-Host 'Your Gmail address [coreyduncan16@gmail.com]'
if ([string]::IsNullOrWhiteSpace($email)) { $email = 'coreyduncan16@gmail.com' }

$appPass = Read-Host 'Paste the 16-letter App Password (spaces are OK)'
$appPass = ($appPass -replace '\s', '')
if ($appPass.Length -lt 16) {
    Write-Host ''
    Write-Host ('That looks too short ({0} characters) - App Passwords are 16 letters. Run this again with the full code.' -f $appPass.Length) -ForegroundColor Yellow
    Read-Host 'Press Enter to close'
    exit 1
}

# keep every non-SMTP line already in .env
$lines = @()
if (Test-Path $envPath) {
    $lines = @(Get-Content $envPath -Encoding UTF8 | Where-Object { $_ -notmatch '^SMTP_' })
}
$lines += 'SMTP_HOST=smtp.gmail.com'
$lines += 'SMTP_PORT=587'
$lines += ('SMTP_USER=' + $email)
$lines += ('SMTP_PASS=' + $appPass)
$lines += ('SMTP_FROM=' + $email)
Set-Content -Path $envPath -Value $lines -Encoding UTF8

Write-Host ''
Write-Host 'Saved. Sending a test email to yourself...' -ForegroundColor Green
Write-Host ''

& (Join-Path $root 'alerts.ps1') -TestEmail

Write-Host ''
Read-Host 'Press Enter to close'
