---
id: 073d2627dc51fe3e
alias: already truck measure reward cable business
kind: reference
title: Contributing to Glacier
created: '2026-11-02'
updated: '2026-11-04'
tags:
- glacier
- macos
- open-source
---

# Contributing

Glacier needs macOS 14.4 or newer, Swift 6 and `uv` for the development helpers.
The current packaged target is Apple Silicon. Start with the
[architecture](docs/glacier-architecture_b2669b52851e2771.md), then read
`Sources/GlacierModuleKit` for tool registration and
[the minimal compiled module](Examples/MinimalModule/README.md) for a runnable
example. The example uses a temporary support root and does not add its tool
to the normal app.

From the repository root:

```sh
swift build --product glacier --disable-index-store -j 4
uv run --offline --no-project python Scripts/run_tests.py -- -j 4
swift run --disable-index-store glacier-example
```

The test wrapper checks that Swift Testing reaches its final total; its AppKit
run-loop guard is test-only. Keep default tests synthetic: use temporary state,
fake transports and platform effects. Do not use personal API keys, live
provider calls, another app installation, real clipboard capture or global
shortcuts as test fixtures. If you change the Python pronunciation helper or
packaging scripts, run the relevant pytest, mypy, Ruff check and Ruff format
commands in [.github/workflows/synthetic.yml](.github/workflows/synthetic.yml).
That workflow defines checks; it is not evidence that hosted CI has run.

For a change, describe what it does, how it was checked and any permissions or
network destinations it adds. Include a focused regression for changed
behavior. Connect new settings, commands and modules to their real callers;
preserve cancellation and module-off behavior. A new provider must bind a
credential to its approved destination, handle redirects safely and redact
failures. Keep the source independent of your home layout, shell profiles and
installed helper tools. See [SECURITY.md](SECURITY.md) before sharing a bug
report that may contain sensitive material.

For a bug report, include the source commit or app version, macOS version and
architecture, steps to reproduce, expected and actual behavior, and a small
redacted log or screenshot if it helps. Remove API keys, selected text,
clipboard history, personal paths and private documents. Ordinary feature
requests can explain the use case without proposing a new service or account.

Glacier's source is offered under **GPL-3.0-only**; preserve
[LICENSE](LICENSE) and [third-party notices](THIRD_PARTY_NOTICES.md), and review
new dependency terms before adding them. Contributions are expected under the
project license. This repository has no contributor copyright assignment
requirement, support SLA or promise to accept a proposed change.
