-- setup.sql
-- Creates the raw landing schema + table that extract.py loads into and that
-- dbt reads as source('raw', 'raw_exchange_rates').
--
-- Run once against the target database (matches the dbt profile: exchange_rate):
--   psql -h localhost -U postgres -d exchange_rate -f setup.sql
--
-- Safe to re-run: everything is IF NOT EXISTS.

create schema if not exists raw;

create table if not exists raw.raw_exchange_rates (
    rate_date       date            not null,
    base_currency   text            not null,
    quote_currency  text            not null,
    rate            numeric(20,10)  not null,
    source          text            not null,
    fetched_at      timestamptz     not null default now(),

    -- must match the ON CONFLICT target in extract.py::upsert()
    primary key (rate_date, base_currency, quote_currency, source)
);
