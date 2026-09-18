# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

An ELT pipeline for foreign-exchange rates. Two stages, two tools:

1. **Extract/Load** — `extract.py` pulls FX rates from the [Frankfurter API](https://frankfurter.dev) and upserts them into a Postgres table `raw_exchange_rates`.
2. **Transform** — a dbt project (profile `exchange_rate`, Postgres adapter) models that raw table into a staging view and an analytics fact table.

`extract.py` and dbt are decoupled: they share only the `raw_exchange_rates` table. The Python side never touches the dbt models; dbt reads `raw_exchange_rates` as a declared *source*.

## Commands

### First-time setup

`extract.py` only INSERTs — it does not create the landing table. Create it once with the DDL in `setup.sql` (schema `raw` + table `raw_exchange_rates`, PK matching the upsert's conflict target):

```bash
psql -h localhost -U postgres -d exchange_rate -f setup.sql   # if psql is installed
# no psql? apply setup.sql through psycopg2 with the same connection params
```

`setup.sql` is idempotent (`IF NOT EXISTS`), so it is safe to re-run.

### Extraction (Python)

Requires `PGPASSWORD` set. Runs against the same Postgres DB as dbt (`exchange_rate`).

```bash
# latest rates (single day)
python extract.py

# backfill an inclusive date range (Frankfurter start..end series)
python extract.py 2024-01-01 2024-12-31
```

Behavior is driven by env vars (defaults in parens): `BASE_CURRENCY` (`USD`), `TARGET_CURRENCIES` (`THB,EUR,JPY,GBP,CNY`), `DB_HOST` (`localhost`), `DB_PORT` (`5432`), `DB_NAME` (`exchange_rate`), `DB_USER` (`postgres`), `DB_SCHEMA` (`raw`), and `PGPASSWORD` (required — no default, the process fails on import without it). The `DB_NAME`/`DB_SCHEMA` defaults are deliberately aligned with the dbt source `raw.raw_exchange_rates`, so extract and dbt point at the same table out of the box.

### Transformation (dbt)

Run from the project root. The dbt profile `exchange_rate` lives in `~/.dbt/profiles.yml` (Postgres, `target: dev`).

```bash
dbt deps            # install packages.yml deps into dbt_packages/ (dbt_utils)
dbt build           # run + test all models in DAG order (the usual full command)
dbt run             # build models only
dbt test            # run data tests only
dbt source freshness # check raw_exchange_rates freshness (warn 36h / error 7d)

# single-model iteration
dbt run  --select stg_exchange_rates
dbt build --select fct_daily_date          # +downstream: fct_daily_date+
dbt test --select stg_exchange_rates
```

## Architecture

### The data flow

```
Frankfurter API → extract.py → raw_exchange_rates (Postgres)
                                      │  (dbt source: raw.raw_exchange_rates)
                                      ▼
                          stg_exchange_rates  (view, staging)
                                      ▼
                            fct_daily_date    (table, marts)
```

### extract.py (fetch → transform → load)

Three pure-ish functions plus two entry points:
- `fetch_rates(path)` — GETs `{API_BASE}/{path}` with a 10s timeout and 3-attempt retry. `path` is either `latest` or a `start..end` range.
- `to_rows(payload)` — flattens Frankfurter's **wide** JSON (`{quote: rate}`) into **long** rows `(rate_date, base, quote, value)`. Handles both response shapes transparently: a single-day object and a multi-day time series (detected by whether every value in `rates` is itself a dict).
- `upsert(rows)` — one batched `execute_values` round-trip with `ON CONFLICT (rate_date, base_currency, quote_currency, source) DO UPDATE`. This is what makes re-runs and overlapping backfills idempotent.

The load target's uniqueness key is `(rate_date, base_currency, quote_currency, source)` — this must match both the `ON CONFLICT` clause and the primary key in `setup.sql`. `source` is hard-coded to `"frankfurter"`. The target table is schema-qualified via `DB_SCHEMA` (default `raw`).

### dbt models (`models/`)

- **`staging/stg_exchange_rates.sql`** (view) — rename/cast layer only. Reads `{{ source('raw','raw_exchange_rates') }}`, casts `rate` to `numeric(20,10)`, and derives `pair_currency` (`base/quote`). Grain: one row per `(rate_date, base_currency, quote_currency)`.
- **`marts/fct_daily_date.sql`** (table) — the analytics layer. Adds trading-day window metrics per currency pair: `prev_rate` (lag), `ma_7d` / `ma_30d` (6- and 29-row trailing SMAs), `volatility_30d` (29-row rolling sample stddev), running high/low (unbounded-preceding frame via named window `w`), `pct_change_1d`, a rebased-to-100 index (`rate_indexed`, fixed baseline = each pair's first trading day, via `first_value` over `w`), and multi-horizon `pct_change_7d` / `pct_change_30d` (trading-day `lag`) / `pct_change_ytd` (vs first trading day of the calendar year).

Note that the window metrics are **trading-day** based (row-count frames like `rows between 6 preceding and current row`), *not* calendar-day based — gaps in `rate_date` (weekends/holidays) are ignored, not filled.

### Sources, tests, and conventions

- `models/staging/sources.yml` declares the `raw` source and freshness thresholds on `fetched_at`.
- Tests are declared inline in `.yml` alongside models (`stg_exchange_rates.sql` shares `models/marts/fct_daily_date.yml`, which documents both staging and marts models despite its path). Uniqueness is enforced with `dbt_utils.unique_combination_of_columns`; `exchange_rate > 0` with `dbt_utils.expression_is_true`.
- Materialization is set project-wide in `dbt_project.yml`: `staging/` → view, `marts/` → table. Prefix new models `stg_` (staging) or `fct_`/`dim_` (marts) and place them in the matching folder so they inherit the right materialization.
- The dbt source `raw.raw_exchange_rates` has no `schema:`/`database:` override, so dbt resolves it to database = the profile's `exchange_rate` and schema = the source name `raw`. `setup.sql` and `extract.py`'s defaults are matched to that exact location — keep the three in sync if you move the table.
- `seeds/`, `macros/`, `tests/`, `snapshots/` are configured paths but do not exist yet — create them as needed.

## CI/CD (GitHub Actions)

`.github/workflows/daily_pipeline.yml` runs the full ELT pipeline (`extract.py` → dbt) on a schedule and on demand:

- **Triggers** — `schedule` at `00:00 UTC` daily (07:00 Asia/Bangkok), plus `workflow_dispatch` with optional `backfill_start`/`backfill_end` inputs. When both dates are provided it runs `python extract.py <start> <end>`; otherwise `python extract.py` (latest).
- **Steps** — install `requirements.txt` → apply `setup.sql` (idempotent, via psycopg2) → extract/load → `dbt deps` → `dbt build` → `dbt source freshness` (non-blocking, `continue-on-error`) → write row counts + run status to the job summary → upload `logs/` and `target/` as artifacts (14-day retention).
- **Concurrency** — group `fx-pipeline` with `cancel-in-progress: false`, so two runs never touch the warehouse at the same time.
- **Config** — all DB settings come from GitHub secrets as env vars (`DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `PGPASSWORD`) — the same names `extract.py` reads. CI-only additions: `PGSSLMODE=require` (libpq honours it, no code change), `DB_SCHEMA=raw` (extract load target), `DB_TARGET_SCHEMA=public` (dbt output schema), and `DBT_PROFILES_DIR=ci`.
- **`ci/profiles.yml`** — a CI-only copy of the `exchange_rate` profile (`target: dev`) that reads every field from env vars, so no credentials are committed. It lives under `ci/` and is selected via `DBT_PROFILES_DIR: ci` so it never shadows the developer's local `~/.dbt/profiles.yml`.

## Notes

- `dbt_packages/` is vendored dependency code (dbt_utils), not part of this project — don't edit it; it's regenerated by `dbt deps` and is a `clean-target`.
- Python dependencies are pinned in `requirements.txt` (`requests`, `psycopg2-binary`, `dbt-postgres`); `pip install -r requirements.txt` covers both the extract and dbt stages. `dbt_utils` is not listed there — it is installed separately from `packages.yml` via `dbt deps`.
- This is a git repository with a GitHub remote (`Petethanarat/Exchange_rate_API`). There is still no README — `CLAUDE.md` is the only project-level doc.
