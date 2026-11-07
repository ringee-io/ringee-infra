#!/usr/bin/env python3
"""Copy production's database from Railway to RDS: the cutover (plan §10, steps
8 and 9) and its rehearsal (AWS-24).

  AWS_PROFILE=ringee-prod scripts/prod-data.py copy --mode rehearsal --expect-account 405762675020
  AWS_PROFILE=ringee-prod scripts/prod-data.py wipe --expect-account 405762675020 --confirm ringee-prod
  AWS_PROFILE=ringee-prod scripts/prod-data.py copy --mode cutover --expect-account 405762675020

Every step runs as the ops task in AWS (scripts/data/*.sh): pg_dump runs there,
no customer data crosses this machine, and the dump stays in the ops bucket
(encrypted, deleted after 30 days) as the rollback point.

  dump     Railway -> s3://<ops bucket>/cutover/<mode>-<UTC time>.dump, with the
           source's stats right before and right after it. Railway's URL goes to
           Secrets Manager for the task and is overwritten as soon as it ends.
           In cutover mode it fails if another session is connected to Railway's
           database or if the source changed during the dump.
  restore  The dump -> RDS's `ringee` database, as ringee_app. Never over tables.
  verify   RDS against the stats taken around the dump.
  copy     dump + restore + verify, timed. Checks the target first. In rehearsal
           mode it then wipes RDS (unless --keep): a copy of real data must not
           sit next to production's credentials while Railway is still live,
           where starting a service would dial the same leads twice.
  wipe     Empties RDS's `ringee` database after a rehearsal.

restore, copy and wipe refuse while api or orchestrator run on this stack, and
once api.ringee.io points at it. Railway is only read: one variable and pg_dump.
"""

import argparse
import importlib.util
import json
import os
import shlex
import socket
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "scripts" / "data"
ENV = "prod"
PROD_HOST = "api.ringee.io"
# What the source secret holds outside a dump. Written twice after each dump,
# so neither AWSCURRENT nor AWSPREVIOUS keeps Railway's URL.
PLACEHOLDER = "none: scripts/prod-data.py fills this only while it dumps"
# ECS rejects container overrides above 8192 characters.
MAX_COMMAND = 7800


def sibling(name: str, file: str):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


railway = sibling("railway_env", "railway-env.py")
schema = sibling("staging_schema", "staging-schema.py")
aws = railway.aws


def stack_outputs() -> dict:
    proc = subprocess.run(
        ["terraform", f"-chdir={ROOT / 'envs' / ENV}", "output", "-json", "stack"],
        capture_output=True, text=True,
    )
    if proc.returncode != 0:
        sys.exit("terraform output failed: " + proc.stderr.strip())
    outputs = json.loads(proc.stdout)
    if "cutover_source_secret" not in outputs:
        sys.exit("envs/prod has no cutover_source_secret output yet: terraform apply first")
    return outputs


def check_account(expected: str) -> None:
    account = json.loads(aws(["sts", "get-caller-identity", "--output", "json"]))["Account"]
    if account != expected:
        sys.exit(f"Refusing: the AWS session is account {account}, not {expected}")


def running_services(outputs: dict) -> list[str]:
    data = json.loads(aws([
        "ecs", "describe-services", "--cluster", outputs["cluster_name"],
        "--services", "api", "orchestrator", "--output", "json",
    ]))
    return [s["serviceName"] for s in data["services"] if s["desiredCount"] or s["runningCount"]]


def points_here(outputs: dict) -> bool:
    """True once api.ringee.io resolves to this stack's load balancer."""
    alb = outputs["alb_dns_name"].lower().rstrip(".")
    try:
        canonical, _, prod_ips = socket.gethostbyname_ex(PROD_HOST)
        _, _, alb_ips = socket.gethostbyname_ex(alb)
    except OSError as error:
        sys.exit(f"Refusing: can't resolve {PROD_HOST} or the load balancer ({error})")
    return canonical.lower().rstrip(".") == alb or bool(set(prod_ips) & set(alb_ips))


def guard_target(outputs: dict, action: str, dns_switched_early: bool = False) -> None:
    busy = running_services(outputs)
    if busy:
        sys.exit(f"Refusing to {action}: {', '.join(busy)} run on ringee-{ENV}. On cutover night they start "
                 "after the copy (plan §10 step 10).")
    if points_here(outputs):
        if not dns_switched_early:
            sys.exit(f"Refusing to {action}: {PROD_HOST} already points at this stack, so RDS is production now.")
        # The DNS moved before the copy: with api and orchestrator at 0 nothing
        # can have written to RDS, and dump.sh/restore.sh still refuse a target
        # that has tables.
        print(f"{action}: {PROD_HOST} already points at this stack (--dns-switched-early); going ahead because "
              "api and orchestrator are at 0 and the task refuses an RDS that has tables.", flush=True)


def run_step(outputs: dict, step: str, key: str, mode: str, timeout_minutes: int, **flags: str) -> bool:
    settings = {"KEY": key, "MODE": mode, "SOURCE_SECRET": outputs["cutover_source_secret"], **flags}
    script = "".join(f"{name}={shlex.quote(value)}\n" for name, value in settings.items())
    script += (DATA / "common.sh").read_text() + (DATA / f"{step}.sh").read_text()
    if len(json.dumps(script)) > MAX_COMMAND:
        sys.exit(f"{step}: the command is too long for an ECS override ({len(json.dumps(script))} characters)")
    print(f"=== {step} ({key})", flush=True)
    started = time.monotonic()
    proc = subprocess.run(
        [str(ROOT / "scripts" / "run-task.sh"), ENV, "ops", "--", "sh", "-c", script],
        env={**os.environ, "RUN_TASK_TIMEOUT_MINUTES": str(timeout_minutes)},
    )
    elapsed = time.monotonic() - started
    print(f"=== {step}: {'OK' if proc.returncode == 0 else 'FAILED'} after {elapsed:.0f} s, task start included",
          flush=True)
    return proc.returncode == 0


def dump(outputs: dict, mode: str, allow_sessions: bool, empty_target: bool) -> str:
    key = f"cutover/{mode}-{datetime.now(timezone.utc):%Y%m%dT%H%M%SZ}"
    secret = outputs["cutover_source_secret"]
    url = schema.production_database_url(railway)
    aws(["secretsmanager", "put-secret-value", "--secret-id", secret, "--secret-string", "file:///dev/stdin"],
        stdin=url)
    del url
    try:
        ok = run_step(outputs, "dump", key, mode, 40,
                      ALLOW_SESSIONS="yes" if allow_sessions else "no",
                      EMPTY_TARGET="yes" if empty_target else "no")
    finally:
        for _ in range(2):
            aws(["secretsmanager", "put-secret-value", "--secret-id", secret, "--secret-string", PLACEHOLDER])
    if not ok:
        sys.exit(1)
    return key


def latest_key(outputs: dict) -> str:
    listing = json.loads(aws([
        "s3api", "list-objects-v2", "--bucket", outputs["ops_bucket"], "--prefix", "cutover/", "--output", "json",
    ]))
    dumps = sorted((o["LastModified"], o["Key"]) for o in listing.get("Contents", []) if o["Key"].endswith(".dump"))
    if not dumps:
        sys.exit("No dump in the ops bucket yet: run dump first")
    return dumps[-1][1].removesuffix(".dump")


def mode_of(key: str) -> str:
    return "cutover" if key.startswith("cutover/cutover-") else "rehearsal"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("step", choices=["dump", "restore", "verify", "copy", "wipe"])
    parser.add_argument("--expect-account", required=True, help="the ringee-prod account id")
    parser.add_argument("--mode", choices=["rehearsal", "cutover"], help="dump and copy: required")
    parser.add_argument("--key", help="restore and verify: cutover/<mode>-<time> (default: the newest dump)")
    parser.add_argument("--allow-sessions", action="store_true",
                        help="cutover: dump even with other sessions on Railway's database")
    parser.add_argument("--confirm", help="wipe: must be ringee-prod")
    parser.add_argument("--keep", action="store_true",
                        help="copy --mode rehearsal: leave the copy in RDS (wipe it yourself before any service starts)")
    parser.add_argument("--dns-switched-early", action="store_true",
                        help="copy --mode cutover: api.ringee.io was pointed at this stack before the copy. Still "
                             "refuses while api or orchestrator run, and the task still refuses an RDS with tables")
    args = parser.parse_args()

    if args.step in ("dump", "copy") and not args.mode:
        parser.error(f"{args.step} needs --mode rehearsal or --mode cutover")
    if args.dns_switched_early and not (args.step == "copy" and args.mode == "cutover"):
        parser.error("--dns-switched-early only applies to copy --mode cutover")
    check_account(args.expect_account)
    outputs = stack_outputs()

    if args.step == "dump":
        print(f"dump ready: {dump(outputs, args.mode, args.allow_sessions, empty_target=False)}")
    elif args.step in ("restore", "verify"):
        key = args.key or latest_key(outputs)
        if args.step == "restore":
            guard_target(outputs, "restore")
            sys.exit(0 if run_step(outputs, "restore", key, mode_of(key), 60) else 1)
        sys.exit(0 if run_step(outputs, "verify", key, mode_of(key), 30) else 1)
    elif args.step == "copy":
        guard_target(outputs, "restore", dns_switched_early=args.dns_switched_early)
        started = time.monotonic()
        key = dump(outputs, args.mode, args.allow_sessions, empty_target=True)
        if not run_step(outputs, "restore", key, args.mode, 60):
            sys.exit(1)
        ok = run_step(outputs, "verify", key, args.mode, 30)
        print(f"copy: {'OK' if ok else 'FAILED'} in {(time.monotonic() - started) / 60:.1f} min ({key})")
        if args.mode == "rehearsal" and not args.keep:
            guard_target(outputs, "wipe")
            ok = run_step(outputs, "wipe", "-", "rehearsal", 10) and ok
        elif args.mode == "rehearsal":
            print("copy: --keep: RDS holds a copy of production. Run wipe before any service starts.")
        sys.exit(0 if ok else 1)
    else:
        if args.confirm != f"ringee-{ENV}":
            sys.exit(f"wipe empties RDS's ringee database: pass --confirm ringee-{ENV}")
        guard_target(outputs, "wipe")
        sys.exit(0 if run_step(outputs, "wipe", "-", "rehearsal", 10) else 1)


if __name__ == "__main__":
    main()
