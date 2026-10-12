# Secret Manager secrets for one environment, driven by secrets/secrets.yaml:
# the secret, its replication and who may read it. NOT the value: values are
# added out of band (Secret Manager console or `gcloud secrets versions add`)
# so they never end up in Terraform state or in git.
#
# Every entry whose `envs` list contains var.env becomes a secret with that ID.
# The ID is the same in every project, so code reads
# projects/<project>/secrets/<id>/versions/latest and only switches project.
# A new secret has no value until someone adds one; reading it fails until then.
# Keys starting with "_" are examples and are ignored.
#
# accessors are principal names from environments/principals.yaml (e.g.
# composer), resolved for this env, or literal IAM members containing ":".

locals {
  definitions = yamldecode(file(var.definitions_file))
  live        = { for id, s in local.definitions : id => s if !startswith(id, "_") }

  secrets = {
    for id, s in local.live : id => {
      description       = try(s.description, null)
      replica_locations = try(s.replica_locations, [])
      labels            = try(s.labels, {})
      accessors         = flatten([for m in try(s.accessors, []) : strcontains(m, ":") ? [m] : lookup(var.principals, m, [])])
    }
    if contains(try(s.envs, []), var.env)
  }

  iam = merge([
    for id, s in local.secrets : merge(
      { for m in s.accessors : "${id}|accessor|${m}" => { secret = id, role = "roles/secretmanager.secretAccessor", member = m } },
      { for m in var.developer_members : "${id}|developer|${m}" => { secret = id, role = var.developer_role, member = m } },
      { for m in var.value_admins : "${id}|adder|${m}" => { secret = id, role = "roles/secretmanager.secretVersionAdder", member = m } },
    )
  ]...)

  # Mistakes that would otherwise be silently ignored; checked by the output
  # precondition in outputs.tf, so `terraform plan` fails with this list.
  fields = ["description", "accessors", "replica_locations", "labels", "envs"]
  errors = flatten([
    for id, s in local.live : concat(
      can(regex("^[A-Za-z0-9_-]{1,255}$", id)) ? [] : ["${id}: IDs may contain only letters, digits, underscores and dashes"],
      can(s.envs) ? [] : ["${id}: missing envs"],
      [for f in keys(s) : "${id}: unknown field '${f}'" if !contains(local.fields, f)],
      [for e in try(s.envs, []) : "${id}: unknown env '${e}'" if !contains(["dev", "test", "prod"], e)],
      [for m in try(s.accessors, []) : "${id}: unknown principal '${m}' (add it to environments/principals.yaml)" if !strcontains(m, ":") && !contains(keys(var.principals), m)],
    )
  ])
}

resource "google_secret_manager_secret" "secret" {
  for_each = local.secrets

  project   = var.project_id
  secret_id = each.key
  labels    = merge(var.labels, each.value.labels)

  annotations = each.value.description == null ? {} : { description = each.value.description }

  replication {
    dynamic "auto" {
      for_each = length(each.value.replica_locations) == 0 ? [1] : []
      content {}
    }

    dynamic "user_managed" {
      for_each = length(each.value.replica_locations) == 0 ? [] : [1]
      content {
        dynamic "replicas" {
          for_each = each.value.replica_locations
          content {
            location = replicas.value
          }
        }
      }
    }
  }
}

# Non-authoritative: adds members without touching access granted elsewhere.
resource "google_secret_manager_secret_iam_member" "member" {
  for_each = local.iam

  project   = var.project_id
  secret_id = google_secret_manager_secret.secret[each.value.secret].secret_id
  role      = each.value.role
  member    = each.value.member
}
