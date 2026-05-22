-- =============================================
-- Rubbercity — 010: RPCs de consulta de regras OFM
--
-- Funções "puras" (STABLE) que o agente n8n invoca para tomar decisão sobre
-- cada pedido. Nenhuma delas escreve nada — apenas devolve, em JSONB, o
-- raciocínio aplicado, para o agente formar a OFM final.
--
-- Funções:
--   * rubbercity_ofm_durometer_band(alias_text)
--       Dado '23/27' (texto vindo do pedido), devolve a faixa oficial
--       (ex.: '20/25') e os limites.
--   * rubbercity_ofm_safety_margin(family_code, band_code, parede_mm)
--       Quanto a mais (em %) deve ser empregado no rolo. Por enquanto retorna
--       uma curva default; pode ser alimentado por tabela depois.
--   * rubbercity_ofm_can_substitute(source_family, target_family, band)
--       Diz se massa source pode entrar no lugar da target naquela banda.
--   * rubbercity_ofm_can_mix_colors(source_color, target_color)
--       Cumpre regras de cor (branca x vermelha, preta só em preta...).
--   * rubbercity_ofm_resolve_customer(customer, family, band, color, product_desc)
--       Devolve o JSONB de override do cliente, se houver.
--   * rubbercity_ofm_status_decision(row_jsonb)
--       Dado um row do producaodb.producao, devolve {action, reason}
--       (ACCEPT/IGNORE/WAIT) conforme rubbercity_status_workflow.
--   * rubbercity_ofm_recipe(recipe_code, total_kg)
--       Decompõe um total em quilos pelas frações da receita.
--
-- Rode APÓS 009_ofm_customer_overrides.sql.
-- =============================================

-- =======  UP  ========

-- ---------- 1) faixa oficial a partir de um alias ----------
CREATE OR REPLACE FUNCTION rubbercity_ofm_durometer_band(p_alias TEXT)
RETURNS TABLE(band_code TEXT, band_min INT, band_max INT)
LANGUAGE sql STABLE
SET search_path = public
AS $$
  SELECT b.band_code, b.band_min, b.band_max
    FROM rubbercity_durometer_alias a
    JOIN rubbercity_durometer_band b ON b.id = a.band_id
   WHERE a.alias_text = TRIM(p_alias)
   LIMIT 1;
$$;

-- ---------- 2) margem de segurança ----------
-- Default simples enquanto não houver tabela específica:
--   parede <= 5 mm  → 8%
--   parede <= 10 mm → 6%
--   parede >  10 mm → 5%
-- Massas de dureza >= 60 SHA recebem +1%.
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
  v_margin NUMERIC := 0.06;
  v_top    INT;
BEGIN
  IF p_parede_mm IS NULL THEN
    v_margin := 0.06;
  ELSIF p_parede_mm <= 5 THEN
    v_margin := 0.08;
  ELSIF p_parede_mm <= 10 THEN
    v_margin := 0.06;
  ELSE
    v_margin := 0.05;
  END IF;

  SELECT band_max INTO v_top
    FROM rubbercity_durometer_band
   WHERE band_code = p_band_code;

  IF v_top IS NOT NULL AND v_top >= 60 THEN
    v_margin := v_margin + 0.01;
  END IF;

  RETURN v_margin;
END;
$$;

-- ---------- 3) substituição de massa ----------
CREATE OR REPLACE FUNCTION rubbercity_ofm_can_substitute(
  p_source_family TEXT,
  p_target_family TEXT,
  p_band_code     TEXT
)
RETURNS BOOLEAN
LANGUAGE plpgsql STABLE
SET search_path = public
AS $$
DECLARE
  v_eq RECORD;
  v_target_max_band INT;
  v_req_max         INT;
BEGIN
  SELECT eq.*, b.band_max AS eq_max_max
    INTO v_eq
    FROM rubbercity_material_equivalence eq
    JOIN rubbercity_material_family sf ON sf.id = eq.source_family_id
    JOIN rubbercity_material_family tf ON tf.id = eq.target_family_id
    LEFT JOIN rubbercity_durometer_band b ON b.id = eq.max_band_id
   WHERE sf.code = UPPER(TRIM(p_source_family))
     AND tf.code = UPPER(TRIM(p_target_family))
   LIMIT 1;

  IF NOT FOUND THEN
    RETURN FALSE;
  END IF;

  IF v_eq.max_band_id IS NULL THEN
    RETURN TRUE;
  END IF;

  SELECT band_max INTO v_req_max FROM rubbercity_durometer_band WHERE band_code = p_band_code;
  RETURN COALESCE(v_req_max <= v_eq.eq_max_max, FALSE);
END;
$$;

-- ---------- 4) mix de cor ----------
CREATE OR REPLACE FUNCTION rubbercity_ofm_can_mix_colors(
  p_source_color TEXT,
  p_target_color TEXT
)
RETURNS BOOLEAN
LANGUAGE sql STABLE
SET search_path = public
AS $$
  SELECT COALESCE(
    (SELECT is_allowed
       FROM rubbercity_color_mix_rule
      WHERE LOWER(source_color) = LOWER(TRIM(p_source_color))
        AND LOWER(target_color) = LOWER(TRIM(p_target_color))
      LIMIT 1),
    /* default: mesma cor sempre permite, diferente nega */
    (LOWER(TRIM(p_source_color)) = LOWER(TRIM(p_target_color)))
  );
$$;

-- ---------- 5) override por cliente ----------
CREATE OR REPLACE FUNCTION rubbercity_ofm_resolve_customer(
  p_customer     TEXT,
  p_family       TEXT,
  p_band         TEXT,
  p_color        TEXT,
  p_product_desc TEXT DEFAULT NULL
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
           'components', o.override_components,
           'notes',      o.notes
         )
    INTO v_result
    FROM rubbercity_customer_override o
   WHERE o.active
     AND (
           UPPER(o.customer_name) = UPPER(TRIM(p_customer))
        OR UPPER(TRIM(p_customer)) = ANY (SELECT UPPER(x) FROM unnest(COALESCE(o.customer_aliases, '{}')) x)
     )
     AND (o.requested_family IS NULL OR UPPER(o.requested_family) = UPPER(TRIM(p_family)))
     AND (o.requested_band   IS NULL OR o.requested_band = TRIM(p_band))
     AND (o.requested_color  IS NULL OR UPPER(o.requested_color)  = UPPER(TRIM(p_color)))
     AND (o.product_pattern  IS NULL OR p_product_desc ~* o.product_pattern)
   ORDER BY (o.product_pattern IS NOT NULL) DESC,  -- prioriza overrides específicos
            (o.requested_family IS NOT NULL) DESC
   LIMIT 1;

  RETURN v_result;
END;
$$;

-- ---------- 6) decisão de status sobre uma row de producaodb.producao ----------
-- p_row é o JSONB do registro vindo do MySQL via n8n.
-- Aplica todas as regras de rubbercity_status_workflow em ordem de priority asc.
CREATE OR REPLACE FUNCTION rubbercity_ofm_status_decision(p_row JSONB)
RETURNS TABLE(action TEXT, rule_name TEXT, reason TEXT)
LANGUAGE plpgsql STABLE
SET search_path = public
AS $$
DECLARE
  r RECORD;
  cond_ok BOOLEAN;
  k TEXT;
  v JSONB;
BEGIN
  FOR r IN
    SELECT * FROM rubbercity_status_workflow ORDER BY priority ASC, rule_name ASC
  LOOP
    -- status match
    IF r.match_status IS NOT NULL AND array_length(r.match_status, 1) > 0 THEN
      IF NOT (UPPER(COALESCE(p_row->>'status','')) = ANY (SELECT UPPER(s) FROM unnest(r.match_status) s)) THEN
        CONTINUE;
      END IF;
    END IF;

    -- conditions: cada chave deve bater (valor textual ou NULL=ausente)
    cond_ok := TRUE;
    IF r.conditions IS NOT NULL THEN
      FOR k, v IN SELECT key, value FROM jsonb_each(r.conditions) LOOP
        IF jsonb_typeof(v) = 'null' THEN
          IF p_row ? k AND COALESCE(p_row->>k,'') <> '' THEN
            cond_ok := FALSE; EXIT;
          END IF;
        ELSE
          IF COALESCE(p_row->>k,'') <> COALESCE(v#>>'{}','') THEN
            cond_ok := FALSE; EXIT;
          END IF;
        END IF;
      END LOOP;
    END IF;

    IF cond_ok THEN
      action     := r.action;
      rule_name  := r.rule_name;
      reason     := r.notes;
      RETURN NEXT;
      RETURN;
    END IF;
  END LOOP;

  -- default: IGNORE (não casou com nenhuma regra → segurança)
  action    := 'IGNORE';
  rule_name := '__default__';
  reason    := 'Nenhuma regra correspondente em rubbercity_status_workflow.';
  RETURN NEXT;
END;
$$;

-- ---------- 7) decomposição de receita ----------
CREATE OR REPLACE FUNCTION rubbercity_ofm_recipe(p_recipe_code TEXT, p_total_kg NUMERIC)
RETURNS JSONB
LANGUAGE plpgsql STABLE
SET search_path = public
AS $$
DECLARE
  v_components JSONB;
  v_result     JSONB;
BEGIN
  SELECT components INTO v_components
    FROM rubbercity_product_recipe
   WHERE recipe_code = UPPER(TRIM(p_recipe_code))
   LIMIT 1;

  IF v_components IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT jsonb_agg(
           c || jsonb_build_object('kg', ROUND(((c->>'fraction')::NUMERIC) * p_total_kg, 3))
         )
    INTO v_result
    FROM jsonb_array_elements(v_components) c;

  RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION rubbercity_ofm_durometer_band(TEXT)                                       TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION rubbercity_ofm_safety_margin(TEXT, TEXT, NUMERIC)                         TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION rubbercity_ofm_can_substitute(TEXT, TEXT, TEXT)                           TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION rubbercity_ofm_can_mix_colors(TEXT, TEXT)                                 TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION rubbercity_ofm_resolve_customer(TEXT, TEXT, TEXT, TEXT, TEXT)             TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION rubbercity_ofm_status_decision(JSONB)                                     TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION rubbercity_ofm_recipe(TEXT, NUMERIC)                                      TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

-- =======  DOWN  ========
-- DROP FUNCTION IF EXISTS rubbercity_ofm_recipe(TEXT, NUMERIC);
-- DROP FUNCTION IF EXISTS rubbercity_ofm_status_decision(JSONB);
-- DROP FUNCTION IF EXISTS rubbercity_ofm_resolve_customer(TEXT, TEXT, TEXT, TEXT, TEXT);
-- DROP FUNCTION IF EXISTS rubbercity_ofm_can_mix_colors(TEXT, TEXT);
-- DROP FUNCTION IF EXISTS rubbercity_ofm_can_substitute(TEXT, TEXT, TEXT);
-- DROP FUNCTION IF EXISTS rubbercity_ofm_safety_margin(TEXT, TEXT, NUMERIC);
-- DROP FUNCTION IF EXISTS rubbercity_ofm_durometer_band(TEXT);
-- NOTIFY pgrst, 'reload schema';
