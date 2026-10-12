locals {
  project_id = "newzoo-nexus-raw-test"
  principals = yamldecode(file("${path.root}/../../principals.yaml"))["test"]
}

# Developers get only read access from Terraform here.
# TODO(close-manual-access): during the gradual migration, developers keep the
# admin access to this project they were given by hand (outside Terraform), so
# this is not what limits them yet. Removing that access is the last rollout
# step; see docs/setup.md, "8. Later: close manual access".
module "bigquery" {
  source = "../../../modules/bq_tables"

  project_id      = local.project_id
  env             = "test"
  definitions_dir = "${path.root}/../../../bigquery"
  location        = var.location

  dataset_iam = [
    for m in local.principals.developers : { role = "roles/bigquery.dataViewer", member = m }
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
