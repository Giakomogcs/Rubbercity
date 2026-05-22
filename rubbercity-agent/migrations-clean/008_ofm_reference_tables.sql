-- =============================================
-- Rubbercity — 008: Tabelas mestre do domínio OFM
--
-- Modelo de dados que captura as regras descritas no PDF
-- "DESCRITIVO OFM - Ordem Fabricação de Massas".
--
-- Inclui:
--   * rubbercity_durometer_band         - faixas oficiais (20/25, 25/28, 30/33, 35/40)
--                                          + mapeamento de "durezas vizinhas" para cada faixa.
--   * rubbercity_material_family        - famílias de massa (AG, ABI, EPP, RC, FLEX,
--                                          PU, NEOPRENE, HYPALON, EBONITE, NAT...).
--   * rubbercity_material_equivalence   - substituições permitidas
--                                          (ex.: AG cobre ABI/EPP/RC até 35/40).
--   * rubbercity_color_mix_rule         - regras de mix por cor.
--   * rubbercity_min_stock              - estoque mínimo desejado por massa
--                                          (AG 20/25, 25/28, 30/33 = 90 kg; 35/40 = 30 kg).
--   * rubbercity_product_recipe         - receitas especiais de produto
--                                          (ROLL BOW, HYPALON, dupla camada, ebonite base).
--   * rubbercity_status_workflow        - status que o agente DEVE/PODE/NÃO DEVE pegar
--                                          (LIMPEZA, JATO, ENDS, balanceamento…).
--
-- Todas as tabelas são lidas por todos os membros rubbercity e escritíveis
-- somente por admin via RPCs (ou direto no SQL Editor).
--
-- Rode APÓS 007_seeds.sql.
-- =============================================

-- =======  UP  ========

-- ---------- 1) faixas de dureza oficiais ----------
CREATE TABLE IF NOT EXISTS rubbercity_durometer_band (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  band_code    TEXT NOT NULL UNIQUE,         -- '20/25', '25/28', '30/33', '35/40'
  band_min     INT  NOT NULL,                -- limite inferior nominal (ex.: 20)
  band_max     INT  NOT NULL,                -- limite superior nominal (ex.: 25)
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- "durezas reais" aceitas dentro de cada faixa. Ex.: faixa 20/25 cobre
-- 17/23, 20/23, 20/25, 22/25, 23/27, 24/26, 25.
CREATE TABLE IF NOT EXISTS rubbercity_durometer_alias (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  band_id          UUID NOT NULL REFERENCES rubbercity_durometer_band(id) ON DELETE CASCADE,
  alias_text       TEXT NOT NULL,            -- como aparece no pedido (ex.: '23/27', '25')
  alias_min        INT,                      -- numérico para comparações
  alias_max        INT,
  UNIQUE(band_id, alias_text)
);
CREATE INDEX IF NOT EXISTS idx_rubbercity_durometer_alias_text ON rubbercity_durometer_alias(alias_text);

-- ---------- 2) famílias de massa ----------
CREATE TABLE IF NOT EXISTS rubbercity_material_family (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  code            TEXT NOT NULL UNIQUE,      -- 'AG','ABI','ABI_CARBOX','EPP','EPPLUS','EPDM',
                                              -- 'RC_2000','RC_AD_503','RC_ULTRA','RC_ULTRA_CARBOX',
                                              -- 'FLEX','FLEX_ROT','FLEX_AT','PU_SOLIDO','PU_LIQUIDO',
                                              -- 'NEOPRENE','HYPALON','EBONITE','NAT','SB_NAT'
  name            TEXT NOT NULL,
  is_pu_liquido   BOOLEAN NOT NULL DEFAULT FALSE,
  notes           TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ---------- 3) equivalências / substituições de massa ----------
-- Regra do PDF: "a massa AG pode e deve ser usada no lugar de ABI, ABI CARBOX,
-- EPP, EPPLUS, EPDM, RC 2000, RC AD 503, RC ULTRA CARBOX, RC ULTRA até dureza 35/40."
-- Modelado como linhas (source_family substitui target_family até max_band).
CREATE TABLE IF NOT EXISTS rubbercity_material_equivalence (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  source_family_id UUID NOT NULL REFERENCES rubbercity_material_family(id) ON DELETE CASCADE,
  target_family_id UUID NOT NULL REFERENCES rubbercity_material_family(id) ON DELETE CASCADE,
  max_band_id      UUID REFERENCES rubbercity_durometer_band(id) ON DELETE SET NULL,
  -- complementos permitidos para "completar lote" (FLEX, FLEX_ROT, PU_SOLIDO em pedidos de ABI):
  is_complement    BOOLEAN NOT NULL DEFAULT FALSE,
  notes            TEXT,
  UNIQUE(source_family_id, target_family_id)
);

-- ---------- 4) regras de mix de cor ----------
-- "branca não mixa com vermelha", "preta só entra em mix de preta",
-- "verde entra em verde e preta", "cinza entra em cinza e preta", etc.
CREATE TABLE IF NOT EXISTS rubbercity_color_mix_rule (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  source_color    TEXT NOT NULL,             -- cor da massa em estoque (branca, preta, vermelha...)
  target_color    TEXT NOT NULL,             -- cor pretendida no rolo
  is_allowed      BOOLEAN NOT NULL,
  notes           TEXT,
  UNIQUE(source_color, target_color)
);
CREATE INDEX IF NOT EXISTS idx_rubbercity_colormix_target ON rubbercity_color_mix_rule(target_color);

-- ---------- 5) estoque mínimo desejado ----------
-- Por padrão, ideal = 0 kg (massa tem prazo de validade).
-- Exceções do PDF: AG 20/25, 25/28, 30/33 PT → 90 kg; AG 35/40 PT → 30 kg.
CREATE TABLE IF NOT EXISTS rubbercity_min_stock (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  family_id       UUID NOT NULL REFERENCES rubbercity_material_family(id) ON DELETE CASCADE,
  band_id         UUID NOT NULL REFERENCES rubbercity_durometer_band(id) ON DELETE CASCADE,
  color           TEXT,                      -- NULL = qualquer cor
  min_kg          NUMERIC(10,2) NOT NULL,
  notes           TEXT,
  UNIQUE(family_id, band_id, color)
);

-- ---------- 6) receitas/regras de produto especial ----------
-- ROLL BOW: toda camisa vai com base ABI 70/75 PT (50% do peso) + a massa final.
-- HYPALON: 2/3 de neoprene + 1/3 de hypalon.
-- Dupla camada, flamenguistas, ebonite base: regras descritas em texto.
CREATE TABLE IF NOT EXISTS rubbercity_product_recipe (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  recipe_code     TEXT NOT NULL UNIQUE,      -- 'ROLL_BOW','HYPALON','DUPLA_CAMADA','EBONITE_BASE','FLAMENGUISTA'
  description     TEXT NOT NULL,
  components      JSONB NOT NULL,
    -- formato sugerido:
    -- [
    --   {"family":"ABI","band":"70/75","color":"PT","fraction":0.50,"role":"base"},
    --   {"family":"<varia>","fraction":0.50,"role":"top"}
    -- ]
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ---------- 7) workflow de status na producaodb.producao ----------
-- O agente precisa saber quais combinações de status/flags ele PODE pegar
-- e quais ele DEVE IGNORAR. Modelado como tabela para ficar editaveldepois.
CREATE TABLE IF NOT EXISTS rubbercity_status_workflow (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  rule_name       TEXT NOT NULL UNIQUE,
  action          TEXT NOT NULL CHECK (action IN ('ACCEPT','IGNORE','WAIT')),
  match_status    TEXT[],                    -- status que dispara a regra (ex.: '{LIMPEZA,LIMPEZAI,JATO}')
  conditions      JSONB,                     -- ex.: {"bl":"S","bl_desba":"S","blpr":"S"} (peca voltou do balanceamento)
  priority        INT NOT NULL DEFAULT 100,
  notes           TEXT
);

-- ---------- RLS ----------
ALTER TABLE rubbercity_durometer_band       ENABLE ROW LEVEL SECURITY;
ALTER TABLE rubbercity_durometer_alias      ENABLE ROW LEVEL SECURITY;
ALTER TABLE rubbercity_material_family      ENABLE ROW LEVEL SECURITY;
ALTER TABLE rubbercity_material_equivalence ENABLE ROW LEVEL SECURITY;
ALTER TABLE rubbercity_color_mix_rule       ENABLE ROW LEVEL SECURITY;
ALTER TABLE rubbercity_min_stock            ENABLE ROW LEVEL SECURITY;
ALTER TABLE rubbercity_product_recipe       ENABLE ROW LEVEL SECURITY;
ALTER TABLE rubbercity_status_workflow      ENABLE ROW LEVEL SECURITY;

DO $$ BEGIN
  CREATE POLICY rbct_ofm_ref_select ON rubbercity_durometer_band       FOR SELECT TO authenticated USING (rubbercity_is_member());
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  CREATE POLICY rbct_ofm_ref_select ON rubbercity_durometer_alias      FOR SELECT TO authenticated USING (rubbercity_is_member());
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  CREATE POLICY rbct_ofm_ref_select ON rubbercity_material_family      FOR SELECT TO authenticated USING (rubbercity_is_member());
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  CREATE POLICY rbct_ofm_ref_select ON rubbercity_material_equivalence FOR SELECT TO authenticated USING (rubbercity_is_member());
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  CREATE POLICY rbct_ofm_ref_select ON rubbercity_color_mix_rule       FOR SELECT TO authenticated USING (rubbercity_is_member());
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  CREATE POLICY rbct_ofm_ref_select ON rubbercity_min_stock            FOR SELECT TO authenticated USING (rubbercity_is_member());
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  CREATE POLICY rbct_ofm_ref_select ON rubbercity_product_recipe       FOR SELECT TO authenticated USING (rubbercity_is_member());
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  CREATE POLICY rbct_ofm_ref_select ON rubbercity_status_workflow      FOR SELECT TO authenticated USING (rubbercity_is_member());
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

GRANT SELECT ON rubbercity_durometer_band       TO authenticated, service_role;
GRANT SELECT ON rubbercity_durometer_alias      TO authenticated, service_role;
GRANT SELECT ON rubbercity_material_family      TO authenticated, service_role;
GRANT SELECT ON rubbercity_material_equivalence TO authenticated, service_role;
GRANT SELECT ON rubbercity_color_mix_rule       TO authenticated, service_role;
GRANT SELECT ON rubbercity_min_stock            TO authenticated, service_role;
GRANT SELECT ON rubbercity_product_recipe       TO authenticated, service_role;
GRANT SELECT ON rubbercity_status_workflow      TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

-- =======  DOWN  ========
-- DROP TABLE IF EXISTS rubbercity_status_workflow      CASCADE;
-- DROP TABLE IF EXISTS rubbercity_product_recipe       CASCADE;
-- DROP TABLE IF EXISTS rubbercity_min_stock            CASCADE;
-- DROP TABLE IF EXISTS rubbercity_color_mix_rule       CASCADE;
-- DROP TABLE IF EXISTS rubbercity_material_equivalence CASCADE;
-- DROP TABLE IF EXISTS rubbercity_material_family      CASCADE;
-- DROP TABLE IF EXISTS rubbercity_durometer_alias      CASCADE;
-- DROP TABLE IF EXISTS rubbercity_durometer_band       CASCADE;
-- NOTIFY pgrst, 'reload schema';
