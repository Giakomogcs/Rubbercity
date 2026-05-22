$root = "C:\Users\Administrador\Downloads\Zanaflex\zanaflex"
$dst  = "$root\workspaces\Zanaflex-Agent-IA.json"
$frag = "$root\.scripts\agent-fragments"
$enc  = New-Object System.Text.UTF8Encoding($false)

# Read fragments as UTF-8 (bypasses PS 5.1 default Windows-1252 script encoding)
$prepareCode = [System.IO.File]::ReadAllText("$frag\prepare-input.js", $enc)
$aclSql      = [System.IO.File]::ReadAllText("$frag\acl.sql",          $enc)
$systemMsg   = [System.IO.File]::ReadAllText("$frag\system-prompt.md", $enc)

$wf = [ordered]@{
    name  = "Zanaflex-Agent-IA"
    nodes = @(
        [ordered]@{
            parameters  = [ordered]@{
                httpMethod   = "POST"
                path         = "zanaflex-AgentRag"
                responseMode = "responseNode"
                options      = @{}
            }
            id          = [Guid]::NewGuid().ToString()
            name        = "Webhook: AgentRag"
            type        = "n8n-nodes-base.webhook"
            typeVersion = 2
            position    = @(-720, 0)
            webhookId   = [Guid]::NewGuid().ToString()
        },
        [ordered]@{
            parameters  = [ordered]@{ jsCode = $prepareCode }
            id          = [Guid]::NewGuid().ToString()
            name        = "Prepare Input"
            type        = "n8n-nodes-base.code"
            typeVersion = 2
            position    = @(-512, 0)
        },
        [ordered]@{
            parameters  = [ordered]@{
                operation = "executeQuery"
                query     = $aclSql
                options   = @{}
            }
            id          = [Guid]::NewGuid().ToString()
            name        = "Get Allowed Categories"
            type        = "n8n-nodes-base.postgres"
            typeVersion = 2.6
            position    = @(-304, 0)
            credentials = [ordered]@{
                postgres = [ordered]@{ id = "jFjeYH6Nt3aRNkoM"; name = "Supabase_database" }
            }
        },
        [ordered]@{
            parameters  = [ordered]@{
                promptType = "define"
                text       = "={{ `$('Prepare Input').item.json.chatInput }}"
                options    = [ordered]@{ systemMessage = $systemMsg }
            }
            id          = [Guid]::NewGuid().ToString()
            name        = "AI Agent"
            type        = "@n8n/n8n-nodes-langchain.agent"
            typeVersion = 1.9
            position    = @(-96, 0)
        },
        [ordered]@{
            parameters  = [ordered]@{
                model   = "gpt-5.4-mini"
                options = @{}
            }
            id          = [Guid]::NewGuid().ToString()
            name        = "Azure OpenAI Chat Model"
            type        = "@n8n/n8n-nodes-langchain.lmChatAzureOpenAi"
            typeVersion = 1
            position    = @(-224, 240)
            credentials = [ordered]@{
                azureOpenAiApi = [ordered]@{ id = "xby4FSbCaCnssJxl"; name = "Azure Open AI account 3" }
            }
        },
        [ordered]@{
            parameters  = [ordered]@{
                sessionIdType       = "customKey"
                sessionKey          = "={{ `$('Prepare Input').item.json.sessionId }}"
                tableName           = "zanaflex_chat_message"
                contextWindowLength = 20
            }
            id          = [Guid]::NewGuid().ToString()
            name        = "Postgres Chat Memory"
            type        = "@n8n/n8n-nodes-langchain.memoryPostgresChat"
            typeVersion = 1.3
            position    = @(-96, 240)
            credentials = [ordered]@{
                postgres = [ordered]@{ id = "jFjeYH6Nt3aRNkoM"; name = "Supabase_database" }
            }
        },
        [ordered]@{
            parameters  = [ordered]@{
                mode             = "retrieve-as-tool"
                toolName         = "search_knowledge_base"
                toolDescription  = "Busca trechos relevantes nas Instrucoes de Trabalho (IT) e procedimentos da Zanaflex. Use sempre que a pergunta for tecnica ou citar um codigo (IT-XX.YY). Retorna ate 6 trechos com codigo, titulo, conteudo e link."
                tableName        = "zanaflex_documents"
                topK             = 6
                options          = [ordered]@{
                    queryName = "zanaflex_match_documents"
                }
                filter           = "={{ { allowed_category_ids: `$('Get Allowed Categories').item.json.allowed_ids } }}"
            }
            id          = [Guid]::NewGuid().ToString()
            name        = "Supabase Vector Store"
            type        = "@n8n/n8n-nodes-langchain.vectorStoreSupabase"
            typeVersion = 1.1
            position    = @(112, 240)
            credentials = [ordered]@{
                supabaseApi = [ordered]@{ id = "REPLACE_ME_SUPABASE_CRED"; name = "Supabase" }
            }
        },
        [ordered]@{
            parameters  = [ordered]@{
                model   = "text-embedding-3-small"
                options = @{}
            }
            id          = [Guid]::NewGuid().ToString()
            name        = "Azure OpenAI Embeddings"
            type        = "@n8n/n8n-nodes-langchain.embeddingsAzureOpenAi"
            typeVersion = 1
            position    = @(112, 460)
            credentials = [ordered]@{
                azureOpenAiApi = [ordered]@{ id = "xby4FSbCaCnssJxl"; name = "Azure Open AI account 3" }
            }
        },
        [ordered]@{
            parameters  = [ordered]@{
                respondWith  = "json"
                responseBody = "={ ""output"": {{ JSON.stringify(`$json.output) }}, ""sessionId"": ""{{ `$('Prepare Input').item.json.sessionId }}"" }"
                options      = @{}
            }
            id          = [Guid]::NewGuid().ToString()
            name        = "Respond"
            type        = "n8n-nodes-base.respondToWebhook"
            typeVersion = 1.1
            position    = @(112, 0)
        }
    )
    pinData     = @{}
    connections = [ordered]@{
        "Webhook: AgentRag"        = [ordered]@{ main = @(,@( [ordered]@{ node = "Prepare Input";          type = "main"; index = 0 } )) }
        "Prepare Input"            = [ordered]@{ main = @(,@( [ordered]@{ node = "Get Allowed Categories"; type = "main"; index = 0 } )) }
        "Get Allowed Categories"   = [ordered]@{ main = @(,@( [ordered]@{ node = "AI Agent";               type = "main"; index = 0 } )) }
        "AI Agent"                 = [ordered]@{ main = @(,@( [ordered]@{ node = "Respond";                type = "main"; index = 0 } )) }
        "Azure OpenAI Chat Model"  = [ordered]@{ ai_languageModel = @(,@( [ordered]@{ node = "AI Agent";              type = "ai_languageModel"; index = 0 } )) }
        "Postgres Chat Memory"     = [ordered]@{ ai_memory        = @(,@( [ordered]@{ node = "AI Agent";              type = "ai_memory";        index = 0 } )) }
        "Supabase Vector Store"    = [ordered]@{ ai_tool          = @(,@( [ordered]@{ node = "AI Agent";              type = "ai_tool";          index = 0 } )) }
        "Azure OpenAI Embeddings"  = [ordered]@{ ai_embedding     = @(,@( [ordered]@{ node = "Supabase Vector Store"; type = "ai_embedding";     index = 0 } )) }
    }
    active   = $false
    settings = [ordered]@{ executionOrder = "v1" }
    id       = "ZanaflexAgentIA"
    tags     = @()
    meta     = [ordered]@{
        notes = "Zanaflex IT assistant. Azure OpenAI (gpt-5.4-mini + text-embedding-3-small) + Supabase Vector Store with filter-based ACL. See migration 014_match_documents_filter_acl.sql. Replace REPLACE_ME_SUPABASE_CRED with your Supabase API credential id."
    }
}

$json = $wf | ConvertTo-Json -Depth 50
[System.IO.File]::WriteAllText($dst, $json, $enc)

try {
    $check = [System.IO.File]::ReadAllText($dst, $enc) | ConvertFrom-Json
    "OK: Zanaflex-Agent-IA.json valid. Nodes: $($check.nodes.Count). Size: $((Get-Item $dst).Length) bytes."
} catch {
    "FAIL: $_"
}
