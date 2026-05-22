-- =============================================
-- Rubbercity — 013: aliases de família (producao.mat → formula.mat)
--
-- Motivo: o ERP tem `producao.mat` com nomes que NÃO batem 1:1 com
-- `quimicadb.formula.mat` (que é a tabela de fórmulas oficiais). Exemplos
-- vistos no painel hoje:
--   * producao.mat = 'ABI CARBOX'   → formula.mat = 'ABI CARBOX'   (existe, mas faixas distintas)
--   * producao.mat = 'RC AD 503'    → formula.mat = ?              (não cadastrada, fica pendente)
--   * producao.mat = 'RC ULTRA'     → formula.mat = ?              (não cadastrada)
--   * producao.mat = 'PU LIQ RC NAC'→ formula.mat = 'PU LIQ' / variante
-- Sem esse mapeamento, o painel mostra "sem fórmula oficial" e o agente
-- declara pendente.
--
-- Esta migration cria uma tabela leve no Supabase com pares
-- (producao_mat → formula_mat). O bridge passa a fazer LEFT JOIN dessa
-- tabela ANTES de buscar a fórmula em quimicadb.formula.
--
-- IMPORTANTE: o seed abaixo está vazio de propósito — apenas o Marcelo
-- Asmir ou o Alex devem cadastrar os mapeamentos reais (cada par é uma
-- decisão de negócio). Use o painel admin (ou um INSERT direto) para
-- popular conforme o ERP for sendo auditado.
--
-- Rode APÓS 012_ofm_priority_dim_and_run.sql.
-- =============================================

-- =======  UP  ========

CREATE TABLE IF NOT EXISTS rubbercity_family_alias (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  producao_mat  TEXT NOT NULL,
  formula_mat   TEXT NOT NULL,
  notes         TEXT,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (producao_mat)
);

CREATE INDEX IF NOT EXISTS idx_family_alias_producao_mat
  ON rubbercity_family_alias (UPPER(producao_mat));

CREATE OR REPLACE FUNCTION rubbercity_family_alias_touch()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := NOW();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS rbct_family_alias_touch ON rubbercity_family_alias;
CREATE TRIGGER rbct_family_alias_touch
  BEFORE UPDATE ON rubbercity_family_alias
  FOR EACH ROW EXECUTE FUNCTION rubbercity_family_alias_touch();

ALTER TABLE rubbercity_family_alias ENABLE ROW LEVEL SECURITY;

DO $$ BEGIN
  CREATE POLICY rbct_family_alias_select ON rubbercity_family_alias
    FOR SELECT TO authenticated USING (rubbercity_is_member());
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE POLICY rbct_family_alias_write ON rubbercity_family_alias
    FOR ALL TO authenticated
    USING (rubbercity_is_admin())
    WITH CHECK (rubbercity_is_admin());
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

GRANT SELECT ON rubbercity_family_alias TO authenticated, service_role;
GRANT INSERT, UPDATE, DELETE ON rubbercity_family_alias TO authenticated;

-- Helper opcional: resolve um nome de produção para um nome de fórmula.
-- Retorna o próprio input se não houver alias cadastrado.
CREATE OR REPLACE FUNCTION rubbercity_family_alias_resolve(p_mat TEXT)
RETURNS TEXT
LANGUAGE sql STABLE
SET search_path = public
AS $$
  SELECT COALESCE(
    (SELECT formula_mat
       FROM rubbercity_family_alias
      WHERE UPPER(producao_mat) = UPPER(TRIM(p_mat))
      LIMIT 1),
    p_mat
  );
$$;

GRANT EXECUTE ON FUNCTION rubbercity_family_alias_resolve(TEXT)
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

-- =======  DOWN  ========
-- DROP FUNCTION IF EXISTS rubbercity_family_alias_resolve(TEXT);
-- DROP TRIGGER  IF EXISTS rbct_family_alias_touch ON rubbercity_family_alias;
-- DROP FUNCTION IF EXISTS rubbercity_family_alias_touch();
-- DROP TABLE    IF EXISTS rubbercity_family_alias CASCADE;
-- NOTIFY pgrst, 'reload schema';
