-- =============================================================================
-- 90_observability.sql  —  NHTSA / Mercedes-Benz demo
--
-- *** [LOCAL] ONLY — aidb 7.6.0. *** These queries read the action_log written
-- by Track B's in-database agents, which only exist on the laptop. Nothing here
-- applies to the 7.5.0 Hybrid Manager cluster that Track A runs against.
--
-- ACT 5: "show me what it actually did."
--
-- Every query here reads ordinary PostgreSQL tables. The agent's reasoning
-- trace was written by the same backend, in the same transaction, as the
-- queries it ran. There is no log shipper, no trace collector, no sampling,
-- and nothing to correlate after the fact. `pg_dump` captures the audit
-- trail along with the data, and point-in-time recovery restores both.
--
-- HOW TO USE THIS FILE
--   Run sql/04_agents.sql STEP 6 (the agent_converse calls) first, and keep
--   the conversation_id it returns. Then either:
--     \set conv '00000000-0000-0000-0000-000000000000'   -- paste yours
--   or leave it unset and every query below falls back to the most recent
--   conversation for the agent named in :agent.
--
-- *** DO NOT RE-RUN sql/04_agents.sql BEFORE THIS FILE. *** Its teardown
-- calls delete_agent(force => true), which deletes exactly these rows.
--
-- Schema verified against aidb main @ 7db15bcf (7.6.0):
--   static-sql/agent-hub.sql   aidb.agents, aidb_internal.agent_task_queue,
--                              aidb_internal.action_queue / action_log,
--                              aidb.agent_tasks, aidb.conversation_log,
--                              aidb.conversations, the action_type enum
--   aidb-agents/src/action_log.rs   the request_payload / response_payload
--                                   JSON shapes
-- =============================================================================

\set ON_ERROR_STOP off
\set agent 'nhtsa_semkb'

-- Resolve the conversation once. Everything below reads demo.conv.
-- Leave :conv unset to auto-pick the newest conversation for :agent.
-- \set conv '<paste-the-conversation_id-from-agent_converse>'
SELECT set_config('demo.agent', :'agent', false) AS agent;

DO $resolve$
DECLARE
    v_conv UUID;
BEGIN
    SELECT atq.conversation_id
      INTO v_conv
      FROM aidb_internal.agent_task_queue atq
      JOIN aidb.agents a ON a.id = atq.agent_id
     WHERE a.name = current_setting('demo.agent')
     ORDER BY atq.created_at DESC
     LIMIT 1;

    IF v_conv IS NULL THEN
        RAISE WARNING 'No conversations found for agent %. Run the agent_converse '
                      'calls in sql/04_agents.sql STEP 6 first.',
                      current_setting('demo.agent');
        PERFORM set_config('demo.conv', '00000000-0000-0000-0000-000000000000', false);
    ELSE
        PERFORM set_config('demo.conv', v_conv::text, false);
        RAISE NOTICE 'using conversation % for agent %', v_conv, current_setting('demo.agent');
    END IF;
END
$resolve$;

-- ---------------------------------------------------------------------------
-- TYPE NOTE, and a real trip hazard:
--   aidb.agent_converse returns conversation_id as TEXT.
--   aidb_internal.agent_task_queue.conversation_id is UUID.
-- Always cast: `... = :'conv'::uuid`. Comparing text to uuid without the cast
-- gives "operator does not exist: uuid = text".
-- ---------------------------------------------------------------------------


\echo ''
\echo '############################################################'
\echo '#  1. THE FULL ReAct TRACE                                  #'
\echo '############################################################'
\echo ''
\echo '-- PROVES: the reasoning loop is not a black box. Every Thought, every'
\echo '-- tool call, every observation and the final answer is a row in a'
\echo '-- PostgreSQL table, ordered, timed, and attributable to one task.'
\echo ''
\echo '-- `seq` groups one Thought/Action/Observation round together'
\echo '-- (action_queue.sequence_id). `ms` is completed_at - created_at for'
\echo '-- that single action - so you can point at which tool call was slow.'
\echo ''

WITH seq_order AS (
    -- sequence_id is a UUID, so ordering by it directly would number the
    -- Thought/Action/Observation rounds in random order. Rank the sequences
    -- by when each one started instead.
    SELECT sequence_id,
           dense_rank() OVER (ORDER BY min(created_at), sequence_id) AS seq_no
    FROM aidb_internal.action_log
    WHERE conversation_id = current_setting('demo.conv')::uuid
    GROUP BY sequence_id
)
SELECT
    row_number() OVER (ORDER BY al.created_at, al.id)          AS step,
    so.seq_no                                                  AS seq,
    al.action_type,
    -- Which tool, when it is a tool action. Shape verified against
    -- aidb-agents/src/action_log.rs::ToolCall { tool_name, arguments }.
    al.request_payload ->> 'tool_name'                         AS tool,
    to_char(al.created_at, 'HH24:MI:SS.MS')                    AS started,
    round(EXTRACT(EPOCH FROM (al.completed_at - al.created_at))::numeric * 1000, 1)
                                                               AS ms,
    al.status,
    -- One readable "what happened" column across every action_type. Each
    -- action_type stores a different payload struct, so this CASE mirrors
    -- render_action_contents() in action_log.rs.
    left(regexp_replace(
        CASE al.action_type
            WHEN 'user_prompt'    THEN al.request_payload  ->> 'contents'
            WHEN 'model_request'  THEN '(model prompted for its next step)'
            WHEN 'model_response' THEN al.response_payload ->> 'contents'
            WHEN 'answer'         THEN al.response_payload ->> 'contents'
            WHEN 'tool_call'      THEN al.request_payload  ->  'arguments' #>> '{}'
            WHEN 'tool_response'  THEN al.response_payload ->> 'contents'
            WHEN 'error'          THEN coalesce(al.error, al.response_payload ->> 'error')
            WHEN 'compaction'     THEN '(history compacted to fit the context window)'
            ELSE coalesce(al.response_payload #>> '{}', al.request_payload #>> '{}')
        END, '\s+', ' ', 'g'), 130)                            AS contents
FROM aidb_internal.action_log al
JOIN seq_order so ON so.sequence_id = al.sequence_id
WHERE al.conversation_id = current_setting('demo.conv')::uuid
ORDER BY al.created_at, al.id;

\echo ''
\echo '-- 1b. Same trace, joined to the owning task and agent. This is the'
\echo '--     version to show if anyone asks "how do you know which agent and'
\echo '--     which user produced this?"'
\echo ''

SELECT
    ag.name                                                    AS agent,
    atq.role                                                   AS ran_as_role,
    atq.status                                                 AS task_status,
    row_number() OVER (PARTITION BY atq.id ORDER BY al.created_at, al.id) AS step,
    al.action_type,
    al.request_payload ->> 'tool_name'                         AS tool,
    round(EXTRACT(EPOCH FROM (al.completed_at - al.created_at))::numeric * 1000, 1) AS ms,
    -- Cumulative wall-clock from the moment the task was created.
    round(EXTRACT(EPOCH FROM (al.created_at - atq.created_at))::numeric, 3)         AS t_plus_s
FROM aidb_internal.agent_task_queue atq
JOIN aidb.agents           ag ON ag.id = atq.agent_id
JOIN aidb_internal.action_log al ON al.task_id = atq.id
WHERE atq.conversation_id = current_setting('demo.conv')::uuid
ORDER BY atq.created_at, al.created_at, al.id;

-- NOTE on ordering: ORDER BY created_at alone is not sufficient. Actions
-- inside one sequence can share a timestamp to the microsecond, so `id` is
-- the tiebreaker throughout this file. Drop it and the trace can appear
-- out of order on a fast machine — a bad look on stage.
--
-- NOTE on completeness: rows live in aidb_internal.action_queue while
-- IN PROGRESS and are moved verbatim to action_log on resolution
-- (static-sql/agent-hub.sql). For a finished conversation, action_log is the
-- whole story. Mid-run, UNION in action_queue to see the in-flight action.


\echo ''
\echo '############################################################'
\echo '#  2. JUST THE SQL THE AGENT WROTE                          #'
\echo '############################################################'
\echo ''
\echo '-- PROVES: the generated SQL is inspectable, diffable, reviewable and'
\echo '-- attributable. Not "the model said 4,182" - here is the exact'
\echo '-- statement, and you can re-run it yourself.'
\echo ''
\echo '-- This is also the compliance answer. "Can you show me every query an'
\echo '-- AI agent ran against production last quarter?" Yes. It is a SELECT.'
\echo ''

SELECT
    to_char(al.created_at, 'YYYY-MM-DD HH24:MI:SS')            AS at,
    ag.name                                                    AS agent,
    atq.role                                                   AS ran_as_role,
    round(EXTRACT(EPOCH FROM (al.completed_at - al.created_at))::numeric * 1000, 1) AS ms,
    -- run_sql_query's single parameter is `query`
    -- (aidb-tools/src/native_tools.rs, NativeTool "run_sql_query").
    al.request_payload -> 'arguments' ->> 'query'              AS generated_sql
FROM aidb_internal.action_log al
JOIN aidb_internal.agent_task_queue atq ON atq.id = al.task_id
JOIN aidb.agents ag                     ON ag.id = atq.agent_id
WHERE al.action_type = 'tool_call'
  AND al.request_payload ->> 'tool_name' = 'run_sql_query'
  AND al.conversation_id = current_setting('demo.conv')::uuid
ORDER BY al.created_at, al.id;

\echo ''
\echo '-- 2b. Every SQL statement written by ANY agent, ever. No filter.'
\echo '--     Show this one if the room is a security team.'
\echo ''

SELECT
    ag.name                                       AS agent,
    atq.role                                      AS ran_as_role,
    al.conversation_id,
    to_char(al.created_at, 'YYYY-MM-DD HH24:MI')  AS at,
    left(regexp_replace(
        al.request_payload -> 'arguments' ->> 'query', '\s+', ' ', 'g'), 110) AS sql_excerpt
FROM aidb_internal.action_log al
JOIN aidb_internal.agent_task_queue atq ON atq.id = al.task_id
JOIN aidb.agents ag                     ON ag.id = atq.agent_id
WHERE al.action_type = 'tool_call'
  AND al.request_payload ->> 'tool_name' = 'run_sql_query'
ORDER BY al.created_at DESC
LIMIT 25;

\echo ''
\echo '-- 2c. The retrieval calls that GROUNDED that SQL. This is the pairing'
\echo '--     that makes the semantic-layer argument auditable rather than'
\echo '--     merely plausible: for each generated query, the column'
\echo '--     definitions the agent looked up immediately before writing it.'
\echo ''

SELECT
    row_number() OVER (ORDER BY al.created_at, al.id)          AS step,
    al.request_payload ->> 'tool_name'                         AS retrieval_tool,
    left(regexp_replace(
        al.request_payload -> 'arguments' ->> 'query_text', '\s+', ' ', 'g'), 80)
                                                               AS asked_for,
    left(regexp_replace(
        al.response_payload ->> 'contents', '\s+', ' ', 'g'), 130)
                                                               AS retrieved
FROM aidb_internal.action_log al
WHERE al.conversation_id = current_setting('demo.conv')::uuid
  AND al.action_type IN ('tool_call','tool_response')
  AND coalesce(al.request_payload ->> 'tool_name', '') IN (
        'semantic_kb_search','get_column_definitions','get_entity_definitions',
        'search_by_comment','get_metadata','semantic_kb_stats')
ORDER BY al.created_at, al.id;


\echo ''
\echo '############################################################'
\echo '#  3. ACTION-TYPE HISTOGRAM — it LOOPED, it did not guess    #'
\echo '############################################################'
\echo ''
\echo '-- PROVES: this was a genuine ReAct loop, not one prompt and one'
\echo '-- answer. If model_request / model_response counts are 1, the agent'
\echo '-- one-shotted it and the demo has not shown reasoning at all.'
\echo '-- Expect the semkb agent to show several tool_call rounds BEFORE its'
\echo '-- first run_sql_query - that ordering is the whole thesis.'
\echo ''

SELECT
    al.action_type,
    count(*)                                                   AS occurrences,
    round(avg(EXTRACT(EPOCH FROM (al.completed_at - al.created_at)))::numeric * 1000, 1)
                                                               AS avg_ms,
    round(sum(EXTRACT(EPOCH FROM (al.completed_at - al.created_at)))::numeric, 2)
                                                               AS total_s,
    -- Little bar chart. Costs nothing and reads instantly from the back row.
    repeat('#', LEAST(count(*)::int, 40))                      AS chart
FROM aidb_internal.action_log al
WHERE al.conversation_id = current_setting('demo.conv')::uuid
GROUP BY al.action_type
ORDER BY occurrences DESC;

\echo ''
\echo '-- 3b. Tool-call histogram. Which tools did it actually reach for?'
\echo ''

SELECT
    al.request_payload ->> 'tool_name'                         AS tool,
    count(*)                                                   AS calls,
    round(avg(EXTRACT(EPOCH FROM (al.completed_at - al.created_at)))::numeric * 1000, 1)
                                                               AS avg_ms,
    repeat('#', LEAST(count(*)::int, 40))                      AS chart
FROM aidb_internal.action_log al
WHERE al.conversation_id = current_setting('demo.conv')::uuid
  AND al.action_type = 'tool_call'
GROUP BY 1
ORDER BY calls DESC;

\echo ''
\echo '-- 3c. THE COMPARISON SLIDE. Naive agent vs SemKB agent, side by side.'
\echo '--     Reasoning rounds, retrieval calls, SQL attempts, wall clock.'
\echo '--     Expect the semkb agent to take LONGER and use MORE tokens, and'
\echo '--     to be right. Own that trade-off out loud - it is the honest'
\echo '--     version of the pitch and it survives scrutiny.'
\echo ''

-- Aggregate PER TASK first, then average across tasks. Aggregating straight
-- over the agent x action_log join would weight budget_consumed and wall
-- clock by each task's action count — quietly wrong, and wrong in the
-- direction that flatters the naive agent.
WITH per_task AS (
    SELECT
        ag.name                                                       AS agent,
        atq.id                                                        AS task_id,
        atq.budget_consumed                                           AS tokens,
        EXTRACT(EPOCH FROM (atq.completed_at - atq.created_at))        AS wall_s,
        count(*) FILTER (WHERE al.action_type = 'model_request')       AS reasoning_rounds,
        count(*) FILTER (WHERE al.action_type = 'tool_call'
                           AND al.request_payload ->> 'tool_name' IN (
                               'semantic_kb_search','get_column_definitions',
                               'get_entity_definitions','search_by_comment',
                               'get_metadata'))                        AS retrieval_calls,
        count(*) FILTER (WHERE al.action_type = 'tool_call'
                           AND al.request_payload ->> 'tool_name' = 'run_sql_query')
                                                                       AS sql_attempts,
        count(*) FILTER (WHERE al.action_type = 'error')               AS errors
    FROM aidb.agents ag
    JOIN aidb_internal.agent_task_queue atq ON atq.agent_id = ag.id
    LEFT JOIN aidb_internal.action_log al   ON al.task_id   = atq.id
    WHERE ag.name IN ('nhtsa_naive','nhtsa_semkb')
    GROUP BY ag.name, atq.id, atq.budget_consumed, atq.completed_at, atq.created_at
)
SELECT
    agent,
    count(*)                                  AS runs,
    round(avg(reasoning_rounds), 1)           AS avg_reasoning_rounds,
    round(avg(retrieval_calls),  1)           AS avg_retrieval_calls,
    round(avg(sql_attempts),     1)           AS avg_sql_attempts,
    sum(errors)                               AS total_errors,
    round(avg(tokens))                        AS avg_tokens,
    round(avg(wall_s)::numeric, 2)            AS avg_wall_s
FROM per_task
GROUP BY agent
ORDER BY agent;


\echo ''
\echo '############################################################'
\echo '#  4. BUDGET, TOKENS AND WALL CLOCK PER RUN                 #'
\echo '############################################################'
\echo ''
\echo '-- PROVES: cost and latency are first-class, queryable columns. You can'
\echo '-- put an agent on a dashboard and an alert without adding a single'
\echo '-- piece of infrastructure.'
\echo ''
\echo '-- READ THE COLUMN NAME CAREFULLY: budget_consumed is a SINGLE INTEGER'
\echo '-- holding input + output tokens SUMMED (aidb-agents/src/budget.rs:'
\echo '-- total_tokens() = tokens_in + tokens_out, and "mirrors'
\echo '-- agent_task_queue.budget_consumed"). The split is tracked in memory'
\echo '-- during the run but is NOT persisted per task. Do not offer a customer'
\echo '-- an input-vs-output cost breakdown from this table - you cannot'
\echo '-- produce one, and the input_token_budget / output_token_budget columns'
\echo '-- on aidb.agents are LIMITS, not consumption.'
\echo ''

SELECT
    ag.name                                                       AS agent,
    atq.id                                                        AS task_id,
    atq.status,
    atq.role                                                      AS ran_as_role,
    atq.blocking,
    atq.budget_consumed                                           AS tokens_total,
    ag.input_token_budget                                         AS limit_in,
    ag.output_token_budget                                        AS limit_out,
    ag.max_iterations                                             AS limit_iterations,
    count(*) FILTER (WHERE al.action_type = 'model_request')       AS iterations_used,
    ag.budget_strategy,
    to_char(atq.created_at,   'HH24:MI:SS')                       AS started,
    to_char(atq.completed_at, 'HH24:MI:SS')                       AS finished,
    round(EXTRACT(EPOCH FROM (atq.completed_at - atq.created_at))::numeric, 2)
                                                                  AS wall_clock_s,
    ag.timeout_seconds                                            AS timeout_s,
    -- timeout_at is computed from the agent's configured timeout at task
    -- creation (agent_hub.rs), never a fixed fallback.
    round(EXTRACT(EPOCH FROM (atq.timeout_at - atq.created_at))::numeric, 0)
                                                                  AS budgeted_s,
    coalesce(atq.error, '(none)')                                 AS error
FROM aidb_internal.agent_task_queue atq
JOIN aidb.agents ag              ON ag.id = atq.agent_id
LEFT JOIN aidb_internal.action_log al ON al.task_id = atq.id
WHERE ag.name IN ('nhtsa_naive','nhtsa_semkb')
GROUP BY ag.name, atq.id, atq.status, atq.role, atq.blocking, atq.budget_consumed,
         ag.input_token_budget, ag.output_token_budget, ag.max_iterations,
         ag.budget_strategy, atq.created_at, atq.completed_at, ag.timeout_seconds,
         atq.timeout_at, atq.error
ORDER BY atq.created_at DESC
LIMIT 20;

\echo ''
\echo '-- 4b. Budget headroom. `iterations_used` approaching max_iterations is'
\echo '--     the early warning for the "agent appears to stall" failure mode.'
\echo '--     With budget_strategy = attempt_complete and max_iterations left'
\echo '--     NULL, the effective cap is an invisible 21 - which is exactly'
\echo '--     why sql/04_agents.sql sets it explicitly.'
\echo ''

SELECT
    ag.name                                                       AS agent,
    coalesce(ag.max_iterations, 21)                               AS effective_cap,
    (ag.max_iterations IS NULL)                                   AS cap_is_implicit,
    max(sub.iters)                                                AS worst_run_iterations,
    round(avg(sub.iters), 1)                                      AS avg_iterations,
    max(atq.budget_consumed)                                      AS worst_run_tokens
FROM aidb.agents ag
JOIN aidb_internal.agent_task_queue atq ON atq.agent_id = ag.id
JOIN LATERAL (
    SELECT count(*) AS iters
    FROM aidb_internal.action_log al
    WHERE al.task_id = atq.id AND al.action_type = 'model_request'
) sub ON true
WHERE ag.name IN ('nhtsa_naive','nhtsa_semkb')
GROUP BY ag.name, ag.max_iterations
ORDER BY ag.name;


\echo ''
\echo '############################################################'
\echo '#  5. THE REGISTRY VIEWS                                    #'
\echo '############################################################'
\echo ''
\echo '-- PROVES: agents, tools and conversations are catalog objects, not'
\echo '-- YAML in someone''s home directory. `\d aidb.` and they are all there.'
\echo ''

\echo ''
\echo '-- 5a. aidb.agents — the agent registry'
SELECT
    name,
    model,
    coalesce(array_length(tools, 1), 0)        AS tools,
    coalesce(array_length(delegates, 1), 0)    AS delegates,
    max_iterations,
    timeout_seconds,
    budget_strategy,
    (output_type IS NOT NULL)                  AS structured_output,
    coalesce(role, '(caller)')                 AS runs_as,
    to_char(created_at, 'YYYY-MM-DD HH24:MI')  AS created
FROM aidb.agents
ORDER BY name;

\echo ''
\echo '-- 5b. aidb.tools — native + SQL + MCP tools in one view.'
\echo '--     tool_type is the discriminator. read_only is what the Act 4'
\echo '--     guardrail enforces against.'
-- NOTE: `params` is NOT the same shape across tool_type. Native tools and SQL
-- tools store a JSON ARRAY of {name,type,description}; MCP tools store the
-- server's raw JSON Schema OBJECT (aidb.list_cached_mcp_tools passes
-- mcp_tool_cache.input_schema straight through). A bare
-- jsonb_array_length(params) therefore ERRORS the moment one MCP server is
-- registered. Hence the jsonb_typeof guard.
SELECT
    tool_type,
    name,
    read_only,
    CASE jsonb_typeof(params)
        WHEN 'array'  THEN jsonb_array_length(params)
        WHEN 'object' THEN
            coalesce(jsonb_array_length(params -> 'required'), 0)   -- JSON Schema
        ELSE 0
    END                                               AS n_params,
    jsonb_typeof(params)                              AS params_shape,
    left(coalesce(description, ''), 58)               AS description
FROM aidb.tools
ORDER BY tool_type, name
LIMIT 40;

\echo ''
\echo '-- 5c. aidb.conversations — one row per conversation'
SELECT
    c.conversation_id,
    ag.name                                    AS agent,
    c.status,
    c.message_count,
    to_char(c.created_at, 'YYYY-MM-DD HH24:MI:SS') AS started,
    to_char(c.updated_at, 'HH24:MI:SS')            AS last_message
FROM aidb.conversations c
JOIN aidb.agents ag ON ag.id = c.agent_id
ORDER BY c.created_at DESC
LIMIT 15;

-- HONEST CAVEAT: aidb.conversations.parent_conversation_id and
-- forked_from_message_id are ALWAYS NULL. The columns exist for a
-- conversation-forking capability that has no implementation
-- (static-sql/agent-hub.sql says so in as many words). Do not present
-- conversation branching as a feature.

\echo ''
\echo '-- 5d. aidb.conversation_log — the user-visible transcript only'
\echo '--     (action_type IN (''user_prompt'',''answer'')). This is what you'
\echo '--     would show an end user; sections 1-2 are what you show an'
\echo '--     auditor. Two different audiences, one table underneath.'
SELECT
    to_char(cl.created_at, 'HH24:MI:SS')            AS at,
    cl.action_type,
    left(regexp_replace(cl.payload ->> 'contents', '\s+', ' ', 'g'), 150) AS message
FROM aidb.conversation_log cl
WHERE cl.conversation_id = current_setting('demo.conv')::uuid
ORDER BY cl.created_at, cl.id;

\echo ''
\echo '-- 5e. aidb.agent_tasks — the customer-facing task view (a projection'
\echo '--     of agent_task_queue with worker/budget/context internals hidden)'
SELECT
    t.task_id,
    ag.name         AS agent,
    t.caller_role,
    t.status,
    t.blocking,
    to_char(t.created_at,   'HH24:MI:SS') AS created,
    to_char(t.completed_at, 'HH24:MI:SS') AS completed,
    coalesce(t.error, '(none)')           AS error
FROM aidb.agent_tasks t
JOIN aidb.agents ag ON ag.id = t.agent_id
ORDER BY t.created_at DESC
LIMIT 15;


\echo ''
\echo '############################################################'
\echo '#  6. pg_stat_activity — TRACK A, purpose in application_name#'
\echo '############################################################'
\echo ''
\echo '-- PROVES (Track A): every external agent session is attributable to a'
\echo '-- PURPOSE, live, with no APM agent installed. pg_airman-mcp stamps the'
\echo '-- purpose into application_name and connects as the purpose-scoped'
\echo '-- LOGIN user from sql/06_governance.sql, so the DBA''s existing tools'
\echo '-- already answer "which agent is running this?"'
\echo ''
\echo '-- Try it: open a second psql as agent_defect_analytics, run'
\echo '--   SET application_name = ''langflow:defect-analytics'';'
\echo '-- and leave a query running. Then run this here.'
\echo ''

SELECT
    pid,
    usename                                        AS connected_as,
    application_name,
    -- Convention: "<runtime>:<purpose>". Splitting it out makes the point
    -- without anyone having to read the string.
    split_part(application_name, ':', 1)           AS runtime,
    nullif(split_part(application_name, ':', 2),'') AS agent_purpose,
    client_addr,
    state,
    to_char(backend_start, 'HH24:MI:SS')           AS connected_at,
    round(EXTRACT(EPOCH FROM (now() - query_start))::numeric, 2) AS query_age_s,
    wait_event_type,
    left(regexp_replace(query, '\s+', ' ', 'g'), 90) AS current_query
FROM pg_stat_activity
WHERE datname = current_database()
  AND pid <> pg_backend_pid()
  AND (
        application_name LIKE 'langflow:%'
     OR application_name LIKE 'airman%'
     OR usename LIKE 'agent\_%'
      )
ORDER BY backend_start DESC;

\echo ''
\echo '-- 6b. If that returned nothing, this shows every session so you can'
\echo '--     see the shape of the answer anyway. Note usename: the whole'
\echo '--     Track A model is that an agent NEVER connects as the owner.'
\echo ''

SELECT
    pid, usename AS connected_as,
    coalesce(nullif(application_name,''), '(unset)') AS application_name,
    state,
    to_char(backend_start, 'HH24:MI:SS') AS connected_at
FROM pg_stat_activity
WHERE datname = current_database()
ORDER BY backend_start DESC
LIMIT 15;

\echo ''
\echo '-- 6c. Track A + Track B, same governance question, same answer:'
\echo '--     which role did this actually run as? Track B records it on the'
\echo '--     task row; Track A shows it in pg_stat_activity. Same roles, from'
\echo '--     sql/06_governance.sql, either way.'
\echo ''

SELECT DISTINCT
    'track-B (in-database)'::text AS track,
    ag.name                       AS actor,
    atq.role                      AS ran_as_role
FROM aidb_internal.agent_task_queue atq
JOIN aidb.agents ag ON ag.id = atq.agent_id
UNION ALL
SELECT DISTINCT
    'track-A (external)'::text,
    coalesce(nullif(application_name,''), '(unset)'),
    usename
FROM pg_stat_activity
WHERE datname = current_database()
  AND usename LIKE 'agent\_%'
ORDER BY 1, 2;


-- =============================================================================
--  WHAT IS *NOT* HERE.  READ BEFORE THE Q&A.
--
--  The observability story above is entirely shippable today. It is
--  aidb_internal.action_log, aidb_internal.agent_task_queue, the aidb.*
--  registry views, and pg_stat_activity. All ordinary tables and views. All
--  backed up by pg_dump, all restored by PITR, all queryable by any tool that
--  speaks Postgres.
--
--  THE FOLLOWING EXIST ONLY ON POC BRANCHES. DO NOT PROMISE THEM, DO NOT
--  IMPLY A DATE, AND DO NOT PUT THEM ON A SLIDE:
--
--    * OpenTelemetry export of agent spans.  Prototype only. There is no
--      OTel exporter in a shipping build. If asked "can I get these traces
--      into our existing observability stack?", the honest answer is: today
--      you SELECT them and push them yourself, or you LISTEN/NOTIFY on a
--      trigger over action_log. Both are five lines. Neither is OTel.
--
--    * An `agent_audit` table / tamper-evident audit log.  POC branch only.
--      What ships is action_log, which is an append-only-by-convention table
--      with ordinary table privileges — NOT a hash-chained or WORM audit log.
--      If a customer needs tamper evidence, that is a design conversation,
--      and for Mercedes specifically it is a good candidate for the design
--      partnership described in README.md "The ask" — not a checkbox to tick
--      on stage.
--
--  The credibility of everything in Acts 1-5 depends on being precise here.
--  A gap you name yourself is a reason to partner. A gap they find in the
--  follow-up call is a reason to disengage.
--
--  Shippable observability, in one line for the deck:
--      action_log + agent_task_queue + LISTEN/NOTIFY.
-- =============================================================================

\echo ''
\echo '############################################################'
\echo '#  90_observability.sql complete                            #'
\echo '############################################################'
\echo ''
\echo '-- Closing line for Act 5: none of this needed an agent framework, a'
\echo '-- trace collector or a log pipeline. The reasoning trace was written'
\echo '-- by the same backend, in the same transaction, as the query it'
\echo '-- describes. It is in your backup already.'
\echo ''
