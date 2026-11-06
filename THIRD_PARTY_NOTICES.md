---
id: de0899b084100a7f
alias: task dynamic history amused absent display
kind: reference
title: Glacier third-party notices
created: '2026-11-02'
updated: '2026-11-05'
tags:
- glacier
- macos
- open-source
---

# Third-party notices

Glacier's own source is offered under **GPL-3.0-only**. The complete project
license is [LICENSE](LICENSE); the pronunciation helper's copied source has
its own [GPLv3 text](Helpers/Pronunciation/source/LICENSE) and
[provenance record](Helpers/Pronunciation/provenance.json). These project
licenses do not replace the terms for bundled data, runtimes or dependencies.

| Material | Source-tree notice or provenance | Location in a packaged app |
| --- | --- | --- |
| Unicode character and emoji data | `Sources/OmniCore/Resources/UNICODE-LICENSE.txt` and corpus source metadata | `Contents/Resources/Glacier_OmniCore.bundle/Contents/Resources/UNICODE-LICENSE.txt` |
| Pronunciation helper source | `Helpers/Pronunciation/source/LICENSE`; `Helpers/Pronunciation/provenance.json` | `Contents/Resources/Pronunciation/notices/GLACIER-PRON-LICENSE.txt` |
| Bundled standalone Python | `Helpers/Pronunciation/standalone-notices/PYTHON.json` and its `LICENSE.*.txt` notice inputs | `Contents/Resources/Pronunciation/notices/PYTHON-LICENSE.txt` and `Contents/Resources/Pronunciation/notices/native/` |
| Bundled Itcl and Tcl Thread libraries | `Helpers/Pronunciation/standalone-notices/LICENSE.itcl.txt` and `LICENSE.thread.txt`; versioned upstream references in `Helpers/Pronunciation/provenance.json` | `Contents/Resources/Pronunciation/notices/native/` in packages built after these source notices were added |
| CMU dictionary data and installed Python packages | The helper's locked source and package metadata | `Contents/Resources/Pronunciation/notices/CMUDICT-DATA-LICENSE.txt`, `license-inventory.json` and copied license files within its runtime |

`Scripts/package_glacier.py` also copies this file and `LICENSE` to
`Glacier.app/Contents/Resources/`. The packaged
`Pronunciation/license-inventory.json` records the exact installed
distributions, native components and copied notices for that build; its
`helper-build-manifest.json` and `helper-package-manifest.json` bind the helper
to source and signed files. The local package's release license gate checks
that inventory, but does not certify every redistribution obligation. The
inventory's zlib-ng notice exception refers to a system-linked zlib library,
not a bundled zlib-ng binary; confirm that relationship for any public build.

### Source form for bundled Python packages

The inspected local helper contains **certifi 2026.10.18** under MPL-2.0 and
**cmudict 1.1.3** under GPL-3.0-or-later. Their installed `.py` files and
data are in `Pronunciation/runtime/lib/python3.12/site-packages/`, with their
package and data licenses in the same runtime. The exact certifi `core.py`
and `cacert.pem` bytes match its
[2026.10.18 upstream source tag](https://github.com/certifi/python-certifi/tree/2026.10.18).
For executable-form MPL distribution, recipients must be told how to obtain
the [Source Code Form](https://www.mozilla.org/en-US/MPL/2.0/#section-3.2).

`Helpers/Pronunciation/standalone-notices/THIRD_PARTY_SOURCES.json` records
verified source-distribution URLs and SHA-256 values for all 12 observed
third-party Python distributions, including certifi, cmudict and pip; Glacier's
own `pron` source is tracked in this repository. The exact
source archives, with package build metadata and licenses, are gathered in
the **local-only** `dist/Glacier-third-party-sources-LOCAL-audit.tar.gz`.
This companion is ignored by Git and is not yet a public source release.
Publish a matching source companion and tell recipients where it is before
offering a public app binary. The helper's own source and build scripts are
tracked under `Helpers/Pronunciation/`.

The pinned `python-build-standalone` full archive and its hash are recorded in
`Helpers/Pronunciation/provenance.json`. It is a runtime/build-artifact input,
not a source-form archive. The inspected native-library license inventory uses
permissive terms (including Tcl, BSD, MIT, PSF, Apache and OpenSSL); this audit
found no separate native component whose license itself requires source
mirroring. Preserve the exact upstream provenance and notice texts with any
future binary. The bundled OpenSSL implementation identifies itself as 3.5.7;
both OpenSSL 1.1 and 3 notice texts are retained from the pinned build metadata.

The bundled character corpus is plain JSON marked Unicode 17.0.0. The emoji
corpus is plain JSON marked CLDR 47.0.0 and Emoji 16.0. Both files and the
[Unicode License v3](Sources/OmniCore/Resources/UNICODE-LICENSE.txt) are in
the source tree, and the license ships in the same resource bundle. A separate
corpus regeneration tool would aid maintenance, but no missing source-form
data or notice was found in this audit.

Swift, AppKit and Apple frameworks come from the platform/toolchain and are
not relicensed by Glacier. Forvo, Merriam-Webster, Wiktionary/Commons and
other optional remote services have separate terms for their services and
outputs. Glacier's app archive does not include provider credentials, user
recordings or personal caches.

Before public distribution, inspect the actual frozen app and corresponding
source archive, keep their notices together, and complete the third-party
rights review. A local development receipt is not a public-release clearance.
