-- The project is filled in per environment (see README: escape literal dollar-braces by doubling the dollar).
SELECT *
FROM `${project}._example.store_prices`
QUALIFY ROW_NUMBER() OVER (PARTITION BY app_id, country ORDER BY scraped_at DESC) = 1
