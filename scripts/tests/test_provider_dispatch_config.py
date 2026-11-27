import contextlib
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import provider_dispatch_config as dispatch

spec = importlib.util.spec_from_file_location("staging_env", SCRIPTS / "staging-env.py")
staging = importlib.util.module_from_spec(spec)
spec.loader.exec_module(staging)


class DispatchConfigurationTests(unittest.TestCase):
    def setUp(self):
        self.desired = {"PROVIDER_DISPATCH_REDIS_URL": "rediss://:test-only@private.invalid:6379/0", **dispatch.POLICY}

    def test_sync_preserves_unrelated_credentials(self):
        current = {"STRIPE_SECRET_KEY": "test-credential", "CUSTOM_SETTING": "keep"}
        merged = dispatch.merged_values(current, self.desired)
        self.assertEqual(merged["STRIPE_SECRET_KEY"], current["STRIPE_SECRET_KEY"])
        self.assertEqual(merged["CUSTOM_SETTING"], "keep")
        self.assertEqual(current, {"STRIPE_SECRET_KEY": "test-credential", "CUSTOM_SETTING": "keep"})
        self.assertEqual(merged["TELNYX_CPS_MODE"], "enforce")

    def test_existing_coordinator_cannot_be_silently_replaced(self):
        with self.assertRaisesRegex(RuntimeError, "draining"):
            dispatch.merged_values({"PROVIDER_DISPATCH_REDIS_URL": "rediss://other.invalid/0"}, self.desired)

    def test_repeated_sync_is_idempotent(self):
        self.assertEqual(dispatch.merged_values(self.desired, self.desired), self.desired)

    def test_staging_reload_preserves_shared_dispatch_without_putting_it_in_env_file(self):
        keys = {"shared": sorted(dispatch.MANAGED_KEYS | {"STRIPE_SECRET_KEY"})}
        writes = []

        def aws(args, stdin=None):
            if args[:2] == ["sts", "get-caller-identity"]:
                return json.dumps({"Account": "699340623836"})
            if args[:2] == ["secretsmanager", "get-secret-value"]:
                return json.dumps({"SecretString": json.dumps(self.desired)})
            if args[:2] == ["secretsmanager", "put-secret-value"]:
                writes.append(json.loads(stdin))
                return "{}"
            raise AssertionError(args)

        with tempfile.TemporaryDirectory() as directory:
            env_file = Path(directory) / "staging.env"
            env_file.write_text("STRIPE_SECRET_KEY=staging-only\n")
            output = io.StringIO()
            with patch.object(staging, "ENV_FILE", env_file), patch.object(staging, "production_values", return_value=(keys, {"STRIPE_SECRET_KEY": "production-only"})), patch.object(staging, "required_variables", return_value=set()), patch.object(staging, "railway_env", return_value=SimpleNamespace(aws=aws)), contextlib.redirect_stdout(output):
                staging.load(SimpleNamespace(expect_account="699340623836", region="us-east-1"))
        self.assertEqual(writes, [{"STRIPE_SECRET_KEY": "staging-only", **self.desired}])
        self.assertNotIn(self.desired["PROVIDER_DISPATCH_REDIS_URL"], output.getvalue())


if __name__ == "__main__":
    unittest.main()
