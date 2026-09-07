-- =============================================================================
-- 05b_hybrid_query.sql  —  NHTSA / Mercedes-Benz demo
--
-- *** THIS IS THE ACT 4 FILE. It is query-only and it is fast. ***
--
-- It reads odi.cmpl_sample, which sql/05a_hybrid_build.sql created and embedded
-- days ago. It creates nothing, drops nothing and grants nothing, so it cannot
-- disturb sql/06_governance.sql.
--
-- If odi.cmpl_sample does not exist, STOP — run sql/05a_hybrid_build.sql (3-6
-- minutes) and then re-run sql/06_governance.sql. Do not do that on stage; use
-- the tsvector fallback in STEP 3 instead.
--
-- THE SHOWCASE QUERY.
--
-- Question:  "Find complaints whose free-text narrative describes a burning
--             smell, but which were NOT coded as a fire."
--
-- That question is unanswerable with SQL alone (the signal is in prose) and
-- unanswerable with a vector store alone (the constraint `fire <> 'Y'` is
-- relational). It needs BOTH, in one statement, over one copy of the data.
--
-- Semantic similarity + full-text rank + a structured predicate, fused and
-- ranked in a SINGLE SQL statement. No data leaves PostgreSQL: the embedding
-- model runs inside the backend process. There is no vector database, no
-- ETL job, no embedding API, and nothing to keep in sync.
--
-- Verified against aidb main @ 7db15bcf (7.6.0):
--   src/model_accessors.rs  encode_text_query
-- =============================================================================

\set ON_ERROR_STOP off
\timing on

-- MUST match the model sql/05a_hybrid_build.sql embedded with, which must in
-- turn match sql/03_semantic_kb.sql. Different model => different vector space
-- => meaningless distances.
\set kb_model 'my_embeddings_model'
-- \set kb_model 'bert'
-- \set kb_model 'bge-m3-f16'

SELECT set_config('demo.kb_model', :'kb_model', false) AS kb_model;

-- Preflight. Better to find out here than three lines into the fused query.
DO $check$
BEGIN
    IF to_regclass('odi.cmpl_sample') IS NULL THEN
        RAISE WARNING 'odi.cmpl_sample does NOT exist. Run sql/05a_hybrid_build.sql '
                      '(3-6 min), then re-run sql/06_governance.sql. On stage, skip '
                      'to STEP 3 (7b), which runs straight off odi.cmpl.';
    ELSE
        DECLARE v_emb BIGINT; v_all BIGINT;
        BEGIN
            EXECUTE 'SELECT count(cdescr_vec), count(*) FROM odi.cmpl_sample'
                INTO v_emb, v_all;
            IF v_emb = 0 THEN
                RAISE WARNING 'odi.cmpl_sample exists but NOTHING is embedded (0 of %). '
                              'The vector arm will be empty - use the STEP 3 fallback.', v_all;
            ELSE
                RAISE NOTICE 'odi.cmpl_sample ready: % of % narratives embedded', v_emb, v_all;
            END IF;
        END;
    END IF;
END
$check$;

-- RISK, and the honest caveat for this whole act: HNSW is APPROXIMATE, and
-- the `fire <> 'Y'` predicate is applied AFTER the index returns its
-- candidates. If most top-similarity rows are fire-coded, the post-filter
-- can leave you short. Raising ef_search widens the candidate pool.
SET hnsw.ef_search = 200;


\echo ''
\echo '############################################################'
\echo '#  STEP 1 — THE FUSED QUERY.  One statement.                #'
\echo '############################################################'
\echo ''
\echo '-- "Complaints whose narrative describes a burning smell, but which'
\echo '--  were NOT coded as a fire."'
\echo ''
\echo '--  vector similarity   -> finds "smelled like something was burning",'
\echo '--                         "acrid odor from the vents", "hot plastic'
\echo '--                         smell" - none of which contain the word'
\echo '--                         "fire" and none of which a LIKE would catch'
\echo '--  full-text (GIN)     -> exact lexical anchors, cheap and precise'
\echo '--  fire <> ''Y''         -> the relational constraint. THE POINT.'
\echo '--  RRF                 -> fuses the two rankings without needing the'
\echo '--                         two scores to be on a comparable scale'
\echo ''

WITH q AS (
    -- encode_text_QUERY, not encode_text. Asymmetric models (bge-*, e5-*,
    -- nomic-*) prepend a different instruction prefix to a query than to a
    -- document; using the wrong one quietly degrades recall.
    -- The stored vectors in 05a were built with encode_text (document side).
    SELECT
        aidb.encode_text_query(
            current_setting('demo.kb_model'),
            'a burning smell, acrid odor of hot plastic or melting wiring '
            'coming from the vents or engine bay while driving'
        )::vector AS qv,
        websearch_to_tsquery('english',
            'burning OR smoke OR smell OR odor OR melting') AS tsq
),
-- Candidate list A: nearest neighbours in embedding space.
vec AS (
    SELECT c.id,
           row_number() OVER (ORDER BY c.cdescr_vec <=> q.qv) AS vec_rank,
           1 - (c.cdescr_vec <=> q.qv)                        AS cosine_sim
    FROM   odi.cmpl_sample c
    CROSS  JOIN q
    WHERE  c.cdescr_vec IS NOT NULL
      AND  coalesce(c.fire, 'N') <> 'Y'     -- <<< the structured predicate
    ORDER  BY c.cdescr_vec <=> q.qv
    LIMIT  300
),
-- Candidate list B: lexical matches.
fts AS (
    SELECT c.id,
           row_number() OVER (ORDER BY ts_rank_cd(c.cdescr_tsv, q.tsq) DESC) AS fts_rank,
           ts_rank_cd(c.cdescr_tsv, q.tsq)                                    AS ts_score
    FROM   odi.cmpl_sample c
    CROSS  JOIN q
    WHERE  c.cdescr_tsv @@ q.tsq
      AND  coalesce(c.fire, 'N') <> 'Y'     -- <<< same predicate, both arms
    ORDER  BY ts_rank_cd(c.cdescr_tsv, q.tsq) DESC
    LIMIT  300
),
-- Reciprocal Rank Fusion. k = 60 is the conventional damping constant; it
-- keeps a single #1 hit from dominating a document that ranks well in both.
fused AS (
    SELECT
        coalesce(v.id, f.id)                                   AS id,
        coalesce(1.0 / (60 + v.vec_rank), 0.0)
      + coalesce(1.0 / (60 + f.fts_rank), 0.0)                 AS rrf_score,
        v.vec_rank,
        f.fts_rank,
        v.cosine_sim,
        f.ts_score
    FROM vec v
    FULL OUTER JOIN fts f USING (id)
)
SELECT
    row_number() OVER (ORDER BY x.rrf_score DESC)     AS rank,
    round(x.rrf_score::numeric, 5)                    AS rrf,
    x.vec_rank,
    x.fts_rank,
    round(x.cosine_sim::numeric, 4)                   AS cosine_sim,
    c.maketxt                                         AS make,
    c.modeltxt                                        AS model,
    c.yeartxt                                         AS model_year,
    c.compdesc                                        AS component,
    c.fire                                            AS fire_coded,
    left(regexp_replace(c.cdescr, '\s+', ' ', 'g'), 150) AS narrative
FROM fused x
JOIN odi.cmpl_sample c ON c.id = x.id
ORDER BY x.rrf_score DESC
LIMIT 20;

\echo ''
\echo '-- READ THE fire_coded COLUMN. Every row is N or blank. These are'
\echo '-- complaints describing a thermal event that the structured coding'
\echo '-- missed. That is a finding, not a demo trick - and it took one'
\echo '-- statement against one copy of the data.'
\echo ''
\echo '-- Watch what these rows are NOT: the vector arm returns narratives'
\echo '-- containing no query keyword at all. Show one with `vec_rank` set and'
\echo '-- `fts_rank` NULL - that row is invisible to full-text search.'
\echo ''

\echo ''
\echo '-- 1b. Rows found ONLY by the semantic arm (fts_rank IS NULL).'
\echo '--     This is the slide that justifies the embeddings.'
\echo ''

WITH q AS (
    SELECT aidb.encode_text_query(
               current_setting('demo.kb_model'),
               'a burning smell, acrid odor of hot plastic or melting wiring '
               'coming from the vents or engine bay while driving')::vector AS qv,
           websearch_to_tsquery('english',
               'burning OR smoke OR smell OR odor OR melting') AS tsq
)
SELECT
    round((1 - (c.cdescr_vec <=> q.qv))::numeric, 4)      AS cosine_sim,
    c.maketxt AS make, c.compdesc AS component, c.fire AS fire_coded,
    left(regexp_replace(c.cdescr, '\s+', ' ', 'g'), 170)  AS narrative
FROM odi.cmpl_sample c
CROSS JOIN q
WHERE c.cdescr_vec IS NOT NULL
  AND coalesce(c.fire, 'N') <> 'Y'
  AND NOT (c.cdescr_tsv @@ q.tsq)          -- explicitly NOT a lexical match
ORDER BY c.cdescr_vec <=> q.qv
LIMIT 10;


\echo ''
\echo '############################################################'
\echo '#  STEP 2 — The plan                                        #'
\echo '############################################################'
\echo ''
\echo '-- Point at the Bitmap Index Scan on cmpl_sample_tsv_gin. One planner,'
\echo '-- one buffer cache, one transaction, one backup.'
\echo ''
\echo '-- CAVEAT, verified live: the vec arm shows a Seq Scan here, not an'
\echo '-- Index Scan on cmpl_sample_vec_hnsw. This pgvector build cannot use'
\echo '-- the HNSW index when the ORDER BY is combined with another WHERE'
\echo '-- filter (fire <> ''Y'') in the same scan -- confirmed by re-running'
\echo '-- with enable_seqscan=off: the seq scan is still chosen, disabled,'
\echo '-- because no alternative plan exists. At 50k rows this still lands'
\echo '-- in a few seconds; do not claim on stage that the HNSW index is'
\echo '-- what makes the vector arm fast here -- a full scan with a cosine'
\echo '-- distance sort is.'
\echo ''

EXPLAIN (COSTS OFF, SUMMARY OFF)
WITH q AS (
    SELECT aidb.encode_text_query(current_setting('demo.kb_model'),
               'a burning smell from the vents')::vector AS qv,
           websearch_to_tsquery('english', 'burning OR smoke OR smell') AS tsq
),
vec AS (
    SELECT c.id FROM odi.cmpl_sample c CROSS JOIN q
    WHERE c.cdescr_vec IS NOT NULL AND coalesce(c.fire,'N') <> 'Y'
    ORDER BY c.cdescr_vec <=> q.qv LIMIT 300
),
fts AS (
    SELECT c.id FROM odi.cmpl_sample c CROSS JOIN q
    WHERE c.cdescr_tsv @@ q.tsq AND coalesce(c.fire,'N') <> 'Y' LIMIT 300
)
SELECT id FROM vec UNION SELECT id FROM fts;


\echo ''
\echo '############################################################'
\echo '#  STEP 3 — FALLBACK: pure SQL, no embeddings required      #'
\echo '############################################################'
\echo ''
\echo '-- Use this if sql/05a_hybrid_build.sql never finished, if the model'
\echo '-- will not load, or if the machine is thermally throttled. It needs'
\echo '-- ONLY the GIN index from 05a STEP 2, so it works the moment'
\echo '-- odi.cmpl_sample exists - embedded or not.'
\echo ''
\echo '-- It is also the more honest comparison: this is what a competent team'
\echo '-- WITHOUT a semantic layer would write. It finds the rows that use the'
\echo '-- words you thought of, and misses every paraphrase. Run 1b afterwards'
\echo '-- to show what it missed.'
\echo ''

SELECT
    round(ts_rank_cd(c.cdescr_tsv,
        websearch_to_tsquery('english', 'burning OR smoke OR smell OR odor'))::numeric, 5)
                                                          AS ts_score,
    c.maketxt   AS make,
    c.modeltxt  AS model,
    c.yeartxt   AS model_year,
    c.compdesc  AS component,
    c.fire      AS fire_coded,
    left(regexp_replace(c.cdescr, '\s+', ' ', 'g'), 150) AS narrative
FROM odi.cmpl_sample c
WHERE c.cdescr_tsv @@ websearch_to_tsquery('english', 'burning OR smoke OR smell OR odor')
  AND coalesce(c.fire, 'N') <> 'Y'
ORDER BY ts_score DESC
LIMIT 20;

\echo ''
\echo '-- 3b. Deepest fallback: straight off odi.cmpl, no derived table at all,'
\echo '--     in case sql/05a_hybrid_build.sql was never run. This still uses an'
\echo '--     index - sql/01_schema.sql already builds cmpl_cdescr_fts_idx as a'
\echo '--     GIN index on the expression'
\echo '--     to_tsvector(''english'', coalesce(cdescr,'''')).'
\echo ''
\echo '--     The predicate below must be written EXACTLY that way, expression'
\echo '--     and regconfig included, or the planner will not match the index'
\echo '--     and you get a 2.2M-row sequential scan on stage.'
\echo ''

SELECT
    round(ts_rank_cd(
        to_tsvector('english', coalesce(cdescr, '')),
        websearch_to_tsquery('english', 'burning OR smoke OR smell OR odor'))::numeric, 5)
                                                          AS ts_score,
    maketxt  AS make,
    modeltxt AS model,
    yeartxt  AS model_year,
    compdesc AS component,
    fire     AS fire_coded,
    left(regexp_replace(cdescr, '\s+', ' ', 'g'), 150) AS narrative
FROM odi.cmpl
WHERE to_tsvector('english', coalesce(cdescr, ''))
      @@ websearch_to_tsquery('english', 'burning OR smoke OR smell OR odor')
  AND coalesce(fire, 'N') <> 'Y'
ORDER BY ts_score DESC
LIMIT 20;

-- RISK: the ORDER BY ts_rank_cd is NOT indexable — GIN gets you the matching
-- rows fast, then the ranking sorts them all. On the full 2.2M-row file the
-- match set for these four common words is large. If it drags on the demo
-- box, drop the ORDER BY (or add `AND yeartxt = '2024'`) and say why.

\echo ''
\echo '############################################################'
\echo '#  05b_hybrid_query.sql complete                            #'
\echo '############################################################'
\echo ''
\echo '-- The line to land: PostgreSQL did relational filtering, lexical'
\echo '-- ranking, vector similarity and rank fusion in one statement, one'
\echo '-- transaction, one security model, one backup. Nothing was copied out'
\echo '-- and nothing has to be kept in sync.'
\echo ''

RESET hnsw.ef_search;
\timing off
