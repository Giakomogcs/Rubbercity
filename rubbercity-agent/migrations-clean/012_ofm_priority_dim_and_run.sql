-- =============================================
-- Rubbercity — 012: prioridade, dimensão de cliente, auditoria de OFM
--
-- Implementa o que foi acordado com o Alex e o Marcelo após inspeção real
-- do MySQL (producaodb.producao + quimicadb.matprima):
--
--   * Adiciona famílias de massa que aparecem no ERP e ainda não estavam em
--     rubbercity_material_family (SILICONE, RUBBERTON, RC PAE, RC CSN,
--     RC CARBOX-X, RC CARBOX F, HYPALON P, EBONITE S, PU SOLIDO F,
--     PU LIQ RC NAC, RC CARBOX ROLLBOW, RC RB).
--
--   * Cria rubbercity_customer_dim (idcli → nome curto). Como não existe
--     tabela de clientes em producaodb (verificado via SHOW TABLES LIKE
--     '%cli%' → vazio), o cadastro é manual aqui no Supabase. O agente e o
--     painel fazem LEFT JOIN para mostrar nome amigável quando existir.
--
--   * Adiciona `customer_idcli VARCHAR(6)` em rubbercity_customer_override
--     para permitir match exato por código do ERP (mais estável que parsing
--     do nome dentro de `pedido`).
--
--   * Cria RPC `rubbercity_ofm_priority_band(dias_sla, tem_urgente,
--     tem_retorno_bal)` que classifica um grupo em URGENTE / ATRASADO /
--     RETORNO_BAL / SLA_3D / SLA_7D / NORMAL / SEM_SLA. Usada tanto pelo
--     painel (badge) quanto pelo agente (ordenação).
--
--   * Cria `rubbercity_ofm_run` para auditoria das OFMs propostas pelo
--     agente / painel. Inicialmente o painel apenas grava o status
--     PROPOSTA ao marcar uma linha como "emitida" (futuro).
--
-- Rode APÓS 011_ofm_seeds.sql.
-- =============================================

-- =======  UP  ========

-- ---------- A) famílias de massa que faltavam (vistas no ERP em 2026-05) ----------
INSERT INTO rubbercity_material_family(code, name, is_pu_liquido, notes) VALUES
  ('SILICONE',          'Silicone',                    FALSE, 'Vários colors (BC, VM, PT, INCOLOR). Famílias G/INJEX/CONDUTEX/ELASTOSIL etc. são variantes.'),
  ('RUBBERTON',         'Rubberton',                   FALSE, 'Massa proprietária Rubbercity.'),
  ('RC_PAE',            'RC PAE',                      FALSE, 'Linha NEO PT — usada como neoprene.'),
  ('RC_CSN',            'RC CSN',                      FALSE, 'Linha NEO PT/VM cliente CSN.'),
  ('RC_CARBOX_F',       'RC CARBOX F',                 FALSE, 'Variante F de CARBOX.'),
  ('RC_CARBOX_X',       'RC CARBOX-X',                 FALSE, 'Variante X de CARBOX.'),
  ('RC_CARBOX_ROLLBOW', 'RC CARBOX ROLLBOW',           FALSE, 'Base CARBOX usada como camada base em rolos ROLL BOW.'),
  ('RC_RB',             'RC RB',                       FALSE, 'Linha RC RB AZ.'),
  ('HYPALON_P',         'Hypalon P',                   FALSE, 'Variante P de HYPALON.'),
  ('EBONITE_S',         'Ebonite S',                   FALSE, 'Ebonite variante S — usada em acoplamento Promarine etc.'),
  ('PU_SOLIDO_F',       'PU Sólido F',                 FALSE, 'Variante F de PU sólido (TEKNO, etc.).'),
  ('PU_LIQ_RC_NAC',     'PU Líquido RC Nacional',      TRUE,  'PU líquido para revestimento, usado com puliq=1.')
ON CONFLICT (code) DO NOTHING;

-- ---------- B) dimensão de cliente (idcli → nome) ----------
CREATE TABLE IF NOT EXISTS rubbercity_customer_dim (
  idcli           VARCHAR(6) PRIMARY KEY,
  name            TEXT NOT NULL,
  is_priority     BOOLEAN NOT NULL DEFAULT FALSE,
  notes           TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE OR REPLACE FUNCTION rubbercity_customer_dim_touch()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := NOW();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS rbct_customer_dim_touch ON rubbercity_customer_dim;
CREATE TRIGGER rbct_customer_dim_touch
  BEFORE UPDATE ON rubbercity_customer_dim
  FOR EACH ROW EXECUTE FUNCTION rubbercity_customer_dim_touch();

ALTER TABLE rubbercity_customer_dim ENABLE ROW LEVEL SECURITY;
DO $$ BEGIN
  CREATE POLICY rbct_customer_dim_select ON rubbercity_customer_dim
    FOR SELECT TO authenticated USING (rubbercity_is_member());
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  CREATE POLICY rbct_customer_dim_write ON rubbercity_customer_dim
    FOR ALL TO authenticated
    USING (rubbercity_is_admin())
    WITH CHECK (rubbercity_is_admin());
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
GRANT SELECT ON rubbercity_customer_dim TO authenticated, service_role;
GRANT INSERT, UPDATE, DELETE ON rubbercity_customer_dim TO authenticated;

-- ---------- C) idcli em customer_override (match estável por código ERP) ----------
ALTER TABLE rubbercity_customer_override
  ADD COLUMN IF NOT EXISTS customer_idcli VARCHAR(6);
CREATE INDEX IF NOT EXISTS idx_customer_override_idcli
  ON rubbercity_customer_override(customer_idcli);

-- Substitui resolver: agora prioriza idcli quando fornecido.
CREATE OR REPLACE FUNCTION rubbercity_ofm_resolve_customer(
  p_customer     TEXT,
  p_family       TEXT,
  p_band         TEXT,
  p_color        TEXT,
  p_product_desc TEXT DEFAULT NULL,
  p_idcli        TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql STABLE
SET search_path = public
AS $$
DECLARE
  v_result JSONB;
BEGIN
  SELECT jsonb_build_object(
           'customer',   o.customer_name,
           'idcli',      o.customer_idcli,
           'components', o.override_components,
           'notes',      o.notes
         )
    INTO v_result
    FROM rubbercity_customer_override o
   WHERE o.active
     AND (
           (p_idcli IS NOT NULL AND TRIM(p_idcli) <> '' AND o.customer_idcli = TRIM(p_idcli))
        OR UPPER(o.customer_name) = UPPER(TRIM(COALESCE(p_customer,'')))
        OR UPPER(TRIM(COALESCE(p_customer,''))) = ANY (SELECT UPPER(x) FROM unnest(COALESCE(o.customer_aliases, '{}')) x)
     )
     AND (o.requested_family IS NULL OR UPPER(o.requested_family) = UPPER(TRIM(COALESCE(p_family,''))))
     AND (o.requested_band   IS NULL OR o.requested_band = TRIM(COALESCE(p_band,'')))
     AND (o.requested_color  IS NULL OR UPPER(o.requested_color)  = UPPER(TRIM(COALESCE(p_color,''))))
     AND (o.product_pattern  IS NULL OR (p_product_desc IS NOT NULL AND p_product_desc ~* o.product_pattern))
   ORDER BY (o.customer_idcli IS NOT NULL AND p_idcli IS NOT NULL AND o.customer_idcli = TRIM(p_idcli)) DESC,
            (o.product_pattern IS NOT NULL) DESC,
            (o.requested_family IS NOT NULL) DESC
   LIMIT 1;

  RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION rubbercity_ofm_resolve_customer(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT)
  TO authenticated, service_role;

-- ---------- D) classificação de prioridade ----------
-- Entrada: dias até a entrega (negativo = atrasado), tem_urgente (0/1),
-- tem_retorno_bal (0/1 — peça voltou do balanceamento e segue para o JATO).
--
-- Saída:
--   URGENTE     → operador marcou urgente=S no ERP.
--   ATRASADO    → SLA já estourou (dias_sla < 0).
--   RETORNO_BAL → vai pro JATO, regra do PDF.
--   SLA_3D      → vence em até 3 dias.
--   SLA_7D      → vence em até 7 dias.
--   NORMAL      → tem SLA confortável (> 7 dias).
--   SEM_SLA     → não tem prazo nem dt_entrega no ERP.
CREATE OR REPLACE FUNCTION rubbercity_ofm_priority_band(
  p_dias_sla        INT,
  p_tem_urgente     INT DEFAULT 0,
  p_tem_retorno_bal INT DEFAULT 0
)
RETURNS TEXT
LANGUAGE sql IMMUTABLE
AS $$
  SELECT CASE
    WHEN COALESCE(p_tem_urgente,0)     = 1 THEN 'URGENTE'
    WHEN p_dias_sla IS NULL                THEN
      CASE WHEN COALESCE(p_tem_retorno_bal,0)=1 THEN 'RETORNO_BAL' ELSE 'SEM_SLA' END
    WHEN p_dias_sla < 0                    THEN 'ATRASADO'
    WHEN COALESCE(p_tem_retorno_bal,0) = 1 THEN 'RETORNO_BAL'
    WHEN p_dias_sla <= 3                   THEN 'SLA_3D'
    WHEN p_dias_sla <= 7                   THEN 'SLA_7D'
    ELSE 'NORMAL'
  END;
$$;
GRANT EXECUTE ON FUNCTION rubbercity_ofm_priority_band(INT, INT, INT)
  TO authenticated, service_role;

-- ---------- E) auditoria de OFMs propostas/emitidas ----------
CREATE TABLE IF NOT EXISTS rubbercity_ofm_run (
  id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  gerado_em          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  gerado_por         UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  origem             TEXT NOT NULL CHECK (origem IN ('CHAT','PAINEL','CRON')),
  mat                TEXT,
  d                  INT,
  da                 INT,
  cor                TEXT,
  puliq              INT,
  codigo_formula     INT,
  formulacao         TEXT,
  ped_mestres        TEXT[],
  qtd_pedidos        INT,
  kt_total           NUMERIC(12,3),
  kg_ofm             NUMERIC(12,3),
  decisao            TEXT NOT NULL CHECK (decisao IN ('criar','consumir','pendente')),
  prioridade         TEXT,
  dias_sla           INT,
  status             TEXT NOT NULL DEFAULT 'PROPOSTA'
                       CHECK (status IN ('PROPOSTA','EMITIDA','DESCARTADA','SUBSTITUIDA')),
  status_em          TIMESTAMPTZ,
  status_por         UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  observacao         TEXT,
  payload_origem     JSONB
);

CREATE INDEX IF NOT EXISTS idx_ofm_run_gerado_em ON rubbercity_ofm_run(gerado_em DESC);
CREATE INDEX IF NOT EXISTS idx_ofm_run_status    ON rubbercity_ofm_run(status);
CREATE INDEX IF NOT EXISTS idx_ofm_run_mat_d_da  ON rubbercity_ofm_run(mat, d, da);

ALTER TABLE rubbercity_ofm_run ENABLE ROW LEVEL SECURITY;
DO $$ BEGIN
  CREATE POLICY rbct_ofm_run_select ON rubbercity_ofm_run
    FOR SELECT TO authenticated USING (rubbercity_is_member());
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  CREATE POLICY rbct_ofm_run_insert ON rubbercity_ofm_run
    FOR INSERT TO authenticated WITH CHECK (rubbercity_is_member());
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  CREATE POLICY rbct_ofm_run_update ON rubbercity_ofm_run
    FOR UPDATE TO authenticated
    USING (rubbercity_is_member())
    WITH CHECK (rubbercity_is_member());
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

GRANT SELECT, INSERT, UPDATE ON rubbercity_ofm_run TO authenticated, service_role;

-- ---------- F) RPC de gravação a partir do painel/chat ----------
CREATE OR REPLACE FUNCTION rubbercity_ofm_run_log(p JSONB)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id UUID;
  v_user UUID := NULLIF(p->>'gerado_por','')::UUID;
BEGIN
  IF v_user IS NULL THEN
    v_user := auth.uid();
  END IF;

  INSERT INTO rubbercity_ofm_run (
    gerado_por, origem, mat, d, da, cor, puliq,
    codigo_formula, formulacao, ped_mestres, qtd_pedidos,
    kt_total, kg_ofm, decisao, prioridade, dias_sla,
    status, observacao, payload_origem
  ) VALUES (
    v_user,
    COALESCE(p->>'origem','PAINEL'),
    p->>'mat',
    NULLIF(p->>'d','')::INT,
    NULLIF(p->>'da','')::INT,
    p->>'cor',
    NULLIF(p->>'puliq','')::INT,
    NULLIF(p->>'codigo_formula','')::INT,
    p->>'formulacao',
    CASE WHEN jsonb_typeof(p->'ped_mestres')='array'
         THEN ARRAY(SELECT jsonb_array_elements_text(p->'ped_mestres'))
         WHEN p->>'ped_mestres' IS NOT NULL
         THEN string_to_array(p->>'ped_mestres', ',')
         ELSE NULL
    END,
    NULLIF(p->>'qtd_pedidos','')::INT,
    NULLIF(p->>'kt_total','')::NUMERIC,
    NULLIF(p->>'kg_ofm','')::NUMERIC,
    COALESCE(p->>'decisao','pendente'),
    p->>'prioridade',
    NULLIF(p->>'dias_sla','')::INT,
    COALESCE(p->>'status','PROPOSTA'),
    p->>'observacao',
    p
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION rubbercity_ofm_run_log(JSONB) TO authenticated, service_role;

-- ---------- G) RPC de transição de status (Marcar como Emitida etc.) ----------
CREATE OR REPLACE FUNCTION rubbercity_ofm_run_set_status(
  p_id     UUID,
  p_status TEXT,
  p_obs    TEXT DEFAULT NULL
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF p_status NOT IN ('PROPOSTA','EMITIDA','DESCARTADA','SUBSTITUIDA') THEN
    RAISE EXCEPTION 'status inválido: %', p_status;
  END IF;

  UPDATE rubbercity_ofm_run
     SET status      = p_status,
         status_em   = NOW(),
         status_por  = auth.uid(),
         observacao  = COALESCE(p_obs, observacao)
   WHERE id = p_id;

  RETURN FOUND;
END;
$$;

GRANT EXECUTE ON FUNCTION rubbercity_ofm_run_set_status(UUID, TEXT, TEXT)
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

-- =======  DOWN  ========
-- DROP FUNCTION IF EXISTS rubbercity_ofm_run_set_status(UUID, TEXT, TEXT);
-- DROP FUNCTION IF EXISTS rubbercity_ofm_run_log(JSONB);
-- DROP TABLE IF EXISTS rubbercity_ofm_run CASCADE;
-- DROP FUNCTION IF EXISTS rubbercity_ofm_priority_band(INT, INT, INT);
-- -- ATENÇÃO: re-criar resolve_customer com a assinatura antiga se for fazer downgrade.
-- ALTER TABLE rubbercity_customer_override DROP COLUMN IF EXISTS customer_idcli;
-- DROP TRIGGER IF EXISTS rbct_customer_dim_touch ON rubbercity_customer_dim;
-- DROP FUNCTION IF EXISTS rubbercity_customer_dim_touch();
-- DROP TABLE IF EXISTS rubbercity_customer_dim CASCADE;
-- DELETE FROM rubbercity_material_family WHERE code IN (
--   'SILICONE','RUBBERTON','RC_PAE','RC_CSN','RC_CARBOX_F','RC_CARBOX_X',
--   'RC_CARBOX_ROLLBOW','RC_RB','HYPALON_P','EBONITE_S','PU_SOLIDO_F','PU_LIQ_RC_NAC'
-- );
-- NOTIFY pgrst, 'reload schema';
