#!/usr/bin/env python3
"""Synchronize only the shared Telnyx dispatch configuration, without exposing secrets.

Requires SSO profiles ringee-prod and ringee-staging. Dry run is the default.
Run after production's dedicated coordinator is available, before rolling ECS:
  python3 scripts/provider_dispatch_config.py --apply
"""

import argparse
import json
import subprocess
from urllib.parse import urlsplit

POLICY = {
    "TELNYX_ACCOUNT_REF": "ringee-managed",
    "TELNYX_CPS_MODE": "enforce",
    "TELNYX_CPS_CEILING": "5",
    "TELNYX_CPS_SAFETY_MARGIN": "0.2",
    "DISPATCH_QUEUE_ENABLED": "false",
}
MANAGED_KEYS = frozenset({"PROVIDER_DISPATCH_REDIS_URL", *POLICY})
ACCOUNTS = {"prod": "405762675020", "staging": "699340623836"}


def aws(env, *args, body=None):
    result = subprocess.run(
        ["aws", "--profile", f"ringee-{env}", "--region", "us-east-1", *args, "--output", "json"],
        input=json.dumps(body) if body is not None else None,
        capture_output=True,
        text=True,
    )
    if result.returncode:
        # Never echo CLI output: it may include the secret payload.
        raise RuntimeError(f"{env}: AWS {args[0]} {args[1]} failed")
    return json.loads(result.stdout or "{}")


def dispatch_values():
    for env, account in ACCOUNTS.items():
        if aws(env, "sts", "get-caller-identity")["Account"] != account:
            raise RuntimeError(f"Wrong AWS account for {env}")
    source = aws("prod", "secretsmanager", "get-secret-value", "--secret-id", "ringee/provider-dispatch")
    url = json.loads(source["SecretString"])["PROVIDER_DISPATCH_REDIS_URL"]
    parsed = urlsplit(url)
    cache = aws("prod", "elasticache", "describe-replication-groups", "--replication-group-id", "ringee-provider-dispatch")["ReplicationGroups"][0]
    endpoint = cache["NodeGroups"][0].get("PrimaryEndpoint", {}).get("Address")
    if not (cache["Status"] == "available" and parsed.scheme == "rediss" and parsed.hostname == endpoint and parsed.port == 6379 and parsed.path == "/0" and parsed.password):
        raise RuntimeError("The dedicated TLS coordinator must be available before synchronization")
    return {"PROVIDER_DISPATCH_REDIS_URL": url, **POLICY}


def merged_values(current, desired):
    previous = current.get("PROVIDER_DISPATCH_REDIS_URL")
    if previous and previous != desired["PROVIDER_DISPATCH_REDIS_URL"]:
        raise RuntimeError("Changing an existing coordinator requires draining every originator first")
    return {**current, **desired}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    desired = dispatch_values()
    plans = []
    for env in ACCOUNTS:
        name = f"ringee/{env}/shared"
        current = aws(env, "secretsmanager", "get-secret-value", "--secret-id", name)
        payload = json.loads(current["SecretString"])
        merged = merged_values(payload, desired)
        plans.append((env, name, current["VersionId"], payload, merged))
        print(f"{name}: " + ", ".join(sorted(k for k in desired if payload.get(k) != desired[k])))
    if not args.apply:
        print("Dry run: nothing written. API and orchestrator must be rolled after --apply.")
        return
    for env, name, version, current, merged in plans:
        if merged == current:
            print(f"{name}: already synchronized")
            continue
        latest = aws(env, "secretsmanager", "get-secret-value", "--secret-id", name)
        if latest["VersionId"] != version:
            raise RuntimeError(f"{name} changed during review; rerun before writing")
        aws(env, "secretsmanager", "put-secret-value", "--secret-id", name, "--secret-string", "file:///dev/stdin", body=merged)
        print(f"{name}: synchronized; existing application credentials preserved")
    print("Done. Roll API and orchestrator in both environments without changing their images.")


if __name__ == "__main__":
    main()
