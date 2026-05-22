$ErrorActionPreference = "Stop"

$src  = "C:\Users\Administrador\Downloads\Aspiramaq\workspaces\Aspiramaq-Agent-IA-copy.json"
$root = "C:\Users\Administrador\Downloads\Zanaflex\zanaflex"
$dst  = "$root\workspaces\Zanaflex-Agent-IA.json"
$frag = "$root\.scripts\agent-fragments"
$enc  = New-Object System.Text.UTF8Encoding($false)

# --- 1) Read source as UTF-8 text and do bulk prefix-rename ---
$text = [System.IO.File]::ReadAllText($src, $enc)

# Aspiramaq -> Zanaflex (case-sensitive variants)
$text = $text.Replace('aspiramaq_',  'zanaflex_')
$text = $text.Replace('aspiramaq-',  'zanaflex-')
$text = $text.Replace('Aspiramaq',   'Zanaflex')
$text = $text.Replace('ASPIRAMAQ',   'ZANAFLEX')
$text = $text.Replace('aspiramaq',   'zanaflex')   # any leftover

# Replace Aspiramaq-only credential IDs with REPLACE_ME placeholders
# Supabase API (Vector Store) - we use service_role key on Zanaflex
$text = $text.Replace('"id":"i5Q8tj8Pyc9XjSGd","name":"Supabase account"', '"id":"REPLACE_ME_SUPABASE_CRED","name":"Supabase service_role"')
# OpenRouter (alt LLM, disconnected)
$text = $text.Replace('"id":"hZRBXrfocBn4jbFB","name":"openrouter_cloudfy"', '"id":"REPLACE_ME_OPENROUTER","name":"openrouter (optional)"')
# Anthropic (alt LLM, disconnected)
$text = $text.Replace('"id":"ohN9YHsrwMLXZUKL","name":"Anthropic account 3"', '"id":"REPLACE_ME_ANTHROPIC","name":"anthropic (optional)"')
# Google Gemini (alt LLM/embeddings, disconnected)
$text = $text.Replace('"id":"Z4XWEFCEAurXpq6I","name":"Google Gemini(PaLM) Api account Giovani"', '"id":"REPLACE_ME_GEMINI","name":"gemini (optional)"')

# Sub-workflow ID for "Consultar Planilha Inteligente" -> placeholder; the node will be removed below anyway
$text = $text.Replace('"value":"aeevv95g1JrqmHe2"', '"value":"REPLACE_ME_SUBWORKFLOW_ID"')

# --- 2) Parse JSON, do surgical edits ---
$wf = $text | ConvertFrom-Json

# Drop Aspiramaq-only tools (no Zanaflex equivalent)
$dropNames = @('Calculadora_Dimensionamento', 'Consultar_Planilha_Inteligente1')
$wf.nodes = @($wf.nodes | Where-Object { $dropNames -notcontains $_.name })

# Drop connections OUT of removed nodes
$keepConn = [ordered]@{}
foreach ($k in $wf.connections.PSObject.Properties.Name) {
    if ($dropNames -notcontains $k) {
        $keepConn[$k] = $wf.connections.$k
    }
}
$wf.connections = [pscustomobject]$keepConn

# --- 3) Replace systemMessage on RAG AI Agent ---
$systemMsg = [System.IO.File]::ReadAllText("$frag\system-prompt.md", $enc)
$agentNode = $wf.nodes | Where-Object { $_.name -eq 'RAG AI Agent' } | Select-Object -First 1
if ($agentNode) {
    $agentNode.parameters.options.systemMessage = $systemMsg
    # Use the user-context-injected chatInput from Prepare Input (added below)
    $agentNode.parameters.text = "={{ `$('Prepare Input').item.json.chatInput }}"
}

# --- 4) Rewire: Webhook -> Edit Fields -> Prepare Input -> Get Allowed Categories -> RAG AI Agent ---
# Build new nodes
$prepareCode = [System.IO.File]::ReadAllText("$frag\prepare-input.js", $enc)
$aclSql      = [System.IO.File]::ReadAllText("$frag\acl.sql",          $enc)

$prepareInputNode = [pscustomobject]@{
    parameters  = [pscustomobject]@{ jsCode = $prepareCode }
    id          = [Guid]::NewGuid().ToString()
    name        = 'Prepare Input'
    type        = 'n8n-nodes-base.code'
    typeVersion = 2
    position    = @(4592, 3856)
}
$aclNode = [pscustomobject]@{
    parameters  = [pscustomobject]@{
        operation = 'executeQuery'
        query     = $aclSql
        options   = New-Object PSObject
    }
    id          = [Guid]::NewGuid().ToString()
    name        = 'Get Allowed Categories'
    type        = 'n8n-nodes-base.postgres'
    typeVersion = 2.6
    position    = @(4640, 3856)
    credentials = [pscustomobject]@{
        postgres = [pscustomobject]@{ id = 'jFjeYH6Nt3aRNkoM'; name = 'Supabase_database' }
    }
}
$wf.nodes += $prepareInputNode
$wf.nodes += $aclNode

# Edit Fields: extend to also carry userId/userName/userRole (Prepare Input expects them in body)
$editFields = $wf.nodes | Where-Object { $_.name -eq 'Edit Fields' } | Select-Object -First 1
if ($editFields) {
    # Add userId assignment so downstream can read $('Edit Fields').item.json.userId if needed
    $editFields.parameters.assignments.assignments += [pscustomobject]@{
        id    = [Guid]::NewGuid().ToString()
        name  = 'userId'
        value = "={{ `$json?.userId || `$json.body?.userId }}"
        type  = 'string'
    }
}

# Rebuild connections for the main chain: Webhook -> Edit Fields -> Prepare Input -> Get Allowed Categories -> RAG AI Agent
# Original: Webhook -> Edit Fields -> RAG AI Agent
$cn = $wf.connections
# Edit Fields previously fed RAG AI Agent. Now feeds Prepare Input.
$cn.'Edit Fields' = [pscustomobject]@{
    main = @(,@( [pscustomobject]@{ node = 'Prepare Input'; type = 'main'; index = 0 } ))
}
# Add Prepare Input -> Get Allowed Categories
$cn | Add-Member -NotePropertyName 'Prepare Input' -NotePropertyValue ([pscustomobject]@{
    main = @(,@( [pscustomobject]@{ node = 'Get Allowed Categories'; type = 'main'; index = 0 } ))
}) -Force
# Add Get Allowed Categories -> RAG AI Agent
$cn | Add-Member -NotePropertyName 'Get Allowed Categories' -NotePropertyValue ([pscustomobject]@{
    main = @(,@( [pscustomobject]@{ node = 'RAG AI Agent'; type = 'main'; index = 0 } ))
}) -Force

# --- 5) Add filter (ACL) to search_knowledge_base Vector Store ---
$vs = $wf.nodes | Where-Object { $_.name -eq 'search_knowledge_base' } | Select-Object -First 1
if ($vs) {
    $vs.parameters | Add-Member -NotePropertyName 'filter' -NotePropertyValue "={{ { allowed_category_ids: `$('Get Allowed Categories').item.json.allowed_ids } }}" -Force
}

# --- 6) Update PostgresTool SQLs to honor user's allowed categories ---
$listDocs = $wf.nodes | Where-Object { $_.name -eq 'List Documents' } | Select-Object -First 1
if ($listDocs) {
    $listDocs.parameters.query = @"
SELECT m.id, m.title, m.url, m.code, m.category_id
FROM zanaflex_document_metadata m
WHERE EXISTS (
  SELECT 1 FROM jsonb_array_elements_text(`$2::jsonb) AS allowed(cid)
  WHERE allowed.cid = '*' OR allowed.cid = m.category_id::text
);
"@
    $listDocs.parameters.options.queryReplacement = "={{ `$('Prepare Input').item.json.sessionId }}, {{ JSON.stringify(`$('Get Allowed Categories').item.json.allowed_ids) }}"
}

$getFile = $wf.nodes | Where-Object { $_.name -eq 'Get File Contents' } | Select-Object -First 1
if ($getFile) {
    $getFile.parameters.query = @"
SELECT string_agg(d.content, ' ') AS document_text
FROM zanaflex_documents d
WHERE d.metadata->>'file_id' = `$1
  AND EXISTS (
    SELECT 1 FROM jsonb_array_elements_text(`$2::jsonb) AS allowed(cid)
    WHERE allowed.cid = '*' OR allowed.cid = d.metadata->>'category_id'
  )
GROUP BY d.metadata->>'file_id';
"@
    $getFile.parameters.options.queryReplacement = "={{ `$fromAI('file_id') }}, {{ JSON.stringify(`$('Get Allowed Categories').item.json.allowed_ids) }}"
}

$qrows = $wf.nodes | Where-Object { $_.name -eq 'Query Document Rows' } | Select-Object -First 1
if ($qrows) {
    # Keep dynamic SQL but constrain through a view? Simpler: leave SQL as $fromAI but rely on category_id presence in document_rows.
    # No standard ACL way for free-form SQL — add a description warning.
    $qrows.parameters.toolDescription = "Executa SQL livre em zanaflex_document_rows (linhas de planilhas indexadas). ATENCAO: use SEMPRE dataset_id IN (SELECT id FROM zanaflex_document_metadata WHERE category_id::text = ANY(SELECT jsonb_array_elements_text('REPLACE_BY_AGENT_WITH_ALLOWED_IDS'))) para respeitar permissoes do usuario. Em caso de duvida, consulte primeiro List Documents."
}

# --- 7) Save ---
$json = $wf | ConvertTo-Json -Depth 100
[System.IO.File]::WriteAllText($dst, $json, $enc)

try {
    $check = [System.IO.File]::ReadAllText($dst, $enc) | ConvertFrom-Json
    "OK: Zanaflex-Agent-IA.json valid. Nodes: $($check.nodes.Count). Size: $((Get-Item $dst).Length) bytes."
} catch {
    "FAIL parse: $_"
}
