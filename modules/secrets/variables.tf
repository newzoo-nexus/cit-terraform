variable "project_id" {
  description = "GCP project to manage, e.g. newzoo-nexus-raw-test."
  type        = string
}

variable "env" {
  description = "Environment name as used in the `envs` lists of secrets/secrets.yaml."
  type        = string

  validation {
    condition     = contains(["dev", "test", "prod"], var.env)
    error_message = "env must be one of dev, test, prod."
  }
}

variable "definitions_file" {
  description = "Path to secrets/secrets.yaml."
  type        = string
}

variable "principals" {
  description = "This env's entry of environments/principals.yaml: name => IAM members."
  type        = map(list(string))
}

variable "developer_members" {
  description = "IAM members granted developer_role on every secret."
  type        = list(string)
  default     = []
}

variable "developer_role" {
  description = "Role developers get on every secret: secretAccessor in dev, viewer (metadata only) in test and prod."
  type        = string
  default     = "roles/secretmanager.viewer"
}

variable "value_admins" {
  description = "IAM members who may add new values (versions) to every secret, but not read them."
  type        = list(string)
  default     = []
}

variable "labels" {
  description = "Labels applied to every secret."
  type        = map(string)
  default     = { managed_by = "terraform" }
}
