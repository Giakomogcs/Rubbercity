-- =============================================
-- Rubbercity — 009: Overrides por cliente (massas usadas != pedido)
--
-- Captura a seção "Massas que são usadas diferentes do pedido" do PDF:
--   * AMBEV de PU 45/50 VD                       → PU 50/55 VD AMBEV
--   * AVANÇO de ABI 70/75 PT                     → ABI 75/80 PT
--   * Camisas da PRINTGRAF                       → FLEX correspondente
--   * BRASMETAL de SB NAT 55/60 PT               → 50% FLEX AT 60/65 PT + 50% NAT 55/60 PT
--
-- Regra de match: o agente extrai (cliente, família_pedida, banda_pedida, cor_pedida)
-- da producaodb.producao e procura aqui ANTES de aplicar a regra geral.
--
-- Rode APÓS 008_ofm_reference_tables.sql.
-- =============================================

-- =======  UP  ========

CREATE TABLE IF NOT EXISTS rubbercity_customer_override (
  id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_name      TEXT NOT NULL,                  -- ex.: 'AMBEV', 'AVANCO', 'PRINTGRAF', 'BRASMETAL'
  customer_aliases   TEXT[],                         -- ex.: ARRAY['AVANÇO','AVANCO']
  -- match: o que vem do pedido
  requested_family   TEXT,                           -- ex.: 'PU' (NULL = qualquer)
  requested_band     TEXT,                           -- ex.: '45/50' (NULL = qualquer)
  requested_color    TEXT,                           -- ex.: 'VD' (NULL = qualquer)
  product_pattern    TEXT,                           -- regex p/ casar com descrição do rolo (ex.: 'CAMISA.*')
  -- ação: o que aplicar
  override_components JSONB NOT NULL,                -- ver exemplo abaixo
  notes              TEXT,
  active             BOOLEAN NOT NULL DEFAULT TRUE,
  created_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at         TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Exemplo de override_components (em JSONB):
-- [
--   {"family":"FLEX_AT","band":"60/65","color":"PT","fraction":0.5},
--   {"family":"NAT",    "band":"55/60","color":"PT","fraction":0.5}
-- ]

CREATE INDEX IF NOT EXISTS idx_rbct_override_customer ON rubbercity_customer_override(customer_name);
CREATE INDEX IF NOT EXISTS idx_rbct_override_family   ON rubbercity_customer_override(requested_family);

ALTER TABLE rubbercity_customer_override ENABLE ROW LEVEL SECURITY;

DO $$ BEGIN
  CREATE POLICY rbct_override_select ON rubbercity_customer_override
    FOR SELECT TO authenticated USING (rubbercity_is_member());
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

GRANT SELECT ON rubbercity_customer_override TO authenticated, service_role;

-- Trigger updated_at (reusa função criada em 004)
DROP TRIGGER IF EXISTS trg_rbct_override_updated_at ON rubbercity_customer_override;
CREATE TRIGGER trg_rbct_override_updated_at
  BEFORE UPDATE ON rubbercity_customer_override
  FOR EACH ROW EXECUTE FUNCTION rubbercity_set_updated_at();

NOTIFY pgrst, 'reload schema';

-- =======  DOWN  ========
-- DROP TRIGGER IF EXISTS trg_rbct_override_updated_at ON rubbercity_customer_override;
-- DROP TABLE   IF EXISTS rubbercity_customer_override CASCADE;
-- NOTIFY pgrst, 'reload schema';
