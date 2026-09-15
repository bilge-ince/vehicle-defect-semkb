-- =============================================================================
-- 03b_aliases.sql  —  NHTSA / Mercedes-Benz demo   (aidb 7.7.0+)
--
-- Curated semantic ALIASES, created AFTER the relationships (03a) so the demo
-- tells its story in the right order: schema -> relationships -> aliases, then
-- one fused ranked list over all three.
--
-- PREREQUISITES (in this exact order):
--   psql -f sql/03_semantic_kb.sql     -- models + create_semantic_kb('nhtsa_kb')
--   psql -f sql/03a_relationships.sql  -- relationships FIRST
--   psql -f sql/03b_aliases.sql        -- THIS FILE
--
-- (This file was split out of the original 03_semantic_kb.sql so relationships
--  land before aliases; the alias SQL itself is unchanged.)
-- =============================================================================

\set ON_ERROR_STOP off
\timing on

\set kb_name 'nhtsa_semkb'

\echo ''
\echo '############################################################'
\echo '#  STEP 1 — Idempotent cleanup of a previous run           #'
\echo '############################################################'
\echo ''

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
END
$cleanup$;

\echo ''
\echo '############################################################'
\echo '#  STEP 2 — Curated semantic aliases                        #'
\echo '############################################################'
\echo ''
\echo '-- An alias is a named, reviewed, read-only SELECT that an analyst or an'
\echo '-- agent can FIND by meaning. It is how you stop re-deriving the same'
\echo '-- three joins, and how a data steward pins the *approved* answer.'
\echo ''

-- *** TRAILING SEMICOLON: never end a query_text in `;` — execute_semantic_alias
--     wraps it as `... FROM (<sql>) AS t`. All aliases below obey this.
-- *** PARAM TYPING: every alias argument arrives as TEXT. Compare against TEXT
--     columns (all of odi.* is TEXT) or cast explicitly. Never a bare LIMIT ${n}.
-- *** The 5th positional arg is kb_name (NOT a model). Passing it is what makes
--     the alias's description embed, so semantic_kb_search(sources=>['alias'])
--     can find it. Omit it and the alias is invisible to search.

\echo ''
\echo '-- Alias 1 — complaint volume by component for a given model year'
SELECT aidb.create_semantic_alias(
    'nhtsa_complaints_by_component_and_year',
    'How many consumer complaints were filed against each vehicle component '
    'for a given model year. Use for questions about which parts or systems '
    'generate the most complaints in a particular model year.',
    $sql$
        SELECT compdesc      AS component,
               yeartxt       AS model_year,
               count(*)      AS complaint_count
        FROM   odi.cmpl
        WHERE  yeartxt = ${model_year}
          AND  compdesc IS NOT NULL
          AND  btrim(compdesc) <> ''
        GROUP BY compdesc, yeartxt
        ORDER BY complaint_count DESC
        LIMIT 25
    $sql$,
    aidb.alias_params(
        aidb.alias_param('model_year', 'string',
                         'Four-digit vehicle model year as text, e.g. 2019. '
                         'This is YEARTXT (the model year of the vehicle), '
                         'NOT the year the complaint was filed.')
    ),
    :'kb_name'
) AS alias_1;

\echo ''
\echo '-- Alias 2 — fire and crash flagged complaints by manufacturer make'
SELECT aidb.create_semantic_alias(
    'nhtsa_fire_and_crash_by_make',
    'Counts of complaints flagged as involving a vehicle fire or a crash, '
    'broken down by vehicle make, for incidents occurring on or after a given '
    'year. Use for thermal event, fire risk, burning or crash severity '
    'questions across manufacturers.',
    $sql$
        SELECT maketxt                                  AS make,
               count(*) FILTER (WHERE fire  = 'Y')      AS fire_flagged,
               count(*) FILTER (WHERE crash = 'Y')      AS crash_flagged,
               count(*)                                 AS total_complaints
        FROM   odi.cmpl
        WHERE  faildate ~ '^[0-9]{8}$'
          AND  substring(faildate FROM 1 FOR 4) >= ${since_year}
          AND  maketxt IS NOT NULL
          AND  btrim(maketxt) <> ''
        GROUP BY maketxt
        HAVING count(*) FILTER (WHERE fire = 'Y') > 0
        ORDER BY fire_flagged DESC, total_complaints DESC
        LIMIT 25
    $sql$,
    aidb.alias_params(
        aidb.alias_param('since_year', 'string',
                         'Four-digit year as text, e.g. 2015. Filters on '
                         'FAILDATE (when the failure occurred), not DATEA '
                         '(when the record was added to the file).')
    ),
    :'kb_name'
) AS alias_2;

\echo ''
\echo '-- Alias 3 — harm-weighted components for one make'
SELECT aidb.create_semantic_alias(
    'nhtsa_harm_weighted_components_for_make',
    'For a single vehicle make, rank components by reported deaths and '
    'injuries as well as raw complaint count. Use for safety severity, harm, '
    'casualty or injury-weighted questions rather than plain complaint volume.',
    $sql$
        SELECT compdesc AS component,
               count(*) AS complaints,
               sum(CASE WHEN deaths  ~ '^[0-9]+$' THEN deaths::bigint  ELSE 0 END) AS deaths,
               sum(CASE WHEN injured ~ '^[0-9]+$' THEN injured::bigint ELSE 0 END) AS injuries
        FROM   odi.cmpl
        WHERE  maketxt = upper(btrim(${make}))
          AND  compdesc IS NOT NULL
        GROUP BY compdesc
        ORDER BY deaths DESC, injuries DESC, complaints DESC
        LIMIT 25
    $sql$,
    aidb.alias_params(
        aidb.alias_param('make', 'string',
                         'Vehicle make as it appears in MAKETXT. Matched '
                         'case-insensitively. Examples: MERCEDES BENZ, BMW, FORD.')
    ),
    :'kb_name'
) AS alias_3;

\echo ''
\echo '############################################################'
\echo '#  STEP 3 — Registered aliases                              #'
\echo '############################################################'
\echo ''

SELECT name, param_count, left(description, 70) AS description
FROM aidb.get_semantic_aliases()
WHERE name LIKE 'nhtsa\_%'
ORDER BY name;

\echo ''
\echo '############################################################'
\echo '#  STEP 4 — THE PAYOFF: one ranked list, ALL THREE sources  #'
\echo '############################################################'
\echo ''
\echo '-- No sources filter => schema columns + curated aliases + the'
\echo '-- relationships from 03a, fused into a single ranked result. source_type'
\echo '-- tells you which layer each row came from. This is the whole thesis:'
\echo '-- the agent gets columns, curated SQL, AND how the tables join, together.'
\echo ''

SELECT source_type,
       entity_type,
       coalesce(object_ref,
                relation_name || coalesce('.' || column_name, '')) AS object,
       round(score::numeric, 4) AS score,
       rank
FROM aidb.semantic_kb_search(
    query_text => 'recall campaigns that resulted from vehicle defect investigations, by component',
    kb_name    => :'kb_name',
    top_k      => 10
);

\echo ''
\echo '-- Alias discovery by MEANING (nobody typed "fire"):'
SELECT object_ref,
       round(score::numeric, 4) AS score,
       rank,
       left(definition, 60) AS definition_excerpt
FROM aidb.semantic_kb_search(
    query_text => 'which brands have the most thermal events and burning smells',
    kb_name    => 'nhtsa_semkb',
    top_k      => 5,
    sources    => ARRAY['alias']
);

\echo ''
\echo '-- Execute an alias. Returns SETOF (result JSONB); expand it client-side.'
SELECT r.result ->> 'make'                        AS make,
       (r.result ->> 'fire_flagged')::bigint      AS fire_flagged,
       (r.result ->> 'crash_flagged')::bigint     AS crash_flagged,
       (r.result ->> 'total_complaints')::bigint  AS total_complaints
FROM aidb.execute_semantic_alias(
    'nhtsa_fire_and_crash_by_make',
    '{"since_year": "2015"}'::jsonb
) AS r
LIMIT 10;

\echo ''
\echo '############################################################'
\echo '#  03b_aliases.sql complete — next: sql/04_agents.sql       #'
\echo '############################################################'
\echo ''

\timing off
