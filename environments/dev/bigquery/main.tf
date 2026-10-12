locals {
  project_id = "newzoo-nexus-raw-dev"
  principals = yamldecode(file("${path.root}/../../principals.yaml"))["dev"]
}

module "bigquery" {
  source = "../../../modules/bq_tables"

  project_id      = local.project_id
  env             = "dev"
  definitions_dir = "${path.root}/../../../bigquery"
  location        = var.location

  # Dev: datasets and IAM only. Tables come from scripts/dev_table.py and
  # expire after 14 days unless the script is rerun.
  create_tables                 = false
  default_table_expiration_days = 14

  dataset_iam = [
    for m in local.principals.developers : { role = "roles/bigquery.dataEditor", member = m }
  ]
}

output "datasets" {
  value = module.bigquery.datasets
}

output "tables" {
  value = module.bigquery.tables
}

output "views" {
  value = module.bigquery.views
}
