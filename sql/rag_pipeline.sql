-- ============================================================================
-- LOOVE OS RAG Pipeline: Automatic Embeddings for vault_files
-- ============================================================================
-- Requires: vault_files table, translation layer triggers
-- Reference: https://supabase.com/docs/guides/ai/automatic-embeddings
-- ============================================================================

-- ── Step 1: Enable Required Extensions ──────────────────────────────────────

CREATE EXTENSION IF NOT EXISTS vector WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pgmq;
CREATE EXTENSION IF NOT EXISTS pg_net WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE EXTENSION IF NOT EXISTS hstore WITH SCHEMA extensions;

-- ── Step 2: Add Embedding Column ────────────────────────────────────────────

ALTER TABLE vault_files
  ADD COLUMN IF NOT EXISTS embedding vector(384);

CREATE INDEX IF NOT EXISTS vault_files_embedding_idx
  ON vault_files
  USING ivfflat (embedding vector_cosine_ops)
  WITH (lists = 100);

-- ── Step 3: Utility Schema ──────────────────────────────────────────────────

CREATE SCHEMA IF NOT EXISTS util;

CREATE OR REPLACE FUNCTION util.project_url()
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  secret_value text;
BEGIN
  SELECT decrypted_secret INTO secret_value
    FROM vault.decrypted_secrets
    WHERE name = 'project_url';
  RETURN secret_value;
END;
$$;

CREATE OR REPLACE FUNCTION util.invoke_edge_function(
  name text,
  body jsonb,
  timeout_milliseconds int = 5 * 60 * 1000
)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
  headers_raw text;
  auth_header text;
BEGIN
  headers_raw := current_setting('request.headers', true);
  auth_header := CASE
    WHEN headers_raw IS NOT NULL THEN
      (headers_raw::json->>'authorization')
    ELSE NULL
  END;

  PERFORM net.http_post(
    url => util.project_url() || '/functions/v1/' || name,
    headers => jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', auth_header
    ),
    body => body,
    timeout_milliseconds => timeout_milliseconds
  );
END;
$$;

-- ── Step 4: Embedding Queue ─────────────────────────────────────────────────

SELECT pgmq.create('embedding_jobs');

-- ── Step 5: Enqueue Trigger ─────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION loove_enqueue_embedding()
RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.is_binary = true OR NEW.deleted = true OR NEW.content IS NULL THEN
    RETURN NEW;
  END IF;

  IF TG_OP = 'UPDATE' AND OLD.content IS DISTINCT FROM NEW.content THEN
    NEW.embedding := NULL;
  END IF;

  PERFORM pgmq.send(
    'embedding_jobs',
    jsonb_build_object(
      'id', NEW.id,
      'table', 'vault_files',
      'content_column', 'content',
      'embedding_column', 'embedding'
    )
  );

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_enqueue_vault_embedding ON vault_files;
CREATE TRIGGER trg_enqueue_vault_embedding
  BEFORE INSERT OR UPDATE OF content ON vault_files
  FOR EACH ROW
  EXECUTE FUNCTION loove_enqueue_embedding();

-- ── Step 6: Cron Job ────────────────────────────────────────────────────────

SELECT cron.schedule(
  'process-embedding-queue',
  '30 seconds',
  $$
    SELECT util.invoke_edge_function(
      'generate-embedding',
      jsonb_build_object('queue', 'embedding_jobs', 'batch_size', 10)
    );
  $$
);

-- ── Step 7: Semantic Search ─────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION loove_semantic_search(
  p_query_embedding vector(384),
  p_match_threshold float DEFAULT 0.7,
  p_match_count int DEFAULT 10,
  p_filter_tags text[] DEFAULT NULL,
  p_filter_source_table text DEFAULT NULL
)
RETURNS TABLE (
  id text,
  path text,
  content text,
  similarity float,
  tags text[],
  source_table text,
  source_id text,
  frontmatter jsonb
)
LANGUAGE plpgsql AS $$
BEGIN
  RETURN QUERY
  SELECT
    vf.id,
    vf.path,
    vf.content,
    1 - (vf.embedding <=> p_query_embedding) AS similarity,
    vf.tags,
    vf.frontmatter->>'source_table' AS source_table,
    vf.frontmatter->>'source_id' AS source_id,
    vf.frontmatter
  FROM vault_files vf
  WHERE
    vf.deleted = false
    AND vf.embedding IS NOT NULL
    AND 1 - (vf.embedding <=> p_query_embedding) > p_match_threshold
    AND (p_filter_tags IS NULL OR vf.tags && p_filter_tags)
    AND (p_filter_source_table IS NULL
         OR vf.frontmatter->>'source_table' = p_filter_source_table)
  ORDER BY vf.embedding <=> p_query_embedding
  LIMIT p_match_count;
END;
$$;

-- ── Step 8: Unified Cross-Table Search ──────────────────────────────────────

CREATE OR REPLACE FUNCTION loove_unified_search(
  p_query_embedding vector(384),
  p_match_threshold float DEFAULT 0.7,
  p_match_count int DEFAULT 10
)
RETURNS TABLE (
  source text,
  id text,
  title text,
  content_preview text,
  similarity float,
  tags text[],
  metadata jsonb
)
LANGUAGE plpgsql AS $$
BEGIN
  RETURN QUERY
  (
    SELECT
