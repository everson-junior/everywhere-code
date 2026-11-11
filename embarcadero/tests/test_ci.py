# SPDX-License-Identifier: MIT
"""CI packaging behavior with synthetic fixtures, never a Delphi build."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import zipfile

from test_contract import ROOT, REPO, powershell_executable


class WorkflowContracts(unittest.TestCase):
    def test_native_runner_is_opt_in_and_not_a_pr_trigger(self):
        workflow = (REPO / '.github/workflows/build-embarcadero.yml').read_text(encoding='utf-8-sig')
        self.assertIn('  workflow_dispatch:', workflow)
        self.assertIn('  workflow_call:', workflow)
        self.assertNotIn('pull_request:', workflow)
        self.assertNotIn('pull_request_target:', workflow)
        for required in ('vars.RADSTUDIO_CI_ENABLED', 'needs: preflight',
                         'environment: radstudio-ci', 'runs-on: [self-hosted, Windows, radstudio,',
                         'persist-credentials: false', 'contents: read', '-RunTests',
                         'if-no-files-found: error', 'embarcadero/build/artifacts/*.zip'):
            self.assertIn(required, workflow)
        release = (REPO / '.github/workflows/release.yml').read_text(encoding='utf-8-sig')
        block = release.split('  build-embarcadero:', 1)[1]
        self.assertIn("if: vars.RADSTUDIO_CI_ENABLED == 'true'", block)
        self.assertIn('uses: ./.github/workflows/build-embarcadero.yml', block)
        self.assertIn('contents: read', block)


@unittest.skipUnless(powershell_executable(), 'PowerShell unavailable')
class PackageBehavior(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='RAD package test ')
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name)
        self.root = self.repo / 'embarcadero'
        (self.root / 'scripts').mkdir(parents=True)
        (self.root / 'docs').mkdir()
        (self.root / 'build/Win32').mkdir(parents=True)
        shutil.copy2(ROOT / 'scripts/package.ps1', self.root / 'scripts/package.ps1')
        for path in (self.repo / 'LICENSE', self.root / 'README.md', self.root / 'docs/COMPATIBILITY.md'):
            path.write_text('fixture documentation', encoding='utf-8')
        (self.root / 'compatibility.json').write_text('{}', encoding='utf-8')
        self.binary = self.root / 'build/Win32/EverywhereRAD.bpl'
        self.binary.write_bytes(b'synthetic fixture - NOT an executable')
        self.evidence = self.root / 'build/Win32/build-evidence.json'
        self.evidence.write_text(json.dumps(dict(platform='Win32', compiler='dcc32.exe',
            compilerFileVersion='test-fixture-version', nativeBuildExecuted=True,
            protocolTestsPassed=True)), encoding='utf-8')

    def run_package(self, target='rad13-win32', commit='a' * 40):
        return subprocess.run([powershell_executable(), '-NoProfile', '-NonInteractive',
            '-ExecutionPolicy', 'Bypass', '-File', str(self.root / 'scripts/package.ps1'),
            '-Target', target, '-Platform', 'Win32', '-Commit', commit],
            capture_output=True, text=True, errors='replace', timeout=30)

    def test_archive_allowlist_and_manifest_hash(self):
        for name in ('vendor.dll', 'secret.lic', 'ProtocolTests.exe', 'EverywhereRAD.dcp'):
            (self.binary.parent / name).write_text('must not ship')
        result = self.run_package()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        archives = list((self.root / 'build/artifacts').glob('*.zip'))
        self.assertEqual(len(archives), 1)
        with zipfile.ZipFile(archives[0]) as archive:
            names = {name.replace('\\', '/'): name for name in archive.namelist() if not name.endswith('/')}
            self.assertEqual(set(names), {'EverywhereRAD.bpl', 'LICENSE', 'README.md',
                'docs/COMPATIBILITY.md', 'compatibility.json', 'build-manifest.json', 'INSTALL.txt'})
            manifest = json.loads(archive.read(names['build-manifest.json']).decode('utf-8-sig'))
            self.assertEqual(manifest['commit'], 'a' * 40)
            self.assertEqual(manifest['sha256'], hashlib.sha256(self.binary.read_bytes()).hexdigest())
            self.assertEqual(manifest['compilerFileVersion'], 'test-fixture-version')
            self.assertEqual(manifest['ideSmokeTest'], 'pending')
            self.assertTrue(manifest['protocolTestsPassed'])

    def test_missing_binary_is_rejected(self):
        self.binary.unlink()
        result = self.run_package()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Nonempty EverywhereRAD.bpl required', result.stdout + result.stderr)

    def test_missing_native_test_evidence_is_rejected(self):
        value = json.loads(self.evidence.read_text())
        value['protocolTestsPassed'] = False
        self.evidence.write_text(json.dumps(value))
        result = self.run_package()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Successful native build and protocol tests', result.stdout + result.stderr)

    def test_target_mismatch_is_rejected(self):
        self.assertNotEqual(self.run_package(target='rad13-win64').returncode, 0)

    def test_invalid_commit_is_rejected(self):
        self.assertNotEqual(self.run_package(commit='../invalid').returncode, 0)


if __name__ == '__main__':
    unittest.main()
