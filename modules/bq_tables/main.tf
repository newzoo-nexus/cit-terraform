# Datasets, tables and views for one environment, driven by the catalog.
#
# Every bigquery/catalog/<dataset>.yaml becomes a dataset. Its tables and views are
# created only when their `envs` list contains var.env (and, for dev, only when
# var.create_tables is true — dev tables are made by scripts/dev_table.py).
# Files whose name starts with "_" (e.g. _example.yaml) are ignored.

locals {
  catalog_files = [
    for f in fileset("${var.definitions_dir}/catalog", "*.yaml") : f
    if !startswith(f, "_")
  ]

  catalogs = {
    for f in local.catalog_files :
    trimsuffix(f, ".yaml") => yamldecode(file("${var.definitions_dir}/catalog/${f}"))
  }

  tables = merge([
    for ds, c in local.catalogs : {
      # partition_field set: column partitioning (type defaults to DAY).
      # Only partition_type set: ingestion-time partitioning (_PARTITIONTIME).
      for name, cfg in try(c.tables, {}) : "${ds}.${name}" => {
        dataset                  = ds
        name                     = name
        schema                   = cfg.schema
        description              = try(cfg.description, null)
        partition_field          = try(cfg.partition_field, null)
        partition_type           = try(cfg.partition_type, null)
        partition_expiration_ms  = try(cfg.partition_expiration_days * 86400000, null)
        require_partition_filter = try(cfg.require_partition_filter, null)
        clustering               = try(cfg.clustering, null)
      }
      if var.create_tables && contains(try(cfg.envs, []), var.env)
    }
  ]...)

  views = merge([
    for ds, c in local.catalogs : {
      for name, cfg in try(c.views, {}) : "${ds}.${name}" => {
        dataset     = ds
        name        = name
        sql         = cfg.sql
        description = try(cfg.description, null)
      }
      if var.create_tables && contains(try(cfg.envs, []), var.env)
    }
  ]...)

  # Catalog mistakes that would otherwise be silently ignored (a misspelt
  # field, an unknown env). Checked by the output preconditions in outputs.tf.
  envs = ["dev", "test", "prod"]
  catalog_errors = flatten([
    for ds, c in local.catalogs : concat(
      [for k in keys(c) : "${ds}: unknown top-level key '${k}'" if !contains(["description", "tables", "views"], k)],
      flatten([for name, cfg in try(c.tables, {}) : concat(
        [for k in keys(cfg) : "${ds}.${name}: unknown table field '${k}'" if !contains(["schema", "description", "partition_field", "partition_type", "partition_expiration_days", "require_partition_filter", "clustering", "envs"], k)],
        [for t in compact([try(cfg.partition_type, null)]) : "${ds}.${name}: partition_type must be HOUR, DAY, MONTH or YEAR, got '${t}'" if !contains(["HOUR", "DAY", "MONTH", "YEAR"], t)],
        can(cfg.partition_expiration_days) && !can(cfg.partition_field) && !can(cfg.partition_type) ? ["${ds}.${name}: partition_expiration_days needs partition_field or partition_type"] : [],
        [for e in try(cfg.envs, []) : "${ds}.${name}: unknown env '${e}'" if !contains(local.envs, e)],
      )]),
      flatten([for name, cfg in try(c.views, {}) : concat(
        [for k in keys(cfg) : "${ds}.${name}: unknown view field '${k}'" if !contains(["sql", "description", "envs"], k)],
        [for e in try(cfg.envs, []) : "${ds}.${name}: unknown env '${e}'" if !contains(local.envs, e)],
      )]),
    )
  ])

  dataset_iam = {
    for pair in setproduct(keys(local.catalogs), var.dataset_iam) :
    "${pair[0]}|${pair[1].role}|${pair[1].member}" => {
      dataset = pair[0]
      role    = pair[1].role
      member  = pair[1].member
    }
  }
}

resource "google_bigquery_dataset" "dataset" {
  for_each = local.catalogs

  project     = var.project_id
  dataset_id  = each.key
  location    = var.location
  description = try(each.value.description, null)
  labels      = var.labels

  default_table_expiration_ms = (
    var.default_table_expiration_days == null ? null : var.default_table_expiration_days * 24 * 60 * 60 * 1000
  )

  # Never drop a dataset that still holds tables.
  delete_contents_on_destroy = false
}

# Non-authoritative: adds members without touching access granted elsewhere.
resource "google_bigquery_dataset_iam_member" "member" {
  for_each = local.dataset_iam

  project    = var.project_id
  dataset_id = google_bigquery_dataset.dataset[each.value.dataset].dataset_id
  role       = each.value.role
  member     = each.value.member
}

resource "google_bigquery_table" "table" {
  for_each = local.tables

  project             = var.project_id
  dataset_id          = google_bigquery_dataset.dataset[each.value.dataset].dataset_id
  table_id            = each.value.name
  description         = each.value.description
  schema              = file("${var.definitions_dir}/schemas/${each.value.schema}")
  clustering          = each.value.clustering
  deletion_protection = var.deletion_protection
  labels              = var.labels

  require_partition_filter = each.value.require_partition_filter

  dynamic "time_partitioning" {
    for_each = each.value.partition_field == null && each.value.partition_type == null ? [] : [each.value]
    content {
      type          = coalesce(time_partitioning.value.partition_type, "DAY")
      field         = time_partitioning.value.partition_field # null = ingestion time
      expiration_ms = time_partitioning.value.partition_expiration_ms
    }
  }
}

# Views are created after all tables, because BigQuery validates a view's
# query at creation. Keep views one layer deep (see docs/).
resource "google_bigquery_table" "view" {
  for_each = local.views

  project             = var.project_id
  dataset_id          = google_bigquery_dataset.dataset[each.value.dataset].dataset_id
  table_id            = each.value.name
  description         = each.value.description
  deletion_protection = var.deletion_protection
  labels              = var.labels

  view {
    query          = templatefile("${var.definitions_dir}/views/${each.value.sql}", { project = var.project_id })
    use_legacy_sql = false
  }

  depends_on = [google_bigquery_table.table]
}
