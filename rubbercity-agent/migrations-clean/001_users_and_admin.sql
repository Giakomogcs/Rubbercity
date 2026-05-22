-- =============================================
-- Rubbercity (clean) — 001: Users, roles, company filter and admin guards
-- Consolida: 001 + 002 + 003 + 004 + 005 + 013 do conjunto original.
--
-- - Helpers: rubbercity_is_admin(), rubbercity_is_member()
-- - CRUD de usuários via raw_user_meta_data (role + company_name='rubbercity')
-- - Guards admin-only em todas as RPCs
-- - Admin não pode excluir a si mesmo
-- - RPC rubbercity_admin_set_user_teams() para sincronizar equipes do user
-- =============================================

-- =======  UP  ========

-- ---------- helpers ----------
CREATE OR REPLACE FUNCTION rubbercity_is_admin()
RETURNS BOOLEAN
SECURITY DEFINER
SET search_path = auth, public
LANGUAGE sql
STABLE
AS $$
  SELECT COALESCE(
    (SELECT raw_user_meta_data->>'role' = 'admin'
            AND raw_user_meta_data->>'company_name' = 'rubbercity'
       FROM auth.users
      WHERE id = auth.uid()),
    false
  );
$$;

CREATE OR REPLACE FUNCTION rubbercity_is_member()
RETURNS BOOLEAN
SECURITY DEFINER
SET search_path = auth, public
LANGUAGE sql
STABLE
AS $$
  SELECT COALESCE(
    (SELECT raw_user_meta_data->>'company_name' = 'rubbercity'
       FROM auth.users
      WHERE id = auth.uid()),
    false
  );
$$;

-- ---------- list users (admin-only, filtra por company_name) ----------
DROP FUNCTION IF EXISTS rubbercity_admin_list_users();
CREATE OR REPLACE FUNCTION rubbercity_admin_list_users()
RETURNS TABLE(
  user_id      UUID,
  email        TEXT,
  full_name    TEXT,
  role         TEXT,
  company_name TEXT,
  created_at   TIMESTAMPTZ
)
SECURITY DEFINER
SET search_path = auth, public
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
  IF NOT rubbercity_is_admin() THEN
    RAISE EXCEPTION 'Acesso negado: apenas administradores.' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
    SELECT
      u.id,
      u.email::TEXT,
      COALESCE(u.raw_user_meta_data->>'full_name', '')::TEXT,
      COALESCE(u.raw_user_meta_data->>'role', 'visualizador')::TEXT,
      COALESCE(u.raw_user_meta_data->>'company_name', '')::TEXT,
      u.created_at
    FROM auth.users u
    WHERE u.raw_user_meta_data->>'company_name' = 'rubbercity'
    ORDER BY u.created_at DESC;
END;
$$;

-- ---------- confirm user (admin-only) ----------
CREATE OR REPLACE FUNCTION rubbercity_admin_confirm_user(p_user_id UUID)
RETURNS VOID
SECURITY DEFINER
SET search_path = auth, public
LANGUAGE plpgsql
AS $$
BEGIN
  IF NOT rubbercity_is_admin() THEN
    RAISE EXCEPTION 'Acesso negado: apenas administradores.' USING ERRCODE = '42501';
  END IF;
  UPDATE auth.users
     SET email_confirmed_at = NOW(),
         updated_at         = NOW()
   WHERE id = p_user_id;
END;
$$;

-- ---------- update user (admin-only, sempre carimba company_name) ----------
DROP FUNCTION IF EXISTS rubbercity_admin_update_user(UUID, TEXT, TEXT);
CREATE OR REPLACE FUNCTION rubbercity_admin_update_user(
  p_user_id   UUID,
  p_full_name TEXT,
  p_role      TEXT DEFAULT NULL
)
RETURNS VOID
SECURITY DEFINER
SET search_path = auth, public
LANGUAGE plpgsql
AS $$
DECLARE
  new_meta JSONB;
BEGIN
  IF NOT rubbercity_is_admin() THEN
    RAISE EXCEPTION 'Acesso negado: apenas administradores.' USING ERRCODE = '42501';
  END IF;
  new_meta := jsonb_build_object('full_name', p_full_name, 'company_name', 'rubbercity');
  IF p_role IS NOT NULL THEN
    new_meta := new_meta || jsonb_build_object('role', p_role);
  END IF;
  UPDATE auth.users
     SET raw_user_meta_data = COALESCE(raw_user_meta_data, '{}'::jsonb) || new_meta,
         updated_at         = NOW()
   WHERE id = p_user_id;
END;
$$;

-- ---------- delete user (admin-only, sem self-delete) ----------
CREATE OR REPLACE FUNCTION rubbercity_admin_delete_user(p_user_id UUID)
RETURNS VOID
SECURITY DEFINER
SET search_path = auth, public
LANGUAGE plpgsql
AS $$
BEGIN
  IF NOT rubbercity_is_admin() THEN
    RAISE EXCEPTION 'Acesso negado: apenas administradores.' USING ERRCODE = '42501';
  END IF;
  IF p_user_id = auth.uid() THEN
    RAISE EXCEPTION 'Você não pode excluir sua própria conta.' USING ERRCODE = '42501';
  END IF;
  DELETE FROM auth.users WHERE id = p_user_id;
END;
$$;

-- ---------- set teams of a user (admin-only) ----------
-- Obs: depende de rubbercity_team_members criada em 003_teams_and_acl.sql.
-- Criamos aqui apenas a função (sem CREATE OR REPLACE em tabela); se rodar
-- migrations em ordem, a tabela já existe quando a função for invocada.
CREATE OR REPLACE FUNCTION rubbercity_admin_set_user_teams(
  p_user_id  UUID,
  p_team_ids UUID[]
)
RETURNS VOID
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql
AS $$
BEGIN
  IF NOT rubbercity_is_admin() THEN
    RAISE EXCEPTION 'Acesso negado: apenas administradores.' USING ERRCODE = '42501';
  END IF;

  DELETE FROM rubbercity_team_members
   WHERE user_id = p_user_id
     AND (p_team_ids IS NULL OR NOT (team_id = ANY(p_team_ids)));

  IF p_team_ids IS NOT NULL THEN
    INSERT INTO rubbercity_team_members(team_id, user_id)
    SELECT unnest(p_team_ids), p_user_id
    ON CONFLICT (team_id, user_id) DO NOTHING;
  END IF;
END;
$$;

-- ---------- grants ----------
GRANT EXECUTE ON FUNCTION rubbercity_is_admin()                                  TO authenticated;
GRANT EXECUTE ON FUNCTION rubbercity_is_member()                                 TO authenticated;
GRANT EXECUTE ON FUNCTION rubbercity_admin_list_users()                          TO authenticated;
GRANT EXECUTE ON FUNCTION rubbercity_admin_confirm_user(UUID)                    TO authenticated;
GRANT EXECUTE ON FUNCTION rubbercity_admin_update_user(UUID, TEXT, TEXT)         TO authenticated;
GRANT EXECUTE ON FUNCTION rubbercity_admin_delete_user(UUID)                     TO authenticated;
REVOKE ALL    ON FUNCTION rubbercity_admin_set_user_teams(UUID, UUID[])          FROM PUBLIC;
GRANT EXECUTE ON FUNCTION rubbercity_admin_set_user_teams(UUID, UUID[])          TO authenticated;

NOTIFY pgrst, 'reload schema';

-- =======  DOWN  ========
-- DROP FUNCTION IF EXISTS rubbercity_admin_set_user_teams(UUID, UUID[]);
-- DROP FUNCTION IF EXISTS rubbercity_admin_delete_user(UUID);
-- DROP FUNCTION IF EXISTS rubbercity_admin_update_user(UUID, TEXT, TEXT);
-- DROP FUNCTION IF EXISTS rubbercity_admin_confirm_user(UUID);
-- DROP FUNCTION IF EXISTS rubbercity_admin_list_users();
-- DROP FUNCTION IF EXISTS rubbercity_is_member();
-- DROP FUNCTION IF EXISTS rubbercity_is_admin();
-- NOTIFY pgrst, 'reload schema';
