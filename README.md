# Semantic Knowledge Base — Mercedes-Benz Demo

**Audience:** Mercedes-Benz Group / Mercedes-Benz Tech Innovation, as a sponsorship and design-partnership conversation for the Semantic Knowledge Base project.

**Duration:** ~26 minutes live, plus Q&A.

**Core claim:**

> The hard part of Text-to-SQL is not the model. It is *retrieval* — knowing which
> tables and columns a question actually refers to. On a real enterprise schema with
> cryptic physical column names, a frontier model is confidently wrong. A small local
> model with a semantic layer is right. The semantic layer is the durable asset, it is
> the part that runs inside your database — and it is not a static export. **The agent
> builds and maintains it.**

---

## Two environments — read this first

**This demo runs against two separate databases on two different aidb versions.** Almost
every operational mistake in this repo's history traces back to forgetting that. Every
instruction in `RUNBOOK.md` and `STEP-BY-STEP.md` is tagged **[CLOUD]** or **[LOCAL]**.

| | **[CLOUD] EDB Hybrid Manager Postgres** | **[LOCAL] Tim's branch, presenter's laptop** |
| --- | --- | --- |
| aidb version | **7.5.0** | **7.6.0** |
| Langflow access | **yes** — Track A runs here | no |
| Agent hub usable for this demo | **no** (see below) | **yes** — Track B runs here |
| `aidb.semantic_kb_search` | **does not exist** | yes |
| Retrieval entry point | MCP **`discover_context`**, fanning out over `get_entity_definitions` + `get_metadata` + `search_semantic_aliases` | one server-side `semantic_kb_search` call |
| `top_k` on the retrieval functions | **yes** — it is *not* new in 7.6.0 | yes |
| `min_similarity` | the `0.5 → 0.3` ladder is **required** | optional |
| `COMMENT ON COLUMN` → KB | **broken** — explicit `refresh_kb` required | automatic, same transaction |
| Acts | 0–5 | 6–7 |
| Data load | `--subset 250000` (2.2M rows into an HM cluster is slow) | fuller load |

Every version claim above was checked against the migration files in `aidb/sql/`, and two
claims that were circulating turned out to be **wrong**:

- **`top_k` is not new in 7.6.0.** It arrived in `aidb--7.4.0--7.5.0.sql` (*"`top_k` becomes
  the primary result cap (renamed from the old `limit`)"*), with `min_similarity` demoted to
  an optional nullable floor. Both exist on the cloud. The `min_similarity` ladder belongs in
  the Track A prompt because **`discover_context` is an MCP tool with its own 0.6–0.7
  defaults**, which are too strict for short entity comments — not because `top_k` is absent.
- **The agent hub is not new in 7.6.0.** `aidb--7.4.0--7.5.0.sql` creates `create_agent`,
  `update_agent`, `delete_agent` and `agent_converse` (AID-4108). Track B is still local-only,
  but for concrete reasons: `sql/04_agents.sql` gives its agent the **`semantic_kb_search`
  native tool** (added with the 7.6.0 function by AID-2200), tears down with
  `delete_agent(force => true)`, and every call uses `agent_converse(debug => true)`. The
  `force` and `debug` parameters are both added by the 7.5.0→7.6.0 migration.

Verified and load-bearing: `aidb--7.5.0--7.6.0.sql` CREATEs `aidb.semantic_kb_search` ("New
function in this version"), and is titled in part *"Fix column-comment propagation:
skb_ddl_handler now handles 'table column' object types (COMMENT ON COLUMN) … instead of
dropping the event."* On 7.5.0 the handler branches only on `'table'`/`'view'`; a column
comment falls through to `CONTINUE` and is dropped. **Act 2 writes a column comment**, so on
the cloud the explicit refresh is a required workaround, not stale cruft.

**Three practical consequences.**

1. **Load the NHTSA data into both databases**, and expect **different row counts**. Never
   quote a number from one environment while showing the other.
2. **Track B is local-only:** `sql/04_agents.sql`, `sql/90_observability.sql`,
   `fallback/dummy_model.sql`, the local-GGUF swap and the whole `eval/` harness.
3. **There is a mid-demo environment switch** between Act 5 and Act 6. It is scripted in
   `RUNBOOK.md` under *The switch*, with a line to say.

**Frame the version gap as a roadmap beat, not something to conceal.** Between the cloud and
the laptop, three retrieval calls become one and the refresh disappears. For a sponsorship
conversation that is an asset: they see the shipping thing work, then they see where it is
going, and the ask makes sense.

---

## Why this demo is built the way it is

### 1. The Semantic Knowledge Base is the deliverable, and it builds itself

The demo is not "here is a semantic layer". Everyone can export a schema once. The demo
is what happens **after** the export: an agent hits a column the publisher never
explained, goes and samples the data, refuses to write a description it cannot ground,
and — once a human answers its question — writes a comment that the layer picks up in the
same transaction. Then a query that worked becomes a curated alias that the next person
retrieves by meaning.

Two moments carry the whole argument, and both are things a static semantic layer cannot
do:

- **Act 2 — it looked.** The agent documents `odi.rcl.rcltypecd` by running
  `get_object_details`, `SELECT * LIMIT 5` and a `GROUP BY` before writing prose, and
  stops to ask when the values turn out to be codes with no published legend. Then it makes
  its own work retrievable: on the **[CLOUD]** 7.5.0 cluster where Act 2 runs, it calls
  `refresh_kb` itself, in the same turn, with no ticket and no second system. On the
  **[LOCAL]** 7.6.0 laptop the `ddl_command_end` trigger re-embeds the column in the same
  transaction as the `COMMENT ON` and the refresh disappears — **that contrast is Act 6**,
  and it is a roadmap beat, not an omission.
- **Act 5 — it compounds.** A working query is saved as a semantic alias with a business
  description and typed parameters. The next question returns that alias *alongside*
  schema objects in one ranked list, so the agent executes curated SQL instead of
  regenerating it.

### 2. It shows two runtimes, deliberately

| Track | Environment | Runtime | Status | What it proves |
| --- | --- | --- | --- | --- |
| **A — External agent** | **[CLOUD]** HM, aidb **7.5.0** | Langflow + `pg-airman-mcp` | Ships today | Conversational analytics over the KB. The semantic layer is the mandatory first hop; the agent enriches it by sampling data and writing grounded comments, refreshes the layer itself, and curates aliases as it goes. |
| **B — In-database agent** | **[LOCAL]** laptop, aidb **7.6.0** | `aidb.agent_converse()` | Work in progress | The ReAct loop runs *inside* the Postgres backend. No orchestrator, no egress, audit trail written in the same transaction as the query — plus the two 7.6.0 simplifications: one fused retrieval call, and column comments that propagate with no refresh. |

The KB is **built in AIDB** and consumed over MCP by Track A. That is the whole argument:
**one layer, two consumers.** MCP is transport, not logic. The runtime is converging into
Postgres; the semantic layer is the constant across both.

The two tracks also sit on **two different databases at two different versions** — see *Two
environments* above. Same KB *definition*, same comments, same embedding model; separate
loads, separate row counts, and a version delta the audience gets to watch.

This matters for a sponsorship conversation specifically. Sponsors fund *direction*,
not finished products. Showing only the finished thing (Track A) invites "nice, we'll
buy it when it's done." Showing only the unfinished thing (Track B) invites "come back
next year." Showing both, in that order, invites "how do we shape this?"

**Access control is deliberately not a demo act.** It is orthogonal, it is ordinary
PostgreSQL, and it lives in `appendix/06_governance.sql` for the moment someone asks
"how do we control who sees what?" See the runbook's *If they ask about access control*.

### 3. It uses a dataset where the semantic layer is *necessary*, not decorative

The previous demo used the Olist Brazilian e-commerce dataset. Its columns are named
`order_purchase_timestamp`, `payment_type`, `customer_state`. Any competent model does
Text-to-SQL on that with zero schema assistance — so the demo could not show what SemKB
is *for*.

This demo uses the **NHTSA Office of Defects Investigation** flat files. Real, public
domain, automotive, updated daily. The column names are genuinely opaque:

```
CMPLID   ODINO   COMPDESC   CMPL_TYPE   LDATE   DATEA   FAILDATE
ORIG_EQUIP_YN    LOC_OF_TIRE    OCCURENCES    PROD_TYPE    MFR_NAME
```

Three different date columns. No model can guess which one means "when the defect
occurred" versus "when the record was added to the file." Worse, `datea` exists in
**both** `odi.cmpl` and `odi.rcl` and means something different in each — "date added to
file" versus "record creation date". **That is not a contrived failure — it is a real
public dataset that behaves exactly like an SAP-derived enterprise warehouse.**

The names lie in the other direction too. `cmpl_type` sounds like the subject of a
complaint; the dictionary says it is the **intake channel** (`VOQ`, `IVOQ`, `LETR`, …).
And `rcl.rcltypecd` — Act 2's column — is the one place where even the publisher's
dictionary doesn't rescue you: it describes four product categories in prose and never
publishes the code list, so the only way to document it is to look at the data.

> **Honest note for the presenter, and a good line to use on stage:** while building
> this demo, an AI assistant with live web access *also* could not reliably determine
> what `DATEA` means versus `LDATE`. It had to go and read the publisher's data
> dictionary. That is precisely the argument: retrieval beats parametric knowledge, and
> the fix is grounding, not a bigger model.

### 4. The comments come from the publisher, not from us — and then from the data

`COMMENT ON` text is **generated from NHTSA's own data dictionary** (`CMPL.txt`,
`RCL.txt`) by `scripts/generate_comments.py`, not hand-written by a sales engineer.
Where a field will not parse, the generator emits a literal `-- UNPARSED:` line rather
than a guess. When someone in the room asks "did you tune the comments to make this
work?", the answer is a script and a source URL.

That is the *starting* state, and it is deliberately thin in places. Everything the layer
learns after that comes from the agent sampling real rows (Act 2) or from curated
aliases (Act 5) — never from the presenter.

### 5. Mercedes-relevant, without pointing at their defects

The NHTSA data contains Mercedes-Benz vehicles. **Do not build the script around
Mercedes-Benz defect counts.** All scripted questions are industry-wide. Let them
notice their own brand appears in the result set on their own. Pointing at a customer's
failures on stage loses the room, and there is no upside.

---

## Repository layout

```
mercedes-demo/
├── README.md                   ← you are here
├── SETUP.md                    ← full from-scratch environment build
├── RUNBOOK.md                  ← the narrated 26-minute script, act by act
├── data/
│   ├── download.sh             ← fetch NHTSA flat files + data dictionaries
│   ├── load_nhtsa.py           ← load into Postgres, verify column counts
│   └── raw/                    ← the three published data dictionaries
├── scripts/
│   └── generate_comments.py    ← parse CMPL.txt/RCL.txt → COMMENT ON statements
├── sql/
│   ├── 01_schema.sql           ← DDL preserving the original cryptic column names
│   ├── 02_comments.sql         ← GENERATED — do not hand-edit
│   ├── 03_semantic_kb.sql      ← create_semantic_kb, Live auto-processing, aliases
│   ├── 04_agents.sql           ← Track B: agents, tools, budgets. [LOCAL] ONLY.
│   │                             Ships a PLACEHOLDER Azure URL — edit before running.
│   ├── 05a_hybrid_build.sql    ← PREFLIGHT [LOCAL]: builds + embeds odi.cmpl_sample
│   │                             (3–6 min). Raises semantic_kb_stats 94 → ~112.
│   ├── 05b_hybrid_query.sql    ← spare beat [LOCAL]: fused vector + FTS + SQL query
│   └── 90_observability.sql    ← action_log / agent_tasks demo queries (Act 6). [LOCAL]
├── appendix/
│   └── 06_governance.sql       ← OPTIONAL. Purpose-scoped roles + odi_safe views.
│                                 Not part of the standard build; see "If they ask
│                                 about access control" in RUNBOOK.md.
├── langflow/
│   ├── conversational-analytics-nhtsa.json ← Track A flow. IMPORT THIS ONE. [CLOUD]
│   ├── conversational-analytics-demo.json  ← the original generic-warehouse export.
│   │                             Reference only — do not import.
│   └── README.md               ← Track A wiring notes + the full prompt text
├── eval/                       ← [LOCAL] ONLY (needs 7.6.0 agents). Requires
│   │                             AIDB_EVAL_AZURE_FOUNDRY_API_KEY + its own EVAL_DSN.
│   ├── nhtsa_text2sql.yaml         ← treatment arm: SemKB, English comments
│   ├── nhtsa_text2sql_naive.yaml   ← control arm: no semantic layer
│   └── nhtsa_text2sql_german.yaml  ← German-comment arm — this one is the ask
└── fallback/
    └── dummy_model.sql         ← scripted dummy-provider responses. [LOCAL] ONLY —
                                  there is no fallback for Track A.
```

---

## Quick start

**Two databases. Do both.** `$CLOUD_DSN` is the EDB Hybrid Manager cluster (aidb 7.5.0);
`$DEMO_DSN` is the laptop (aidb 7.6.0).

```bash
# 1. [LOCAL] Environment (once) — see SETUP.md for the full version
mise run-aidb

# 2. Data — download once, load TWICE. The row counts WILL differ; write both down.
./data/download.sh
python3 data/load_nhtsa.py --dsn "$CLOUD_DSN" --subset 250000   # [CLOUD] 250k, not 2.2M
python3 data/load_nhtsa.py --dsn "$DEMO_DSN"                     # [LOCAL] fuller load

# 3. Comments from the publisher's dictionary — generate once, apply to both
python3 scripts/generate_comments.py > sql/02_comments.sql

# 4a. [CLOUD] Build Track A's side — 01, 02, 03 and STOP.
#     04 is Track B and uses 7.6.0-only surfaces; it will not run here.
psql "$CLOUD_DSN" -f sql/01_schema.sql \
                  -f sql/02_comments.sql \
                  -f sql/03_semantic_kb.sql

# 4b. [LOCAL] Build the full thing — 01, 02, 03, 04, 05a, 05b
#     EDIT sql/04_agents.sql FIRST: it ships a placeholder Azure URL.
psql "$DEMO_DSN" -f sql/01_schema.sql \
                 -f sql/02_comments.sql \
                 -f sql/03_semantic_kb.sql \
                 -f sql/04_agents.sql \
                 -f sql/05a_hybrid_build.sql \
                 -f sql/05b_hybrid_query.sql

# 05a takes 3–6 minutes, is [LOCAL] only, and is preflight — never run it on stage.
# It also adds odi.cmpl_sample to schema odi, so semantic_kb_stats goes 94 → ~112
# on the laptop. That is expected, not a failed check.
#
# appendix/06_governance.sql is OPTIONAL and not part of this build. If you do run
# it, run it AFTER 05a (it REVOKEs on odi.cmpl_sample, which 05a creates) and
# re-run it after every 05a — 05a DROPs that table and the ACL goes with it.

# 5. [CLOUD] Import and re-point the Langflow flow
#    langflow/conversational-analytics-nhtsa.json — its prompt is already correct,
#    nothing to hand-paste. Re-point FIVE fields on the EDB Database Component:
#    hm_project, hm_db_cluster, db_name (ships null), hm_db_group (ships the literal
#    placeholder "Select database group"), db_password (ships empty).
#    Full checklist in RUNBOOK.md.

# 6. Rehearse — including the environment switch between Act 5 and Act 6
open RUNBOOK.md
```

---

## Build against `main`

Tim's branch `tim/aidb-agent-demo-fixes-072026` contains two fixes that this demo
depends on, and **both are already merged into `main`**:

- `aidb-tools/src/registry.rs` — `quote_ident()` on emitted parameter names. Without
  it, every SemKB search tool call from an agent fails, because
  `get_column_definitions` / `get_metadata` / `get_entity_definitions` /
  `search_by_comment` all take a pagination parameter literally named `offset`, which
  is a reserved SQL keyword. **This demo calls those tools constantly.**
- `aidb-agents/src/thought_prompt.rs` — moves replayed history away from the generation
  point so a resumed conversation doesn't anchor on its own previous answer. Matters
  wherever the demo continues a conversation rather than starting one.

`main` is strictly ahead of the branch. Use `main`.

---

## Known landmines

Read these before rehearsing. Each one has bitten someone.

| Landmine | Effect on stage | Handling |
| --- | --- | --- |
| `create_agent` / `update_agent` / `delete_agent` return **zero rows** on success | Empty result reads as failure to an audience | Every such call is wrapped in a `DO` block that prints `OK` — in `sql/04_agents.sql`, in `fallback/dummy_model.sql`, and for the Act 6 swap in `RUNBOOK.md`. Never type a bare `SELECT error FROM aidb.update_agent(...)` on stage. |
| `read_only => true` uses `NullActionRecorder` | Persists nothing, returns `conversation_id = NULL` | Demo the guardrail and the audit trail in **separate** runs. Never chain them. |
| `debug => true` truncates at 2000 chars but does **not redact** | Credentials in a payload would be visible | Reviewed; no secrets in this demo's payloads. Still, don't improvise new queries live. |
| `execute_semantic_alias` ignores declared param types | Declared `param_type` is documentation for the agent, not enforced — every JSON argument arrives as TEXT | Compare against TEXT columns, or cast explicitly. Never a bare `LIMIT ${n}`. |
| `execute_semantic_alias` used to break on a trailing `;` | Alias act failed with `syntax error at or near ";"` | **Fixed on `main`** (AID-4849, commit `7db15bcf`, current HEAD). `sql/03_semantic_kb.sql` does not *sanitize* anything — it simply never writes a trailing `;`. A packaged 7.6.0 predating that commit still has the bug. |
| An alias created **without** a `model` argument gets no `description_vector` | It is **invisible** to alias search — `search_semantic_aliases` on the cloud, `semantic_kb_search(sources => ARRAY['alias'])` locally — so Act 5's payoff silently doesn't happen | `sql/03_semantic_kb.sql` passes `model => :'kb_model'` on all three pre-built aliases. Same model as the KB, or the vectors aren't comparable. On the cloud, also check the agent actually called `refresh_kb` after `create_alias`. |
| Deleting `refresh_kb`, `discover_context` or the `min_similarity` 0.5→0.3 ladder from the Track A prompt | **Breaks Track A.** `discover_context` is the only composite entry point on 7.5.0; the ladder compensates for its 0.6–0.7 MCP defaults; and without `refresh_kb` the Act 2 comment never reaches the KB, so the payoff search returns the *old* text. | **All three are correct on the cloud and are present in `conversational-analytics-nhtsa.json`. Leave them alone.** A previous pass removed them on the mistaken belief that Track A ran on 7.6.0; that has been reverted. Rationale and source citations in `langflow/README.md` §5.1. |
| Every MCP tool is blocked in read-only mode, regardless of its own `read_only` flag | Tools vanish unexpectedly mid-run | Intentional fail-closed behaviour. Not a demo act any more — know it in case a rehearsal trips it. |
| Aliases are **not** native agent tools in Track B | An in-database agent cannot create or execute an alias directly | Deliberate: `aidb-tools/src/native_tools.rs` asserts they are absent from the catalog. Track B **[LOCAL]** *discovers* an alias via `semantic_kb_search(sources => ARRAY['alias'])` and runs the returned SQL itself. Track A's MCP toolset does have `create_alias` / `execute_alias` — which is why Act 5 runs on the cloud. |
| `create_semantic_kb(auto_processing => 'Live')` makes every later DDL on `odi` synchronously call the embedding model | Great demo, bad for a bulk migration | Volunteer it before they find it. `'Background'` exists for that case. |
| No `max_iterations` under `attempt_complete` → effective cap of 21 | Long query appears to stall | Budgets set explicitly in `sql/04_agents.sql` |
| `credentials_env` is read by the **server** process | Model auth fails mysteriously | Export before starting Postgres. See `SETUP.md`. |
| `bert_local` (SemKB default) is **English-only** | German `COMMENT ON` text retrieves poorly | See "The ask" below — this is deliberately surfaced, not hidden. |
| OTel / `agent_audit` are POC branches only | Don't promise them | Shippable observability is `action_log` + `LISTEN/NOTIFY` |

---

## The ask

Mercedes-Benz Tech Innovation selects sponsorship targets by polling their own
engineers: *"which FOSS do they use the most"* and which is *"useful for many but does
not get enough credit."* There is no procurement desk and no application form — **the
decision loop runs inside Mercedes.**

So the objective of this demo is not to impress an executive. It is to make a
Mercedes-Benz engineer want to run it against their own schema on Monday. Everything
here is reproducible from public parts: public-domain data, a loader, a comment
generator and SQL.

**Be honest about the setup cost.** There is **no container image and no compose file** in
this repo today — standing it up means a pgrx build of the extension, which `SETUP.md`
budgets at roughly three hours of mostly-unattended wall clock. "Run it on Monday" is
true, but it is a Monday morning, not a coffee break. A one-command container image is a
follow-up (see *Open items* below), not something to promise on stage.

The ask itself is a **design partnership, not a cheque**, on two concrete gaps:

1. **Multilingual semantic retrieval.** SemKB's default embedding model is English.
   Mercedes' `COMMENT ON` text will be German. Measure this before the meeting —
   `eval/nhtsa_text2sql_german.yaml` holds everything constant except the comment
   language — and present the real number, whatever it is. A gap you name yourself is a
   reason to partner; a gap they find is a reason to disengage.
2. **Cryptic-schema retrieval patterns.** SAP-derived names, 30-character truncation,
   abbreviation dictionaries. NHTSA is a good public proxy, but their real patterns
   would make the benchmark materially better — and a benchmark contribution is a
   sponsorship-shaped contribution that costs them no budget approval.

---

## Open items

Known gaps in **this repo**, worst first. These are build tasks, not talking points — do
not raise them on stage unless asked directly.

### 1. Build tasks still outstanding in this repo.

- **`sql/02_comments.sql` is generated, not committed.** Every other doc references it as
  though it exists. `python3 scripts/generate_comments.py > sql/02_comments.sql` (Phase 3 of
  `STEP-BY-STEP.md`) creates it.
- **`sql/04_agents.sql` ships a placeholder Azure URL** —
  `https://<resource>.openai.azure.com/openai/v1/responses`. It **must** be edited before the
  file is run, or `nhtsa_chat` registers against a hostname that does not resolve and every
  model call fails mid-demo. The file now carries a loud banner; it is still on you to edit it.
- **`SETUP.md` §4 and §6 referenced `sql/06_governance.sql`;** the file lives at
  `appendix/06_governance.sql`. Corrected.
- **The eval needs `AIDB_EVAL_AZURE_FOUNDRY_API_KEY` and its own `EVAL_DSN`**, and it is
  **[LOCAL] only** (it needs 7.6.0 agents). Both are now in `SETUP.md` §1.4's env template.
- **`langflow/README.md`'s §5.1 rationale was rewritten** after a pass wrongly deleted
  `discover_context`, the `min_similarity` ladder and `refresh_kb` from the Track A prompt on
  the assumption Track A ran on 7.6.0. Reverted; see the landmine table. If you find any doc
  still asserting 7.6.0 behaviour for Track A, it is stale.

**Do not delete `refresh_kb`, `discover_context` or the `min_similarity` ladder from the
Track A prompt.** They are correct for aidb 7.5.0, which is what the Hybrid Manager cluster
runs. This has now been got wrong once.

### 2. No container image or compose file.

Setup is a pgrx build of the extension: ~3 hours, mostly unattended (`SETUP.md` §6). That
is the single biggest obstacle to the "run it against your own schema on Monday" ask, and
the highest-leverage thing to fix after the meeting. Until it exists, do not describe the
setup as one command.

### 3. Slide 14's nine cells are placeholders.

Three arms (SemKB-English, SemKB-off, SemKB-German) × three models. They must be filled
from a real `agent_eval` run before the meeting. Never present an invented number.

### 4. Items inherited from the Olist guide, still unverified.

Tracked with `<!-- VERIFY -->` markers in `langflow/README.md`; see the open-items table
at the end of that file. Model-name inconsistency, a referenced-but-absent
`langflow-mcp` wrapper, and an unconfirmed web app URL.

---

## Sources

- [NHTSA ODI flat file downloads](https://www.autosafety.org/nhtsa-office-of-defects-investigation-flat-file-downloads/)
- [ODI Complaints dataset metadata (data.gov)](https://catalog.data.gov/dataset/nhtsas-office-of-defects-investigation-odi-complaints) — public domain, `R/P1D` accrual
- [Mercedes-Benz: 4 Reasons to Sponsor Open Source Projects](https://thenewstack.io/mercedes-benz-4-reasons-to-sponsor-open-source-projects/)
- [MO360 Data Platform](https://group.mercedes-benz.com/company/production/procuction-network/mo360-data-platform.html)
- [Mercedes-Benz AI digital workplace](https://group.mercedes-benz.com/technology/digitalisation/artificial-intelligence/ai-digital-workplace.html)
