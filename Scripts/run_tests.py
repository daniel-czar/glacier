#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# ///
"""Run Swift tests with the macOS async-main guard and require a final total.

Usage: uv run --offline --no-project python Scripts/run_tests.py
Append SwiftPM arguments after --, for example -- --filter OmniPresentationTests.
The guard is compiled in the normal .build directory and never packaged.
Tests run serially because AppKit tests share the process application/menu.
"""

from __future__ import annotations

import argparse
import os
import platform
import re
import subprocess
import sys
from pathlib import Path

PACKAGE = Path(__file__).resolve().parents[1]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("swift_arguments", nargs=argparse.REMAINDER)
    arguments = parser.parse_args().swift_arguments
    if arguments[:1] == ["--"]:
        arguments = arguments[1:]
    guard = PACKAGE / ".build/omni-test-runloop-guard.dylib"
    guard.parent.mkdir(exist_ok=True)
    # SwiftPM inherits this injection in build helpers too. On Apple Silicon,
    # /usr/bin/xcrun is arm64e while the test worker is arm64, so the guard
    # must provide both slices before SwiftPM can reach the tests.
    architectures = (
        ["-arch", "arm64", "-arch", "arm64e"] if platform.machine() == "arm64" else []
    )
    subprocess.run(
        [
            "xcrun",
            "clang",
            "-dynamiclib",
            *architectures,
            "-framework",
            "CoreFoundation",
            str(PACKAGE / "Scripts/omni_test_runloop_guard.c"),
            "-o",
            str(guard),
        ],
        check=True,
    )
    # /usr/bin/swift is a protected shim that strips DYLD variables; xcrun
    # locates the selected toolchain's actual executable without changing it.
    swift = subprocess.check_output(["xcrun", "--find", "swift"], text=True).strip()
    environment = os.environ.copy()
    # Synthetic tests never inherit provider credentials or opt-in live smoke flags.
    for key in list(environment):
        upper = key.upper()
        if (
            upper.endswith(("_API_KEY", "_TOKEN", "_SECRET"))
            or upper.startswith(
                (
                    "CEREBRAS_",
                    "OPENAI_",
                    "ANTHROPIC_",
                    "OPENROUTER_",
                    "TYPESAFE_",
                    "PRON_",
                    "EXPRESS_",
                    "OMNI_",
                )
            )
            or upper in {"OMNI_LAUNCHER_SMOKE", "OMNI_LIVE", "PRON_LIVE"}
        ):
            environment.pop(key, None)
    previous = environment.get("DYLD_INSERT_LIBRARIES")
    environment["DYLD_INSERT_LIBRARIES"] = str(guard) + (
        ":" + previous if previous else ""
    )
    process = subprocess.Popen(
        [swift, "test", "--disable-index-store", "--no-parallel", *arguments],
        cwd=PACKAGE,
        env=environment,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    completed = False
    assert process.stdout is not None
    for line in process.stdout:
        sys.stdout.write(line)
        if re.search(r"Test run with \d+ tests?\b.*\b(?:passed|failed)\b", line):
            completed = True
    return_code = process.wait()
    if return_code != 0:
        return return_code
    if not completed:
        print(
            "Glacier test run incomplete: Swift Testing printed no final total.",
            file=sys.stderr,
        )
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
