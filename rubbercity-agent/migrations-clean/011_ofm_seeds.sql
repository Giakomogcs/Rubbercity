-- =============================================
-- Rubbercity — 011: Seeds OFM (extraídos do "DESCRITIVO OFM" e do "BD-RUBBERCITY")
--
-- Idempotente: todas as inserções usam ON CONFLICT.
--
-- Rode APÓS 010_ofm_rules_rpc.sql.
-- =============================================

-- =======  UP  ========

-- ---------- A) faixas de dureza oficiais ----------
INSERT INTO rubbercity_durometer_band(band_code, band_min, band_max) VALUES
  ('20/25', 20, 25),
  ('25/28', 25, 28),
  ('30/33', 30, 33),
  ('35/40', 35, 40)
ON CONFLICT (band_code) DO NOTHING;

-- ---------- B) aliases de dureza (durezas reais que caem em cada faixa) ----------
-- 20/25: 17/23, 20/23, 20/25, 22/25, 23/27, 24/26, 25
WITH b AS (SELECT id FROM rubbercity_durometer_band WHERE band_code = '20/25')
INSERT INTO rubbercity_durometer_alias(band_id, alias_text, alias_min, alias_max)
SELECT b.id, x.alias, x.amin, x.amax FROM b,
  (VALUES
    ('17/23',17,23),('20/23',20,23),('20/25',20,25),
    ('22/25',22,25),('23/27',23,27),('24/26',24,26),('25',25,25)
  ) AS x(alias, amin, amax)
ON CONFLICT (band_id, alias_text) DO NOTHING;

-- 25/28: 25/28, 25/30, 27/30, 27/33, 27, 28, 28/32
WITH b AS (SELECT id FROM rubbercity_durometer_band WHERE band_code = '25/28')
INSERT INTO rubbercity_durometer_alias(band_id, alias_text, alias_min, alias_max)
SELECT b.id, x.alias, x.amin, x.amax FROM b,
  (VALUES
    ('25/28',25,28),('25/30',25,30),('27/30',27,30),('27/33',27,33),
    ('27',27,27),('28',28,28),('28/32',28,32)
  ) AS x(alias, amin, amax)
ON CONFLICT (band_id, alias_text) DO NOTHING;

-- 30/33: 30, 30/33, 30/35, 32, 32/38, 33/35, 33/37, 33/38
WITH b AS (SELECT id FROM rubbercity_durometer_band WHERE band_code = '30/33')
INSERT INTO rubbercity_durometer_alias(band_id, alias_text, alias_min, alias_max)
SELECT b.id, x.alias, x.amin, x.amax FROM b,
  (VALUES
    ('30',30,30),('30/33',30,33),('30/35',30,35),('32',32,32),
    ('32/38',32,38),('33/35',33,35),('33/37',33,37),('33/38',33,38)
  ) AS x(alias, amin, amax)
ON CONFLICT (band_id, alias_text) DO NOTHING;

-- 35/40: 35/40, 35/38, 37/40, 37/43, 38, 40
WITH b AS (SELECT id FROM rubbercity_durometer_band WHERE band_code = '35/40')
INSERT INTO rubbercity_durometer_alias(band_id, alias_text, alias_min, alias_max)
SELECT b.id, x.alias, x.amin, x.amax FROM b,
  (VALUES
    ('35/40',35,40),('35/38',35,38),('37/40',37,40),
    ('37/43',37,43),('38',38,38),('40',40,40)
  ) AS x(alias, amin, amax)
ON CONFLICT (band_id, alias_text) DO NOTHING;

-- ---------- C) famílias de massa ----------
INSERT INTO rubbercity_material_family(code, name, is_pu_liquido, notes) VALUES
  ('AG',              'AG',                          FALSE, 'Massa de baixa dureza, substituta universal até 35/40.'),
  ('ABI',             'ABI',                         FALSE, NULL),
  ('ABI_CARBOX',      'ABI CARBOX',                  FALSE, NULL),
  ('EPP',             'EPP',                         FALSE, NULL),
  ('EPPLUS',          'EPPLUS',                      FALSE, NULL),
  ('EPDM',            'EPDM',                        FALSE, NULL),
  ('RC_2000',         'RC 2000',                     FALSE, NULL),
  ('RC_AD_503',       'RC AD 503',                   FALSE, NULL),
  ('RC_ULTRA',        'RC ULTRA',                    FALSE, NULL),
  ('RC_ULTRA_CARBOX', 'RC ULTRA CARBOX',             FALSE, NULL),
  ('FLEX',            'FLEX',                        FALSE, NULL),
  ('FLEX_ROT',        'FLEX ROT',                    FALSE, NULL),
  ('FLEX_AT',         'FLEX AT',                     FALSE, NULL),
  ('PU_SOLIDO',       'PU Sólido',                   FALSE, NULL),
  ('PU_LIQUIDO',      'PU Líquido',                  TRUE,  'Linha puliq=1 em producaodb.producao.'),
  ('NEOPRENE',        'Neoprene',                    FALSE, NULL),
  ('HYPALON',         'Hypalon',                     FALSE, NULL),
  ('EBONITE',         'Ebonite',                     FALSE, 'Usada em base de rolos de pressão.'),
  ('NAT',             'Borracha Natural',            FALSE, NULL),
  ('SB_NAT',          'SB NAT',                      FALSE, NULL)
ON CONFLICT (code) DO NOTHING;

-- ---------- D) equivalências (AG substitui ABI/EPP/RC até 35/40) ----------
WITH ag AS (SELECT id FROM rubbercity_material_family WHERE code = 'AG'),
     band AS (SELECT id FROM rubbercity_durometer_band WHERE band_code = '35/40'),
     targets(code) AS (VALUES
        ('ABI'),('ABI_CARBOX'),('EPP'),('EPPLUS'),('EPDM'),
        ('RC_2000'),('RC_AD_503'),('RC_ULTRA'),('RC_ULTRA_CARBOX')
     )
INSERT INTO rubbercity_material_equivalence(source_family_id, target_family_id, max_band_id, is_complement, notes)
SELECT ag.id, tf.id, band.id, FALSE,
       'AG substitui ' || t.code || ' até dureza 35/40 (PDF descritivo).'
  FROM ag, band, targets t
  JOIN rubbercity_material_family tf ON tf.code = t.code
ON CONFLICT (source_family_id, target_family_id) DO NOTHING;

-- Complementos permitidos em ABI: FLEX, FLEX_ROT, PU_SOLIDO
WITH abi AS (SELECT id FROM rubbercity_material_family WHERE code = 'ABI'),
     sources(code) AS (VALUES ('FLEX'),('FLEX_ROT'),('PU_SOLIDO'))
INSERT INTO rubbercity_material_equivalence(source_family_id, target_family_id, max_band_id, is_complement, notes)
SELECT sf.id, abi.id, NULL, TRUE,
       s.code || ' pode ser usada para completar lote em pedidos de ABI.'
  FROM abi, sources s
  JOIN rubbercity_material_family sf ON sf.code = s.code
ON CONFLICT (source_family_id, target_family_id) DO NOTHING;

-- ---------- E) regras de mix de cor ----------
INSERT INTO rubbercity_color_mix_rule(source_color, target_color, is_allowed, notes) VALUES
  ('branca',   'vermelha', FALSE, 'PDF: branca NÃO pode ser usada em lote mix com vermelha.'),
  ('vermelha', 'branca',   FALSE, 'PDF: vermelha NÃO pode entrar em mix com branca.'),
  ('preta',    'preta',    TRUE,  'PDF: preta só pode ser usada em mix para preta.'),
  ('preta',    'branca',   FALSE, NULL),
  ('preta',    'verde',    FALSE, NULL),
  ('preta',    'cinza',    FALSE, NULL),
  ('preta',    'vermelha', FALSE, NULL),
  ('vermelha', 'vermelha', TRUE,  'PDF: vermelha só pode ser usada no mix vermelho.'),
  ('verde',    'verde',    TRUE,  NULL),
  ('verde',    'preta',    TRUE,  'PDF: verde pode entrar em mix para preta.'),
  ('cinza',    'cinza',    TRUE,  NULL),
  ('cinza',    'preta',    TRUE,  'PDF: cinza pode entrar em mix para preta.'),
  ('branca',   'branca',   TRUE,  NULL)
ON CONFLICT (source_color, target_color) DO NOTHING;

-- ---------- F) estoque mínimo desejado ----------
-- AG 20/25, 25/28, 30/33 PT → 90 kg; AG 35/40 PT → 30 kg. Demais → 0 (linhas opcionais).
WITH ag AS (SELECT id FROM rubbercity_material_family WHERE code = 'AG')
INSERT INTO rubbercity_min_stock(family_id, band_id, color, min_kg, notes)
SELECT ag.id, b.id, 'PT', m.kg, 'PDF: massa AG '||b.band_code||' PT muito usada, manter sobra.'
  FROM ag,
       rubbercity_durometer_band b
       JOIN (VALUES
         ('20/25', 90),
         ('25/28', 90),
         ('30/33', 90),
         ('35/40', 30)
       ) AS m(band_code, kg) ON m.band_code = b.band_code
ON CONFLICT (family_id, band_id, color) DO NOTHING;

-- ---------- G) receitas de produto especial ----------
INSERT INTO rubbercity_product_recipe(recipe_code, description, components) VALUES
  ('ROLL_BOW',
   'Camisas ROLL BOW: base ABI 70/75 PT corresponde a metade do peso total da camisa; o restante é a massa final solicitada.',
   '[
      {"family":"ABI","band":"70/75","color":"PT","fraction":0.50,"role":"base"},
      {"family":"REQUESTED","fraction":0.50,"role":"top"}
    ]'::jsonb),
  ('HYPALON',
   'Revestimento HYPALON: 2/3 neoprene + 1/3 hypalon.',
   '[
      {"family":"NEOPRENE","fraction":0.6667},
      {"family":"HYPALON", "fraction":0.3333}
    ]'::jsonb),
  ('EBONITE_BASE',
   'Rolos de pressão recebem base de ebonite; a parte restante é a massa solicitada.',
   '[
      {"family":"EBONITE","fraction":0.50,"role":"base"},
      {"family":"REQUESTED","fraction":0.50,"role":"top"}
    ]'::jsonb),
  ('DUPLA_CAMADA',
   'Rolo em dupla camada: receita varia conforme pedido; componentes resolvidos pelo agente a partir dos campos do producaodb.producao.',
   '[]'::jsonb),
  ('FLAMENGUISTA',
   'Rolo flamenguista: massas e cores diferentes na mesma camisa, dependentes do desenho do pedido.',
   '[]'::jsonb)
ON CONFLICT (recipe_code) DO NOTHING;

-- ---------- H) workflow de status (producaodb.producao) ----------
-- Regras vindas do "BD-RUBBERCITY".
INSERT INTO rubbercity_status_workflow(rule_name, action, match_status, conditions, priority, notes) VALUES
  ('queima_pendente',         'IGNORE', NULL,                                '{"queima":"S"}'::jsonb,                                                 10, 'Peça em vulcanização (queima_S). Ignorar até queima=N.'),
  ('usinagem_pendente',       'IGNORE', NULL,                                '{"usinagem":"SIM","usinafinal":null}'::jsonb,                            20, 'Usinagem ainda não finalizada (usinafinal vazio).'),
  ('usiter_pendente',         'IGNORE', NULL,                                '{"usiter":"S","usi_stat":null}'::jsonb,                                  21, 'Usinagem terceirizada pendente (usi_stat vazio/R/X).'),
  ('balanceamento_pendente',  'IGNORE', NULL,                                '{"bl":"S","bl_desba":"N","blpr":null}'::jsonb,                           30, 'Balanceamento ainda não retornou.'),
  ('balanceamento_finalizado','ACCEPT', '{JATO}',                            '{"bl":"S","bl_desba":"S","blpr":"S"}'::jsonb,                            40, 'Voltou do balanceamento limpa e segue para JATO → pode aceitar.'),
  ('balanceamento_bl_n',      'ACCEPT', '{LIMPEZA,LIMPEZAI}',                '{"bl":"N"}'::jsonb,                                                      45, 'Sem balanceamento → aceita normalmente em LIMPEZA/LIMPEZAI.'),
  ('balanceamento_blfim_F',   'ACCEPT', NULL,                                '{"blfim":"F"}'::jsonb,                                                   46, 'Balanceamento finalizado (blfim=F).'),
  ('usinagem_ok',             'ACCEPT', '{JATO,LIMPEZA,LIMPEZAI}',           '{"usinagem":"SIM","usinafinal":"F"}'::jsonb,                             50, 'Usinagem terminada (usinafinal=F).'),
  ('usiter_ok',               'ACCEPT', '{JATO,LIMPEZA,LIMPEZAI}',           '{"usiter":"S","usi_stat":"F"}'::jsonb,                                   51, 'Usinagem terceirizada terminada.'),
  ('ends_pendente',           'IGNORE', '{ENDS}',                            NULL,                                                                     60, 'Peça em ENDs/ultrassom. Quando voltar irá para JATO.'),
  ('retifica_only',           'IGNORE', NULL,                                '{"mat":"RETIFICA"}'::jsonb,                                              70, 'Pedido só de retífica não gera OFM.'),
  ('default_limpeza',         'ACCEPT', '{LIMPEZA,LIMPEZAI}',                NULL,                                                                    900, 'Default: peças prontas em limpeza geram OFM.'),
  ('default_jato',            'ACCEPT', '{JATO}',                            NULL,                                                                    901, 'Default: peças em JATO já passaram pelas pendências.')
ON CONFLICT (rule_name) DO UPDATE
   SET action       = EXCLUDED.action,
       match_status = EXCLUDED.match_status,
       conditions   = EXCLUDED.conditions,
       priority     = EXCLUDED.priority,
       notes        = EXCLUDED.notes;

-- ---------- I) overrides por cliente (PDF descritivo OFM, p. 3) ----------
INSERT INTO rubbercity_customer_override
  (customer_name, customer_aliases, requested_family, requested_band, requested_color, product_pattern, override_components, notes)
VALUES
  ('AMBEV', NULL, 'PU', '45/50', 'VD', NULL,
   '[{"family":"PU_LIQUIDO","band":"50/55","color":"VD","fraction":1.0}]'::jsonb,
   'AMBEV: PU 45/50 VD vira PU 50/55 VD AMBEV.'),
  ('AVANCO', ARRAY['AVANÇO','AVANCO','Avanço','Avanco'], 'ABI', '70/75', 'PT', NULL,
   '[{"family":"ABI","band":"75/80","color":"PT","fraction":1.0}]'::jsonb,
   'AVANÇO: pedido ABI 70/75 PT vira ABI 75/80 PT.'),
  ('PRINTGRAF', NULL, NULL, NULL, NULL, 'CAMISA',
   '[{"family":"FLEX","band":"REQUESTED","color":"REQUESTED","fraction":1.0}]'::jsonb,
   'PRINTGRAF: camisas usam FLEX de cor e dureza correspondentes ao pedido.'),
  ('BRASMETAL', NULL, 'SB_NAT', '55/60', 'PT', NULL,
   '[{"family":"FLEX_AT","band":"60/65","color":"PT","fraction":0.50},
     {"family":"NAT",    "band":"55/60","color":"PT","fraction":0.50}]'::jsonb,
   'BRASMETAL: SB NAT 55/60 PT = 50% FLEX AT 60/65 PT + 50% NAT 55/60 PT.')
ON CONFLICT DO NOTHING;

NOTIFY pgrst, 'reload schema';

-- =======  DOWN  ========
-- DELETE FROM rubbercity_customer_override;
-- DELETE FROM rubbercity_status_workflow;
-- DELETE FROM rubbercity_product_recipe;
-- DELETE FROM rubbercity_min_stock;
-- DELETE FROM rubbercity_color_mix_rule;
-- DELETE FROM rubbercity_material_equivalence;
-- DELETE FROM rubbercity_material_family;
-- DELETE FROM rubbercity_durometer_alias;
-- DELETE FROM rubbercity_durometer_band;
-- NOTIFY pgrst, 'reload schema';
