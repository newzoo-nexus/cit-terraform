variable "location" {
  description = "BigQuery location of the datasets. TODO: confirm it matches the existing datasets (bq show --format=prettyjson newzoo-nexus-raw-test:steam)."
  type        = string
  default     = "EU"
}
