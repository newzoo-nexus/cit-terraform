locals {
  project_id = "newzoo-nexus-raw"
  env        = "prod"
  principals = yamldecode(file("${path.root}/../../principals.yaml"))[local.env]
}

# Developers get only read access from Terraform here.
# TODO(close-manual-access): during the gradual migration, developers keep the
# admin access to this project they were given by hand (outside Terraform), so
# this is not what limits them yet. Removing that access is the last rollout
# step; see docs/setup.md, "8. Later: close manual access".
module "secrets" {
  source = "../../../modules/secrets"

  project_id        = local.project_id
  env               = local.env
  definitions_file  = "${path.root}/../../../secrets/secrets.yaml"
  principals        = local.principals
  developer_members = local.principals.developers
  developer_role    = "roles/secretmanager.viewer"
  value_admins      = local.principals.secret_value_admins
}

output "secrets" {
  value = module.secrets.secret_ids
}
