#!/usr/bin/python3
"""Mock acquisition and host interactions without sudo or production access."""

import argparse
import contextlib
import hashlib
import importlib.machinery
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
source = Path(__file__).resolve().parents[1] / "prepare-codex-env"
loader = importlib.machinery.SourceFileLoader("prepare_codex_env", str(source))
spec = importlib.util.spec_from_loader(loader.name, loader)
env = importlib.util.module_from_spec(spec)
loader.exec_module(env)


class ProvisioningTest(unittest.TestCase):
    def setUp(self):
        fixture = tempfile.TemporaryDirectory()
        self.addCleanup(fixture.cleanup)
        self.path = Path(fixture.name)
        output = io.StringIO()
        self.enterContext(contextlib.redirect_stdout(output))
        self.output = output
        self.args = argparse.Namespace(estimate_bytes=0, reserve_bytes=0, jobs=1)
        self.info = {"data": str(self.path), "databases": {}}
        umask = os.umask(0o077)
        self.addCleanup(os.umask, umask)

    def acquisition(self, *, fail=False):
        def command(argv, _error, **options):
            if argv[0].name == "psql":
                self.assertTrue(options["source"])
                self.assertIn("service=vpsdatabase", argv)
                return "1000"
            if argv[0].name == "pg_dump":
                self.assertTrue({"--no-password", "--format=custom", "--no-owner", "--no-acl"} <= set(argv))
                file = next(value.removeprefix("--file=") for value in argv[1:] if value.startswith("--file="))
                Path(file).write_bytes(b"synthetic custom archive")
                if fail:
                    raise env.Failure("pg_dump failed")
        return patch.object(env, "run", side_effect=command)

    def test_missing_executable_fails_before_state_query(self):
        with patch.object(env.os, "access", return_value=False), patch.object(env, "state") as state:
            with self.assertRaisesRegex(env.Failure, "Missing required executable"):
                env.main(env.arguments())
            state.assert_not_called()

    def test_shared_filesystem_capacity_is_aggregated(self):
        class Capacity:
            f_bavail = 500
            f_frsize = 1

        with patch.object(env.os, "statvfs", return_value=Capacity()):
            with self.assertRaisesRegex(env.Failure, "Insufficient free space"):
                env.capacity(20, (self.path, 300), (self.path, 200))

    def test_success_publishes_a_verified_reusable_bundle(self):
        with self.acquisition() as run, patch.object(env, "protected_path", side_effect=Path):
            archive = env.capture_dump(self.path, self.info, self.args)
            self.assertTrue(any("--list" in call.args[0] for call in run.call_args_list))
            reused = env.reuse_latest(self.path, {})
            self.assertEqual(archive, reused)
            self.assertEqual(archive[1], hashlib.sha256(archive[0].read_bytes()).hexdigest())
            self.assertFalse(list(self.path.glob(".incoming-*")))

    def snapshot(self, stamp, contents):
        directory = self.path / f"snapshot-{stamp}-fixture0"
        directory.mkdir(mode=0o700)
        (directory / "snapshot.dump").write_bytes(contents)
        digest = hashlib.sha256(contents).hexdigest()
        (directory / "snapshot.json").write_text(json.dumps({"bytes": len(contents), "sha256": digest}))
        return directory, digest

    def test_latest_verified_snapshot_skips_corrupt_and_unpublished_dumps(self):
        oldest, _ = self.snapshot("20260101T000000", b"old")
        latest, digest = self.snapshot("20260102T000000", b"verified")
        corrupt, _ = self.snapshot("20260103T000000", b"original")
        (corrupt / "snapshot.dump").write_bytes(b"corrupt")
        (self.path / ".incoming-abcdefgh").mkdir()
        with patch.object(env, "protected_path", side_effect=Path), patch.object(env, "archive_check") as check:
            archive, checksum, _, _ = env.reuse_latest(self.path, {})
        self.assertEqual(archive.parent, latest)
        self.assertNotEqual(archive.parent, oldest)
        self.assertEqual(checksum, digest)
        check.assert_called_once_with(archive, full=False)

    def test_interrupted_refresh_selects_matching_archive_without_production(self):
        interrupted, digest = self.snapshot("20260101T000000", b"interrupted")
        self.snapshot("20260102T000000", b"newer")
        baseline = dict(owner="postgres", tablespace="pg_default", bytes=10, sessions=0,
                        limit=0, connect=False, create=False, marker=None)
        ready = dict(version=170010, safe_role=True, data=str(self.path), databases={env.BASELINE: baseline})
        candidate = dict(baseline, marker=f"gpt-work baseline refresh v2; state=restoring; sha256={digest}")
        pending = dict(ready, databases={**ready["databases"], env.CANDIDATE: candidate})
        refresh = self.path / "installed-refresh"
        reset = self.path / "installed-reset"
        for source_file, installed in (("refresh_baseline.sh", refresh), ("reset-binancebot-work", reset)):
            shutil.copyfile(env.ROOT / source_file, installed)
            installed.chmod(0o700)
        with (
            patch.object(sys, "argv", ["prepare-codex-env", "--reuse-latest", "--dump-dir", str(self.path)]),
            patch.object(env, "state", side_effect=[pending, ready]),
            patch.object(env, "REFRESH", str(refresh)),
            patch.object(env, "RESET", str(reset)),
            patch.object(env, "protected_path", side_effect=Path),
            patch.object(env, "allowed"),
            patch.object(env, "capacity"),
            patch.object(env, "archive_check"),
            patch.object(env, "verify_work") as verify,
            patch.object(env, "capture_dump") as capture,
            patch.object(env, "run") as run,
        ):
            env.main(env.arguments())
        capture.assert_not_called()
        verify.assert_called_once()
        run.assert_called_once()
        command = run.call_args.args[0]
        self.assertEqual(command[-3:], ["--sha256", digest, "--stdin"])
        self.assertEqual(run.call_args.kwargs["stdin"].name, str(interrupted / "snapshot.dump"))

    def test_unknown_candidate_fails_without_attempting_restore(self):
        with patch.object(env, "reuse") as reuse:
            with self.assertRaisesRegex(env.Failure, "Unrecognized candidate"):
                env.reuse_latest(self.path, {env.CANDIDATE: {"marker": None}})
        reuse.assert_not_called()

    def test_missing_recovery_archive_does_not_restore_a_different_snapshot(self):
        self.snapshot("20260102T000000", b"newer")
        pending = {env.CANDIDATE: {
            "marker": f"gpt-work baseline refresh v2; state=restoring; sha256={'a' * 64}",
        }}
        with patch.object(env, "protected_path", side_effect=Path), patch.object(env, "reuse") as reuse:
            with self.assertRaisesRegex(env.Failure, "No verified snapshot matches"):
                env.reuse_latest(self.path, pending)
        reuse.assert_not_called()

    def test_db_refresh_dispatches_only_database_modes(self):
        entry = self.path / "db_refresh"
        shutil.copy(env.ROOT / "db_refresh", entry)
        backend = self.path / "prepare-codex-env"
        backend.write_text("#!/bin/bash\nprintf '%s\\n' \"$@\"\n")
        backend.chmod(0o700)
        for mode, expected in (("--full", "--refresh"), ("--restore-only", "--reuse-latest")):
            result = subprocess.run([entry, mode, "--dump-dir", "path with spaces", "--jobs", "2"],
                                    capture_output=True, text=True, check=True)
            self.assertEqual(result.stdout.splitlines(), [expected, "--dump-dir=path with spaces", "--jobs=2"])
        result = subprocess.run([entry, "--full", "--launch"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 64)
        with patch.object(sys, "argv", ["prepare-codex-env", "--refresh", "--launch"]):
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as exc:
                env.arguments()
        self.assertEqual(exc.exception.code, 2)

    def test_signal_handlers_keep_nohup_hangup_protection(self):
        script = """
import os, runpy, signal, sys
runpy.run_path(sys.argv[1])["install_signal_handlers"]()
os.kill(os.getpid(), signal.SIGHUP)
print("still running")
"""
        result = subprocess.run(["nohup", sys.executable, "-B", "-c", script, str(source)],
                                capture_output=True, text=True, check=True)
        self.assertEqual(result.stdout.strip(), "still running")

    def test_failed_dump_preserves_preexisting_bundle(self):
        with self.acquisition():
            archive = env.capture_dump(self.path, self.info, self.args)
        with self.acquisition(fail=True):
            with self.assertRaisesRegex(env.Failure, "pg_dump failed"):
                env.capture_dump(self.path, self.info, self.args)
        self.assertEqual(list(self.path.glob("snapshot-*")), [archive[0].parent])
        self.assertFalse(list(self.path.glob(".incoming-*")))

    def test_checksum_and_invalid_external_dump_rejected(self):
        archive = self.path / "external.dump"
        archive.write_bytes(b"truncated file")
        with patch.object(env, "protected_path", side_effect=Path):
            with self.assertRaisesRegex(env.Failure, "checksum mismatch"):
                env.reuse(archive, "a" * 64)
            with self.assertRaisesRegex(env.Failure, "corrupt or incomplete"):
                env.reuse(archive, hashlib.sha256(archive.read_bytes()).hexdigest())

    def test_replay_skips_the_expensive_helper_call(self):
        digest = "a" * 64
        self.info["databases"][env.BASELINE] = {
            "marker": f"gpt-work baseline refresh v2; state=complete; sha256={digest}",
        }
        with patch.object(env, "verify_work") as verify, patch.object(env, "run") as run:
            env.apply_dump(self.info, self.args, self.path / "snapshot.dump", digest, 10, 10)
            verify.assert_called_once()
            run.assert_not_called()

    def test_unrelated_credentials_are_not_passed_to_local_commands_or_logged(self):
        probe = [sys.executable, "-c", "import os; print(bool(os.getenv('BINANCE_GATEWAY_TOKEN')))"]
        with patch.dict(os.environ, {env.TOKEN: "fixture-secret", "PGPASSWORD": "fixture-password"}):
            self.assertEqual(env.run(probe, "probe failed", capture=True), "False")
            pg_probe = [sys.executable, "-c", "import os; print('PGPASSWORD' in os.environ)"]
            self.assertEqual(env.run(pg_probe, "probe failed", capture=True), "False")
            with self.assertRaisesRegex(env.Failure, "sanitized diagnostic"):
                env.run([sys.executable, "-c",
                         "import sys; sys.stderr.write('fixture-password'); sys.exit(1)"],
                        "sanitized diagnostic", source=True)
        self.assertNotIn("fixture-secret", self.output.getvalue())
        self.assertNotIn("fixture-password", self.output.getvalue())


if __name__ == "__main__":
    unittest.main()
