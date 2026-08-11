-- =============================================================================
-- fallback/dummy_model.sql  —  NHTSA / Mercedes-Benz demo
--
-- *** [LOCAL] ONLY — aidb 7.6.0, the presenter's laptop. ***
-- This swaps the Track B agents (nhtsa_naive / nhtsa_semkb) onto scripted dummy
-- models, and those agents only exist locally: sql/04_agents.sql cannot run on
-- the 7.5.0 Hybrid Manager cluster. The scripted tool sequence below also names
-- `semantic_kb_search`, which is a 7.6.0 function (CREATEd by
-- aidb--7.5.0--7.6.0.sql). THERE IS NO FALLBACK FOR TRACK A — if the cloud
-- cluster, Langflow or pg-airman-mcp dies, switch to the laptop early and
-- re-stage Acts 1-5 in psql. Know that before you need it.
--
-- ZERO-NETWORK SAFETY NET. Run this when the conference wifi is gone, the Azure
-- subscription has expired, or the local GGUF will not load. It replays the
-- Act 1 (naive fails) / Act 3 (SemKB succeeds) contrast with scripted model
-- output, and nothing else in the demo has to change.
--
--   psql "$DEMO_DSN" -f fallback/dummy_model.sql
--
-- PREREQUISITES
--   sql/01_schema.sql   loaded, with data (the scripted SQL really executes)
--   sql/03_semantic_kb.sql  built on `bert`, NOT on dummy (see WHAT IS REAL)
--   sql/04_agents.sql   run, so nhtsa_naive and nhtsa_semkb exist
--
-- =============================================================================
-- BE HONEST ABOUT WHAT THIS PROVES. READ THIS PARAGRAPH BEFORE YOU PRESENT IT.
--
-- WHAT IS REAL in fallback mode:
--   * The ReAct loop itself — iteration accounting, the tool-dispatch path,
--     budget enforcement, timeouts.
--   * Every tool call. run_sql_query genuinely executes against odi.cmpl;
--     the counts on screen are real counts off real NHTSA data.
--   * semantic_kb_search / get_column_definitions genuinely query the semantic
--     knowledge base and return its real content (as long as the KB was built
--     with `bert`, which is local and needs no network).
--   * aidb_internal.action_log and agent_task_queue. The audit trail is
--     completely genuine, which is why Act 5 (90_observability.sql) works
--     perfectly on the fallback.
--
-- WHAT IS NOT REAL:
--   * The model's reasoning. The sequence of tool calls and the wording of the
--     final answers below are WRITTEN BY HAND, not produced by a model. The
--     dummy adapter replays them in order regardless of what the tools return.
--   * Therefore the fallback demonstrates THE MECHANISM AND THE TRACE. It does
--     NOT demonstrate that a model, given the semantic layer, would actually
--     choose faildate over datea. That is the claim the live demo makes and
--     the fallback cannot.
--
-- IF SOMEONE IN THE ROOM ASKS "is that the model or is that canned?", THE
-- ANSWER IS "canned — we are on the offline fallback; the tools, the SQL and
-- the audit trail are live, the model's turns are scripted." Say it plainly.
-- Presenting scripted output as live model reasoning is the one way to lose
-- this room permanently. The banner below exists to stop you forgetting.
-- =============================================================================
--
-- MECHANICS, verified against aidb main (7.6.0):
--
--   aidb-model/src/adapter/dummy.rs
--     - Config shape is {"responses": [ <TooledResponse>, ... ]}. Any other
--       shape (including none) deserializes to Default and the model just says
--       "Hello world!" forever — a silent failure, so get the JSON right.
--     - Only the TooledLanguageAdapter path (i.e. the agent path) replays the
--       script. The plain LanguageAdapter path (aidb.generate_text) ignores it
--       and returns "Hello world!", and calls reject_tools.
--     - `next_tooled_response` is an AtomicUsize on the adapter instance:
--       responses come back IN ORDER, one per model round-trip, and the LAST
--       ONE REPEATS forever once the script is exhausted. That is the graceful
--       degradation: always end a script with the final answer.
--
--   aidb-model/src/adapter/tooled.rs  (TooledResponse)
--     {"response": TEXT,            -- required
--      "tool_calls": [ {"name": TEXT, "arguments": {...}} ],   -- optional
--      "tokens_in": INT, "tokens_out": INT, "error": TEXT}     -- optional
--     NOTE the tool-call shape: `name`/`arguments` AT THE TOP LEVEL. This is
--     the internal ToolCall struct, not the OpenAI `{"function": {...}}` wire
--     shape. Getting this wrong yields a parse failure, not a warning.
--
--   src/model_cache.rs + static-sql/aidb_model_registry.sql
--     - The adapter cache is a per-PROCESS LRU, so the script pointer lives in
--       your backend and survives across statements. See "RESETTING" below.
--     - aidb.delete_model() ends with PERFORM aidb.remove_cached_model(name),
--       so the drop-then-create pattern used here also resets the pointer.
--
--   *** THE NO-OP TRAP: aidb.create_model does CREATE FOREIGN TABLE IF NOT
--   EXISTS. Re-running create_model for a name that already exists SILENTLY
--   KEEPS THE OLD CONFIG — your edited script is ignored and it still returns
--   the model name, so it looks like it worked. Every create below is
--   therefore preceded by a delete. Do not "optimize" that away. ***
--
-- Two dummy models, not one, deliberately: the script pointer is per model
-- adapter, so one shared model would make Act 3 continue Act 1's script and
-- the two acts would have to be run in a fixed order, exactly once. Separate
-- models make each act independently replayable.
-- =============================================================================

\set ON_ERROR_STOP off
\timing on


\echo ''
\echo '################################################################'
\echo '##                                                            ##'
\echo '##   !!!  FALLBACK MODE — SCRIPTED MODEL RESPONSES  !!!       ##'
\echo '##                                                            ##'
\echo '##   The agents below are NOT reasoning. Their turns are      ##'
\echo '##   canned. The tools, the SQL, the semantic KB lookups and  ##'
\echo '##   the action_log audit trail ARE REAL.                     ##'
\echo '##                                                            ##'
\echo '##   >>> SAY SO IF ANYONE ASKS. Do not present this as live   ##'
\echo '##   >>> model reasoning.                                     ##'
\echo '##                                                            ##'
\echo '##   Restore to live models: see the last section of this     ##'
\echo '##   file, or re-run sql/04_agents.sql STEP 1.                ##'
\echo '##                                                            ##'
\echo '################################################################'
\echo ''


\echo ''
\echo '############################################################'
\echo '#  STEP 1 — Drop any previous fallback models               #'
\echo '############################################################'
\echo ''

-- Mandatory, not hygiene: see THE NO-OP TRAP above. delete_model also evicts
-- the cached adapter in this backend, which resets the script pointer.
-- delete_model raises 'Model does not exist' on a missing name, so swallow it.
--
-- Harmless here but worth knowing: delete_model also runs DROP USER MAPPING IF
-- EXISTS FOR PUBLIC SERVER <provider>, and credentials are stored per FDW
-- server, not per model. Dropping one model on a provider therefore drops the
-- credentials shared by every model on it. The `dummy` provider has no
-- credentials, so nothing is lost. Do NOT copy this drop loop for a real
-- cloud provider without re-registering credentials afterwards.
DO $drop$
DECLARE
    v_name TEXT;
BEGIN
    FOREACH v_name IN ARRAY ARRAY['nhtsa_chat_dummy_naive', 'nhtsa_chat_dummy_semkb'] LOOP
        BEGIN
            PERFORM aidb.delete_model(v_name);
            RAISE NOTICE 'dropped stale fallback model %', v_name;
        EXCEPTION WHEN OTHERS THEN
            NULL;  -- did not exist; nothing to do
        END;
    END LOOP;
END
$drop$;


\echo ''
\echo '############################################################'
\echo '#  STEP 2 — Act 1 script: the naive agent gets it WRONG     #'
\echo '############################################################'
\echo ''

-- ---------------------------------------------------------------------------
-- Round-trip map for nhtsa_naive (tools => ARRAY['run_sql_query'] only):
--
--   responses[0]  turn 1 — reaches straight for a date column, picks DATEA
--   responses[1]  turn 2 — having seen a large, plausible number, answers
--                          confidently and wrongly
--
-- WHY DATEA IS THE WRONG COLUMN (this is the whole demo):
--   odi.cmpl.datea    date the record was ADDED to the ODI file
--   odi.cmpl.ldate    date the complaint was RECEIVED BY NHTSA (dict. field 17)
--   odi.cmpl.faildate date the DEFECT ACTUALLY OCCURRED   <-- the question
--
-- The canonical demo question is:
--   "How many complaints were filed about airbags where the defect actually
--    occurred during 2025?"
-- 2025 is chosen so the rows survive `load_nhtsa.py --subset 250000`, which
-- keeps the most recent rows BY DATEA. Confirm BOTH arms return a non-zero
-- count before the demo - see the preflight assertion in RUNBOOK.md. If the
-- datea arm is 0, Act 1 reads as broken rather than as confidently wrong.
--
-- The naive agent has no way to ask what a column MEANS, so it pattern-matches
-- on the name. "datea" reads like "date" plus a suffix. The SQL is valid, the
-- number is large and believable, and nothing anywhere flags it. That is
-- exactly how this fails in production: silently, and with confidence.
--
-- The scripted answer below deliberately contains NO hedging and NO mention of
-- the alternatives. Contrast that with STEP 3.
-- ---------------------------------------------------------------------------

SELECT aidb.create_model(
    'nhtsa_chat_dummy_naive',
    'dummy',
    $json${
      "responses": [
        {
          "response": "",
          "tool_calls": [
            {"name": "run_sql_query",
             "arguments": {"query": "SELECT count(*) AS airbag_complaints_2025 FROM odi.cmpl WHERE compdesc ILIKE '%AIR BAG%' AND datea ~ '^[0-9]{8}$' AND substring(datea FROM 1 FOR 4) = '2025'"}}
          ],
          "tokens_in": 1240, "tokens_out": 74
        },
        {
          "response": "In 2025 there were the number of airbag complaints shown above. I matched the component description against 'AIR BAG' and counted rows in odi.cmpl whose date falls in 2025, using the table's date column. The SQL I used was:\n\n  SELECT count(*) AS airbag_complaints_2025\n  FROM odi.cmpl\n  WHERE compdesc ILIKE '%AIR BAG%'\n    AND datea ~ '^[0-9]{8}$'\n    AND substring(datea FROM 1 FOR 4) = '2025';\n\nDates in this table are TEXT in YYYYMMDD form, so I matched on the first four characters. This is the complaint date for the 2025 calendar year.",
          "tokens_in": 1610, "tokens_out": 168
        }
      ]
    }$json$::jsonb,
    validate => false
) AS naive_fallback_model;


\echo ''
\echo '############################################################'
\echo '#  STEP 3 — Act 3 script: the SemKB agent gets it RIGHT     #'
\echo '############################################################'
\echo ''

-- ---------------------------------------------------------------------------
-- Round-trip map for nhtsa_semkb:
--
--   responses[0]  turn 1 — DISCOVER: semantic_kb_search on the user's own
--                          words, narrowed to Column entities
--   responses[1]  turn 2 — NARROW/DISAMBIGUATE: get_column_definitions to pull
--                          the actual definition text for the candidate dates
--   responses[2]  turn 3 — only now, run_sql_query, on FAILDATE
--   responses[3]  turn 4 — the grounded answer, naming the column it used, the
--                          alternatives it rejected, and why
--
-- Every tool named here MUST be in the agent's `tools` array in
-- sql/04_agents.sql or the call is rejected at dispatch. All four are.
--
-- Argument names verified against aidb-tools/src/native_tools.rs:
--   semantic_kb_search(query_text, kb_name, top_k, sources, entity_types,
--                      rrf_k, min_similarity)
--   get_column_definitions(kb_name, query_text, min_similarity, top_k, offset)
--   run_sql_query(query)
-- kb_name is omitted on purpose: a NULL kb_name resolves to the single
-- registered KB (analytics_kb). If you ever register a second KB, these calls
-- start erroring on ambiguity — add "kb_name": "analytics_kb" here if so.
--
-- The final response is a JSON *string* because nhtsa_semkb declares an
-- output_type. Its keys must match the declared fields exactly:
-- answer / sql_used / columns_grounded / confidence. Note the \" escaping —
-- this is a JSON string nested inside a JSON document.
--
-- WANT A LONGER TRACE? The agent's instructions also describe a STEP 4
-- "check for a curated alias" turn. To show it, insert one more element
-- before the final answer:
--   {"response": "", "tool_calls": [{"name": "semantic_kb_search",
--     "arguments": {"query_text": "complaints by failure year",
--                   "sources": ["alias"], "top_k": 3}}]}
-- (Only do this if sql/03_semantic_kb.sql actually registered an alias, or
-- the beat lands on an empty result.)
-- ---------------------------------------------------------------------------

SELECT aidb.create_model(
    'nhtsa_chat_dummy_semkb',
    'dummy',
    $json${
      "responses": [
        {
          "response": "",
          "tool_calls": [
            {"name": "semantic_kb_search",
             "arguments": {"query_text": "complaints about airbags where the defect actually occurred during 2025",
                           "entity_types": ["Column"],
                           "top_k": 8}}
          ],
          "tokens_in": 2180, "tokens_out": 96
        },
        {
          "response": "",
          "tool_calls": [
            {"name": "get_column_definitions",
             "arguments": {"query_text": "date the failure or defect occurred, versus date the record was added to the file, versus date received by NHTSA",
                           "top_k": 6}}
          ],
          "tokens_in": 3050, "tokens_out": 88
        },
        {
          "response": "",
          "tool_calls": [
            {"name": "run_sql_query",
             "arguments": {"query": "SELECT count(*) AS airbag_failures_2025 FROM odi.cmpl WHERE compdesc ILIKE '%AIR BAG%' AND faildate ~ '^[0-9]{8}$' AND substring(faildate FROM 1 FOR 4) = '2025'"}}
          ],
          "tokens_in": 3860, "tokens_out": 112
        },
        {
          "response": "{\"answer\": \"The count shown above is the number of airbag complaints whose defect actually occurred during 2025. I used odi.cmpl.faildate, which the publisher's data dictionary defines as the date of incident. Three columns in odi.cmpl could plausibly have matched the question, so I retrieved the definition of each before choosing: odi.cmpl.datea is the date the record was ADDED to the ODI file, and odi.cmpl.ldate is the date the complaint was RECEIVED BY NHTSA. Both describe the file's own bookkeeping, not the event, so both are wrong for this question. Note that faildate is an empty string rather than NULL on a meaningful fraction of rows, so this count is lower than the equivalent count on datea -- that is correct, not a defect. Dates in schema odi are TEXT in YYYYMMDD form, so I matched the year as text rather than casting, and guarded against malformed values with a regex test.\", \"sql_used\": \"SELECT count(*) AS airbag_failures_2025 FROM odi.cmpl WHERE compdesc ILIKE '%AIR BAG%' AND faildate ~ '^[0-9]{8}$' AND substring(faildate FROM 1 FOR 4) = '2025'\", \"columns_grounded\": [\"odi.cmpl.faildate\", \"odi.cmpl.datea\", \"odi.cmpl.ldate\"], \"confidence\": \"high\"}",
          "tokens_in": 4420, "tokens_out": 286
        }
      ]
    }$json$::jsonb,
    validate => false
) AS semkb_fallback_model;


\echo ''
\echo '############################################################'
\echo '#  STEP 4 — Point both agents at the scripted models        #'
\echo '############################################################'
\echo ''

-- aidb.update_agent RETURNS TABLE(error TEXT) and returns ZERO ROWS on success
-- (src/api/agent_hub.rs) — a bare SELECT prints "(0 rows)", which reads as
-- failure. Same DO-block wrapper as sql/04_agents.sql. SELECT ... INTO (not
-- STRICT) leaves the variable NULL on zero rows. NULL => success.
--
-- Only non-NULL arguments are changed: tools, instructions, budgets,
-- output_type, role and conversation history are all untouched.
DO $swap$
DECLARE
    v_err TEXT;
BEGIN
    SELECT error INTO v_err FROM aidb.update_agent('nhtsa_naive', model => 'nhtsa_chat_dummy_naive');
    IF v_err IS NULL THEN RAISE NOTICE 'OK: nhtsa_naive  -> nhtsa_chat_dummy_naive  (SCRIPTED)';
    ELSE RAISE WARNING 'FAILED to swap nhtsa_naive: %', v_err; END IF;

    SELECT error INTO v_err FROM aidb.update_agent('nhtsa_semkb', model => 'nhtsa_chat_dummy_semkb');
    IF v_err IS NULL THEN RAISE NOTICE 'OK: nhtsa_semkb  -> nhtsa_chat_dummy_semkb  (SCRIPTED)';
    ELSE RAISE WARNING 'FAILED to swap nhtsa_semkb: %', v_err; END IF;
END
$swap$;


\echo ''
\echo '-- Confirm the swap took (both must read nhtsa_chat_dummy_*):'
SELECT name, model, coalesce(array_length(tools, 1), 0) AS tool_count
FROM aidb.agents
WHERE name IN ('nhtsa_naive', 'nhtsa_semkb')
ORDER BY name;

DO $verify$
DECLARE
    n INT;
BEGIN
    SELECT count(*) INTO n FROM aidb.agents
    WHERE name IN ('nhtsa_naive','nhtsa_semkb') AND model LIKE 'nhtsa_chat_dummy_%';
    IF n = 2 THEN
        RAISE NOTICE 'PASS: fallback armed. Both agents are on scripted models.';
    ELSE
        RAISE WARNING 'FAIL: expected 2 agents on dummy models, found %. Did sql/04_agents.sql run?', n;
    END IF;
END
$verify$;


\echo ''
\echo '############################################################'
\echo '#  STEP 5 — The two runs (paste these, do not run the file) #'
\echo '############################################################'
\echo ''
\echo '-- Left commented so replaying this file does not burn the script'
\echo '-- pointer or overwrite the audit trail Act 5 wants to show.'
\echo ''

-- --------------------------------------------------------------------------
-- ACT 1 — the naive agent. Plain text; nhtsa_naive has no output_type.
-- Expect: one run_sql_query on DATEA, then a confident wrong answer.
-- --------------------------------------------------------------------------
-- SELECT message, conversation_id, coalesce(error, '(none)') AS error
-- FROM aidb.agent_converse(
--     'nhtsa_naive',
--     'How many complaints were filed about airbags where the defect '
--     'actually occurred during 2025?'
-- );

-- --------------------------------------------------------------------------
-- ACT 3 — the SemKB agent. `message` is a JSON object string (output_type).
-- Expect: semantic_kb_search -> get_column_definitions -> run_sql_query on
-- FAILDATE -> a grounded answer naming the rejected alternatives.
-- --------------------------------------------------------------------------
-- SELECT message, conversation_id, coalesce(error, '(none)') AS error
-- FROM aidb.agent_converse(
--     'nhtsa_semkb',
--     'How many complaints were filed about airbags where the defect '
--     'actually occurred during 2025?'
-- ) \gset a_
--
-- SELECT :'a_message'::jsonb ->> 'answer'            AS answer,
--        :'a_message'::jsonb ->> 'sql_used'          AS sql_used,
--        :'a_message'::jsonb ->  'columns_grounded'  AS columns_grounded,
--        :'a_message'::jsonb ->> 'confidence'        AS confidence;

-- Act 5 (sql/90_observability.sql) then works unchanged against
-- :'a_conversation_id'. The action_log is genuine.

-- --------------------------------------------------------------------------
-- ACT 4 — the read-only guardrail — is NOT worth running on the fallback.
-- read_only => true installs a NullActionRecorder and persists nothing, and
-- the scripted model would "refuse" the prompt-injection attempt because the
-- script says so, not because a model resisted it. If you must show a
-- guardrail offline, show it at the TOOL layer instead: run_sql_query is
-- read_only and rejects writes regardless of what the model asks for. That
-- part is genuinely enforced and does not depend on the model at all.
-- --------------------------------------------------------------------------


\echo ''
\echo '############################################################'
\echo '#  RESETTING THE SCRIPT BETWEEN REHEARSALS  (read this)     #'
\echo '############################################################'
\echo ''

-- The script pointer only ever moves FORWARD, and it lives on the cached
-- adapter in your backend process. Run Act 1 twice in one psql session and the
-- second run falls off the end of the script and just repeats the last
-- response — i.e. the final answer, with NO tool call and NO trace. It will
-- look broken on stage.
--
-- Reset it before each rehearsal, and once more right before you go live:
--
--   SELECT aidb.remove_cached_model('nhtsa_chat_dummy_naive');
--   SELECT aidb.remove_cached_model('nhtsa_chat_dummy_semkb');
--
-- Caveat: the adapter cache is PER PROCESS. Those calls reset the pointer in
-- the backend that runs them. A second psql connection, or a background
-- worker, holds its own copy. If in doubt, reconnect — a fresh backend always
-- starts at responses[0]. Re-running this whole file also resets both.


\echo ''
\echo '############################################################'
\echo '#  RESTORE TO LIVE  —  run this the moment the net is back  #'
\echo '############################################################'
\echo ''

-- ---------------------------------------------------------------------------
-- Points both agents back at the real model and removes the scripted ones, so
-- nobody can accidentally demo canned output later. ORDER MATTERS: swap the
-- agents FIRST, then drop the dummy models.
--
-- `demo.live_model` is 'nhtsa_chat' — the CLOUD model (Azure OpenAI) that
-- sql/04_agents.sql STEP 1 registers as the demo default. Restore to that and
-- nothing else: Acts 1-5 must run on the cloud model, because Act 6's whole
-- content is swapping FROM it TO the local GGUF ('nhtsa_chat_local') with the
-- network off. Restoring to the local model would quietly destroy Act 6.
--
-- Because nhtsa_chat is a cloud model, its credentials_env name must carry the
-- AIDB_ prefix. See the big comment block in sql/04_agents.sql: the
-- aidb.env_var_allowed_prefix GUC (default 'AIDB_') is enforced at model-USE
-- time, so a bad name registers fine and then dies mid-conversation.
--
-- A GUC rather than a psql \set on purpose: psql does NOT interpolate :vars
-- inside dollar-quoted strings, so :'live_model' would arrive in the DO block
-- as those literal characters.
--
-- Uncomment and run:
-- ---------------------------------------------------------------------------

-- SELECT set_config('demo.live_model', 'nhtsa_chat', false) AS live_model;
--
-- DO $restore$
-- DECLARE
--     v_err   TEXT;
--     v_model TEXT := current_setting('demo.live_model');
--     v_name  TEXT;
-- BEGIN
--     IF NOT EXISTS (SELECT 1 FROM aidb.models WHERE name = v_model) THEN
--         RAISE EXCEPTION 'live model % is not registered - register it first '
--                         '(sql/04_agents.sql STEP 1), or the agents end up '
--                         'pointing at nothing', v_model;
--     END IF;
--
--     FOREACH v_name IN ARRAY ARRAY['nhtsa_naive', 'nhtsa_semkb'] LOOP
--         SELECT error INTO v_err FROM aidb.update_agent(v_name, model => v_model);
--         IF v_err IS NULL THEN RAISE NOTICE 'OK: % -> % (LIVE)', v_name, v_model;
--         ELSE RAISE WARNING 'FAILED to restore %: %', v_name, v_err; END IF;
--     END LOOP;
--
--     FOREACH v_name IN ARRAY ARRAY['nhtsa_chat_dummy_naive', 'nhtsa_chat_dummy_semkb'] LOOP
--         BEGIN
--             PERFORM aidb.delete_model(v_name);
--             RAISE NOTICE 'removed scripted model %', v_name;
--         EXCEPTION WHEN OTHERS THEN
--             NULL;
--         END;
--     END LOOP;
-- END
-- $restore$;
--
-- -- Must show the live model for both, and no nhtsa_chat_dummy_* rows:
-- SELECT name, model FROM aidb.agents
-- WHERE name IN ('nhtsa_naive','nhtsa_semkb') ORDER BY name;
-- SELECT name FROM aidb.models WHERE name LIKE 'nhtsa_chat_dummy_%';


\echo ''
\echo '################################################################'
\echo '##  fallback/dummy_model.sql complete — FALLBACK MODE ACTIVE  ##'
\echo '##  Model turns are scripted. Tools, SQL and audit are real.  ##'
\echo '##  Reset the pointer between rehearsals (see above).         ##'
\echo '################################################################'
\echo ''

\timing off


