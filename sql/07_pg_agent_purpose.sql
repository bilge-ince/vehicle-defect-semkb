-- =============================================================================
-- 07_pg_agent_purpose.sql  —  NHTSA / Mercedes-Benz demo   (aidb 7.7.0+)
--
-- TRACK B governance: PURPOSE ENFORCEMENT for IN-DATABASE pg-agents.
--
-- Where appendix/06_governance.sql governs the Langflow / pg-airman-mcp agents
-- (Track A) by putting each purpose behind its own LOGIN user + connection
-- string, THIS file governs AIDB in-database agents (`aidb.agent_converse`)
-- using the native 7.7.0 PURPOSE REGISTRY.
--
-- ***  ADDITIVE / NON-DESTRUCTIVE  ***
-- This file does NOT touch your existing demo flow. It leaves untouched:
--     * the KB  nhtsa_semkb  (and its aliases)
--     * the agents  nhtsa_naive  and  nhtsa_semkb_agent
-- It only ADDS new objects, all prefixed for easy teardown:
--     * KB      nhtsa_semkb_local     (local bge embedding, over schema odi)
--     * agents  nhtsa_insights_agent  and  nhtsa_reporting_agent
--     * purposes defect_analytics / safety_reporting
-- Tear the demo down with the block at the very bottom of this file.
--
-- THE MECHANISM (the whole thing, in three sentences)
--   1. `aidb.create_purpose(name, role, description)` maps a named purpose to
--      exactly one Postgres role.
--   2. An agent names a PURPOSE, not a role. At every `aidb.agent_converse`
--      call the purpose is resolved to its role and the agent's SQL tools run
--      *as that role* (an identity switch inside a contained sub-transaction).
--   3. So an agent can only ever read what its purpose's role is GRANTed. The
--      system prompt is irrelevant to this: you cannot talk a model out of a
--      missing SELECT privilege.
--
-- THE TWO LANES (mutually exclusive, by design)
--   nhtsa_insights_agent  -> purpose 'defect_analytics' -> role agent_insights_reader
--                            -> RAW schema odi (complaints incl. VIN + narrative,
--                               recalls, investigations). Deep-dive analyst.
--   nhtsa_reporting_agent -> purpose 'safety_reporting'  -> role agent_reporting
--                            -> ONLY the de-identified odi_safe.* views. Governed
--                               reporting. Physically cannot reach a VIN, a
--                               complainant location, or a complaint narrative.
--
-- WHY A SEPARATE LOCAL KB (nhtsa_semkb_local)
--   nhtsa_insights_agent's semantic_kb_search runs *as* agent_insights_reader.
--   The existing nhtsa_semkb uses an Azure OpenAI embedding whose API key lives
--   in a PUBLIC user mapping, and Postgres redacts user-mapping options from any
--   non-superuser -> the tool 401s under the restricted role. A LOCAL embedding
--   (bge-small-en-v1.5-f16, llama.cpp, in-process) has no credential, so it
--   works under any role. We build a NEW KB on it rather than rebuild yours.
--   (This is the model-credential facet of the access-control gap in
--   agent_docs/semkb-query-access-control-gap-report.md.)
--
-- RUN AS: a superuser (or a member of aidb_governance for the create_purpose
--         calls) that can also GRANT on schemas odi and odi_safe. On the live
--         box: bilge.ince.
--
-- PREREQUISITES already present on the live box:
--   * schema odi (raw) + schema odi_safe (views)  — appendix/06_governance.sql
--   * local model 'bge-small-en-v1.5-f16' (llamacpp_embeddings)
--   * chat model 'nhtsa_chat'
--   * roles agent_insights_reader / agent_reporting + login users
--     airman_insights / airman_reporting (re-asserted below, idempotently)
--
-- IDEMPOTENT: safe to run more than once.
-- =============================================================================

\set ON_ERROR_STOP off
\timing on

\echo ''
\echo '############################################################'
\echo '#  STEP 0 — Prerequisite check                             #'
\echo '############################################################'
DO $chk$
BEGIN
    IF to_regclass('odi.cmpl') IS NULL THEN
        RAISE EXCEPTION 'schema odi not found — load the dataset first';
    END IF;
    IF to_regclass('odi_safe.complaint_facts') IS NULL THEN
        RAISE EXCEPTION 'schema odi_safe not found — run appendix/06_governance.sql first';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM aidb.models WHERE name = 'bge-small-en-v1.5-f16') THEN
        RAISE EXCEPTION 'local model bge-small-en-v1.5-f16 not registered';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM aidb.models WHERE name = 'nhtsa_chat') THEN
        RAISE EXCEPTION 'chat model nhtsa_chat not registered';
    END IF;
    RAISE NOTICE 'prerequisites OK';
END
$chk$;


\echo ''
\echo '############################################################'
\echo '#  STEP 1 — Roles and login users (idempotent re-assert)    #'
\echo '############################################################'
-- One NOLOGIN functional role per purpose; one LOGIN user per role. Privileges
-- attach to the functional role, never to the person. (You already created
-- these; the block below just makes this file stand alone and re-runnable.)
DO $roles$
DECLARE r TEXT;
BEGIN
    FOREACH r IN ARRAY ARRAY['agent_insights_reader','agent_reporting'] LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
            EXECUTE format('CREATE ROLE %I NOLOGIN', r);
            RAISE NOTICE 'created functional role %', r;
        END IF;
    END LOOP;
END
$roles$;

COMMENT ON ROLE agent_insights_reader IS
    'PURPOSE defect_analytics. Deep-dive defect root-cause analysis over the RAW '
    'odi schema, including complaint narratives. The unrestricted analytics lane.';
COMMENT ON ROLE agent_reporting IS
    'PURPOSE safety_reporting. Governed aggregate reporting over odi_safe only. '
    'No individual complaint rows, no VIN, no location, no narrative — by omission.';

DO $users$
DECLARE v_user TEXT; v_role TEXT; v_pw TEXT;
BEGIN
    FOR v_user, v_role, v_pw IN
        SELECT * FROM (VALUES
            ('airman_insights',  'agent_insights_reader', 'insights_secret_pw'),
            ('airman_reporting', 'agent_reporting',       'reporting_secret_pw')
        ) AS t(u,r,p)
    LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = v_user) THEN
            EXECUTE format('CREATE USER %I WITH PASSWORD %L CONNECTION LIMIT 10', v_user, v_pw);
            RAISE NOTICE 'created login user %', v_user;
        END IF;
        -- INHERIT (default) so the login user picks up the functional role's grants.
        EXECUTE format('GRANT %I TO %I', v_role, v_user);
    END LOOP;
END
$users$;


\echo ''
\echo '############################################################'
\echo '#  STEP 2 — Let the roles use the AIDB tool surface         #'
\echo '############################################################'
-- run_sql_query and semantic_kb_search are aidb.* functions invoked *as* the
-- purpose role. That role therefore needs EXECUTE on them — i.e. aidb_users
-- membership. It grants no data access on its own.
GRANT aidb_users TO agent_insights_reader, agent_reporting;


\echo ''
\echo '############################################################'
\echo '#  STEP 3 — The two data lanes (mutually exclusive)         #'
\echo '############################################################'

-- --- INSIGHTS lane: RAW odi (and nothing in odi_safe) -----------------------
GRANT USAGE ON SCHEMA odi TO agent_insights_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA odi TO agent_insights_reader;
ALTER DEFAULT PRIVILEGES IN SCHEMA odi GRANT SELECT ON TABLES TO agent_insights_reader;

-- --- REPORTING lane: de-identified odi_safe views ONLY (no odi) -------------
-- The odi_safe views run with their OWNER's privileges (NOT security_invoker),
-- which is what lets agent_reporting read aggregates without any privilege on
-- odi.cmpl. See appendix/06_governance.sql STEP 4 for the full rationale.
GRANT USAGE ON SCHEMA odi_safe TO agent_reporting;
GRANT SELECT ON ALL TABLES IN SCHEMA odi_safe TO agent_reporting;
ALTER DEFAULT PRIVILEGES IN SCHEMA odi_safe GRANT SELECT ON TABLES TO agent_reporting;

-- Belt-and-braces: the reporting lane must never reach the raw schema.
REVOKE ALL ON SCHEMA odi FROM agent_reporting;
REVOKE ALL ON ALL TABLES IN SCHEMA odi FROM agent_reporting;


\echo ''
\echo '############################################################'
\echo '#  STEP 4 — A NEW local-embedding KB for the insights lane  #'
\echo '############################################################'
-- Additive: builds nhtsa_semkb_local on the local bge model, leaving your
-- existing nhtsa_semkb (and its aliases) completely untouched. Only schema
-- METADATA is embedded (3 tables + ~91 columns), not the 2.2M rows.
-- auto_processing = Disabled so it adds NO DDL triggers to schema odi; we
-- refresh it once by hand. (Schema metadata is static for the demo.)
DO $kb$
BEGIN
    IF EXISTS (SELECT 1 FROM aidb.list_semantic_kbs() WHERE name = 'nhtsa_semkb_local') THEN
        PERFORM aidb.delete_semantic_kb('nhtsa_semkb_local');
        RAISE NOTICE 're-building nhtsa_semkb_local';
    END IF;
END
$kb$;

SELECT aidb.create_semantic_kb('nhtsa_semkb_local', 'bge-small-en-v1.5-f16', ARRAY['odi'], 'Disabled');
SELECT aidb.refresh_semantic_kb('nhtsa_semkb_local');

-- The insights role must READ this KB's metadata (semantic_kb_search runs as
-- it). Narrow on purpose: only this KB's tables, NOT all of aidb_internal
-- (which also holds agent memory, OTel and the purpose registry itself).
GRANT USAGE ON SCHEMA aidb_internal TO agent_insights_reader;
GRANT SELECT ON aidb_internal.semantic_knowledge_bases,
                aidb_internal.semantic_kb_state,
                aidb_internal.schema_metadata_nhtsa_semkb_local
  TO agent_insights_reader;


\echo ''
\echo '############################################################'
\echo '#  STEP 5 — Register the two purposes                       #'
\echo '############################################################'
-- name -> role -> human-readable scope. Only aidb_governance (or a superuser)
-- may write here; the description is documentation, not an enforced filter —
-- the enforcement is the GRANTs in STEP 3.
SELECT aidb.create_purpose(
    'defect_analytics',
    'agent_insights_reader',
    'Engineering defect root-cause analysis over the raw NHTSA odi schema '
    '(complaints incl. narratives, recalls, investigations). Deep-dive analyst lane.');

SELECT aidb.create_purpose(
    'safety_reporting',
    'agent_reporting',
    'Governed aggregate safety reporting over the de-identified odi_safe views. '
    'No individual complaint records, VINs, locations or narratives.');


\echo ''
\echo '############################################################'
\echo '#  STEP 6 — Create the two NEW purpose-bound agents         #'
\echo '############################################################'
-- New agents (your nhtsa_naive / nhtsa_semkb_agent are left as-is). Re-runnable:
-- if the agent already exists we update it in place, otherwise we create it.

-- --- INSIGHTS agent: semkb-first over the local KB, raw odi ------------------
DO $ins$
DECLARE
    v_instr TEXT := $INS$You are the DEFECT ANALYTICS agent for NHTSA vehicle-defect data in PostgreSQL schema "odi"
(odi.cmpl = consumer complaints incl. the free-text narrative cdescr; odi.rcl = recalls; odi.inv = investigations).
Never infer a column's meaning from its name. DISCOVER first, before writing any SQL:
call semantic_kb_search(query_text => <the user's question>, kb_name => 'nhtsa_semkb_local', top_k => 20,
sources => ARRAY['schema']). Use the returned tables and columns to write correct PostgreSQL.
Before filtering any text column, find the exact stored literal first:
SELECT DISTINCT <col> FROM odi.<table> WHERE <col> ILIKE '%<term>%' LIMIT 20 -- e.g. airbags are stored as 'AIR BAGS'.
Prefer the structured/coded column the KB identifies over scanning the narrative; use cdescr only when no
structured column captures the concept. Run the SQL with run_sql_query.
Answer the user's question directly and state the SQL you used.$INS$;
BEGIN
    IF EXISTS (SELECT 1 FROM aidb.agents WHERE name = 'nhtsa_insights_agent') THEN
        PERFORM aidb.update_agent('nhtsa_insights_agent', instructions => v_instr, purpose => 'defect_analytics');
        RAISE NOTICE 'updated agent nhtsa_insights_agent';
    ELSE
        PERFORM aidb.create_agent('nhtsa_insights_agent', v_instr, 'nhtsa_chat',
            ARRAY['semantic_kb_search','run_sql_query'], NULL, 'defect_analytics',
            NULL, NULL, NULL, 8, 240);
        RAISE NOTICE 'created agent nhtsa_insights_agent';
    END IF;
END
$ins$;

-- --- REPORTING agent: odi_safe only, refuses raw/PII -------------------------
DO $rep$
DECLARE
    v_instr TEXT := $INS$You are the SAFETY REPORTING agent. Your purpose is governed, aggregate safety reporting for NHTSA vehicle-defect data.
You may ONLY use the curated, de-identified views in PostgreSQL schema "odi_safe":
- odi_safe.complaints_by_make_year(make, model_year, complaint_count, fire_count, crash_count, earliest_failure, latest_failure)
- odi_safe.complaints_by_component_year(component, model_year, complaint_count, fire_count, crash_count, total_injured, total_killed)
- odi_safe.exec_defect_kpi(make, model_year, component, complaint_count, fire_count, crash_count, total_injured, total_killed, fire_rate_pct)
- odi_safe.recall_summary(...), odi_safe.investigation_summary(...), odi_safe.recall_to_complaint_link(...)
- odi_safe.complaint_facts (aggregate-safe: make/model/component/dates/counts and narrative_length ONLY; NO VIN, city, state, or narrative text)
Use run_sql_query with standard PostgreSQL SELECT statements against odi_safe.
Your purpose FORBIDS access to individual complaint records or personal data. If asked for a VIN, a complainant's
city/state, an individual complaint narrative (cdescr), or any row-level personal detail, DO NOT attempt it:
explain that your reporting purpose only permits governed aggregates and that raw complaint detail is out of scope.
The raw "odi" schema is not accessible to you by design.
Answer directly and state the SQL you used.$INS$;
BEGIN
    IF EXISTS (SELECT 1 FROM aidb.agents WHERE name = 'nhtsa_reporting_agent') THEN
        PERFORM aidb.update_agent('nhtsa_reporting_agent', instructions => v_instr, purpose => 'safety_reporting');
        RAISE NOTICE 'updated agent nhtsa_reporting_agent';
    ELSE
        PERFORM aidb.create_agent('nhtsa_reporting_agent', v_instr, 'nhtsa_chat',
            ARRAY['run_sql_query'], NULL, 'safety_reporting',
            NULL, NULL, NULL, 8, 120);
        RAISE NOTICE 'created agent nhtsa_reporting_agent';
    END IF;
END
$rep$;


\echo ''
\echo '############################################################'
\echo '#  STEP 7 — Verification (read-only)                        #'
\echo '############################################################'
\echo ''
\echo '-- Purpose registry:'
SELECT name, role, left(description, 60) AS description FROM aidb.purpose_registry ORDER BY name;

\echo ''
\echo '-- The NEW agents and their purpose bindings (existing agents untouched):'
SELECT name, purpose, tools FROM aidb.agents
WHERE name IN ('nhtsa_insights_agent','nhtsa_reporting_agent') ORDER BY name;

\echo ''
\echo '-- Existing demo objects, confirmed UNCHANGED:'
SELECT name, model_name FROM aidb.list_semantic_kbs() WHERE name = 'nhtsa_semkb';           -- still my_embeddings_model
SELECT name, coalesce(purpose,'<none>') AS purpose FROM aidb.agents
WHERE name IN ('nhtsa_naive','nhtsa_semkb_agent') ORDER BY name;                            -- still <none>

\echo ''
\echo '-- The cross-lane membership gate (stops a reporting user borrowing the'
\echo '-- insights agent, and vice-versa):'
SELECT pg_has_role('airman_reporting','agent_insights_reader','MEMBER') AS reporting_user_can_be_insights,
       pg_has_role('airman_insights', 'agent_reporting',      'MEMBER') AS insights_user_can_be_reporting;
--   expect: f | f

\echo ''
\echo '-- The grant matrix, evaluated as superuser (has_*_privilege takes the role'
\echo '-- as its first argument, so no SET ROLE is needed — and referencing odi.cmpl'
\echo '-- under a role that lacks USAGE on odi would raise, not return false):'
SELECT has_schema_privilege('agent_reporting','odi','USAGE')             AS reporting_usage_on_odi,       -- expect f
       has_table_privilege ('agent_reporting','odi.cmpl','SELECT')       AS reporting_select_on_cmpl,     -- expect f
       has_schema_privilege('agent_reporting','odi_safe','USAGE')        AS reporting_usage_on_odi_safe,  -- expect t
       has_table_privilege ('agent_insights_reader','odi.cmpl','SELECT') AS insights_select_on_cmpl;      -- expect t

\echo ''
\echo 'SETUP COMPLETE. Drive the demo from runbooks/PG_AGENT_PURPOSE_DEMO.md'


-- =============================================================================
-- TEARDOWN (removes ONLY what this file added; leaves your demo flow intact)
-- Uncomment and run to reset.
-- =============================================================================
-- SELECT aidb.delete_agent('nhtsa_insights_agent', true);
-- SELECT aidb.delete_agent('nhtsa_reporting_agent', true);
-- SELECT aidb.delete_semantic_kb('nhtsa_semkb_local');
-- SELECT aidb.delete_purpose('defect_analytics');   -- fails if an agent still references it
-- SELECT aidb.delete_purpose('safety_reporting');
-- REVOKE USAGE, SELECT ON ALL TABLES IN SCHEMA odi      FROM agent_insights_reader;
-- REVOKE USAGE ON SCHEMA odi                             FROM agent_insights_reader;
-- REVOKE USAGE, SELECT ON ALL TABLES IN SCHEMA odi_safe FROM agent_reporting;
-- REVOKE USAGE ON SCHEMA odi_safe                        FROM agent_reporting;
