# Builds the Lead Copilot Decision Handler workflow: reacts to the Approve/Edit/Reject
# inline buttons sent by the main pipeline's Telegram Notify node.
#
# Flow: Telegram callback_query -> parse action+recordId out of callback_data ->
# update the Airtable record's Human Decision field -> edit the original Telegram
# message to show the outcome (buttons become a status line) -> acknowledge the
# button press (stops the client-side loading spinner).
#
# "Edit" does not implement a full in-Telegram rewrite flow (that needs stateful
# multi-turn conversation tracking) - it marks the record for manual follow-up in
# Airtable instead. Approve/Reject are fully handled.
#
# Prerequisites: same as n8n/build-workflow.ps1 (stack up, credentials created, N8N_API_KEY set).
# Run from the lead-copilot/ directory: ./n8n/build-decision-handler.ps1
# Re-running is safe - it overwrites the same workflow (by WORKFLOW_ID below) in place.

$ErrorActionPreference = "Stop"
Set-Location (Join-Path $PSScriptRoot "..")
$envLines = Get-Content .env
$n8nKey = (($envLines | Where-Object { $_ -match '^N8N_API_KEY=' }) -split '=', 2)[1]
$headers = @{ "X-N8N-API-KEY" = $n8nKey; "Content-Type" = "application/json" }

$TG_CRED_ID = "7PND2WjJoeHdKxfq"
$AT_CRED_ID = "wFpt3sgGvcK9OKPS"
$AIRTABLE_BASE_ID = "applFYTv9nu77gF19"
$AIRTABLE_TABLE_ID = "tblp3dl2oBAL3aPEJ"

# First run: leave blank to create a new workflow; copy the returned id here for
# subsequent runs so the workflow gets updated in place instead of duplicated.
$WORKFLOW_ID = "844cmsgeNuT1aM9p"

$jsParseCallback = @'
const cb = $input.first().json.callbackQuery;
const parts = (cb.data || "").split(":");
const action = parts[0];
const recordId = parts[1];

const decisionMap = { approve: "Approved", edit: "Edited", reject: "Rejected" };
const decision = decisionMap[action] || "Pending";

const statusLines = {
  approve: "✅ Одобрено командой - готово к отправке.",
  edit: "✏️ Отмечено на доработку - обновите черновик в Airtable и отправьте вручную.",
  reject: "❌ Отклонено - ответ отправляться не будет."
};
const statusLine = statusLines[action] || "Обновлено.";

const ackTexts = {
  approve: "Одобрено",
  edit: "Отмечено на доработку",
  reject: "Отклонено"
};
const ackText = ackTexts[action] || "Принято";

if (!action || !recordId) {
  throw new Error("Callback data missing action/recordId: " + JSON.stringify(cb.data));
}

return [{
  json: {
    action, recordId, decision, statusLine, ackText,
    chatId: cb.message.chat.id,
    messageId: cb.message.message_id,
    originalText: cb.message.text,
    callbackQueryId: cb.id
  }
}];
'@

$nodes = @(
  @{ parameters = @{ updates = @("callback_query"); additionalFields = @{} }
     type = "n8n-nodes-base.telegramTrigger"; typeVersion = 1.1; position = @(0,0)
     id = "80000000-0000-0000-0000-000000000001"; name = "Telegram Decision Trigger"
     credentials = @{ telegramApi = @{ id = $TG_CRED_ID; name = "Lead Copilot Telegram" } } },

  @{ parameters = @{ mode = "runOnceForAllItems"; jsCode = $jsParseCallback }
     type = "n8n-nodes-base.code"; typeVersion = 2; position = @(220,0)
     id = "80000000-0000-0000-0000-000000000002"; name = "Parse Callback" },

  @{ parameters = @{
       resource = "record"; operation = "update"
       base = @{ __rl = $true; value = $AIRTABLE_BASE_ID; mode = "id" }
       table = @{ __rl = $true; value = $AIRTABLE_TABLE_ID; mode = "id" }
       columns = @{
         mappingMode = "defineBelow"
         value = @{
           "id" = "={{`$json.recordId}}"
           "Human Decision" = "={{`$json.decision}}"
         }
         matchingColumns = @("id")
         schema = @()
       }
     }
     type = "n8n-nodes-base.airtable"; typeVersion = 2.1; position = @(440,0)
     id = "80000000-0000-0000-0000-000000000003"; name = "Airtable Update Decision"
     credentials = @{ airtableTokenApi = @{ id = $AT_CRED_ID; name = "Lead Copilot Airtable" } } },

  @{ parameters = @{
       resource = "message"; operation = "editMessageText"
       chatId = "={{`$(`"Parse Callback`").item.json.chatId}}"
       messageId = "={{`$(`"Parse Callback`").item.json.messageId}}"
       text = "={{`$(`"Parse Callback`").item.json.originalText}} `n`n{{`$(`"Parse Callback`").item.json.statusLine}}"
       inlineKeyboard = @{}
       additionalFields = @{}
     }
     type = "n8n-nodes-base.telegram"; typeVersion = 1.2; position = @(660,0)
     id = "80000000-0000-0000-0000-000000000004"; name = "Edit Message"
     credentials = @{ telegramApi = @{ id = $TG_CRED_ID; name = "Lead Copilot Telegram" } } },

  @{ parameters = @{
       resource = "callback"; operation = "answerQuery"
       queryId = "={{`$(`"Parse Callback`").item.json.callbackQueryId}}"
       text = "={{`$(`"Parse Callback`").item.json.ackText}}"
       additionalFields = @{}
     }
     type = "n8n-nodes-base.telegram"; typeVersion = 1.2; position = @(880,0)
     id = "80000000-0000-0000-0000-000000000005"; name = "Answer Callback"
     credentials = @{ telegramApi = @{ id = $TG_CRED_ID; name = "Lead Copilot Telegram" } } }
)

function Link($from, $to) {
  return "`"$from`": {`"main`": [[{`"node`":`"$to`",`"type`":`"main`",`"index`":0}]]}"
}

$connectionsJson = "{`n" + (
  @(
    (Link "Telegram Decision Trigger" "Parse Callback"),
    (Link "Parse Callback" "Airtable Update Decision"),
    (Link "Airtable Update Decision" "Edit Message"),
    (Link "Edit Message" "Answer Callback")
  ) -join ",`n"
) + "`n}"

$nodesJson = $nodes | ConvertTo-Json -Depth 30
$json = '{"name":"Lead Copilot - Decision Handler","nodes":' + $nodesJson + ',"connections":' + $connectionsJson + ',"settings":{"executionOrder":"v1"}}'

if ($WORKFLOW_ID -eq "PLACEHOLDER_DECISION_HANDLER_ID") {
  try {
    $resp = Invoke-RestMethod -Uri "http://localhost:5678/api/v1/workflows" -Method Post -Headers $headers -Body $json
    Write-Host "CREATED - id=$($resp.id) - update WORKFLOW_ID at the top of this script to this value for future re-runs"
    $resp.nodes | Select-Object name, type, typeVersion | Format-Table -AutoSize
  } catch {
    Write-Host "FAILED:"
    Write-Host $_.ErrorDetails.Message
  }
} else {
  try {
    $resp = Invoke-RestMethod -Uri "http://localhost:5678/api/v1/workflows/$WORKFLOW_ID" -Method Put -Headers $headers -Body $json
    Write-Host "SUCCESS - $($resp.nodes.Count) nodes saved"
    $resp.nodes | Select-Object name, type, typeVersion | Format-Table -AutoSize
    Write-Host "Re-activate if needed: POST /api/v1/workflows/$WORKFLOW_ID/activate (saving deactivates it)"
  } catch {
    Write-Host "FAILED:"
    Write-Host $_.ErrorDetails.Message
  }
}
