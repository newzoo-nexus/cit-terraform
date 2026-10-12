# Terraform for BigQuery: Proposed Workflow

Oct 8, 2026 · @Andy

## Summary

We manage the BigQuery datasets and tables in `newzoo-nexus-raw-test` and `newzoo-nexus-raw` with Terraform, from a single `main` branch, and add a third project, `newzoo-nexus-raw-dev`, for local development.

- **Environments are folders, not branches.** Dev, test and prod each have their own Terraform configs and state, split into stacks: BigQuery, GCS and Secret Manager. Nothing is ever merged from test into prod.
- **Shared YAML files list every table, view, bucket and secret** and which environments it exists in. Promoting anything to prod is a one-line PR.
- **Local development needs no Terraform and no PR.** A script creates tables in the dev project straight from the catalog and schema files.
- **Scrapers only switch project.** Dataset names (`xbox`, `playstation`, `steam`, …) are identical in all three projects. Scrapers only need a way to pick the dev project; scraper-utils chooses between test and prod today.

## Why not a branch per environment

The obvious setup, a `test` branch and a `prod` branch, breaks our workflow in three places.

- **Starting a scraper would need a merged PR** just to get a destination table to develop against.
- **Removing a table from test needs another commit**, and if it is forgotten, the next test-to-prod merge creates that table in prod.
- **The branches drift.** Hotfixes on one side and experiments on the other make every merge a manual review of what test and prod should actually differ by.

The root cause is that branches mix two things: code history and environment membership. This plan keeps history in git and states environment membership explicitly in the catalog.

## Environments

Three projects share the same dataset names; they differ in who may create tables and how.

| Project | Purpose | Datasets | Tables created by | Who writes data |
| --- | --- | --- | --- | --- |
| `newzoo-nexus-raw-dev` (new) | Local development and debugging | Terraform | `dev_table.py` script, freely | Developers, from their machines |
| `newzoo-nexus-raw-test` | Airflow runs before promotion | Terraform | Terraform, via PR | Composer service account |
| `newzoo-nexus-raw` | Production | Terraform | Terraform, via PR with approval | Composer service account |

Tables in dev expire after 14 days unless the script is rerun, so abandoned experiments clean themselves up. Developers get write access in dev. During the migration they also keep their existing admin access to test and prod, but Terraform-managed resources still change only through PRs: a manual edit shows up as drift and is reverted on the next apply. The dev project costs little beyond the storage and queries we actually use.

## Repository layout

The infra repo, new-terra, holds the catalog, the schemas and the Terraform configs for every stack; scrapers stay in their own repo.

What exists is described in YAML at the top level: `bigquery/` for tables and views, `storage/buckets.yaml`, `secrets/secrets.yaml`. Who is who in each environment is in `environments/principals.yaml`. The rest of `environments/` and `modules/` is Terraform plumbing that rarely changes.

```
new-terra/
├── bigquery/                 # WHAT: tables and views
│   ├── catalog/
│   │   ├── xbox.yaml         # one file per dataset (ecosystem)
│   │   ├── playstation.yaml
│   │   └── steam.yaml
│   ├── schemas/steam/store_prices.json
│   └── views/steam/store_prices_latest.sql   # SQL template, ${project} per env
├── storage/
│   └── buckets.yaml          # WHAT: GCS buckets, each with envs
├── secrets/
│   └── secrets.yaml          # WHAT: secrets, each with envs (never values)
├── environments/
│   ├── principals.yaml       # WHO: developers, composer, ... per env
│   ├── dev/                  # HOW: one folder per stack: bigquery/ storage/ secrets/
│   ├── test/
│   └── prod/
├── modules/                  # HOW: bq_tables, gcs_buckets, secrets
├── scripts/
│   ├── dev_table.py          # creates tables and views in dev without Terraform
│   └── bootstrap_catalog.py  # catalog, schemas and imports for an existing dataset
└── docs/
```

### Catalog

Each dataset has one catalog file listing its tables and the environments they exist in. One file per ecosystem keeps PRs small and avoids merge conflicts between people working on different ecosystems.

```yaml
# bigquery/catalog/steam.yaml
tables:
  store_prices:
    schema: steam/store_prices.json
    partition_field: scraped_at
    envs: [test, prod]
  player_counts:
    schema: steam/player_counts.json
    partition_field: scraped_at
    envs: [test]        # not promoted yet

views:
  store_prices_latest:
    sql: steam/store_prices_latest.sql
    envs: [test]
```

Partitioning: `partition_field` partitions by that column (`partition_type` defaults to `DAY`); `partition_type` on its own (e.g. `partition_type: DAY`) means ingestion-time partitioning (`_PARTITIONTIME`), which many existing tables use. `partition_expiration_days` and `require_partition_filter` are optional. Changing a table's partitioning recreates it, so the bootstrap must capture it exactly.

The test and prod configs read every catalog file and keep only the tables whose `envs` include them. Prod sets `deletion_protection = true`; test does not.

### Schemas

Schemas are standard BigQuery JSON (the format of `bq show --schema --format=prettyjson`). Terraform and the dev script both read the same file, so a table looks the same in dev, test and prod.

### Views

Views are catalog entries like tables, with their SQL kept as templates under `bigquery/views/<dataset>/`. The project is the only template variable, because views reference fully qualified tables:

```sql
-- bigquery/views/steam/store_prices_latest.sql
SELECT *
FROM `${project}.steam.store_prices`
QUALIFY ROW_NUMBER() OVER (PARTITION BY app_id ORDER BY scraped_at DESC) = 1
```

Terraform renders each template with `templatefile(..., { project = var.project_id })` and creates the view after all tables, since BigQuery validates a view's query at creation. Rules to keep this simple:

- **Keep views one layer deep.** A view that selects from another view needs a `layer` field in the catalog and a resource block per layer, because Terraform cannot see that dependency.
- **Escape `${` in SQL as `$${`**, since `templatefile` treats it as template syntax.
- **Promote tables before or with their views.** A view in prod fails to plan until its tables are in prod.
- **Dev views expire with their tables.** Rerun `dev_table.py` for both when that happens.

If views grow into multi-layer transformation logic with tests, we move them to Dataform or dbt rather than Terraform.

### State

State lives in GCS, never in git: one bucket per project (for example `newzoo-nexus-raw-tfstate` and `newzoo-nexus-raw-test-tfstate`), with object versioning on. GCS locks the state during an apply, so two runs cannot collide. The buckets are created once by hand.

Each stack keeps its own state under a prefix named after it (`bigquery`, `storage` and `secrets`), so the dev project gets a `newzoo-nexus-raw-dev-tfstate` bucket too.

### Stacks

GCS buckets and Secret Manager live in this same repo, but each kind of resource gets its own folder and Terraform state, called a stack.

- **Same repo.** Same team, same three projects, same PR flow. CI, state buckets, the CircleCI login and the prod gate are reused, and one PR can add a table, a bucket and a secret for a new scraper.
- **Separate state per stack.** A bad catalog PR cannot plan changes to secrets or buckets, plans stay small, and each stack can run under its own service account if needed.
- **Same shape as tables.** Buckets and secrets are listed in one shared YAML file each, every entry with `envs`, so promoting is adding `prod`, as for tables.
- **Names, not accounts.** Entries say `composer` or `developers`; `environments/principals.yaml` says who that is in each environment, so one entry works in test and prod although the Composer service account differs.
- **Secret values stay out of Terraform.** Terraform manages each secret and who can read it. Values are added with `gcloud secrets versions add`, so they never land in state.
- **Typos fail the plan.** An unknown field, env or principal name stops the plan with a list of what to fix, instead of being silently ignored.
- **Stacks don't read each other's state.** They refer to resources by name, which follows the same pattern in every project.

| Stack | Defined in | Naming | Developers in dev | Developers in test, prod |
| --- | --- | --- | --- | --- |
| bigquery | `bigquery/catalog/<dataset>.yaml` | dataset = ecosystem | write (tables expire after 14 days) | read |
| storage | `storage/buckets.yaml` | `<project>-<key>`, same key in every env | write (objects expire after 14 days) | read |
| secrets | `secrets/secrets.yaml` | same secret ID in every env | read and add values | metadata only |

Developer access comes from the `developers` entry in `environments/principals.yaml`. Secret values are added in Secret Manager (the console or `gcloud secrets versions add`) after the secret is applied. In test and prod, `secret_value_admins` may add values without being able to read them; only each secret's `accessors` (such as `composer`) can read.

A separate repo only makes sense for resources another team owns, or for things above the three projects: project creation, org IAM, the CI login pool.

### How the folders fit together

The YAML files are the data, `modules/` is the code that turns data into GCP resources, and each `environments/<env>/<stack>/` folder runs that code for one environment and keeps its state.

```
storage/buckets.yaml          data:  what should exist
environments/principals.yaml  data:  who is who, per env
modules/gcs_buckets/          code:  how to turn the data into resources
environments/test/storage/    run:   that code for test, with its own state
```

**`modules/` is written once.** A module knows how to build, say, a bucket with its lifecycle rules and access, but not which project it builds for, and it has no state. A module change therefore reaches dev, test and prod at once, and its PR shows nine plans; it deserves the most careful review.

**`environments/<env>/<stack>/` is where Terraform runs.** Each of the nine folders has its own state (`backend.tf`), provider settings (`versions.tf`) and one module call (`main.tf`), so a plan there can only touch that environment's resources of that kind. The folders are near-identical on purpose; every difference between environments is an argument in `main.tf`:

| Setting | dev | test | prod |
| --- | --- | --- | --- |
| Tables created by Terraform | no (`dev_table.py`) | yes | yes |
| Deletion protection on tables | no | no | yes |
| Default expiry of tables and objects | 14 days | none | none |
| Developer access | write | read | read |
| Who adds secret values | developers | `secret_value_admins` | `secret_value_admins` |

A CI plan for `environments/test/storage/` loads its state from `gs://newzoo-nexus-raw-test-tfstate/storage`, reads the `test` part of `principals.yaml`, calls `modules/gcs_buckets`, which keeps the `storage/buckets.yaml` entries whose `envs` include `test`, and compares that with the state and with GCP.

| To change | Edit |
| --- | --- |
| One table, view, bucket or secret | Its YAML entry |
| Who someone is in an environment | `environments/principals.yaml` |
| Behaviour of every bucket (or table, or secret) everywhere | The module |
| Behaviour of one environment only | That environment's stack `main.tf` |
| A new kind of resource, such as Pub/Sub | A new module plus a stack folder per environment |

Three things to avoid:

- **Resources written directly in an environment's `main.tf`.** They exist in that environment only and bypass the YAML, so environments drift apart.
- **Renaming a resource inside a module without a `moved` block.** Terraform tracks resources by address, so a rename plans a destroy and re-create of every one of them.
- **Changing one environment folder and forgetting the others.** The intended differences are those in the table above; anything else should match across dev, test and prod.

## Lifecycle of a scraper

A scraper moves from dev to test to prod through two PRs in the infra repo; local work needs none.

1. **Develop.** On a branch of the infra repo, add the schema file and a catalog entry with `envs: [test]`. Run `python scripts/dev_table.py steam.player_counts` to create the table in dev. Build the scraper in its repo with the project set to `newzoo-nexus-raw-dev`. When the schema changes, edit the JSON and rerun the script (`--recreate` for breaking changes).
2. **Open the infra PR.** CI posts `terraform plan` for dev, test and prod (in the CircleCI jobs, and on the PR when a GitHub token is set): test shows one new table, prod shows no changes. Merging applies test.
3. **Run in Airflow on test.** Deploy the DAG with the project set to `newzoo-nexus-raw-test`, as today.
4. **Promote.** A second PR changes `envs` to `[test, prod]`. After approval, CI applies prod and the DAG is switched to `newzoo-nexus-raw`.
5. **Retire.** Remove an environment from `envs`, or delete the entry. The plan shows the table being destroyed. In prod, deletion protection blocks the apply until someone deliberately turns it off for that table.

Schema changes follow steps 2–4. Adding nullable columns is applied in place; changing a type or removing a column shows up in the plan as a replace, which is the warning to plan a migration.

Views follow the same steps: add the SQL template and a catalog entry, create it in dev with `dev_table.py steam.store_prices_latest`, then promote it with its tables.

## CI/CD and permissions

CircleCI runs Terraform, as it runs CI for our other repos; nobody applies to test or prod from a laptop.

| Trigger | Jobs | Gate |
| --- | --- | --- |
| Push to a branch | `check` (fmt, validate), then `plan-dev`, `plan-test`, `plan-prod`; plans in the job log and artifacts, and on the PR when a GitHub token is set | Code review; branch protection requires these checks |
| Merge to `main` | `apply-dev`, then `apply-test` | None |
| Merge to `main` | `plan-prod` saves the plans, `hold-prod` waits, `apply-prod` applies exactly those plans | Approval of `hold-prod` by the prod approvers' group |

- **Authentication:** Workload Identity Federation with CircleCI's OIDC token, so no service account keys are stored in CircleCI.
- **One Terraform service account per project**, so the test pipeline cannot touch prod. Prod adds a read-only `terraform-plan` account for PR plans.
- **The prod admin account only works from `main`.** A WIF rule on the git ref enforces it, and its CircleCI context is restricted to the prod approvers' group, so a branch that edits the CI config cannot apply prod.
- **Developers:** write in `newzoo-nexus-raw-dev`, read in test and prod from Terraform. Until the migration is done they also keep the admin access to test and prod they were given by hand; closing it is the last rollout step.
- **DAGs deploy separately.** Terraform manages datasets, tables, buckets, secrets and IAM; DAG files keep going to the Composer bucket through our existing deploy.

CI plans and applies every folder under `environments/<env>/`, so a new stack needs no CI change. `plan-prod` ends by saying whether prod has changes. CircleCI cannot skip an approval based on a job's result, so `hold-prod` appears on every merge; when prod has no changes it can simply be left unapproved. A saved plan refuses to apply if prod changed in between, and jobs for the same environment run one at a time (`serial-group`).

## SOPs

Day-to-day work is a YAML edit and a PR. Three questions cover the whole repo:

- **What exists, and where?** One entry per table, view, bucket or secret, in `bigquery/`, `storage/buckets.yaml` or `secrets/secrets.yaml`. Its `envs` list says which environments it exists in.
- **Who gets access?** Entries name roles such as `composer` or `developers`; `environments/principals.yaml` says who those are in each environment.
- **What are the secret values?** Never in the repo. They are added in Secret Manager (the console or `gcloud secrets versions add`) once the secret exists.

Every change takes the same path: PR (CI comments a plan per environment), merge (dev and test applied), prod plan, one approval, prod applied.

| Task | Edit | After merge |
| --- | --- | --- |
| New table or view | `bigquery/catalog/<dataset>.yaml` + schema or SQL file | See Lifecycle of a scraper |
| New bucket | `storage/buckets.yaml` | Nothing |
| New secret | `secrets/secrets.yaml` | Add the value in each env |
| Promote to prod | Add `prod` to the entry's `envs` | Approve the prod run; for a secret, add the prod value |
| Rotate a secret value | Nothing (no PR) | Add a new version in Secret Manager |
| Give a person or service access | `environments/principals.yaml`, or the entry's `readers` / `writers` / `accessors` | Nothing |
| Retire from an environment | Remove the env from `envs` | Check the destroy in the plan first |
| Adopt an existing bucket or secret | The YAML entry + an `import` block | Delete the import block |

### New bucket

1. Add an entry to `storage/buckets.yaml`:

```yaml
raw-dumps:
  envs: [dev, test]
  writers: [composer]
  delete_after_days: 90
```

2. Open a PR. The dev and test plans each show one new bucket (`newzoo-nexus-raw-dev-raw-dumps`, `newzoo-nexus-raw-test-raw-dumps`); prod shows no changes.
3. Merge. CI creates both buckets. The scraper finds its bucket as `<project>-raw-dumps`.
4. When the scraper goes to prod, promote the bucket (below).

### New secret

1. Add an entry to `secrets/secrets.yaml`, without a value:

```yaml
steam-api-key:
  description: Steam Web API key for the steam scrapers
  envs: [dev, test]
  accessors: [composer]
```

2. PR and merge. CI creates the empty secret in dev and test.
3. Add the value in each env, in the Secret Manager console or with `gcloud secrets versions add steam-api-key --project=<project> --data-file=-`. Developers can do dev; in test and prod a member of `secret_value_admins` does it.
4. Code reads `projects/<project>/secrets/steam-api-key/versions/latest`. Reading fails until a value exists, so add it before the DAG runs.

### Promote to prod

1. Add `prod` to the entry's `envs`. Promote a view together with, or after, the tables it reads.
2. Open a PR. The prod plan shows exactly that addition; dev and test show no changes.
3. Merge, check the prod plan in the plan-prod job, and approve hold-prod.
4. For a secret, add the prod value in Secret Manager.

### Rotate a secret value

1. Add a new version in the Secret Manager console or with `gcloud secrets versions add <id> --project=<project> --data-file=-`. Code reading `latest` picks it up the next time it reads the secret.
2. Once nothing uses the old value, disable it: `gcloud secrets versions disable <version> --secret=<id> --project=<project>`.

No PR is needed: values are not in Terraform.

### Give a person or service access

- **For every entry that names a role:** add the member to that role in `environments/principals.yaml`, under the environment (for example a new Composer service account under `test.composer`).
- **For one entry only:** add the literal member (`serviceAccount:...`, `group:...`, `user:...`) to that entry's `readers`, `writers` or `accessors`.
- **To remove access:** delete the member from either place. This removes only what Terraform granted; access granted by hand stays.

### Retire from an environment

1. Remove the env from `envs`, or delete the entry to retire it everywhere.
2. The plan shows a destroy. Check it before merging:
    - **Table in prod:** deletion protection blocks the apply until someone deliberately turns it off for that table.
    - **Bucket:** the apply fails while the bucket holds objects. Empty it first if the data can go.
    - **Secret:** the destroy deletes every version of the value, permanently. Make sure nothing still reads it.

### Adopt an existing bucket or secret

1. Add the entry. A bucket whose name doesn't follow `<project>-<key>` gets a `name` per environment, because bucket names are global: `name: {test: old-test-bucket, prod: old-bucket}`.
2. Add an `import` block in `environments/<env>/storage/imports.tf` or `environments/<env>/secrets/imports.tf`; both files contain an example.
3. Open a PR. The plan must show the import and no other change to that resource; adjust the entry (for example `versioning` or `location`) until it does.
4. Merge, then delete the import block. Importing a secret never touches its value.

### When a plan fails on a YAML mistake

The plan stops with `Fix storage/buckets.yaml: ...` (or the secrets file or the BigQuery catalog) and lists each problem: an unknown field such as `writer` for `writers`, an unknown env, a principal name missing from `environments/principals.yaml`, or a bucket key that breaks the naming rules. Fix those lines and push again.

## Rollout

We adopt this gradually: new scrapers use the new flow from day one, and existing tables are imported one ecosystem at a time.

1. **Foundation.** Create `newzoo-nexus-raw-dev`, the state buckets, the infra repo, and CI with Workload Identity Federation.
2. **Pilot one ecosystem.** Generate the catalog, schema files and `import` blocks for one dataset (for example `steam`) from what is deployed, with `scripts/bootstrap_catalog.py`. Iterate until `plan` shows no changes in test and prod.
3. **New scrapers.** From here on, every new scraper follows the lifecycle above.
4. **Remaining ecosystems.** Import `xbox`, `playstation` and the rest the same way. Any differences between test and prod surface during import and get recorded in the catalog.
5. **Buckets and secrets.** The `storage` and `secrets` stacks are scaffolded. Manage new buckets and secrets there once the BigQuery flow has settled, and import existing ones as they are touched.
6. **Close manual access.** Once everything above is in Terraform, remove developers' hand-granted admin roles in test and prod, keeping one break-glass admin per project. The repo marks every affected place with `TODO(close-manual-access)`; the steps are in `docs/setup.md`, step 8.
