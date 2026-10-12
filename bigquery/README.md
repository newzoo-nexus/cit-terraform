# bigquery/

What the BigQuery stack (`environments/<env>/bigquery/`) creates. Nothing
else in the repo reads these files; buckets and secrets are defined in their
own stack folders.

| Folder | Holds |
| --- | --- |
| `catalog/<dataset>.yaml` | One file per dataset (ecosystem): its tables and views, and the `envs` each exists in |
| `schemas/<dataset>/<table>.json` | Table schemas, in `bq show --schema --format=prettyjson` format |
| `views/<dataset>/<view>.sql` | View SQL; `${project}` is filled in per environment, a literal `${` is written `$${` |

Files and folders starting with `_` are examples and are ignored.

- Create a table or view in dev: `python scripts/dev_table.py steam.player_counts`
- Generate these files for an existing dataset: `python scripts/bootstrap_catalog.py steam`

See the main README for the full flow from dev to prod.
