# Builds the Lead Copilot n8n workflow (all 17 nodes, prompts, routing, retries) and PUTs
# it to a running n8n instance via the REST API. This is the source of truth for the
# workflow - n8n/workflow-export.json is a generated snapshot, not hand-edited.
#
# Prerequisites:
#   - scripts/start.ps1 has been run (stack is up)
#   - n8n/setup-credentials.ps1 has been run (or credential IDs below are updated to match
#     your instance's actual credential IDs - Settings -> Credentials in the n8n UI)
#   - N8N_API_KEY is set in .env (Settings -> n8n API -> Create API key)
#
# Run from the lead-copilot/ directory: ./n8n/build-workflow.ps1
# Re-running is safe - it overwrites the same workflow (by WORKFLOW_ID below) in place.

$ErrorActionPreference = "Stop"
Set-Location (Join-Path $PSScriptRoot "..")
$envLines = Get-Content .env
$n8nKey = (($envLines | Where-Object { $_ -match '^N8N_API_KEY=' }) -split '=', 2)[1]
$headers = @{ "X-N8N-API-KEY" = $n8nKey; "Content-Type" = "application/json" }

# From n8n/setup-credentials.ps1's output. Update these if you re-created the credentials.
$TG_CRED_ID = "7PND2WjJoeHdKxfq"
$AT_CRED_ID = "wFpt3sgGvcK9OKPS"
$GEMINI_CRED_ID = "nzFzEHYR9WRmL67B"

# From the Airtable base created per README section 3 (URL when the base/table is open,
# or GET https://api.airtable.com/v0/meta/bases/{baseId}/tables).
$AIRTABLE_BASE_ID = "applFYTv9nu77gF19"
$AIRTABLE_TABLE_ID = "tblp3dl2oBAL3aPEJ"

# The workflow to create/overwrite. First run: create a blank workflow in the n8n UI and
# copy its ID from the URL; subsequent runs reuse the same ID so the URL stays stable.
$WORKFLOW_ID = "v0UKoEySYc5cspIi"

# gemini-flash-lite-latest over gemini-flash-latest: noticeably less prone to 503
# "experiencing high demand" on the free tier in testing. Each agent node also has
# retryOnFail set (3 tries, 3s apart) since free-tier capacity blips do still happen.
$GEMINI_MODEL = "gemini-flash-lite-latest"
$GEMINI_URL = "https://generativelanguage.googleapis.com/v1beta/models/${GEMINI_MODEL}:generateContent"

# Telegram chat id that receives Hot-lead / QA-failed pings (TELEGRAM_SALES_CHAT_ID in .env).
$TELEGRAM_CHAT_ID = "7492868342"

# ---------- Code node JS bodies ----------

$jsNormalize = @'
const raw = $input.first().json;
let b = (raw.body !== undefined) ? raw.body : raw;
// The landing page posts with fetch's no-cors mode, which silently forces
// Content-Type to text/plain (custom headers like application/json aren't allowed
// without a CORS preflight n8n does not handle) - so the body arrives here as a raw
// JSON string instead of a parsed object. Handle both shapes rather than depending
// on the caller's Content-Type header being honored.
if (typeof b === "string") {
  try { b = JSON.parse(b); } catch (e) { b = {}; }
}
const now = new Date().toISOString();
return [{
  json: {
    lead_id: "lead_" + Date.now() + "_" + Math.random().toString(36).slice(2, 8),
    source: "Form",
    contact_name_raw: b.name || null,
    email_raw: b.email || null,
    phone_raw: b.phone || null,
    company_name_raw: b.company || null,
    message: b.message || "",
    received_at: now
  }
}];
'@

$jsLoadPrompts = @'
const fs = require("fs");
const dir = "/data/prompts";
const read = (name) => fs.readFileSync(dir + "/" + name, "utf8");
const prompts = {
  extractor: read("extractor.md"),
  qualifier: read("qualifier_rubric.md"),
  responder: read("responder.md"),
  qa_reviewer: read("qa_reviewer.md")
};
return $input.all().map(item => ({ json: Object.assign({}, item.json, { prompts: prompts }) }));
'@

$jsGuardrail = @'
const item = $input.first().json;
const raw = item.message || "";

// Neutralize delimiter-injection attempts (e.g. fake closing tags trying to break
// out of the <lead_message> wrapper used in agent prompts) before anything reaches an LLM.
const neutralized = raw.replace(/</g, "\u2039").replace(/>/g, "\u203a");

// Mask obvious PII in the copy that goes into LLM prompts - originals are kept
// separately (contact_name_raw / email_raw / phone_raw) for the Airtable record.
const maskedForLlm = neutralized
  .replace(/[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}/g, "[EMAIL]")
  .replace(/\+?\d[\d\s().-]{7,}\d/g, "[PHONE]");

return [{
  json: Object.assign({}, item, {
    message_for_llm: maskedForLlm,
    message_raw: raw
  })
}];
'@

$jsParseExtractor = @'
const prior = $("Guardrail").item.json;
const resp = $input.first().json;
let extracted;
try {
  const raw = resp.candidates[0].content.parts[0].text;
  extracted = JSON.parse(raw);
} catch (e) {
  throw new Error("Extractor agent returned invalid JSON: " + e.message);
}
return [{ json: Object.assign({}, prior, { extracted: extracted }) }];
'@

$jsParseQualifier = @'
const prior = $("Parse Extractor").item.json;
const resp = $input.first().json;
let q;
try {
  const raw = resp.candidates[0].content.parts[0].text;
  q = JSON.parse(raw);
} catch (e) {
  throw new Error("Qualifier agent returned invalid JSON: " + e.message);
}
return [{ json: Object.assign({}, prior, {
  score: q.score,
  temperature: q.temperature,
  scoring_reasoning: q.reasoning
}) }];
'@

$jsFormatRag = @'
const prior = $("Parse Qualifier").item.json;
const resp = $input.first().json;
const results = resp.results || [];
const context = results.map(r => "[" + r.source + " / " + r.heading + "]\n" + r.text).join("\n\n");
const sources = [...new Set(results.map(r => r.source))];
return [{ json: Object.assign({}, prior, { rag_context: context, rag_sources: sources }) }];
'@

$jsParseResponder = @'
const prior = $("Format RAG Context").item.json;
const resp = $input.first().json;
let d;
try {
  const raw = resp.candidates[0].content.parts[0].text;
  d = JSON.parse(raw);
} catch (e) {
  throw new Error("Responder agent returned invalid JSON: " + e.message);
}
return [{ json: Object.assign({}, prior, {
  draft_v1: d.draft,
  draft_sources_used: d.sources_used || []
}) }];
'@

$jsParseQa = @'
const prior = $("Parse Responder").item.json;
const resp = $input.first().json;
let qa;
try {
  const raw = resp.candidates[0].content.parts[0].text;
  qa = JSON.parse(raw);
} catch (e) {
  throw new Error("QA reviewer agent returned invalid JSON: " + e.message);
}

const verdict = qa.verdict; // "Pass" | "Fixed" | "Failed"
const finalDraft = verdict === "Failed" ? null : (verdict === "Fixed" ? qa.corrected_draft : prior.draft_v1);
// Every lead now gets a Telegram notification (not just Hot) - pingReason just
// records WHY, for the audit trail and to pick the right header wording below.
const needsPing = true;
const pingReason = verdict === "Failed" ? "qa_failed" : (
  prior.temperature === "Hot" ? "hot_lead" : (prior.temperature === "Warm" ? "warm_lead" : "cold_lead")
);

const fire = "\u{1F525}";
const warn = "\u26A0\uFE0F";
const warm = "\u26C5";
const cold = "\u2744\uFE0F";
const headers = {
  qa_failed: warn + " \u0422\u0440\u0435\u0431\u0443\u0435\u0442\u0441\u044F \u0440\u0443\u0447\u043D\u0430\u044F \u043F\u0440\u043E\u0432\u0435\u0440\u043A\u0430 (\u0430\u0432\u0442\u043E\u043E\u0431\u0440\u0430\u0431\u043E\u0442\u043A\u0430 \u043F\u043E\u043C\u0435\u0442\u0438\u043B\u0430 \u044D\u0442\u043E\u0442 \u043B\u0438\u0434)",
  hot_lead: fire + " \u0413\u043E\u0440\u044F\u0447\u0438\u0439 \u043B\u0438\u0434",
  warm_lead: warm + " \u0422\u0451\u043F\u043B\u044B\u0439 \u043B\u0438\u0434",
  cold_lead: cold + " \u0425\u043E\u043B\u043E\u0434\u043D\u044B\u0439 \u043B\u0438\u0434"
};
const header = headers[pingReason];
// The draft shown here is always Russian (qa.draft_ru) for the internal reviewer -
// the version that actually gets sent to the lead stays in their own language
// (finalDraft, stored separately in Airtable / used by a future "send" step).
const draftForReview = verdict === "Failed" ? null : (qa.draft_ru || finalDraft);
const leadLanguage = (prior.extracted && prior.extracted.language) || "?";
const telegramText = header + "\n\n"
  + "\u041E\u0446\u0435\u043D\u043A\u0430: " + prior.score + "/100\n"
  + "\u041E\u0431\u043E\u0441\u043D\u043E\u0432\u0430\u043D\u0438\u0435: " + prior.scoring_reasoning + "\n\n"
  + "\u0427\u0435\u0440\u043D\u043E\u0432\u0438\u043A \u043E\u0442\u0432\u0435\u0442\u0430 (\u043F\u0435\u0440\u0435\u0432\u043E\u0434 \u0434\u043B\u044F \u043E\u0437\u043D\u0430\u043A\u043E\u043C\u043B\u0435\u043D\u0438\u044F, \u043A\u043B\u0438\u0435\u043D\u0442\u0443 \u0443\u0439\u0434\u0451\u0442 \u043D\u0430 \u044F\u0437\u044B\u043A\u0435 \"" + leadLanguage + "\"):\n"
  + (draftForReview || "(\u043D\u0435\u0442 - \u0441\u043C. \u0437\u0430\u043C\u0435\u0447\u0430\u043D\u0438\u044F QA)") + "\n\n"
  + "\u0417\u0430\u043C\u0435\u0447\u0430\u043D\u0438\u044F QA: " + qa.notes;

return [{ json: Object.assign({}, prior, {
  qa_verdict: verdict,
  qa_notes: qa.notes,
  final_draft: finalDraft,
  needs_telegram_ping: needsPing,
  ping_reason: pingReason,
  telegram_text: telegramText,
  processing_failed: false,
  processed_at: new Date().toISOString()
}) }];
'@

# ---------- Error path (used by the separate error workflow, defined later) ----------

# ---------- HTTP Request bodies (as n8n expressions) ----------

function GeminiJsonBody($systemPromptExpr, $userTextExpr) {
  return "={{ JSON.stringify({ systemInstruction: { parts: [{ text: " + $systemPromptExpr + " }] }, contents: [{ parts: [{ text: " + $userTextExpr + " }] }], generationConfig: { responseMimeType: `"application/json`", temperature: 0.2 } }) }}"
}

$bodyExtractor = GeminiJsonBody '$json.prompts.extractor' '"Lead message (source: " + $json.source + "):\n\n<lead_message>\n" + $json.message_for_llm + "\n</lead_message>"'
$bodyQualifier  = GeminiJsonBody '$json.prompts.qualifier' '"Extracted lead JSON:\n" + JSON.stringify($json.extracted, null, 2)'
$bodyResponder  = GeminiJsonBody '$json.prompts.responder' '"Extracted lead JSON:\n" + JSON.stringify($json.extracted, null, 2) + "\n\nQualifier output:\n" + JSON.stringify({score:$json.score,temperature:$json.temperature,reasoning:$json.scoring_reasoning}, null, 2) + "\n\nRetrieved context:\n" + $json.rag_context'
$bodyQa         = GeminiJsonBody '$json.prompts.qa_reviewer' '"Draft to review:\n" + $json.draft_v1 + "\n\nContext it was grounded in:\n" + $json.rag_context + "\n\nExtracted lead JSON:\n" + JSON.stringify($json.extracted, null, 2)'

# ---------- Nodes ----------
#
# Note: the webhook uses responseMode "onReceived" (default) - a fast, fixed
# acknowledgment sent the instant the request lands, before the agent pipeline runs.
# An earlier attempt at a custom HTML response via a "Respond to Webhook" node
# branched off Normalize was reverted: in this n8n instance it held the HTTP response
# open until the ENTIRE execution finished (~30s+) instead of firing immediately, which
# defeats the point. The polished "thanks" UX lives client-side in landing-page/index.html
# instead - it doesn't depend on n8n's response body or timing at all.

$nodes = @(
  @{ parameters = @{ httpMethod = "POST"; path = "lead-intake"; options = @{} }
     type = "n8n-nodes-base.webhook"; typeVersion = 2.1; position = @(0,0)
     id = "223966a7-ce7b-4d23-840b-f337c5cabbb3"; name = "Lead Intake"
     webhookId = "f7d54c56-4275-43a0-a552-a5603524fb39" },

  @{ parameters = @{ mode = "runOnceForAllItems"; jsCode = $jsNormalize }
     type = "n8n-nodes-base.code"; typeVersion = 2; position = @(220,0)
     id = "10000000-0000-0000-0000-000000000001"; name = "Normalize" },

  @{ parameters = @{ mode = "runOnceForAllItems"; jsCode = $jsLoadPrompts }
     type = "n8n-nodes-base.code"; typeVersion = 2; position = @(440,0)
     id = "10000000-0000-0000-0000-000000000002"; name = "Load Prompts" },

  @{ parameters = @{ mode = "runOnceForAllItems"; jsCode = $jsGuardrail }
     type = "n8n-nodes-base.code"; typeVersion = 2; position = @(660,0)
     id = "10000000-0000-0000-0000-000000000003"; name = "Guardrail" },

  @{ parameters = @{ method = "POST"; url = $GEMINI_URL
       authentication = "genericCredentialType"; genericAuthType = "httpQueryAuth"
       sendBody = $true; specifyBody = "json"; jsonBody = $bodyExtractor; options = @{} }
     type = "n8n-nodes-base.httpRequest"; typeVersion = 4.2; position = @(880,0)
     id = "20000000-0000-0000-0000-000000000001"; name = "Agent A - Extractor"
     credentials = @{ httpQueryAuth = @{ id = $GEMINI_CRED_ID; name = "Lead Copilot Gemini" } }
     retryOnFail = $true; maxTries = 3; waitBetweenTries = 3000 },

  @{ parameters = @{ mode = "runOnceForAllItems"; jsCode = $jsParseExtractor }
     type = "n8n-nodes-base.code"; typeVersion = 2; position = @(1100,0)
     id = "10000000-0000-0000-0000-000000000004"; name = "Parse Extractor" },

  @{ parameters = @{ method = "POST"; url = $GEMINI_URL
       authentication = "genericCredentialType"; genericAuthType = "httpQueryAuth"
       sendBody = $true; specifyBody = "json"; jsonBody = $bodyQualifier; options = @{} }
     type = "n8n-nodes-base.httpRequest"; typeVersion = 4.2; position = @(1320,0)
     id = "20000000-0000-0000-0000-000000000002"; name = "Agent B - Qualifier"
     credentials = @{ httpQueryAuth = @{ id = $GEMINI_CRED_ID; name = "Lead Copilot Gemini" } }
     retryOnFail = $true; maxTries = 3; waitBetweenTries = 3000 },

  @{ parameters = @{ mode = "runOnceForAllItems"; jsCode = $jsParseQualifier }
     type = "n8n-nodes-base.code"; typeVersion = 2; position = @(1540,0)
     id = "10000000-0000-0000-0000-000000000005"; name = "Parse Qualifier" },

  @{ parameters = @{ method = "POST"; url = "http://rag-service:8001/query"; authentication = "none"
       sendBody = $true; specifyBody = "json"
       jsonBody = "={{ JSON.stringify({ query: `$json.extracted.stated_need || `$json.message_raw, k: 4 }) }}"
       options = @{} }
     type = "n8n-nodes-base.httpRequest"; typeVersion = 4.2; position = @(1760,0)
     id = "20000000-0000-0000-0000-000000000003"; name = "RAG Query" },

  @{ parameters = @{ mode = "runOnceForAllItems"; jsCode = $jsFormatRag }
     type = "n8n-nodes-base.code"; typeVersion = 2; position = @(1980,0)
     id = "10000000-0000-0000-0000-000000000006"; name = "Format RAG Context" },

  @{ parameters = @{ method = "POST"; url = $GEMINI_URL
       authentication = "genericCredentialType"; genericAuthType = "httpQueryAuth"
       sendBody = $true; specifyBody = "json"; jsonBody = $bodyResponder; options = @{} }
     type = "n8n-nodes-base.httpRequest"; typeVersion = 4.2; position = @(2200,0)
     id = "20000000-0000-0000-0000-000000000004"; name = "Agent C - Responder"
     credentials = @{ httpQueryAuth = @{ id = $GEMINI_CRED_ID; name = "Lead Copilot Gemini" } }
     retryOnFail = $true; maxTries = 3; waitBetweenTries = 3000 },

  @{ parameters = @{ mode = "runOnceForAllItems"; jsCode = $jsParseResponder }
     type = "n8n-nodes-base.code"; typeVersion = 2; position = @(2420,0)
     id = "10000000-0000-0000-0000-000000000007"; name = "Parse Responder" },

  @{ parameters = @{ method = "POST"; url = $GEMINI_URL
       authentication = "genericCredentialType"; genericAuthType = "httpQueryAuth"
       sendBody = $true; specifyBody = "json"; jsonBody = $bodyQa; options = @{} }
     type = "n8n-nodes-base.httpRequest"; typeVersion = 4.2; position = @(2640,0)
     id = "20000000-0000-0000-0000-000000000005"; name = "Agent D - QA Reviewer"
     credentials = @{ httpQueryAuth = @{ id = $GEMINI_CRED_ID; name = "Lead Copilot Gemini" } }
     retryOnFail = $true; maxTries = 3; waitBetweenTries = 3000 },

  @{ parameters = @{ mode = "runOnceForAllItems"; jsCode = $jsParseQa }
     type = "n8n-nodes-base.code"; typeVersion = 2; position = @(2860,0)
     id = "10000000-0000-0000-0000-000000000008"; name = "Parse QA and Resolve" },

  @{ parameters = @{
       resource = "record"; operation = "create"
       base = @{ __rl = $true; value = $AIRTABLE_BASE_ID; mode = "id" }
       table = @{ __rl = $true; value = $AIRTABLE_TABLE_ID; mode = "id" }
       columns = @{
         mappingMode = "defineBelow"
         value = @{
           "Lead ID" = "={{`$json.lead_id}}"
           "Raw Input" = "={{`$json.message_raw}}"
           "Source" = "={{`$json.source}}"
           "Extracted JSON" = "={{JSON.stringify(`$json.extracted)}}"
           "Score" = "={{`$json.score}}"
           "Temperature" = "={{`$json.temperature}}"
           "Scoring Reasoning" = "={{`$json.scoring_reasoning}}"
           "Draft v1" = "={{`$json.draft_v1}}"
           "QA Verdict" = "={{`$json.qa_verdict}}"
           "Final Draft" = "={{`$json.final_draft}}"
           "Human Decision" = "Pending"
           "Processing Failed" = "={{`$json.processing_failed}}"
           "Received At" = "={{`$json.received_at}}"
           "Processed At" = "={{`$json.processed_at}}"
         }
         matchingColumns = @()
         schema = @()
       }
     }
     type = "n8n-nodes-base.airtable"; typeVersion = 2.1; position = @(3080,0)
     id = "30000000-0000-0000-0000-000000000001"; name = "Airtable Create Record"
     credentials = @{ airtableTokenApi = @{ id = $AT_CRED_ID; name = "Lead Copilot Airtable" } } },

  @{ parameters = @{
       resource = "message"; operation = "sendMessage"
       chatId = $TELEGRAM_CHAT_ID
       text = "={{`$(`"Parse QA and Resolve`").item.json.telegram_text}}"
       replyMarkup = "inlineKeyboard"
       inlineKeyboard = @{
         rows = @(
           @{ row = @{ buttons = @(
             @{ text = "={{`"\u041E\u0434\u043E\u0431\u0440\u0438\u0442\u044C`"}}"; additionalFields = @{ callback_data = "={{`"approve:`" + `$(`"Airtable Create Record`").item.json.id}}" } },
             @{ text = "={{`"\u0418\u0437\u043C\u0435\u043D\u0438\u0442\u044C`"}}"; additionalFields = @{ callback_data = "={{`"edit:`" + `$(`"Airtable Create Record`").item.json.id}}" } },
             @{ text = "={{`"\u041E\u0442\u043A\u043B\u043E\u043D\u0438\u0442\u044C`"}}"; additionalFields = @{ callback_data = "={{`"reject:`" + `$(`"Airtable Create Record`").item.json.id}}" } }
           ) } }
         )
       }
       additionalFields = @{ appendAttribution = $false }
     }
     type = "n8n-nodes-base.telegram"; typeVersion = 1.2; position = @(3300,0)
     id = "50000000-0000-0000-0000-000000000001"; name = "Telegram Notify"
     credentials = @{ telegramApi = @{ id = $TG_CRED_ID; name = "Lead Copilot Telegram" } } }
)

function Link($from, $to) {
  return "`"$from`": {`"main`": [[{`"node`":`"$to`",`"type`":`"main`",`"index`":0}]]}"
}

$connectionsJson = "{`n" + (
  @(
    (Link "Lead Intake" "Normalize"),
    (Link "Normalize" "Load Prompts"),
    (Link "Load Prompts" "Guardrail"),
    (Link "Guardrail" "Agent A - Extractor"),
    (Link "Agent A - Extractor" "Parse Extractor"),
    (Link "Parse Extractor" "Agent B - Qualifier"),
    (Link "Agent B - Qualifier" "Parse Qualifier"),
    (Link "Parse Qualifier" "RAG Query"),
    (Link "RAG Query" "Format RAG Context"),
    (Link "Format RAG Context" "Agent C - Responder"),
    (Link "Agent C - Responder" "Parse Responder"),
    (Link "Parse Responder" "Agent D - QA Reviewer"),
    (Link "Agent D - QA Reviewer" "Parse QA and Resolve"),
    (Link "Parse QA and Resolve" "Airtable Create Record"),
    (Link "Airtable Create Record" "Telegram Notify")
  ) -join ",`n"
) + "`n}"

$nodesJson = $nodes | ConvertTo-Json -Depth 30

$json = '{"name":"Lead Copilot - Intake Pipeline","nodes":' + $nodesJson + ',"connections":' + $connectionsJson + ',"settings":{"executionOrder":"v1"}}'

try {
  $resp = Invoke-RestMethod -Uri "http://localhost:5678/api/v1/workflows/$WORKFLOW_ID" -Method Put -Headers $headers -Body $json
  Write-Host "SUCCESS - $($resp.nodes.Count) nodes saved"
  $resp.nodes | Select-Object name, type, typeVersion | Format-Table -AutoSize
  Write-Host "Re-activate if needed: POST /api/v1/workflows/$WORKFLOW_ID/activate (saving deactivates it)"
} catch {
  Write-Host "FAILED:"
  Write-Host $_.ErrorDetails.Message
}
