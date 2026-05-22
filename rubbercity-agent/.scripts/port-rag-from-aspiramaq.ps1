$ErrorActionPreference = "Stop"

$src  = "C:\Users\Administrador\Downloads\Aspiramaq\workspaces\Aspiramaq-RAG.json"
$root = "C:\Users\Administrador\Downloads\Zanaflex\zanaflex"
$dst  = "$root\workspaces\Zanaflex-RAG.json"
$enc  = New-Object System.Text.UTF8Encoding($false)

# --- 1) Read source as UTF-8 and bulk prefix-rename ---
$text = [System.IO.File]::ReadAllText($src, $enc)

# Fix Aspiramaq typos before generic rename so we don't carry them over
$text = $text.Replace('aspirapaq_documents',  'aspiramaq_documents')
$text = $text.Replace('aspiramaq_metadata->', 'metadata->')

# Aspiramaq -> Zanaflex
$text = $text.Replace('aspiramaq_',  'zanaflex_')
$text = $text.Replace('aspiramaq-',  'zanaflex-')
$text = $text.Replace('Aspiramaq',   'Zanaflex')
$text = $text.Replace('ASPIRAMAQ',   'ZANAFLEX')
$text = $text.Replace('aspiramaq',   'zanaflex')

# Credential placeholders (Zanaflex tenant)
$text = $text.Replace('"id":"i5Q8tj8Pyc9XjSGd","name":"Supabase account"',                   '"id":"REPLACE_ME_SUPABASE_CRED","name":"Supabase service_role"')
$text = $text.Replace('"id":"1yxLK6IGIPQiU21B","name":"Google Drive account"',               '"id":"REPLACE_ME_GDRIVE_CRED","name":"Google Drive (Zanaflex)"')
$text = $text.Replace('"id":"Vx67HOLUDVbPAmHc","name":"Google Gemini(PaLM) Api account"',    '"id":"REPLACE_ME_GEMINI","name":"gemini (optional)"')
$text = $text.Replace('"id":"hZRBXrfocBn4jbFB","name":"openrouter_cloudfy"',                 '"id":"REPLACE_ME_OPENROUTER","name":"openrouter (optional)"')

# Google Drive folder ID -> placeholder (user must point to a Zanaflex folder)
$text = $text.Replace('1GjhE3afR9P31voTVW4sP4rIUGoXRj1Tv', 'REPLACE_ME_GDRIVE_FOLDER_ID')

# n8n test-instance URL leftover in sticky notes
$text = $text.Replace('exotickoala-n8n.cloudfy.live', 'longflatworm-n8n.cloudfy.live')

# --- 2) Parse JSON for surgical edits ---
$wf = $text | ConvertFrom-Json
$wf.name = "Zanaflex-RAG"

# 2a) Set File ID - to Context: add category_id / category_code from webhook body
$setNode = $wf.nodes | Where-Object { $_.name -eq 'Set File ID - to Context' } | Select-Object -First 1
if ($setNode) {
    $setNode.parameters.assignments.assignments += [pscustomobject]@{
        id    = [Guid]::NewGuid().ToString()
        name  = 'category_id'
        value = "={{ `$if( `$(`"InsertFile-drive`").isExecuted, `$(`"InsertFile-drive`").first().json.body.category_id, null) }}"
        type  = 'string'
    }
    $setNode.parameters.assignments.assignments += [pscustomobject]@{
        id    = [Guid]::NewGuid().ToString()
        name  = 'category_code'
        value = "={{ `$if( `$(`"InsertFile-drive`").isExecuted, `$(`"InsertFile-drive`").first().json.body.category_code, null) }}"
        type  = 'string'
    }
    $setNode.parameters.assignments.assignments += [pscustomobject]@{
        id    = [Guid]::NewGuid().ToString()
        name  = 'code'
        value = "={{ `$if( `$(`"InsertFile-drive`").isExecuted, `$(`"InsertFile-drive`").first().json.body.code, `$input.item.json.name) }}"
        type  = 'string'
    }
}

# 2b) Default Data Loader: include category_id in chunk metadata so filter-ACL works at query time
$ddl = $wf.nodes | Where-Object { $_.name -eq 'Default Data Loader' } | Select-Object -First 1
if ($ddl) {
    $ddl.parameters.options.metadata.metadataValues += [pscustomobject]@{
        name  = 'category_id'
        value = "={{ `$('Set File ID - to Context').first().json.category_id }}"
    }
    $ddl.parameters.options.metadata.metadataValues += [pscustomobject]@{
        name  = 'code'
        value = "={{ `$('Set File ID - to Context').first().json.code }}"
    }
}

# 2c) Insert Document Metadata1 (upsert into zanaflex_document_metadata): add category_id and code
$insMeta = $wf.nodes | Where-Object { $_.name -eq 'Insert Document Metadata1' } | Select-Object -First 1
if ($insMeta) {
    $insMeta.parameters.columns.value | Add-Member -NotePropertyName 'category_id' -NotePropertyValue "={{ `$('Set File ID - to Context').item.json.category_id }}" -Force
    $insMeta.parameters.columns.value | Add-Member -NotePropertyName 'code'        -NotePropertyValue "={{ `$('Set File ID - to Context').item.json.code }}"        -Force
    # Extend schema entries
    $insMeta.parameters.columns.schema += [pscustomobject]@{
        id = 'category_id'; displayName = 'category_id'; required = $false; defaultMatch = $false; display = $true; type = 'string'; canBeUsedToMatch = $false; removed = $false
    }
    $insMeta.parameters.columns.schema += [pscustomobject]@{
        id = 'code';        displayName = 'code';        required = $false; defaultMatch = $false; display = $true; type = 'string'; canBeUsedToMatch = $false; removed = $false
    }
}

# 2d) Update Schema for Document Metadata: also persist category_id when Excel/CSV branch runs
$updSchema = $wf.nodes | Where-Object { $_.name -eq 'Update Schema for Document Metadata' } | Select-Object -First 1
if ($updSchema) {
    $updSchema.parameters.columns.value | Add-Member -NotePropertyName 'category_id' -NotePropertyValue "={{ `$('Set File ID - to Context').item.json.category_id }}" -Force
    $updSchema.parameters.columns.schema += [pscustomobject]@{
        id = 'category_id'; displayName = 'category_id'; required = $false; defaultMatch = $false; display = $true; type = 'string'; canBeUsedToMatch = $false; removed = $false
    }
}

# 2e) Confirmar Upload: respond with file_id and friendly status
$confirmar = $wf.nodes | Where-Object { $_.name -eq 'Confirmar Upload' } | Select-Object -First 1
if ($confirmar) {
    $confirmar.parameters.responseBody = "={ ""status"": ""success"", ""message"": ""Documento processado com sucesso! Memoria RAG atualizada."", ""file_id"": ""{{ `$('Set File ID - to Context').first().json.file_id }}"" }"
}

# --- 3) Save ---
$json = $wf | ConvertTo-Json -Depth 100
[System.IO.File]::WriteAllText($dst, $json, $enc)

try {
    $check = [System.IO.File]::ReadAllText($dst, $enc) | ConvertFrom-Json
    "OK: Zanaflex-RAG.json valid. Nodes: $($check.nodes.Count). Size: $((Get-Item $dst).Length) bytes."
} catch {
    "FAIL parse: $_"
}
