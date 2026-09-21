# Creates the 3 n8n credentials Lead Copilot's workflow needs, via n8n's REST API.
#
# Run this once against a fresh instance, after scripts/start.ps1 has n8n up and you've
# created an n8n API key (Settings -> n8n API -> Create API key) and put it in .env as
# N8N_API_KEY. Re-running is safe but creates duplicate credential entries - delete the
# old ones from the n8n UI first if you do.
#
# Run from the lead-copilot/ directory: ./n8n/setup-credentials.ps1

$ErrorActionPreference = "Stop"
Set-Location (Join-Path $PSScriptRoot "..")

$envLines = Get-Content .env
function Get-EnvVar($name) {
    $line = $envLines | Where-Object { $_ -match "^$name=" }
    if (-not $line) { throw "$name not found in .env" }
    return ($line -split '=', 2)[1]
}

$n8nKey = Get-EnvVar "N8N_API_KEY"
$telegramToken = Get-EnvVar "TELEGRAM_BOT_TOKEN"
$airtableKey = Get-EnvVar "AIRTABLE_API_KEY"
$geminiKey = Get-EnvVar "GEMINI_API_KEY"

$headers = @{ "X-N8N-API-KEY" = $n8nKey; "Content-Type" = "application/json" }
$base = "http://localhost:5678/api/v1/credentials"

function Create-Credential($name, $type, $data) {
    $body = @{ name = $name; type = $type; data = $data } | ConvertTo-Json
    $resp = Invoke-RestMethod -Uri $base -Method Post -Headers $headers -Body $body
    Write-Host "$name ($type) -> id=$($resp.id)"
    return $resp.id
}

$tgId = Create-Credential "Lead Copilot Telegram" "telegramApi" @{ accessToken = $telegramToken }
$atId = Create-Credential "Lead Copilot Airtable" "airtableTokenApi" @{ accessToken = $airtableKey }
$gmId = Create-Credential "Lead Copilot Gemini" "httpQueryAuth" @{ name = "key"; value = $geminiKey }

Write-Host ""
Write-Host "Credential IDs (update these at the top of n8n/build-workflow.ps1 if they changed):"
Write-Host "  TG_CRED_ID     = $tgId"
Write-Host "  AT_CRED_ID     = $atId"
Write-Host "  GEMINI_CRED_ID = $gmId"
