#!/usr/bin/env python3
"""Create catalog tables and views in the dev project, without Terraform.

    python scripts/dev_table.py steam.player_counts
    python scripts/dev_table.py steam.store_prices steam.store_prices_latest
    python scripts/dev_table.py steam.player_counts --recreate   # breaking schema change

Reads the same catalog entry and schema file Terraform uses, so the table
looks the same in dev, test and prod. The entry's `envs` list is ignored: it
only controls test and prod. An entry's `overrides` are applied (dev gets
what test gets, unless overrides.dev says otherwise). Tables and views expire after --expiration-days
(14 by default); rerunning the script pushes the expiry out again.

Without --recreate, an existing table gets its schema updated in place, which
BigQuery allows only for additive changes (new NULLABLE columns, relaxing
REQUIRED to NULLABLE). Anything else needs --recreate, which drops the data.

Dev datasets are created by Terraform (environments/dev/bigquery); this script never
creates datasets.
"""

from __future__ import annotations

import argparse
import datetime as dt
import sys

from google.api_core.exceptions import BadRequest, NotFound
from google.cloud import bigquery

from catalog import PROJECTS, SCHEMAS_DIR, VIEWS_DIR, effective, load_catalog, render_view_sql


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("objects", nargs="+", metavar="DATASET.NAME", help="catalog table or view, e.g. steam.player_counts")
    p.add_argument("--recreate", action="store_true", help="drop and recreate instead of updating in place")
    p.add_argument("--expiration-days", type=int, default=14, help="days until the object expires (default: 14)")
    p.add_argument("--project", default=PROJECTS["dev"], help=f"target project (default: {PROJECTS['dev']})")
    args = p.parse_args()
    if args.project in (PROJECTS["test"], PROJECTS["prod"]):
        p.error("test and prod are managed by Terraform only; this script is for dev")
    return args


def build_table(client: bigquery.Client, project: str, dataset: str, name: str, cfg: dict) -> bigquery.Table:
    table = bigquery.Table(f"{project}.{dataset}.{name}")
    table.schema = client.schema_from_json(str(SCHEMAS_DIR / cfg["schema"]))
    table.description = cfg.get("description")
    # partition_field: column partitioning; only partition_type: ingestion time.
    if cfg.get("partition_field") or cfg.get("partition_type"):
        days = cfg.get("partition_expiration_days")
        table.time_partitioning = bigquery.TimePartitioning(
            type_=cfg.get("partition_type", "DAY"),
            field=cfg.get("partition_field"),
            expiration_ms=days * 86_400_000 if days else None,
        )
    if cfg.get("require_partition_filter") is not None:
        table.require_partition_filter = cfg["require_partition_filter"]
    if cfg.get("clustering"):
        table.clustering_fields = cfg["clustering"]
    return table


def build_view(client: bigquery.Client, project: str, dataset: str, name: str, cfg: dict) -> bigquery.Table:
    view = bigquery.Table(f"{project}.{dataset}.{name}")
    view.view_query = render_view_sql((VIEWS_DIR / cfg["sql"]).read_text(), project)
    view.description = cfg.get("description")
    return view


def apply(client: bigquery.Client, obj: bigquery.Table, is_view: bool, recreate: bool) -> str:
    try:
        existing = client.get_table(obj.reference)
    except NotFound:
        client.create_table(obj)
        return "created"

    if recreate:
        client.delete_table(obj.reference)
        client.create_table(obj)
        return "recreated"

    existing.expires = obj.expires
    existing.description = obj.description
    fields = ["expires", "description"]
    if is_view:
        existing.view_query = obj.view_query
        fields.append("view_query")
    else:
        if existing.time_partitioning != obj.time_partitioning or existing.clustering_fields != obj.clustering_fields:
            print("    partitioning/clustering differ from the catalog; rerun with --recreate to apply them")
        existing.schema = obj.schema
        fields.append("schema")
    try:
        client.update_table(existing, fields)
    except BadRequest as e:
        raise SystemExit(f"    update failed ({e.message}); rerun with --recreate for breaking changes")
    return "updated"


def main() -> int:
    args = parse_args()
    expires = dt.datetime.now(dt.timezone.utc) + dt.timedelta(days=args.expiration_days)

    # Tables before views, since BigQuery validates a view's query at creation.
    resolved = []
    for ref in args.objects:
        dataset, _, name = ref.partition(".")
        if not name:
            raise SystemExit(f"'{ref}' should be DATASET.NAME")
        cat = load_catalog(dataset)
        if name in cat["tables"]:
            resolved.append((False, dataset, name, effective(cat["tables"][name], "dev")))
        elif name in cat["views"]:
            resolved.append((True, dataset, name, effective(cat["views"][name], "dev")))
        else:
            raise SystemExit(f"'{name}' is not a table or view in bigquery/catalog/{dataset}.yaml")
    resolved.sort(key=lambda r: r[0])

    client = bigquery.Client(project=args.project)

    for is_view, dataset, name, cfg in resolved:
        build = build_view if is_view else build_table
        obj = build(client, args.project, dataset, name, cfg)
        obj.expires = expires
        try:
            client.get_dataset(f"{args.project}.{dataset}")
        except NotFound:
            raise SystemExit(
                f"Dataset {args.project}.{dataset} does not exist. Datasets are created by Terraform "
                f"(environments/dev/bigquery) once bigquery/catalog/{dataset}.yaml is merged."
            )
        result = apply(client, obj, is_view, args.recreate)
        kind = "view" if is_view else "table"
        print(f"{result} {kind} {args.project}.{dataset}.{name} (expires {expires:%Y-%m-%d})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
