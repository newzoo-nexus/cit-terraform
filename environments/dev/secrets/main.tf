locals {
  project_id = "newzoo-nexus-raw-dev"
  env        = "dev"
  principals = yamldecode(file("${path.root}/../../principals.yaml"))[local.env]
}

module "secrets" {
  source = "../../../modules/secrets"

  project_id        = local.project_id
  env               = local.env
  definitions_file  = "${path.root}/../../../secrets/secrets.yaml"
  principals        = local.principals
  developer_members = local.principals.developers
  developer_role    = "roles/secretmanager.secretAccessor"
  value_admins      = local.principals.developers
}

output "secrets" {
  value = module.secrets.secret_ids
}
