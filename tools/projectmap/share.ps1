# share.ps1 — put the project map behind a temporary Cloudflare tunnel.
#
# Gives you a public https URL anyone can open, with no deploy and nothing
# published. The URL dies when you close this window.
#
# WHAT YOU ARE SHARING: the map embeds a live read of production posture — which
# flags are on, which migrations have not deployed, the deploy gate state. That
# is why the colours mean anything. It is not secret (game_config is anon-read
# and the Supabase URL already ships in the public Pages bundle), but the link is
# public to anyone who has it. Use -NoLive to share structure only.
#
# Usage (this machine has no pwsh — use powershell.exe):
#   powershell.exe -File tools\projectmap\share.ps1
#   powershell.exe -File tools\projectmap\share.ps1 -NoLive
#   powershell.exe -File tools\projectmap\share.ps1 -EnvPath C:\path\to\.env.local
#
# Why Cloudflare and not ngrok: Norton intercepts TLS and re-signs ngrok's
# endpoints with a root it never trusts, so ngrok tunnels fail on this machine.

param(
  [int]$Port = 5183,
  [string]$EnvPath = "",
  [switch]$NoLive
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

$cf = "C:\Program Files (x86)\cloudflared\cloudflared.exe"
if (-not (Test-Path $cf)) { $cf = (Get-Command cloudflared -ErrorAction SilentlyContinue).Source }
if (-not $cf) {
  Write-Error "cloudflared not found. Install: winget install --id Cloudflare.cloudflared -e --source winget"
  exit 1
}

Push-Location $root
try {
  if (-not (Test-Path (Join-Path $root 'node_modules'))) {
    Write-Host "Installing deps (one-time)..."
    npm install --no-audit --no-fund | Out-Null
  }

  Write-Host "Scanning the repo..."
  node scan/scan.mjs | Out-Null

  if ($NoLive) {
    Remove-Item (Join-Path $root 'public/live.json') -ErrorAction SilentlyContinue
    Write-Host "Structure only — no production data will be shared."
  } else {
    Write-Host "Reading production..."
    $liveArgs = @('scan/live.mjs')
    if ($EnvPath) { $liveArgs += @('--env', $EnvPath) }
    node @liveArgs
  }

  Write-Host "Building..."
  npx vite build | Out-Null
  if ($NoLive) { Remove-Item (Join-Path $root 'dist/live.json') -ErrorAction SilentlyContinue }

  # Serve the built files. Bound to localhost — only the tunnel reaches it.
  $srv = Start-Process -FilePath "npx" `
    -ArgumentList @('vite', 'preview', '--port', "$Port", '--strictPort') `
    -PassThru -WindowStyle Hidden
  Start-Sleep -Seconds 2

  $cfOut = Join-Path $root 'cloudflared.log'
  $cfErr = Join-Path $root 'cloudflared.err.log'
  Remove-Item $cfOut, $cfErr -ErrorAction SilentlyContinue

  # --http-host-header keeps the dev server from rejecting the tunnel's Host.
  Write-Host "Opening Cloudflare tunnel -> http://localhost:$Port ..."
  $cfProc = Start-Process -FilePath $cf `
    -ArgumentList @('tunnel', '--no-autoupdate', '--http-host-header', "localhost:$Port", '--url', "http://localhost:$Port") `
    -RedirectStandardOutput $cfOut -RedirectStandardError $cfErr -PassThru -WindowStyle Hidden

  $url = $null
  for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Seconds 1
    $content = (Get-Content $cfOut, $cfErr -ErrorAction SilentlyContinue) -join "`n"
    $m = [regex]::Match($content, 'https://[a-z0-9-]+\.trycloudflare\.com')
    if ($m.Success) { $url = $m.Value; break }
  }
  if (-not $url) {
    Write-Error "No tunnel URL (see $cfErr)"
    Stop-Process -Id $cfProc.Id -Force -ErrorAction SilentlyContinue
    Stop-Process -Id $srv.Id -Force -ErrorAction SilentlyContinue
    exit 1
  }

  Write-Host ""
  Write-Host "  Share this:  $url" -ForegroundColor Green
  if (-not $NoLive) { Write-Host "  (includes a live production snapshot)" -ForegroundColor Yellow }
  Write-Host ""
  Write-Host "  Ctrl+C to stop. The URL dies with this window."
  Write-Host ""

  try { Wait-Process -Id $cfProc.Id } finally {
    Stop-Process -Id $cfProc.Id -Force -ErrorAction SilentlyContinue
    Stop-Process -Id $srv.Id -Force -ErrorAction SilentlyContinue
    Write-Host "Tunnel stopped. The link is dead."
  }
} finally {
  Pop-Location
}
