output "bucket_names" {
  description = "Bucket names by key."
  value       = { for k, b in google_storage_bucket.bucket : k => b.name }

  precondition {
    condition     = length(local.errors) == 0
    error_message = "Fix storage/buckets.yaml: ${join("; ", local.errors)}"
  }
}
