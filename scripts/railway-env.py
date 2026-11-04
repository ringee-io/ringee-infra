#!/usr/bin/env python3
"""Copy the Railway variables of Api, Orchestrator and chatgpt-mcp into Secrets
Manager (plan §4.7, AWS-18) and keep config/secret-keys.json in step.

A value never leaves this process except on its way to Secrets Manager, through
the AWS CLI's stdin: nothing is printed, logged, written to disk or put on argv.
Only variable names and counts are shown.

  scripts/railway-env.py                        # dry run: what would be copied
  scripts/railway-env.py --write-keys           # also rewrite config/secret-keys.json
  AWS_PROFILE=ringee-prod scripts/railway-env.py --apply --expect-account <id>

Run it in dry mode first, then again right before the cutover (plan §4.7), in
case someone changed a variable on Railway. Production only: staging must hold
test credentials (its own Telnyx account, Stripe test mode), never these.
"""

import argparse
import json
import subprocess
import sys
from pathlib import Path

RAILWAY_API = "https://backboard.railway.com/graphql/v2"
RAILWAY_PROJECT = "Ringee"
RAILWAY_ENVIRONMENT = "production"
# Secret scope => Railway service name.
SERVICES = {"api": "Api", "orchestrator": "Orchestrator", "chatgpt-mcp": "chatgpt-mcp"}
# Set by Terraform itself (modules/stack/main.tf, managed_variables). Keep in step.
MANAGED = {
    "DATABASE_URL", "REDIS_URL", "REDIS_HOST", "REDIS_PORT", "REDIS_PASSWORD", "REDIS_USERNAME",
    "TEMPORAL_ADDRESS", "PORT", "NODE_ENV", "TRUST_PROXY_HOPS", "RINGEE_MCP_PORT",
}
# Private Railway hostnames do not resolve outside Railway; public ones keep
# working from AWS, but only while that service stays on Railway.
RAILWAY_PRIVATE = "railway.internal"
RAILWAY_PUBLIC = "railway.app"
KEYS_FILE = Path(__file__).resolve().parent.parent / "config" / "secret-keys.json"


def railway_token() -> str:
    config = json.loads((Path.home() / ".railway" / "config.json").read_text())
    return config["user"]["token"]


def graphql(token: str, query: str, variables: dict) -> dict:
    body = json.dumps({"query": query, "variables": variables})
    # The token travels on stdin (curl -H @-), never on argv where ps shows it.
    # curl, not urllib: Python's certificate store fails against Railway here.
    proc = subprocess.run(
        ["curl", "-sS", RAILWAY_API, "-H", "@-", "-H", "Content-Type: application/json", "--data-binary", body],
        input=f"Authorization: Bearer {token}\n",
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        sys.exit(f"Railway API: curl failed with exit code {proc.returncode}")
    data = json.loads(proc.stdout)
    if data.get("errors"):
        sys.exit(f"Railway API: {data['errors'][0].get('message', 'unknown error')}")
    return data["data"]


def railway_variables() -> dict[str, dict[str, str]]:
    listing = subprocess.run(["railway", "list", "--json"], capture_output=True, text=True)
    if listing.returncode != 0:
        sys.exit("railway list failed: run `railway login` first")
    project_id = next((p["id"] for p in json.loads(listing.stdout) if p["name"] == RAILWAY_PROJECT), None)
    if not project_id:
        sys.exit(f"Railway project {RAILWAY_PROJECT!r} not found")

    token = railway_token()
    project = graphql(
        token,
        "query($id:String!){project(id:$id){environments{edges{node{id name}}} services{edges{node{id name}}}}}",
        {"id": project_id},
    )["project"]
    environment_id = next(
        e["node"]["id"] for e in project["environments"]["edges"] if e["node"]["name"] == RAILWAY_ENVIRONMENT
    )
    service_ids = {s["node"]["name"]: s["node"]["id"] for s in project["services"]["edges"]}

    result = {}
    for scope, service in SERVICES.items():
        if service not in service_ids:
            sys.exit(f"Railway service {service!r} not found")
        result[scope] = graphql(
            token,
            "query($p:String!,$e:String!,$s:String!){variables(projectId:$p,environmentId:$e,serviceId:$s)}",
            {"p": project_id, "e": environment_id, "s": service_ids[service]},
        )["variables"]
    return result


def classify(by_service: dict[str, dict[str, str]]) -> tuple[dict[str, dict[str, str]], list[str]]:
    def keep(name: str) -> bool:
        return not name.startswith("RAILWAY_") and name not in MANAGED

    api, orchestrator, chatgpt = (
        {k: v for k, v in by_service[scope].items() if keep(k)} for scope in ("api", "orchestrator", "chatgpt-mcp")
    )
    shared = {k: v for k, v in api.items() if k in orchestrator and orchestrator[k] == v}
    differing = sorted(k for k in api if k in orchestrator and orchestrator[k] != api[k])
    scopes = {
        "shared": shared,
        "api": {k: v for k, v in api.items() if k not in shared},
        "orchestrator": {k: v for k, v in orchestrator.items() if k not in shared},
        "chatgpt-mcp": chatgpt,
    }
    return scopes, differing


def aws(args: list[str], stdin: str | None = None) -> str:
    proc = subprocess.run(["aws", *args], input=stdin, capture_output=True, text=True)
    if proc.returncode != 0:
        # The AWS CLI never echoes the secret string in its errors.
        sys.exit(f"aws {args[0]} {args[1]} failed: {proc.stderr.strip()}")
    return proc.stdout


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--apply", action="store_true", help="write the values to Secrets Manager")
    parser.add_argument("--expect-account", help="required with --apply: the AWS account id of ringee-prod")
    parser.add_argument("--region", default="us-east-1")
    parser.add_argument("--write-keys", action="store_true", help="rewrite config/secret-keys.json")
    args = parser.parse_args()

    scopes, differing = classify(railway_variables())

    for scope, values in scopes.items():
        print(f"{scope}: {len(values)} variables")
        print("  " + " ".join(sorted(values)))
    if differing:
        print("\nSame name, different value in Api and Orchestrator (kept per service): " + " ".join(differing))
    def mentioning(host: str) -> list[str]:
        return sorted(
            f"{scope}:{name}" for scope, values in scopes.items() for name, value in values.items() if host in value
        )

    private = mentioning(RAILWAY_PRIVATE)
    public = [name for name in mentioning(RAILWAY_PUBLIC) if name not in private]
    if private:
        print("\nWARNING, private Railway hostnames (will not resolve on AWS): " + " ".join(private))
    if public:
        print("\nPublic Railway hostnames (work from AWS while that service stays on Railway): " + " ".join(public))

    keys = {scope: sorted(values) for scope, values in scopes.items()}
    if args.write_keys or args.apply:
        KEYS_FILE.write_text(json.dumps(keys, indent=2) + "\n")
        print(f"\nWrote {KEYS_FILE.relative_to(KEYS_FILE.parent.parent)} (names only).")
    elif KEYS_FILE.exists() and json.loads(KEYS_FILE.read_text()) != keys:
        print("\nconfig/secret-keys.json is out of date: run with --write-keys, then terraform apply.")

    if not args.apply:
        print("\nDry run: nothing was written to AWS.")
        return

    if not args.expect_account:
        sys.exit("--apply needs --expect-account <ringee-prod account id>")
    account = json.loads(aws(["sts", "get-caller-identity", "--output", "json"]))["Account"]
    if account != args.expect_account:
        sys.exit(f"Refusing to write: the AWS session is account {account}, not {args.expect_account}")

    for scope, values in scopes.items():
        aws(
            ["secretsmanager", "put-secret-value", "--region", args.region,
             "--secret-id", f"ringee/prod/{scope}", "--secret-string", "file:///dev/stdin"],
            stdin=json.dumps(values),
        )
        print(f"ringee/prod/{scope}: {len(values)} variables written")
    print("\nNext: terraform apply in envs/prod, so the task definitions list the same names.")


if __name__ == "__main__":
    main()
