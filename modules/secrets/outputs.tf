output "secret_ids" {
  description = "Managed secrets, by ID, as full resource names."
  value       = { for k, s in google_secret_manager_secret.secret : k => s.name }

  precondition {
    condition     = length(local.errors) == 0
    error_message = "Fix secrets/secrets.yaml: ${join("; ", local.errors)}"
  }
}
