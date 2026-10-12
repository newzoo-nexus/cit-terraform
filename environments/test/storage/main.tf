locals {
  project_id = "newzoo-nexus-raw-test"
  env        = "test"
  principals = yamldecode(file("${path.root}/../../principals.yaml"))[local.env]
}

# Developers get only read access from Terraform here.
# TODO(close-manual-access): during the gradual migration, developers keep the
# admin access to this project they were given by hand (outside Terraform), so
# this is not what limits them yet. Removing that access is the last rollout
# step; see docs/setup.md, "8. Later: close manual access".
module "storage" {
  source = "../../../modules/gcs_buckets"

  project_id        = local.project_id
  env               = local.env
  definitions_file  = "${path.root}/../../../storage/buckets.yaml"
  principals        = local.principals
  location          = var.location
  developer_members = local.principals.developers
  developer_role    = "roles/storage.objectViewer"
}

output "buckets" {
  value = module.storage.bucket_names
}
