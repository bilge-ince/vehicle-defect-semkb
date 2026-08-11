# Self-Building Semantic Knowledge Base for Text-to-SQL on Postgres

A reproducible example: an AI agent answers business questions in plain English against a
**deliberately messy** real-world Postgres schema — and builds the semantic layer it relies
on as it goes.

> **The point in one line:** The hard part of Text-to-SQL is not the model, it is
> *retrieval* — knowing which tables and columns a question actually refers to. On a schema
> with cryptic column names, a frontier model guesses and is confidently wrong. A smaller
> model backed by a semantic layer is right. Here that layer is **built and maintained by
> the agent itself**, inside the database — not exported once and left to rot.

Everything runs on public-domain data and open parts (a loader, a comment generator, SQL),
so you can point it at your own schema.

---

## What makes it interesting

Anyone can export a schema into a semantic layer once. The interesting part is what happens
**after** the export. Two behaviors carry the whole idea — and both are things a static,
exported layer cannot do:

- **It looks before it describes.** When the agent hits a column nobody documented, it
  samples the real data (`get_object_details`, `SELECT * LIMIT 5`, a `GROUP BY`) *before*
  writing a description — and it stops to ask when the values turn out to be codes with no
  published legend. Once a human answers, it writes a grounded comment and refreshes the
  layer itself, in the same turn. No ticket, no second system.
- **It compounds.** A query that worked is saved as a **semantic alias** with a business
  description and typed parameters. The next related question returns that alias *alongside*
  the raw schema objects in one ranked list, so the agent runs curated SQL instead of
  regenerating it.

The semantic layer is the durable asset. The agent is what keeps it honest.

---

## Why this dataset

The schema has to be one where a semantic layer is *necessary*, not decorative. A clean
schema (`order_purchase_timestamp`, `payment_type`, `customer_state`) lets any model do
Text-to-SQL with zero help — so it proves nothing.

This uses the **NHTSA Office of Defects Investigation** flat files: real, public domain,
automotive, updated daily. The column names are genuinely opaque:

```
CMPLID   ODINO   COMPDESC   CMPL_TYPE   LDATE   DATEA   FAILDATE
ORIG_EQUIP_YN    LOC_OF_TIRE    OCCURENCES    PROD_TYPE    MFR_NAME
```

It behaves exactly like a real enterprise (e.g. SAP-derived) warehouse:

- **Three different date columns.** No model can guess that `faildate` = when the defect
  occurred, `datea` = when the record was added, `ldate` = when it was received.
- **Same name, different meaning.** `datea` exists in **both** the complaints and recalls
  tables and means something different in each.
- **Names that lie.** `cmpl_type` sounds like a complaint category; it is actually the
  intake channel (`VOQ`, `IVOQ`, `LETR`, …). `rcltypecd` has codes the publisher never
  documents — the only way to describe it is to look at the data.
- **Real-world grime.** Every column is `TEXT`, blanks are `''` not `NULL`, dates are
  `YYYYMMDD` strings, no foreign keys, and two column names are misspelled at source
  (`occurences`, `conequence_defect`).

The `COMMENT ON` text is **generated from NHTSA's own data dictionary** by
`scripts/generate_comments.py`, not hand-tuned. That is the thin starting state; everything
richer is learned by the agent from real rows or from curated aliases.

---

## Two ways to run it

Same knowledge base, two different agent runtimes. **One layer, two consumers.**

| | **Track A — External agent** | **Track B — In-database agent** |
| --- | --- | --- |
| Runtime | Langflow + `pg-airman-mcp` | `aidb.agent_converse()` — a ReAct loop **inside** Postgres |
| Where the agent runs | Outside the database, over MCP | In the Postgres backend; nothing leaves the process |
| Reaches the KB via | MCP tool calls | A native backend function call |
| Good for | You already have an orchestrator | You want no orchestrator, no egress, in-transaction audit |
| Status | Works today | Work in progress |

MCP is transport, not logic. The knowledge base is built once in AIDB
(`aidb.create_semantic_kb`) and both tracks consume the same definition — same comments,
same embedding model, same aliases.

---

## Two database versions (why setup has two halves)

The two tracks run on two AIDB versions, and a few behaviors differ. This is worth knowing
before you're surprised by it:

| | **aidb 7.5.0** (Track A) | **aidb 7.6.0** (Track B) |
| --- | --- | --- |
| Composite retrieval | MCP **`discover_context`** (fans out over several searches) | one `aidb.semantic_kb_search` call |
| `COMMENT ON COLUMN` → KB | **needs an explicit `refresh_kb`** | propagates automatically, same transaction |

So on 7.5.0 the agent must call `refresh_kb` after writing a column comment; on 7.6.0 a
trigger does it for you. Same behavior from the user's side — the newer version just makes
it simpler. If you load data into both, **expect different row counts** and never quote a
number from one while showing the other.

---

## Repository layout

```
.
├── README.md                   ← you are here
├── data/
│   ├── download.sh             ← fetch NHTSA flat files + data dictionaries
│   ├── load_nhtsa.py           ← load into Postgres, verify column counts
│   └── raw/                    ← downloaded dictionaries (created by download.sh)
├── scripts/
│   └── generate_comments.py    ← parse the dictionaries → COMMENT ON statements
├── sql/
│   ├── 01_schema.sql           ← DDL preserving the original cryptic column names
│   ├── 02_comments.sql         ← GENERATED — do not hand-edit
│   ├── 03_semantic_kb.sql      ← create_semantic_kb, Live auto-processing, aliases
│   ├── 04_agents.sql           ← Track B agents/tools/budgets (7.6.0). Edit the Azure URL first.
│   ├── 05a_hybrid_build.sql    ← optional: build + embed a sample table (3–6 min)
│   ├── 05b_hybrid_query.sql    ← optional: fused vector + full-text + SQL query
│   └── 90_observability.sql    ← action_log / agent_tasks demo queries
├── appendix/
│   └── 06_governance.sql       ← OPTIONAL: purpose-scoped roles + safe views (access control)
├── langflow/
│   ├── conversational-analytics-nhtsa.json ← Track A flow — import this one
│   ├── conversational-analytics-demo.json  ← generic reference export — do not import
│   └── README.md               ← Track A wiring notes + the full agent prompt
├── eval/                       ← Text-to-SQL accuracy harness (needs 7.6.0 agents)
│   ├── nhtsa_text2sql.yaml         ← with the semantic layer
│   ├── nhtsa_text2sql_naive.yaml   ← control: no semantic layer
│   └── nhtsa_text2sql_german.yaml  ← non-English comments (multilingual test)
└── fallback/
    └── dummy_model.sql         ← scripted responses for offline rehearsal
```

---

## Quick start

You need a Postgres with the **AIDB** extension installed. `$DSN` below is your database
connection string.

> **Setup cost, honestly:** there's no container image yet, so standing this up means a
> pgrx build of the AIDB extension — roughly three hours, mostly unattended. It's
> reproducible, just not a one-liner today. A one-command image is the top follow-up.

```bash
# 1. Get the data
./data/download.sh
python3 data/load_nhtsa.py --dsn "$DSN"          # add --subset 250000 on a small/remote DB

# 2. Generate comments from the publisher's data dictionary
python3 scripts/generate_comments.py > sql/02_comments.sql

# 3. Build the schema, comments, and knowledge base
psql "$DSN" -f sql/01_schema.sql \
            -f sql/02_comments.sql \
            -f sql/03_semantic_kb.sql

# 4a. Track A — import langflow/conversational-analytics-nhtsa.json into Langflow,
#     then re-point the EDB Database Component at your database. See langflow/README.md.

# 4b. Track B (aidb 7.6.0) — edit the Azure URL in sql/04_agents.sql first, then:
psql "$DSN" -f sql/04_agents.sql

# 5. Ask it something, e.g.:
#    "Which vehicle components generate the most complaints for 2019 models?"
#    More worked examples are in langflow/README.md.
```

`03_semantic_kb.sql` creates the KB with `auto_processing => 'Live'`, so every later DDL on
the schema re-embeds automatically. That's great for a demo and bad for a bulk migration —
use `'Background'` for the latter.

---

## Gotchas worth knowing

Each of these has bitten someone. Skim before you build.

| Gotcha | Why it matters |
| --- | --- |
| `create_agent` / `update_agent` / `delete_agent` return **zero rows** on success | An empty result looks like failure. `sql/04_agents.sql` wraps them in a `DO` block that prints `OK`. |
| An alias created **without** a `model` argument gets no embedding | It becomes invisible to alias search — the "it compounds" payoff silently doesn't happen. Always pass the same model as the KB. |
| `execute_semantic_alias` ignores declared param types | Every argument arrives as `TEXT`. Compare against TEXT columns or cast explicitly; never a bare `LIMIT ${n}`. |
| `read_only => true` persists nothing and returns `conversation_id = NULL` | Demo the guardrail and the audit trail in **separate** runs — don't chain them. |
| The default embedding model is **English-only** | Non-English `COMMENT ON` text retrieves poorly. See *Limitations* below; `eval/nhtsa_text2sql_german.yaml` measures it. |
| For Track A on aidb 7.5.0, keep `discover_context`, `refresh_kb`, and the `min_similarity` ladder in the prompt | They're correct for 7.5.0. Removing them breaks Track A. Rationale in `langflow/README.md` §5.1. |
| `auto_processing => 'Live'` calls the embedding model on every DDL | Fine for interactive use, slow for bulk loads. Use `'Background'` there. |

Access control is intentionally **not** part of the main flow — it's ordinary PostgreSQL and
lives in `appendix/06_governance.sql` (purpose-scoped roles + safe views) for when you need it.

---

## Limitations & roadmap

Honest gaps, and the interesting directions:

1. **Multilingual retrieval.** The default embedding model is English, so non-English
   comments retrieve worse. `eval/nhtsa_text2sql_german.yaml` holds everything constant
   except comment language so you can measure the real gap.
2. **Cryptic-schema retrieval patterns.** SAP-style names, 30-character truncation,
   abbreviation dictionaries — NHTSA is a good public proxy, but more real-world patterns
   would make the benchmark better.
3. **No container image yet.** Setup is a ~3-hour pgrx build (see *Quick start*). A
   one-command image is the highest-leverage thing to add.

---

## Sources

- [NHTSA ODI flat file downloads](https://www.autosafety.org/nhtsa-office-of-defects-investigation-flat-file-downloads/)
- [ODI Complaints dataset metadata (data.gov)](https://catalog.data.gov/dataset/nhtsas-office-of-defects-investigation-odi-complaints) — public domain, `R/P1D` accrual
