# Publishes the latest dashboard:
#   1. copies it to docs\ and commits (GitHub Pages serves this when healthy)
#   2. if NETLIFY_TOKEN + NETLIFY_SITE_ID are in .env, ALSO uploads straight
#      to Netlify - no GitHub involved, so outages there cannot block the site.
# Safe to run anytime.

[CmdletBinding()]
param([string]$Message = 'fare update')

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
Set-Location $root
. (Join-Path $root 'common.ps1')

$git = 'git'
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    $portable = 'D:\CLAUDE\Git\cmd\git.exe'
    if (Test-Path $portable) { $git = $portable }
    else { throw 'git not found on PATH or at D:\CLAUDE\Git\cmd\git.exe' }
}

if (-not (Test-Path (Join-Path $root 'dashboard.html'))) {
    throw 'dashboard.html not found - run sweep.ps1 or render.ps1 first.'
}

$docs = Join-Path $root 'docs'
if (-not (Test-Path $docs)) { New-Item -ItemType Directory -Path $docs | Out-Null }
Copy-Item (Join-Path $root 'dashboard.html') (Join-Path $docs 'index.html') -Force
# tiny freshness beacon the page polls to know a live sweep just landed
$metaSrc = Join-Path $root 'data\meta.json'
if (Test-Path $metaSrc) { Copy-Item $metaSrc (Join-Path $docs 'meta.json') -Force }

& $git add docs
& $git commit -m $Message 2>$null
if ($LASTEXITCODE -ne 0) { Write-Output 'publish: nothing new to commit.' }

$remote = & $git remote
if ($remote) {
    & $git push
    if ($LASTEXITCODE -eq 0) { Write-Output 'publish: pushed to GitHub - the live site updates in about a minute.' }
    else { Write-Output 'publish: push failed - check your GitHub sign-in (GitHub Desktop or git credential manager).' }
} else {
    Write-Output 'publish: committed locally. No GitHub remote configured yet - see README section "Hosting it for everyone".'
}

# --- Netlify direct upload (outage-proof path) ---
# Uses the file-digest deploy API so the live-search function deploys too
# (the simple zip method only handles static files).
$secrets = Read-FwEnv
$nToken = $secrets['NETLIFY_TOKEN']
$nSite  = $secrets['NETLIFY_SITE_ID']
$backoffPath = Join-Path $root 'data\netlify-backoff.txt'
$inBackoff = $false
if (Test-Path $backoffPath) {
    $age = (Get-Date) - (Get-Item $backoffPath).LastWriteTime
    if ($age.TotalMinutes -lt 20) { $inBackoff = $true }
}
if ($inBackoff) {
    Write-Output 'publish: Netlify rate-limit backoff active - skipping this round (GitHub mirror still updated; next run retries).'
} elseif ($nToken -and $nSite) {
    try {
        $auth = @{ Authorization = 'Bearer ' + $nToken }

        function Get-HashHex($algo, [string]$path) {
            $h = [System.Security.Cryptography.HashAlgorithm]::Create($algo)
            $bytes = $h.ComputeHash([IO.File]::ReadAllBytes($path))
            (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
        }

        # static files (everything under docs\ except the functions folder)
        $files = @{}; $byHash = @{}
        foreach ($f in (Get-ChildItem $docs -Recurse -File | Where-Object { $_.FullName -notmatch '\\netlify\\functions\\' })) {
            $rel = '/' + $f.FullName.Substring($docs.Length + 1).Replace('\', '/')
            $sha1 = Get-HashHex 'SHA1' $f.FullName
            $files[$rel] = $sha1
            if (-not $byHash.ContainsKey($sha1)) { $byHash[$sha1] = @() }
            $byHash[$sha1] += @(@{ rel = $rel; path = $f.FullName })
        }

        # function bundle: zip each .js in docs\netlify\functions
        $functions = @{}; $fnZips = @{}; $fnByHash = @{}
        $fnDir = Join-Path $docs 'netlify\functions'
        if (Test-Path $fnDir) {
            foreach ($fn in (Get-ChildItem $fnDir -Filter '*.js' -File)) {
                $fnName = [IO.Path]::GetFileNameWithoutExtension($fn.Name)
                $zipPath = Join-Path $env:TEMP ('fw-fn-' + $fnName + '.zip')
                if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
                Compress-Archive -Path $fn.FullName -DestinationPath $zipPath -Force
                $sha256 = Get-HashHex 'SHA256' $zipPath
                $functions[$fnName] = $sha256
                $fnZips[$fnName] = $zipPath
                $fnByHash[$sha256] = $fnName   # required_functions comes back as hashes
            }
        }

        # clear any half-finished deploys so they cannot block this one
        try {
            $recent = Invoke-RestMethod -Uri ('https://api.netlify.com/api/v1/sites/{0}/deploys?per_page=5' -f $nSite) -Headers $auth -TimeoutSec 60
            foreach ($old in @($recent | Where-Object { $_.state -eq 'uploading' -or $_.state -eq 'prepared' })) {
                Invoke-RestMethod -Method Post -Uri ('https://api.netlify.com/api/v1/deploys/{0}/cancel' -f $old.id) -Headers $auth -TimeoutSec 60 | Out-Null
            }
        } catch { }

        $body = @{ files = $files; functions = $functions } | ConvertTo-Json -Depth 4
        # Netlify rate-limits deploy creation when we publish rapidly; retry
        # once, then back off for 20 minutes so we stop feeding the limiter
        $dep = $null
        for ($try = 1; $try -le 2; $try++) {
            try {
                $dep = Invoke-RestMethod -Method Post -Uri ('https://api.netlify.com/api/v1/sites/{0}/deploys' -f $nSite) `
                    -Headers $auth -ContentType 'application/json' -Body $body -TimeoutSec 120
                break
            } catch {
                $code = 0
                try { $code = [int]$_.Exception.Response.StatusCode } catch { }
                if (($code -eq 403 -or $code -eq 429) -and $try -lt 2) {
                    Write-Output 'publish: Netlify rate limit, one spaced retry in 80s...'
                    Start-Sleep -Seconds 80
                } elseif ($code -eq 403 -or $code -eq 429) {
                    Set-Content -Path $backoffPath -Value ([string](Get-Date)) -Encoding ASCII
                    Write-Output 'publish: Netlify still rate-limited - backing off 20 min (GitHub mirror stays current).'
                    $dep = $null
                    break
                } else { throw }
            }
        }
        if ($null -eq $dep) { return }

        foreach ($sha in @($dep.required)) {
            foreach ($entry in @($byHash[$sha])) {
                $urlPath = ($entry.rel.TrimStart('/').Split('/') | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'
                $putUri = 'https://api.netlify.com/api/v1/deploys/{0}/files/{1}' -f $dep.id, $urlPath
                if ((Get-Item $entry.path).Length -eq 0) {
                    # -InFile chokes on 0-byte files (this is what kept 400ing on .nojekyll)
                    Invoke-RestMethod -Method Put -Uri $putUri -Headers $auth -ContentType 'application/octet-stream' -Body '' -TimeoutSec 120 | Out-Null
                } else {
                    Invoke-RestMethod -Method Put -Uri $putUri -Headers $auth -ContentType 'application/octet-stream' -InFile $entry.path -TimeoutSec 120 | Out-Null
                }
            }
        }
        foreach ($fnHash in @($dep.required_functions)) {
            $fnName = $fnByHash[$fnHash]
            if (-not $fnName) { continue }
            Invoke-RestMethod -Method Put -Uri ('https://api.netlify.com/api/v1/deploys/{0}/functions/{1}?runtime=js' -f $dep.id, $fnName) `
                -Headers $auth -ContentType 'application/octet-stream' -InFile $fnZips[$fnName] -TimeoutSec 180 | Out-Null
        }
        foreach ($z in $fnZips.Values) { Remove-Item $z -Force -ErrorAction SilentlyContinue }
        $state = 'uploading'
        for ($w = 0; $w -lt 8; $w++) {
            Start-Sleep -Seconds 4
            $state = [string](Invoke-RestMethod -Uri ('https://api.netlify.com/api/v1/deploys/{0}' -f $dep.id) -Headers $auth -TimeoutSec 60).state
            if ($state -eq 'ready' -or $state -eq 'error') { break }
        }
        if (Test-Path $backoffPath) { Remove-Item $backoffPath -Force -ErrorAction SilentlyContinue }
        Write-Output ('publish: Netlify deploy {0} ({1} files, {2} functions) -> {3}' -f $state, $files.Count, $functions.Count, $dep.ssl_url)
    } catch {
        $msg = $_.Exception.Message
        try {
            $sr = New-Object IO.StreamReader($_.Exception.Response.GetResponseStream())
            $msg += ' | ' + $sr.ReadToEnd()
        } catch { }
        Write-Output ('publish: Netlify deploy failed: ' + $msg)
    }
}
