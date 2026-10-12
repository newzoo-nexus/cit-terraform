# One-time setup

Rollout step 1 ("Foundation") from the plan. Everything here is done once, by
hand, by someone with project-level admin rights. Replace the `<...>`
placeholders first.

```bash
CIRCLECI_ORG_ID="<org-uuid>"        # CircleCI: Organization Settings > Overview
CIRCLECI_PROJECT_ID="<project-uuid>" # CircleCI: Project Settings > Overview (new-terra)
WIF_PROJECT="newzoo-nexus-raw"       # project that hosts the identity pool
LOCATION="EU"                        # match the existing BigQuery datasets
```

## 1. Dev project

```bash
gcloud projects create newzoo-nexus-raw-dev --folder=<folder-id>   # or --organization=<org-id>
gcloud billing projects link newzoo-nexus-raw-dev --billing-account=<billing-account-id>
gcloud services enable bigquery.googleapis.com --project=newzoo-nexus-raw-dev
```

Secret Manager must be enabled in every project before the `secrets` stack's
first apply (Terraform does not enable APIs, so its service account needs no
Service Usage rights):

```bash
for P in newzoo-nexus-raw-dev newzoo-nexus-raw-test newzoo-nexus-raw; do
  gcloud services enable secretmanager.googleapis.com storage.googleapis.com --project="$P"
done
```

## 2. State buckets

One per project, versioned, never public.

```bash
for P in newzoo-nexus-raw-dev newzoo-nexus-raw-test newzoo-nexus-raw; do
  gcloud storage buckets create "gs://${P}-tfstate" --project="$P" --location="$LOCATION" \
    --uniform-bucket-level-access --public-access-prevention
  gcloud storage buckets update "gs://${P}-tfstate" --versioning
done
```

## 3. Terraform service accounts

One admin account per project, so the test pipeline cannot touch prod. It runs
every stack in its project, so it gets the admin role for each.

```bash
for P in newzoo-nexus-raw-dev newzoo-nexus-raw-test newzoo-nexus-raw; do
  gcloud iam service-accounts create terraform --project="$P" --display-name="Terraform (CI)"
  SA="terraform@${P}.iam.gserviceaccount.com"
  # Datasets, tables, views and dataset IAM.
  gcloud projects add-iam-policy-binding "$P" --member="serviceAccount:$SA" --role=roles/bigquery.admin
  # Buckets and bucket IAM (storage stack).
  gcloud projects add-iam-policy-binding "$P" --member="serviceAccount:$SA" --role=roles/storage.admin
  # Secrets and secret IAM (secrets stack). Never reads values: no secretAccessor.
  gcloud projects add-iam-policy-binding "$P" --member="serviceAccount:$SA" --role=roles/secretmanager.admin
  # State.
  gcloud storage buckets add-iam-policy-binding "gs://${P}-tfstate" \
    --member="serviceAccount:$SA" --role=roles/storage.objectAdmin
done
```

Prod also gets a read-only account for plans, so that PR builds from any
branch can plan prod without being able to change it:

```bash
P=newzoo-nexus-raw
gcloud iam service-accounts create terraform-plan --project="$P" --display-name="Terraform plans (CI, read-only)"
SA="terraform-plan@${P}.iam.gserviceaccount.com"
gcloud projects add-iam-policy-binding "$P" --member="serviceAccount:$SA" --role=roles/viewer
# Read IAM policies on datasets, buckets and secrets (to plan their access).
gcloud projects add-iam-policy-binding "$P" --member="serviceAccount:$SA" --role=roles/iam.securityReviewer
# Read the state (plans run with -lock=false, so no write needed).
gcloud storage buckets add-iam-policy-binding "gs://${P}-tfstate" \
  --member="serviceAccount:$SA" --role=roles/storage.objectViewer
```

## 4. Workload Identity Federation for CircleCI

No service account keys are stored anywhere. Every CircleCI job that uses a
context gets an OIDC token from CircleCI; Google exchanges it for short-lived
credentials of a service account, if the rules below allow it
(`.circleci/bin/gcp-auth.sh` does the exchange).

```bash
gcloud services enable iamcredentials.googleapis.com sts.googleapis.com --project="$WIF_PROJECT"

gcloud iam workload-identity-pools create circleci \
  --project="$WIF_PROJECT" --location=global --display-name="CircleCI"

# Only tokens from the new-terra CircleCI project are accepted at all.
# attribute.project_ref = "<project id>:<git ref>" lets prod require main.
gcloud iam workload-identity-pools providers create-oidc new-terra \
  --project="$WIF_PROJECT" --location=global --workload-identity-pool=circleci \
  --issuer-uri="https://oidc.circleci.com/org/${CIRCLECI_ORG_ID}" \
  --allowed-audiences="${CIRCLECI_ORG_ID}" \
  --attribute-mapping="google.subject=assertion.sub,attribute.project=assertion['oidc.circleci.com/project-id'],attribute.project_ref=assertion['oidc.circleci.com/project-id'] + ':' + assertion['oidc.circleci.com/vcs-ref']" \
  --attribute-condition="assertion['oidc.circleci.com/project-id'] == '${CIRCLECI_PROJECT_ID}'"

WIF_NUMBER=$(gcloud projects describe "$WIF_PROJECT" --format='value(projectNumber)')
POOL="principalSet://iam.googleapis.com/projects/${WIF_NUMBER}/locations/global/workloadIdentityPools/circleci"

# dev, test and the read-only prod plan account: any branch of this project.
for SA in terraform@newzoo-nexus-raw-dev.iam.gserviceaccount.com \
          terraform@newzoo-nexus-raw-test.iam.gserviceaccount.com \
          terraform-plan@newzoo-nexus-raw.iam.gserviceaccount.com; do
  gcloud iam service-accounts add-iam-policy-binding "$SA" --role=roles/iam.workloadIdentityUser \
    --member="${POOL}/attribute.project/${CIRCLECI_PROJECT_ID}"
done

# The prod admin account: only builds of main. A branch that edits
# .circleci/config.yml to apply prod gets a token for its own ref and is refused.
gcloud iam service-accounts add-iam-policy-binding terraform@newzoo-nexus-raw.iam.gserviceaccount.com \
  --role=roles/iam.workloadIdentityUser \
  --member="${POOL}/attribute.project_ref/${CIRCLECI_PROJECT_ID}:refs/heads/main"

echo "WIF_PROVIDER=projects/${WIF_NUMBER}/locations/global/workloadIdentityPools/circleci/providers/new-terra"
```

Check the claims on the first run: the setup relies on CircleCI's v2 OIDC token
(`$CIRCLE_OIDC_TOKEN_V2`) carrying `oidc.circleci.com/project-id` and
`oidc.circleci.com/vcs-ref` (e.g. `refs/heads/main`). If authentication fails,
print the token's claims in a job with
`echo "$CIRCLE_OIDC_TOKEN_V2" | cut -d. -f2 | base64 -d 2>/dev/null; echo`
and adjust the attribute mapping to match.

## 5. CircleCI and GitHub settings

**Project** (Project Settings → Environment Variables):

- `WIF_PROVIDER`: printed above.
- `GITHUB_TOKEN` (optional): a fine-grained GitHub token with "Pull requests:
  write" on this repo, so plans are posted on PRs. Without it, plans are in the
  job log and its artifacts.

**Contexts** (Organization Settings → Contexts), each with one variable,
`TF_SA`:

| Context | `TF_SA` | Restrict to |
| --- | --- | --- |
| `new-terra-dev` | `terraform@newzoo-nexus-raw-dev.iam.gserviceaccount.com` | – |
| `new-terra-test` | `terraform@newzoo-nexus-raw-test.iam.gserviceaccount.com` | – |
| `new-terra-prod-plan` | `terraform-plan@newzoo-nexus-raw.iam.gserviceaccount.com` | – |
| `new-terra-prod` | `terraform@newzoo-nexus-raw.iam.gserviceaccount.com` | the prod approvers' security group (a GitHub team) |

Restricting `new-terra-prod` means `apply-prod` only runs when someone in that
group approved `hold-prod`; anyone else's approval makes the job fail
unauthorized. Together with the main-only WIF rule above, the prod admin
account can only be used from main, after an approval by that group.

**GitHub** branch protection on `main`: require PRs, a review, and the
CircleCI checks `check`, `plan-dev`, `plan-test` and `plan-prod`.

## 6. Who is who: `environments/principals.yaml`

Every stack reads `environments/principals.yaml`, which says per environment
who "developers", "composer" and "secret_value_admins" are. Fill it in once:

```yaml
test:
  developers: ["group:<data-team>@newzoo.com"]
  composer: ["serviceAccount:<composer-sa>@newzoo-nexus-raw-test.iam.gserviceaccount.com"]
  secret_value_admins: ["group:<data-team-leads>@newzoo.com"]
```

It holds only IAM member names, no secrets, so it is committed. Empty lists
grant nothing.

What Terraform grants developers:

| Stack | dev | test, prod |
| --- | --- | --- |
| bigquery | `bigquery.dataEditor` on every dataset | `bigquery.dataViewer` |
| storage | `storage.objectUser` on every bucket | `storage.objectViewer` |
| secrets | `secretmanager.secretAccessor` + add values | `secretmanager.viewer` (metadata only) |

For now, developers also keep the admin access to test and prod they already
have; closing it is step 8.

To run `dev_table.py`, developers also need `roles/bigquery.jobUser` on the
dev project:

```bash
gcloud projects add-iam-policy-binding newzoo-nexus-raw-dev \
  --member="group:<data-team>@newzoo.com" --role=roles/bigquery.jobUser
```

## 7. First apply of dev

Dev has no existing tables, buckets or secrets, so it needs no imports. Once
a catalog file is merged, CI creates its dataset in dev; buckets and secrets
appear in dev once they are merged with `dev` in their `envs`.

## 8. Later: close manual access

During the migration, developers keep the admin access to test and prod they
were given by hand, so they can still fix things directly while tables,
buckets and secrets move over gradually. Terraform never removes that access:
every grant it makes only adds.

Two consequences while this lasts:

- A manual change to something Terraform manages shows up as drift in the
  next plan, and the next apply puts it back. Change managed resources through
  a PR; use manual access for what is not in Terraform yet.
- The read-only developer roles in the test and prod stacks are not what
  limits anyone yet.

Once every ecosystem is imported (the plan's rollout step 4) and new buckets
and secrets go through the stacks, close the manual access. Search the repo for
`TODO(close-manual-access)` to find every place this applies, then:

```bash
# See who has which project-level roles today.
for P in newzoo-nexus-raw-test newzoo-nexus-raw; do
  gcloud projects get-iam-policy "$P" --format=json \
    | jq -r '.bindings[] | .role as $r | .members[] | "\($r)\t\(.)"' | sort
done

# Remove the broad roles from people and groups (keep service accounts,
# including terraform@ and Composer), e.g.:
gcloud projects remove-iam-policy-binding newzoo-nexus-raw-test \
  --member="group:<data-team>@newzoo.com" --role=roles/bigquery.admin
```

Developers are then left with what the stacks grant: read access to
datasets, buckets and secret metadata in test and prod, and full access in
dev. Keep one break-glass admin (a named person or a small group) per project
for emergencies.
