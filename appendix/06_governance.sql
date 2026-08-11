-- =============================================================================
-- 06_governance.sql  —  NHTSA / Mercedes-Benz demo
--
-- TRACK A governance (Langflow + pg-airman-mcp), ported from the Olist demo to
-- the NHTSA dataset.
--
-- THE ARGUMENT
--   An agent's permissions are not a system-prompt instruction. They are
--   PostgreSQL grants. The prompt-injection beat in Act 4 does not work
--   because the model is well-behaved; it works because the role the agent
--   connects as has no SELECT privilege on odi.cmpl.vin. The LLM cannot be
--   talked out of a grant.
--
-- THE PATTERN
--   ONE AGENT PURPOSE <-> ONE NOLOGIN FUNCTIONAL ROLE <-> ONE LOGIN USER.
--   Privileges attach to the purpose, never to a person and never to an
--   application. Rotating an agent's credentials touches only the LOGIN user;
--   changing what a purpose may see touches only the functional role.
--
-- This file is ordinary PostgreSQL. No AIDB API is required — deliberately.
-- Governance that depends on the AI extension is governance the security team
-- has to review twice.
--
-- RUN AS: a superuser or the owner of schema odi.
-- =============================================================================

\set ON_ERROR_STOP off

-- =============================================================================
--  PERMISSION MATRIX  (the whole security model, on one screen)
-- =============================================================================
--
--  Object                                  | defect-   | recall-    | executive-
--                                          | analytics | compliance | reporting
--  ----------------------------------------+-----------+------------+-----------
--  odi.cmpl                     (RAW)      |     -     |     -      |     -
--  odi.rcl                      (RAW)      |     -     |     -      |     -
--  odi.inv                      (RAW)      |     -     |     -      |     -
--  odi.cmpl_sample              (RAW)      |     -     |     -      |     -
--  ----------------------------------------+-----------+------------+-----------
--  odi_safe.complaint_facts                |  SELECT   |   SELECT   |     -
--  odi_safe.complaints_by_component_year   |  SELECT   |     -      |     -
--  odi_safe.complaints_by_make_year        |  SELECT   |     -      |     -
--  odi_safe.recall_summary                 |     -     |   SELECT   |     -
--  odi_safe.investigation_summary          |     -     |   SELECT   |     -
--  odi_safe.recall_to_complaint_link       |     -     |   SELECT   |     -
--  odi_safe.exec_defect_kpi     (CERTIFIED)|     -     |     -      |  SELECT
--  ----------------------------------------+-----------+------------+-----------
--  agent_outputs.agent_reports             |     -     |     -      |  SELECT
--                                          |           |            |  INSERT
--  ----------------------------------------+-----------+------------+-----------
--  SCHEMA odi                   USAGE      |     -     |     -      |     -
--  SCHEMA odi_safe              USAGE      |    yes    |    yes     |    yes
--  SCHEMA agent_outputs         USAGE      |     -     |     -      |    yes
--  SCHEMA public                CREATE     |     -     |     -      |     -
--
--  COLUMNS THAT NO AGENT ROLE CAN REACH BY ANY PATH:
--      odi.cmpl.vin            field 15; personally identifiable via DMV records
--      odi.cmpl.cdescr         free-text narrative; complainants routinely
--                              type their own name, address and phone number
--                              into it. This is the highest-risk column in
--                              the dataset and the one an LLM most wants.
--      odi.cmpl.dealer_name    \
--      odi.cmpl.dealer_tel     |  named commercial third parties, defamation
--      odi.cmpl.dealer_city    |  and contract-liability exposure
--      odi.cmpl.dealer_state   |
--      odi.cmpl.dealer_zip     /
--      odi.cmpl.city           complainant location (field 13)
--      odi.cmpl.state          complainant location (field 14)
--      odi.cmpl.state_of_incident   added by NHTSA 2026-04-30 (field 50)
--      odi.cmpl.vehicle_operator    added by NHTSA 2026-04-30 (field 51)
--
--  (Field numbers are from sql/01_schema.sql, which mirrors the flat-file
--   field order. odi.cmpl is 51 columns, not the widely-quoted 49.)
--
--  ENFORCEMENT: DENY BY OMISSION. Those columns are not excluded by a rule
--  the agent could be argued out of — they are simply absent from every
--  object the role can name. There is no query that produces them.
-- =============================================================================


\echo ''
\echo '############################################################'
\echo '#  STEP 1 — Purpose-scoped functional roles (NOLOGIN)       #'
\echo '############################################################'
\echo ''

-- CREATE ROLE has no IF NOT EXISTS, so each is guarded. Idempotent.
DO $roles$
DECLARE
    r TEXT;
BEGIN
    FOREACH r IN ARRAY ARRAY[
        'nhtsa_defect_analytics',
        'nhtsa_recall_compliance',
        'nhtsa_exec_reporting'
    ] LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
            EXECUTE format('CREATE ROLE %I NOLOGIN', r);
            RAISE NOTICE 'created functional role %', r;
        ELSE
            RAISE NOTICE 'functional role % already exists', r;
        END IF;
    END LOOP;
END
$roles$;

COMMENT ON ROLE nhtsa_defect_analytics IS
    'PURPOSE: defect-analytics. Complaint trend analysis over de-identified '
    'aggregates. No VIN, no narrative, no dealer, no complainant location.';
COMMENT ON ROLE nhtsa_recall_compliance IS
    'PURPOSE: recall-compliance. Recall and investigation lifecycle tracking, '
    'plus the complaint facts needed to link a recall to its complaints.';
COMMENT ON ROLE nhtsa_exec_reporting IS
    'PURPOSE: executive-reporting. Certified aggregate KPIs only, plus INSERT '
    'into agent_outputs.agent_reports. Cannot reach any complaint-level row.';


\echo ''
\echo '############################################################'
\echo '#  STEP 2 — LOGIN users, one per agent purpose              #'
\echo '############################################################'
\echo ''
\echo '-- These are the credentials that go into the Langflow / pg-airman-mcp'
\echo '-- connection strings. One per purpose. Never one shared "agent" user -'
\echo '-- that collapses the whole model back into a single blast radius.'
\echo ''

-- *** RISK: passwords in a script file. ***
-- These are demo passwords on a throwaway box. For anything real, use SCRAM
-- with a password supplied out of band, or better, `CREATE ROLE ... LOGIN`
-- with no password and a pg_hba.conf `cert` / `peer` method. Do not copy
-- these literals into a customer environment.
-- Loop variables are v_-prefixed and the VALUES aliases are not: PL/pgSQL
-- substitutes declared variable names into the query text, so a variable
-- named `u` alongside a column named `u` is a genuine ambiguity trap.
DO $users$
DECLARE
    v_user TEXT;
    v_role TEXT;
    v_pw   TEXT;
BEGIN
    FOR v_user, v_role, v_pw IN
        SELECT t.login_user, t.func_role, t.pw
        FROM (VALUES
            ('agent_defect_analytics', 'nhtsa_defect_analytics',  'demo_defect_pw'),
            ('agent_recall_compliance','nhtsa_recall_compliance', 'demo_recall_pw'),
            ('agent_exec_reporting',   'nhtsa_exec_reporting',    'demo_exec_pw')
        ) AS t(login_user, func_role, pw)
    LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = v_user) THEN
            EXECUTE format('CREATE ROLE %I LOGIN PASSWORD %L', v_user, v_pw);
            RAISE NOTICE 'created login user %', v_user;
        ELSE
            RAISE NOTICE 'login user % already exists', v_user;
        END IF;

        -- INHERIT (the default) means the user picks up the functional role's
        -- privileges without an explicit SET ROLE. That is what makes the
        -- connection string alone sufficient for the MCP server.
        EXECUTE format('GRANT %I TO %I', v_role, v_user);

        -- No object creation anywhere, ever. pg_catalog is pinned last so the
        -- role cannot shadow a built-in with something it created (it can't
        -- create anything, but defence in depth costs nothing here).
        EXECUTE format(
            'ALTER ROLE %I SET search_path = odi_safe, agent_outputs, pg_catalog', v_user);
    END LOOP;
END
$users$;

-- Every role in this file is denied the public schema outright. Without this,
-- PG < 15 lets any role CREATE in public — which is a writable staging area
-- an injected agent would happily use.
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
REVOKE ALL ON SCHEMA public FROM nhtsa_defect_analytics,
                                 nhtsa_recall_compliance,
                                 nhtsa_exec_reporting;


\echo ''
\echo '############################################################'
\echo '#  STEP 3 — Lock the raw schema down                        #'
\echo '############################################################'
\echo ''
\echo '-- This is the load-bearing statement of the entire demo.'
\echo ''

-- Belt: nobody gets into schema odi at all. Without USAGE on the schema, no
-- grant on any table inside it can be exercised, however it was acquired.
REVOKE ALL ON SCHEMA odi FROM PUBLIC;
REVOKE ALL ON SCHEMA odi FROM nhtsa_defect_analytics,
                              nhtsa_recall_compliance,
                              nhtsa_exec_reporting;

-- Braces: and no table privileges either, current or future.
REVOKE ALL ON ALL TABLES IN SCHEMA odi FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA odi FROM nhtsa_defect_analytics,
                                            nhtsa_recall_compliance,
                                            nhtsa_exec_reporting;

-- And a table added to odi tomorrow is denied by default, not by someone
-- remembering to run a REVOKE. This is the clause auditors ask about.
--
-- CAVEAT, state it if asked: ALTER DEFAULT PRIVILEGES applies only to objects
-- created BY THE ROLE THAT RUNS THIS STATEMENT (or by the role named in a FOR
-- ROLE clause). If the nightly loader connects as a different user, repeat
-- this with FOR ROLE <loader> — otherwise the guarantee has a hole in it.
ALTER DEFAULT PRIVILEGES IN SCHEMA odi
    REVOKE ALL ON TABLES FROM PUBLIC;

\echo '-- Belt, braces, and a default-privileges rule for tables not yet created.'


\echo ''
\echo '############################################################'
\echo '#  STEP 4 — Purpose-scoped views                            #'
\echo '############################################################'
\echo ''

CREATE SCHEMA IF NOT EXISTS odi_safe;
COMMENT ON SCHEMA odi_safe IS
    'Purpose-scoped, de-identified projections of schema odi. The only schema '
    'any agent role can reach. Views are owned by the odi owner and run with '
    'the OWNER''s privileges, which is what lets a grantee read through them '
    'without any privilege on the base tables.';

-- ===========================================================================
-- *** DO NOT SET security_invoker = true ON THESE VIEWS. ***
-- A plain view executes against its base tables with the VIEW OWNER's
-- privileges. That indirection is precisely the mechanism doing the work
-- here: nhtsa_defect_analytics has zero privilege on odi.cmpl, yet can read
-- odi_safe.complaint_facts. Turning on security_invoker (PG15+) would push
-- the check down to the caller and every view below would start failing with
-- "permission denied for table cmpl". If someone in the room asks "isn't
-- security_invoker the safer default?" — yes, generally, and no, not for this
-- pattern.
-- ===========================================================================

---------------------------------------------------------------------------
-- 4a. defect-analytics
---------------------------------------------------------------------------

-- Complaint-level facts with EVERY identifying column removed. Note what is
-- absent: vin, cdescr, dealer_*, city, state, zip.
CREATE OR REPLACE VIEW odi_safe.complaint_facts AS
SELECT
    c.cmplid                                             AS complaint_id,
    c.odino                                              AS odi_number,
    c.mfr_name                                           AS manufacturer,
    c.maketxt                                            AS make,
    c.modeltxt                                           AS model,
    c.yeartxt                                            AS model_year,
    c.compdesc                                           AS component,
    c.prod_type                                          AS product_type,
    c.cmpl_type                                          AS complaint_type,
    c.orig_equip_yn                                      AS original_equipment,
    -- Dates are TEXT YYYYMMDD in the source. Exposed as real dates here, and
    -- renamed to what they MEAN. The semantic layer disambiguates them for a
    -- model; this view disambiguates them for a human.
    to_date(nullif(c.faildate,''), 'YYYYMMDD')           AS date_failure_occurred,
    to_date(nullif(c.datea,''),    'YYYYMMDD')           AS date_added_to_file,
    -- NHTSA's dictionary, field 17: "Date complaint received by NHTSA".
    -- NOT a last-modified timestamp - do not rename it back.
    to_date(nullif(c.ldate,''),    'YYYYMMDD')           AS date_received_by_nhtsa,
    (c.fire  = 'Y')                                      AS fire_reported,
    (c.crash = 'Y')                                      AS crash_reported,
    CASE WHEN c.injured ~ '^[0-9]+$' THEN c.injured::int ELSE 0 END AS persons_injured,
    CASE WHEN c.deaths  ~ '^[0-9]+$' THEN c.deaths::int  ELSE 0 END AS persons_killed,
    -- The narrative itself is NOT exposed. Its LENGTH is, because "was there
    -- a detailed description?" is a legitimate analytic question and a
    -- character count leaks nothing.
    length(coalesce(c.cdescr, ''))                       AS narrative_length
FROM odi.cmpl c;

COMMENT ON VIEW odi_safe.complaint_facts IS
    'De-identified complaint-level facts. Excludes VIN, the CDESCR narrative, '
    'all DEALER_* columns and complainant city/state/zip. Dates are parsed '
    'and renamed by meaning.';

CREATE OR REPLACE VIEW odi_safe.complaints_by_component_year AS
SELECT
    component,
    model_year,
    count(*)                                   AS complaint_count,
    count(*) FILTER (WHERE fire_reported)      AS fire_count,
    count(*) FILTER (WHERE crash_reported)     AS crash_count,
    sum(persons_injured)                       AS total_injured,
    sum(persons_killed)                        AS total_killed
FROM odi_safe.complaint_facts
WHERE component IS NOT NULL
GROUP BY component, model_year;

CREATE OR REPLACE VIEW odi_safe.complaints_by_make_year AS
SELECT
    make,
    model_year,
    count(*)                                   AS complaint_count,
    count(*) FILTER (WHERE fire_reported)      AS fire_count,
    count(*) FILTER (WHERE crash_reported)     AS crash_count,
    min(date_failure_occurred)                 AS earliest_failure,
    max(date_failure_occurred)                 AS latest_failure
FROM odi_safe.complaint_facts
WHERE make IS NOT NULL
GROUP BY make, model_year;

---------------------------------------------------------------------------
-- 4b. recall-compliance
---------------------------------------------------------------------------
-- Column names below were cross-checked line by line against
-- sql/01_schema.sql (odi.rcl = 29 fields, odi.inv = 11 fields, verified
-- 2026-08-07 against the NHTSA dictionaries). Two publisher misspellings are
-- reproduced verbatim and are NOT typos here:
--     odi.rcl.conequence_defect   (missing the 's' in "consequence")
--     odi.cmpl.occurences         (one 'r'; not used in these views)
-- NHTSA adds fields periodically. If a CREATE VIEW below fails on an unknown
-- column, re-check 01_schema.sql — do not discover that on stage.

CREATE OR REPLACE VIEW odi_safe.recall_summary AS
SELECT
    r.campno                                             AS campaign_number,
    r.mfgcampno                                          AS manufacturer_campaign_number,
    r.mfgname                                            AS manufacturer,
    r.maketxt                                            AS make,
    r.modeltxt                                           AS model,
    r.yeartxt                                            AS model_year,
    r.compname                                           AS component,
    r.rcltypecd                                          AS recall_type,
    r.potaff                                             AS potentially_affected,
    to_date(nullif(r.odate,''), 'YYYYMMDD')              AS date_owner_notified,
    to_date(nullif(r.rcdate,''),'YYYYMMDD')              AS date_recall_reported,
    r.desc_defect                                        AS defect_description,
    r.conequence_defect                                  AS defect_consequence,
    r.corrective_action                                  AS corrective_action
FROM odi.rcl r;

COMMENT ON VIEW odi_safe.recall_summary IS
    'Recall campaigns. The defect/consequence/action text here is the '
    'MANUFACTURER''s own published statement, not consumer-supplied free '
    'text, so it carries no PII and is safe to expose.';

CREATE OR REPLACE VIEW odi_safe.investigation_summary AS
SELECT
    i.nhtsa_action_number                                AS action_number,
    i.make                                               AS make,
    i.model                                              AS model,
    i.year                                               AS model_year,
    i.compname                                           AS component,
    i.subject                                            AS subject,
    to_date(nullif(i.odate,''), 'YYYYMMDD')              AS date_opened,
    to_date(nullif(i.cdate,''), 'YYYYMMDD')              AS date_closed,
    i.summary                                            AS summary
FROM odi.inv i;

-- The join an actual compliance analyst needs: does this recall have
-- complaints still arriving after the owner-notification date?
--
-- *** PERFORMANCE LANDMINE — DO NOT `SELECT * ... LIMIT 5` THIS ON STAGE. ***
-- It is a 325k x 2.2M join with a GROUP BY. A LIMIT does NOT save you: the
-- aggregate is computed in full before a single row is returned. Always
-- constrain the recall side first, e.g.
--     SELECT * FROM odi_safe.recall_to_complaint_link
--     WHERE make = 'FORD' AND model_year = '2019';
-- The predicate on make/model_year pushes down through the GROUP BY, and
-- odi.cmpl/odi.rcl both have btree indexes on those columns (01_schema.sql).
-- Rehearse the exact WHERE clause you intend to type.
CREATE OR REPLACE VIEW odi_safe.recall_to_complaint_link AS
SELECT
    rs.campaign_number,
    rs.manufacturer,
    rs.make,
    rs.model,
    rs.model_year,
    rs.component,
    rs.date_owner_notified,
    count(cf.complaint_id)                                             AS related_complaints,
    count(cf.complaint_id) FILTER (
        WHERE cf.date_failure_occurred > rs.date_owner_notified)        AS complaints_after_notification,
    sum(cf.persons_injured)                                            AS total_injured,
    sum(cf.persons_killed)                                             AS total_killed
FROM odi_safe.recall_summary rs
LEFT JOIN odi_safe.complaint_facts cf
       ON cf.make       = rs.make
      AND cf.model       = rs.model
      AND cf.model_year  = rs.model_year
GROUP BY rs.campaign_number, rs.manufacturer, rs.make, rs.model,
         rs.model_year, rs.component, rs.date_owner_notified;

---------------------------------------------------------------------------
-- 4c. executive-reporting — CERTIFIED AGGREGATES ONLY
---------------------------------------------------------------------------
-- This role never sees a row that describes an individual complaint. The
-- HAVING clause is a k-anonymity floor: a group of fewer than 5 complaints is
-- suppressed entirely, because a make/model/year/component cell with one
-- complaint in it is effectively a pointer to one identifiable vehicle.

CREATE OR REPLACE VIEW odi_safe.exec_defect_kpi AS
SELECT
    cf.make,
    cf.model_year,
    cf.component,
    count(*)                                              AS complaint_count,
    count(*) FILTER (WHERE cf.fire_reported)              AS fire_count,
    count(*) FILTER (WHERE cf.crash_reported)             AS crash_count,
    sum(cf.persons_injured)                               AS total_injured,
    sum(cf.persons_killed)                                AS total_killed,
    round(
        100.0 * count(*) FILTER (WHERE cf.fire_reported) / count(*), 2
    )                                                     AS fire_rate_pct
FROM odi_safe.complaint_facts cf
WHERE cf.make IS NOT NULL
  AND cf.component IS NOT NULL
GROUP BY cf.make, cf.model_year, cf.component
HAVING count(*) >= 5;

COMMENT ON VIEW odi_safe.exec_defect_kpi IS
    'CERTIFIED aggregate KPIs. k-anonymity floor of 5: any make/year/component '
    'group with fewer than 5 complaints is suppressed. No complaint-level row '
    'is reachable through this view.';


\echo ''
\echo '############################################################'
\echo '#  STEP 5 — Write target for the reporting agent            #'
\echo '############################################################'
\echo ''

CREATE SCHEMA IF NOT EXISTS agent_outputs;

CREATE TABLE IF NOT EXISTS agent_outputs.agent_reports (
    id             BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    -- DEFAULT current_user, and no UPDATE grant anywhere below: the writer
    -- cannot forge or later alter the attribution on its own row.
    written_by     TEXT        NOT NULL DEFAULT current_user,
    written_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    agent_purpose  TEXT        NOT NULL,
    title          TEXT        NOT NULL,
    question       TEXT,
    findings       TEXT        NOT NULL,
    sql_used       TEXT,
    source_views   TEXT[],
    conversation_id TEXT,
    CONSTRAINT agent_reports_purpose_ck CHECK (
        agent_purpose IN ('defect-analytics','recall-compliance','executive-reporting'))
);

COMMENT ON TABLE agent_outputs.agent_reports IS
    'Append-only landing table for agent-authored reports. INSERT and SELECT '
    'only - no UPDATE, no DELETE grant to any agent role, so a written report '
    'cannot be silently revised.';

CREATE INDEX IF NOT EXISTS agent_reports_purpose_idx
    ON agent_outputs.agent_reports (agent_purpose, written_at DESC);


\echo ''
\echo '############################################################'
\echo '#  STEP 6 — Grants. Nothing broader than the matrix above.  #'
\echo '############################################################'
\echo ''

-- Every role needs USAGE on odi_safe to name anything in it, and nothing more.
GRANT USAGE ON SCHEMA odi_safe TO nhtsa_defect_analytics,
                                  nhtsa_recall_compliance,
                                  nhtsa_exec_reporting;

---- defect-analytics --------------------------------------------------------
GRANT SELECT ON odi_safe.complaint_facts              TO nhtsa_defect_analytics;
GRANT SELECT ON odi_safe.complaints_by_component_year TO nhtsa_defect_analytics;
GRANT SELECT ON odi_safe.complaints_by_make_year      TO nhtsa_defect_analytics;

---- recall-compliance -------------------------------------------------------
GRANT SELECT ON odi_safe.recall_summary               TO nhtsa_recall_compliance;
GRANT SELECT ON odi_safe.investigation_summary        TO nhtsa_recall_compliance;
GRANT SELECT ON odi_safe.recall_to_complaint_link     TO nhtsa_recall_compliance;
-- Needed for the recall<->complaint linkage; still no VIN, narrative or dealer.
GRANT SELECT ON odi_safe.complaint_facts              TO nhtsa_recall_compliance;

---- executive-reporting -----------------------------------------------------
GRANT SELECT ON odi_safe.exec_defect_kpi              TO nhtsa_exec_reporting;
GRANT USAGE  ON SCHEMA agent_outputs                  TO nhtsa_exec_reporting;
GRANT SELECT, INSERT ON agent_outputs.agent_reports   TO nhtsa_exec_reporting;
-- NOT needed for the INSERT above, and kept deliberately anyway.
--
-- CORRECTION, because the opposite is widely believed: PostgreSQL does NOT
-- check the sequence ACL for a GENERATED ALWAYS AS IDENTITY column. The
-- nextval() is performed internally on the owned sequence and the INSERT
-- succeeds with no USAGE grant at all. The "permission denied for sequence"
-- trap is real, but it belongs to `DEFAULT nextval('...')` columns and to
-- explicit nextval()/currval() calls - not to identity columns.
--
-- Why keep it: if anyone ever rewrites this table with a plain serial /
-- DEFAULT nextval() column, the grant is already there and the failure never
-- happens. It grants nothing the role could misuse.
GRANT USAGE ON ALL SEQUENCES IN SCHEMA agent_outputs  TO nhtsa_exec_reporting;

-- NOT GRANTED, deliberately and explicitly, so the omission is auditable:
--   UPDATE / DELETE / TRUNCATE on agent_outputs.agent_reports  (append-only)
--   any privilege at all on schema odi                          (raw data)
--   any privilege on odi.cmpl_sample                            (carries cdescr)
--   CREATE on any schema                                        (no staging)

-- Future objects in odi_safe are denied by default; a new view must be
-- granted deliberately, one purpose at a time.
ALTER DEFAULT PRIVILEGES IN SCHEMA odi_safe REVOKE ALL ON TABLES FROM PUBLIC;

-- If sql/05a_hybrid_build.sql has run, odi.cmpl_sample exists and carries the
-- full cdescr narrative. Belt-and-braces revoke, since it was created after
-- the STEP 3 sweep.
--
-- *** THIS IS WHY 06 RUNS LAST, AND WHY IT MUST BE RE-RUN AFTER EVERY 05a. ***
-- 05a DROPs and recreates odi.cmpl_sample, and a dropped table takes its ACL
-- with it. Run 05a again without re-running this file and the highest-risk
-- column in the dataset is reachable again.
DO $sample$
BEGIN
    IF to_regclass('odi.cmpl_sample') IS NOT NULL THEN
        REVOKE ALL ON odi.cmpl_sample FROM PUBLIC;
        REVOKE ALL ON odi.cmpl_sample FROM nhtsa_defect_analytics,
                                           nhtsa_recall_compliance,
                                           nhtsa_exec_reporting;
        RAISE NOTICE 'revoked all access to odi.cmpl_sample (it carries CDESCR)';
    END IF;
END
$sample$;


\echo ''
\echo '############################################################'
\echo '#  STEP 7 — Effective-privilege report                      #'
\echo '############################################################'
\echo ''
\echo '-- Computed from the catalog, not restated from the matrix comment.'
\echo '-- If this table and the matrix ever disagree, the catalog is right.'
\echo ''

SELECT
    r.rolname                                     AS purpose_role,
    n.nspname || '.' || c.relname                 AS object,
    CASE WHEN c.relkind = 'v' THEN 'view' ELSE 'table' END AS kind,
    string_agg(p.priv, ', ' ORDER BY p.priv)      AS privileges
FROM pg_roles r
CROSS JOIN LATERAL (VALUES ('SELECT'),('INSERT'),('UPDATE'),('DELETE')) AS p(priv)
JOIN pg_class c     ON c.relkind IN ('r','v','m')
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE r.rolname IN ('nhtsa_defect_analytics','nhtsa_recall_compliance','nhtsa_exec_reporting')
  AND n.nspname IN ('odi','odi_safe','agent_outputs')
  AND has_table_privilege(r.rolname, c.oid, p.priv)
GROUP BY r.rolname, n.nspname, c.relname, c.relkind
ORDER BY r.rolname, object;

\echo ''
\echo '-- The negative assertion. THIS is the slide. Every row must say NO.'
\echo ''

SELECT
    r.rolname AS purpose_role,
    has_table_privilege(r.rolname, 'odi.cmpl',  'SELECT') AS can_read_raw_complaints,
    has_table_privilege(r.rolname, 'odi.rcl',   'SELECT') AS can_read_raw_recalls,
    has_schema_privilege(r.rolname, 'odi',      'USAGE')  AS can_enter_odi_schema,
    has_schema_privilege(r.rolname, 'public',   'CREATE') AS can_create_in_public
FROM pg_roles r
WHERE r.rolname IN ('nhtsa_defect_analytics','nhtsa_recall_compliance','nhtsa_exec_reporting')
ORDER BY r.rolname;


\echo ''
\echo '############################################################'
\echo '#  STEP 8 — Live verification.  SET ROLE, then try it.      #'
\echo '############################################################'
\echo ''
\echo '-- Talk over this. It is short and it settles the argument.'
\echo ''

---------------------------------------------------------------------------
\echo ''
\echo '### 8a. defect-analytics: the ALLOWED query'
---------------------------------------------------------------------------
SET ROLE nhtsa_defect_analytics;
-- Track A beat: pg-airman-mcp stamps the purpose into application_name so
-- every session in pg_stat_activity is attributable to an agent purpose.
-- See sql/90_observability.sql section 6.
SET application_name = 'langflow:defect-analytics';

SELECT current_user, session_user, current_setting('application_name') AS app;

SELECT component, model_year, complaint_count, fire_count
FROM odi_safe.complaints_by_component_year
WHERE model_year = '2019'
ORDER BY complaint_count DESC
LIMIT 5;

---------------------------------------------------------------------------
\echo ''
\echo '### 8b. defect-analytics: the DENIED queries'
\echo '### These are the prompt-injection targets. Note there is nothing to'
\echo '### negotiate with: the role has no privilege, so no prompt helps.'
---------------------------------------------------------------------------
-- Wrapped so a hard error does not abort the rest of the file mid-demo.
-- If you would rather show the bare red ERROR (more visceral, and it is),
-- run the statements inside the RAISE blocks directly instead.
DO $deny$
DECLARE
    v_dummy TEXT;
BEGIN
    BEGIN
        EXECUTE 'SELECT vin FROM odi.cmpl LIMIT 1' INTO v_dummy;
        RAISE WARNING 'SECURITY FAILURE: VIN was readable. STOP THE DEMO.';
    EXCEPTION WHEN insufficient_privilege OR undefined_table THEN
        RAISE NOTICE 'DENIED  SELECT vin FROM odi.cmpl        -> %', SQLERRM;
    END;

    BEGIN
        EXECUTE 'SELECT cdescr FROM odi.cmpl LIMIT 1' INTO v_dummy;
        RAISE WARNING 'SECURITY FAILURE: narrative was readable. STOP THE DEMO.';
    EXCEPTION WHEN insufficient_privilege OR undefined_table THEN
        RAISE NOTICE 'DENIED  SELECT cdescr FROM odi.cmpl     -> %', SQLERRM;
    END;

    BEGIN
        EXECUTE 'SELECT dealer_name FROM odi.cmpl LIMIT 1' INTO v_dummy;
        RAISE WARNING 'SECURITY FAILURE: dealer data was readable. STOP THE DEMO.';
    EXCEPTION WHEN insufficient_privilege OR undefined_table THEN
        RAISE NOTICE 'DENIED  SELECT dealer_name FROM odi.cmpl-> %', SQLERRM;
    END;

    BEGIN
        EXECUTE 'SELECT campaign_number FROM odi_safe.recall_summary LIMIT 1' INTO v_dummy;
        RAISE WARNING 'UNEXPECTED: defect-analytics reached recall data.';
    EXCEPTION WHEN insufficient_privilege THEN
        RAISE NOTICE 'DENIED  cross-purpose read of recall_summary -> %', SQLERRM;
    END;

    BEGIN
        EXECUTE 'INSERT INTO agent_outputs.agent_reports '
                '(agent_purpose,title,findings) VALUES (''defect-analytics'',''x'',''y'')';
        RAISE WARNING 'UNEXPECTED: defect-analytics could write a report.';
    EXCEPTION WHEN insufficient_privilege THEN
        RAISE NOTICE 'DENIED  INSERT into agent_reports       -> %', SQLERRM;
    END;
END
$deny$;

RESET ROLE;

---------------------------------------------------------------------------
\echo ''
\echo '### 8c. recall-compliance: allowed here, denied there'
---------------------------------------------------------------------------
SET ROLE nhtsa_recall_compliance;
SET application_name = 'langflow:recall-compliance';

SELECT campaign_number, make, model_year, component, potentially_affected
FROM odi_safe.recall_summary
LIMIT 5;

DO $deny2$
DECLARE v_dummy TEXT;
BEGIN
    BEGIN
        EXECUTE 'SELECT complaint_count FROM odi_safe.complaints_by_component_year LIMIT 1'
            INTO v_dummy;
        RAISE WARNING 'UNEXPECTED: recall-compliance reached the analytics rollup.';
    EXCEPTION WHEN insufficient_privilege THEN
        RAISE NOTICE 'DENIED  cross-purpose read of complaints_by_component_year -> %', SQLERRM;
    END;
END
$deny2$;

RESET ROLE;

---------------------------------------------------------------------------
\echo ''
\echo '### 8d. executive-reporting: aggregates in, report out, nothing else'
---------------------------------------------------------------------------
SET ROLE nhtsa_exec_reporting;
SET application_name = 'langflow:executive-reporting';

-- PERFORMANCE: this aggregates the whole complaints table. On a --subset
-- 250000 load it is sub-second; on the full 2.2M-row file expect 5-20s and a
-- silent room. The `make` predicate keeps it instant and costs nothing
-- rhetorically. Drop it only if you have rehearsed the timing.
SELECT make, model_year, component, complaint_count, fire_rate_pct
FROM odi_safe.exec_defect_kpi
WHERE make IN ('FORD','TOYOTA','HONDA','BMW','MERCEDES BENZ')
ORDER BY fire_rate_pct DESC, complaint_count DESC
LIMIT 5;

INSERT INTO agent_outputs.agent_reports
    (agent_purpose, title, question, findings, sql_used, source_views)
VALUES (
    'executive-reporting',
    'Fire-rate outliers by component',
    'Which make/component combinations show the highest fire rate?',
    'Placeholder written during the RBAC verification step.',
    'SELECT ... FROM odi_safe.exec_defect_kpi ORDER BY fire_rate_pct DESC',
    ARRAY['odi_safe.exec_defect_kpi']
);

-- written_by defaults to current_user and there is no UPDATE grant, so this
-- attribution is not forgeable by the writer.
SELECT id, written_by, agent_purpose, title, written_at
FROM agent_outputs.agent_reports
ORDER BY id DESC
LIMIT 3;

DO $deny3$
DECLARE v_dummy TEXT;
BEGIN
    BEGIN
        EXECUTE 'SELECT complaint_id FROM odi_safe.complaint_facts LIMIT 1' INTO v_dummy;
        RAISE WARNING 'SECURITY FAILURE: exec role reached complaint-level rows.';
    EXCEPTION WHEN insufficient_privilege THEN
        RAISE NOTICE 'DENIED  complaint-level read            -> %', SQLERRM;
    END;

    BEGIN
        EXECUTE 'UPDATE agent_outputs.agent_reports SET findings = ''revised''';
        RAISE WARNING 'SECURITY FAILURE: reports table is not append-only.';
    EXCEPTION WHEN insufficient_privilege THEN
        RAISE NOTICE 'DENIED  UPDATE of an existing report    -> %', SQLERRM;
    END;

    BEGIN
        EXECUTE 'DELETE FROM agent_outputs.agent_reports';
        RAISE WARNING 'SECURITY FAILURE: reports can be deleted.';
    EXCEPTION WHEN insufficient_privilege THEN
        RAISE NOTICE 'DENIED  DELETE of reports               -> %', SQLERRM;
    END;
END
$deny3$;

RESET ROLE;
RESET application_name;


\echo ''
\echo '############################################################'
\echo '#  STEP 9 — Wiring this into Track B (in-database agents)   #'
\echo '############################################################'
\echo ''
\echo '-- Same roles, both tracks. Track A supplies them via the connection'
\echo '-- string; Track B via aidb.create_agent(..., role => ...), which makes'
\echo '-- the agent SET LOCAL ROLE before every tool call.'
\echo ''

-- PRECONDITION for create_agent/update_agent with `role`:
-- check_role_membership() requires pg_has_role(current_user, <role>, 'MEMBER')
-- (src/api/agent_hub.rs:431). Grant the purpose roles to whoever runs the
-- demo, or the call errors with "current user is not a member of role ...".
DO $grantself$
DECLARE r TEXT;
BEGIN
    FOREACH r IN ARRAY ARRAY['nhtsa_defect_analytics',
                             'nhtsa_recall_compliance',
                             'nhtsa_exec_reporting'] LOOP
        EXECUTE format('GRANT %I TO %I', r, current_user);
    END LOOP;
    RAISE NOTICE 'granted all three purpose roles to % (needed by create_agent role =>)',
        current_user;
END
$grantself$;

-- Then, from sql/04_agents.sql:
--   SELECT error FROM aidb.update_agent('nhtsa_semkb',
--       role => 'nhtsa_defect_analytics');
-- and for semantic aliases (sql/03_semantic_kb.sql):
--   SELECT r.result FROM aidb.execute_semantic_alias(
--       'nhtsa_complaints_by_component_and_year',
--       '{"model_year":"2019"}'::jsonb,
--       execute_role => 'nhtsa_defect_analytics') AS r;
--
-- CAVEAT worth stating honestly: the aliases in 03_semantic_kb.sql read
-- odi.cmpl directly, so under execute_role => 'nhtsa_defect_analytics' they
-- will be DENIED. That is correct behaviour, not a bug — and it is the right
-- moment to say that in production the aliases would be written against
-- odi_safe.*, not against the raw tables. Rewriting them is a two-line change
-- to update_semantic_alias.


\echo ''
\echo '############################################################'
\echo '#  06_governance.sql complete                               #'
\echo '############################################################'
\echo ''
\echo '-- Closing line: the agent did not decline to read the VIN. It could'
\echo '-- not. There was no query it could have written that would have'
\echo '-- returned one. That is the difference between a guardrail and a grant.'
\echo ''
