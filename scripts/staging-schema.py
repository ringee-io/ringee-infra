#!/usr/bin/env python3
"""Give staging's empty `ringee` database production's schema, without data.

  AWS_PROFILE=ringee-staging scripts/staging-schema.py --expect-account 699340623836

An interim step until the migrations are in git (AWS-09): it copies the tables,
indexes (including the ones applied by hand that `prisma db push` would miss)
and the rows of `_prisma_migrations`, so `prisma migrate deploy` can take over
later. No customer row is copied.

1. Reads DATABASE_PUBLIC_URL of Railway's `Postgres` service, in memory only.
2. pg_dump 17 --schema-only (plus _prisma_migrations' rows) into
   staging-schema.sql on this machine. Production's password goes to pg_dump
   through the environment, never on argv, and never leaves this machine.
3. Uploads the file to the staging ops bucket and loads it with the ops task, as
   the ringee_app role, in one transaction. It refuses a database that already
   has tables.
"""

import argparse
import importlib.util
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import unquote, urlparse

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "staging-schema.sql"
PG_DUMP = os.environ.get("PG_DUMP", "/opt/homebrew/opt/postgresql@17/bin/pg_dump")
# Monitoring extensions the app does not use. On RDS they need rds_superuser
# (the load runs as ringee_app) or a preload parameter, so their lines are
# dropped; trusted ones (pgcrypto, uuid-ossp, pg_trgm...) load as they are.
SKIPPED_EXTENSIONS = {"pgaudit", "pg_stat_statements"}


def railway_env():
    spec = importlib.util.spec_from_file_location("railway_env", ROOT / "scripts" / "railway-env.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def production_database_url(module) -> str:
    listing = subprocess.run(["railway", "list", "--json"], capture_output=True, text=True)
    if listing.returncode != 0:
        sys.exit("railway list failed: run `railway login` first")
    project_id = next(p["id"] for p in json.loads(listing.stdout) if p["name"] == module.RAILWAY_PROJECT)
    token = module.railway_token()
    project = module.graphql(
        token,
        "query($id:String!){project(id:$id){environments{edges{node{id name}}} services{edges{node{id name}}}}}",
        {"id": project_id},
    )["project"]
    environment_id = next(
        e["node"]["id"] for e in project["environments"]["edges"] if e["node"]["name"] == module.RAILWAY_ENVIRONMENT
    )
    service_id = next(s["node"]["id"] for s in project["services"]["edges"] if s["node"]["name"] == "Postgres")
    variables = module.graphql(
        token,
        "query($p:String!,$e:String!,$s:String!){variables(projectId:$p,environmentId:$e,serviceId:$s)}",
        {"p": project_id, "e": environment_id, "s": service_id},
    )["variables"]
    url = variables.get("DATABASE_PUBLIC_URL")
    if not url:
        sys.exit("Railway's Postgres has no DATABASE_PUBLIC_URL (no public TCP proxy)")
    return url


def pg_dump(url: str, *args: str) -> str:
    parsed = urlparse(url)
    env = {**os.environ, "PGPASSWORD": unquote(parsed.password or ""), "PGSSLMODE": "require"}
    command = [
        PG_DUMP, "--no-owner", "--no-privileges",
        "--host", parsed.hostname, "--port", str(parsed.port or 5432),
        "--username", unquote(parsed.username or ""), "--dbname", parsed.path.lstrip("/"),
        *args,
    ]
    proc = subprocess.run(command, env=env, capture_output=True, text=True)
    if proc.returncode != 0:
        sys.exit("pg_dump failed: " + proc.stderr.strip().splitlines()[-1])
    return proc.stdout


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--expect-account", required=True, help="the ringee-staging account id")
    args = parser.parse_args()

    module = railway_env()
    account = json.loads(module.aws(["sts", "get-caller-identity", "--output", "json"]))["Account"]
    if account != args.expect_account:
        sys.exit(f"Refusing: the AWS session is account {account}, not {args.expect_account}")
    version = subprocess.run([PG_DUMP, "--version"], capture_output=True, text=True).stdout.strip()
    if not re.search(r"\b1[7-9]\.", version):
        sys.exit(f"pg_dump 17 or newer is needed, found: {version or PG_DUMP}")

    url = production_database_url(module)
    schema = pg_dump(url, "--schema-only")
    migrations = pg_dump(url, "--data-only", "--table=public._prisma_migrations")

    kept, dropped = [], []
    for line in schema.splitlines():
        # Comments on extensions need their owner; they are cosmetic.
        if line.startswith("COMMENT ON EXTENSION"):
            continue
        extension = re.match(r'^CREATE EXTENSION IF NOT EXISTS "?([a-z_]+)"?', line)
        if extension and extension.group(1) in SKIPPED_EXTENSIONS:
            dropped.append(extension.group(1))
            continue
        kept.append(line)
    OUT.write_text("\n".join(kept) + "\n" + migrations)
    OUT.chmod(0o600)
    tables = len(re.findall(r"^CREATE TABLE ", schema, flags=re.M))
    indexes = len(re.findall(r"^CREATE (?:UNIQUE )?INDEX ", schema, flags=re.M))
    applied = len(re.findall(r"^[0-9a-f-]{36}\t", migrations, flags=re.M))
    extensions = sorted(set(re.findall(r'^CREATE EXTENSION IF NOT EXISTS "?([a-z_]+)"?', schema, flags=re.M)))
    print(f"{OUT.name}: {tables} tables, {indexes} indexes, {applied} applied migrations, no data")
    print("extensions: " + (" ".join(extensions) or "none") + (f" (dropped: {' '.join(sorted(set(dropped)))})" if dropped else ""))

    outputs = json.loads(subprocess.run(
        ["terraform", f"-chdir={ROOT / 'envs' / 'staging'}", "output", "-json", "stack"],
        capture_output=True, text=True, check=True,
    ).stdout)
    key = "schema/production-schema-" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + ".sql"
    module.aws(["s3", "cp", str(OUT), f"s3://{outputs['ops_bucket']}/{key}", "--only-show-errors"])
    print(f"uploaded to s3://{outputs['ops_bucket']}/{key}")

    load = (
        "set -eu; apk add --no-cache aws-cli >/dev/null; "
        "tables=$(psql \"$PG_URL_APP\" -tAc \"select count(*) from pg_tables where schemaname = 'public'\"); "
        "if [ \"$tables\" != 0 ]; then echo \"ringee already has $tables tables; not loading over them\"; exit 3; fi; "
        f"aws s3 cp \"s3://$OPS_BUCKET/{key}\" - | psql -v ON_ERROR_STOP=1 --single-transaction --quiet \"$PG_URL_APP\"; "
        "echo \"loaded: $(psql \"$PG_URL_APP\" -tAc \"select count(*) from pg_tables where schemaname = 'public'\") tables\""
    )
    result = subprocess.run([str(ROOT / "scripts" / "run-task.sh"), "staging", "ops", "--", "sh", "-c", load])
    sys.exit(result.returncode)


if __name__ == "__main__":
    main()
