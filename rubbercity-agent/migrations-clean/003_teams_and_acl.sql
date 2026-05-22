-- =============================================
-- Rubbercity (clean) — 003: Teams + ACL (team→categories, user→teams)
-- Equivalente à 007 original (sem mudanças semânticas).
--
-- Modelo:
--   user ∈ N teams
--   team tem acesso a N document categories
--   user vê documentos cuja category ∈ união(team.categories | team ∈ teams(user))
--   admin vê tudo
-- Rode APÓS 002_categories.sql
-- =============================================

-- =======  UP  ========

CREATE TABLE IF NOT EXISTS rubbercity_teams (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name        TEXT NOT NULL UNIQUE,
  description TEXT,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS rubbercity_team_members (
  team_id    UUID NOT NULL REFERENCES rubbercity_teams(id) ON DELETE CASCADE,
  user_id    UUID NOT NULL,
  added_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (team_id, user_id)
);
CREATE INDEX IF NOT EXISTS idx_rubbercity_tm_user ON rubbercity_team_members(user_id);

CREATE TABLE IF NOT EXISTS rubbercity_team_category_access (
  team_id     UUID NOT NULL REFERENCES rubbercity_teams(id)               ON DELETE CASCADE,
  category_id UUID NOT NULL REFERENCES rubbercity_document_categories(id) ON DELETE CASCADE,
  granted_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (team_id, category_id)
);
CREATE INDEX IF NOT EXISTS idx_rubbercity_tca_cat ON rubbercity_team_category_access(category_id);

ALTER TABLE rubbercity_teams                ENABLE ROW LEVEL SECURITY;
ALTER TABLE rubbercity_team_members         ENABLE ROW LEVEL SECURITY;
ALTER TABLE rubbercity_team_category_access ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS rubbercity_teams_select ON rubbercity_teams;
DROP POLICY IF EXISTS rubbercity_tm_select    ON rubbercity_team_members;
DROP POLICY IF EXISTS rubbercity_tca_select   ON rubbercity_team_category_access;

CREATE POLICY rubbercity_teams_select ON rubbercity_teams
  FOR SELECT TO authenticated USING (rubbercity_is_member());
CREATE POLICY rubbercity_tm_select ON rubbercity_team_members
  FOR SELECT TO authenticated USING (rubbercity_is_member());
CREATE POLICY rubbercity_tca_select ON rubbercity_team_category_access
  FOR SELECT TO authenticated USING (rubbercity_is_member());

-- ---------- helper: categorias permitidas para auth.uid() ----------
CREATE OR REPLACE FUNCTION rubbercity_user_allowed_categories()
RETURNS SETOF UUID
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
  IF rubbercity_is_admin() THEN
    RETURN QUERY SELECT id FROM rubbercity_document_categories;
    RETURN;
  END IF;
  IF NOT rubbercity_is_member() THEN
    RETURN;
  END IF;
  RETURN QUERY
    SELECT DISTINCT tca.category_id
      FROM rubbercity_team_category_access tca
      JOIN rubbercity_team_members tm ON tm.team_id = tca.team_id
     WHERE tm.user_id = auth.uid();
END;
$$;

CREATE OR REPLACE FUNCTION rubbercity_user_allowed_category_codes()
RETURNS JSONB
SECURITY DEFINER
SET search_path = public
LANGUAGE sql
STABLE
AS $$
  SELECT COALESCE(jsonb_agg(c.code ORDER BY c.code), '[]'::jsonb)
    FROM rubbercity_document_categories c
   WHERE c.id IN (SELECT rubbercity_user_allowed_categories());
$$;

-- ---------- helper: idem, porém para um user_id explícito (service_role/n8n) ----------
CREATE OR REPLACE FUNCTION rubbercity_user_allowed_categories_for(p_user_id UUID)
RETURNS SETOF UUID
SECURITY DEFINER
SET search_path = auth, public
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  is_adm BOOLEAN;
  is_mem BOOLEAN;
BEGIN
  SELECT
    (raw_user_meta_data->>'role' = 'admin'
     AND raw_user_meta_data->>'company_name' = 'rubbercity'),
    (raw_user_meta_data->>'company_name' = 'rubbercity')
  INTO is_adm, is_mem
  FROM auth.users
  WHERE id = p_user_id;

  IF COALESCE(is_adm, false) THEN
    RETURN QUERY SELECT id FROM rubbercity_document_categories;
    RETURN;
  END IF;
  IF NOT COALESCE(is_mem, false) THEN
    RETURN;
  END IF;
  RETURN QUERY
    SELECT DISTINCT tca.category_id
      FROM rubbercity_team_category_access tca
      JOIN rubbercity_team_members tm ON tm.team_id = tca.team_id
     WHERE tm.user_id = p_user_id;
END;
$$;

-- ---------- team CRUD (admin) ----------
CREATE OR REPLACE FUNCTION rubbercity_admin_create_team(
  p_name        TEXT,
  p_description TEXT DEFAULT NULL
)
RETURNS UUID
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql
AS $$
DECLARE
  new_id UUID;
BEGIN
  IF NOT rubbercity_is_admin() THEN
    RAISE EXCEPTION 'Acesso negado: apenas administradores.' USING ERRCODE = '42501';
  END IF;
  INSERT INTO rubbercity_teams(name, description) VALUES (TRIM(p_name), p_description)
  RETURNING id INTO new_id;
  RETURN new_id;
END;
$$;

CREATE OR REPLACE FUNCTION rubbercity_admin_update_team(
  p_id          UUID,
  p_name        TEXT,
  p_description TEXT DEFAULT NULL
)
RETURNS VOID
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql
AS $$
BEGIN
  IF NOT rubbercity_is_admin() THEN
    RAISE EXCEPTION 'Acesso negado: apenas administradores.' USING ERRCODE = '42501';
  END IF;
  UPDATE rubbercity_teams
     SET name = TRIM(p_name), description = p_description, updated_at = NOW()
   WHERE id = p_id;
END;
$$;

CREATE OR REPLACE FUNCTION rubbercity_admin_delete_team(p_id UUID)
RETURNS VOID
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql
AS $$
BEGIN
  IF NOT rubbercity_is_admin() THEN
    RAISE EXCEPTION 'Acesso negado: apenas administradores.' USING ERRCODE = '42501';
  END IF;
  DELETE FROM rubbercity_teams WHERE id = p_id;
END;
$$;

CREATE OR REPLACE FUNCTION rubbercity_admin_set_team_members(
  p_team_id  UUID,
  p_user_ids UUID[]
)
RETURNS VOID
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql
AS $$
BEGIN
  IF NOT rubbercity_is_admin() THEN
    RAISE EXCEPTION 'Acesso negado: apenas administradores.' USING ERRCODE = '42501';
  END IF;
  DELETE FROM rubbercity_team_members WHERE team_id = p_team_id;
  IF p_user_ids IS NOT NULL AND array_length(p_user_ids, 1) > 0 THEN
    INSERT INTO rubbercity_team_members(team_id, user_id)
    SELECT p_team_id, uid FROM unnest(p_user_ids) AS uid
    ON CONFLICT DO NOTHING;
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION rubbercity_admin_set_team_categories(
  p_team_id      UUID,
  p_category_ids UUID[]
)
RETURNS VOID
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql
AS $$
BEGIN
  IF NOT rubbercity_is_admin() THEN
    RAISE EXCEPTION 'Acesso negado: apenas administradores.' USING ERRCODE = '42501';
  END IF;
  DELETE FROM rubbercity_team_category_access WHERE team_id = p_team_id;
  IF p_category_ids IS NOT NULL AND array_length(p_category_ids, 1) > 0 THEN
    INSERT INTO rubbercity_team_category_access(team_id, category_id)
    SELECT p_team_id, cid FROM unnest(p_category_ids) AS cid
    ON CONFLICT DO NOTHING;
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION rubbercity_admin_list_teams()
RETURNS TABLE(
  id           UUID,
  name         TEXT,
  description  TEXT,
  member_ids   JSONB,
  category_ids JSONB,
  created_at   TIMESTAMPTZ
)
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
  IF NOT rubbercity_is_admin() THEN
    RAISE EXCEPTION 'Acesso negado: apenas administradores.' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
    SELECT
      t.id,
      t.name,
      t.description,
      COALESCE(
        (SELECT jsonb_agg(tm.user_id) FROM rubbercity_team_members tm WHERE tm.team_id = t.id),
        '[]'::jsonb
      ),
      COALESCE(
        (SELECT jsonb_agg(tca.category_id) FROM rubbercity_team_category_access tca WHERE tca.team_id = t.id),
        '[]'::jsonb
      ),
      t.created_at
    FROM rubbercity_teams t
    ORDER BY t.name;
END;
$$;

CREATE OR REPLACE FUNCTION rubbercity_my_teams()
RETURNS TABLE(id UUID, name TEXT)
SECURITY DEFINER
SET search_path = public
LANGUAGE sql
STABLE
AS $$
  SELECT t.id, t.name
    FROM rubbercity_teams t
    JOIN rubbercity_team_members tm ON tm.team_id = t.id
   WHERE tm.user_id = auth.uid()
   ORDER BY t.name;
$$;

GRANT SELECT ON rubbercity_teams                  TO authenticated;
GRANT SELECT ON rubbercity_team_members           TO authenticated;
GRANT SELECT ON rubbercity_team_category_access   TO authenticated;

GRANT EXECUTE ON FUNCTION rubbercity_user_allowed_categories()                       TO authenticated;
GRANT EXECUTE ON FUNCTION rubbercity_user_allowed_category_codes()                   TO authenticated;
GRANT EXECUTE ON FUNCTION rubbercity_user_allowed_categories_for(UUID)               TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION rubbercity_admin_create_team(TEXT, TEXT)                   TO authenticated;
GRANT EXECUTE ON FUNCTION rubbercity_admin_update_team(UUID, TEXT, TEXT)             TO authenticated;
GRANT EXECUTE ON FUNCTION rubbercity_admin_delete_team(UUID)                         TO authenticated;
GRANT EXECUTE ON FUNCTION rubbercity_admin_set_team_members(UUID, UUID[])            TO authenticated;
GRANT EXECUTE ON FUNCTION rubbercity_admin_set_team_categories(UUID, UUID[])         TO authenticated;
GRANT EXECUTE ON FUNCTION rubbercity_admin_list_teams()                              TO authenticated;
GRANT EXECUTE ON FUNCTION rubbercity_my_teams()                                      TO authenticated;

NOTIFY pgrst, 'reload schema';

-- =======  DOWN  ========
-- DROP FUNCTION IF EXISTS rubbercity_my_teams();
-- DROP FUNCTION IF EXISTS rubbercity_admin_list_teams();
-- DROP FUNCTION IF EXISTS rubbercity_admin_set_team_categories(UUID, UUID[]);
-- DROP FUNCTION IF EXISTS rubbercity_admin_set_team_members(UUID, UUID[]);
-- DROP FUNCTION IF EXISTS rubbercity_admin_delete_team(UUID);
-- DROP FUNCTION IF EXISTS rubbercity_admin_update_team(UUID, TEXT, TEXT);
-- DROP FUNCTION IF EXISTS rubbercity_admin_create_team(TEXT, TEXT);
-- DROP FUNCTION IF EXISTS rubbercity_user_allowed_categories_for(UUID);
-- DROP FUNCTION IF EXISTS rubbercity_user_allowed_category_codes();
-- DROP FUNCTION IF EXISTS rubbercity_user_allowed_categories();
-- DROP TABLE IF EXISTS rubbercity_team_category_access;
-- DROP TABLE IF EXISTS rubbercity_team_members;
-- DROP TABLE IF EXISTS rubbercity_teams;
-- NOTIFY pgrst, 'reload schema';
