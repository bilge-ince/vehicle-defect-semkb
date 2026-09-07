-- =============================================================================
-- 05a_hybrid_build.sql  —  NHTSA / Mercedes-Benz demo
--
-- *** PREFLIGHT ONLY. DO NOT RUN THIS ON STAGE. ***
--
-- This file builds odi.cmpl_sample and embeds its narratives. It takes 3-6
-- minutes for 50k rows on CPU. Act 4 is a 3-minute act. The two are not
-- compatible; that is why this file and sql/05b_hybrid_query.sql are separate.
--
-- Run this DAYS BEFORE the demo. Act 4 runs sql/05b_hybrid_query.sql, which is
-- query-only and instant.
--
-- *** AND WHEN IT FINISHES, RE-RUN sql/06_governance.sql. ***
-- This file DROPs and recreates odi.cmpl_sample. A dropped table takes its
-- grants and revokes with it, so 06's belt-and-braces REVOKE on that table is
-- silently undone every time this runs. See the closing block below.
--
-- Together with 05b this is THE SHOWCASE QUERY.
--
-- Question:  "Find complaints whose free-text narrative describes a burning
--             smell, but which were NOT coded as a fire."
--
-- That question is unanswerable with SQL alone (the signal is in prose) and
-- unanswerable with a vector store alone (the constraint `fire <> 'Y'` is
-- relational). It needs BOTH, in one statement, over one copy of the data.
--
-- Verified against aidb main @ 7db15bcf (7.6.0):
--   src/model_accessors.rs  encode_text / encode_text_query /
--                           encode_text_batch / get_adapter_embedding_dimensions
--   pgvector/sql/vector--0.2.0--0.2.1.sql   CAST (real[] AS vector)
-- =============================================================================

\set ON_ERROR_STOP off
\timing on

-- Must match the model used in sql/03_semantic_kb.sql. Different model =>
-- different vector space => meaningless distances. sql/05b_hybrid_query.sql
-- sets the SAME value; if you change it here, change it there too.
\set kb_model 'my_embeddings_model'
-- \set kb_model 'bert'
-- \set kb_model 'bge-m3-f16'

-- 50k is the number quoted on stage. Drop to 10000 if you are rebuilding
-- live and the room is watching. odi.cmpl in full is ~2.2M rows; embedding
-- all of them is a batch job, not a demo step. SAY THAT OUT LOUD — claiming
-- you embedded 2.2M rows in the last four minutes is how you lose an engineer.
\set sample_size 50000

SELECT set_config('demo.kb_model',    :'kb_model',            false) AS kb_model;
SELECT set_config('demo.sample_size', :'sample_size'::text,   false) AS sample_size;


\echo ''
\echo '############################################################'
\echo '#  STEP 1 — Build the sampled subset                        #'
\echo '############################################################'
\echo ''

CREATE EXTENSION IF NOT EXISTS vector;

-- NOTE: vin, dealer_name, dealer_tel, dealer_city, dealer_state and dealer_zip
-- are DELIBERATELY NOT COPIED. They are the PII-adjacent columns that
-- sql/06_governance.sql denies to every agent role. Leaving them out of the
-- derived table means the denial holds even for someone who forgets to grant
-- carefully. Defense in depth, and a free callback in Act 4.
DROP TABLE IF EXISTS odi.cmpl_sample CASCADE;

CREATE TABLE odi.cmpl_sample (
    id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    cmplid      TEXT,
    odino       TEXT,
    mfr_name    TEXT,
    maketxt     TEXT,
    modeltxt    TEXT,
    yeartxt     TEXT,
    compdesc    TEXT,
    faildate    TEXT,
    datea       TEXT,
    fire        TEXT,
    crash       TEXT,
    injured     TEXT,
    deaths      TEXT,
    cdescr      TEXT
);

COMMENT ON TABLE odi.cmpl_sample IS
    'Sampled subset of odi.cmpl carrying a pgvector embedding of the CDESCR '
    'free-text narrative. Demo artefact for hybrid search. Excludes VIN and '
    'all DEALER_* columns by construction.';

-- TABLESAMPLE SYSTEM is block-level: fast, but the row count it yields is
-- approximate AND proportional to the table size. A hardcoded `SYSTEM (10)`
-- silently under-delivers if the loader was run with --subset 250000
-- (10% of 250k = 25k, not the 50k we asked for). So compute the percentage
-- from the actual row count, with generous headroom for the WHERE filter.
DO $sample$
DECLARE
    v_want  BIGINT := current_setting('demo.sample_size')::bigint;
    v_have  BIGINT;
    v_pct   NUMERIC;
    v_got   BIGINT;
BEGIN
    SELECT reltuples::bigint INTO v_have FROM pg_class WHERE oid = 'odi.cmpl'::regclass;
    IF v_have IS NULL OR v_have <= 0 THEN
        SELECT count(*) INTO v_have FROM odi.cmpl;   -- never ANALYZEd
    END IF;

    -- 3x headroom: TABLESAMPLE is approximate and the cdescr filter drops rows.
    v_pct := LEAST(100.0, GREATEST(1.0, (v_want::numeric * 300.0) / GREATEST(v_have,1)));

    RAISE NOTICE 'odi.cmpl has ~% rows; sampling %%% to reach % narratives',
        v_have, round(v_pct, 2), v_want;

    EXECUTE format($ins$
        INSERT INTO odi.cmpl_sample
            (cmplid, odino, mfr_name, maketxt, modeltxt, yeartxt, compdesc,
             faildate, datea, fire, crash, injured, deaths, cdescr)
        SELECT cmplid, odino, mfr_name, maketxt, modeltxt, yeartxt, compdesc,
               faildate, datea, fire, crash, injured, deaths, cdescr
        FROM   odi.cmpl TABLESAMPLE SYSTEM (%s)
        WHERE  cdescr IS NOT NULL
          AND  length(btrim(cdescr)) > 40   -- stub narratives embed to noise
        LIMIT  %s
    $ins$, v_pct, v_want);

    GET DIAGNOSTICS v_got = ROW_COUNT;

    IF v_got < v_want / 2 THEN
        RAISE WARNING 'only % of % rows sampled. Either odi.cmpl is small, or '
                      'it was never loaded. Check `SELECT count(*) FROM odi.cmpl`.',
                      v_got, v_want;
    ELSE
        RAISE NOTICE 'sampled % rows into odi.cmpl_sample', v_got;
    END IF;
END
$sample$;

SELECT count(*) AS rows_sampled FROM odi.cmpl_sample;


\echo ''
\echo '############################################################'
\echo '#  STEP 2 — Lexical index (this is also the FALLBACK path)  #'
\echo '############################################################'
\echo ''
\echo '-- Build this FIRST and unconditionally. If the embedding pass in STEP 4'
\echo '-- is too slow on the demo machine, the fallback section of'
\echo '-- sql/05b_hybrid_query.sql still runs off this alone.'
\echo ''

ALTER TABLE odi.cmpl_sample
    ADD COLUMN cdescr_tsv tsvector
    GENERATED ALWAYS AS (to_tsvector('english', coalesce(cdescr, ''))) STORED;

CREATE INDEX cmpl_sample_tsv_gin ON odi.cmpl_sample USING GIN (cdescr_tsv);

-- Cheap B-tree support for the structured predicates we fuse in below.
CREATE INDEX cmpl_sample_fire_idx  ON odi.cmpl_sample (fire);
CREATE INDEX cmpl_sample_make_idx  ON odi.cmpl_sample (maketxt);

ANALYZE odi.cmpl_sample;


\echo ''
\echo '############################################################'
\echo '#  STEP 3 — Add the pgvector column, sized from the model   #'
\echo '############################################################'
\echo ''

-- Dimensionality is a property of the model, not something to hard-code.
-- bert (all-MiniLM-L6-v2) = 384; bge-m3-f16 = 1024.
-- aidb.get_adapter_embedding_dimensions(model_name, data_format) asks the
-- adapter directly. Signature verified: src/model_accessors.rs:159.
-- FIRST CALL LOADS THE MODEL — expect a pause here, once.
DO $addcol$
DECLARE
    v_dims INT;
BEGIN
    -- The enum cast is explicit on purpose: the parameter type is
    -- aidb.PipelineDataFormat, and leaving it as an unknown literal works
    -- today but is exactly the kind of thing that breaks under a future
    -- overload. Do not remove it live.
    v_dims := aidb.get_adapter_embedding_dimensions(
        current_setting('demo.kb_model'), 'Text'::aidb.PipelineDataFormat);

    EXECUTE format(
        'ALTER TABLE odi.cmpl_sample ADD COLUMN cdescr_vec vector(%s)', v_dims);

    RAISE NOTICE 'added odi.cmpl_sample.cdescr_vec as vector(%) for model %',
        v_dims, current_setting('demo.kb_model');
END
$addcol$;


\echo ''
\echo '############################################################'
\echo '#  STEP 4 — Embed the narratives, in batches, in-database   #'
\echo '############################################################'
\echo ''
\echo '-- aidb.encode_text_batch(model_name TEXT, input TEXT[]) RETURNS SETOF'
\echo '-- real[]. One model call per batch instead of one per row - roughly an'
\echo '-- order of magnitude faster than looping aidb.encode_text().'
\echo ''
\echo '-- >>> THIS IS THE SLOW STEP. This whole file runs before the meeting. <<<'
\echo ''

-- ===========================================================================
-- WHY WE DO IT THIS WAY RATHER THAN WITH A PIPELINE
--
-- AIDB's managed path is a KnowledgeBase pipeline:
--
--   SELECT aidb.create_pipeline(
--       name               => 'cmpl_narrative_kb',
--       source             => 'odi.cmpl_sample',
--       source_key_column  => 'id',
--       source_data_column => 'cdescr',
--       step_1             => 'KnowledgeBase',
--       step_1_options     => aidb.knowledge_base_config(
--                                 model => 'bert', data_format => 'Text'),
--       auto_processing    => 'Live');
--
-- (Pattern verified in tests/pg_regress/sql/knowledge_base_creation.sql and
-- hybrid_search_helpers.sql.) That is the RIGHT answer in production: it
-- writes embeddings into its own managed vector table, keeps them current on
-- INSERT/UPDATE, and exposes aidb.kb_query_encode(kb_name, text) plus the
-- aidb.knowledge_bases_v7 view telling you vector_schema / vector_table /
-- vector_key_column / distance_operator_sql so you can join to it.
--
-- We do NOT use it here for one reason: the fused query in 05b is the thing
-- the audience is meant to read. An in-table vector column makes that query a
-- single self-join-free statement. A pipeline makes it a join to
-- aidb_internal.<vector_table> on source_id, which is more moving parts on a
-- slide for zero additional truth.
--
-- Uncomment the pipeline above if someone asks "how would you keep this
-- current?" — that is the honest answer, and it is one statement.
-- ===========================================================================

DO $embed$
DECLARE
    v_ids        BIGINT[];
    v_txt        TEXT[];
    v_batch      INT := 128;      -- raise for GPU, lower if you hit n_ctx limits
    v_done       BIGINT := 0;
    v_total      BIGINT;
    v_model      TEXT := current_setting('demo.kb_model');
    v_started    TIMESTAMPTZ := clock_timestamp();
    v_attempt    INT;
    v_backoff    NUMERIC;
BEGIN
    SELECT count(*) INTO v_total FROM odi.cmpl_sample WHERE cdescr_vec IS NULL;
    RAISE NOTICE 'embedding % narratives with model % ...', v_total, v_model;

    LOOP
        -- Truncate to 4000 chars: bert's context is small and an over-long
        -- input is either truncated silently or errors depending on adapter.
        -- Explicit is better than surprising.
        SELECT array_agg(s.id  ORDER BY s.id),
               array_agg(left(s.cdescr, 4000) ORDER BY s.id)
          INTO v_ids, v_txt
          FROM (SELECT id, cdescr
                  FROM odi.cmpl_sample
                 WHERE cdescr_vec IS NULL
                 ORDER BY id
                 LIMIT v_batch) s;

        EXIT WHEN v_ids IS NULL;

        -- Azure's embedding endpoint rate-limits on tokens/min, not just
        -- requests/min, and a single batch of 128 x ~4000-char narratives
        -- can trip it. The whole DO block is one transaction (see the RISK
        -- note below), so an unhandled error here loses ALL prior progress,
        -- not just this batch. Retry the SAME batch with backoff instead of
        -- letting that exception propagate.
        v_attempt := 0;
        LOOP
            v_attempt := v_attempt + 1;
            BEGIN
                -- WITH ORDINALITY is what maps each returned vector back to
                -- its input row: encode_text_batch returns a bare SETOF
                -- real[] with no key, and yields results in input order.
                UPDATE odi.cmpl_sample t
                   SET cdescr_vec = e.vec::vector   -- CAST (real[] AS vector)
                                                     -- is provided by pgvector
                  FROM (
                        SELECT vec, ord
                        FROM aidb.encode_text_batch(v_model, v_txt)
                             WITH ORDINALITY AS x(vec, ord)
                       ) e
                 WHERE t.id = v_ids[e.ord];
                EXIT;  -- success, leave the retry loop
            EXCEPTION WHEN OTHERS THEN
                IF SQLERRM ILIKE '%rate limit%' AND v_attempt < 8 THEN
                    v_backoff := LEAST(2 ^ (v_attempt - 1), 30);  -- 1,2,4,...30s cap
                    RAISE NOTICE '  rate limited on batch at row %, attempt %, backing off %s',
                        v_done, v_attempt, v_backoff;
                    PERFORM pg_sleep(v_backoff);
                ELSE
                    RAISE;  -- not a rate limit, or out of retries: fail loudly
                END IF;
            END;
        END LOOP;

        v_done := v_done + coalesce(array_length(v_ids, 1), 0);

        -- RAISE's only format placeholder is bare `%`. There is no printf
        -- precision syntax in PL/pgSQL — round() the value instead.
        IF v_done % 2560 = 0 THEN
            RAISE NOTICE '  % / % embedded (% rows/sec)',
                v_done, v_total,
                round((v_done / GREATEST(
                    EXTRACT(EPOCH FROM clock_timestamp() - v_started), 0.001))::numeric, 1);
        END IF;
    END LOOP;

    RAISE NOTICE 'done: % narratives embedded in %s',
        v_done, round(EXTRACT(EPOCH FROM clock_timestamp() - v_started)::numeric, 1);
END
$embed$;

-- RISK: the loop above runs as ONE transaction. On a 50k sample that is a
-- long-lived write transaction — fine on a dedicated demo box, not something
-- to copy verbatim onto a production primary. In production, drive the same
-- loop from a client (or use the KnowledgeBase pipeline above, which batches
-- and commits for you).

SELECT
    count(*)                            AS rows_total,
    count(cdescr_vec)                   AS rows_embedded,
    count(*) - count(cdescr_vec)        AS rows_missing
FROM odi.cmpl_sample;


\echo ''
\echo '############################################################'
\echo '#  STEP 5 — HNSW index                                      #'
\echo '############################################################'
\echo ''

-- vector_cosine_ops matches the <=> operator used in 05b. Mismatch the opclass
-- and the index is silently ignored — you get a correct but slow seq scan.
CREATE INDEX cmpl_sample_vec_hnsw
    ON odi.cmpl_sample
    USING hnsw (cdescr_vec vector_cosine_ops)
    WITH (m = 16, ef_construction = 64);

ANALYZE odi.cmpl_sample;


\echo ''
\echo '############################################################'
\echo '#  STEP 6 — *** NOW RE-RUN sql/06_governance.sql ***        #'
\echo '############################################################'
\echo ''
\echo '-- This file DROPPED and recreated odi.cmpl_sample. Dropping a table'
\echo '-- discards its ACL, so sql/06_governance.sql STEP 6 belt-and-braces'
\echo '-- REVOKE on odi.cmpl_sample HAS BEEN UNDONE. That table carries the'
\echo '-- full CDESCR narrative - the highest-risk column in the dataset.'
\echo ''
\echo '--   psql "$DEMO_DSN" -f sql/06_governance.sql'
\echo ''
\echo '-- If you only want the revoke and not the whole file, this is the'
\echo '-- minimum. Run it as the owner of schema odi:'
\echo ''
\echo '--   REVOKE ALL ON odi.cmpl_sample FROM PUBLIC;'
\echo '--   REVOKE ALL ON odi.cmpl_sample FROM nhtsa_defect_analytics,'
\echo '--                                      nhtsa_recall_compliance,'
\echo '--                                      nhtsa_exec_reporting;'
\echo ''
\echo '-- Then confirm, before you consider this file finished:'
\echo ''

-- Every row must read false. If any reads true, the revoke did not happen.
SELECT
    r.rolname AS purpose_role,
    has_table_privilege(r.rolname, 'odi.cmpl_sample', 'SELECT') AS can_read_cmpl_sample
FROM pg_roles r
WHERE r.rolname IN ('nhtsa_defect_analytics','nhtsa_recall_compliance','nhtsa_exec_reporting')
ORDER BY r.rolname;


\echo ''
\echo '############################################################'
\echo '#  05a_hybrid_build.sql complete                            #'
\echo '#  Act 4 runs sql/05b_hybrid_query.sql, not this file.      #'
\echo '#  DID YOU RE-RUN sql/06_governance.sql?                    #'
\echo '############################################################'
\echo ''

\timing off
