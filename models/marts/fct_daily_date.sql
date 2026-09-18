with rates as (
 
    select * from {{ ref('stg_exchange_rates') }}
 
),
 
with_metrics as (
 
    select
        rate_date,
        base_currency,
        quote_currency,
        pair_currency,
        exchange_rate,
 
        -- previous trading day's rate for the pair
        lag(exchange_rate) over w as prev_rate,
 
        -- 7 / 30 trading-day simple moving averages
        avg(exchange_rate) over (
            partition by pair_currency order by rate_date
            rows between 6 preceding and current row
        ) as ma_7d,
 
        avg(exchange_rate) over (
            partition by pair_currency order by rate_date
            rows between 29 preceding and current row
        ) as ma_30d,
 
        -- 30 trading-day rolling volatility (sample std dev)
        stddev_samp(exchange_rate) over (
            partition by pair_currency order by rate_date
            rows between 29 preceding and current row
        ) as volatility_30d,
 
        -- running high / low since data begins
        max(exchange_rate) over w as running_high,
        min(exchange_rate) over w as running_low,

        -- rebased index: 100 at each pair's first trading day (fixed baseline).
        -- first_value over w (frame = unbounded preceding -> current row) is the
        -- earliest row's rate, constant across the partition.
        round(
            exchange_rate / first_value(exchange_rate) over w * 100
        , 4) as rate_indexed,

        -- multi-horizon % change (trading-day offsets: 7 / 30 rows back)
        round(
            (exchange_rate - lag(exchange_rate, 7) over w)
            / nullif(lag(exchange_rate, 7) over w, 0) * 100
        , 4) as pct_change_7d,

        round(
            (exchange_rate - lag(exchange_rate, 30) over w)
            / nullif(lag(exchange_rate, 30) over w, 0) * 100
        , 4) as pct_change_30d,

        -- % change since the first trading day of the calendar year (YTD)
        round(
            (exchange_rate / first_value(exchange_rate) over (
                partition by pair_currency, date_trunc('year', rate_date)
                order by rate_date
            ) - 1) * 100
        , 4) as pct_change_ytd
 
    from rates
 
    -- named window: with ORDER BY and no explicit frame, the default frame is
    -- UNBOUNDED PRECEDING -> CURRENT ROW, so max/min give a RUNNING high/low.
    -- lag() ignores the frame, so it correctly returns the prior row.
    window w as (partition by pair_currency order by rate_date)
 
)
 
select
    *,
    round(
        (exchange_rate - prev_rate) / nullif(prev_rate, 0) * 100
    , 4) as pct_change_1d
from with_metrics