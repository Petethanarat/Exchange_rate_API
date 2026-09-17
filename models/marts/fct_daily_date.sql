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
        min(exchange_rate) over w as running_low
 
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