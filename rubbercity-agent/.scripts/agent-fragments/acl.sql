SELECT CASE
  WHEN (SELECT raw_user_meta_data->>'role'
          FROM auth.users
         WHERE id = '{{ $json.userId }}'::uuid) = 'admin'
    THEN '["*"]'::jsonb
  ELSE COALESCE(
    (SELECT jsonb_agg(cid)
       FROM zanaflex_user_allowed_categories_for('{{ $json.userId }}'::uuid) cid),
    '[]'::jsonb)
END AS allowed_ids;
