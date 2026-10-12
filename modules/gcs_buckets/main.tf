# GCS buckets for one environment, driven by storage/buckets.yaml.
#
# Every entry whose `envs` list contains var.env becomes a bucket named
# "<project_id>-<key>": the key raw-dumps gives newzoo-nexus-raw-dev-raw-dumps,
# newzoo-nexus-raw-test-raw-dumps and newzoo-nexus-raw-raw-dumps, so code only
# switches project. Existing buckets with other names are adopted with an
# explicit `name`: one name if the bucket is in a single env, otherwise a map
# per env ({test: ..., prod: ...}), since bucket names are global.
# Keys starting with "_" are examples and are ignored.
#
# readers / writers are principal names from environments/principals.yaml
# (e.g. composer, developers), resolved for this env, or literal IAM members
# containing ":" (serviceAccount:..., group:..., user:...).
#
# The Terraform state buckets (<project>-tfstate) are created by hand and are
# never managed here.

locals {
  definitions = yamldecode(file(var.definitions_file))
  live        = { for key, b in local.definitions : key => b if !startswith(key, "_") }

  buckets = {
    for key, b in local.live : key => {
      name              = coalesce(try(tostring(b.name), b.name[var.env], null), "${var.project_id}-${key}")
      location          = coalesce(try(b.location, null), var.location)
      storage_class     = try(b.storage_class, "STANDARD")
      versioning        = try(b.versioning, false)
      delete_after_days = try(b.delete_after_days, var.default_delete_after_days)
      labels            = try(b.labels, {})
      readers           = flatten([for m in try(b.readers, []) : strcontains(m, ":") ? [m] : lookup(var.principals, m, [])])
      writers           = flatten([for m in try(b.writers, []) : strcontains(m, ":") ? [m] : lookup(var.principals, m, [])])
    }
    if contains(try(b.envs, []), var.env)
  }

  # One entry per bucket x role x member: readers/writers per bucket, plus the
  # developer access that applies to every bucket in this env.
  iam = merge([
    for key, b in local.buckets : merge(
      { for m in b.readers : "${key}|objectViewer|${m}" => { bucket = key, role = "roles/storage.objectViewer", member = m } },
      { for m in b.writers : "${key}|objectUser|${m}" => { bucket = key, role = "roles/storage.objectUser", member = m } },
      { for m in var.developer_members : "${key}|dev|${m}" => { bucket = key, role = var.developer_role, member = m } },
    )
  ]...)

  # Mistakes that would otherwise be silently ignored; checked by the output
  # precondition in outputs.tf, so `terraform plan` fails with this list.
  fields = ["name", "location", "storage_class", "versioning", "delete_after_days", "readers", "writers", "labels", "envs"]
  errors = flatten([
    for key, b in local.live : concat(
      can(regex("^[a-z0-9][a-z0-9-]{0,38}[a-z0-9]$", key)) ? [] : ["${key}: keys must be 2-40 lowercase letters, digits and dashes"],
      key == "tfstate" ? ["tfstate: reserved for the hand-made Terraform state bucket"] : [],
      can(b.envs) ? [] : ["${key}: missing envs"],
      can(tostring(b.name)) && length(try(b.envs, [])) > 1 ? ["${key}: a single name only works for one env; use name: {test: ..., prod: ...}"] : [],
      [for e in try(b.envs, []) : "${key}: name has no entry for ${e}" if can(keys(b.name)) && !contains(try(keys(b.name), []), e)],
      [for f in keys(b) : "${key}: unknown field '${f}'" if !contains(local.fields, f)],
      [for e in try(b.envs, []) : "${key}: unknown env '${e}'" if !contains(["dev", "test", "prod"], e)],
      [for m in concat(try(b.readers, []), try(b.writers, [])) : "${key}: unknown principal '${m}' (add it to environments/principals.yaml)" if !strcontains(m, ":") && !contains(keys(var.principals), m)],
    )
  ])
}

resource "google_storage_bucket" "bucket" {
  for_each = local.buckets

  project       = var.project_id
  name          = each.value.name
  location      = each.value.location
  storage_class = each.value.storage_class
  labels        = merge(var.labels, each.value.labels)

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  # Never delete a bucket that still holds objects.
  force_destroy = false

  versioning {
    enabled = each.value.versioning
  }

  dynamic "lifecycle_rule" {
    for_each = each.value.delete_after_days == null ? [] : [each.value.delete_after_days]
    content {
      action {
        type = "Delete"
      }
      condition {
        age = lifecycle_rule.value
      }
    }
  }

  # Keep only the newest few noncurrent versions of versioned objects.
  dynamic "lifecycle_rule" {
    for_each = each.value.versioning ? [1] : []
    content {
      action {
        type = "Delete"
      }
      condition {
        num_newer_versions = 5
        with_state         = "ARCHIVED"
      }
    }
  }
}

# Non-authoritative: adds members without touching access granted elsewhere.
resource "google_storage_bucket_iam_member" "member" {
  for_each = local.iam

  bucket = google_storage_bucket.bucket[each.value.bucket].name
  role   = each.value.role
  member = each.value.member
}
