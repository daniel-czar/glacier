#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Build and package a detached development app. Never installs or uses signing accounts."""

from __future__ import annotations

import argparse
import hashlib
import json
import plistlib
import runpy
import shutil
import subprocess
import tempfile
import uuid
from pathlib import Path
from typing import Any, Callable, cast

ROOT = Path(__file__).resolve().parents[1]
APP_ICON = ROOT / "Assets/GlacierAppIcon.icns"


def run(args: list[str], *, capture: bool = False) -> str:
    result = subprocess.run(
        args, cwd=ROOT, check=True, text=True, capture_output=capture
    )
    return result.stdout.strip() if capture else ""


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def source_state(root: Path) -> dict[str, object]:
    revision_run = subprocess.run(
        ["git", "rev-parse", "--verify", "HEAD"],
        cwd=root,
        capture_output=True,
        text=True,
        check=False,
    )
    revision = revision_run.stdout.strip() if revision_run.returncode == 0 else None
    status_run = subprocess.run(
        ["git", "status", "--porcelain=v1", "--untracked-files=all"],
        cwd=root,
        capture_output=True,
        text=True,
        check=True,
    )
    status = status_run.stdout.splitlines()
    listed = subprocess.run(
        ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
        cwd=root,
        capture_output=True,
        check=True,
    ).stdout
    paths = sorted(
        {
            Path(raw.decode("utf-8", errors="surrogateescape"))
            for raw in listed.split(b"\0")
            if raw
        }
    )
    files: dict[str, str] = {}
    for relative in paths:
        path = root / relative
        key = relative.as_posix()
        if path.is_symlink():
            files[key] = "symlink:" + str(path.readlink())
        elif path.is_file():
            files[key] = sha256_file(path)
        elif path.exists():
            files[key] = "directory-or-special"
        else:
            files[key] = "deleted"
    digest = hashlib.sha256(
        json.dumps(files, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()
    return {
        "sourceRevision": revision,
        "sourceCommitted": revision is not None,
        "sourceDirty": bool(status),
        "sourceStatusPorcelain": status,
        "sourceTreeSHA256": digest,
        "sourceFileCount": len(files),
    }


def require_release_source(state: dict[str, object], *, debug: bool) -> None:
    if not debug and (
        state["sourceCommitted"] is not True or state["sourceDirty"] is not False
    ):
        raise RuntimeError("Release-mode packaging requires clean committed source")


def helper_validator() -> Callable[..., dict[str, object]]:
    namespace: dict[str, Any] = runpy.run_path(
        str(ROOT / "Helpers/Pronunciation/build-runtime.py"),
        run_name="glacier_helper_validation",
    )
    return cast(Callable[..., dict[str, object]], namespace["validate_build_manifest"])


def ensure_helper_cache(
    *, release_required: bool, root: Path = ROOT
) -> tuple[Path, dict[str, object], bool]:
    cache = root / ".scratch/Pronunciation"
    cache.parent.mkdir(parents=True, exist_ok=True)
    validate = helper_validator()
    if cache.is_dir() and not cache.is_symlink():
        try:
            return cache, validate(cache, release_required=release_required), False
        except (OSError, ValueError, RuntimeError, KeyError, TypeError):
            pass
    candidate = cache.parent / f".Pronunciation-build-{uuid.uuid4().hex}"
    previous = cache.parent / f".Pronunciation-previous-{uuid.uuid4().hex}"
    try:
        command = [
            "uv",
            "run",
            "--no-project",
            "Helpers/Pronunciation/build-runtime.py",
            str(candidate),
        ]
        if release_required:
            command.append("--release")
        subprocess.run(command, cwd=root, check=True)
        manifest = validate(candidate, release_required=release_required)
        had_previous = cache.exists() or cache.is_symlink()
        if had_previous:
            cache.rename(previous)
        try:
            candidate.rename(cache)
        except Exception:
            if had_previous:
                previous.rename(cache)
            raise
        if had_previous:
            if previous.is_symlink() or not previous.is_dir():
                previous.unlink()
            else:
                shutil.rmtree(previous)
        return cache, manifest, True
    finally:
        if candidate.exists():
            shutil.rmtree(candidate)


def signed_helper_hashes(helper: Path) -> tuple[dict[str, str], dict[str, str]]:
    files: dict[str, str] = {}
    links: dict[str, str] = {}
    for path in helper.rglob("*"):
        relative = path.relative_to(helper).as_posix()
        if relative == "helper-package-manifest.json":
            continue
        if path.is_symlink():
            links[relative] = str(path.readlink())
        elif path.is_file():
            files[relative] = sha256_file(path)
    return files, links


def write_signed_helper_manifest(
    helper: Path, build_manifest: dict[str, object]
) -> None:
    files, links = signed_helper_hashes(helper)
    document: dict[str, object] = {
        "schemaVersion": 1,
        "sourceFingerprint": build_manifest["sourceFingerprint"],
        "releaseGate": build_manifest["releaseGate"],
        "unsignedBuildManifestSHA256": sha256_file(
            helper / "helper-build-manifest.json"
        ),
        "licenseInventorySHA256": sha256_file(helper / "license-inventory.json"),
        "signedFilesSHA256": files,
        "symlinkTargets": links,
    }
    (helper / "helper-package-manifest.json").write_text(
        json.dumps(document, indent=2, sort_keys=True) + "\n"
    )


def validate_signed_helper_manifest(
    helper: Path, *, release_required: bool
) -> dict[str, object]:
    raw: object = json.loads((helper / "helper-package-manifest.json").read_text())
    if not isinstance(raw, dict):
        raise RuntimeError("Signed helper receipt is invalid")
    document = cast(dict[str, object], raw)
    build_raw: object = json.loads((helper / "helper-build-manifest.json").read_text())
    if not isinstance(build_raw, dict):
        raise RuntimeError("Signed helper source receipt is invalid")
    build_manifest = cast(dict[str, object], build_raw)
    if (
        document.get("schemaVersion") != 1
        or document.get("sourceFingerprint") != build_manifest.get("sourceFingerprint")
        or document.get("releaseGate") != build_manifest.get("releaseGate")
    ):
        raise RuntimeError("Signed helper source association changed")
    files, links = signed_helper_hashes(helper)
    if (
        document.get("signedFilesSHA256") != files
        or document.get("symlinkTargets") != links
    ):
        raise RuntimeError("Signed helper files differ from package receipt")
    if document.get("unsignedBuildManifestSHA256") != sha256_file(
        helper / "helper-build-manifest.json"
    ):
        raise RuntimeError("Signed helper lost its source association")
    if document.get("licenseInventorySHA256") != sha256_file(
        helper / "license-inventory.json"
    ):
        raise RuntimeError("Signed helper notice inventory changed")
    if release_required and document.get("releaseGate") is not True:
        raise RuntimeError("Signed helper did not pass release license gate")
    return document


def macho(path: Path) -> bool:
    if not path.is_file() or path.is_symlink():
        return False
    with path.open("rb") as stream:
        return stream.read(4) in {
            b"\xcf\xfa\xed\xfe",
            b"\xce\xfa\xed\xfe",
            b"\xfe\xed\xfa\xcf",
            b"\xfe\xed\xfa\xce",
            b"\xca\xfe\xba\xbe",
            b"\xbe\xba\xfe\xca",
        }


def verify_local_candidate(
    app: Path, receipt_path: Path, source: dict[str, object]
) -> None:
    """Bind an archived local app to its clean source and complete file inventory."""
    raw: object = json.loads(receipt_path.read_text())
    if not isinstance(raw, dict):
        raise RuntimeError("Local package receipt is invalid")
    receipt = cast(dict[str, object], raw)
    if (
        source["sourceCommitted"] is not True
        or source["sourceDirty"] is not False
        or receipt.get("sourceRevision") != source["sourceRevision"]
        or receipt.get("sourceTreeSHA256") != source["sourceTreeSHA256"]
        or receipt.get("sourceDirty") is not False
        or receipt.get("configuration") != "release"
        or receipt.get("distribution") != "LOCAL-ONLY-NOT-NOTARIZED"
        or receipt.get("signing") != "ad-hoc-local-development-only"
        or receipt.get("notarized") is not False
        or receipt.get("pronunciation_bundled") is not True
        or receipt.get("helperReleaseGate") is not True
    ):
        raise RuntimeError("Local package does not match clean release-mode source")

    resources = app / "Contents/Resources"
    embedded_raw: object = json.loads((resources / "SOURCE_RECEIPT.json").read_text())
    if not isinstance(embedded_raw, dict):
        raise RuntimeError("Embedded source receipt is invalid")
    embedded = cast(dict[str, object], embedded_raw)
    for key in (
        "sourceRevision",
        "sourceTreeSHA256",
        "sourceCommitted",
        "sourceDirty",
        "helperSourceFingerprint",
        "helperBuildManifestSHA256",
        "helperReleaseGate",
    ):
        if embedded.get(key) != receipt.get(key):
            raise RuntimeError(f"Embedded source receipt differs: {key}")

    helper = resources / "Pronunciation"
    if sha256_file(helper / "helper-build-manifest.json") != receipt.get(
        "helperBuildManifestSHA256"
    ) or sha256_file(helper / "helper-package-manifest.json") != receipt.get(
        "signedHelperManifestSHA256"
    ):
        raise RuntimeError("Bundled helper manifest differs from package receipt")
    helper_manifest = validate_signed_helper_manifest(helper, release_required=True)
    if helper_manifest.get("sourceFingerprint") != receipt.get(
        "helperSourceFingerprint"
    ):
        raise RuntimeError("Bundled helper source differs from package receipt")
    expected_helper_links = helper_manifest.get("symlinkTargets")
    if not isinstance(expected_helper_links, dict):
        raise RuntimeError("Bundled helper symlink inventory is invalid")
    expected_links = {
        f"Contents/Resources/Pronunciation/{relative}": target
        for relative, target in expected_helper_links.items()
    }
    actual_links: dict[str, str] = {}
    actual_hashes: dict[str, str] = {}
    for path in app.rglob("*"):
        relative = path.relative_to(app).as_posix()
        if path.is_symlink():
            target = str(path.readlink())
            if Path(target).is_absolute() or not (
                path.parent / target
            ).resolve().is_relative_to(app.resolve()):
                raise RuntimeError(f"Packaged symlink escapes app: {relative}")
            actual_links[relative] = target
        elif path.is_file():
            actual_hashes[relative] = sha256_file(path)
    if actual_links != expected_links:
        raise RuntimeError("Packaged symlinks differ from helper receipt")
    if actual_hashes != receipt.get("sha256"):
        raise RuntimeError("Packaged files differ from package receipt")


def package(*, debug: bool, without_pronunciation: bool) -> Path:
    if without_pronunciation and not debug:
        raise RuntimeError(
            "A release-mode package must include the pronunciation helper"
        )
    initial_source = source_state(ROOT)
    require_release_source(initial_source, debug=debug)
    helper: Path | None = None
    helper_manifest: dict[str, object] | None = None
    helper_rebuilt = False
    if not without_pronunciation:
        helper, helper_manifest, helper_rebuilt = ensure_helper_cache(
            release_required=not debug
        )
    configuration = "debug" if debug else "release"
    scratch = ".build" if debug else ".build-release"
    common = [
        "--configuration",
        configuration,
        "--scratch-path",
        scratch,
        "--disable-index-store",
    ]
    run(
        [
            "swift",
            "build",
            "--product",
            "glacier",
            *common,
            "-j",
            "4",
            "-Xswiftc",
            "-strict-concurrency=complete",
        ]
    )
    binaries = Path(run(["swift", "build", *common, "--show-bin-path"], capture=True))
    output = ROOT / "dist"
    output.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="glacier-stage-", dir=output) as temporary:
        app = Path(temporary) / "Glacier.app"
        contents = app / "Contents"
        executable_dir = contents / "MacOS"
        resources = contents / "Resources"
        executable_dir.mkdir(parents=True)
        resources.mkdir()
        shutil.copy2(binaries / "glacier", executable_dir / "glacier")
        for resource in binaries.glob("*.bundle"):
            shutil.copytree(resource, resources / resource.name)
        for resource in binaries.glob("*.resources"):
            shutil.copytree(resource, resources / resource.name)
        shutil.copy2(ROOT / "LICENSE", resources / "LICENSE")
        if (ROOT / "THIRD_PARTY_NOTICES.md").exists():
            shutil.copy2(
                ROOT / "THIRD_PARTY_NOTICES.md", resources / "THIRD_PARTY_NOTICES.md"
            )
        shutil.copy2(APP_ICON, resources / APP_ICON.name)
        if helper is not None:
            shutil.copytree(helper, resources / "Pronunciation", symlinks=True)
            helper_validator()(resources / "Pronunciation", release_required=not debug)
        source_link: dict[str, object] = {
            "sourceRevision": initial_source["sourceRevision"],
            "sourceCommitted": initial_source["sourceCommitted"],
            "sourceDirty": initial_source["sourceDirty"],
            "sourceTreeSHA256": initial_source["sourceTreeSHA256"],
            "helperSourceFingerprint": helper_manifest.get("sourceFingerprint")
            if helper_manifest
            else None,
            "helperBuildManifestSHA256": sha256_file(
                resources / "Pronunciation/helper-build-manifest.json"
            )
            if helper is not None
            else None,
            "helperReleaseGate": helper_manifest.get("releaseGate")
            if helper_manifest
            else None,
        }
        (resources / "SOURCE_RECEIPT.json").write_text(
            json.dumps(source_link, indent=2, sort_keys=True) + "\n"
        )
        info: dict[str, object] = {
            "CFBundleIdentifier": "local.Glacier.Development",
            "CFBundleName": "Glacier",
            "CFBundleDisplayName": "Glacier",
            "CFBundleIconFile": APP_ICON.name,
            "CFBundleExecutable": "glacier",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "0.1.0",
            "CFBundleVersion": "1",
            "LSMinimumSystemVersion": "14.4",
            "LSUIElement": True,
            "NSPrincipalClass": "NSApplication",
            "NSAppleEventsUsageDescription": "Glacier uses Finder and your chosen terminal when you invoke their commands.",
            "NSLocationWhenInUseUsageDescription": "Weather can use your location when you open it. You can enter a place instead.",
        }
        (contents / "Info.plist").write_bytes(plistlib.dumps(info))
        # Sign leaf Mach-O files and resource bundles before the outer app.
        for binary in sorted(
            (p for p in app.rglob("*") if macho(p)),
            key=lambda p: len(p.parts),
            reverse=True,
        ):
            run(["codesign", "--force", "--sign", "-", "--timestamp=none", str(binary)])
        for bundle in sorted(
            resources.rglob("*.bundle"), key=lambda p: len(p.parts), reverse=True
        ):
            run(["codesign", "--force", "--sign", "-", "--timestamp=none", str(bundle)])
        if helper_manifest is not None:
            write_signed_helper_manifest(resources / "Pronunciation", helper_manifest)
        run(["codesign", "--force", "--sign", "-", "--timestamp=none", str(app)])
        run(["codesign", "--verify", "--deep", "--strict", "--verbose=2", str(app)])
        if helper_manifest is not None:
            validate_signed_helper_manifest(
                resources / "Pronunciation", release_required=not debug
            )
        if json.loads((resources / "SOURCE_RECEIPT.json").read_text()) != source_link:
            raise RuntimeError("Signed app source receipt changed")
        with tempfile.TemporaryDirectory(prefix="glacier-packaged-smoke-") as smoke:
            print(
                run(
                    [
                        str(app / "Contents/MacOS/glacier"),
                        "--headless-check",
                        "--test-root",
                        smoke,
                    ],
                    capture=True,
                )
            )
        final_source = source_state(ROOT)
        require_release_source(final_source, debug=debug)
        if (
            final_source["sourceTreeSHA256"] != initial_source["sourceTreeSHA256"]
            or final_source["sourceRevision"] != initial_source["sourceRevision"]
        ):
            raise RuntimeError(
                "Source changed during packaging; bundle was not promoted"
            )
        # Preserve every previous local bundle; never remove an older receipt.
        destination = output / "Glacier.app"
        previous: Path | None = None
        if destination.exists():
            previous = output / f"Glacier.previous-{uuid.uuid4().hex}.app"
            destination.rename(previous)
        try:
            app.rename(destination)
        except Exception:
            if previous is not None:
                previous.rename(destination)
            raise
        if previous is not None and (output / "package-receipt.json").is_file():
            shutil.copy2(
                output / "package-receipt.json",
                output / f"{previous.name}.receipt.json",
            )
    receipt: dict[str, object] = {
        "configuration": configuration,
        "bundle": str(destination),
        "signing": "ad-hoc-local-development-only",
        "notarized": False,
        "distribution": "LOCAL-ONLY-NOT-NOTARIZED",
        "pronunciation_bundled": not without_pronunciation,
        **initial_source,
        "helperCacheRebuilt": helper_rebuilt,
        "helperSourceFingerprint": helper_manifest.get("sourceFingerprint")
        if helper_manifest
        else None,
        "helperReleaseGate": helper_manifest.get("releaseGate")
        if helper_manifest
        else None,
        "helperBuildManifestSHA256": sha256_file(
            destination / "Contents/Resources/Pronunciation/helper-build-manifest.json"
        )
        if helper is not None
        else None,
        "signedHelperManifestSHA256": sha256_file(
            destination
            / "Contents/Resources/Pronunciation/helper-package-manifest.json"
        )
        if helper is not None
        else None,
        "sha256": {
            str(p.relative_to(destination)): sha256_file(p)
            for p in destination.rglob("*")
            if p.is_file() and not p.is_symlink()
        },
    }
    (output / "package-receipt.json").write_text(
        json.dumps(receipt, indent=2, sort_keys=True) + "\n"
    )
    return destination


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--debug", action="store_true")
    parser.add_argument("--verify-local-candidate", action="store_true")
    parser.add_argument(
        "--without-pronunciation",
        action="store_true",
        help="Development-only partial package",
    )
    args = parser.parse_args()
    if args.verify_local_candidate:
        verify_local_candidate(
            ROOT / "dist/Glacier.app",
            ROOT / "dist/package-receipt.json",
            source_state(ROOT),
        )
        print("Local candidate matches clean source and package receipt")
        return
    print(package(debug=args.debug, without_pronunciation=args.without_pronunciation))


if __name__ == "__main__":
    main()
