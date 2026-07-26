import os
import shutil
import subprocess
import textwrap
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(shutil.which("pwsh"), "PowerShell 7 is not available")
class PowerShellSafetyTests(unittest.TestCase):
    def test_cleanup_preview_collision_and_owned_delete_contract(self):
        harness = textwrap.dedent(
            r"""
            $ErrorActionPreference = 'Stop'
            $global:foreign = $false
            $global:deletes = @()
            function global:az {
                $request = $args -join ' '
                if ($request -match '^account show') {
                    '{"id":"11111111-1111-1111-1111-111111111111","name":"Lab Subscription"}'
                    return
                }
                if ($request -match '^group exists') { 'true'; return }
                if ($request -match '^group show') {
                    '{"name":"trifecta-lab-rg","tags":{"nlzt-owner":"lethal-trifecta-lab","project":"trifecta-lab","environment":"lab","purpose":"lethal-trifecta-demo"}}'
                    return
                }
                if ($request -match '^resource list') {
                    if ($global:foreign) {
                        '[{"id":"/subscriptions/sub/resourceGroups/trifecta-lab-rg/providers/Example/widgets/foreign","type":"Example/widgets","tags":{"project":"someone-else"}}]'
                    } else {
                        '[{"id":"/subscriptions/sub/resourceGroups/trifecta-lab-rg/providers/Example/widgets/owned","type":"Example/widgets","tags":{"nlzt-owner":"lethal-trifecta-lab","project":"trifecta-lab"}}]'
                    }
                    return
                }
                if ($request -match '^group delete') {
                    $global:deletes += $request
                    return
                }
                throw "Unexpected mocked az call: $request"
            }

            $preview = & $env:REMOVE_LAB_SCRIPT -ProjectName 'trifecta-lab' -WhatIf 6>&1 | Out-String
            if ($preview -notmatch 'Cleanup preview complete; no resources were deleted') {
                throw "Cleanup preview summary missing: $preview"
            }
            if ($global:deletes.Count -ne 0) { throw 'WhatIf issued a group delete' }

            $global:foreign = $true
            $collision = ''
            try {
                $null = & $env:REMOVE_LAB_SCRIPT -ProjectName 'trifecta-lab' -Confirm:$false 6>&1
            } catch {
                $collision = $_.Exception.Message
            }
            if ($collision -notmatch 'unowned or foreign top-level resources') {
                throw "Foreign collision was not rejected: $collision"
            }
            if ($global:deletes.Count -ne 0) { throw 'Foreign collision issued a delete' }

            $global:foreign = $false
            $null = & $env:REMOVE_LAB_SCRIPT -ProjectName 'trifecta-lab' -Confirm:$false 6>&1
            if ($global:deletes.Count -ne 1) {
                throw "Expected one owned group delete, got $($global:deletes.Count)"
            }
            if ($global:deletes[0] -notmatch '--name trifecta-lab-rg') {
                throw "Delete targeted the wrong group: $($global:deletes[0])"
            }
            'OK'
            """
        )
        environment = os.environ.copy()
        environment["REMOVE_LAB_SCRIPT"] = str(ROOT / "scripts" / "Remove-Lab.ps1")
        result = subprocess.run(
            ["pwsh", "-NoLogo", "-NoProfile", "-Command", harness],
            capture_output=True,
            text=True,
            env=environment,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr or result.stdout)
        self.assertIn("OK", result.stdout)


if __name__ == "__main__":
    unittest.main()
