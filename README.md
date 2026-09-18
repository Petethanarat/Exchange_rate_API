# Exchange Rate ELT Pipeline

An end-to-end **ELT pipeline for foreign-exchange rates**. It pulls daily FX rates from the
[Frankfurter API](https://frankfurter.dev), lands them in Postgres, and models them with
[dbt](https://www.getdbt.com/) into an analytics fact table with moving averages, volatility,
and risk metrics. The whole thing runs on a schedule via GitHub Actions.

```
Frankfurter API → extract.py → raw_exchange_rates (Postgres)
                                      │  (dbt source: raw.raw_exchange_rates)
                                      ▼
                          stg_exchange_rates  (view · staging)
                                      ▼
                            fct_daily_date    (table · marts)
                                      ▼
                              Dashboard.pbix  (Power BI)
```

The two stages are decoupled — they share only the `raw_exchange_rates` table. `extract.py`
never touches the dbt models; dbt reads `raw_exchange_rates` as a declared **source**.

## Tech stack

| Layer | Tool |
|-------|------|
| Extract / Load | Python (`requests`, `psycopg2`) |
| Warehouse | PostgreSQL |
| Transform | dbt (`dbt-postgres`, `dbt_utils`) |
| Orchestration | GitHub Actions (scheduled + manual) |
| Visualization | Power BI (`Dashboard.pbix`) |

## Prerequisites

- Python 3.12+
- A reachable PostgreSQL database
- The dbt `exchange_rate` profile (Postgres adapter) — see [dbt setup](#3-configure-the-dbt-profile)

## Getting started

### 1. Install dependencies

```bash
pip install -r requirements.txt   # requests, psycopg2-binary, dbt-postgres
dbt deps                          # install dbt_utils from packages.yml
```

### 2. Create the landing table

`extract.py` only INSERTs — it does **not** create the table. Create it once with the DDL in
`setup.sql` (schema `raw` + table `raw_exchange_rates`). It is idempotent (`IF NOT EXISTS`), so
it is safe to re-run.

```bash
psql -h localhost -U postgres -d exchange_rate -f setup.sql
# no psql? apply setup.sql through psycopg2 with the same connection params
```

### 3. Configure the dbt profile

dbt looks for a profile named `exchange_rate` in `~/.dbt/profiles.yml`. Example:

```yaml
exchange_rate:
  target: dev
  outputs:
    dev:
      type: postgres
      host: localhost
      port: 5432
      user: postgres
      password: "{{ env_var('PGPASSWORD') }}"
      dbname: exchange_rate
      schema: public
      threads: 4
```

> The source `raw.raw_exchange_rates` has no `schema:`/`database:` override, so dbt resolves it
> to database = the profile's `dbname` (`exchange_rate`) and schema = `raw`. `setup.sql` and
> `extract.py`'s defaults point at that exact location — keep the three in sync if you move the table.

## Usage

### Extract / Load (Python)

Requires `PGPASSWORD` set in the environment.

```bash
# latest rates (single day)
python extract.py

# backfill an inclusive date range (Frankfurter start..end series)
python extract.py 2024-01-01 2024-12-31
```

The load is **idempotent**: a batched upsert with `ON CONFLICT (rate_date, base_currency,
quote_currency, source)`, so re-runs and overlapping backfills never create duplicates.

### Transform (dbt)

```bash
dbt build            # run + test all models in DAG order (the usual full command)
dbt run              # build models only
dbt test             # run data tests only
dbt source freshness # check raw_exchange_rates freshness (warn 36h / error 7d)

# single-model iteration
dbt run   --select stg_exchange_rates
dbt build --select fct_daily_date+
```

## Configuration

`extract.py` is driven entirely by environment variables (defaults in parentheses):

| Variable | Default | Purpose |
|----------|---------|---------|
| `PGPASSWORD` | *(required)* | DB password — the process fails on import without it |
| `BASE_CURRENCY` | `USD` | Base currency for the FX quotes |
| `TARGET_CURRENCIES` | `THB,EUR,JPY,GBP,CNY` | Comma-separated quote currencies |
| `DB_HOST` | `localhost` | Postgres host |
| `DB_PORT` | `5432` | Postgres port |
| `DB_NAME` | `exchange_rate` | Database name (aligned with the dbt profile) |
| `DB_USER` | `postgres` | Database user |
| `DB_SCHEMA` | `raw` | Load-target schema (`raw.raw_exchange_rates`) |

## Data model

| Model | Materialization | Description |
|-------|-----------------|-------------|
| `raw.raw_exchange_rates` | source table | Long-format landing table written by `extract.py`. Grain: one row per `(rate_date, base_currency, quote_currency, source)`. |
| `stg_exchange_rates` | view (staging) | Rename/cast layer. Casts `rate` to `numeric(20,10)` and derives `pair_currency` (`base/quote`). |
| `fct_daily_date` | table (marts) | Analytics fact table with per-pair trading-day metrics (see below). |

### `fct_daily_date` metrics

All window metrics are **trading-day** based (row-count frames), *not* calendar-day based —
gaps in `rate_date` (weekends/holidays) are ignored, not filled.

- **Trend** — `prev_rate` (lag), `ma_7d` / `ma_30d` (7- and 30-row trailing SMAs),
  running `running_high` / `running_low`.
- **Rebased index** — `rate_indexed`: 100 at each pair's first trading day (fixed baseline),
  so pairs at different scales compare on one axis.
- **Returns** — `pct_change_1d`, `pct_change_7d`, `pct_change_30d`, `pct_change_ytd`
  (vs first trading day of the calendar year).
- **Risk** — `volatility_30d` (30-row rolling sample stddev), `volatility_30d_pct`
  (volatility as % of rate, comparable across pairs), `ret_vol_30d` (30-row stddev of daily
  returns), `ret_zscore_1d`, and an `is_anomaly` flag (`|z| >= 2`).

### Tests

Declared inline in `models/marts/fct_daily_date.yml`:

- Uniqueness via `dbt_utils.unique_combination_of_columns` on `(rate_date, base_currency, quote_currency)`.
- `not_null` on key columns; `exchange_rate > 0` via `dbt_utils.expression_is_true`.
- Source **freshness** on `fetched_at`: warn after 36h, error after 7d.

## CI/CD

`.github/workflows/daily_pipeline.yml` runs the full ELT pipeline on a schedule and on demand:

- **Triggers** — daily at `00:00 UTC` (07:00 Asia/Bangkok), plus `workflow_dispatch` with
  optional `backfill_start` / `backfill_end` inputs.
- **Steps** — install deps → apply `setup.sql` → extract/load → `dbt deps` → `dbt build` →
  `dbt source freshness` (non-blocking) → write row counts + status to the job summary →
  upload `logs/` and `target/` as artifacts (14-day retention).
- **Concurrency** — group `fx-pipeline` with `cancel-in-progress: false`, so two runs never
  touch the warehouse at the same time.
- **Config** — all DB settings come from GitHub secrets (`DB_HOST`, `DB_PORT`, `DB_NAME`,
  `DB_USER`, `PGPASSWORD`) plus CI-only `PGSSLMODE=require` and a committed, credential-free
  `ci/profiles.yml` selected via `DBT_PROFILES_DIR=ci`.

## Project structure

```
Exchange_rate_API/
├── extract.py                 # Extract/Load: Frankfurter API → Postgres
├── setup.sql                  # DDL for raw.raw_exchange_rates (run once)
├── requirements.txt           # Python + dbt-postgres deps
├── packages.yml               # dbt package deps (dbt_utils)
├── dbt_project.yml            # dbt project config + materializations
├── models/
│   ├── staging/
│   │   ├── sources.yml        # raw source + freshness thresholds
│   │   └── stg_exchange_rates.sql
│   └── marts/
│       ├── fct_daily_date.sql
│       └── fct_daily_date.yml # docs + tests for staging & marts
├── ci/profiles.yml            # CI dbt profile (env-var only, no secrets)
├── .github/workflows/daily_pipeline.yml
└── Dashboard.pbix             # Power BI dashboard
```

## Dashboard

`Dashboard.pbix` is a Power BI report built on `fct_daily_date` — connect it to the same
Postgres database to explore trends, the rebased index, and volatility across currency pairs.
