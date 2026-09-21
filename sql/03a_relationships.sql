-- =============================================================================
-- 03a_relationships.sql  —  NHTSA / Mercedes-Benz demo   (aidb 7.7.0+)
--
-- THE HEADLINE OF THIS DEMO. Populate the semantic RELATIONSHIPS the schema
-- never declared, THEN show that aidb.semantic_kb_search returns them by
-- meaning alongside schema columns and curated aliases.
--
-- PREREQUISITES (in this exact order):
--   psql -f sql/01_schema.sql          -- DDL (already loaded on this box)
--   psql -f sql/02_comments.sql        -- COMMENT ON (already loaded)
--   psql -f sql/03_semantic_kb.sql     -- models + create_semantic_kb('nhtsa_kb')
--   psql -f sql/03a_relationships.sql  -- THIS FILE  (relationships FIRST)
--   psql -f sql/03b_aliases.sql        -- curated aliases (AFTER relationships)
--
-- WHY THIS FILE EXISTS AT ALL — the whole point:
--   create_semantic_kb() auto-crawls relationships, but ONLY from declared
--   FOREIGN KEYS (src/pipeline_common/semantic_kb/relationship_crawl.rs — "turns
--   what pg_constraint already knows into relationship rows"). The NHTSA flat
--   files have NO foreign keys (README: "no foreign keys"), so the crawl finds
--   nothing. semantic_kb_stats('nhtsa_kb') shows relationships = 0 right after
--   creation. That is not a bug — it is the setup. The joins that matter here
--   live only in the publisher's data dictionary and in analysts' heads. We
--   make them first-class, embedded, retrievable objects with add_relationship.
-- =============================================================================

\set ON_ERROR_STOP off
\timing on

\set kb_name 'nhtsa_semkb'
SELECT set_config('demo.kb_name', :'kb_name', false) AS demo_kb_name;

\echo ''
\echo '############################################################'
\echo '#  STEP 0 — Prove the crawl found NOTHING (no FKs)          #'
\echo '############################################################'
\echo ''
\echo '-- semantic_kb_stats now returns relationship/drift/query counts too.'
\echo '-- relationships should be 0 here: odi has no foreign keys to crawl.'
\echo ''

SELECT total, tables, views, columns, pending, relationships, drifted, queries
FROM aidb.semantic_kb_stats(:'kb_name');

\echo ''
\echo '############################################################'
\echo '#  STEP 1 — Idempotent cleanup of a previous run           #'
\echo '############################################################'
\echo ''

-- add_relationship UPSERTs on structural identity, but delete first so a re-run
-- from a clean slate reports action = "inserted" (nicer on stage) and so a
-- changed predicate/description is never masked by an existing row.
DO $cleanup$
DECLARE
    r RECORD;
    n INT := 0;
BEGIN
    FOR r IN SELECT relationship_id
             FROM aidb.list_relationships(current_setting('demo.kb_name'))
             WHERE source = 'manual'
    LOOP
        PERFORM aidb.delete_relationship(current_setting('demo.kb_name'),
                                         relationship_id => r.relationship_id);
        n := n + 1;
    END LOOP;
    IF n > 0 THEN
        RAISE NOTICE 'dropped % stale manual relationship(s)', n;
    END IF;
EXCEPTION WHEN OTHERS THEN
    NULL;  -- no KB / no rows yet — fine
END
$cleanup$;

\echo ''
\echo '############################################################'
\echo '#  STEP 2 — Author the relationships the schema never had   #'
\echo '############################################################'
\echo ''
\echo '-- add_relationship(kb_name, left_object, right_object, kind, predicate,'
\echo '--                  left_columns, right_columns, ...). For kind => key_join'
\echo '-- the join_expr is RENDERED by aidb from the column lists — never supplied'
\echo '-- by the caller — so an agent cannot launder a guess into the ON clause.'
\echo '-- source defaults to ''manual'' (a human curated this); the agent tool path'
\echo '-- (add_relationship_as_agent) stamps source => ''agent'' instead.'
\echo ''

-- ---------------------------------------------------------------------------
-- Relationship 1 — THE canonical one. An ODI investigation that resulted in a
-- recall shares its campaign number. This join is documented in the odi.inv
-- table comment ("CAMPNO, where present, identifies the recall campaign that
-- resulted from the investigation and joins to odi.rcl.campno") but exists
-- NOWHERE in the physical schema. No model can infer it from column names.
-- ---------------------------------------------------------------------------
\echo '-- R1: odi.inv  -->  odi.rcl   ON campno'
SELECT relationship_id, kind, source, status, action, join_expr
FROM aidb.add_relationship(
    kb_name         => :'kb_name',
    left_object     => 'odi.inv',
    right_object    => 'odi.rcl',
    kind            => 'key_join',
    predicate       => 'resulted in the recall campaign',
    left_columns    => ARRAY['campno'],
    right_columns   => ARRAY['campno'],
    inverse_predicate => 'was opened as the investigation behind',
    cardinality     => 'many-to-many',
    is_nullable     => true,
    description      =>
        'An ODI safety-defect investigation (odi.inv) is linked to the recall '
        'campaign (odi.rcl) it produced through the shared NHTSA campaign number '
        'CAMPNO. Use this to answer questions that connect an investigation to '
        'its resulting recall, e.g. which investigations led to recalls and for '
        'what component. Not every investigation ends in a recall, so CAMPNO on '
        'odi.inv may be blank.',
    curated_label    => 'investigation → recall (CAMPNO)'
);

-- ---------------------------------------------------------------------------
-- Relationship 2 — a SEMANTIC join no FK could ever express: complaints and
-- recalls about the same physical vehicle, matched on make/model/year.
-- ---------------------------------------------------------------------------
\echo '-- R2: odi.cmpl -->  odi.rcl   ON (maketxt, modeltxt, yeartxt)'
SELECT relationship_id, kind, source, status, action, join_expr
FROM aidb.add_relationship(
    kb_name         => :'kb_name',
    left_object     => 'odi.cmpl',
    right_object    => 'odi.rcl',
    kind            => 'key_join',
    predicate       => 'concerns the same make/model/year as the recall',
    left_columns    => ARRAY['maketxt', 'modeltxt', 'yeartxt'],
    right_columns   => ARRAY['maketxt', 'modeltxt', 'yeartxt'],
    inverse_predicate => 'is the recall covering the vehicle complained about in',
    cardinality     => 'many-to-many',
    is_nullable     => true,
    description      =>
        'A consumer complaint (odi.cmpl) and a recall campaign (odi.rcl) describe '
        'the same vehicle when their make, model and model year agree. Use this '
        'to correlate what owners complain about with what manufacturers recall '
        'for a given make/model/year. There is no key relating the two tables in '
        'the schema; this correlation is by vehicle identity only.',
    curated_label    => 'complaint ↔ recall (same vehicle)'
);

-- ---------------------------------------------------------------------------
-- Relationship 3 — the SAME vehicle-identity join, but across tables whose
-- columns are spelled DIFFERENTLY on each side (cmpl.maketxt vs inv.make).
-- This is exactly the case a name-matching heuristic gets wrong and a curated
-- relationship gets right.
-- ---------------------------------------------------------------------------
\echo '-- R3: odi.cmpl -->  odi.inv   ON (maketxt,modeltxt,yeartxt) = (make,model,year)'
SELECT relationship_id, kind, source, status, action, join_expr
FROM aidb.add_relationship(
    kb_name         => :'kb_name',
    left_object     => 'odi.cmpl',
    right_object    => 'odi.inv',
    kind            => 'key_join',
    predicate       => 'may relate to the investigation of the same vehicle',
    left_columns    => ARRAY['maketxt', 'modeltxt', 'yeartxt'],
    right_columns   => ARRAY['make', 'model', 'year'],
    inverse_predicate => 'is the investigation of the vehicle complained about in',
    cardinality     => 'many-to-many',
    is_nullable     => true,
    description      =>
        'Consumer complaints (odi.cmpl) and ODI investigations (odi.inv) about the '
        'same vehicle are matched on make/model/year — but the columns are named '
        'differently on each side: cmpl.maketxt/modeltxt/yeartxt versus '
        'inv.make/model/year. Use this when a question spans complaints and '
        'investigations for the same vehicle.',
    curated_label    => 'complaint ↔ investigation (same vehicle)'
);

\echo ''
\echo '############################################################'
\echo '#  STEP 3 — Browse what we just recorded                    #'
\echo '############################################################'
\echo ''

SELECT relationship_id,
       left_object, left_columns, right_object, right_columns,
       kind, source, status, round(confidence::numeric, 2) AS conf,
       curated_label
FROM aidb.list_relationships(:'kb_name')
ORDER BY relationship_id;

\echo ''
\echo '-- semantic_kb_stats again: relationships is now 3 (still 0 pending).'
SELECT total, columns, relationships, drifted, queries
FROM aidb.semantic_kb_stats(:'kb_name');

\echo ''
\echo '############################################################'
\echo '#  STEP 4 — Retrieve a relationship BY MEANING              #'
\echo '############################################################'
\echo ''
\echo '-- Nobody typed "campno" or "investigation". The relationship is embedded'
\echo '-- (its description_vector), so it is found the same way a column is.'
\echo '-- entity_type = ''Relationship''; object_ref renders "left -> right [kind]".'
\echo ''

SELECT source_type,
       entity_type,
       object_ref,
       round(score::numeric, 4) AS score,
       rank,
       left(definition, 80) AS definition_excerpt
FROM aidb.semantic_kb_search(
    query_text => 'which safety investigations led to a recall being issued',
    kb_name    => :'kb_name',
    top_k      => 5,
    sources    => ARRAY['relationship']
);

\echo ''
\echo '############################################################'
\echo '#  STEP 5 — Ask HOW to join two tables (routes)             #'
\echo '############################################################'
\echo ''
\echo '-- find_join_path returns ranked routes with a ready-to-use ON clause,'
\echo '-- built from the curated relationships — not guessed from column names.'
\echo ''

SELECT path_rank, hops, route, kind,
       round(confidence::numeric, 2) AS conf,
       join_clause
FROM aidb.find_join_path(:'kb_name', 'odi.inv', 'odi.rcl')
ORDER BY path_rank;

\echo ''
\echo '-- suggest_joins: every one-hop join available from odi.cmpl, both ways.'
\echo ''

SELECT from_object, to_object, kind, predicate,
       round(confidence::numeric, 2) AS conf, join_expr
FROM aidb.suggest_joins(:'kb_name', ARRAY['odi.cmpl']);

\echo ''
\echo '-- semantic_kb_subgraph: the neighbourhood of tables a question touches.'
\echo ''

SELECT hop, from_object, to_object, kind, predicate
FROM aidb.semantic_kb_subgraph(
    :'kb_name',
    'recalls and investigations for a vehicle make',
    top_k    => 5,
    max_hops => 2
);

\echo ''
\echo '############################################################'
\echo '#  03a_relationships.sql complete                           #'
\echo '#  Next: sql/03b_aliases.sql, then sql/04_agents.sql        #'
\echo '############################################################'
\echo ''

\timing off
