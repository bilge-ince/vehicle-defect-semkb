-- =============================================================================
-- 03_semantic_kb.sql  —  NHTSA / Mercedes-Benz demo
--
-- Builds the Semantic Knowledge Base over schema `odi`.
--
-- PREREQUISITES (in this exact order):
--   psql -f sql/01_schema.sql      -- DDL, cryptic column names preserved
--   psql -f sql/02_comments.sql    -- GENERATED COMMENT ON from NHTSA's dictionary
--   psql -f sql/03_semantic_kb.sql -- this file
--
-- ORDER MATTERS. Verified in src/pipeline_common/semantic_kb/registry.rs:
-- create_semantic_kb() runs crawl_schemas() *immediately* and embeds both the
-- column definition AND the COMMENT text. If the comments are not in place yet,
-- the KB embeds only cryptic identifiers and the whole demo falls over.
--
-- If you re-run 02_comments.sql AFTER this file, every COMMENT ON statement
-- fires the Live DDL event trigger and re-embeds that object synchronously
-- (static-sql/semantic_kb_triggers.sql -> handle_comment). ~2000 comments =
-- ~2000 sequential model calls. Don't do it mid-demo.
--
-- Verified against aidb main @ 7db15bcf (7.6.0).
-- =============================================================================

\set ON_ERROR_STOP off
\timing on

\echo ''
\echo '############################################################'
\echo '#  ACT 2 / STEP 1 — Register the embedding model           #'
\echo '############################################################'
\echo ''

-- -----------------------------------------------------------------------------
-- OPTION A (DEFAULT) — `bert`, provider `bert_local`.
--   sentence-transformers/all-MiniLM-L6-v2, 384 dims, runs in-process, no
--   network, no download beyond first use, no GPU.
--   Verified: aidb-model/src/types/configs/bert.rs default_bert_model().
--   It is registered automatically by CREATE EXTENSION aidb
--   (src/model_registry.rs: SELECT aidb.create_model('bert','bert_local',...)).
--
--   *** ENGLISH ONLY. *** This is the honest gap named in README.md "The ask".
--   German COMMENT ON text retrieves poorly with this model. Say so on stage.
--
-- OPTION B — `bge-m3-f16`, provider `llamacpp_embeddings`.
--   BGE-M3, 1024 dims, MULTILINGUAL (incl. German), GGUF via llama.cpp,
--   fully local. Also pre-registered by CREATE EXTENSION aidb
--   (src/model_registry.rs llamacpp_embeddings block), but the GGUF is
--   downloaded from HuggingFace on FIRST USE — do that before you go on stage.
--
-- To switch: comment out the bert line, uncomment the bge-m3 line. Nothing
-- else in this file changes.
-- -----------------------------------------------------------------------------

\set kb_model 'bge-small-en-v1.5-f16'
-- \set kb_model 'bert'
-- \set kb_model 'bge-m3-f16'

\set kb_name 'nhtsa_semkb'

-- Idempotent. aidb.create_model uses CREATE FOREIGN TABLE IF NOT EXISTS
-- internally (sql/aidb--7.5.0--7.6.0.sql), so re-running is a documented no-op.
-- validate => false skips the live probe: for a local model the probe would
-- force a model load right here, which is slow and not what we want mid-demo.

-- Option A: bert_local (default, English). No config needed — defaults apply.
SELECT aidb.create_model('bert', 'bert_local', validate => false) AS registered_model;

-- Option B: multilingual GGUF. Uncomment together with the \set above.
-- SELECT aidb.create_model(
--     'bge-m3-f16',
--     'llamacpp_embeddings',
--     '{"model":"CompendiumLabs/bge-m3-gguf",
--       "model_file":"bge-m3-f16.gguf",
--       "revision":"1864f47f9824dace6802faf1ff83c5558ba8207b",
--       "n_ctx":8192}'::jsonb,
--     validate => false
-- ) AS registered_model;

-- SELECT aidb.create_model(
--     'my_embeddings_model',
--     'openai_embeddings',
--     config => '{
--         "model": "text-embedding-3-small",
--         "url": "https://<your-resource>.cognitiveservices.azure.com/openai/v1/embeddings"
--     }'::jsonb,
--     credentials_env => 'AIDB_AZURE_OPENAI_API_KEY'
-- );

SELECT aidb.create_model(
    'nhtsa_chat',
    'openai_responses_azure',
    aidb.openai_responses_config(
        model             => 'gpt-5.4-mini',
        url               => 'https://<your-resource>.cognitiveservices.azure.com/openai/v1/responses',
        temperature       => 0.2,
        max_output_tokens => 2048
    ),
    credentials_env    => 'AIDB_AZURE_OPENAI_API_KEY',
    replace_credentials => true,
    validate           => false
);

-- NOTE: the KB is created once, in STEP 3 below (after the idempotent cleanup in
-- STEP 2). A premature create here would only be dropped and re-embedded, which
-- doubles the embedding calls to the model for no benefit.

\echo ''
\echo '-- Model in use:'
\echo :kb_model

-- Make the model name reachable from inside DO blocks. psql does NOT perform
-- :variable interpolation inside dollar-quoted bodies, so a GUC is the reliable
-- way to hand a psql variable to PL/pgSQL.
SELECT set_config('demo.kb_model', :'kb_model', false) AS demo_kb_model;
SELECT set_config('demo.kb_name',  :'kb_name',  false) AS demo_kb_name;



\echo ''
\echo '############################################################'
\echo '#  STEP 2 — Idempotent cleanup of a previous run           #'
\echo '############################################################'
\echo ''

-- RISK: create_semantic_kb / create_semantic_alias both hard-error on an
-- existing name (registry.rs:"already exists"). On stage that reads as a
-- failure. Drop first, inside exception handlers, so a fresh machine is fine
-- too.
DO $cleanup$
DECLARE
    a TEXT;
BEGIN
    FOREACH a IN ARRAY ARRAY[
        'nhtsa_complaints_by_component_and_year',
        'nhtsa_fire_and_crash_by_make',
        'nhtsa_harm_weighted_components_for_make'
    ] LOOP
        BEGIN
            PERFORM aidb.delete_semantic_alias(a);
            RAISE NOTICE 'dropped stale alias %', a;
        EXCEPTION WHEN OTHERS THEN
            NULL;  -- did not exist; fine
        END;
    END LOOP;

    BEGIN
        PERFORM aidb.delete_semantic_kb(current_setting('demo.kb_name'));
        RAISE NOTICE 'dropped stale KB %', current_setting('demo.kb_name');
    EXCEPTION WHEN OTHERS THEN
        NULL;
    END;
END
$cleanup$;


\echo ''
\echo '############################################################'
\echo '#  STEP 3 — Create the Semantic Knowledge Base over `odi`   #'
\echo '############################################################'
\echo ''
\echo '-- One statement. The crawl + embedding of every table, view and column'
\echo '-- in schema odi happens inside this call, inside PostgreSQL.'
\echo '-- No data leaves the database. No embedding service. No egress.'
\echo ''

-- Signature verified in src/pipeline_common/semantic_kb/registry.rs:16
--   create_semantic_kb(name, model, schemas TEXT[], auto_processing,
--                      bypass_triggers BOOL, vector_index JSONB) RETURNS TEXT
--
-- auto_processing => 'Live' installs ddl_command_end event triggers that
-- re-embed on CREATE / ALTER / DROP / COMMENT for objects in `odi`
-- (src/pipeline_common/semantic_kb/triggers.rs). That is the Act 2 beat:
-- "add a COMMENT, the KB is current in the same transaction."
--
-- RISK: those triggers make every later DDL statement on `odi` synchronously
-- call the embedding model. Great demo, bad for a bulk migration. Say so.
--
-- WARNING you will see if another KB already exists: registry.rs deliberately
-- warns that once >1 KB is registered, calls that omit kb_name become
-- ambiguous and error. We always pass kb_name explicitly below, so this is
-- informational only.

SELECT aidb.create_semantic_kb(
    name            => :'kb_name',
    model           => :'kb_model',
    schemas         => ARRAY['odi'],
    auto_processing => 'Live',
    bypass_triggers => false,
    vector_index    => NULL   -- exact search; odi is ~150 metadata rows, an
                              -- HNSW index would be pure overhead here
) AS semantic_kb;


\echo ''
\echo '############################################################'
\echo '#  STEP 4 — Refresh + verify                                #'
\echo '############################################################'
\echo ''
\echo '-- refresh_semantic_kb TRUNCATEs the metadata table and re-crawls from'
\echo '-- scratch. It is the recovery path if comments landed after creation.'
\echo '-- Immediately after create it is redundant — keep it here anyway so the'
\echo '-- audience sees the operation exists and is a single call.'
\echo ''

SELECT aidb.refresh_semantic_kb(:'kb_name');

\echo ''
\echo '-- semantic_kb_stats returns (total, tables, views, columns, pending).'
\echo '-- `pending` counts rows queued in aidb_internal.semantic_kb_state and'
\echo '-- should be 0 under Live auto-processing.'
\echo ''

SELECT
    total   AS entities_embedded,
    tables  AS tables_,
    views   AS views_,
    columns AS columns_,
    pending AS pending_
FROM aidb.semantic_kb_stats(:'kb_name');

\echo ''
\echo '-- Assertion: if this prints anything other than PASS, stop and fix it'
\echo '-- before continuing. An empty KB makes Act 3 silently meaningless.'
\echo ''

DO $verify$
DECLARE
    v_total   BIGINT;
    v_columns BIGINT;
    v_pending BIGINT;
BEGIN
    SELECT total, columns, pending
      INTO v_total, v_columns, v_pending
      FROM aidb.semantic_kb_stats(current_setting('demo.kb_name'));

    IF v_total IS NULL OR v_total = 0 THEN
        RAISE WARNING 'FAIL: semantic KB % is empty. Did 01_schema.sql run?',
            current_setting('demo.kb_name');
    -- odi.cmpl is 51 columns, odi.rcl 29, odi.inv 11 = 91 minimum
    -- (see sql/01_schema.sql, field lists verified against NHTSA 2026-08-07;
    -- the widely-circulated "complaints has 49 fields" figure is stale).
    ELSIF v_columns < 85 THEN
        RAISE WARNING 'FAIL: only % columns embedded — odi.cmpl(51) + rcl(29) + inv(11) = 91. Check the schema name and that 01_schema.sql ran.',
            v_columns;
    ELSIF v_pending > 0 THEN
        RAISE WARNING 'PARTIAL: % entities still pending embedding.', v_pending;
    ELSE
        RAISE NOTICE 'PASS: % entities embedded (% columns), 0 pending.',
            v_total, v_columns;
    END IF;
END
$verify$;

\echo ''
\echo '-- Smoke test: the question that has no matching column NAME anywhere.'
\echo '-- "when did the defect actually happen" must surface FAILDATE, not'
\echo '-- DATEA and not LDATE. This is the whole thesis in one query.'
\echo ''

SELECT
    entity_type,
    relation_name,
    column_name,
    round(score::numeric, 4) AS score,
    rank,
    left(coalesce(comment, '(no comment)'), 90) AS comment_excerpt
FROM aidb.semantic_kb_search(
    query_text   => 'the date on which the defect or failure actually occurred in the vehicle',
    kb_name      => :'kb_name',
    top_k        => 5,
    entity_types => ARRAY['Column']
);


\echo ''
\echo '############################################################'
\echo '#  03_semantic_kb.sql complete                              #'
\echo '#  NEXT: sql/03a_relationships.sql  (relationships FIRST),   #'
\echo '#        then sql/03b_aliases.sql, then sql/04_agents.sql    #'
\echo '############################################################'
\echo ''
\echo '-- NOT AVAILABLE, do not promise it: semantic aliases are deliberately'
\echo '-- NOT exposed as agent tools. aidb-tools/src/native_tools.rs asserts'
\echo '-- that create/execute/update/delete_semantic_alias are absent from the'
\echo '-- native tool catalog. An agent DISCOVERS an alias via'
\echo '-- semantic_kb_search(sources => ARRAY[''alias'']) and then runs the'
\echo '-- returned SQL itself through run_sql_query.'
\echo ''

\timing off
