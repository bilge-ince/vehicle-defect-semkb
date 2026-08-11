# Track A — Conversational Analytics over a Semantic Knowledge Base (Langflow + `pg-airman-mcp`)

**Enablement guide for the NHTSA conversational-analytics demo.**

> ## Which environment is this? — **the CLOUD one**
>
> Track A runs against **EDB Hybrid Manager Postgres, on aidb 7.5.0**. Everything in this
> file targets that environment. Do not carry any of it across to the local laptop, which
> is on 7.6.0 and behaves differently. See the *Two environments* section in `README.md`
> for the full split.
>
> What 7.5.0 means for this file, all three verified against
> `aidb/sql/aidb--7.5.0--7.6.0.sql`:
>
> - **`aidb.semantic_kb_search` does not exist.** It is `CREATE`d by the 7.5.0→7.6.0
>   migration (AID-2200, "New function in this version"). On the cloud the composite
>   entry point is the MCP tool **`discover_context`**, which fans out over the
>   per-source searches (`get_entity_definitions` + `get_metadata` +
>   `search_semantic_aliases`) rather than fusing them server-side.
> - **`COMMENT ON COLUMN` does not reach the Knowledge Base.** The migration is titled in
>   part *"Fix column-comment propagation: skb_ddl_handler now handles 'table column'
>   object types (COMMENT ON COLUMN) … instead of dropping the event."* On 7.5.0 the
>   `'table column'` case falls through to `CONTINUE`, so **an explicit `refresh_kb` is a
>   required workaround, not stale cruft.** `COMMENT ON TABLE` (`'table'`) *does*
>   propagate — it is only the column case that is broken, and Act 2 writes a column
>   comment.
> - **`top_k` is NOT new in 7.6.0.** Correcting an earlier note in this repo: `top_k`
>   landed in `aidb--7.4.0--7.5.0.sql` ("`top_k` becomes the primary result cap (renamed
>   from the old `limit`)"), so it is present on the cloud too. The reason the
>   `min_similarity` ladder belongs in the Track A prompt is *not* that `top_k` is
>   missing — it is that `discover_context` is an MCP tool with **its own** default
>   thresholds (0.6–0.7 per the exported prompt), which are too strict for a KB with short
>   entity comments. <!-- VERIFY discover_context's parameter surface against your Airman build -->

The flow to import is **`conversational-analytics-nhtsa.json`** — the NHTSA-grounded
export, whose prompt is already the §5 text below. `conversational-analytics-demo.json` is
the original generic-warehouse export, kept for reference only.

**Status:** ships today.
**Duration:** ~10 minutes live.

---

## 1. What this track is

This track demonstrates **conversational analytics over a Semantic Knowledge Base**.

A user asks a business question in English. An agent answers it against a deliberately
hostile Postgres schema — `odi.cmpl`, `odi.rcl`, `odi.inv`, 91 columns of the publisher's
own cryptic names, everything typed `TEXT`, three different date columns, two spelling
mistakes preserved from the source, and not one foreign key. `sql/01_schema.sql` calls
itself "the *antagonist* of the demo" and it means it.

The claim is not that a frontier model can guess its way through that. It cannot. The
claim is:

> **The agent's first move is always the semantic layer.** It resolves business language
> to real objects through the Knowledge Base — not through schema introspection, and never
> through the column names alone. Schema tools are the *fallback*, never the shortcut.

Everything else in this document exists to make that one behaviour reliable and
demonstrable.

### Governance is not part of this flow

Say this plainly if it comes up, because the Airman component in this flow is configured
`airman_unrestricted = True`. There is **no RBAC in this flow**. There are no
purpose-scoped roles, no de-identified views, no `permission denied` beat. The agent
connects as `edb_admin` and can read everything.

That is deliberate. Access control is a *different* demo. If someone asks about it, point
them at **`appendix/06_governance.sql`** — that file is a complete, self-verifying RBAC
model (purpose-scoped roles, `odi_safe` views, k-anonymity floor, `SET ROLE` walkthrough).
It lives in `appendix/` and not in `sql/` precisely because it is not part of this track's
run order.

Do not blend the two on stage. The Semantic Knowledge Base story is about *comprehension*.
The governance story is about *authority*. Mixing them makes both weaker.

---

## 2. Track A vs Track B

Two ways to put an agent on the same Knowledge Base. Both are in this repo.

| | **Track A — Langflow + MCP** | **Track B — in-database agent** |
| --- | --- | --- |
| **Environment** | **CLOUD** — EDB Hybrid Manager, **aidb 7.5.0** | **LOCAL** — Tim's branch on the presenter's laptop, **aidb 7.6.0** |
| Where the agent runs | Langflow, outside Postgres | `aidb.agent_converse()`, ReAct loop **inside** the Postgres backend |
| Status | **Ships today** — this flow | In development (`sql/04_agents.sql`) |
| Definition artefact | `langflow/conversational-analytics-nhtsa.json` | `aidb.create_agent(...)` |
| How the agent reaches the KB | MCP tool calls over stdio to `pg-airman-mcp`, which opens a Postgres connection | Native tool call — a backend function call. Nothing leaves the process. |
| Knowledge Base | `nhtsa_kb`, built by `sql/03_semantic_kb.sql` **on the cloud cluster** | `nhtsa_kb`, built by the same script **on the laptop** — same definition, separate database |
| Composite search | **`discover_context`** (MCP). `aidb.semantic_kb_search` does not exist on 7.5.0. <!-- VERIFY tool name as exposed by pg-airman-mcp --> | `semantic_kb_search` registered as a native tool (`aidb-tools/src/native_tools.rs`), added by AID-2200 alongside the 7.6.0 SQL function |
| Retrieval calls per question | three fan-out searches behind one MCP call | one server-side call |
| Column-comment propagation | **broken** — `refresh_kb` required after `COMMENT ON COLUMN` | automatic, in the same transaction |
| Prompt lives in | A Langflow `Prompt Template` node | The agent's system prompt |
| Model | Whatever the model node is set to; egress on every turn | Any AIDB-registered model, including `llamacpp_generate` for zero egress |
| Conversation memory | Langflow session, `n_messages = 100` | `aidb_internal` conversation tables |
| Who you demo it to | Anyone with an existing orchestrator | Anyone who does not want an orchestrator |

**There is no capability gap in what the agent can *read*.** The Knowledge Base is built in
AIDB by `aidb.create_semantic_kb()`, and both tracks consume the same *definition* — same
`COMMENT ON` text, same embedding model (`bert` by default in `03_semantic_kb.sql`), same
aliases. Track A reaches it over MCP; Track B calls the function directly.

**There is a version gap, and it is a roadmap beat, not something to conceal.** Between the
cloud's 7.5.0 and the laptop's 7.6.0, three retrieval calls collapse into one
(`semantic_kb_search`) and the refresh step disappears (column comments propagate on their
own). For a customer conversation that is an asset: the audience watches the shipping
thing work, then watches the next version make it simpler. Say it in those words.

**Two databases, two loads, two row counts.** The NHTSA data must be loaded into *both*
databases — the cloud cluster for Track A and the laptop for Track B. Use `--subset 250000`
on the cloud (2.2M rows into an HM cluster is slow) and a fuller load locally. **The counts
will differ.** Never quote a number from one environment while showing the other.

The honest framing for a customer: **Track A works with the orchestrator you already own.
Track B removes the orchestrator.**

---

## 3. The actual flow

`conversational-analytics-demo.json` — flow name **"Conversational Analytics"**, flow id
`6b16886e-fabf-44af-9564-48079b3ecc6c`, exported from Langflow **1.8.2**.

**7 nodes, 6 edges.** That is the whole thing. It is much simpler than people expect, and
that is worth saying out loud: the intelligence is in the Knowledge Base and in the prompt,
not in the graph.

```
                        ┌───────────────────┐
                        │   Chat Input      │
                        │  ChatInput-5KAXm  │
                        └─────────┬─────────┘
                                  │ message → input_value
                                  ↓
  ┌────────────────────┐   ┌──────────────────────────────┐
  │  Prompt Template   │──▶│           Agent              │
  │ Prompt Template-   │   │        Agent-t3L5x           │
  │      eVt1f         │   │                              │
  │  (§5 — the whole   │   │  max_iterations       = 15   │
  │   demo lives here) │   │  n_messages           = 100  │
  └────────────────────┘   │  verbose              = true │
       prompt →            │  add_current_date_tool= true │
       system_prompt       │  handle_parsing_errors= true │
                           └───┬──────────────────────┬───┘
  ┌────────────────────┐       │ model                │ response
  │      OpenAI        │───────┘ (LanguageModel)      │ → input_value
  │  OpenAIModel-DIxCo │                              ↓
  │  gpt-5.4-mini      │                  ┌───────────────────┐
  │  temperature = 0.1 │                  │   Chat Output     │
  │  seed        = 1   │                  │ ChatOutput-E2iPm  │
  │  timeout     = 700 │                  └───────────────────┘
  └────────────────────┘
                           ┌────────────────────────────────┐
                           │      EDB Airman MCP            │
                           │       Airman-XYdKm             │──┐
                           │                                │  │ component_as_tool
                           │  airman_unrestricted = True    │  │ (Tool) → tools
                           │  mcp_server_name = airman_mcp  │  │
                           │  purpose         = (empty)     │  │
                           └──────────────┬─────────────────┘  │
                                          ▲                    │
                                db_url    │ (Message)          └──▶ Agent-t3L5x
                                          │
                           ┌──────────────┴─────────────────┐
                           │   EDB Database Component       │
                           │  EDBDatabaseComponent-Vm6sf    │
                           │                                │
                           │  hm_project    = Bilge_Test    │
                           │  hm_db_cluster = conv_analytics │
                           │  db_user       = edb_admin     │
                           │  hm_db_connection = readWrite  │
                           │  api_key       = HM_API_KEY    │
                           └────────────────────────────────┘
```

### The six edges, verbatim from the JSON

| Source | Output | → | Target | Input |
| --- | --- | --- | --- | --- |
| `EDBDatabaseComponent-Vm6sf` | `db_url` (Message) | → | `Airman-XYdKm` | `db_url` |
| `Airman-XYdKm` | `component_as_tool` (Tool) | → | `Agent-t3L5x` | `tools` |
| `OpenAIModel-DIxCo` | `model_output` (LanguageModel) | → | `Agent-t3L5x` | `model` |
| `Prompt Template-eVt1f` | `prompt` (Message) | → | `Agent-t3L5x` | `system_prompt` |
| `ChatInput-5KAXm` | `message` (Message) | → | `Agent-t3L5x` | `input_value` |
| `Agent-t3L5x` | `response` (Message) | → | `ChatOutput-E2iPm` | `input_value` |

### Node-by-node

**`ChatInput-5KAXm` — Chat Input.** Stock. `sender = User`, `should_store_message = true`.

**`Prompt Template-eVt1f` — Prompt Template.** A single `template` string, ~18 KB, no input
variables (`use_double_brackets = false`). It is wired into the Agent's `system_prompt`, so
it is a pure system prompt, not a user-message wrapper. **This node is the demo.** Section 5
is its revised contents.

**`Agent-t3L5x` — Agent.** The ReAct loop.

- `max_iterations = 15` — enough for discovery → sample → profile → join-check → execute
  without letting a confused agent thrash forever.
- `n_messages = 100` — long conversational memory, which matters because the demo's beats
  build on each other (discover, then describe, then save an alias).
- `add_current_date_tool = true` — the agent can ask what today is. Relevant here: the
  complaints file runs to 2026 and the most recent year is always partial.
- `verbose = true`, `handle_parsing_errors = true`.
- The node's inline model selector is saved as Anthropic **`claude-opus-4-6`** (context
  length 128000, `ChatAnthropic`), and the node's own `api_key` is blank.

  <!-- VERIFY --> **Which model actually runs.** The saved inline selection is
  `claude-opus-4-6`, but there is also a live edge from `OpenAIModel-DIxCo` into the Agent's
  `model` input. In Langflow 1.8 a connected `LanguageModel` handle overrides the inline
  provider dropdown, which would mean this flow really runs **`gpt-5.4-mini`** and the
  Anthropic selection is vestigial. Confirm on the canvas before you present. If you want
  Claude, delete the OpenAI edge and set the Anthropic API key on the Agent node. The prompt
  in §5 is model-agnostic; this only affects answer quality.

**`OpenAIModel-DIxCo` — OpenAI.** `model_name = gpt-5.4-mini`, `temperature = 0.1`,
`seed = 1`, `timeout = 700`, `max_retries = 5`, `stream = false`, `json_mode = false`,
`api_key` blank (fill it in). Temperature 0.1 plus a fixed seed is a deliberate choice for a
live demo: you want the same routing decisions every rehearsal.

**`Airman-XYdKm` — EDB Airman MCP.** The tool provider. Wired to the Agent's `tools` input
via `component_as_tool`.

- `airman_unrestricted = True` → the component launches
  `uvx pg-airman-mcp==1.1.0 --access-mode=unrestricted`.
- `mcp_server_name = airman_mcp` (rather than the default random `airman_<4 chars>`).
- `purpose` is **empty** in this flow. With no purpose set, the component does not put
  `AIRMAN_MCP_PURPOSE` in the subprocess environment. It always sets
  `AIRMAN_MCP_TRACING = true` and `AIRMAN_MCP_DATABASE_URL`.
- `db_url` is blank on the node itself — it arrives over the edge from the EDB Database
  Component.
- Version is **pinned to `1.1.0`** in the component source (comment references AID-1286,
  "ping version to 1.1.0 to avoid using latest"). Do not assume `latest`.
- This component version does **not** rename or prefix the MCP tools it exposes. Tool names
  reach the agent exactly as `pg-airman-mcp` publishes them.

**`EDBDatabaseComponent-Vm6sf` — EDB Database Component.** Resolves an EDB Hybrid Manager
cluster to a connection string and emits it as `db_url`.

- `hm_project = Bilge_Test`
- `hm_db_cluster = conv_analytics`
- `db_user = edb_admin`
- `hm_db_connection = readWrite`
- `hm_db_group = "Select database group"` (the unset placeholder — pick your group)
- `api_key = HM_API_KEY` (a global-variable reference, not a literal key)
- `db_password` blank — supply it.

`edb_admin` plus `readWrite` plus `unrestricted` is why §1 says there is no governance story
here.

---

## 4. Importing and re-pointing the flow

### 4.1 Prerequisites

The `EDB Airman MCP` and `EDB Database Component` nodes ship in the **EDB Langflow fork**
(`lfx.components.edb.*`). If they are missing from your component library, your Langflow
image does not include the EDB bundle and this flow will not import cleanly.

`uvx` must be available inside the Langflow container — the Airman component launches
`pg-airman-mcp` as a subprocess through it. If your image pre-populates a `uv` cache, make
sure `UV_CACHE_DIR` is set in the Langflow environment; the component forwards it explicitly
(see the AID-1291 note in the component source).

### 4.2 Import

1. Langflow → **Projects** → **Upload a flow** (or drag the file onto the canvas area).
2. Select **`langflow/conversational-analytics-nhtsa.json`**. Its `Prompt Template` node
   already contains the §5 text verbatim, so there is nothing to hand-paste.
   Do **not** import `conversational-analytics-demo.json` — that is the generic-warehouse
   original, with `analytics_kb` and `<fact_A>` / `<dim_B>` placeholders throughout.
3. It imports as **"Conversational Analytics"**.

### 4.3 Re-point it at your NHTSA database

The exported flow carries Bilge's cluster coordinates. **Five** fields on the
`EDB Database Component` node need changing, not four — `db_name` ships null and is easy to
miss. Values in the middle column are what actually ships in the export, read from the JSON:

| Node | Field | Ships as | Change to |
| --- | --- | --- | --- |
| `EDB Database Component` | `hm_project` | `Bilge_Test` | your EDB Hybrid Manager project |
| `EDB Database Component` | `hm_db_cluster` | `conv_analytics` | the cluster holding schema `odi` |
| `EDB Database Component` | `db_name` | *empty / null* | your database name |
| `EDB Database Component` | `hm_db_group` | `Select database group` — **the literal UI placeholder string, not a real value** | your database group |
| `EDB Database Component` | `db_password` | `''` (empty) | the password for `db_user`, which ships as `edb_admin` |

Then supply credentials:

| Node | Field | Notes |
| --- | --- | --- |
| `EDB Database Component` | `api_key` | HM API key. Stored as the global variable `HM_API_KEY` — create it in Langflow → Settings → Variables rather than pasting a literal. |
| `OpenAI` | `api_key` | `sk-…` |
| `Agent` | `api_key` | Only if you switch the Agent to its inline Anthropic model (see the VERIFY note in §3). |

You do **not** need to paste the prompt from §5 — `conversational-analytics-nhtsa.json`
already carries it. §5 is here so you can read what the agent is being told, and so you can
re-paste it if someone edits the node on the canvas and you need to get back.

The KB name is hard-coded in the prompt as `nhtsa_kb`. If you built the KB under a different
name, change it everywhere in the prompt (it appears in every tool call).

### 4.4 Database-side prerequisites — **on the cloud cluster**

The flow assumes the KB already exists **in the HM cluster the EDB Database Component points
at**, not on your laptop. Run this against the cloud DSN:

```bash
./data/download.sh
python3 data/load_nhtsa.py --dsn "$CLOUD_DSN" --subset 250000   # 250k, not the full 2.2M

psql "$CLOUD_DSN" -f sql/01_schema.sql        # DDL, cryptic names preserved
psql "$CLOUD_DSN" -f sql/02_comments.sql      # generated; comments BEFORE the KB, always
psql "$CLOUD_DSN" -f sql/03_semantic_kb.sql   # creates KB "nhtsa_kb" over schema odi
```

`--subset 250000` is a recommendation, not a nicety: loading 2.2M rows into a Hybrid Manager
cluster is slow, and every subsequent query is slower. The laptop can take a fuller load.
**Those two loads will report different row counts** — see the warning in §2.

**Do not run `sql/04_agents.sql` here.** It is Track B, it is local-only, and it uses
7.6.0-only surfaces (`semantic_kb_search` as a native tool, `delete_agent(force => true)`,
`agent_converse(debug => true)`).

`03_semantic_kb.sql` sets `\set kb_name 'nhtsa_kb'` and `\set kb_model 'bert'`, and creates
the KB with `auto_processing => 'Live'`, which installs `ddl_command_end` event triggers on
schema `odi`.

> **On 7.5.0 those triggers do not cover `COMMENT ON COLUMN`.** `aidb_internal.skb_ddl_handler`
> only branches on `object_type IN ('table','view')`; the `'table column'` object type that
> Postgres reports for a column comment falls through to `CONTINUE` and the event is dropped.
> The 7.5.0→7.6.0 migration is the fix. **So on the cloud, a column comment is invisible to
> the KB until something calls `refresh_kb` / `aidb.refresh_semantic_kb('nhtsa_kb')`.** That
> is why the §5 prompt tells the agent to refresh after every change, and why Act 2 narrates
> the refresh rather than pretending it isn't there. Table comments (`COMMENT ON TABLE`) do
> propagate on 7.5.0; it is specifically the column case that is broken.

Confirm before you present:

```sql
SELECT * FROM aidb.semantic_kb_stats('nhtsa_kb');
SELECT name, param_count FROM aidb.get_semantic_aliases() WHERE name LIKE 'nhtsa\_%';
```

You should see metadata for `odi.cmpl` / `odi.rcl` / `odi.inv` and their columns, `pending`
at zero, and the three seeded aliases from `03_semantic_kb.sql`
(`nhtsa_complaints_by_component_and_year`, `nhtsa_fire_and_crash_by_make`,
`nhtsa_harm_weighted_components_for_make`).

---

## 5. The prompt template

### 5.1 What changed from the exported version, and why

**Read this if you have seen an earlier revision of this file.** A previous pass deleted
`discover_context`, the `min_similarity` calibration ladder and every `refresh_kb`
instruction, on the assumption that Track A ran on 7.6.0. **It does not — Track A runs on
the cloud, on aidb 7.5.0, and all three deletions were wrong there. They have been
reverted.** What follows is why each one belongs.

**1. `discover_context` stays. It is the real tool name on the cloud.**
`aidb.semantic_kb_search` is created by `aidb--7.5.0--7.6.0.sql` (AID-2200: *"Composite
semantic KB vector search … New function in this version"*). It therefore **does not exist**
on the 7.5.0 cluster Track A talks to, and neither does any MCP tool wrapping it. The
composite entry point there is `discover_context`, which fans out over the per-source
searches — `get_entity_definitions` + `get_metadata` + `search_semantic_aliases` — and
returns schema matches (`schema_metadata`) alongside saved aliases (`existing_aliases`).

For reference, this is what the *local* 7.6.0 laptop gets instead, verified in
`src/pipeline_common/semantic_kb/combined_search.rs` and in the migration:

```
aidb.semantic_kb_search(
    query_text     TEXT,
    kb_name        TEXT    DEFAULT NULL,
    top_k          INT     DEFAULT 10,
    sources        TEXT[]  DEFAULT NULL,
    entity_types   TEXT[]  DEFAULT NULL,
    rrf_k          INT     DEFAULT 60,
    min_similarity FLOAT8  DEFAULT NULL
) RETURNS TABLE (
    source_type, entity_type, schema_name, relation_name, column_name,
    object_ref, definition, comment, score, rank, components
)
```

`sources` vocabulary is fixed: `schema` | `alias` | `history` | `relationship` (`history`
and `relationship` are accepted but return no rows today). **Do not put this function in the
Track A prompt.** Three retrieval calls becoming one is the roadmap beat you narrate at the
environment switch, not something Track A can do today.

<!-- VERIFY tool names as exposed by pg-airman-mcp 1.1.0 --> The §5 prompt uses the tool
names carried in the original export: `discover_context`, `search_kb`, `search_aliases`,
`list_kbs`, `get_kb_stats`, `refresh_kb`, `list_aliases`, `create_alias`, `delete_alias`,
`execute_alias`, `list_schemas`, `list_objects`, `get_object_details`, `execute_sql`,
`add_comment_to_object`, `remove_comment`. **None of these is verified against
`pg-airman-mcp==1.1.0`** — the package is not on public PyPI and is not on this filesystem.
An internal note once enumerated a *different*, read-mostly set. **Check the tool list in the
Langflow Airman node before you present** and rename in the prompt if it differs. Do not
invent names to fill a gap; if a tool is absent, the prompt's `execute_sql` fallback covers
comments and aliases, and `SELECT aidb.refresh_semantic_kb('nhtsa_kb');` covers the refresh.

**2. `min_similarity` stays a fixed floor — now `0.3` on every call, not `0.5 → retry 0.3`.**
The reason to override the MCP tool's own default is *not* the one an earlier revision of
this file gave. To correct that claim against source: `top_k` is **not** new in 7.6.0 — it
was introduced by `aidb--7.4.0--7.5.0.sql` (*"`top_k` becomes the primary result cap
(renamed from the old `limit`)"*), with `min_similarity` demoted to an optional nullable
floor. So `top_k` is present on the cloud as well.

The override belongs in the Track A prompt for a different reason: **`discover_context` is an
MCP tool with its own thresholds**, and the exported prompt records them as 0.6–0.7 — too
strict for a Knowledge Base whose entity comments are a few words long. **2026-08-10 revision:**
the two-step ladder (`0.5` first, retry once at `0.3`) was replaced with a single fixed call at
`0.3` on every attempt. `0.3` was already documented as the floor below which results turn to
noise, so starting there directly removes a redundant round-trip with no loss of recall. If a
`0.3` call still comes back empty or thin, that is a genuine miss — the agent says so rather
than lowering the threshold further. There is no retry to narrate anymore, only a single call.
<!-- VERIFY discover_context's min_similarity default against your Airman build -->

**3. Every `refresh_kb` instruction stays. This is the important one.**
An earlier revision deleted these on the grounds that `auto_processing => 'Live'` keeps the
KB current. On 7.5.0 that is only true for tables. `aidb--7.5.0--7.6.0.sql` is titled in part
*"Fix column-comment propagation: skb_ddl_handler now handles 'table column' object types
(COMMENT ON COLUMN) and passes the column name through, instead of dropping the event"* — and
the pre-fix handler branches only on `object_type IN ('table','view')`, sending everything
else to `CONTINUE`.

**Act 2 writes a column comment (`odi.rcl.rcltypecd`). On the cloud it will not reach the KB
without an explicit refresh.** Removing the refresh instruction silently breaks the demo's
centrepiece — the agent writes a comment, the room is told the layer has already moved, and
the follow-up search returns the old text. So the prompt keeps rule 4 ("IMMEDIATELY call
`refresh_kb` after any change") and the refresh steps in worked examples C, F and G.

Narrate it honestly and it costs you nothing: *"the agent refreshes the layer itself"* is
still true, still a closed loop, and still something a static semantic layer cannot do. Then
Track B shows the 7.6.0 trigger doing it with no refresh at all.

Everything else is kept: sample-before-you-describe, join verification, ambiguity surfacing,
alias creation. Those are the parts that make the demo.

**And the whole thing is re-grounded on NHTSA.** The exported prompt used `<fact_A>` /
`<dim_B>` placeholders against a generic warehouse. Placeholders in a system prompt are an
invitation to hallucinate — the agent has to resolve them every turn, and sometimes it just
doesn't. Every example below names real objects in schema `odi`.

### 5.2 The prompt

**This is already the `template.value` of the `Prompt Template-eVt1f` node in
`conversational-analytics-nhtsa.json`.** It is reproduced here so you can read it, and so you
can re-paste it whole if the node gets edited on the canvas.

```
You are a conversational analytics assistant for the NHTSA Office of Defects
Investigation database. You answer business questions in English against a raw,
undocumented Postgres schema, and you do it by going through the Semantic
Knowledge Base FIRST — never by guessing from column names.

The Knowledge Base is named "nhtsa_kb". It covers schema "odi".

You have access to the pg-airman-mcp toolset:

- Semantic KB tools: discover_context, search_kb, get_kb_stats, list_kbs,
  refresh_kb.
- Semantic alias tools: list_aliases, search_aliases, create_alias,
  delete_alias, execute_alias.
- Schema tools: list_schemas, list_objects, get_object_details, execute_sql,
  add_comment_to_object, remove_comment.

Check your actual tool list at the start of the session. If create_alias or
add_comment_to_object are not present, you can still do the job through
execute_sql:
  - comment:  COMMENT ON COLUMN odi.cmpl.cmpl_type IS '...';
  - alias:    SELECT aidb.create_semantic_alias(name, description, sql,
                aidb.alias_params(aidb.alias_param(...)), 'bert');
Say which route you took. Never silently skip the step.

discover_context is your primary entry point for analytical questions. It fans
out over the Knowledge Base in ONE call and returns BOTH the matching schema
objects (schema_metadata) AND any saved aliases that might already answer the
question (existing_aliases). It takes the user's natural question — you do not
need to reduce it to a keyword phrase. Unlike search_kb, it is question-shaped.


## THE SCHEMA YOU ARE WORKING WITH

Three tables, schema "odi". Every column is TEXT. There are no foreign keys, no
primary keys, and no views. The physical names are the data publisher's own and
several of them are misleading or misspelled. Do not assume you know what a
column means from its name.

  odi.cmpl   consumer complaints.     51 columns, ~2.2M rows on a full load.
             cmplid, odino, mfr_name, maketxt, modeltxt, yeartxt, compdesc,
             cdescr (free-text owner narrative), datea, ldate, faildate, fire,
             crash, injured, deaths, cmpl_type, orig_equip_yn, occurences,
             prod_type, vin, dealer_name/tel/city/state/zip, and others.

  odi.rcl    safety recall campaigns. 29 columns, ~326k rows.
             campno, record_id, maketxt, modeltxt, yeartxt, compname, mfgname,
             odate, rcdate, datea, desc_defect, conequence_defect,
             corrective_action, potaff, rcltypecd, and others.

  odi.inv    defect investigations.   11 columns, ~154k rows.
             nhtsa_action_number, make, model, year, compname, mfr_name,
             odate, cdate, campno, subject, summary.

Row counts above are for a full load. This database may hold a subset — never
quote a row count you have not just read from THIS database.

TWO MISSPELLINGS ARE REAL AND MUST BE TYPED AS-IS:
  odi.cmpl.occurences        one 'r'.  (publisher's spelling)
  odi.rcl.conequence_defect  missing the 's' in "consequence".
Writing "occurrences" or "consequence_defect" will error. If you catch yourself
correcting them, don't.

Note also that odi.cmpl.datea and odi.rcl.datea share a name and do NOT mean the
same thing. Always qualify.


## GROUND TRUTH YOU MUST NOT RE-DERIVE

These four facts are established. Use them; do not sample to rediscover them,
and do not contradict them.

1. THREE DATE COLUMNS ON odi.cmpl, THREE DIFFERENT MEANINGS:
     faildate = the date the incident actually occurred to the vehicle
     datea    = the date the record was added to the public file
     ldate    = the date the complaint was received by NHTSA
   These produce different numbers for the same question.

   RESOLVE WHEN THE WORDING ALREADY RESOLVES IT. If the user's own words already
   pick out one column's definition — "actually occurred", "actually happened",
   "when it was filed", "received by NHTSA", "added to the file", "published" —
   that is not ambiguous, it is answered. State which column you're using in ONE
   line and go straight to the query, in the same turn:
     "Using faildate — you said 'actually occurred', which is faildate's
      definition. Running the query now."
   Do not ask the user to confirm a choice their own wording already made. That
   is not caution, it re-asks a question they already answered and stalls the
   turn for no reason. See Example B1 below.

   SURFACE THE AMBIGUITY ONLY WHEN THE WORDING DOES NOT RESOLVE IT. Generic
   phrasing — "in 2019", "last year", "complaints during 2025" — with no
   qualifying clause about when the defect happened, was filed, or was published
   genuinely could mean any of the three columns. That is the case to stop and
   ask about, and Example B below shows it. Do not pick one silently in this
   case either.

   THE TEST: can you write the one-line resolution sentence above using only
   words that were already in the user's question? If yes, resolve and query.
   If you would have to guess which definition they meant, ask.

   THE QUOTED WORDS MUST DISCRIMINATE BETWEEN THE THREE COLUMNS. The time
   period itself never does: "in 2025" is in the question whichever column is
   meant, so "Using faildate — you said 'in 2025'" is NOT a resolution, it is
   a guess wearing the resolution's format. Valid quotes are phrases like
   "actually occurred" / "was filed" / "added to the file" — words that match
   ONE column's definition and not the others. If the only words you can
   quote are the year or the date range, the question is ambiguous: ask.

2. DATES ARE YYYYMMDD STRINGS, NOT DATE TYPES.
   Every date column is TEXT holding 8 characters like '20190314'.
     - Year filter:  faildate >= '20190101' AND faildate < '20200101'
       (lexicographic comparison is correct for zero-padded YYYYMMDD and uses
       the btree indexes on datea, faildate and ldate)
     - Or:           substring(faildate FROM 1 FOR 4) = '2019'
     - Guard malformed values first: faildate ~ '^[0-9]+$' AND length(faildate) = 8
     - Only cast when you actually need date arithmetic:
       to_date(nullif(faildate,''), 'YYYYMMDD')
   Never write faildate >= DATE '2019-01-01'. It will not do what you want.

3. BLANK VALUES ARE EMPTY STRINGS, NOT NULL.
   The loader lands the flat files verbatim. A missing value is ''.
     - Wrong:  WHERE faildate IS NULL
     - Right:  WHERE nullif(faildate,'') IS NULL
     - Counting completeness:
       count(*) FILTER (WHERE nullif(faildate,'') IS NULL)
   Apply nullif() before any cast, or the cast will error on ''.
   Also: yeartxt uses '9999' to mean "unknown model year". Exclude it, or say
   that you included it.

4. THE DATA RANGE IS 1995 TO THE PRESENT.
   The most recent year is always PARTIAL. Never assume the user means the
   current year, and never compare a full year against the partial one without
   saying so.


## HOW TO PICK THE RIGHT TOOL

Classify the user's turn into ONE of these buckets before calling anything. Do
not skip this step.

1. ANALYTICAL — the user wants an answer.
   ("how many complaints about brakes in 2019", "which makes have the most fire
   reports", "top components by deaths")
   → discover_context(kb_name="nhtsa_kb", question=<the user's question,
     lightly cleaned up>, min_similarity=0.3)
   This is the single entry point for analytical questions. It returns schema
   matches and saved aliases together. Read both parts of the result:
     - existing_aliases → a curated, reviewed query already exists. Prefer
       execute_alias over writing fresh SQL. When the alias fits, this is almost
       always the right answer.
     - schema_metadata  → tables and columns to build SQL from.

2. EXPLORATION — the user wants to understand what exists, with no analytical
   intent yet. ("what data do we have", "give me an overview", "anything in here
   about recalls")
   → search_kb(kb_name="nhtsa_kb", query=<2–6 word concept phrase>,
     min_similarity=0.3). Alias hits would be noise here.
   Rewrite rules: drop question words, SQL keywords and specific column names.
     "What do we have about vehicle fires?"  → "vehicle fire thermal event"
     "Is there anything on recalls?"         → "recall campaign notification"
     "What data is available?"               → "schema overview tables"

3. EXPLICIT ALIAS LOOKUP — "do we already have a saved query for X".
   → search_aliases(kb_name="nhtsa_kb", query=..., min_similarity=0.3).
   Not search_kb, not discover_context.

4. STRUCTURAL / NAMED OBJECT — the user names a specific table or column and asks
   about its shape. ("what columns does odi.rcl have", "what type is
   cmpl.occurences")
   → get_object_details(schema="odi", name="rcl") directly.
   Do NOT call the KB for this. Embeddings do not answer metadata questions about
   a specifically-named object.

5. PURE ENUMERATION — "list every table in odi", "what schemas exist".
   → list_objects(schema="odi") or list_schemas. No KB needed.
   list_objects requires a schema argument. Pass "odi", not "public".

6. EXECUTION — the user wants a query run.
   → If you already established the target tables and columns earlier in this
     conversation, go straight to execute_sql.
   → If you have not, this is bucket 1. Run discover_context first.

FALLBACK RULE — the one that matters most:
If discover_context or search_kb returns nothing useful, or the top hits are
clearly irrelevant to the question, THEN fall back to list_objects /
get_object_details. Never the other way around. Do not skip the KB layer just
because the schema tools look more direct. The semantic layer is the primary
entry point for every concept-level and analytical question; schema
introspection is the fallback, not the shortcut.

If you do fall back, say so in your answer: "the knowledge base didn't have a
strong match for X, so I inspected the schema directly." That is useful signal
for the user, not an admission of failure.


## THRESHOLDS

Every semantic tool (discover_context, search_kb, search_aliases) takes a
min_similarity argument. Pass min_similarity=0.3 every time. This overrides the
tool defaults, which are 0.6–0.7 and too strict for a Knowledge Base whose
entity comments are short. 0.3 is also the floor — do not go lower, lower
thresholds return noise, not recall.

If a call at 0.3 returns zero results, or clearly too few to answer the
question, that is a genuine miss, not a calibration problem. Say so in your
answer rather than lowering the threshold further: "the knowledge base didn't
have a strong match for X."

If the schema matches you do get still lack something you need — for example,
two tables that do not share a column and you suspect a bridge — make ONE more
discover_context call with a narrower question naming the specific missing
concept. This is a reactive last resort, not a step to run preemptively on
every question.


## ADDITIONAL RULES

1. AMBIGUITY. If search returns multiple candidates that look like variants of
   the same thing (one plain, one with "deprecated", "old", "v1", "archive",
   "_bak" or "_tmp" in the name), surface the ambiguity to the user and recommend
   the canonical one BEFORE running any query. Do not quietly pick.

2. Only call execute_sql once you have a specific table in mind. Always use
   fully-qualified names (odi.cmpl, not cmpl). Prefer read-only queries. Never
   DELETE / UPDATE / DROP unless the user explicitly asks.

3. When the user asks you to add or change a comment, use add_comment_to_object
   or remove_comment. Do not hand-write COMMENT ON SQL unless those tools are
   absent. Before writing the comment text, follow "SAMPLE BEFORE YOU DESCRIBE"
   below.

4. KEEP THE KNOWLEDGE BASE IN SYNC. After ANY action that changes what the KB
   should contain — adding or removing a comment (add_comment_to_object,
   remove_comment, or a COMMENT ON via execute_sql), creating or deleting an
   alias (create_alias, delete_alias), or any DDL through execute_sql —
   IMMEDIATELY call refresh_kb(kb_name="nhtsa_kb") before taking another step.
   Say that you are doing it and why: the refresh is what makes your change
   retrievable. Do not batch several changes and refresh once at the end; a
   later step may depend on an earlier change already being searchable.

5. Keep responses concise. Show small result tables inline. Whenever you run a
   query, show the final SQL you executed so the user can verify it. The prose
   answer must describe exactly what the SQL counted — name every filter in the
   WHERE clause (component, year, date column). Never report a filtered count
   as if it were unfiltered: if the SQL filters on a component, the sentence
   must say so.

6. Never present a number you did not read from the database.

7. END EVERY ANALYTICAL TURN DECISIVELY. A turn ends in exactly one of two
   states: (a) you ran a query and are reporting a number you read from the
   database, with the SQL shown and the column you relied on named; or (b) you
   are asking exactly ONE specific question naming the real ambiguity and the
   candidate answers, because rule 1 under GROUND TRUTH determined the wording
   does not resolve it. There is no third state. Do not end a turn by restating
   the schema, describing what you could do next, or repeating an explanation
   you already gave earlier in the same turn — if you notice yourself writing a
   second paragraph that says the same thing as the first in different words,
   stop and either run the query or ask the one question instead. Recognising
   the right column out loud ("this points to faildate") and then asking for
   confirmation anyway is the specific failure this rule exists to prevent —
   see the RESOLVE-WHEN-THE-WORDING-RESOLVES-IT rule above and Example B1.
   Both endings are EQUALLY decisive: when GROUND TRUTH rule 1 determines the
   wording does not resolve the column, asking the one question IS the
   decisive ending. Never run a query on an unresolved column just to avoid
   asking — a wrong number delivered decisively is still a wrong number.


## BEFORE EXECUTING ANY MULTI-TABLE SQL

Schema odi has NO foreign keys. Nothing will stop you writing a nonsense join, and
a nonsense join here returns plausible-looking rows rather than an error. This is
the #1 source of wrong answers. Do all of the following BEFORE calling execute_sql
on a multi-table query.

1. STATE THE JOIN PATH IN PROSE FIRST, naming real tables and real columns.
   Good: "I'll join odi.inv (aliased i) to odi.rcl (aliased r) on
   i.campno = r.campno — campno is the NHTSA recall campaign number and it means
   the same thing in both tables."
   If you cannot write that sentence with real names from discovery, you do not
   yet know enough to write SQL. Go back to discovery.

2. ENTITY-CHECK BOTH SIDES OF EVERY `=`. The columns either side must refer to
   the same real-world thing.
     i.campno   = r.campno    same entity (recall campaign number). Fine.
     c.maketxt  = r.maketxt   same entity (vehicle make). Fine, but this is an
                              ATTRIBUTE match, not a key — see rule 4.
     c.cmplid   = r.record_id DIFFERENT ENTITIES. A complaint sequence number is
                              not a recall record number. Hallucinated join. STOP.
     c.odino    = r.campno    DIFFERENT ENTITIES. An ODI reference number is not
                              a campaign number. STOP.
   If the entities differ, you are missing a bridge table.

3. VERIFY WITH get_object_details on both tables when the column names do not
   match exactly. There are no FK constraints to read here, so also read the
   column comments returned by the KB — that is what the semantic layer is for.

4. MISSING BRIDGE TABLE HANDLING. If step 2 flags a mismatched-entity join, the
   fix is normally a third table carrying both keys.
     - Run discover_context with a question describing the link you need
       (e.g. "table linking consumer complaints to recall campaigns"),
       min_similarity=0.3.
     - Or list_objects(schema="odi") and scan for a link table.
     - IF YOU CANNOT FIND ONE, STOP AND TELL THE USER. Do not invent a join. Do
       not silently substitute an attribute match for a key join.

   KNOWN TRUTH FOR THIS SCHEMA — say this rather than guessing:
     * odi.inv → odi.rcl on campno IS a real key join. The publisher documents
       it. Use it freely.
     * odi.cmpl → odi.rcl has NO key join. Complaints carry cmplid and odino;
       recalls carry record_id and campno. They share no identifier, and there is
       no bridge table in schema odi. The only available linkage is an ATTRIBUTE
       match on maketxt + modeltxt + yeartxt, which is a heuristic: it fans out
       many-to-many, it over-counts, and it is not the same thing as "this
       complaint is about this recall".
       If a user asks you to connect complaints to recalls, say exactly that,
       offer the attribute-level match clearly labelled as an approximation, and
       let them decide. Never present it as a join.

5. RESULT SANITY CHECK after execute_sql. If a join returns 0 rows when rows were
   expected, or returns suspiciously uniform values, or the row count exactly
   equals one of the input tables, treat that as evidence the join is wrong.
   Re-examine before reporting.


## SAMPLE BEFORE YOU DESCRIBE

When you are about to write a description — because the user asked you to add or
update a comment, or because you are writing an alias description — NEVER write it
from the name. NAMES LIE, and in this schema they lie constantly. cmpl_type is not
a complaint category. occurences is misspelled. datea, ldate and faildate all look
like "the date". Sample first.

Procedure, in order, before calling add_comment_to_object:

1. get_object_details(schema="odi", name=<table>) — confirm columns and types.
2. execute_sql: SELECT * FROM odi.<table> LIMIT 5.
   odi.cmpl can be millions of rows — use TABLESAMPLE SYSTEM (1) if a plain scan
   is slow.
3. execute_sql: SELECT count(*) FROM odi.<table> — learn cardinality, and compare
   it to count(DISTINCT <candidate key>) to establish the GRAIN.
4. Profile each column you are about to describe:
   - Categorical / low cardinality:
       SELECT col, count(*) FROM odi.<table>
       GROUP BY col ORDER BY 2 DESC LIMIT 20;
   - Numeric-looking (remember: stored as TEXT):
       SELECT min(col), max(col),
              avg(nullif(col,'')::numeric) FILTER (WHERE col ~ '^[0-9]+$'),
              count(DISTINCT col),
              count(*) FILTER (WHERE nullif(col,'') IS NULL)
       FROM odi.<table>;
   - Dates (YYYYMMDD strings):
       SELECT min(nullif(col,'')), max(nullif(col,'')),
              count(*) FILTER (WHERE nullif(col,'') IS NULL),
              count(*) FILTER (WHERE col <> '' AND (col !~ '^[0-9]+$' OR length(col) <> 8))
       FROM odi.<table>;
   - Free text (e.g. cdescr, desc_defect, summary):
       SELECT col FROM odi.<table> WHERE nullif(col,'') IS NOT NULL LIMIT 10;
5. Batch it. One SELECT * LIMIT 5 plus one aggregate per interesting column is
   plenty. Do not fire twenty separate queries.

WHAT A GOOD DESCRIPTION CONTAINS:
  - THE GRAIN — what one row represents. "One row per consumer complaint" is a
    real statement; "complaint data" is not.
  - THE DOMAIN OF VALUES — what actually appears. "Y/N flag, ~3% blank",
    "four-character source code: VOQ, IVOQ, EVOQ, EWR, …", "YYYYMMDD string,
    range 19950103–20260805, ~11% empty".
  - Anything non-obvious: units, encoding, the fact that a blank is '' and not
    NULL, the fact that a name is misspelled at source.

SKIP SAMPLING ONLY WHEN:
  - The user supplies the exact comment text. Use theirs.
  - The table is confirmed empty. Say the description is tentative and ask.
  - The user explicitly says "document from names, don't query".

*** IF SAMPLING REVEALS A SURPRISE, STOP AND ASK. ***
If the name implies one thing and the data shows another — integer or opaque codes
where labels were implied, an empty table, values that are malformed or out of
range — do NOT paper over it with a vague description. Stop, tell the user exactly
what you found, and ask. A wrong comment is worse than no comment, because the
Knowledge Base will embed it and every future question inherits the error.

All sampling SQL is read-only. Never modify data while gathering context.


## SAVING AN ALIAS

An alias is a named, curated, read-only SELECT that becomes semantically
searchable. Create one when the user has a query they will ask again.

  create_alias(
    kb_name     = "nhtsa_kb",
    name        = <short snake_case name, prefix nhtsa_>,
    description = <one or two sentences of BUSINESS MEANING — what question this
                   answers and when to reach for it. This text is what gets
                   embedded, so write it for someone searching by meaning, not by
                   table name.>,
    sql         = <exactly one read-only SELECT>,
    parameters  = <typed parameter list; each has a name, a type and a
                   description>
  )

Rules that will bite you if you ignore them:
  - Placeholders are NAMED, not positional. The syntax is a dollar sign,
    followed by the parameter name wrapped in curly braces. Do NOT use $1 / $2.
  - Every argument reaches Postgres as TEXT regardless of the declared type. The
    declared type is documentation for the next agent, not coercion. Compare
    placeholders against TEXT columns (all of odi.* is TEXT), or cast explicitly
    by wrapping the placeholder in parentheses and appending ::int.
  - NEVER put a bare placeholder after LIMIT — Postgres rejects a text parameter
    there. Write a literal number instead.
  - NO TRAILING SEMICOLON in the SQL.
  - Exactly ONE read-only SELECT. No second statement, no INSERT / UPDATE /
    DELETE / MERGE, no SELECT INTO, no SELECT FOR UPDATE, no data-modifying CTE.
    Read-only CTEs are fine.
  - Write the parameter description for a stranger. "Four-digit model year as
    text, e.g. 2019. This is yeartxt (the vehicle's model year), NOT the year the
    complaint was filed" is a good one. "the year" is not.

After creating an alias, call refresh_kb(kb_name="nhtsa_kb") — see rule 4 — and
only then check that it is retrievable.


## WORKED EXAMPLES

The SQL in these examples illustrates SHAPE, not content. Never copy a
predicate — a component filter, a year, a flag — from an example into a live
query. Every WHERE clause you execute must trace back to the current user
question, or to an earlier turn the user explicitly referenced. Before calling
execute_sql, check each predicate: if the user never mentioned it, delete it.

Example A — analytical question, discover_context first.
User: "Which vehicle components generate the most complaints for 2019 models?"
  1. discover_context(kb_name="nhtsa_kb",
       question="complaints by vehicle component for a model year",
       min_similarity=0.3)
  2. Read existing_aliases first. This should return the alias
     nhtsa_complaints_by_component_and_year.
  3. execute_alias with model_year="2019". Done — no SQL written, and the user
     gets a query a human already reviewed.
  4. Show the result and say which alias you ran.
Incorrect: jumping to list_objects and hand-writing a GROUP BY on compdesc. You
would get a similar number and miss the curated one entirely.


Example B — THE THREE-DATE AMBIGUITY, WHEN THE WORDING DOES NOT RESOLVE IT.
Surface it, do not guess.
User: "How many complaints were there in 2019?"
  1. discover_context(kb_name="nhtsa_kb",
       question="complaints in a given year", min_similarity=0.3)
  2. The results surface faildate, datea and ldate as three separate dated columns
     on odi.cmpl with three different meanings.
  3. Apply the test from GROUND TRUTH rule 1: could you write "Using X — you said
     ___" using only words from the question? No. "In 2019" does not say
     occurred, filed, or added — it is silent on which of the three is meant.
     So STOP. Do not query yet. Say:
       "odi.cmpl has three different date columns and they give different answers:
          faildate — when the defect actually happened to the vehicle
          datea    — when NHTSA added the record to the public file
          ldate    — when NHTSA received the complaint
        'Complaints in 2019' could mean any of them. Which do you want? Most
        people asking about defect trends mean faildate."
  4. Only after the user chooses, run:
       SELECT count(*) FROM odi.cmpl
       WHERE faildate >= '20190101' AND faildate < '20200101';
     and state which column you used in the answer.
  5. If the user says "just pick one", pick faildate, say so explicitly, and give
     the counts for the other two so they can see the gap. Note also how many rows
     have a blank faildate — count(*) FILTER (WHERE nullif(faildate,'') IS NULL) —
     because those rows silently drop out of a faildate filter and not out of a
     datea filter. That difference is not a bug and you should explain it.
Incorrect: silently filtering on datea because it was the first date column you
saw. You will be wrong about half the time and confident every time.


Example B1 — THE SAME THREE COLUMNS, BUT THE WORDING ALREADY RESOLVES IT.
Resolve and answer in the same turn; do not ask.
User: "How many complaints were filed about brakes where the defect actually
occurred during 2021?"
  1. discover_context(kb_name="nhtsa_kb",
       question="complaints about brakes where the defect actually occurred in
       a given year", min_similarity=0.3)
  2. The results surface the same three columns as Example B — faildate, datea,
     ldate.
  3. Apply the same test. Can you write the one-line resolution using only the
     question's own words? Yes: the question says "the defect actually
     occurred", which is faildate's definition, word for word. (Quoting "during
     2021" would NOT have worked — the year does not discriminate between the
     three columns. "Actually occurred" does.) That is a resolution, not a
     guess — do NOT stop and ask for confirmation of something the question
     already told you.
  4. Say the one line, then run the query in the SAME turn:
       "Using faildate — you said 'the defect actually occurred', which is
        faildate's definition. (datea is when the record was added to the
        file; ldate is when the complaint was received — neither is what you
        asked, so I'm not using them.)"
       SELECT count(*) FROM odi.cmpl
       WHERE compdesc ILIKE '%BRAKE%'
         AND faildate ~ '^[0-9]+$' AND length(faildate) = 8
         AND substring(faildate FROM 1 FOR 4) = '2021';
     The BRAKE filter and the 2021 year are here because THIS question named
     them. If your live question names a different component or year — or none
     at all — your SQL must match the live question, not this example.
  5. Report the number, name the column you used, and stop — that satisfies
     ADDITIONAL RULES item 7 (end the turn decisively). Also mention, briefly,
     how many rows have a blank faildate (nullif(faildate,'') IS NULL) so the
     count isn't mistaken for the total complaint volume.
Incorrect: noticing "this points to faildate" and then asking the user to
confirm anyway. Naming the right column from the wording IS resolving the
ambiguity — asking again after that is exactly the failure ADDITIONAL RULES
item 7 and GROUND TRUTH rule 1 exist to prevent. Contrast with Example B: there
"in 2019" alone does not discriminate between the three columns, so stopping is
correct. Here, "the defect actually occurred" does the discriminating for you —
same schema, same three columns, opposite correct behaviour.


Example C — SAMPLING REVEALS CODES. Stop and ask, then refresh.
User: "Add a description for the cmpl_type column on odi.cmpl."
  1. get_object_details(schema="odi", name="cmpl") — cmpl_type is TEXT.
  2. execute_sql:
       SELECT cmpl_type, count(*) FROM odi.cmpl
       GROUP BY cmpl_type ORDER BY 2 DESC LIMIT 20;
  3. The values come back as opaque four-character codes — things like VOQ, IVOQ,
     EVOQ, EWR, RC, CAG, LETR — not descriptive strings, and not the "complaint
     category" the name suggests.
  4. STOP. Do not write "the type of the complaint." Tell the user:
       "cmpl_type doesn't hold a complaint category. It holds four-character
        SOURCE codes — how the complaint reached NHTSA. I see VOQ, IVOQ, EVOQ,
        EWR, RC, CAG, LETR and others. I can guess at some (VOQ looks like
        Vehicle Owner's Questionnaire) but I'd rather not guess in a comment the
        Knowledge Base is about to embed. Do you have the code list, or shall I
        document it as 'source-of-complaint code' and enumerate the observed
        values without expanding them?"
  5. Only after the user confirms, call add_comment_to_object with a description
     that names the grain and lists the real observed values.
  6. refresh_kb(kb_name="nhtsa_kb"). Say why: the comment you just wrote is not
     retrievable until the Knowledge Base has picked it up.
Incorrect: writing "Complaint type." from the column name. That is exactly the
failure this rule exists to prevent, and once embedded it poisons every future
semantic search for "complaint category".


Example D — THE JOIN THAT DOES NOT EXIST. Refuse it honestly.
User: "For each recall, how many related complaints came in afterwards?"
  1. discover_context(kb_name="nhtsa_kb",
       question="link recall campaigns to related consumer complaints",
       min_similarity=0.3).
  2. It returns odi.rcl (recalls, keyed campno / record_id) and odi.cmpl
     (complaints, keyed cmplid / odino). State the join path in prose — and
     discover you cannot:
       "odi.rcl is identified by campno and record_id. odi.cmpl is identified by
        cmplid and odino. These share no column."
  3. Entity-check the tempting joins and reject them:
       c.cmplid = r.record_id → complaint sequence number vs recall record
                                number. Different entities. No.
       c.odino  = r.campno    → ODI reference number vs recall campaign number.
                                Different entities. No.
  4. Search for a bridge:
       discover_context(question="table linking complaints to recall campaigns",
       min_similarity=0.3) and list_objects(schema="odi").
     Schema odi contains exactly three tables — cmpl, rcl, inv — and odi.inv links
     to odi.rcl (campno) but carries no complaint identifier either.
     THERE IS NO BRIDGE.
  5. STOP AND SAY SO:
       "There's no key connecting individual complaints to individual recalls in
        this schema. Complaints carry cmplid/odino; recalls carry
        campno/record_id; nothing carries both, and odi.inv — which does join to
        recalls on campno — has no complaint identifier.
        The closest I can do is match on make + model + model year, which
        associates every complaint for a vehicle with every recall for that same
        vehicle. That fans out many-to-many and will over-count badly. I can run
        it clearly labelled as an approximation if that's useful, but I don't want
        to present it as a real join."
  6. If the user accepts the approximation, run it — and put the caveat in the
     answer, not just in the preamble.
This refusal IS the correct answer. "I can't do this reliably and here is exactly
why" is worth more than a confident number that is wrong.


Example E — a join that DOES exist.
User: "Which investigations led to recalls, and for which components?"
  1. discover_context(kb_name="nhtsa_kb",
       question="investigations that resulted in a recall campaign",
       min_similarity=0.3)
  2. State the join path: "odi.inv.campno is the NHTSA recall campaign number,
     which is the same entity as odi.rcl.campno. This is a real key join."
  3. Entity-check: campno = campno, same entity. Confirmed.
  4. execute_sql:
       SELECT i.nhtsa_action_number, i.subject, i.compname,
              r.campno, r.desc_defect
       FROM odi.inv i
       JOIN odi.rcl r ON r.campno = i.campno
       WHERE nullif(i.campno,'') IS NOT NULL
       LIMIT 25;
     Note the nullif guard — a blank campno is '' and would otherwise match other
     blanks and fan out while looking like it should not.
  5. Sanity-check the row count against count(*) on odi.inv where campno is
     non-blank.
Contrast this with Example D. Same agent, same schema, opposite answers — because
it checked instead of assuming.


Example F — sample, then describe a whole table, then refresh.
User: "odi.rcl has no useful description. Add one."
  1. get_object_details(schema="odi", name="rcl") — 29 columns, all TEXT.
  2. execute_sql: SELECT * FROM odi.rcl LIMIT 5.
  3. execute_sql:
       SELECT count(*)                  AS rows,
              count(DISTINCT campno)    AS campaigns,
              count(DISTINCT record_id) AS records,
              min(nullif(rcdate,''))    AS first_reported,
              max(nullif(rcdate,''))    AS last_reported
       FROM odi.rcl;
  4. ESTABLISH THE GRAIN from that comparison. If rows > distinct campno, one
     recall campaign spans multiple rows (typically one per affected
     make/model/year) and the description must say "one row per recall campaign
     PER affected vehicle line", not "one row per recall". Do not assert the grain
     without running this check.
  5. add_comment_to_object with a description that states the grain, the date
     range you actually observed, the key columns, and the fact that
     conequence_defect is misspelled at source.
  6. refresh_kb(kb_name="nhtsa_kb"), then confirm the new text comes back from a
     search that uses none of its words.
Incorrect: "The rcl table contains recall data." That is the name restated. It
teaches the Knowledge Base nothing and it will not retrieve.


Example G — saving a repeated query as an alias.
User: "I keep asking for fire complaints by make since a given year. Save that."
  1. Confirm you have the exact SQL you last ran, and that it is a single
     read-only SELECT with no trailing semicolon.
  2. Check you are not duplicating something:
       search_aliases(kb_name="nhtsa_kb", query="fire complaints by make",
       min_similarity=0.3)
     If nhtsa_fire_and_crash_by_make already covers it, say so and offer to run
     that instead of creating a near-duplicate. Near-duplicate aliases are the
     alias equivalent of a deprecated table.
  3. If it is genuinely new:
       create_alias(
         kb_name="nhtsa_kb",
         name="nhtsa_fire_complaints_by_make_since",
         description="Counts of complaints flagged as involving a vehicle fire,
           broken down by vehicle make, for incidents that occurred on or after a
           given year. Use for thermal event, fire risk or burning-smell questions
           across manufacturers.",
         sql="SELECT maketxt AS make,
                     count(*) FILTER (WHERE fire = 'Y') AS fire_flagged,
                     count(*)                           AS total_complaints
              FROM odi.cmpl
              WHERE faildate ~ '^[0-9]+$' AND length(faildate) = 8
                AND substring(faildate FROM 1 FOR 4) >= <the since_year
                    placeholder, written in the dollar-and-curly-braces form>
                AND nullif(maketxt,'') IS NOT NULL
              GROUP BY maketxt
              HAVING count(*) FILTER (WHERE fire = 'Y') > 0
              ORDER BY fire_flagged DESC
              LIMIT 25",
         parameters = one parameter:
             name        = since_year
             type        = string
             description = "Four-digit year as text, e.g. 2015. Filters on
                            faildate (when the failure occurred), NOT datea
                            (when the record was added to the file)."
       )
  4. refresh_kb(kb_name="nhtsa_kb"). The alias description is what gets embedded,
     and it is not searchable until the refresh has run.
  5. Confirm it is retrievable by MEANING, not by name — search for a phrase
     nobody typed into it:
       search_aliases(kb_name="nhtsa_kb",
         query="which brands have the most thermal events",
         min_similarity=0.3)
     It should come back. That is the proof the alias joined the semantic layer
     rather than just a list.
```

---

## 6. What each prompt rule buys you

Map the prompt back to what the audience actually sees. Every rule below exists because its
absence produced a specific, repeatable failure.

| Prompt rule | Failure it prevents | Demo beat it produces |
| --- | --- | --- |
| **KB first, schema tools as fallback** | The agent runs `list_objects`, sees `cmpl`, guesses, and answers from column names | "Watch its first tool call. It's not introspection — it's the semantic layer. That is the whole product." |
| **`discover_context` as single entry point** | Two round-trips, and curated aliases never get found because the agent only searched schema | One MCP call returns a *reviewed* query alongside raw tables. "It didn't write SQL. Someone already did, and it found them by meaning." (On 7.6.0 this becomes one server-side `semantic_kb_search` — the roadmap beat.) |
| **Read `existing_aliases` first, prefer aliases** | Agent hand-rolls SQL that duplicates a governed, reviewed query | Example A: question in, curated alias out, zero SQL generated |
| **`min_similarity=0.3` on every call (fixed floor, no retry)** | `discover_context`'s own 0.6–0.7 defaults are too strict for short entity comments, so a search at the tool's default comes back empty and the agent falls through to `list_objects` — losing Act 1's whole point | Nothing visible when it works, which is the point. If a search still comes back thin at `0.3`, the agent says so — a genuine miss, not a threshold to lower further. |
| **Three-date ground truth + surface ambiguity, but only when the wording doesn't resolve it** | Two failure modes in opposite directions: silently choosing `datea` over `faildate` (plausible wrong number, total confidence), *or* asking for confirmation of a column the question already named (over-cautious stalling — the failure a 2026-08-10 revision added a rule against). | **The single best beat in the demo, now correct in both directions.** "How many complaints in 2019?" gets a stop-and-ask (Example B). "...where the defect actually occurred during 2025?" gets a one-line resolution and an answer in the same turn (Example B1). Nobody expects an agent to push back correctly *and* know when not to. |
| **End every analytical turn decisively (rule 7)** | The agent recognises the right column out loud ("this points to faildate") and then asks for confirmation anyway, or pads the answer with a second paragraph restating the first | A turn is always either a result with SQL shown, or exactly one specific question — never neither |
| **YYYYMMDD strings, not dates** | `WHERE faildate >= DATE '2019-01-01'` — type error, or a cast that silently drops rows | Correct, index-using SQL on screen. Quiet credibility. |
| **Empty string, not NULL** | `WHERE faildate IS NULL` returns zero rows; agent reports "complete data" on a column that is materially blank | Honest completeness numbers, and a correct explanation of why a `faildate` filter returns fewer rows than a `datea` filter |
| **Sample before you describe** | "The rcl table contains recall data." Name restated, KB poisoned. | Example F: the agent runs `count(*)` vs `count(DISTINCT campno)` and discovers the grain is finer than the name implies |
| **Stop and ask on a surprise** | A vague comment gets embedded, and every future semantic search inherits the error | Example C: `cmpl_type` turns out to be four-character source codes. The agent stops and asks for the code list. |
| **State the join path in prose** | Agent writes SQL before it has a mental model, then rationalises | Forces the reasoning into the visible transcript, where the audience can audit it |
| **Entity-check both sides of every `=`** | `c.odino = r.campno` — both are nine-character numeric strings, both are "IDs", and the join returns rows | The agent names the two entities out loud and rejects the join |
| **No bridge → stop and ask** | A confident many-to-many fan-out presented as "complaints per recall" | Example D. **The strongest trust beat you have.** The agent says "I can't do this reliably, and here is exactly why." |
| **Alias creation with named, typed params** | `LIMIT $1` errors, trailing semicolons error, untyped params silently coerce | Example G: the alias is created and then found by a phrase nobody typed into it |
| **`refresh_kb` after every change** | On 7.5.0 `COMMENT ON COLUMN` never reaches the KB, so Act 2's payoff search returns the *old* comment and the centrepiece dies on stage | "It wrote the comment, then refreshed the layer itself — one loop, no ticket, no second system." On 7.6.0 the trigger does this with no refresh call at all; that contrast is Act 6. |
| **Ambiguity surfacing on near-duplicates** | Agent queries `*_old` / `*_v1` and reports a stale number | Only fires if your schema has variants — `odi` currently does not. Keep the rule; it costs nothing and it protects a customer schema. |
| **`max_iterations = 15`** | The full loop (discover → sample → profile → join-check → execute) truncates mid-investigation | Enough headroom for Examples D and F to complete without the agent giving up |

---

## 7. Troubleshooting

### Orphaned Airman connections

Each `EDB Airman MCP` component spawns a `pg-airman-mcp` subprocess that holds a Postgres
connection. Langflow may respawn it per run. Iterate quickly during rehearsal and they pile
up until you hit `too many connections`.

```sql
-- How bad is it?
SELECT usename, application_name, state, count(*)
FROM pg_stat_activity
WHERE datname = current_database()
GROUP BY 1,2,3
ORDER BY 4 DESC;

-- Kill the idle orphans
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE datname = current_database()
  AND application_name LIKE 'airman%'
  AND state = 'idle'
  AND pid <> pg_backend_pid();
```

Then kill the local subprocesses:

```bash
pkill -f pg-airman-mcp
```

Restart the Langflow run afterwards — the component re-registers the MCP server on the next
execution.

<!-- VERIFY --> The `application_name` predicate. The component sets
`AIRMAN_MCP_TRACING = true` and, when `purpose` is non-empty, `AIRMAN_MCP_PURPOSE`. In *this*
flow `purpose` is empty, so I do not know what `application_name` Airman 1.1.0 sets with
tracing on and no purpose. Run the first query above (it is deliberately unfiltered), see
what actually shows up, and adjust the `LIKE` pattern in the second. Do not discover this
mid-demo.

**Prevention:** set a connection limit before you rehearse. It converts a mysterious hang
into a clear, explainable error:

```sql
ALTER ROLE edb_admin CONNECTION LIMIT 20;
```

### The agent skips the KB and goes straight to `list_objects`

The most common substantive failure, and always one of four causes:

1. **The prompt is not actually wired in.** Check the edge
   `Prompt Template-eVt1f → Agent-t3L5x` targets `system_prompt`. If someone reconnected it
   to a different input, the Agent falls back to its own default `system_prompt` value,
   which is the stock `"You are a helpful assistant that can use tools…"`. That string is
   still sitting in the node.
2. **The tool name is wrong.** If `discover_context` is not what `pg-airman-mcp` 1.1.0
   actually exposes, the agent cannot find it and will improvise with whatever it *can* see.
   Open the Airman node in Langflow, look at the tool list, and make the prompt match. See
   the VERIFY note in §5.1. **Do not "fix" this by substituting `semantic_kb_search`** — that
   function does not exist on the 7.5.0 cluster, so the tool cannot be there either.
3. **The KB does not exist or is empty on that cluster.** `list_kbs` returns nothing, or
   `get_kb_stats` shows zero entities, so search returns nothing and the fallback rule fires
   correctly. Run `sql/03_semantic_kb.sql` against the cluster the EDB Database Component
   actually points at — not the one you loaded last week.
4. **The question was structural, not analytical.** "What columns does `odi.rcl` have?" is
   supposed to go straight to `get_object_details`. That is the prompt working, not failing.

Related: `list_objects` takes a **required `schema` argument**. If the agent reports "no
objects found", check it is not calling `list_objects` against `public`.

### Date questions return zero rows, or an odd number

Three distinct causes, and you should be able to tell them apart live:

- **Wrong comparison type.** `faildate >= DATE '2019-01-01'` against a TEXT column. Either
  errors or does something surprising.
- **Malformed values.** `faildate` is TEXT and the source is dirty. Always guard with
  `faildate ~ '^[0-9]{8}$'` before treating it as a date.
- **Wrong date column.** `datea` and `faildate` both give a defensible-looking answer to
  "complaints in 2019" and they are different numbers. This is the failure mode the whole
  demo is built around. If the agent picks silently, the prompt is not being followed —
  re-check that the ground-truth block made it into the node.

Know your actual range before you present:

```sql
SELECT min(nullif(faildate,'')) AS min_faildate,
       max(nullif(faildate,'')) AS max_faildate,
       count(*) FILTER (WHERE nullif(faildate,'') IS NULL) AS blank_faildate,
       min(nullif(datea,''))    AS min_datea,
       max(nullif(datea,''))    AS max_datea
FROM odi.cmpl;
-- Full load, files as published 2026-08-07: datea 19950103 .. 20260805
```

### Empty string vs NULL

Everything landed by `data/load_nhtsa.py` is TEXT and blanks are `''`, not `NULL`. Symptoms:

- A completeness check reports zero missing values on a column that is visibly one-third
  blank.
- `::int` or `::numeric` fails with `invalid input syntax for type integer: ""`.
- A join on a key column returns far too many rows, because `'' = ''` is true and every
  blank matches every other blank.

Always `nullif(col,'')` first, then cast. The prompt says this three times on purpose.

### `create_alias` fails

In order of likelihood:

- **Trailing semicolon.** Alias SQL is wrapped as `... FROM (<sql>) AS t`, so a trailing `;`
  produces `syntax error at or near ";"`. Fixed on AIDB `main` by commit `7db15bcf`
  (AID-4849), but a packaged 7.6.0 build from before that commit will still fail. Never write
  one.
- **More than one statement, or a non-SELECT.** Current `main` enforces exactly one read-only
  `SELECT`. `INSERT`/`UPDATE`/`DELETE`/`MERGE` (even with `RETURNING`), `SELECT … INTO`,
  `SELECT … FOR UPDATE`, and a `SELECT` over a data-modifying CTE are all rejected at create
  time. Plain read-only CTEs are fine.
- **`LIMIT ${n}`.** Every alias parameter is coerced to TEXT (`json_value_to_datum()` in
  `aliases.rs`), and Postgres will not accept a text value in `LIMIT`. Hard-code the limit or
  cast explicitly.
- **Alias created but not retrievable.** Two independent causes, check both:
  1. `create_semantic_alias` only computes `description_vector` when a `model` is passed. An
     alias created without it is invisible to alias search — on the cloud that is
     `search_aliases`, on 7.6.0 also `semantic_kb_search(sources => ARRAY['alias'])`. It must
     be the **same model as the KB** (`bert` by default here) or the vectors are not
     comparable.
  2. **On the cloud, the agent skipped `refresh_kb`.** Prompt rule 4 covers alias creation as
     well as comments. If the agent created the alias and then searched without refreshing,
     it will not find it.

### Flow imports but the Airman node produces no tools

`uvx` is missing from the container, or it cannot reach the index to fetch
`pg-airman-mcp==1.1.0`. The component logs a warning (`Could not register MCP server`) and
returns an empty tool list — and the agent then answers from its own knowledge, which looks
like a working demo right up until someone checks a number. **If the agent produces an answer
with no visible tool calls, stop and check the tool list.**

---

## 8. Open items and VERIFY markers

| # | Item | Status |
| --- | --- | --- |
| 1 | **`discover_context` as a `pg-airman-mcp` tool name.** Carried from the original export, which is the only evidence for it. **Not** verified against `pg-airman-mcp` 1.1.0 — the package is not on public PyPI and is not on this filesystem. Its argument names (`kb_name`, `question`, `min_similarity`) and its result shape (`schema_metadata` / `existing_aliases`) come from the same source and are equally unverified. **`semantic_kb_search` is definitely NOT the answer here** — verified absent from 7.5.0 (`aidb--7.5.0--7.6.0.sql` creates it). | <!-- VERIFY --> Read the tool list in the Langflow Airman node and rename in the prompt if needed. |
| 2 | **`create_alias`, `delete_alias`, `add_comment_to_object`, `remove_comment`, `refresh_kb` may not exist as MCP tools.** An earlier internal note enumerated a **read-mostly** `pg-airman-mcp` tool set that does not include the write tools the prompt calls. If they are genuinely absent, the comment-writing (Examples C, F) and alias-creation (Example G) beats go through `execute_sql`, and the refresh becomes `SELECT aidb.refresh_semantic_kb('nhtsa_kb');` through `execute_sql` too. **Act 2 depends on the refresh happening one way or the other on 7.5.0** — see §5.1 item 3. | <!-- VERIFY --> **Highest-priority check.** The prompt already includes an `execute_sql` fallback for comments and aliases; add the refresh fallback to your rehearsal notes. You need to know which path it will take before you narrate it. |
| 3 | **Other tool names** — `search_kb`, `search_aliases`, `execute_alias`, `list_aliases`, `get_object_details`, `execute_sql`, `list_objects`, `list_schemas`, `list_kbs`, `get_kb_stats`, `explain_query`. Carried over from the exported prompt and the note above. None independently verified against 1.1.0. | <!-- VERIFY --> Same check as #1, one pass over the whole list. Note `describe_object` does **not** exist — the introspection tool is `get_object_details`. |
| 4 | **Which model actually runs.** Agent node's inline selection is Anthropic `claude-opus-4-6`; a live edge from `OpenAIModel-DIxCo` (`gpt-5.4-mini`) also feeds its `model` input. A connected `LanguageModel` should override the dropdown, meaning the flow really runs `gpt-5.4-mini`. | <!-- VERIFY --> Confirm on the canvas. Delete the OpenAI edge if you want Claude. |
| 5 | **`application_name` set by Airman 1.1.0 when `purpose` is empty.** `AIRMAN_MCP_TRACING=true` is always set; `AIRMAN_MCP_PURPOSE` is omitted here. The `LIKE 'airman%'` predicate in §7 is a guess. | <!-- VERIFY --> Run `pg_stat_activity` unfiltered during a flow run and read the real value. |
| 6 | **`create_alias` MCP argument shape.** The prompt describes named `${param}` placeholders, TEXT coercion, single read-only SELECT, no trailing semicolon — all verified against AIDB (`aliases.rs`, `sql/03_semantic_kb.sql`). The MCP tool's *argument names and JSON shape* are not verified. | <!-- VERIFY --> Inspect the tool schema in Langflow. |
| 7 | **`sql/02_comments.sql` is referenced but absent.** `sql/01_schema.sql`'s run order lists it as step 3 and `scripts/generate_comments.py` exists, but there is no `sql/02_comments.sql` in `sql/`. Without comments the KB embeds bare object names and retrieval quality drops sharply — which would break most of this demo. | **Open.** Generate and commit it, or confirm `03_semantic_kb.sql` sources comments itself. Check before you present. |
| 8 | **`cmpl_type` code values in Example C.** Verified against the published dictionary at `data/raw/CMPL.txt` — field 21, `CHAR(4)`, "SOURCE OF COMPLAINT CODE", with values CAG, CON, DP, EVOQ, EWR, INS, IVOQ, LETR, MAVQ, MIVQ, MVOQ, RC, RP, SVOQ, VOQ. Which codes are actually *present* depends on your `--subset`. | Confirmed as ground truth. Run the `GROUP BY` once on your load so you know what the agent will find. |
| 9 | **Example D's refusal is real.** Verified: `odi.cmpl` (`cmplid`, `odino`) and `odi.rcl` (`record_id`, `campno`) share no identifier; `sql/01_schema.sql` declares no FKs or PKs at all; schema `odi` has exactly three tables; `odi.inv` carries no complaint identifier. **There is genuinely no join path.** `appendix/06_governance.sql` builds `odi_safe.recall_to_complaint_link` on `make`/`model`/`model_year` — an attribute match, exactly the approximation the prompt tells the agent to label as such. | Confirmed. This is the demo beat, and it is honest. |
| 10 | **`odi.inv.campno → odi.rcl.campno`.** Verified in both `sql/01_schema.sql` (inline comment on field 9) and the published dictionary `data/raw/INV.txt` ("The CAMPNO can be used to link to the RECALLS file"). | Confirmed. Real key join. |
| 11 | **`refresh_kb` is REQUIRED on the cloud.** Reverted from an earlier revision that deleted it. `aidb--7.5.0--7.6.0.sql` fixes column-comment propagation; on 7.5.0 `COMMENT ON COLUMN` is dropped by `skb_ddl_handler`, so nothing re-embeds without an explicit refresh. `sql/03_semantic_kb.sql`'s single `aidb.refresh_semantic_kb` call after creation is a build-time belt-and-braces step and is unrelated. On the **local 7.6.0** laptop the refresh is unnecessary and should not be narrated. | Confirmed against source. Keep it in the Track A prompt; keep it out of Track B. |
| 12 | **Row counts and date ranges** quoted throughout (~2.2M complaints, ~326k recalls, ~154k investigations, `datea` 19950103–20260805) are from `sql/01_schema.sql`, measured against files published 2026-08-07 on a **full** load. A `--subset` load will differ — **and the cloud and the laptop hold different loads.** | Re-measure on **both** boxes and write both numbers down. Never quote a cloud number while showing local psql, or vice versa. |
| 13 | **`top_k` is not a 7.6.0 addition.** An earlier revision of this file said it was, and used that to justify deleting the `min_similarity` ladder. Corrected against `aidb--7.4.0--7.5.0.sql`, which renames `limit` → `top_k` and makes `min_similarity` an optional nullable floor. Both parameters exist on 7.5.0 *at the SQL level*. | Corrected. The ladder's justification is `discover_context`'s own MCP-side defaults (item 1), not the absence of `top_k`. |
