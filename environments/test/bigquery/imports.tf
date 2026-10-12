# Import blocks for bringing existing datasets and tables under Terraform.
# Generate them with:  python scripts/bootstrap_catalog.py <dataset>
# which writes environments/test/bigquery/imports_<dataset>.tf. Once an import has been
# applied, the block can be deleted (keeping it is harmless).
#
# Hand-written example:
#
# import {
#   to = module.bigquery.google_bigquery_dataset.dataset["steam"]
#   id = "projects/newzoo-nexus-raw-test/datasets/steam"
# }
#
# import {
#   to = module.bigquery.google_bigquery_table.table["steam.store_prices"]
#   id = "projects/newzoo-nexus-raw-test/datasets/steam/tables/store_prices"
# }
