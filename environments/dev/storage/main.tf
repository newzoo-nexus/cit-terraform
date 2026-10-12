locals {
  project_id = "newzoo-nexus-raw-dev"
  env        = "dev"
  principals = yamldecode(file("${path.root}/../../principals.yaml"))[local.env]
}

module "storage" {
  source = "../../../modules/gcs_buckets"

  project_id        = local.project_id
  env               = local.env
  definitions_file  = "${path.root}/../../../storage/buckets.yaml"
  principals        = local.principals
  location          = var.location
  developer_members = local.principals.developers
  developer_role    = "roles/storage.objectUser"

  # Dev objects expire after 14 days, like dev tables, unless a bucket sets its own.
  default_delete_after_days = 14
}

output "buckets" {
  value = module.storage.bucket_names
}
