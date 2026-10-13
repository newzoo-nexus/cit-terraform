#!/usr/bin/env python3
"""Generate the catalog, schemas, view templates and import blocks for an
existing dataset, from what is deployed in test and prod today.

    python scripts/bootstrap_catalog.py steam

Writes:
  bigquery/catalog/steam.yaml            tables and views, with `envs` set to
                                         where each one exists today
  bigquery/schemas/steam/<table>.json    prod schema if the table is in prod,
                                         else the test schema
  bigquery/views/steam/<view>.sql        view SQL with the project replaced
                                         by ${project}
  environments/{test,prod}/bigquery/imports_steam.tf
                                         import blocks for everything that exists

Where test and prod differ (schema, partitioning, clustering, view SQL), the
entry describes prod and `overrides: {test: ...}` holds what test has, with the test
schema or SQL in <name>.test.json / <name>.test.sql, so both plans show no
changes. Each is printed; settle them later (promote or drop the override).
Existing files are not overwritten unless --force.

This is a one-off helper for the rollout; after the import, the catalog is
edited by hand.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import yaml
from google.api_core.exceptions import NotFound
from google.cloud import bigquery

from catalog import CATALOG_DIR, PROJECTS, REPO_ROOT, SCHEMAS_DIR, VIEWS_DIR, templatize_view_sql

ENVS = ("test", "prod")


def describe(client: bigquery.Client, project: str, dataset: str) -> dict[str, bigquery.Table] | None:
    try:
        client.get_dataset(f"{project}.{dataset}")
    except NotFound:
        return None
    return {t.table_id: client.get_table(t.reference) for t in client.list_tables(f"{project}.{dataset}")}


def schema_json(table: bigquery.Table) -> list[dict]:
    return [f.to_api_repr() for f in table.schema]


def table_entry(dataset: str, table: bigquery.Table, envs: list[str]) -> dict:
    entry: dict = {"schema": f"{dataset}/{table.table_id}.json"}
    tp = table.time_partitioning
    if tp is not None:
        if tp.field:
            entry["partition_field"] = tp.field
            if tp.type_ and tp.type_ != "DAY":
                entry["partition_type"] = tp.type_
        else:
            # Ingestion-time partitioning: partition_type without partition_field.
            entry["partition_type"] = tp.type_ or "DAY"
        if tp.expiration_ms:
            days, rest = divmod(int(tp.expiration_ms), 86_400_000)
            if rest:
                print(f"  ! {table.table_id}: partition expiration {tp.expiration_ms} ms is not whole days; rounded")
            entry["partition_expiration_days"] = max(days, 1)
    if table.require_partition_filter:
        entry["require_partition_filter"] = True
    if table.clustering_fields:
        entry["clustering"] = list(table.clustering_fields)
    if table.description:
        entry["description"] = table.description
    entry["envs"] = envs
    return entry


def write(path: Path, content: str, force: bool) -> None:
    if path.exists() and not force:
        print(f"  skip {path.relative_to(REPO_ROOT)} (exists; --force to overwrite)")
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)
    print(f"  wrote {path.relative_to(REPO_ROOT)}")


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("dataset")
    p.add_argument("--force", action="store_true", help="overwrite existing files")
    args = p.parse_args()
    ds = args.dataset

    deployed: dict[str, dict[str, bigquery.Table]] = {}
    clients = {}
    for env in ENVS:
        clients[env] = bigquery.Client(project=PROJECTS[env])
        found = describe(clients[env], PROJECTS[env], ds)
        if found is None:
            print(f"  dataset {ds} not found in {PROJECTS[env]}")
        else:
            deployed[env] = found
    if not deployed:
        raise SystemExit(f"Dataset {ds} exists in neither test nor prod")

    names = sorted({n for objs in deployed.values() for n in objs})
    tables: dict = {}
    views: dict = {}
    imports: dict[str, list[tuple[str, str]]] = {env: [] for env in deployed}

    for env in deployed:
        imports[env].append(
            (f'module.bigquery.google_bigquery_dataset.dataset["{ds}"]', f"projects/{PROJECTS[env]}/datasets/{ds}")
        )

    for name in names:
        present = {env: deployed[env][name] for env in ENVS if env in deployed and name in deployed[env]}
        envs = list(present)
        source_env = "prod" if "prod" in present else "test"
        src = present[source_env]
        types = {t.table_type for t in present.values()}
        if len(types) > 1:
            print(f"  ! {name}: type differs between envs ({types}); skipped")
            continue

        if src.table_type == "VIEW":
            templates = {env: templatize_view_sql(t.view_query, PROJECTS[env]) for env, t in present.items()}
            write(VIEWS_DIR / ds / f"{name}.sql", templates[source_env].rstrip() + "\n", args.force)
            views[name] = {"sql": f"{ds}/{name}.sql", "envs": envs}
            if len(set(templates.values())) > 1:
                print(f"  ! {name}: view SQL differs between test and prod; overrides.test written")
                write(VIEWS_DIR / ds / f"{name}.test.sql", templates["test"].rstrip() + "\n", args.force)
                views[name]["overrides"] = {"test": {"sql": f"{ds}/{name}.test.sql"}}
            resource = "view"
        elif src.table_type == "TABLE":
            schemas = {env: schema_json(t) for env, t in present.items()}
            entries = {env: table_entry(ds, t, envs) for env, t in present.items()}
            write(SCHEMAS_DIR / ds / f"{name}.json", json.dumps(schemas[source_env], indent=2) + "\n", args.force)
            tables[name] = entries[source_env]
            override = {}
            if len({json.dumps(s, sort_keys=True) for s in schemas.values()}) > 1:
                write(SCHEMAS_DIR / ds / f"{name}.test.json", json.dumps(schemas["test"], indent=2) + "\n", args.force)
                override["schema"] = f"{ds}/{name}.test.json"
            if len(entries) > 1:
                prod_e, test_e = entries["prod"], entries["test"]
                for key in sorted((set(prod_e) | set(test_e)) - {"schema", "envs"}):
                    if prod_e.get(key) != test_e.get(key):
                        override[key] = test_e.get(key)  # None (null) removes the prod setting in test
            if override:
                print(f"  ! {name}: test differs from prod ({', '.join(override)}); overrides.test written")
                tables[name]["overrides"] = {"test": override}
            resource = "table"
        else:
            print(f"  ! {name}: {src.table_type} is not managed by the module; skipped")
            continue

        for env in envs:
            imports[env].append(
                (
                    f'module.bigquery.google_bigquery_table.{resource}["{ds}.{name}"]',
                    f"projects/{PROJECTS[env]}/datasets/{ds}/tables/{name}",
                )
            )

    catalog = {}
    if tables:
        catalog["tables"] = tables
    if views:
        catalog["views"] = views
    header = f"# Catalog for the {ds} dataset. Generated by scripts/bootstrap_catalog.py; edit by hand from here on.\n"
    write(CATALOG_DIR / f"{ds}.yaml", header + yaml.safe_dump(catalog, sort_keys=False, default_flow_style=None), args.force)

    for env, blocks in imports.items():
        body = "".join(f"\nimport {{\n  to = {to}\n  id = \"{id_}\"\n}}\n" for to, id_ in blocks)
        write(
            REPO_ROOT / "environments" / env / "bigquery" / f"imports_{ds}.tf",
            f"# Imports existing {ds} objects into Terraform state. Safe to delete once applied.\n{body}",
            args.force,
        )

    print(f"\nNext: cd environments/test/bigquery && terraform plan  (repeat for prod), iterate until both show no changes.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
