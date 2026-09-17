--- rename only ---
with sources as (
	select * from {{source('raw','raw_exchange_rates')}}
),
renamed as (
	select	rate_date,
			base_currency,
			quote_currency,
			base_currency || '/' || quote_currency	as pair_currency,
			rate::numeric(20,10)					as exchange_rate,
			source									as data_source,
			fetched_at
	from sources
)

select * from renamed