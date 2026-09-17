"""
pull FX rates from the Frankfurter API
"""
import os
import sys
import logging
from typing import List, Tuple
from decimal import Decimal
from datetime import date
 
import requests
import psycopg2
from psycopg2.extras import execute_values

API_BASE = "https://api.frankfurter.dev/v1"
BASE_CURRENCY = os.getenv("BASE_CURRENCY", "USD")
TARGET_CURRENCIES = os.getenv("TARGET_CURRENCIES", "THB,EUR,JPY,GBP,CNY")
SOURCE = "frankfurter"
DB_SCHEMA = os.getenv("DB_SCHEMA", "raw")
 
DB_CONFIG = {
    "host": os.getenv("DB_HOST", "localhost"),
    "port": os.getenv("DB_PORT", "5432"),
    "dbname": os.getenv("DB_NAME", "exchange_rate"),
    "user": os.getenv("DB_USER", "postgres"),
    "password": os.environ["PGPASSWORD"],
}
 
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
log = logging.getLogger("fx_extract")
 
Row = Tuple[date, str, str, float]

# ---------------------------------------------------------------------------
# 1. Fetch  — call the API with timeout + simple retry
# ---------------------------------------------------------------------------
def fetch_rates(path: str) -> dict:
    """GET {API_BASE}/{path} and return parsed JSON. Retries transient errors."""
    url = f"{API_BASE}/{path}"
    params = {"base": BASE_CURRENCY, "symbols": TARGET_CURRENCIES}
 
    last_err = None
    for attempt in range(1, 4):
        try:
            resp = requests.get(url, params=params, timeout=10)
            resp.raise_for_status()
            log.info("fetched %s", resp.url)
            return resp.json()
        except requests.RequestException as e:
            last_err = e
            log.warning("fetch failed (attempt %s/3): %s", attempt, e)
    raise RuntimeError(f"could not fetch {url}: {last_err}")
# ---------------------------------------------------------------------------
# 2. Transform  — flatten wide JSON into long rows
# ---------------------------------------------------------------------------
def to_rows(payload: dict) -> List[Row]:
    """
    Handle both response shapes:
      single day : {"date": "...",  "rates": {"THB": 36.7, ...}}
      time series: {"rates": {"2024-01-01": {"THB": 36.7, ...}, ...}}
    """
    base = payload["base"]
    rates = payload["rates"]
    rows: List[Row] = []
 
    is_series = bool(rates) and all(isinstance(v, dict) for v in rates.values())
 
    if is_series:
        for rate_date, day_rates in rates.items():
            for quote, value in day_rates.items():
                rows.append((rate_date, base, quote, value))
    else:
        rate_date = payload["date"]
        for quote, value in rates.items():
            rows.append((rate_date, base, quote, value))
 
    log.info("transformed %s rows", len(rows))
    return rows
# ---------------------------------------------------------------------------
# 3. Load  — idempotent upsert
# ---------------------------------------------------------------------------
def upsert(rows: List[Row]) -> int:
    if not rows:
        log.info("no rows to load")
        return 0
 
    table = f"{DB_SCHEMA}.raw_exchange_rates"
    sql = f"""
        INSERT INTO {table}
            (rate_date, base_currency, quote_currency, rate, source)
        VALUES %s
        ON CONFLICT (rate_date, base_currency, quote_currency, source)
        DO UPDATE SET rate = EXCLUDED.rate,
                      fetched_at = now();
    """
    values = [(d, b, q, r, SOURCE) for (d, b, q, r) in rows]

    conn = psycopg2.connect(**DB_CONFIG)
    try:
        with conn, conn.cursor() as cur:
            execute_values(cur, sql, values)  # one round-trip, batched
        log.info("upserted %s rows into %s", len(values), table)
        return len(values)
    finally:
        conn.close()
# ---------------------------------------------------------------------------
# Entry points
# ---------------------------------------------------------------------------
def run_latest() -> None:
    upsert(to_rows(fetch_rates("latest")))
 
 
def run_backfill(start: str, end: str) -> None:
    upsert(to_rows(fetch_rates(f"{start}..{end}")))
 
 
if __name__ == "__main__":
    if len(sys.argv) == 3:
        run_backfill(sys.argv[1], sys.argv[2])
    elif len(sys.argv) == 1:
        run_latest()
    else:
        print(__doc__)
        sys.exit(1)