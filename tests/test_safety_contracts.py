import json
import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class SafetyContractTests(unittest.TestCase):
    def read(self, relative_path):
        return (ROOT / relative_path).read_text(encoding="utf-8")

    def test_gate_routes_require_authentication_except_health(self):
        source = self.read("function/function_app.py")
        self.assertIn("http_auth_level=func.AuthLevel.FUNCTION", source)
        self.assertIn("auth_level=func.AuthLevel.ANONYMOUS", source)
        self.assertEqual(source.count("auth_level=func.AuthLevel.ANONYMOUS"), 1)

    def test_runtime_has_no_cosmos_key_or_automatic_memory_fallback(self):
        tracker = self.read("function/session_tracker.py")
        configure = self.read("scripts/Configure-Function.ps1")
        self.assertNotIn("COSMOS_KEY", tracker + configure)
        self.assertIn("There is deliberately no automatic fallback", tracker)
        self.assertIn("ALLOW_IN_MEMORY_SESSION_STORE", tracker)
        self.assertIn("match_condition=MatchConditions.IfNotModified", tracker)

    def test_infrastructure_uses_scoped_identity_and_generated_secret(self):
        main = self.read("bicep/main.bicep")
        core = self.read("bicep/modules/core.bicep")
        function = self.read("bicep/modules/function.bicep")
        permissions = self.read("bicep/modules/permissions.bicep")
        combined = main + core + function + permissions
        self.assertIn("param demoSecretValue string = newGuid()", main)
        self.assertIn("disableLocalAuth: true", core)
        self.assertIn("Key Vault Secrets Officer", core)
        self.assertNotIn("Key Vault Administrator", combined)
        self.assertIn("/dbs/trifecta-db/colls/sessions", permissions)
        self.assertIn("/dbs/trifecta-db/colls/employees", permissions)
        self.assertNotIn("sk-demo-trifecta", combined)
        self.assertIn("type: 'SystemAssignedIdentity'", function)
        self.assertIn("AzureWebJobsStorage__accountName", function)
        self.assertIn("allowSharedKeyAccess: false", function)
        self.assertNotIn("listKeys()", function)

    def test_cleanup_requires_ownership_preflight_and_whatif(self):
        cleanup = self.read("scripts/Remove-Lab.ps1")
        self.assertIn("SupportsShouldProcess", cleanup)
        self.assertIn("$group.tags.'nlzt-owner' -ceq $OwnerMarker", cleanup)
        self.assertIn("$foreignResources.Count -gt 0", cleanup)
        self.assertLess(cleanup.index("$groupOwned"), cleanup.index("az @arguments"))

    def test_deployment_is_fail_fast_and_does_not_store_cosmos_keys(self):
        deploy = self.read("scripts/Deploy-Lab.ps1")
        configure = self.read("scripts/Configure-Function.ps1")
        seed = self.read("scripts/Seed-Data.ps1")
        self.assertIn("$PSNativeCommandUseErrorActionPreference = $true", deploy)
        self.assertIn("Deployment failed:", deploy)
        self.assertIn("CleanupOnFailure", deploy)
        self.assertNotIn("COSMOS_KEY", deploy + configure)
        self.assertNotIn("primaryMasterKey", seed)
        self.assertIn("type=aad&ver=1.0&sig=", seed)
        self.assertIn("$runtimeFiles = @(", deploy)
        self.assertIn("'requirements.lock'", deploy)
        self.assertNotIn("Compress-Archive -Path (Join-Path $functionDir '*')", deploy)

    def test_registry_json_is_valid_and_has_unique_tools(self):
        registry = json.loads(self.read("function/tools.json"))
        names = [tool["name"] for tool in registry["tools"]]
        self.assertEqual(len(names), len(set(names)))
        self.assertEqual(len(names), 7)

    def test_readme_does_not_claim_the_missing_companion_route(self):
        readme = self.read("README.md")
        self.assertIn("does **not** currently have a published companion article", readme)
        self.assertNotIn(
            "](https://nineliveszerotrust.com/blog/lethal-trifecta/)", readme
        )

    def test_ci_actions_and_runtime_dependencies_are_immutable(self):
        workflow = self.read(".github/workflows/ci.yml")
        external_actions = re.findall(r"uses:\s*([^\s#]+)", workflow)
        self.assertTrue(external_actions)
        for action in external_actions:
            if action.startswith("./"):
                continue
            self.assertRegex(action, r"@[0-9a-f]{40}$")

        requirements_entrypoint = self.read("function/requirements.txt")
        requirements_input = self.read("function/requirements.in")
        requirements_lock = self.read("function/requirements.lock")
        self.assertIn("--require-hashes", requirements_entrypoint)
        self.assertIn("-r requirements.lock", requirements_entrypoint)
        self.assertIn("--require-hashes --requirement function/requirements.lock", workflow)
        self.assertNotRegex(requirements_input, r"(?m)^[A-Za-z0-9_.-]+(?:>=|~=|>|<)")
        lock_lines = requirements_lock.splitlines()
        package_starts = [
            index
            for index, line in enumerate(lock_lines)
            if re.match(r"^[A-Za-z0-9_.-]+==[^\\]+\\$", line)
        ]
        self.assertGreater(len(package_starts), 5)
        for position, start in enumerate(package_starts):
            end = (
                package_starts[position + 1]
                if position + 1 < len(package_starts)
                else len(lock_lines)
            )
            self.assertIn("--hash=sha256:", "\n".join(lock_lines[start:end]))


if __name__ == "__main__":
    unittest.main()
