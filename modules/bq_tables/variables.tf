variable "project_id" {
  description = "GCP project to manage, e.g. newzoo-nexus-raw-test."
  type        = string
}

variable "env" {
  description = "Environment name as used in the catalog's `envs` lists."
  type        = string

  validation {
    condition     = contains(["dev", "test", "prod"], var.env)
    error_message = "env must be one of dev, test, prod."
  }
}

variable "definitions_dir" {
  description = "Path to the BigQuery definitions: the repo's bigquery/ folder (catalog/, schemas/, views/)."
  type        = string
}

variable "location" {
  description = "BigQuery location for the datasets. Must match the existing datasets, or import will plan a replace."
  type        = string
}

variable "create_tables" {
  description = "Create the catalog's tables and views. False in dev, where scripts/dev_table.py creates them."
  type        = bool
  default     = true
}

variable "deletion_protection" {
  description = "Terraform-side deletion protection on tables and views. True in prod."
  type        = bool
  default     = false
}

variable "default_table_expiration_days" {
  description = "Default expiration for new tables in each dataset. 14 in dev, null elsewhere."
  type        = number
  default     = null
}

variable "dataset_iam" {
  description = "Role/member pairs granted on every dataset (non-authoritative)."
  type = list(object({
    role   = string
    member = string
  }))
  default = []
}

variable "labels" {
  description = "Labels applied to datasets, tables and views."
  type        = map(string)
  default     = { managed_by = "terraform" }
}
