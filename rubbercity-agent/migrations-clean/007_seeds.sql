-- =============================================
-- Rubbercity (clean) — 007: Seeds (categoria IT + admin bootstrap)
-- Consolida: 011 + 015 do conjunto original.
--
-- - Seed da categoria IT — Instrução de Trabalho (idempotente)
-- - Cria/atualiza o usuário admin@rubbercity.com.br (senha @Admin123)
--     * senha NÃO é sobrescrita em re-execuções (preserva rotações em prod)
--     * em re-execução só garante role/company_name = admin/rubbercity
-- ALERTA: troque a senha logo após o primeiro login.
-- Rode APÓS 006_chat_messages.sql
-- =============================================

-- =======  UP  ========

-- ---------- categorias base ----------
INSERT INTO rubbercity_document_categories(code, name, description) VALUES
  ('OFM',         'Ordem de Fabricação de Massa', 'Descritivo, procedimentos e regras de negócio do setor de OFM.'),
  ('IT',          'Instrução de Trabalho',       'Procedimentos operacionais padronizados.'),
  ('PROCESSO',    'Mapeamento de Processos',     'Setores da produção: limpeza, jato, ENDs, usinagem, balanceamento, vulcanização, retífica.'),
  ('FORMULACAO',  'Formulações',                 'Composições químicas das massas (sem expor segredo industrial).'),
  ('CLIENTE',     'Especificações de Cliente',   'Regras especiais por cliente (ex.: AMBEV, AVANÇO, PRINTGRAF, BRASMETAL).')
ON CONFLICT (code) DO UPDATE
   SET name        = EXCLUDED.name,
       description = EXCLUDED.description,
       updated_at  = NOW();

-- ---------- admin bootstrap ----------
DO $$
DECLARE
  v_email     TEXT := 'admin@rubbercity.com.br';
  v_password  TEXT := '@Admin123';
  v_user_id   UUID;
  v_meta      JSONB := '{"role":"admin","company_name":"rubbercity","full_name":"Administrador Rubbercity"}'::jsonb;
BEGIN
  SELECT id INTO v_user_id
    FROM auth.users
   WHERE email = v_email
   LIMIT 1;

  IF v_user_id IS NULL THEN
    v_user_id := gen_random_uuid();

    INSERT INTO auth.users (
      instance_id, id, aud, role, email, encrypted_password,
      email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
      created_at, updated_at,
      confirmation_token, email_change, email_change_token_new, recovery_token
    ) VALUES (
      '00000000-0000-0000-0000-000000000000',
      v_user_id,
      'authenticated',
      'authenticated',
      v_email,
      crypt(v_password, gen_salt('bf')),
      NOW(),
      jsonb_build_object('provider','email','providers',ARRAY['email']),
      v_meta,
      NOW(), NOW(),
      '', '', '', ''
    );

    INSERT INTO auth.identities (
      id, user_id, provider_id, identity_data, provider,
      last_sign_in_at, created_at, updated_at
    ) VALUES (
      gen_random_uuid(),
      v_user_id,
      v_user_id::text,
      jsonb_build_object('sub', v_user_id::text, 'email', v_email, 'email_verified', true),
      'email',
      NOW(), NOW(), NOW()
    );

    RAISE NOTICE 'Rubbercity bootstrap admin criado: %', v_email;
  ELSE
    UPDATE auth.users
       SET raw_user_meta_data = COALESCE(raw_user_meta_data, '{}'::jsonb) || v_meta,
           updated_at         = NOW()
     WHERE id = v_user_id;

    RAISE NOTICE 'Rubbercity bootstrap admin já existe, metadata atualizada: %', v_email;
  END IF;
END
$$;

NOTIFY pgrst, 'reload schema';

-- =======  DOWN  ========
-- DELETE FROM auth.identities
--  WHERE user_id IN (SELECT id FROM auth.users WHERE email = 'admin@rubbercity.com.br');
-- DELETE FROM auth.users
--  WHERE email = 'admin@rubbercity.com.br';
-- DELETE FROM rubbercity_document_categories WHERE code = 'IT';
-- NOTIFY pgrst, 'reload schema';
