# SPDX-License-Identifier: MIT
"""Source/distribution contracts, not Delphi compilation or IDE certification.

Run from the repository root:
    python -B -m unittest discover -s embarcadero/tests -p test_contract.py -v
Only the standard library is needed. PowerShell failure-path tests are skipped
when neither pwsh nor Windows PowerShell is available.
"""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
REPO = ROOT.parent
SCRIPT = ROOT / "scripts" / "build.ps1"
EXPECTED_UNITS = {
    "Everywhere.Register", "Everywhere.Window", "Everywhere.Settings",
    "Everywhere.Runtime", "Everywhere.Protocol",
}


def powershell_executable():
    for command in ("pwsh", "powershell"):
        executable = shutil.which(command)
        if executable:
            return executable
    if os.name == "nt":
        executable = Path(os.environ.get("SystemRoot", r"C:\Windows")) / (
            "System32/WindowsPowerShell/v1.0/powershell.exe"
        )
        if executable.is_file():
            return str(executable)
    return None


class MetadataContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.metadata = json.loads((ROOT / "compatibility.json").read_text(encoding="utf-8-sig"))

    def test_candidate_matrix_is_unique_and_architecture_matches_output(self):
        targets = self.metadata["targets"]
        keys = {(target["version"], target["codename"], target["platform"]) for target in targets}
        self.assertEqual(len(keys), len(targets), "Duplicate compatibility target")
        self.assertEqual(keys, {
            ("12", "Athens", "Win32"), ("13", "Florence", "Win32"),
            ("13", "Florence", "Win64"),
        })
        for target in targets:
            with self.subTest(target=target):
                self.assertEqual(target["ideArchitecture"], {"Win32": "x86", "Win64": "x64"}[target["platform"]])
                self.assertEqual(target["status"], "candidate")
                self.assertIs(target["validated"], False)
                output = Path(self.metadata["outputPattern"].format(platform=target["platform"]))
                self.assertEqual(output.parts, ("build", target["platform"], "EverywhereRAD.bpl"))

    def test_unvalidated_evidence_cannot_claim_release(self):
        self.assertEqual(self.metadata["schemaVersion"], 1)
        self.assertEqual(self.metadata["status"], "experimental")
        for field in ("licensedCompilerAvailable", "nativeBuildExecuted", "ideSmokeTestExecuted", "automaticBplRelease"):
            self.assertIs(self.metadata["validation"][field], False, field)
        self.assertTrue(self.metadata["validation"]["evidence"].strip())
        self.assertEqual(self.metadata["license"], "MIT")
        self.assertTrue((REPO / "LICENSE").read_text(encoding="utf-8").startswith("MIT License"))

    def test_operational_policy_requires_approval_and_ordered_checkpoints(self):
        policy = self.metadata["policy"]
        self.assertEqual(policy["owner"], "Engenharia V&D")
        self.assertEqual(policy["approval"], "pending")
        self.assertEqual(policy["windowDays"], 30)
        milestones = policy["milestones"]
        self.assertEqual([item["day"] for item in milestones], [0, 7, 21, 30])
        self.assertTrue(all(item["action"].strip() for item in milestones))
        self.assertEqual(max(item["day"] for item in milestones), policy["windowDays"])

    def test_capabilities_do_not_advertise_missing_integration(self):
        capabilities = self.metadata["capabilities"]
        self.assertIs(capabilities["modelessWindow"], True)
        self.assertIs(capabilities["embeddedWebView2"], True)
        self.assertIs(capabilities["docking"], True)
        for field in ("editorTab", "reuseExternalService", "terminateByPort", "fmxDesignerIntegration"):
            self.assertIs(capabilities[field], False, field)


class PackageContracts(unittest.TestCase):
    def test_package_unit_manifest_resolves_and_matches_declarations(self):
        package = (ROOT / "EverywhereRAD.dpk").read_text(encoding="utf-8-sig")
        self.assertRegex(package, r"(?i)\bpackage\s+EverywhereRAD\s*;")
        self.assertRegex(package, r"(?i)\{\$DESIGNONLY\}")
        manifest = re.findall(r"(?im)^\s*(Everywhere\.\w+)\s+in\s+'([^']+)'", package)
        self.assertEqual(len(manifest), len(EXPECTED_UNITS))
        self.assertEqual({name for name, _ in manifest}, EXPECTED_UNITS)
        for name, relative in manifest:
            with self.subTest(unit=name):
                path = (ROOT / relative.replace("\\", "/")).resolve()
                self.assertTrue(path.is_relative_to(ROOT.resolve()))
                self.assertTrue(path.is_file(), f"Missing package unit: {relative}")
                source = path.read_text(encoding="utf-8-sig")
                self.assertRegex(source, rf"(?im)^\s*unit\s+{re.escape(name)}\s*;")
        requires = re.search(r"(?is)\brequires\s+(.*?);", package)
        self.assertIsNotNone(requires)
        self.assertTrue({"rtl", "vcl", "vcledge", "designide"}.issubset({name.strip().lower() for name in requires[1].split(",")}))

    def test_docking_frame_resource_and_registration_contract(self):
        source = (ROOT / "src/Everywhere.Window.pas").read_text(encoding="utf-8-sig")
        self.assertIn("class(TFrame)", source)
        self.assertIn("class(TInterfacedObject, INTACustomDockableForm)", source)
        self.assertIn("{$R Everywhere.Window.dfm}", source)
        resource = (ROOT / "src/Everywhere.Window.dfm").read_text(encoding="utf-8-sig")
        self.assertIn("object HarnessFrame: THarnessFrame", resource)
        for call in ("RegisterDockableForm(HarnessDock)", "CreateDockableForm(HarnessDock)",
                     "UnregisterDockableForm(HarnessDock)"):
            self.assertIn(call, source)
        self.assertRegex(source, r"(?s)\binitialization\s+HarnessFrame\s*:=\s*nil;\s+finalization\s+UnregisterHarnessWindow;")

    def test_compact_toolbar_borrows_native_icons_not_ide_commands(self):
        source = (ROOT / "src/Everywhere.Window.pas").read_text(encoding="utf-8-sig")
        self.assertIn("FToolbar := TToolBar.Create(Self)", source)
        self.assertIn("FActions.Images := Services.ImageList", source)
        self.assertIn("FToolbar.Images := Services.ImageList", source)
        self.assertIn("Result.OnExecute := Handler", source)
        self.assertIn("Button.Action := Result", source)
        self.assertIn("RunRunCommand", source)
        self.assertIn("RunResetCommand", source)
        self.assertIn("FToolbar.ShowCaptions := False", source)
        self.assertIn("Button.Style := tbsTextButton", source)
        self.assertIn("FDiagnosticsButton.Style := tbsCheck", source)
        self.assertIn("Erro - abrir diagnosticos|", source)
        self.assertNotIn("NativeAction.Execute", source)
        self.assertNotIn("Button.Action := NativeAction", source)

    def test_webview_uses_all_remaining_space_and_logs_are_on_demand(self):
        source = (ROOT / "src/Everywhere.Window.pas").read_text(encoding="utf-8-sig")
        constructor = source.split("constructor THarnessFrame.Create", 1)[1].split("destructor THarnessFrame.Destroy", 1)[0]
        self.assertIn("FBrowser.Parent := Self", constructor)
        self.assertIn("FBrowser.Align := alClient", constructor)
        for forbidden in ("FBrowserHint", "FStatus", "TFlowPanel", "TButton.Create", "TMemo.Create", "alBottom"):
            self.assertNotIn(forbidden, constructor)
        self.assertIn("FLogs := TStringList.Create", constructor)
        self.assertIn("while FLogs.Count >= 500", source)
        self.assertIn("FreeAndNil(FLogs)", source)
        diagnostics = source.split("procedure THarnessFrame.DiagnosticsClick", 1)[1].split("procedure THarnessFrame.BrowserError", 1)[0]
        self.assertIn("TMemo.Create(Dialog)", diagnostics)
        self.assertIn("Memo.Lines.AddStrings(FLogs)", diagnostics)
        self.assertIn("Dialog.ShowModal", diagnostics)

    def test_loader_flags_are_declared_without_optional_rtl_symbols(self):
        # Regression guard for E2003 on RTLs missing the Windows SDK constants.
        source = (ROOT / "src/Everywhere.Window.pas").read_text(encoding="utf-8-sig")
        self.assertIn("HarnessLoadLibrarySearchDllLoadDir: DWORD = $00000100;", source)
        self.assertIn("HarnessLoadLibrarySearchSystem32: DWORD = $00000800;", source)
        self.assertRegex(source, r"LoadLibraryEx\(PChar\(LoaderPath\), 0,\s*HarnessLoadLibrarySearchDllLoadDir or HarnessLoadLibrarySearchSystem32\)")
        self.assertNotRegex(source, r"\bLOAD_LIBRARY_SEARCH_(?:DLL_LOAD_DIR|SYSTEM32)\b")

    def test_browser_waits_for_creation_and_reports_navigation_errors(self):
        source = (ROOT / "src/Everywhere.Window.pas").read_text(encoding="utf-8-sig")
        self.assertIn("FBrowser.CreateWebView", source)
        pending = source.split("procedure THarnessFrame.NavigatePending;", 1)[1].split("procedure THarnessFrame.Tick", 1)[0]
        self.assertIn("not FBrowser.WebViewCreated", pending)
        self.assertIn("if FBrowser.Navigate(FRuntime.ActiveUrl) then", pending)
        self.assertIn("FLastUrl := FRuntime.ActiveUrl", pending)
        self.assertIn("FBrowser.OnNavigationCompleted := NavigationCompleted", source)
        self.assertIn("IntToHex(Cardinal(AResult), 8)", source)
        self.assertIn("GetTickCount64 - FBrowserStartedAt >= 30000", source)
        self.assertIn("FBrowser.CloseWebView", source)
        self.assertNotIn("SetDllDirectory(", source)
        self.assertNotIn("SetWebView2Path(", source)

    def test_docking_sync_uses_browser_hwnd_bounds_and_effective_visibility(self):
        source = (ROOT / "src/Everywhere.Window.pas").read_text(encoding="utf-8-sig")
        observe = source.split("procedure THarnessFrame.ObserveBrowserHost;", 1)[1].split("function THarnessFrame.BrowserHostReady", 1)[0]
        self.assertIn("FBrowser.HandleGeneration", observe)
        self.assertIn("FBrowser.HandleNeeded", observe)
        self.assertIn("GetAncestor(Current.Window, GA_ROOT)", observe)
        self.assertIn("IsWindowVisible(Current.Window)", observe)
        self.assertIn("GetWindowRect(Current.Window, Current.ScreenBounds)", observe)
        self.assertIn("csDestroying in ComponentState", observe)
        sync = source.split("procedure THarnessFrame.SyncBrowserHost;", 1)[1].split("procedure THarnessFrame.EnsureBrowser;", 1)[0]
        self.assertIn("Controller.Get_ParentWindow(ParentWindow)", sync)
        self.assertIn("Controller.Set_ParentWindow(wireHWND(FBrowserHost.Window))", sync)
        self.assertIn("ClientBounds: System.Types.TRect", sync)
        self.assertIn("Bounds: Winapi.WebView2.tagRECT", sync)
        self.assertIn("ClientBounds := FBrowser.ClientRect", sync)
        for field in ("Left", "Top", "Right", "Bottom"):
            self.assertIn(f"Bounds.{field} := ClientBounds.{field};", sync)
        self.assertNotIn("\n    Bounds := FBrowser.ClientRect;", sync)
        self.assertIn("Controller.Set_Bounds(Bounds)", sync)
        self.assertIn("Controller.Set_IsVisible(Ord(FBrowserHost.Visible))", sync)
        self.assertIn("Controller.NotifyParentWindowPositionChanged", sync)
        self.assertIn("NativeUInt(ParentWindow)", sync)

    def test_docking_recovery_is_deferred_bounded_and_does_not_restart_runtime(self):
        source = (ROOT / "src/Everywhere.Window.pas").read_text(encoding="utf-8-sig")
        sync = source.split("procedure THarnessFrame.SyncBrowserHost;", 1)[1].split("procedure THarnessFrame.EnsureBrowser;", 1)[0]
        self.assertIn("GetTickCount64 - FHostChangedAt < BrowserDockSettleMs", sync)
        self.assertIn("if not FHostRecoveryUsed", sync)
        self.assertIn("FHostRecoveryUsed := True", sync)
        self.assertIn("FHostSyncBlocked := True", sync)
        self.assertIn("FCreatingGeneration <> FBrowserHost.Generation", sync)
        self.assertIn("FResettingBrowser := True", sync)
        self.assertIn("FResettingBrowser := False", sync)
        for forbidden in ("FRuntime.Start", "FRuntime.Stop", "RestartClick(", "CloseBrowserProcess", "CreateWebView"):
            self.assertNotIn(forbidden, sync)
        callback = source.split("procedure THarnessFrame.BrowserCreated", 1)[1].split("procedure THarnessFrame.NavigationCompleted", 1)[0]
        self.assertIn("$80004004", callback)  # E_ABORT while a docking HWND is destroyed
        self.assertIn("FHostSyncPending := True", callback)
        self.assertIn("or FResettingBrowser then Exit", callback)
        self.assertNotIn("NavigatePending;", callback)
        self.assertNotIn("FBrowser.CreateWebView", callback)
        tick = source.split("procedure THarnessFrame.Tick", 1)[1].split("procedure THarnessFrame.StartClick", 1)[0]
        self.assertLess(tick.index("ObserveBrowserHost;"), tick.index("SyncBrowserHost;"))
        self.assertLess(tick.index("SyncBrowserHost;"), tick.index("EnsureBrowser;"))

    def test_protocol_test_program_exists_and_only_references_local_units(self):
        source = (ROOT / "tests" / "ProtocolTests.dpr").read_text(encoding="utf-8-sig")
        self.assertRegex(source, r"(?im)^\s*program\s+ProtocolTests\s*;")
        references = re.findall(r"(?i)\bin\s+'([^']+\.pas)'", source)
        self.assertTrue(references, "Protocol program must resolve its production units")
        for relative in references:
            path = (ROOT / "tests" / relative.replace("\\", "/")).resolve()
            self.assertTrue(path.is_relative_to(ROOT.resolve()))
            self.assertTrue(path.is_file(), relative)

    def test_source_distribution_contains_no_vendor_or_generated_binaries(self):
        # DCUs created by a local IDE Build are ignored by Git, not shipped.
        forbidden = {".bpl", ".dcp", ".dll", ".exe", ".lib", ".obj", ".bpi", ".hpp", ".h"}
        files = [path for path in ROOT.rglob("*") if path.is_file() and "build" not in path.relative_to(ROOT).parts]
        self.assertEqual([str(path.relative_to(ROOT)) for path in files if path.suffix.lower() in forbidden], [])

    def test_runtime_start_uses_profile_cli_without_web_subcommand(self):
        # This is a source contract, NOT execution of Delphi/native semantics.
        source = (ROOT / "src" / "Everywhere.Runtime.pas").read_text(encoding="utf-8-sig")
        start = re.search(
            r"(?is)procedure\s+THarnessRuntime\.Start\b(.*?)procedure\s+THarnessRuntime\.Install\b",
            source,
        )
        self.assertIsNotNone(start)
        body = re.sub(r"//[^\n]*|\{.*?\}|\(\*.*?\*\)", "", start[1], flags=re.S)
        assignments = re.findall(r"(?i)\bArguments\s*:=\s*([^;]+);", body)
        self.assertEqual(len(assignments), 2, "Review CLI argument construction when changing runtime protocol")
        literal_arguments = [re.findall(r"'((?:''|[^'])*)'", expression) for expression in assignments]
        self.assertEqual(literal_arguments, [["--profile ", " --no-open"], [" --port "]])
        self.assertRegex(assignments[0], r"(?i)'--profile '\s*\+\s*Profile\s*\+\s*' --no-open'")
        self.assertRegex(body, r"(?i)if\s+Port\s*<>\s*0\s+then\s+Arguments\s*:=")
        self.assertRegex(body, r"(?i)Launch\(Binary,\s*Arguments,\s*Directory,\s*hsStarting\)")
        self.assertRegex(body, r"(?i)Directory\s*:=\s*ValidDirectory\(Workspace\)")
    def test_metadata_package_path_resolves_inside_distribution(self):
        metadata = json.loads((ROOT / "compatibility.json").read_text(encoding="utf-8-sig"))
        path = (ROOT / metadata["package"]).resolve()
        self.assertTrue(path.is_relative_to(ROOT.resolve()))
        self.assertTrue(path.is_file())
        self.assertEqual(path.suffix, ".dpk")


@unittest.skipUnless(powershell_executable(), "PowerShell is not installed")
class BuildScriptFailureContracts(unittest.TestCase):
    def run_build(self, bds, platform="Win32"):
        return subprocess.run(
            [powershell_executable(), "-NoLogo", "-NoProfile", "-NonInteractive",
             "-ExecutionPolicy", "Bypass", "-File", str(SCRIPT), "-Bds", str(bds), "-Platform", platform],
            capture_output=True, text=True, errors="replace", timeout=30,
        )

    def assert_failed_with(self, result, message):
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn(message, result.stdout + result.stderr)

    def test_nonexistent_bds_fails_before_build(self):
        with tempfile.TemporaryDirectory() as directory:
            result = self.run_build(Path(directory) / "missing BDS")
            self.assert_failed_with(result, "BDS root not found")

    def test_cpp_only_install_requires_correct_delphi_compiler(self):
        with tempfile.TemporaryDirectory(prefix="BDS with spaces ") as directory:
            (Path(directory) / "include").mkdir()
            (Path(directory) / "include" / "ToolsAPI.hpp").write_text("// fixture, not vendor code")
            for platform, compiler in (("Win32", "dcc32.exe"), ("Win64", "dcc64.exe")):
                with self.subTest(platform=platform):
                    result = self.run_build(directory, platform)
                    self.assert_failed_with(result, "Delphi compiler not found")
                    self.assertIn(compiler, result.stdout + result.stderr)

    def test_compiler_without_platform_libraries_is_rejected_before_execution(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "bin").mkdir()
            (root / "bin" / "dcc32.exe").touch()  # Never executed: library validation comes first.
            self.assert_failed_with(self.run_build(root), "Delphi platform libraries not found")

    def test_platform_without_ota_libraries_is_rejected_before_execution(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "bin").mkdir()
            (root / "bin" / "dcc32.exe").touch()
            (root / "lib" / "Win32" / "release").mkdir(parents=True)
            self.assert_failed_with(self.run_build(root), "OTA designide.dcp not found")

    def test_unsupported_platform_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            self.assertNotEqual(self.run_build(directory, "Linux64").returncode, 0)


if __name__ == "__main__":
    unittest.main()
