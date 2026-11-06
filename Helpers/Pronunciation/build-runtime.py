#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Stage a relocatable app-owned Python/runtime; never use Homebrew or a source venv.

Usage: uv run Helpers/Pronunciation/build-runtime.py OUTPUT [--release]
This downloads a pinned uv-managed standalone Python during *packaging* only.
It does not run pronunciation lookups or access live app configuration.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os
import pwd
import shutil
import subprocess
import tempfile
from pathlib import Path
from typing import Sequence, cast

PYTHON_VERSION = "3.12.13"
PYTHON_BUILD = "20260623"
PYTHON_METADATA_SHA256 = (
    "ad73684b0c9fd9511280f8785a500bf6b837820944a92e5264fc9d9f240ffea2"
)
PYTHON_FULL_ARCHIVE_SHA256 = (
    "ce5a2d552077d869f69dc25d834c2fe4d036f9d78e770fb5d916273db802cabc"
)
BUILD_MANIFEST = "helper-build-manifest.json"


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def helper_input_hashes() -> dict[str, str]:
    root = Path(__file__).resolve().parent
    source = root / "source"
    required = [
        root / "build-runtime.py",
        root / "provenance.json",
        source / "pyproject.toml",
        source / "uv.lock",
        source / "LICENSE",
        root / "test_offline.py",
    ]
    for folder in (source / "src", source / "tests", root / "standalone-notices"):
        for path in folder.rglob("*"):
            if path.is_symlink():
                raise RuntimeError(
                    f"Helper source contains a symlink: {path.relative_to(root)}"
                )
            if path.is_file():
                required.append(path)
    result: dict[str, str] = {}
    for path in sorted(set(required)):
        if not path.is_file() or path.is_symlink():
            raise RuntimeError(
                f"Required helper input missing or symlinked: {path.name}"
            )
        if (
            any(
                part
                in {"__pycache__", ".venv", ".scratch", ".pytest_cache", ".mypy_cache"}
                for part in path.relative_to(root).parts
            )
            or path.suffix == ".pyc"
        ):
            continue
        result[path.relative_to(root).as_posix()] = sha256_file(path)
    return result


def helper_source_fingerprint(inputs: dict[str, str] | None = None) -> str:
    payload = json.dumps(
        inputs if inputs is not None else helper_input_hashes(),
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def artifact_hashes(output: Path) -> tuple[dict[str, str], dict[str, str]]:
    regular: dict[str, str] = {}
    links: dict[str, str] = {}
    roots = [output / "runtime", output / "notices", output / "license-inventory.json"]
    for root in roots:
        if not root.exists():
            raise RuntimeError(f"Helper artifact is incomplete: {root.name}")
        paths = [root] if root.is_file() else root.rglob("*")
        for path in paths:
            relative = path.relative_to(output).as_posix()
            if path.is_symlink():
                links[relative] = str(path.readlink())
            elif path.is_file():
                regular[relative] = sha256_file(path)
    return regular, links


def validate_notice_inventory(
    output: Path, *, release_required: bool
) -> dict[str, object]:
    path = output / "license-inventory.json"
    raw: object = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(raw, dict):
        raise RuntimeError("Helper license inventory is invalid")
    inventory = cast(dict[str, object], raw)
    if (
        inventory.get("python_build") != PYTHON_BUILD
        or inventory.get("python_version") != PYTHON_VERSION
    ):
        raise RuntimeError("Helper native runtime inventory is stale")
    native = inventory.get("native_components")
    if not isinstance(native, dict) or not native:
        raise RuntimeError("Helper native components are not inventoried")
    notice_source = Path(__file__).resolve().parent / "standalone-notices"
    expected_native = {
        p.name: sha256_file(p) for p in notice_source.glob("LICENSE.*.txt")
    }
    staged_native = output / "notices/native"
    actual_native = {
        p.name: sha256_file(p) for p in staged_native.glob("LICENSE.*.txt")
    }
    if expected_native != actual_native:
        raise RuntimeError("Helper native notice texts are missing or stale")
    copied = inventory.get("copied_notices")
    actual_copied = sorted(
        p.relative_to(output).as_posix()
        for p in (output / "notices").rglob("*")
        if p.is_file()
    )
    if not isinstance(copied, list) or sorted(copied) != actual_copied:
        raise RuntimeError("Helper copied notice inventory does not match files")
    distributions = inventory.get("distributions")
    if release_required and (
        not isinstance(distributions, dict)
        or any(value == "UNRESOLVED" for value in distributions.values())
    ):
        raise RuntimeError("Helper dependency licenses are unresolved")
    return inventory


def write_build_manifest(
    output: Path, *, release: bool, source_inputs: dict[str, str]
) -> None:
    if helper_input_hashes() != source_inputs:
        raise RuntimeError("Helper source changed while the runtime was being built")
    validate_notice_inventory(output, release_required=release)
    files, links = artifact_hashes(output)
    manifest: dict[str, object] = {
        "schemaVersion": 1,
        "sourceFingerprint": helper_source_fingerprint(source_inputs),
        "sourceFilesSHA256": source_inputs,
        "runtimeAndNoticesSHA256": files,
        "symlinkTargets": links,
        "releaseGate": release,
    }
    (output / BUILD_MANIFEST).write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )


def validate_build_manifest(
    output: Path, *, release_required: bool
) -> dict[str, object]:
    raw: object = json.loads((output / BUILD_MANIFEST).read_text(encoding="utf-8"))
    if not isinstance(raw, dict):
        raise RuntimeError("Helper build manifest is invalid")
    manifest = cast(dict[str, object], raw)
    inputs = helper_input_hashes()
    if manifest.get("schemaVersion") != 1 or manifest.get(
        "sourceFingerprint"
    ) != helper_source_fingerprint(inputs):
        raise RuntimeError("Helper cache was built from different source")
    if type(manifest.get("releaseGate")) is not bool:
        raise RuntimeError("Helper release gate marker is invalid")
    if manifest.get("sourceFilesSHA256") != inputs:
        raise RuntimeError("Helper source file receipt differs")
    if release_required and manifest.get("releaseGate") is not True:
        raise RuntimeError("Helper cache has not passed the release license gate")
    validate_notice_inventory(output, release_required=release_required)
    files, links = artifact_hashes(output)
    if (
        manifest.get("runtimeAndNoticesSHA256") != files
        or manifest.get("symlinkTargets") != links
    ):
        raise RuntimeError("Helper cache files differ from its build receipt")
    verify_relocatable(output)
    return manifest


def run(arguments: Sequence[str], *, cwd: Path, environment: dict[str, str]) -> None:
    subprocess.run(list(arguments), cwd=cwd, env=environment, check=True)


def contained(root: Path, child: Path) -> bool:
    return child.resolve().is_relative_to(root.resolve())


def find_interpreter(managed: Path) -> Path:
    matches = sorted(managed.rglob("bin/python3.12"))
    if len(matches) != 1 or not contained(managed, matches[0]):
        raise RuntimeError("A unique uv-managed Python 3.12 was not staged")
    return matches[0]


def dependency_licenses(
    python: Path, *, cwd: Path, environment: dict[str, str]
) -> dict[str, str]:
    command = (
        "import importlib.metadata as m, json; "
        "print(json.dumps({(d.metadata.get('Name') or 'UNKNOWN'): "
        "(d.metadata.get('License-Expression') or d.metadata.get('License') or 'UNRESOLVED') "
        "for d in m.distributions()}))"
    )
    result = subprocess.run(
        [str(python), "-B", "-I", "-c", command],
        cwd=cwd,
        env=environment,
        check=True,
        capture_output=True,
        text=True,
    )
    decoded: object = json.loads(result.stdout)
    if not isinstance(decoded, dict) or not all(
        isinstance(key, str) and isinstance(value, str)
        for key, value in decoded.items()
    ):
        raise RuntimeError("Invalid installed package metadata")
    return cast(dict[str, str], decoded)


def remove_build_machine_metadata(runtime: Path) -> None:
    # The app invokes `python3 -I -m pron.cli`; installer-generated wrappers
    # embed the staging interpreter path and are never needed in the bundle.
    bin_dir = runtime / "bin"
    for path in bin_dir.iterdir():
        if path.name not in {"python", "python3", "python3.12"}:
            path.unlink()
    for direct_url in runtime.rglob("direct_url.json"):
        record = direct_url.parent / "RECORD"
        if record.is_file():
            with record.open(newline="", encoding="utf-8") as stream:
                rows = list(csv.reader(stream))
            kept = [
                row
                for row in rows
                if not row or not row[0].endswith("/direct_url.json")
            ]
            with record.open("w", newline="", encoding="utf-8") as stream:
                csv.writer(stream).writerows(kept)
        direct_url.unlink()
    # .pyc code objects may retain the temporary build path as co_filename.
    for compiled in runtime.rglob("*.pyc"):
        compiled.unlink()
    for cache in sorted(
        runtime.rglob("__pycache__"), key=lambda path: len(path.parts), reverse=True
    ):
        if not any(cache.iterdir()):
            cache.rmdir()


def repair_managed_prefix(runtime: Path, previous_prefix: Path) -> None:
    # uv's standalone interpreter rewrites sysconfig build variables and its
    # libpython install name to the staging prefix. Runtime code must resolve
    # its own location after the app is moved to another Mac or folder.
    marker = "__GLACIER_RUNTIME_PREFIX__"
    sysconfig_files = list((runtime / "lib/python3.12").glob("_sysconfigdata*.py"))
    if not sysconfig_files:
        raise RuntimeError("Managed Python sysconfig data is missing")
    for path in sysconfig_files:
        content = path.read_text(encoding="utf-8")
        if str(previous_prefix) not in content:
            raise RuntimeError("Managed Python prefix was not found in sysconfig data")
        content = content.replace(str(previous_prefix), marker)
        content += (
            "\n# Glacier bundle relocation: resolve install variables at import time.\n"
            "from pathlib import Path as _GlacierPath\n"
            "_glacier_runtime_prefix = str(_GlacierPath(__file__).resolve().parents[2])\n"
            "build_time_vars = {key: value.replace('"
            + marker
            + "', _glacier_runtime_prefix) if isinstance(value, str) else value "
            "for key, value in build_time_vars.items()}\n"
        )
        path.write_text(content, encoding="utf-8")
    dylib = runtime / "lib/libpython3.12.dylib"
    if dylib.is_file():
        run(
            ["install_name_tool", "-id", "@rpath/libpython3.12.dylib", str(dylib)],
            cwd=runtime,
            environment={"PATH": "/usr/bin:/bin"},
        )


def record_notices(stage: Path, licenses: dict[str, str], source: Path) -> None:
    runtime = stage / "runtime"
    python_license = runtime / "lib/python3.12/LICENSE.txt"
    data_license = runtime / "lib/python3.12/site-packages/cmudict/data/LICENSE"
    helper_license = source / "LICENSE"
    standalone_notices = Path(__file__).resolve().parent / "standalone-notices"
    metadata_path = standalone_notices / "PYTHON.json"
    if hashlib.sha256(metadata_path.read_bytes()).hexdigest() != PYTHON_METADATA_SHA256:
        raise RuntimeError("Pinned standalone Python license metadata changed")
    raw_metadata: object = json.loads(metadata_path.read_text(encoding="utf-8"))
    if not isinstance(raw_metadata, dict):
        raise RuntimeError("Standalone Python license metadata is malformed")
    metadata = cast(dict[str, object], raw_metadata)
    if (
        metadata.get("python_version") != PYTHON_VERSION
        or metadata.get("target_triple") != "aarch64-apple-darwin"
    ):
        raise RuntimeError("Standalone Python license metadata does not match runtime")
    build_info = metadata.get("build_info")
    if not isinstance(build_info, dict) or not isinstance(
        build_info.get("extensions"), dict
    ):
        raise RuntimeError("Standalone Python extension license metadata is missing")
    extensions = cast(dict[str, list[dict[str, object]]], build_info["extensions"])
    native_components: dict[str, dict[str, object]] = {}
    system_license_not_bundled: list[str] = []
    for name, variants in extensions.items():
        for variant in variants:
            paths = variant.get("license_paths", [])
            links = variant.get("links", [])
            if not isinstance(paths, list) or not isinstance(links, list):
                raise RuntimeError("Malformed standalone Python license references")
            system_only = bool(links) and all(
                isinstance(link, dict) and (link.get("system") or link.get("framework"))
                for link in links
            )
            copied: list[str] = []
            for raw in paths:
                if not isinstance(raw, str) or not raw.startswith("licenses/LICENSE."):
                    raise RuntimeError("Invalid native license path")
                license_file = standalone_notices / Path(raw).name
                if not license_file.is_file():
                    if not system_only:
                        raise RuntimeError(
                            f"Bundled native license missing for {name}: {raw}"
                        )
                    system_license_not_bundled.append(f"{name}: {raw}")
                    continue
                copied.append(Path(raw).name)
            if copied:
                native_components[name] = {
                    "licenses": variant.get("licenses", []),
                    "notice_files": copied,
                }
    for required in (python_license, data_license, helper_license):
        if not required.is_file():
            raise RuntimeError(
                f"Required runtime/data license missing: {required.name}"
            )
    notices = stage / "notices"
    notices.mkdir()
    native_notices = notices / "native"
    native_notices.mkdir()
    for license_file in sorted(standalone_notices.glob("LICENSE.*.txt")):
        shutil.copy2(license_file, native_notices / license_file.name)
    shutil.copy2(python_license, notices / "PYTHON-LICENSE.txt")
    shutil.copy2(data_license, notices / "CMUDICT-DATA-LICENSE.txt")
    shutil.copy2(helper_license, notices / "GLACIER-PRON-LICENSE.txt")
    found = sorted(
        str(path.relative_to(stage))
        for path in runtime.rglob("*")
        if path.is_file()
        and any(
            marker in path.name.lower() for marker in ("license", "copying", "notice")
        )
    )
    inventory = {
        "python_version": PYTHON_VERSION,
        "python_build": PYTHON_BUILD,
        "standalone_full_archive_sha256": PYTHON_FULL_ARCHIVE_SHA256,
        "standalone_metadata_sha256": PYTHON_METADATA_SHA256,
        "native_components": native_components,
        "system_license_not_bundled": system_license_not_bundled,
        "distributions": licenses,
        "runtime_notice_paths": found,
        "copied_notices": sorted(
            str(path.relative_to(stage))
            for path in notices.rglob("*")
            if path.is_file()
        ),
    }
    (stage / "license-inventory.json").write_text(
        json.dumps(inventory, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )


def verify_relocatable(stage: Path) -> None:
    runtime = stage / "runtime"
    for path in stage.rglob("*"):
        if path.is_symlink() and not contained(stage, path):
            raise RuntimeError(
                f"Bundle symlink resolves outside output: {path.relative_to(stage)}"
            )
    account_home = Path(pwd.getpwuid(os.getuid()).pw_dir).resolve().as_posix().encode()
    forbidden = (
        b"file:///Users/",
        account_home + b"/",
        b"/opt/homebrew/",
        b"glacier-pron-stage-",
    )
    for path in runtime.rglob("*"):
        if not path.is_file() or path.is_symlink():
            continue
        if path.suffix == ".pyc":
            raise RuntimeError(
                f"Compiled Python cache remains in {path.relative_to(stage)}"
            )
        payload = path.read_bytes()
        if any(marker in payload for marker in forbidden):
            raise RuntimeError(
                f"Build-machine path remains in {path.relative_to(stage)}"
            )
    native = (
        [runtime / "bin/python3.12"]
        + list(runtime.rglob("*.so"))
        + list(runtime.rglob("*.dylib"))
    )
    for binary in native:
        load_commands = subprocess.run(
            ["otool", "-l", str(binary)], check=True, capture_output=True, text=True
        ).stdout.splitlines()
        rpaths: list[Path] = []
        for index, line in enumerate(load_commands):
            if line.strip() != "cmd LC_RPATH" or index + 2 >= len(load_commands):
                continue
            value = (
                load_commands[index + 2].strip().removeprefix("path ").split(" (", 1)[0]
            )
            if value.startswith("@loader_path/"):
                rpaths.append(
                    (binary.parent / value.removeprefix("@loader_path/")).resolve()
                )
            elif value.startswith("@executable_path/"):
                rpaths.append(
                    (
                        runtime / "bin" / value.removeprefix("@executable_path/")
                    ).resolve()
                )
            elif value.startswith("/"):
                rpaths.append(Path(value).resolve())
            else:
                raise RuntimeError(
                    f"Unsupported Mach-O rpath in {binary.relative_to(stage)}: {value}"
                )
        if any(not contained(stage, path) for path in rpaths):
            raise RuntimeError(f"External Mach-O rpath in {binary.relative_to(stage)}")
        output = subprocess.run(
            ["otool", "-L", str(binary)], check=True, capture_output=True, text=True
        ).stdout
        for line in output.splitlines()[1:]:
            dependency = line.strip().split(" (", 1)[0]
            if dependency.startswith(("/usr/lib/", "/System/Library/")):
                continue
            if dependency.startswith("@rpath/"):
                if dependency.removeprefix("@rpath/") == binary.name:
                    continue  # this dylib's own install name
                if any(
                    (base / dependency.removeprefix("@rpath/")).is_file()
                    for base in rpaths
                ):
                    continue
            if dependency.startswith("@loader_path/"):
                candidate = binary.parent / dependency.removeprefix("@loader_path/")
                if candidate.is_file() and contained(stage, candidate):
                    continue
            if dependency.startswith("@executable_path/"):
                candidate = (
                    runtime / "bin" / dependency.removeprefix("@executable_path/")
                )
                if candidate.is_file() and contained(stage, candidate):
                    continue
            if dependency.startswith("/") and contained(stage, Path(dependency)):
                continue
            if (
                not dependency.startswith(("/", "@"))
                and (binary.parent / dependency).is_file()
            ):
                continue
            raise RuntimeError(
                f"External Mach-O dependency in {binary.relative_to(stage)}: {dependency}"
            )


def build(output: Path, release: bool) -> None:
    source = Path(__file__).resolve().parent / "source"
    source_inputs = helper_input_hashes()
    if release and not any(
        (source / name).is_file() for name in ("LICENSE", "COPYING")
    ):
        raise RuntimeError(
            "Helper source license is unresolved; release packaging is forbidden"
        )
    if output.exists():
        raise RuntimeError(f"Output already exists: {output}")
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(
        prefix="glacier-pron-stage-", dir=output.parent
    ) as temporary:
        stage = Path(temporary) / "Pronunciation"
        managed = stage / "managed-python"
        runtime = stage / "runtime"
        stage.mkdir()
        env = {
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "HOME": str(Path(temporary) / "build-home"),
            "UV_PYTHON_INSTALL_DIR": str(managed),
            "UV_NO_PROGRESS": "1",
        }
        Path(env["HOME"]).mkdir()
        run(
            ["uv", "python", "install", PYTHON_VERSION, "--install-dir", str(managed)],
            cwd=source,
            environment=env,
        )
        python = find_interpreter(managed)
        if (python.parent.parent / "BUILD").read_text(
            encoding="utf-8"
        ).strip() != PYTHON_BUILD:
            raise RuntimeError("uv selected a different standalone Python build")
        requirements = stage / "requirements.lock.txt"
        run(
            [
                "uv",
                "export",
                "--locked",
                "--no-dev",
                "--no-emit-project",
                "--format",
                "requirements.txt",
                "--output-file",
                str(requirements),
            ],
            cwd=source,
            environment=env,
        )
        run(
            [
                "uv",
                "pip",
                "install",
                "--system",
                "--break-system-packages",
                "--python",
                str(python),
                "--require-hashes",
                "--no-python-downloads",
                "-r",
                str(requirements),
            ],
            cwd=source,
            environment=env,
        )
        wheels = stage / "wheels"
        run(
            ["uv", "build", "--wheel", str(source), "--out-dir", str(wheels)],
            cwd=source,
            environment=env,
        )
        built = list(wheels.glob("pron-*.whl"))
        if len(built) != 1:
            raise RuntimeError("Expected one pinned pron wheel")
        run(
            [
                "uv",
                "pip",
                "install",
                "--system",
                "--break-system-packages",
                "--python",
                str(python),
                "--no-deps",
                str(built[0]),
            ],
            cwd=source,
            environment=env,
        )
        # A uv-managed standalone Python already has its standard library and
        # binary under one prefix. Move that prefix into runtime directly;
        # venv `home` and absolute interpreter symlinks cannot survive a move.
        previous_prefix = python.parent.parent
        shutil.move(str(previous_prefix), str(runtime))
        shutil.rmtree(managed)
        shutil.rmtree(wheels)
        requirements.unlink()
        runtime_python = runtime / "bin/python3"
        remove_build_machine_metadata(runtime)
        repair_managed_prefix(runtime, previous_prefix)
        licenses = dependency_licenses(runtime_python, cwd=stage, environment=env)
        record_notices(stage, licenses, source)
        if release and any(value == "UNRESOLVED" for value in licenses.values()):
            raise RuntimeError(
                "A dependency license is unresolved; release packaging is forbidden"
            )
        verify_relocatable(stage)
        write_build_manifest(stage, release=release, source_inputs=source_inputs)
        # A post-move smoke check catches absolute virtualenv paths. It parses
        # help only: no dictionary lookup, network request or audio playback.
        shutil.move(str(stage), output)
    moved_python = output / "runtime/bin/python3"
    if not contained(output, moved_python):
        raise RuntimeError("Moved runtime resolves outside output")
    subprocess.run(
        [str(moved_python), "-B", "-I", "-m", "pron.cli", "--help"],
        cwd=output,
        env={
            "PATH": "/usr/bin:/bin",
            "HOME": str(output),
            "PRON_HOME": str(output),
            "PYTHONUNBUFFERED": "1",
            "PYTHONDONTWRITEBYTECODE": "1",
        },
        check=True,
        capture_output=True,
        timeout=10,
    )
    validate_build_manifest(output, release_required=release)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("output", type=Path)
    parser.add_argument("--release", action="store_true")
    arguments = parser.parse_args()
    build(arguments.output.resolve(), release=arguments.release)


if __name__ == "__main__":
    main()
