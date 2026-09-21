# Lead Copilot bootstrap script.
#
# The tunnel only reveals its randomly-assigned public hostname AFTER it connects,
# but n8n needs that hostname baked into its WEBHOOK_URL/N8N_HOST at startup to
# generate correct webhook URLs. This script breaks that chicken-and-egg loop:
#   1. bring up postgres + rag-service + n8n (n8n starts with whatever host is
#      currently in .env, even if stale/empty)
#   2. bring up the tunnel service, wait, scrape its logs for the assigned hostname
#   3. write that hostname into .env
#   4. recreate the n8n container so it picks up the correct WEBHOOK_URL/N8N_HOST
#
# Tunnel provider: serveo.net (free SSH reverse tunnel, no signup). Cloudflare Quick
# Tunnel (trycloudflare.com) was tried first but its edge IPs are blocked on this
# network at the raw TCP level (confirmed via Test-NetConnection - not a DNS or SNI
# issue, other Cloudflare IPs work fine). localhost.run worked next but started
# rate-limiting this IP after several reconnects in one session. If either of those
# stops working, swap the ssh target in docker-compose.yml's "tunnel" service and
# adjust the regex below to match the new provider's domain.
#
# Run from the lead-copilot/ directory: ./scripts/start.ps1

$ErrorActionPreference = "Stop"
$envFile = Join-Path $PSScriptRoot "..\.env"

if (-not (Test-Path $envFile)) {
    Write-Error ".env not found. Copy .env.example to .env and fill in your keys first."
    exit 1
}

Write-Host "Starting postgres, rag-service, n8n..."
docker compose up -d postgres rag-service n8n

Write-Host "Starting tunnel (serveo.net)..."
docker compose up -d tunnel

Write-Host "Waiting for the tunnel to announce its public hostname..."
# serveo.net's banner includes a line like "Forwarding HTTP traffic from
# https://xxxxxxxx.serveo.net" once the SSH reverse tunnel connects. Also matches
# lhr.life/localhost.run in case the tunnel service was swapped back.
$hostname = $null
for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Seconds 2
    $logs = docker compose logs tunnel 2>$null
    $candidates = ($logs | Select-String -Pattern "https://[a-zA-Z0-9.-]+\.(serveousercontent\.com|serveo\.net|lhr\.life|localhost\.run)" -AllMatches).Matches |
        ForEach-Object { $_.Value -replace "^https://", "" }
    if ($candidates) {
        $hostname = $candidates | Select-Object -Last 1
        break
    }
}

if (-not $hostname) {
    Write-Error "Could not find the tunnel URL in logs after 60s. Run 'docker compose logs tunnel' to inspect - the banner format may have changed, adjust the regex in this script to match."
    exit 1
}

Write-Host "Tunnel is up: https://$hostname"

# Update N8N_PUBLIC_HOST in .env (in place, preserves everything else)
$content = Get-Content $envFile -Raw
if ($content -match "(?m)^N8N_PUBLIC_HOST=.*$") {
    $content = $content -replace "(?m)^N8N_PUBLIC_HOST=.*$", "N8N_PUBLIC_HOST=$hostname"
} else {
    $content += "`nN8N_PUBLIC_HOST=$hostname`n"
}
Set-Content -Path $envFile -Value $content -Encoding utf8 -NoNewline

Write-Host "Recreating n8n with the correct public hostname..."
docker compose up -d --force-recreate n8n

Write-Host ""
Write-Host "Lead Copilot is up."
Write-Host "  n8n editor:      https://$hostname  (login with N8N_BASIC_AUTH_USER / N8N_BASIC_AUTH_PASSWORD from .env)"
Write-Host "  Lead webhook:    https://$hostname/webhook/lead-intake  (create the Webhook node with path 'lead-intake' to match)"
Write-Host "  Telegram callback: n8n's Telegram Trigger node registers its own webhook with this public URL automatically"
Write-Host ""
Write-Host "NOTE: this hostname changes every time this script runs. Keep this terminal/session alive while recording demos."
