-- =============================================
-- Rubbercity (clean) — 005: match_documents (ACL + enrichment + service_role)
-- Consolida: 008 + 012 + 014 + 019 + 020 do conjunto original (versão final).
--
-- rubbercity_match_documents(query_embedding, match_count, filter):
--   * Se filter tem "allowed_category_ids": usa essa ACL (n8n service-role).
--       - ["*"]   → bypass ACL (admin context)
--       - [...]   → restringe àquelas categorias
--       - []      → nada
--   * Senão: admin vê tudo; membro vê suas categorias via team ACL.
--   * service_role sem override → confia (trust boundary do n8n).
--   * Enriquece a metadata de cada chunk com (url, title, code,
--     category_id, source, mime_type) do rubbercity_document_metadata.
--
-- rubbercity_match_documents_for_user(p_user_id, ...): variante service-role
-- que avalia ACL como o user_id passado (sem auth.uid()).
--
-- Rode APÓS 004_rag_schema.sql
-- =============================================

-- =======  UP  ========

DROP FUNCTION IF EXISTS rubbercity_match_documents(vector, int, jsonb);
CREATE OR REPLACE FUNCTION rubbercity_match_documents(
  query_embedding vector(1536),
  match_count     int     DEFAULT 6,
  filter          jsonb   DEFAULT '{}'::jsonb
)
RETURNS TABLE(
  id         bigint,
  content    text,
  metadata   jsonb,
  similarity float
)
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  override_ids       UUID[];
  has_override       BOOLEAN := FALSE;
  override_bypass    BOOLEAN := FALSE;
  is_admin_caller    BOOLEAN := rubbercity_is_admin();
  is_member_caller   BOOLEAN := rubbercity_is_member();
  is_service_role    BOOLEAN := (
    COALESCE(current_setting('request.jwt.claim.role', true), '') = 'service_role'
    OR COALESCE(auth.role(), '') = 'service_role'
  );
  effective_filter   JSONB   := COALESCE(filter, '{}'::jsonb);
BEGIN
  IF effective_filter ? 'allowed_category_ids' THEN
    has_override := TRUE;
    IF effective_filter->'allowed_category_ids' @> '["*"]'::jsonb THEN
      override_bypass := TRUE;
    ELSE
      SELECT ARRAY(
        SELECT (jsonb_array_elements_text(effective_filter->'allowed_category_ids'))::uuid
      ) INTO override_ids;
    END IF;
    effective_filter := effective_filter - 'allowed_category_ids';
  END IF;

  IF NOT has_override
     AND NOT is_admin_caller
     AND NOT is_member_caller
     AND NOT is_service_role THEN
    RETURN;
  END IF;

  RETURN QUERY
    SELECT
      d.id,
      d.content,
      (
        jsonb_strip_nulls(jsonb_build_object(
          'url',         m.url,
          'title',       m.title,
          'code',        m.code,
          'category_id', m.category_id,
          'source',      m.source,
          'mime_type',   m.mime_type
        )) || COALESCE(d.metadata, '{}'::jsonb)
      ) AS metadata,
      1 - (d.embedding <=> query_embedding) AS similarity
    FROM rubbercity_documents d
    LEFT JOIN rubbercity_document_metadata m
           ON m.file_id = d.metadata->>'file_id'
    WHERE d.metadata @> effective_filter
      AND (
        (has_override AND (
            override_bypass
            OR (override_ids IS NOT NULL AND m.category_id = ANY(override_ids))
        ))
        OR (NOT has_override AND is_service_role)
        OR (NOT has_override AND NOT is_service_role AND is_admin_caller)
        OR (NOT has_override AND NOT is_service_role AND is_member_caller
            AND m.category_id IN (SELECT rubbercity_user_allowed_categories()))
      )
    ORDER BY d.embedding <=> query_embedding
    LIMIT match_count;
END;
$$;

-- Variante explicitly-user (chamada pelo n8n quando ele já tem o user_id)
DROP FUNCTION IF EXISTS rubbercity_match_documents_for_user(UUID, vector, int, jsonb);
CREATE OR REPLACE FUNCTION rubbercity_match_documents_for_user(
  p_user_id       UUID,
  query_embedding vector(1536),
  match_count     int     DEFAULT 6,
  filter          jsonb   DEFAULT '{}'::jsonb
)
RETURNS TABLE(
  id         bigint,
  content    text,
  metadata   jsonb,
  similarity float
)
SECURITY DEFINER
SET search_path = auth, public
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  is_adm BOOLEAN;
BEGIN
  SELECT (raw_user_meta_data->>'role' = 'admin'
          AND raw_user_meta_data->>'company_name' = 'rubbercity')
    INTO is_adm
    FROM auth.users
   WHERE id = p_user_id;

  RETURN QUERY
    SELECT
      d.id,
      d.content,
      (
        jsonb_strip_nulls(jsonb_build_object(
          'url',         m.url,
          'title',       m.title,
          'code',        m.code,
          'category_id', m.category_id,
          'source',      m.source,
          'mime_type',   m.mime_type
        )) || COALESCE(d.metadata, '{}'::jsonb)
      ) AS metadata,
      1 - (d.embedding <=> query_embedding) AS similarity
    FROM rubbercity_documents d
    LEFT JOIN rubbercity_document_metadata m
           ON m.file_id = d.metadata->>'file_id'
    WHERE d.metadata @> COALESCE(filter, '{}'::jsonb)
      AND (
        COALESCE(is_adm, false)
        OR m.category_id IN (SELECT rubbercity_user_allowed_categories_for(p_user_id))
      )
    ORDER BY d.embedding <=> query_embedding
    LIMIT match_count;
END;
$$;

GRANT EXECUTE ON FUNCTION rubbercity_match_documents(vector, int, jsonb)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION rubbercity_match_documents_for_user(UUID, vector, int, jsonb)
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

-- =======  DOWN  ========
-- DROP FUNCTION IF EXISTS rubbercity_match_documents_for_user(UUID, vector, int, jsonb);
-- DROP FUNCTION IF EXISTS rubbercity_match_documents(vector, int, jsonb);
-- NOTIFY pgrst, 'reload schema';
