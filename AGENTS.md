# AGENTS.md

This file gives AI agents the repo-specific context they need to work in the
Harborside data platform: how the company and its pipelines are organized, the
standard every asset is held to, and the self-healing policy that says what an
agent may do on its own. Read it before opening any SQL.

Two more places hold context an agent should reach for:

- **`glossary.yml`** at the repo root — the shared semantic layer (entities and
  attributes) that asset columns extend.
- **`README.md` in each pipeline folder** — why that pipeline exists, why it is
  shaped the way it is, its lineage, and its designed incidents.

## The company

**Harborside** is a fictional direct-to-consumer (DTC) e-commerce brand selling
home & lifestyle goods, used here to demonstrate a data platform set up for
self-healing. Revenue is one-time storefront orders plus a monthly subscription,
the "Harborside Home Box". The storefront is multi-currency; analytics report in
USD unless a table is explicitly native-currency (the stripe billing tables are).
A small data team (3 people) owns this repo; the backend team owns the
application (`harborside-api`) that emits the source data.

### The four pipelines

| Pipeline | Domain | Source | What it answers | Owner |
|---|---|---|---|---|
| `iot` | operations | sensor gateways (Python fixture) | Are fulfillment-center storage conditions safe? | Sam |
| `shop` | commerce / finance | orders + products (Python fixture) | One-time storefront revenue | Dana |
| `webevents` | marketing | pageview stream (Python fixture) | Web traffic and conversion | Priya |
| `stripe` | finance | Stripe via ingestr | Home Box subscription (recurring) revenue | Dana / Priya |

Each pipeline has `raw` → `stage` → `report` layers, with schemas named
`<pipeline>_<layer>` (for example `shop_raw`, `shop_stage`, `shop_report`).

### People and ownership

| Person | Team | Owns | Alias |
|---|---|---|---|
| Dana | Finance | Net revenue, GMV, AOV, invoice billings | `dana@harborside.example` |
| Priya | Growth | MRR, churn, web traffic, acquisition | `priya@harborside.example` |
| Sam | Ops | Fulfillment, refunds, IoT/warehouse sensors | `sam@harborside.example` |
| — | Data platform on-call | routing / escalation | `data-platform@harborside.example` |

Changing a metric definition owned by one of these people requires their sign-off.

### Internal lingo (terms an agent will not find in the SQL)

- **Home Box** — the monthly subscription product; drives MRR, not one-time revenue.
- **Revenue-eligible order** — an order whose status counts toward revenue
  (`paid`, `fulfilled`, `delivered`). `pending` and `cancelled` never count.
- **`fulfilled`** — an order that shipped/completed. *Formerly `completed`; the
  backend renamed it. Treat the two as equivalent.*
- **MRR / ARR** — monthly / annual recurring revenue; ARR = MRR × 12. Both are
  list-price run rates, not recognized revenue.
- **GMV** — gross merchandise value, before refunds and discounts.
- **AOV** — average order value = net revenue ÷ revenue-eligible order count.
- **Minor units** — the stripe tables keep money in each currency's minor units
  (cents). Divide by 100 for display; never add across currencies without FX.

## Asset requirements (the standard)

Every asset you create or modify must have:

- an `owner` (one of the aliases above)
- a table `description` that says **what one row represents**
- a `description` on every column
- appropriate `tags`, `domains`, and `meta` (layer, tier, team, cost_center)
- a quality check on every column that carries a business rule
- a `custom_checks` entry for any rule that spans columns
- a `unit_test` if the asset contains business logic beyond a straight select
- a `depends` list that matches what the SQL actually reads, including
  cross-pipeline dependencies declared by `uri:`

If you cannot determine one of these, say so and ask. Do not guess an owner or
invent a metric definition.

## Self-healing policy

This is the dial that decides what the agent does on its own. Tune the buckets to
your team's comfort; the version below is a reasonable default.

### Scope

- Pipelines: `iot`, `shop`, `webevents`, `stripe`. Anything outside these, stop and ask.
- Writes: the `agent-dev` environment only (never production).
- The Python `*.py` assets in each `raw/` folder **emulate the upstream source**
  and seed the designed incidents. They are not the self-heal surface. Diagnose
  and fix the `stage`/`report` SQL, the checks, or the metadata — do not rewrite
  a source generator to make a check pass.

### Do without asking

- Read run details, logs, lineage, asset definitions, checks, and unit tests.
- Query `agent-dev` and any named read-only connection.
- Branch, make the fix, `bruin validate`, `bruin unit-test`, and open a pull request.

### Ask first

- Trigger a run, a rerun, or a backfill.
- Merge a pull request.
- Change a schedule, a schema, a check's expectation, or a business definition.

### Never

- Use `--full-refresh` (it discards the stripe daily-snapshot history).
- Delete data, assets, pipelines, connections, or schedules.

### Evidence every diagnosis must include

- Run ID, affected interval, failed asset, failing rows or log lines, lineage, test result.
- The action taken or proposed, and the result expected from it.

### Stop conditions

- The evidence points two ways, or the cause is still a guess.
- The root cause is a genuine business change (real revenue drop) — flag, do not mask.
- A control the policy relies on is missing or unavailable.

Who to ask: data platform on-call (`data-platform@harborside.example`).

<!-- BEGIN BRUIN AI AGENTS -->
## Bruin Pipeline Agent Guidance

### Scope

- Use this file for Bruin pipeline development, asset work, data analysis, and troubleshooting.
- Do not treat this as a general application-code instruction file.
- Prefer existing Bruin CLI commands, pipeline patterns, and project conventions over ad hoc scripts.

### Bruin MCP and Docs

- Use Bruin MCP when it is available to inspect Bruin docs and project context.
- Local Bruin MCP runs with `bruin mcp`.
- If configuring an AI client, register the command as `bruin mcp` and then use the exposed Bruin docs tools.
- Use the docs tree first, then fetch the specific doc page you need. Prefer docs such as `commands/run`, `commands/query`, `commands/validate`, `commands/connections`, `assets/sql`, `assets/ingestr`, `assets/definition-schema`, and platform-specific docs.
- When MCP is not available, use `bruin --help`, `bruin <command> --help`, and the repository docs.

### Navigating Pipelines and Assets

- Start from the nearest `pipeline.yml` to understand pipeline name, schedule, defaults, and asset layout.
- Inspect asset definitions before editing SQL or Python. SQL assets usually include Bruin metadata between `/* @bruin` and `@bruin */`.
- Follow dependencies through `depends`, upstream asset names, source tables, and materialization settings.
- Prefer a `README.md` inside each pipeline folder that explains the pipeline purpose, key source tables, asset dependencies, environment assumptions, operating notes, and how agents should run or troubleshoot the pipeline.
- Use `bruin validate <path>` on the affected pipeline or asset after changes.
- Use `bruin render <asset>` to inspect rendered SQL before running it.
- Keep changes scoped to the affected pipeline, asset, checks, or documentation.

### Environments and Secrets

- Treat `.bruin.yml` as a local development config file. Do not commit real credentials, tokens, passwords, private keys, or personal connection details.
- In Bruin Cloud and other server environments, connections and secrets may be initialized from environment variables instead of a local `.bruin.yml`.
- Prefer environment-variable references in local config, such as `${MY_SECRET}`, over literal secret values.
- If `.bruin.yml` defines both `dev` and `prod` environments, run commands in `dev` unless the user explicitly asks for `prod`.
- Never run against `prod` by assumption. State the environment you are using in your response.
- Before `--full-refresh`, backfills, destructive operations, or commands that can replace data, get explicit user confirmation unless the user already gave specific instructions.

### Querying Data

- Prefer `bruin query` and the connections already configured in `.bruin.yml` when querying data.
- Use read-only, narrow queries first: select only needed columns, include limits, and filter partitions or date ranges where possible.
- Avoid large scans, full table reads, exports, or expensive joins unless the user confirms the scope.
- Do not query sensitive columns unless needed for the task. Mask or aggregate sensitive results in summaries.
- When investigating an asset, prefer rendering the asset query and running a limited diagnostic query before changing logic.
- Query warehouse admin or metadata tables when permissions allow it, such as `INFORMATION_SCHEMA` or platform-specific account usage views, to inspect schemas, row counts, table sizes, partitions, clustering, freshness, and downstream dependencies.
- Save useful diagnostic SQL only when it belongs in the repository; otherwise report the query and result.

### Creating and Updating SQL Assets

- Query and analyze the source and target data before making assumptions about grain, freshness, nullability, uniqueness, or business meaning. Clarify material assumptions with the user before encoding them in SQL or checks.
- Use `bruin render <asset>` to inspect rendered SQL before execution. Use `bruin validate <path>` at regular intervals after meaningful changes, but do not overuse validation after every small edit.
- Filter exploratory and validation queries by partition, clustering columns, date ranges, tenant, or other selective predicates whenever possible.
- Add or preserve partitioning and clustering when the database or warehouse supports it and the expected table size, query pattern, or incremental strategy warrants it. Discuss backfill and cost implications with the user before changing physical layout on large tables.
- When exploring unfamiliar tables, consider asking the user for permission to run `bruin ai enhance` to generate table-level and column-level descriptions as a starting point. Review generated descriptions instead of treating them as authoritative.
- When creating or changing quality checks, run the affected checks or validation to verify they work. If a check fails, assess whether the SQL, data, or check expectation is wrong, and clarify with the user when the intended rule is uncertain.

### Skills

- Check `.agents/skills/` for repository-specific skills before starting specialized work.
- Open the relevant `SKILL.md` and follow its workflow when the task matches its purpose.
- Use the smallest applicable skill. Do not run broad maintenance or action skills when a diagnosis skill is enough.
- If a skill has an `Actions` placeholder, treat it as a policy gap: report findings and stop before modifying data, source systems, production settings, credentials, or repo files.
- When a skill and Bruin docs disagree, verify with the current Bruin CLI help or MCP docs and report the discrepancy.

### Reporting

- Summarize commands run, environment used, files changed, and validation results.
- If validation cannot be run, say why and provide the exact command the user can run.
- If a fix requires warehouse, source-system, or Bruin Cloud action, document the exact follow-up instead of guessing.
<!-- END BRUIN AI AGENTS -->
