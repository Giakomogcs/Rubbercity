# Rubbercity — Agente OFM + RAG

Agente de IA da **Rubbercity** que ajuda o responsável pelo setor de massa (Alex Szabo) a decidir as **Ordens de Fabricação de Massa (OFM)**. Combina:

- **RAG** do PDF descritivo OFM e demais documentos liberados por equipe (ACL).
- **Tools de banco** que consultam o ERP MySQL (read-only, usuário `senai-ia`) — sem Excel, só SQL.
- **Regras de negócio estruturadas** em tabelas Supabase (equivalências de massa, regras de mix por cor, exceções por cliente, margens de segurança, workflow de status de produção).
- **Chat com histórico**, sessões, painel admin para usuários/equipes/categorias/documentos.

Adaptado a partir do agente Zanaflex; mantém o mesmo padrão de auth/ACL/RAG e adiciona a camada **OFM** específica.

---

## Arquitetura

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                       NAVEGADOR (front-rubbercity.html)                     │
│  Chat OFM · Login · Admin (Usuários, Equipes, Categorias, Documentos)       │
└────────────────────┬─────────────────────────────────────┬──────────────────┘
                     │ Auth (Supabase JS SDK)              │ Webhooks (n8n)
                     ▼                                     ▼
       ┌───────────────────────────┐    ┌─────────────────────────────────────┐
       │  Supabase (Postgres +     │    │ n8n                                 │
       │  pgvector + Auth)         │◄───┤ Workflows:                          │
       │                           │    │  - Rubbercity-Front                 │
       │  - rubbercity_users       │    │  - Rubbercity-Agent-OFM             │
       │  - rubbercity_teams       │    │  - Rubbercity-RAG                   │
       │  - rubbercity_documents   │    │  - Rubbercity-RAG-Admin             │
       │    (vetores 1536d)        │    │  - Rubbercity-MySQL-Bridge          │
       │  - rubbercity_*_ofm       │    │  - Chat GET/DELETE × 3              │
       │  - rubbercity_chat_message│    └────────┬──────────────┬─────────────┘
       └───────────────────────────┘             │              │
                                                  ▼              ▼
                                      ┌──────────────┐   ┌──────────────────┐
                                      │ Google Drive │   │ ERP MySQL        │
                                      │ (categorias) │   │ 45.185.0.14:3306 │
                                      │              │   │ producaodb +     │
                                      │              │   │ quimicadb        │
                                      └──────────────┘   └──────────────────┘
```

---

## Fluxo de uma pergunta ao agente OFM

Exemplo: *"Monte as OFMs do dia"*.

1. Front → `POST /webhook/rubbercity-AgentRag` com `{ sessionId, userId, message }`.
2. `Prepare Input` antepõe `[CONTEXTO DO USUÁRIO: nome=... ID="uuid"]` (o trigger SQL usa esse bloco para popular `user_id` em `rubbercity_chat_message`).
3. Agente LangChain (Azure OpenAI) — system prompt traz todas as regras de domínio do PDF. Ferramentas disponíveis:
   - **search_ofm_knowledge** → vetorial em `rubbercity_documents` via `rubbercity_match_documents_for_user(userId, embedding)` com ACL.
   - **list_production_orders** → `Rubbercity-MySQL-Bridge` → `producaodb.producao` filtrando status/queima/usinagem/balanceamento conforme `rubbercity_status_workflow`.
   - **check_mass_stock** → `Rubbercity-MySQL-Bridge` → `quimicadb.matprima` (saldos por formulação).
   - **lookup_formula** → `Rubbercity-MySQL-Bridge` → `quimicadb.formula` (traduz mat+dureza → formulacao).
   - **lookup_customer_override** → `rubbercity_ofm_resolve_customer(...)` (AMBEV/AVANÇO/PRINTGRAF/BRASMETAL).
   - **rules_can_substitute / rules_can_mix_colors / rules_band_for / rules_safety_margin / compute_recipe** → RPCs Supabase.
4. Agente compõe uma resposta em markdown listando rolos, formulação proposta, kg base + margem, decomposição de mix se aplicável, e a justificativa de cada decisão.
5. Resposta volta ao front; mensagens são persistidas em `rubbercity_chat_message`.

---

## Como o agente decide uma OFM (raciocínio padrão do system prompt)

```
1. list_production_orders        → busca pedidos aceitáveis (status + flags)
2. para cada pedido:
   a. lookup_customer_override   → exceção do cliente, se houver
   b. lookup_formula             → formulação oficial
   c. check_mass_stock           → saldo disponível
   d. se faltar:
      - rules_can_substitute     → AG cobre ABI/EPP/RC até 35/40 etc.
      - rules_can_mix_colors     → branca×vermelha proibida, preta só em preta…
   e. rules_safety_margin        → +5% a 8% sobre o kt
   f. compute_recipe             → ROLL_BOW, HYPALON, EBONITE_BASE
3. agrupa por (formulação, cor) → propõe lotes
4. lista OFMs com justificativa item a item
```

Pedidos com pendência (queima=`S`, usinagem incompleta, balanceamento pendente, ENDs, retífica pura) **não geram OFM** — são listados separadamente com motivo.

---

## Estrutura de pastas

```
rubbercity-agent/
├── README.md                          ← este arquivo
├── front-rubbercity.html              ← SPA single-file (chat + admin)
├── migrations/                        ← histórico Zanaflex (legacy, referência)
├── migrations-clean/                  ← migrations para Supabase novo
│   ├── 001_users_and_admin.sql
│   ├── 002_categories.sql
│   ├── 003_teams_and_acl.sql
│   ├── 004_rag_schema.sql
│   ├── 005_match_documents.sql
│   ├── 006_chat_messages.sql
│   ├── 007_seeds.sql                  ← admin@rubbercity.com.br / @Admin123 + categorias OFM/IT/...
│   ├── 008_ofm_reference_tables.sql   ← bandas, famílias, equivalência, mix de cor, estoque min, receitas, status workflow
│   ├── 009_ofm_customer_overrides.sql
│   ├── 010_ofm_rules_rpc.sql          ← funções consumidas pelo agente
│   ├── 011_ofm_seeds.sql              ← dados do PDF descritivo + BD-Rubbercity
│   └── README.md
└── workspaces/                        ← workflows n8n
    ├── Rubbercity-Front.json
    ├── Rubbercity-Agent-OFM.json      ← novo agente (substitui Zanaflex-Agent-IA)
    ├── Rubbercity-MySQL-Bridge.json   ← novo: 3 endpoints para producaodb/quimicadb
    ├── Rubbercity-RAG.json
    ├── Rubbercity-RAG-Admin.json
    ├── Rubbercity-Chat-GET-Sessions.json
    ├── Rubbercity-Chat-GET-History.json
    ├── Rubbercity-Chat-DELETE-Session.json
    └── README.md
```

---

## Stack e credenciais

| Camada                | Tecnologia |
|-----------------------|------------|
| Front                 | HTML/CSS/JS · Supabase JS SDK · Lucide |
| Orquestração          | n8n (self-hosted) |
| LLM + embeddings      | Azure OpenAI — `text-embedding-3-small`, `gpt-4o`/`gpt-5.x` |
| Banco                 | Supabase (Postgres 15 + pgvector) |
| ERP                   | MySQL 5.x `45.185.0.14:3306` (`producaodb`, `quimicadb`) — usuário `senai-ia` read-only |
| Armazenamento docs    | Google Drive (uma pasta por categoria) |
| Auth                  | Supabase Auth (email/senha) |

Credenciais n8n a configurar:

- **Postgres** (Supabase Rubbercity) — credencial chamada `Rubbercity-DB` em todos os nós Postgres. O id `REPLACE_ME_RUBBERCITY_DB` nos workflows deve ser substituído pelo id real da credencial Rubbercity-DB no seu n8n (NOVA credencial, não reuse a da Zanaflex).
- **Azure OpenAI** — substituir `REPLACE_ME_AZURE_OPENAI_CRED` em `Rubbercity-Agent-OFM.json` (e `Rubbercity-RAG.json`).
- **Supabase API** — substituir `REPLACE_ME_SUPABASE_CRED` no nó vector store do Agent OFM.
- **MySQL (Rubbercity ERP)** — criar credencial `Rubbercity ERP (read-only)`, host `45.185.0.14`, port `3306`, db `producaodb`, user `senai-ia`, senha `Rbct2804@`. Trocar `REPLACE_ME_MYSQL_RBCT` no `Rubbercity-MySQL-Bridge.json`.

---

## Setup do zero

1. **Subir o Supabase** (ou usar existente) e rodar as migrations em ordem **001 → 011** (ver [migrations-clean/README.md](migrations-clean/README.md)).
2. **Importar os 8 workflows** em [`workspaces/`](workspaces/) no n8n.
3. **Substituir os placeholders** de credencial nos workflows (`REPLACE_ME_*`).
4. **Ativar** os workflows. Verificar que `Rubbercity-MySQL-Bridge` responde nas 3 rotas (`/webhook/rubbercity-mysql-orders|stock|formula`).
5. **Servir** `front-rubbercity.html` via o workflow `Rubbercity-Front` (ou hospedar estático).
6. **Login** com `admin@rubbercity.com.br` / `@Admin123` — **trocar a senha imediatamente**.
7. **Categorias** — pelo painel admin, definir `drive_folder_id` da categoria `OFM` (pasta do Drive onde estarão o PDF descritivo + outros documentos).
8. **Upload do PDF descritivo OFM** via "Adicionar Documento" do painel (`POST /webhook/rubbercity-rag-upload`).
9. **Equipes** — criar uma equipe "Massa" e dar acesso à categoria `OFM`; associar Alex Szabo a ela.

---

## Regras de negócio capturadas (tabelas 008-011)

| Conceito | Onde está |
|----------|-----------|
| Faixas oficiais 20/25, 25/28, 30/33, 35/40 | `rubbercity_durometer_band` |
| Aliases (ex.: `23/27` cai em `20/25`) | `rubbercity_durometer_alias` |
| Famílias de massa (AG, ABI, EPP, RC, FLEX, PU, NEOPRENE, HYPALON, EBONITE, NAT…) | `rubbercity_material_family` |
| Equivalências (AG cobre ABI/EPP/RC até 35/40; complementos FLEX/PU em ABI) | `rubbercity_material_equivalence` |
| Mix por cor (branca×vermelha proibida; preta só em preta; verde/cinza em preta) | `rubbercity_color_mix_rule` |
| Estoque mínimo AG 20/25, 25/28, 30/33 = 90 kg; AG 35/40 = 30 kg | `rubbercity_min_stock` |
| Receitas especiais ROLL_BOW, HYPALON, EBONITE_BASE, DUPLA_CAMADA, FLAMENGUISTA | `rubbercity_product_recipe` |
| Workflow de status: ACCEPT/IGNORE/WAIT para LIMPEZA/LIMPEZAI/JATO/ENDS + flags `queima`/`bl*`/`usi*` | `rubbercity_status_workflow` |
| Exceções por cliente (AMBEV, AVANÇO, PRINTGRAF, BRASMETAL) | `rubbercity_customer_override` |
| Margem de segurança por parede e dureza | função `rubbercity_ofm_safety_margin` |

Todas essas tabelas podem ser editadas pelo painel admin (categorias) ou via SQL direto no Supabase, sem código.

---

## Próximos passos sugeridos

- Adicionar página admin no front para CRUD direto das tabelas OFM (hoje editáveis só via SQL).
- Calibrar margens de segurança com dados reais (atualmente uma curva simples por espessura de parede).
- Logar cada execução do agente OFM em uma tabela `rubbercity_ofm_run` para auditoria das decisões (rolos analisados, formulações sugeridas, justificativa).
- Workflow agendado diário (cron 16h) que executa o agente em modo *batch* e envia a proposta de OFMs por email para Alex Szabo.
