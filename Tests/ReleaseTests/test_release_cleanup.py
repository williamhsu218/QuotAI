"""Destructive-policy regression tests; synthetic apps only, no accounts/network."""
from pathlib import Path
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import zipfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "script"))
import finalize_release as finalize
from release_cleanup import APP_ID, Cleanup, SafetyError, digest, manifest


def app(path, build, version="3.0.5", payload=None, identifier=APP_ID):
    (path / "Contents/MacOS").mkdir(parents=True)
    (path / "Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": identifier, "CFBundleVersion": str(build),
        "CFBundleShortVersionString": version, "SUPublicEDKey": "A" * 43 + "=",
    }))
    (path / "Contents/MacOS/QuotAI").write_bytes(payload or f"signed-public-{build}".encode())
    return path


class Runtime:
    def __init__(self):
        self.active = set()
        self.unregistered = []

    def validate(self, path):
        if not path.is_dir():
            raise SafetyError("Missing retained application")

    def in_use(self, path):
        return path in self.active

    def unregister(self, path):
        assert path.exists(), "Unregister exact obsolete paths before removal"
        self.unregistered.append(path)


class CleanupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="release-retention-test-")
        self.base = Path(self.temp.name).resolve()
        self.project = self.base / "project"
        self.build = self.project / "build"
        self.installed = app(self.base / "Applications/QuotAI.app", 68)
        self.rollback = app(self.build / "InstallBackups/keep/QuotAI.app", 66, "3.0.4")
        self.downloads = self.base / "Downloads"
        self.downloads.mkdir()
        self.cache = self.build / "DerivedData"
        self.cache.mkdir()
        self.receipt = self.build / "qa/cleanup"
        self.receipt.mkdir(parents=True)
        self.runtime = Runtime()
        self.current_files, self.previous_files = manifest(self.installed), manifest(self.rollback)

    def tearDown(self):
        self.temp.cleanup()

    def engine(self):
        return Cleanup(project=self.project, build_roots=[self.build], cache_roots=[self.cache],
                       scan_roots=[self.downloads], receipt=self.receipt,
                       installed=self.installed, rollback=self.rollback, build=68,
                       current_files=self.current_files, previous_files=self.previous_files,
                       runtime=self.runtime)

    def run_cleanup(self):
        engine = self.engine()
        engine.plan()
        engine.apply()
        return engine

    def zip_app(self, name, source, extra=None):
        path = self.downloads / name
        with zipfile.ZipFile(path, "w") as package:
            for p in source.rglob("*"):
                if p.is_file(): package.write(p, "QuotAI.app/" + str(p.relative_to(source)))
            if extra: package.writestr(*extra)
        return path

    def test_exact_two_public_apps_retained_and_duplicates_removed(self):
        duplicate = app(self.downloads / "QuotAI.app", 68)
        older = app(self.build / "InstallBackups/old/QuotAI.app", 49, "2.1.10")
        engine = self.run_cleanup()
        self.assertFalse(duplicate.exists())
        self.assertFalse(older.exists())
        self.assertEqual(self.current_files, manifest(self.installed))
        self.assertEqual(self.previous_files, manifest(self.rollback))
        self.assertEqual({duplicate, older}, set(self.runtime.unregistered))
        self.assertGreater(engine.preserved_files, 0)

    def test_data_snapshots_logs_screenshots_and_fixture_archives_survive(self):
        files = [self.build / "InstallBackups/old/usage.sqlite", self.build / "qa/result.json",
                 self.build / "qa/screenshot.png", self.build / "qa/runtime.log",
                 self.build / "qa/fixture-state.tar.gz", self.build / "qa/source-before.tar"]
        for p in files: p.parent.mkdir(parents=True, exist_ok=True); p.write_bytes(b"retain verbatim")
        app(self.build / "InstallBackups/old/QuotAI.app", 49, "2.1.10")
        self.run_cleanup()
        self.assertTrue(all(p.read_bytes() == b"retain verbatim" for p in files))

    def test_cache_build_logs_and_test_results_recovered(self):
        log = self.cache / "Logs/Build/session.xcactivitylog"
        result = self.cache / "Logs/Test/Run.xcresult/Info.plist"
        for p in [log, result]: p.parent.mkdir(parents=True, exist_ok=True); p.write_bytes(b"test evidence")
        self.run_cleanup()
        recovered = self.receipt / "Recovered-Build-Records"
        self.assertEqual(2, len([p for p in recovered.rglob("*") if p.is_file()]))
        self.assertTrue(all(p.read_bytes() == b"test evidence" for p in recovered.rglob("*") if p.is_file()))

    def test_possible_database_in_cache_prevents_deletion(self):
        p = self.cache / "unexpected/account.sqlite"
        p.parent.mkdir(); p.write_bytes(b"live data")
        engine = self.run_cleanup()
        self.assertEqual(b"live data", p.read_bytes())
        self.assertTrue(engine.skipped)

    def test_cache_reports_and_fixture_inputs_outside_logs_are_preserved(self):
        records = [self.cache / "QA/run.json", self.cache / "preview.png", self.cache / "fixture-state.tar.gz"]
        for path in records:
            path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(b"original acceptance input")
        code = self.cache / "Products/Unrelated.app/Contents/Info.plist"
        code.parent.mkdir(parents=True); code.write_bytes(b"generated bundle resource")
        self.run_cleanup()
        recovered = [p for p in (self.receipt / "Recovered-Build-Records").rglob("*") if p.is_file()]
        self.assertEqual(3, len(recovered))
        self.assertTrue(all(p.read_bytes() == b"original acceptance input" for p in recovered))

    def test_active_cache_subtree_and_apps_are_not_touched(self):
        candidate = app(self.cache / "Products/QuotAI.app", 67)
        self.runtime.active.add(self.cache)
        engine = self.run_cleanup()
        self.assertTrue(candidate.exists())
        self.assertFalse(self.runtime.unregistered)
        self.assertTrue(engine.skipped)

    def test_active_app_is_deferred_without_stopping_it(self):
        candidate = app(self.downloads / "QuotAI.app", 67)
        self.runtime.active.add(candidate)
        engine = self.run_cleanup()
        self.assertTrue(candidate.exists())
        self.assertTrue(engine.skipped)

    def test_installed_manifest_mismatch_blocks_all_deletions(self):
        (self.installed / "Contents/MacOS/QuotAI").write_bytes(b"unexpected installed build")
        with self.assertRaises(SafetyError): self.engine().plan()
        self.assertTrue(self.cache.exists())

    def test_rollback_manifest_mismatch_blocks_all_deletions(self):
        (self.rollback / "Contents/MacOS/QuotAI").write_bytes(b"wrong rollback")
        with self.assertRaises(SafetyError): self.engine().plan()
        self.assertTrue(self.cache.exists())

    def test_changes_between_plan_and_apply_defer_before_removal(self):
        candidate = app(self.downloads / "QuotAI.app", 67)
        engine = self.engine(); engine.plan()
        (candidate / "Contents/MacOS/QuotAI").write_bytes(b"new development work")
        with self.assertRaises(SafetyError): engine.apply()
        self.assertTrue(self.cache.exists())
        self.assertTrue(candidate.exists())

    def test_active_state_change_between_plan_and_apply_blocks_all(self):
        candidate = app(self.downloads / "QuotAI.app", 67)
        engine = self.engine(); engine.plan(); self.runtime.active.add(candidate)
        with self.assertRaises(SafetyError): engine.apply()
        self.assertTrue(self.cache.exists())

    def test_symlink_does_not_escape_to_data(self):
        external = self.base / "real-data"; external.mkdir()
        (external / "important").write_bytes(b"untouched")
        (self.cache / "external").symlink_to(external, target_is_directory=True)
        self.run_cleanup()
        self.assertEqual(b"untouched", (external / "important").read_bytes())

    def test_symlinked_log_directory_blocks_before_deletion(self):
        external = self.base / "real-logs"; external.mkdir()
        (self.cache / "Logs").symlink_to(external, target_is_directory=True)
        engine = self.engine(); engine.plan()
        with self.assertRaises(SafetyError): engine.apply()
        self.assertTrue(self.cache.exists())

    def test_retained_path_symlink_is_rejected(self):
        alias = self.base / "alias.app"; alias.symlink_to(self.installed, target_is_directory=True)
        with self.assertRaises(SafetyError):
            Cleanup(project=self.project, build_roots=[], cache_roots=[], scan_roots=[], receipt=self.receipt,
                    installed=alias, rollback=self.rollback, current_files=self.current_files,
                    previous_files=self.previous_files, build=68, runtime=self.runtime)

    def test_newer_development_build_is_not_deleted(self):
        future = app(self.downloads / "QuotAI.app", 69)
        engine = self.run_cleanup()
        self.assertTrue(future.exists())
        self.assertTrue(engine.skipped)

    def test_newer_app_prevents_entire_cache_deletion(self):
        future = app(self.cache / "Products/QuotAI.app", 69)
        engine = self.run_cleanup()
        self.assertTrue(future.exists())
        self.assertTrue(engine.skipped)

    def test_missing_build_number_preserves_app_and_its_cache(self):
        candidates = [app(self.downloads / "QuotAI.app", 68),
                      app(self.cache / "Products/QuotAI.app", 68)]
        for candidate in candidates:
            path = candidate / "Contents/Info.plist"
            metadata = plistlib.loads(path.read_bytes())
            del metadata["CFBundleVersion"]
            path.write_bytes(plistlib.dumps(metadata))
        engine = self.run_cleanup()
        self.assertTrue(all(p.exists() for p in candidates))
        self.assertTrue(self.cache.exists())
        self.assertEqual(2, len(engine.skipped))

    def test_symlinked_build_root_is_not_followed(self):
        outside = self.base / "other-project"
        candidate = app(outside / "QuotAI.app", 67)
        alias = self.base / "linked-build"; alias.symlink_to(outside, target_is_directory=True)
        engine = Cleanup(project=self.project, build_roots=[alias], cache_roots=[], scan_roots=[],
                         receipt=self.receipt, installed=self.installed, rollback=self.rollback,
                         current_files=self.current_files, previous_files=self.previous_files,
                         build=68, runtime=self.runtime)
        engine.plan(); engine.apply()
        self.assertTrue(candidate.exists())

    def test_cache_below_linked_build_root_is_not_followed(self):
        outside = self.base / "external"
        candidate = app(outside / "DerivedData/Products/QuotAI.app", 67)
        alias = self.base / "linked-build"; alias.symlink_to(outside, target_is_directory=True)
        engine = Cleanup(project=self.project, build_roots=[alias], cache_roots=[alias / "DerivedData"],
                         scan_roots=[], receipt=self.receipt, installed=self.installed, rollback=self.rollback,
                         current_files=self.current_files, previous_files=self.previous_files,
                         build=68, runtime=self.runtime)
        engine.plan(); engine.apply()
        self.assertTrue(candidate.exists())
        self.assertTrue(engine.skipped)

    def test_installer_only_zip_removed_but_data_archive_retained(self):
        installer = self.zip_app("QuotAI-3.0.5-macos-universal.zip", self.installed)
        state = self.zip_app("QuotAI-backup.zip", self.installed)
        mixed = self.zip_app("QuotAI-archive.zip", self.installed, ("user-data.json", "important"))
        self.run_cleanup()
        self.assertFalse(installer.exists())
        self.assertTrue(state.exists())
        self.assertTrue(mixed.exists())

    def test_compiled_probe_removed_but_source_and_runtime_sdk_kept(self):
        binary = self.build / "qa/probe"; binary.write_bytes(bytes.fromhex("cffaedfe") + b"generated")
        source = self.build / "qa/probe.swift"; source.write_text("source")
        tool = self.build / "SparkleSDK/distribution/bin/probe"; tool.parent.mkdir(parents=True)
        tool.write_bytes(binary.read_bytes())
        self.run_cleanup()
        self.assertFalse(binary.exists())
        self.assertTrue(source.exists())
        self.assertTrue(tool.exists())

    def test_verified_duplicate_sdk_archive_removed_only_when_tools_match(self):
        sdk = self.build / "SparkleSDK"; (sdk / "distribution/bin").mkdir(parents=True)
        archive = sdk / "Sparkle-2.9.6.zip"
        with zipfile.ZipFile(archive, "w") as package:
            for tool in ["generate_keys", "sign_update", "generate_appcast"]:
                (sdk / "distribution/bin" / tool).write_bytes(b"retained signing tool")
                package.writestr("bin/" + tool, b"retained signing tool")
        self.run_cleanup()
        self.assertFalse(archive.exists())
        self.assertTrue((sdk / "distribution/bin/sign_update").exists())

    def test_dry_plan_does_not_delete(self):
        duplicate = app(self.downloads / "QuotAI.app", 68)
        engine = self.engine(); engine.plan()
        self.assertTrue(duplicate.exists())
        self.assertTrue(self.cache.exists())

    def test_second_cleanup_is_idempotent(self):
        self.run_cleanup()
        engine = self.engine(); self.assertEqual([], engine.plan()); engine.apply()

    def test_rollback_uses_previous_public_bytes_not_higher_test_build(self):
        app(self.build / "InstallBackups/local-test/QuotAI.app", 67, "3.0.4")
        with mock.patch.object(finalize.MacRuntime, "validate"):
            result = finalize.choose_rollback(self.project, self.rollback, self.previous_files, False)
        self.assertEqual(self.rollback, result)

    def test_missing_rollback_is_only_proposed_in_dry_run(self):
        previous = app(self.base / "published/QuotAI.app", 65, "3.0.3")
        result = finalize.choose_rollback(self.project, previous, manifest(previous), False)
        self.assertFalse(result.exists())

    def test_missing_rollback_is_copied_and_verified_before_cleaning(self):
        previous = app(self.base / "published/QuotAI.app", 65, "3.0.3")
        with mock.patch.object(finalize.MacRuntime, "validate"), mock.patch.object(finalize, "run", side_effect=lambda a: shutil.copytree(a[1], a[2])):
            result = finalize.choose_rollback(self.project, previous, manifest(previous), True)
        self.assertEqual(manifest(previous), manifest(result))

    def test_linked_backup_root_is_never_written_or_cleaned(self):
        outside = self.base / "external-backups"; outside.mkdir()
        shutil.rmtree(self.build / "InstallBackups")
        (self.build / "InstallBackups").symlink_to(outside, target_is_directory=True)
        previous = app(self.base / "published/QuotAI.app", 65, "3.0.3")
        with self.assertRaises(SafetyError):
            finalize.choose_rollback(self.project, previous, manifest(previous), True)
        self.assertEqual([], list(outside.iterdir()))

    def test_wrong_installed_version_cannot_start_network_or_cleanup(self):
        with mock.patch.object(finalize, "download") as download:
            with self.assertRaises(SafetyError):
                finalize.public_proof("3.0.6", self.project, self.installed, self.base, self.receipt)
            download.assert_not_called()
        self.assertTrue(self.cache.exists())

    def test_finalize_shell_mode_does_not_build_tag_or_publish(self):
        fake = self.base / "shell-project/script"; fake.mkdir(parents=True)
        shutil.copy2(ROOT / "script/verify_and_release.sh", fake / "verify_and_release.sh")
        (fake / "finalize_release.py").write_text("import sys\nprint('FINALIZED ' + ' '.join(sys.argv[1:]))\n")
        result = subprocess.run(["bash", str(fake / "verify_and_release.sh"), "3.0.5", "--finalize"], capture_output=True, text=True, check=True)
        self.assertEqual("FINALIZED 3.0.5 --apply", result.stdout.strip())


if __name__ == "__main__":
    unittest.main()
