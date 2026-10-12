output "datasets" {
  description = "Datasets managed in this environment."
  value       = sort(keys(google_bigquery_dataset.dataset))

  precondition {
    condition     = length(local.catalog_errors) == 0
    error_message = "Fix bigquery/catalog/: ${join("; ", local.catalog_errors)}"
  }
}

output "tables" {
  description = "Tables managed in this environment, as dataset.table."
  value       = sort(keys(google_bigquery_table.table))
}

output "views" {
  description = "Views managed in this environment, as dataset.view."
  value       = sort(keys(google_bigquery_table.view))
}
