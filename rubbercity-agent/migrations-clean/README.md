# Rubbercity — Migrations (clean) para Supabase novo

Versão consolidada e enxuta das migrations, pensada para rodar do zero num Supabase limpo. As 7 primeiras vêm da base Zanaflex (auth/ACL/RAG/chat). As **008 → 011** são específicas do agente **OFM** (Ordem de Fabricação de Massa) da Rubbercity. Cada arquivo tem o bloco `DOWN` comentado no final.

## Ordem de execução

Execute na ordem numérica, uma de cada vez (Supabase Dashboard → SQL Editor → New query → cole → Run):

| #   | Arquivo                          | Conteúdo                                                                                                                                                                                   |
| --- | -------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 001 | `001_users_and_admin.sql`        | Helpers `rubbercity_is_admin/is_member`, CRUD de usuários, guards admin-only, anti self-delete, `set_user_teams`                                                                           |
| 002 | `002_categories.sql`             | Categorias de documento (com `drive_folder_id`) + RPCs admin                                                                                                                               |
| 003 | `003_teams_and_acl.sql`          | Equipes, membros, ACL team×categoria + helpers `user_allowed_categories[_for]`                                                                                                             |
| 004 | `004_rag_schema.sql`             | pgvector + tabelas RAG + upsert/purge atômicos + listagens                                                                                                                                 |
| 005 | `005_match_documents.sql`        | `match_documents` (ACL via filter, service_role bypass, enrichment) + variante `_for_user`                                                                                                 |
| 006 | `006_chat_messages.sql`          | Tabela `rubbercity_chat_message` (com `user_id`) + trigger                                                                                                                                 |
| 007 | `007_seeds.sql`                  | Seed categoria `OFM` + admin bootstrap (`admin@rubbercity.com.br` / `@Admin123`)                                                                                                           |
| 008 | `008_ofm_reference_tables.sql`   | Tabelas mestre: escalas de dureza, equivalência de massas (AG→ABI/EPP/RC…), regras de mix de cor, regras de produto especiais (ROLL BOW, HYPALON, ebonite, dupla camada), estoques mínimos |
| 009 | `009_ofm_customer_overrides.sql` | Exceções por cliente (AMBEV PU 45/50→PU 50/55 VD, AVANÇO ABI 70/75→75/80, BRASMETAL 50%+50%, PRINTGRAF→FLEX)                                                                               |
| 010 | `010_ofm_rules_rpc.sql`          | RPCs de consulta de regras: `ofm_resolve_formula`, `ofm_durometer_band`, `ofm_can_mix_colors`, `ofm_safety_margin`                                                                         |
| 011 | `011_ofm_seeds.sql`              | Seeds das tabelas 008/009 a partir do PDF descritivo OFM da Rubbercity                                                                                                                     |

## Pós-instalação

1. Faça login com `admin@rubbercity.com.br` / `@Admin123` e **troque a senha** imediatamente.
2. Configure o `drive_folder_id` da categoria `OFM` na página Categorias do front (para upload do descritivo e procedimentos).
3. Importe e ative os 7 workflows n8n em [`../workspaces/`](../workspaces/README.md). Substitua `REPLACE_ME_OPENAI_CRED` pela credencial Azure OpenAI real, e `REPLACE_ME_MYSQL_RBCT` pela credencial MySQL `senai-ia@45.185.0.14:3306` (read-only).
4. Ajuste/seed as tabelas 008-009 conforme regras vigentes (o `011_ofm_seeds.sql` traz os defaults extraídos do PDF descritivo OFM e do BD-Rubbercity).

## Rollback

Cada arquivo tem o bloco `-- =======  DOWN  ========` no final com `DROP`/`DELETE` comentados. Para reverter tudo, descomente e execute na ordem inversa (011 → 001).
