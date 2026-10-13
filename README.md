# CIT Terraform

Terraform for the GCP resources our scrapers use: BigQuery datasets, tables
and views, GCS buckets, and Secret Manager secrets.
The design and the reasons behind it are in
[docs/terraform-bigquery-workflow.md](docs/terraform-bigquery-workflow.md).
In short:

- **Environments are folders, not branches.** `environments/dev`, `test` and
  `prod` each have their own configs and state; everything lives on `main`.
- **Each environment is split into stacks** (`bigquery`, `storage`,
  `secrets`), each with its own state, so a change to one cannot touch
  another.
- **Shared YAML files list every table, view, bucket and secret** and which
  environments each exists in. Promoting anything to prod is a one-line PR.
- **Local development needs no Terraform and no PR.** `scripts/dev_table.py`
  creates tables in `newzoo-nexus-raw-dev` straight from the catalog.
- **Scrapers only switch project.** Dataset names are the same everywhere.

| Environment | Project | Tables created by |
| --- | --- | --- |
| dev | `newzoo-nexus-raw-dev` | `scripts/dev_table.py`, freely (expire after 14 days) |
| test | `newzoo-nexus-raw-test` | Terraform, on merge to `main` |
| prod | `newzoo-nexus-raw` | Terraform, on merge to `main` after approval |

## Layout

```
bigquery/                     WHAT exists: tables and views
├ catalog/<dataset>.yaml      tables and views per dataset (ecosystem), with their envs
├ schemas/<dataset>/<t>.json  JSON schemas (bq show --schema --format=prettyjson)
└ views/<dataset>/<v>.sql     view SQL templates; ${project} is filled in per env
storage/buckets.yaml          WHAT exists: GCS buckets, with their envs
secrets/secrets.yaml          WHAT exists: Secret Manager secrets, with their envs (no values)
environments/principals.yaml  WHO is who per env (developers, composer, ...)
modules/bq_tables/            datasets, tables, views and dataset IAM from the catalog
modules/gcs_buckets/          buckets, lifecycle rules and bucket IAM
modules/secrets/              secrets and who can read them (never their values)
environments/<env>/<stack>/   HOW: one root config + state per env and stack; rarely edited
scripts/dev_table.py          create/update a table or view in dev, no Terraform
scripts/bootstrap_catalog.py  one-off: generate catalog + imports for an existing dataset
.circleci/                    CircleCI: plan on branches, apply on main (prod after approval)
docs/                         the plan and one-time setup
```

`bigquery/catalog/_example.yaml` (and the matching `_example` schema and
view) show the format. Files starting with `_` are ignored by Terraform.

## Adding a table for a new scraper

1. On a branch, add `bigquery/schemas/steam/player_counts.json` and an entry
   in `bigquery/catalog/steam.yaml` with `envs: [test]`.
2. Create it in dev and build the scraper against `newzoo-nexus-raw-dev`:
   ```bash
   python scripts/dev_table.py steam.player_counts
   python scripts/dev_table.py steam.player_counts --recreate   # after a breaking schema change
   ```
3. Open the PR. CI comments the plan for each env: test shows one new table,
   prod shows no changes. Merging applies test.
4. Run the DAG on test as today. When it is ready, a second PR changes `envs`
   to `[test, prod]`; after approval CI applies prod.

To change a table or view that is already in prod, add a temporary
`overrides.test` to its entry (e.g. pointing at `player_counts.test.json`):
test and dev get the change, prod keeps the entry. A second PR moves it into
the entry to promote it. See the SOP "Change an existing table or view".

Views work the same way (`python scripts/dev_table.py steam.store_prices_latest`);
promote a view together with, or after, the tables it reads.

## Stacks

An environment is split into stacks, one folder each:

```
environments/
  dev/   bigquery/  storage/  secrets/
  test/  bigquery/  storage/  secrets/
  prod/  bigquery/  storage/  secrets/
```

Each stack is its own Terraform root with its own state, in the project's
state bucket under a prefix named after the stack (`bigquery`, ...). That
keeps plans small and limits what a bad PR can touch.

To add another stack (say `pubsub`):

1. Write the reusable part as `modules/<name>/`.
2. Add `environments/{dev,test,prod}/pubsub/` with `backend.tf` (same bucket,
   `prefix = "pubsub"`), `versions.tf` and a `main.tf` calling the module.
3. Give the Terraform service accounts the roles it needs (docs/setup.md).

CI plans and applies every folder under `environments/<env>/`, so the new
folders are picked up without touching `.circleci/config.yml`.

Stacks don't read each other's state; refer to resources by name (names are
the same pattern in every environment).

How the folders relate: the YAML files are the data (what should exist),
`modules/` is the code that turns it into resources (written once, so a module
change hits every environment), and each `environments/<env>/<stack>/` folder
runs that code for one environment and keeps its state. Per-environment
differences are the arguments in those `main.tf` files; see "How the folders
fit together" in the plan.

## Buckets and secrets

They work like tables: one shared file each, every entry listing the `envs`
it exists in, so promoting to prod is adding `prod` to that list.

```yaml
# storage/buckets.yaml -> bucket <project>-raw-dumps in each env listed
raw-dumps:
  envs: [dev, test]          # promote: [dev, test, prod]
  writers: [composer]        # names from environments/principals.yaml
  delete_after_days: 90

# secrets/secrets.yaml -> secret steam-api-key in each env listed
steam-api-key:
  description: Steam Web API key for the steam scrapers
  envs: [dev, test]
  accessors: [composer]      # who may read the value
```

`composer`, `developers` and `secret_value_admins` are defined per
environment in `environments/principals.yaml`, so one entry gives Airflow
access in test with the test service account and in prod with the prod one.
Terraform creates secrets and their access, never their values; add those in
Secret Manager (the console or `gcloud secrets versions add`) once the secret
is applied.

What every bucket gets: uniform access, public access prevention, no deletion
while it holds objects, a 14-day object expiry in dev unless it sets its own
`delete_after_days`. Typos (an unknown field, env or principal name) fail the
plan instead of being ignored.

Step-by-step procedures (new bucket, new secret, rotate a value, give access,
retire, adopt an existing one) are the SOPs in
[docs/terraform-bigquery-workflow.md](docs/terraform-bigquery-workflow.md).

## Local setup

```bash
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
gcloud auth application-default login
```

You only need Terraform locally to run `terraform fmt`/`validate` or to plan
during an import; applies to test and prod happen in CI only. The version is
pinned in `.terraform-version` (works with tfenv).

## Open items

- [ ] Confirm the BigQuery location of the existing datasets and set
      `location` in `environments/*/bigquery/variables.tf` (defaults to `EU`).
- [ ] Fill in `environments/principals.yaml`: the team's Google group, the
      Composer service account per project, and who may add secret values.
- [ ] Scrapers pick their project in `scraper-utils` via
      `bigquery_client_factory` (`production` → `newzoo-nexus-raw`, anything
      else → `newzoo-nexus-raw-test`). Developing against dev needs a third
      option there, e.g. an environment value or `GCP_PROJECT` override.
- [ ] Later: close developers' manual admin access to test and prod, once the
      migration is done (`docs/setup.md`, step 8; search the repo for
      `TODO(close-manual-access)`).
- [ ] Set up CircleCI for this repo: contexts, `WIF_PROVIDER`, the prod
      approvers' security group (`docs/setup.md`, steps 4 and 5).
