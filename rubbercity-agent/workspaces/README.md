# Rubbercity — n8n Workflows

8 workflows que compõem o backend Rubbercity. Importe **todos** no mesmo projeto n8n.

| Arquivo                                                                | Webhooks expostos                                                                                                                                                                                                                |
| ---------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [Rubbercity-Front.json](Rubbercity-Front.json)                         | `GET /webhook/rubbercity-chat` — serve o HTML do front                                                                                                                                                                          |
| [Rubbercity-Agent-OFM.json](Rubbercity-Agent-OFM.json)                 | `POST /webhook/rubbercity-AgentRag` — agente OFM com tools de MySQL/Supabase                                                                                                                                                    |
| [Rubbercity-MySQL-Bridge.json](Rubbercity-MySQL-Bridge.json)           | `POST /webhook/rubbercity-mysql-orders` · `…/rubbercity-mysql-stock` · `…/rubbercity-mysql-formula` (lidos pelo Agent OFM)                                                                                                       |
| [Rubbercity-RAG.json](Rubbercity-RAG.json)                             | `POST /webhook/rubbercity-index-drive` · `…/rubbercity-rag-upload` · `…/rubbercity-rag-reindex` + trigger `Webhook Setup`/manual para reset                                                                                      |
| [Rubbercity-RAG-Admin.json](Rubbercity-RAG-Admin.json)                 | `POST /webhook/rubbercity-rag-upsert` · `GET /webhook/rubbercity-rag-docs` · `DELETE /webhook/rubbercity-rag-doc-delete` · `POST /webhook/rubbercity-rag-purge-all`                                                              |
| [Rubbercity-Chat-GET-Sessions.json](Rubbercity-Chat-GET-Sessions.json) | `GET /webhook/rubbercity-sessions?userId=…`                                                                                                                                                                                     |
| [Rubbercity-Chat-GET-History.json](Rubbercity-Chat-GET-History.json)   | `GET /webhook/rubbercity-history?sessionId=…&userId=…`                                                                                                                                                                          |
| [Rubbercity-Chat-DELETE-Session.json](Rubbercity-Chat-DELETE-Session.json) | `DELETE /webhook/rubbercity-session?sessionId=…&userId=…`                                                                                                                                                                    |

## Credenciais esperadas

Todos os workflows referenciam:

- **Postgres** (Supabase Rubbercity) → todos os nós Postgres apontam para uma credencial chamada `Rubbercity-DB` (id placeholder `REPLACE_ME_RUBBERCITY_DB`). **Crie uma credencial nova** no n8n com esse nome apontando para o Supabase da Rubbercity — não reaproveite a credencial da Zanaflex.
- **Azure OpenAI** → placeholder `REPLACE_ME_AZURE_OPENAI_CRED` no Agent OFM e no RAG. Trocar pelo id real antes de ativar.
- **Supabase API** → placeholder `REPLACE_ME_SUPABASE_CRED` no nó vector store do Agent OFM.
- **MySQL (Rubbercity ERP)** → placeholder `REPLACE_ME_MYSQL_RBCT` no `Rubbercity-MySQL-Bridge.json`. Criar credencial **read-only**: host `45.185.0.14`, port `3306`, db `producaodb`, user `senai-ia`, senha conforme fornecida no documento BD-Rubbercity.

## Ordem de import

1. Garanta que as migrations **001 → 011** estão aplicadas no Supabase (ver [../migrations-clean/README.md](../migrations-clean/README.md)).
2. Importe os 8 JSONs na ordem que preferir — eles são independentes entre si, mas o **Agent OFM** depende do **MySQL Bridge** estar ativo para responder corretamente sobre estoque e pedidos.
3. Em `Rubbercity-Agent-IA` e `Rubbercity-RAG`, substitua `REPLACE_ME_OPENAI_CRED` pelo id da sua credencial OpenAI (botão "..." → Edit → escolha a credencial).
4. Ative todos os workflows.

## Pontos de design importantes

### RAG — upsert atômico por documento

`POST /webhook/rubbercity-rag-upsert` recebe:

```json
{
  "file_id": "IT-18.05",
  "title": "Pesagem e Dosagem de Produtos Químicos",
  "code": "IT-18.05",
  "category_code": "IT",
  "url": "https://.../IT-18.05.pdf",
  "mime_type": "application/pdf",
  "content_text": "...texto extraído..."
}
```

O fluxo: **purge_file(file_id) → chunk → embed → insert → upsert_metadata**. Só os chunks **daquele** `file_id` são removidos antes de reinserir — os outros documentos permanecem intactos.

Para PDFs binários, insira um nó `Extract from File` **entre** _Parse Payload_ e _Chunk Content_ e use o output como `content_text`. O fallback de decode ASCII via `content_base64` existe só para emergência.

### Agent — ACL por usuário

A ferramenta `search_knowledge_base` invoca `rubbercity_match_documents_for_user(userId, embedding, ...)` (migration 012). A função aplica a ACL: admin enxerga tudo; demais usuários só veem trechos cujo `category_id` esteja entre `rubbercity_user_allowed_categories_for(userId)`.

A ferramenta `get_document_metadata` também filtra por ACL — se o usuário pedir um código que existe mas para o qual não tem acesso, o agente recebe "Documento não encontrado ou sem acesso" e responde de acordo.

### Memória de chat

O nó `Postgres Chat Memory` grava em `rubbercity_chat_message`. O trigger da migration 010 popula `user_id` extraindo do bloco `[CONTEXTO DO USUÁRIO: ... ID="uuid"]` que o nó `Prepare Input` antepõe na mensagem human. Isso garante que `GET /rubbercity-sessions?userId=...` retorne apenas as sessões daquele usuário.

### Privacidade dos endpoints de chat

Todos os 3 endpoints Chat-\* exigem `userId` e filtram por ele no SQL. Mesmo que um usuário descubra um `sessionId` alheio, a query retorna 0 linhas (cláusula `AND user_id = ...`).

## Como atualizar um IT já indexado

Basta enviar o **mesmo** `file_id` no webhook `rubbercity-rag-upsert`. A função `rubbercity_rag_purge_file` apaga só os chunks antigos daquele `file_id` e os novos chunks substituem. Nenhum outro documento é tocado. Tempo de reindexação ≈ proporcional ao tamanho daquele 1 PDF, não ao tamanho do RAG inteiro.

## RAG — entry-points unificados

O workflow `Rubbercity-RAG.json` concentra **3 webhooks de ingestão** que compartilham o mesmo pipeline downstream (extração → chunk → embed → upsert):

### 1. `POST /webhook/rubbercity-index-drive` — upload via chat

Usado quando o usuário anexa arquivo a uma sessão de chat. Mantém o comportamento original: prefixa o nome no Drive com a data (`21-05-2026_arquivo.pdf`), grava `session_id`, e o arquivo + vetores são apagados após 24 h pelo trigger `24h Trigger (Session)1`.

Multipart: `data` (binário) + body com `sessionId`, `category_id`, `category_code`, `drive_folder_id`, `code`.

### 2. `POST /webhook/rubbercity-rag-upload` — upload permanente (admin/ERP)

Usado pelo botão **Adicionar Documento** do front-end e pelo ERP da Rubbercity.

Multipart:

- `data` (arquivo) — binário do documento. O **nome do arquivo** é a chave de dedupe.
- `categoria` (string) — `category_code` (ex: `IT`, `NR`). A categoria precisa ter `drive_folder_id` configurado.

Fluxo:

1. `Lookup Upload Category` resolve `drive_folder_id` + `category_id`.
2. `Search Drive by Filename` busca arquivo com nome exato na pasta.
3. **Achou** → `Drive: Update File` mantém o mesmo `fileId` e troca só o conteúdo. **Não achou** → `Drive: Upload File (no prefix)` cria sem prefixar data.
4. `Set Upload Item Shape` normaliza para o shape do Loop Over Items.
5. Pipeline padrão: extrai texto (PDF/XLSX/CSV/Google Doc) com fallback OCR via Azure Responses → chunk + embed → insert no `rubbercity_documents` (apagando antes os chunks daquele `file_id`) → upsert em `rubbercity_document_metadata` (`source = 'admin'`).

Exemplo:

```bash
curl -X POST "https://longflatworm-n8n.cloudfy.live/webhook/rubbercity-rag-upload" \
  -F "data=@./IT-06.06.pdf" \
  -F "categoria=IT"
```

### 3. `POST /webhook/rubbercity-rag-reindex` — reprocessar 1/N/todos

Re-executa o pipeline RAG **sem** re-upload no Drive. Útil para refazer chunks após mudança no prompt/extrator.

JSON body (aceita qualquer um dos formatos):

```json
{ "file_id": "1AbCDef…" }
{ "file_ids": ["1AbC…", "2XyZ…"] }
{ "ids": ["1AbC…"] }
```

Fluxo:

1. `Normalize Reindex IDs` extrai e sanitiza o array.
2. `Fetch Reindex Metadata` busca `id`, `mimeType`, `webViewLink`, `category_id`, `category_code` em `rubbercity_document_metadata` + `rubbercity_document_categories`.
3. Responde imediatamente `{ status: 'queued', reindex_count, ids }` (HTTP 200) — o processamento continua em background.
4. Mesmo pipeline downstream: re-baixa do Drive pelo `file_id`, re-extrai, re-chunka, re-embede, substitui chunks no `rubbercity_documents`, atualiza `last_indexed_at`.

Exemplo:

```bash
curl -X POST "https://longflatworm-n8n.cloudfy.live/webhook/rubbercity-rag-reindex" \
  -H "Content-Type: application/json" \
  -d '{"file_ids":["1AbCDef","2XyZ"]}'
```

### Reset / Database Setup

O trigger manual `When clicking 'Execute workflow'` (ou webhook interno `Webhook Setup`) varre **todas** as categorias com `drive_folder_id`, lista cada pasta do Drive, anexa o contexto da categoria via `Attach Cat to Drive Files`, e dispara o pipeline para cada arquivo. Útil após reset completo da tabela vetorial.
