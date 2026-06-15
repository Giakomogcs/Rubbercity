-- =============================================
-- Rubbercity — 014: aliases de cor + tabela de margem de segurança
--
-- Objetivo: REMOVER os dois valores "hardcoded" que ainda viviam dentro da
-- query do motor `rubbercity-mysql-ofm-decisions` (Rubbercity-MySQL-Bridge):
--
--   1. O piso de estoque AG (90 kg / 30 kg) estava escrito num CASE SQL
--      com a cor literal 'PRETA'. A fonte de verdade correta é a tabela
--      `rubbercity_min_stock` (migration 008/011), mas ela guarda a cor no
--      formato de CÓDIGO ('PT'), enquanto `producaodb.producao.cor` usa o
--      nome por extenso ('PRETA'). Sem uma ponte, ler a tabela quebraria o
--      casamento. Esta migration cria `rubbercity_color_alias` para mapear
--      códigos canônicos de cor ↔ tokens vistos no ERP.
--
--   2. A margem de segurança (7% padrão, 8% para dureza ≥ 60) estava num
--      CASE SQL fixo. Agora vira a tabela `rubbercity_safety_margin`,
--      editável pelo admin, e o RPC `rubbercity_ofm_safety_margin` passa a
--      LER essa tabela (fonte única), caindo na curva por parede só quando
--      não houver linha aplicável.
--
-- Tudo idempotente. Rode APÓS 013_family_alias.sql.
-- =============================================

-- =======  UP  ========

-- ---------- 1) aliases de cor (código canônico ↔ tokens do ERP) ----------
CREATE TABLE IF NOT EXISTS rubbercity_color_alias (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  canonical   TEXT NOT NULL,               -- código curto usado nas regras (PT, BC, VM, VD, CZ, AZ, AM, IN)
  token       TEXT NOT NULL,               -- como a cor pode aparecer em producaodb.producao.cor / matprima
  notes       TEXT,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (token)
);
CREATE INDEX IF NOT EXISTS idx_color_alias_canonical ON rubbercity_color_alias(UPPER(canonical));

INSERT INTO rubbercity_color_alias(canonical, token, notes) VALUES
  ('PT','PT',       'preta — código'),
  ('PT','PRETA',    'preta — extenso (producao)'),
  ('PT','PRETO',    'preta — variação'),
  ('PT','PRET',     'preta — abreviação'),
  ('PT','BLACK',    'preta — inglês'),
  ('BC','BC',       'branca — código'),
  ('BC','BRANCA',   'branca — extenso'),
  ('BC','BRANCO',   'branca — variação'),
  ('BC','WHITE',    'branca — inglês'),
  ('VM','VM',       'vermelha — código'),
  ('VM','VERMELHA', 'vermelha — extenso'),
  ('VM','VERMELHO', 'vermelha — variação'),
  ('VM','RED',      'vermelha — inglês'),
  ('VD','VD',       'verde — código'),
  ('VD','VERDE',    'verde — extenso'),
  ('VD','GREEN',    'verde — inglês'),
  ('CZ','CZ',       'cinza — código'),
  ('CZ','CINZA',    'cinza — extenso'),
  ('CZ','GREY',     'cinza — inglês'),
  ('CZ','GRAY',     'cinza — inglês (US)'),
  ('AZ','AZ',       'azul — código'),
  ('AZ','AZUL',     'azul — extenso'),
  ('AZ','BLUE',     'azul — inglês'),
  ('AM','AM',       'amarela — código'),
  ('AM','AMARELA',  'amarela — extenso'),
  ('AM','AMARELO',  'amarela — variação'),
  ('AM','YELLOW',   'amarela — inglês'),
  ('IN','IN',       'incolor — código'),
  ('IN','INCOLOR',  'incolor — extenso'),
  ('IN','NATURAL',  'incolor/natural'),
  ('IN','TRANSP',   'transparente')
ON CONFLICT (token) DO NOTHING;

-- Helper: devolve o código canônico de uma cor do ERP (ou a própria cor em
-- maiúsculas, se não houver alias cadastrado).
CREATE OR REPLACE FUNCTION rubbercity_color_canonical(p_color TEXT)
RETURNS TEXT
LANGUAGE sql STABLE
SET search_path = public
AS $$
  SELECT COALESCE(
    (SELECT UPPER(ca.canonical)
       FROM rubbercity_color_alias ca
      WHERE UPPER(ca.token) = UPPER(TRIM(p_color))
      LIMIT 1),
    UPPER(TRIM(p_color))
  );
$$;
GRANT EXECUTE ON FUNCTION rubbercity_color_canonical(TEXT) TO authenticated, service_role;

ALTER TABLE rubbercity_color_alias ENABLE ROW LEVEL SECURITY;
DO $$ BEGIN
  CREATE POLICY rbct_color_alias_select ON rubbercity_color_alias
    FOR SELECT TO authenticated USING (rubbercity_is_member());
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  CREATE POLICY rbct_color_alias_write ON rubbercity_color_alias
    FOR ALL TO authenticated
    USING (rubbercity_is_admin())
    WITH CHECK (rubbercity_is_admin());
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
GRANT SELECT ON rubbercity_color_alias TO authenticated, service_role;
GRANT INSERT, UPDATE, DELETE ON rubbercity_color_alias TO authenticated;

-- ---------- 2) tabela de margem de segurança ----------
-- Substitui o CASE fixo (da>=60 -> 8% senão 7%) por dados editáveis.
-- Regra de seleção: dentre as linhas cujas condições casam com o grupo
-- (família opcional + faixa de dureza opcional), vence a de maior `priority`.
-- A linha "coringa" (tudo NULL) funciona como default.
CREATE TABLE IF NOT EXISTS rubbercity_safety_margin (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  family_code  TEXT,                        -- NULL = qualquer família
  dureza_min   INT,                         -- casa quando o grupo tem da >= dureza_min (NULL = sem piso)
  dureza_max   INT,                         -- casa quando o grupo tem da <= dureza_max (NULL = sem teto)
  margin       NUMERIC(5,4) NOT NULL,       -- fração (0.07 = 7%)
  priority     INT NOT NULL DEFAULT 100,    -- maior = mais específico; default coringa usa priority baixa
  notes        TEXT,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT rbct_safety_margin_range CHECK (margin >= 0 AND margin <= 1)
);

CREATE OR REPLACE FUNCTION rubbercity_safety_margin_touch()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := NOW();
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS rbct_safety_margin_touch ON rubbercity_safety_margin;
CREATE TRIGGER rbct_safety_margin_touch
  BEFORE UPDATE ON rubbercity_safety_margin
  FOR EACH ROW EXECUTE FUNCTION rubbercity_safety_margin_touch();

-- Seed reproduz exatamente o comportamento anterior (7% padrão, 8% p/ da>=60),
-- agora editável.
INSERT INTO rubbercity_safety_margin(family_code, dureza_min, dureza_max, margin, priority, notes) VALUES
  (NULL, NULL, NULL, 0.07, 0,   'Margem de segurança padrão (7%).'),
  (NULL, 60,   NULL, 0.08, 100, 'Massas duras (dureza máx ≥ 60 SHA) recebem 8%.')
ON CONFLICT DO NOTHING;

ALTER TABLE rubbercity_safety_margin ENABLE ROW LEVEL SECURITY;
DO $$ BEGIN
  CREATE POLICY rbct_safety_margin_select ON rubbercity_safety_margin
    FOR SELECT TO authenticated USING (rubbercity_is_member());
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  CREATE POLICY rbct_safety_margin_write ON rubbercity_safety_margin
    FOR ALL TO authenticated
    USING (rubbercity_is_admin())
    WITH CHECK (rubbercity_is_admin());
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
GRANT SELECT ON rubbercity_safety_margin TO authenticated, service_role;
GRANT INSERT, UPDATE, DELETE ON rubbercity_safety_margin TO authenticated;

-- ---------- 3) RPC de margem passa a LER a tabela (fonte única) ----------
-- Mantém a assinatura antiga. Primeiro tenta casar uma linha da tabela pela
-- família + dureza máxima da faixa; se nada casar, cai na curva por parede.
CREATE OR REPLACE FUNCTION rubbercity_ofm_safety_margin(
  p_family_code TEXT,
  p_band_code   TEXT,
  p_parede_mm   NUMERIC
)
RETURNS NUMERIC
LANGUAGE plpgsql STABLE
SET search_path = public
AS $$
DECLARE
  v_top    INT;
  v_margin NUMERIC;
BEGIN
  -- dureza máxima da faixa pedida (ex.: '35/40' -> 40)
  SELECT band_max INTO v_top
    FROM rubbercity_durometer_band
   WHERE band_code = p_band_code;

  -- 1) tenta a tabela de margem (fonte de verdade)
  SELECT sm.margin INTO v_margin
    FROM rubbercity_safety_margin sm
   WHERE (sm.family_code IS NULL OR UPPER(sm.family_code) = UPPER(TRIM(COALESCE(p_family_code,''))))
     AND (sm.dureza_min  IS NULL OR (v_top IS NOT NULL AND v_top >= sm.dureza_min))
     AND (sm.dureza_max  IS NULL OR (v_top IS NOT NULL AND v_top <= sm.dureza_max))
   ORDER BY sm.priority DESC, sm.dureza_min DESC NULLS LAST
   LIMIT 1;

  IF v_margin IS NOT NULL THEN
    RETURN v_margin;
  END IF;

  -- 2) fallback: curva simples por espessura de parede
  IF p_parede_mm IS NULL THEN
    v_margin := 0.06;
  ELSIF p_parede_mm <= 5 THEN
    v_margin := 0.08;
  ELSIF p_parede_mm <= 10 THEN
    v_margin := 0.06;
  ELSE
    v_margin := 0.05;
  END IF;

  IF v_top IS NOT NULL AND v_top >= 60 THEN
    v_margin := v_margin + 0.01;
  END IF;

  RETURN v_margin;
END;
$$;
GRANT EXECUTE ON FUNCTION rubbercity_ofm_safety_margin(TEXT, TEXT, NUMERIC) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

-- =======  DOWN  ========
-- DROP FUNCTION IF EXISTS rubbercity_color_canonical(TEXT);
-- DROP TRIGGER  IF EXISTS rbct_safety_margin_touch ON rubbercity_safety_margin;
-- DROP FUNCTION IF EXISTS rubbercity_safety_margin_touch();
-- DROP TABLE    IF EXISTS rubbercity_safety_margin CASCADE;
-- DROP TABLE    IF EXISTS rubbercity_color_alias   CASCADE;
-- NOTIFY pgrst, 'reload schema';
