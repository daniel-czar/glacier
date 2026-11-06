"""Synthetic package receipts and helper-cache validation; no app build."""

from __future__ import annotations

import json
import os
import pwd
import runpy
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from typing import Any, Callable, cast

PACKAGE: dict[str, Any] = runpy.run_path(
    str(Path(__file__).with_name("package_glacier.py")),
    run_name="glacier_package_tests",
)
HELPER_ROOT = Path(__file__).resolve().parents[1] / "Helpers/Pronunciation"
HELPER: dict[str, Any] = runpy.run_path(
    str(HELPER_ROOT / "build-runtime.py"), run_name="glacier_helper_tests"
)


def git(arguments: list[str], root: Path) -> None:
    subprocess.run(["git", *arguments], cwd=root, check=True, capture_output=True)


class PackagingTests(unittest.TestCase):
    def test_relocation_rejects_current_account_home_without_a_name_literal(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory(prefix="glacier-home-scan-") as temporary:
            stage = Path(temporary)
            runtime = stage / "runtime"
            runtime.mkdir()
            account_home = Path(pwd.getpwuid(os.getuid()).pw_dir).resolve()
            (runtime / "leak.txt").write_text(
                str(account_home / "private-fixture") + "/"
            )
            verify = cast(Callable[[Path], None], HELPER["verify_relocatable"])
            with self.assertRaisesRegex(RuntimeError, "Build-machine path remains"):
                verify(stage)

    def test_local_archive_verifier_rejects_stale_embedded_receipt_and_payload(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory(prefix="glacier-local-archive-") as temporary:
            root = Path(temporary)
            app = root / "Glacier.app"
            resources = app / "Contents/Resources"
            helper = resources / "Pronunciation"
            helper.mkdir(parents=True)
            helper_build = {"sourceFingerprint": "fixture-helper", "releaseGate": True}
            (helper / "helper-build-manifest.json").write_text(json.dumps(helper_build))
            (helper / "license-inventory.json").write_text("{}")
            PACKAGE["write_signed_helper_manifest"](helper, helper_build)
            (resources / "payload.txt").write_text("original")
            digest = cast(Callable[[Path], str], PACKAGE["sha256_file"])
            source: dict[str, object] = {
                "sourceRevision": "fixture-commit",
                "sourceTreeSHA256": "fixture-tree",
                "sourceCommitted": True,
                "sourceDirty": False,
            }
            embedded = {
                **source,
                "helperSourceFingerprint": "fixture-helper",
                "helperBuildManifestSHA256": digest(
                    helper / "helper-build-manifest.json"
                ),
                "helperReleaseGate": True,
            }
            embedded_path = resources / "SOURCE_RECEIPT.json"
            embedded_path.write_text(json.dumps(embedded))
            receipt = {
                **embedded,
                "configuration": "release",
                "distribution": "LOCAL-ONLY-NOT-NOTARIZED",
                "signing": "ad-hoc-local-development-only",
                "notarized": False,
                "pronunciation_bundled": True,
                "signedHelperManifestSHA256": digest(
                    helper / "helper-package-manifest.json"
                ),
                "sha256": {
                    path.relative_to(app).as_posix(): digest(path)
                    for path in app.rglob("*")
                    if path.is_file()
                },
            }
            receipt_path = root / "package-receipt.json"
            receipt_path.write_text(json.dumps(receipt))
            verify = cast(
                Callable[[Path, Path, dict[str, object]], None],
                PACKAGE["verify_local_candidate"],
            )
            verify(app, receipt_path, source)

            embedded_path.write_text(
                json.dumps({**embedded, "sourceRevision": "stale"})
            )
            with self.assertRaisesRegex(RuntimeError, "Embedded source receipt"):
                verify(app, receipt_path, source)
            embedded_path.write_text(json.dumps(embedded))

            (resources / "payload.txt").write_text("changed")
            with self.assertRaisesRegex(RuntimeError, "Packaged files"):
                verify(app, receipt_path, source)

    def test_source_receipt_handles_unborn_packed_and_dirty_revisions(self) -> None:
        with tempfile.TemporaryDirectory(prefix="glacier-source-receipt-") as temporary:
            root = Path(temporary)
            git(["init", "-q"], root)
            source = root / "main.swift"
            source.write_text("print(1)\n")
            state = PACKAGE["source_state"](root)
            self.assertIsNone(state["sourceRevision"])
            self.assertTrue(state["sourceDirty"])
            self.assertTrue(
                any("main.swift" in item for item in state["sourceStatusPorcelain"])
            )
            with self.assertRaisesRegex(RuntimeError, "clean committed"):
                PACKAGE["require_release_source"](state, debug=False)

            git(["add", "main.swift"], root)
            git(
                [
                    "-c",
                    "user.name=Fixture",
                    "-c",
                    "user.email=fixture@example.invalid",
                    "commit",
                    "-qm",
                    "fixture",
                ],
                root,
            )
            git(["pack-refs", "--all", "--prune"], root)
            clean = PACKAGE["source_state"](root)
            self.assertEqual(len(clean["sourceRevision"]), 40)
            self.assertFalse(clean["sourceDirty"])
            PACKAGE["require_release_source"](clean, debug=False)

            (root / "untracked.txt").write_text("new")
            dirty = PACKAGE["source_state"](root)
            self.assertTrue(dirty["sourceDirty"])
            self.assertNotEqual(dirty["sourceTreeSHA256"], clean["sourceTreeSHA256"])
            self.assertTrue(
                any("untracked.txt" in item for item in dirty["sourceStatusPorcelain"])
            )

    def test_helper_manifest_binds_source_runtime_notices_and_release_gate(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory(prefix="glacier-helper-receipt-") as temporary:
            output = Path(temporary)
            (output / "runtime/bin").mkdir(parents=True)
            binary = output / "runtime/bin/python3.12"
            binary.write_bytes(b"synthetic interpreter")
            native = output / "notices/native"
            native.mkdir(parents=True)
            for source in (HELPER_ROOT / "standalone-notices").glob("LICENSE.*.txt"):
                shutil.copy2(source, native / source.name)
            copied = sorted(p.relative_to(output).as_posix() for p in native.iterdir())
            inventory = {
                "python_build": "20260623",
                "python_version": "3.12.13",
                "native_components": {
                    "_ssl": {"notice_files": ["LICENSE.openssl-3.txt"]}
                },
                "distributions": {"pron": "GPL-3.0-only"},
                "copied_notices": copied,
            }
            (output / "license-inventory.json").write_text(json.dumps(inventory))
            inputs = HELPER["helper_input_hashes"]()
            HELPER["write_build_manifest"](output, release=False, source_inputs=inputs)
            validate = cast(
                Callable[..., dict[str, object]], HELPER["validate_build_manifest"]
            )
            validate.__globals__["verify_relocatable"] = lambda _: (
                None
            )  # fake binary only
            self.assertEqual(
                validate(output, release_required=False)["sourceFingerprint"],
                HELPER["helper_source_fingerprint"](inputs),
            )
            with self.assertRaisesRegex(RuntimeError, "release license gate"):
                validate(output, release_required=True)
            binary.write_bytes(b"tampered")
            with self.assertRaisesRegex(RuntimeError, "differ from its build receipt"):
                validate(output, release_required=False)
            binary.write_bytes(b"synthetic interpreter")
            (native / "LICENSE.openssl-3.txt").unlink()
            with self.assertRaisesRegex(RuntimeError, "notice texts"):
                validate(output, release_required=False)

    def test_signed_helper_receipt_detects_post_sign_changes(self) -> None:
        with tempfile.TemporaryDirectory(prefix="glacier-signed-helper-") as temporary:
            helper = Path(temporary)
            (helper / "runtime").mkdir()
            binary = helper / "runtime/python3"
            binary.write_bytes(b"synthetic signed bytes")
            (helper / "helper-build-manifest.json").write_text(
                json.dumps({"sourceFingerprint": "synthetic", "releaseGate": False})
            )
            (helper / "license-inventory.json").write_text("{}")
            PACKAGE["write_signed_helper_manifest"](
                helper, {"sourceFingerprint": "synthetic", "releaseGate": False}
            )
            PACKAGE["validate_signed_helper_manifest"](helper, release_required=False)
            with self.assertRaisesRegex(RuntimeError, "release license gate"):
                PACKAGE["validate_signed_helper_manifest"](
                    helper, release_required=True
                )
            binary.write_bytes(b"changed")
            with self.assertRaisesRegex(RuntimeError, "differ from package receipt"):
                PACKAGE["validate_signed_helper_manifest"](
                    helper, release_required=False
                )


if __name__ == "__main__":
    unittest.main()
