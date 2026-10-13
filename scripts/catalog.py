"""Shared helpers for reading the catalog, schemas and view templates."""

from __future__ import annotations

import re
from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
BIGQUERY_DIR = REPO_ROOT / "bigquery"
CATALOG_DIR = BIGQUERY_DIR / "catalog"
SCHEMAS_DIR = BIGQUERY_DIR / "schemas"
VIEWS_DIR = BIGQUERY_DIR / "views"

PROJECTS = {
    "dev": "newzoo-nexus-raw-dev",
    "test": "newzoo-nexus-raw-test",
    "prod": "newzoo-nexus-raw",
}


# Pipeline order. An entry's `overrides.<env>` applies to that env and the ones
# before it (so dev gets what test gets); the closest env wins. Prod is the
# entry itself and is never overridden. Same rule as modules/bq_tables.
ENVS = ("dev", "test", "prod")


def effective(cfg: dict, env: str) -> dict:
    """A catalog entry as `env` sees it, with its overrides applied."""
    overrides = cfg.get("overrides") or {}
    result = dict(cfg)
    for e in reversed(ENVS[ENVS.index(env):]):
        if e != "prod":
            result.update(overrides.get(e) or {})
    return result


def load_catalog(dataset: str) -> dict:
    path = CATALOG_DIR / f"{dataset}.yaml"
    if not path.exists():
        raise SystemExit(f"No catalog file for dataset '{dataset}' ({path.relative_to(REPO_ROOT)})")
    data = yaml.safe_load(path.read_text()) or {}
    data.setdefault("tables", {})
    data.setdefault("views", {})
    data["tables"] = data["tables"] or {}
    data["views"] = data["views"] or {}
    return data


_TEMPLATE_VAR = re.compile(r"(?<!\$)\$\{(\w+)\}")


def render_view_sql(template: str, project: str) -> str:
    """Render a view template the same way Terraform's templatefile() does.

    ${project} is replaced; "$${" is an escaped literal "${". Any other
    ${...} variable is an error, as it would be in Terraform.
    """
    unknown = {m.group(1) for m in _TEMPLATE_VAR.finditer(template)} - {"project"}
    if unknown:
        raise SystemExit(f"View template uses unknown variables: {', '.join(sorted(unknown))}")
    stray = re.sub(r"\$\$\{", "", _TEMPLATE_VAR.sub("", template))
    if "${" in stray:
        raise SystemExit("View template has a '${' that is not ${project}; write a literal one as '$${'")
    rendered = _TEMPLATE_VAR.sub(project, template)
    return rendered.replace("$${", "${")


def templatize_view_sql(sql: str, project: str) -> str:
    """Inverse of render_view_sql: turn a deployed view's SQL into a template."""
    sql = sql.replace("${", "$${")
    return re.sub(rf"(?<![\w-]){re.escape(project)}\.", "${project}.", sql)
