variable "project_id" {
  description = "GCP project to manage, e.g. newzoo-nexus-raw-test. Also the bucket name prefix."
  type        = string
}

variable "env" {
  description = "Environment name as used in the `envs` lists of storage/buckets.yaml."
  type        = string

  validation {
    condition     = contains(["dev", "test", "prod"], var.env)
    error_message = "env must be one of dev, test, prod."
  }
}

variable "definitions_file" {
  description = "Path to storage/buckets.yaml."
  type        = string
}

variable "principals" {
  description = "This env's entry of environments/principals.yaml: name => IAM members."
  type        = map(list(string))
}

variable "location" {
  description = "Default bucket location; a bucket can override it."
  type        = string
}

variable "default_delete_after_days" {
  description = "Object age limit for buckets that don't set their own. 14 in dev, null elsewhere."
  type        = number
  default     = null
}

variable "developer_members" {
  description = "IAM members granted developer_role on every bucket."
  type        = list(string)
  default     = []
}

variable "developer_role" {
  description = "Role developers get on every bucket: objectUser in dev, objectViewer in test and prod."
  type        = string
  default     = "roles/storage.objectViewer"
}

variable "labels" {
  description = "Labels applied to every bucket."
  type        = map(string)
  default     = { managed_by = "terraform" }
}
