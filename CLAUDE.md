# new-terra

Terraform for the team's GCP resources (BigQuery, GCS, Secret Manager). Design and SOPs:
docs/terraform-bigquery-workflow.md. Setup: docs/setup.md.

- Environments are folders (`environments/dev|test|prod`), not branches. Everything is on `main`.
- Each environment is split into stacks (`environments/<env>/<stack>/`, e.g. `bigquery`), each with its
  own state (GCS prefix = stack name). Reusable code goes in `modules/`; a stack never reads another
  stack's state, it refers to resources by their (deterministic) names.
- BigQuery definitions live in `bigquery/`: `bigquery/catalog/<dataset>.yaml` is the source of truth; an object exists in an env iff `envs` lists it.
  Files starting with `_` are examples and ignored.
- Schemas are BigQuery JSON in `bigquery/schemas/<dataset>/`; views are SQL templates in `bigquery/views/<dataset>/`
  where `${project}` is the only variable and a literal `${` is written `$${`.
- Dev tables are created by `scripts/dev_table.py`, never by Terraform (`create_tables = false`).
- Never apply to test or prod locally; CircleCI does it (`.circleci/config.yml`, helpers in
  `.circleci/bin/`, auth via Workload Identity Federation, no keys). `terraform plan` locally is fine.
- During the migration developers keep manual admin access to test and prod; don't remove it as part
  of other work. Closing it is tracked by `TODO(close-manual-access)` and docs/setup.md step 8.
  Change Terraform-managed resources through PRs: manual edits show up as drift and get reverted.
- Prod has `deletion_protection = true`; don't turn it off as part of an unrelated change.
- Buckets: `storage/buckets.yaml`, each entry with `envs`; bucket name `<project>-<key>`.
- Secrets: `secrets/secrets.yaml`, each entry with `envs`. Terraform never holds secret values; they are
  added in Secret Manager (console or `gcloud secrets versions add`). Never add a `google_secret_manager_secret_version` resource.
- Who: `environments/principals.yaml` maps names (developers, composer, secret_value_admins) to IAM
  members per env. Entries refer to those names; literal members contain ":".
- Day-to-day changes are YAML edits; `environments/` and `modules/` change only when the setup changes.
- Keep views one layer deep. Run `terraform fmt -recursive` before committing.
