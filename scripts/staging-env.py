#!/usr/bin/env python3
"""Staging secrets (plan §4.9): a template built from production's variables,
then the filled file loaded into Secrets Manager.

  scripts/staging-env.py template                 # writes staging.env (git-ignored)
  AWS_PROFILE=ringee-staging scripts/staging-env.py load --expect-account 699340623836

`template` copies from production only what is plainly configuration (numbers,
booleans, model names, flags, provider endpoints), maps our own production URLs
to their staging hosts, generates a new APP_ENCRYPTION_SECRET, and leaves every
credential, id and address empty. Variables the app refuses to boot without are
marked REQUIRED.

`load` refuses a file that misses a variable, leaves a REQUIRED one empty, or
holds a value equal to production's that is not plain configuration: a
production credential cannot reach staging by mistake. Values are only ever
sent to Secrets Manager through the AWS CLI's stdin, never printed.

Staging needs its own accounts: Telnyx, Stripe test mode, a Clerk development
instance, a separate R2 bucket and Firebase project, development OAuth apps.
"""

import argparse
import importlib.util
import json
import re
import secrets
import subprocess
import sys
from datetime import date
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ENV_FILE = ROOT / "staging.env"
CONFIGURATION_SOURCE = (
    "https://raw.githubusercontent.com/ringee-io/ringee-app/main/packages/configuration/src/api.configuration.ts"
)

# Our production hosts and their staging counterparts.
HOST_MAP = {
    "api.ringee.io": "api.staging.ringee.io",
    "chatgpt.ringee.io": "chatgpt.staging.ringee.io",
    "www.ringee.io": "staging.ringee.io",
    "ringee.io": "staging.ringee.io",
}
# Name endings that make a variable environment-specific whatever its value.
SPECIFIC_ENDINGS = (
    "_ID", "_IDS", "_KEY", "_SECRET", "_TOKEN", "_PASSWORD", "_PWD", "_SIP_USER", "_USERNAME",
    "_EMAIL", "_EMAILS", "_ADDRESS", "_NUMBER", "_BUCKETNAME", "_CERT_URL",
)
SPECIFIC_WORDS = ("PRIVATE", "SECRET", "TOKEN", "PASSWORD")
# URLs that are provider endpoints, identical in every environment.
PROVIDER_URL_ENDINGS = ("_API_BASE_URL", "_OAUTH_AUTHORIZE_URL", "_OAUTH_TOKEN_URL")
# Required at boot but unused in staging: any non-empty value lets it start.
PLACEHOLDER = "disabled-in-staging"
PLACEHOLDER_KEYS = {"WHATSAPP_PHONE_ID", "WHATSAPP_TOKEN", "WHATSAPP_VERIFY_TOKEN", "WHATSAPP_PHONE_NUMBER"}


def railway_env():
    spec = importlib.util.spec_from_file_location("railway_env", ROOT / "scripts" / "railway-env.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def looks_random(value: str) -> bool:
    """A long token without the separators that model names and scopes have."""
    if len(value) < 32 or " " in value:
        return False
    separators = sum(value.count(c) for c in "-._/:")
    return separators * 20 < len(value) and bool(re.search(r"\d", value)) and bool(re.search(r"[A-Za-z]", value))


def is_plain_config(name: str, value: str) -> bool:
    """True for values that can be copied to staging as they are."""
    if value == "*":  # a wildcard ("every organization") names no account
        return True
    if not value or name.endswith(SPECIFIC_ENDINGS):
        return False
    if name.endswith(PROVIDER_URL_ENDINGS):
        return "ringee" not in value and "railway" not in value
    if re.fullmatch(r"-?\d+(\.\d+)?", value) or value in ("true", "false"):
        return True
    if any(word in name for word in SPECIFIC_WORDS):
        return False
    if "://" in value or "@" in value or "railway" in value or looks_random(value):
        return False
    if "ringee" in value and re.search(r"[./]", value):
        return False
    return bool(re.fullmatch(r"[A-Za-z0-9._:,/\- ]{1,400}", value))


def staging_url(value: str) -> str | None:
    """Our production URL with the staging host, or None if it is not ours."""
    match = re.match(r"^(https?|wss?)://([^/:]+)(.*)$", value)
    if not match or match.group(2) not in HOST_MAP:
        return None
    return f"{match.group(1)}://{HOST_MAP[match.group(2)]}{match.group(3)}"


def required_variables() -> set[str]:
    proc = subprocess.run(["curl", "-fsS", CONFIGURATION_SOURCE], capture_output=True, text=True)
    if proc.returncode != 0:
        sys.exit("Could not read the app's configuration from GitHub")
    source = proc.stdout
    names = set(re.findall(r"if \(!(?:apiConfiguration|process\.env)\.([A-Z0-9_]+)", source))
    names |= set(re.findall(r"errors\.push\(\s*[\"'`]([A-Z][A-Z0-9_]+) ", source))
    return names


def production_values() -> tuple[dict[str, list[str]], dict[str, str]]:
    """Scopes from config/secret-keys.json, and production's value per name."""
    module = railway_env()
    keys = json.loads(module.KEYS_FILE.read_text())
    by_service = module.railway_variables()
    values: dict[str, str] = {}
    for service in ("api", "orchestrator", "chatgpt-mcp"):
        for name, value in by_service[service].items():
            values.setdefault(name, value)
    return keys, values


def quote(value: str) -> str:
    if re.fullmatch(r"[A-Za-z0-9._:,/\-]*", value):
        return value
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'


def template(_args) -> None:
    if ENV_FILE.exists():
        sys.exit(f"{ENV_FILE.name} already exists; move it away first so nothing filled in is lost")
    keys, prod = production_values()
    required = required_variables()
    scopes_of: dict[str, list[str]] = {}
    for scope, names in keys.items():
        for name in names:
            scopes_of.setdefault(name, []).append(scope)

    lines = [
        f"# Ringee staging variables, generated {date.today().isoformat()} by scripts/staging-env.py template.",
        "# Fill every empty REQUIRED value. Leave the others empty if staging does not use them.",
        "# Never paste a production credential: `load` refuses values equal to production's.",
        '# One KEY=value per line; quote values with spaces in double quotes ("\\n" is a newline).',
        "# This file holds secrets once filled: it is git-ignored; delete it after loading.",
        "",
    ]
    counts = {"copied": 0, "mapped": 0, "generated": 0, "placeholder": 0, "empty": 0}
    for name in sorted(scopes_of):
        value = prod.get(name, "")
        notes = []
        if name in required:
            notes.append("REQUIRED")
        if name == "APP_ENCRYPTION_SECRET":
            out, kind = secrets.token_hex(32), "generated"
            notes.append("new for staging, never production's")
        elif name in PLACEHOLDER_KEYS:
            out, kind = PLACEHOLDER, "placeholder"
            notes.append("WhatsApp is off in staging")
        elif staging_url(value):
            out, kind = staging_url(value), "mapped"
            notes.append("production URL mapped to staging; check it")
        elif is_plain_config(name, value):
            out, kind = value, "copied"
        else:
            out, kind = "", "empty"
            notes.append("staging value needed" if value else "empty in production too")
        counts[kind] += 1
        notes.append("used by " + ", ".join(scopes_of[name]))
        lines.append(f"# {' · '.join(notes)}")
        lines.append(f"{name}={quote(out)}")
    ENV_FILE.write_text("\n".join(lines) + "\n")
    ENV_FILE.chmod(0o600)
    print(f"Wrote {ENV_FILE.name}: " + ", ".join(f"{n} {k}" for k, n in counts.items()))
    print("REQUIRED and still empty: " + " ".join(
        sorted(n for n in scopes_of if n in required and not parse(ENV_FILE).get(n))))


def parse(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for number, raw in enumerate(path.read_text().splitlines(), start=1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        name, sep, value = line.partition("=")
        name = name.strip()
        if not sep or not re.fullmatch(r"[A-Z][A-Z0-9_]*", name):
            sys.exit(f"{path.name}:{number}: expected KEY=value")
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] == '"':
            value = re.sub(r'\\(["\\n])', lambda m: "\n" if m.group(1) == "n" else m.group(1), value[1:-1])
        elif len(value) >= 2 and value[0] == value[-1] == "'":
            value = value[1:-1]
        values[name] = value
    return values


def load(args) -> None:
    if not ENV_FILE.exists():
        sys.exit(f"{ENV_FILE.name} not found: run `template` first")
    staging = parse(ENV_FILE)
    keys, prod = production_values()
    required = required_variables()
    names = sorted({name for scope in keys.values() for name in scope})

    missing = [n for n in names if n not in staging]
    empty_required = [n for n in names if n in required and not staging.get(n)]
    from_production = [
        n for n in names
        if staging.get(n) and staging[n] == prod.get(n) and not is_plain_config(n, staging[n])
    ]
    problems = []
    if missing:
        problems.append("missing from the file: " + " ".join(missing))
    if empty_required:
        problems.append("REQUIRED and empty: " + " ".join(empty_required))
    if from_production:
        problems.append("same value as production (a production credential?): " + " ".join(from_production))
    if problems:
        sys.exit("Refusing to load:\n  " + "\n  ".join(problems))

    module = railway_env()
    account = json.loads(module.aws(["sts", "get-caller-identity", "--output", "json"]))["Account"]
    if account != args.expect_account:
        sys.exit(f"Refusing to write: the AWS session is account {account}, not {args.expect_account}")
    for scope, scope_names in keys.items():
        module.aws(
            ["secretsmanager", "put-secret-value", "--region", args.region,
             "--secret-id", f"ringee/staging/{scope}", "--secret-string", "file:///dev/stdin"],
            stdin=json.dumps({n: staging[n] for n in scope_names}),
        )
        print(f"ringee/staging/{scope}: {len(scope_names)} variables written")
    print(f"\nDone. Delete {ENV_FILE.name} or keep it in your password manager.")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("template", help="write staging.env from production's variable names")
    loader = commands.add_parser("load", help="write staging.env to Secrets Manager")
    loader.add_argument("--expect-account", required=True, help="the ringee-staging account id")
    loader.add_argument("--region", default="us-east-1")
    args = parser.parse_args()
    {"template": template, "load": load}[args.command](args)


if __name__ == "__main__":
    main()
