---
id: 88189953575222a9
alias: marine shadow feel push captain fee
kind: runbook
title: Glacier release preparation
created: '2026-11-04'
updated: '2026-11-05'
summary: Local candidate packaging and remaining steps for a signed public Glacier download.
tags:
- glacier
- macos
- release
---

# Glacier release preparation

This repository currently produces a **local development candidate**. Its
optimized build includes the pronunciation helper, a Finder icon, GPLv3 license
and notices, source receipt, and a strict ad hoc signature. It is **not a
public download**: the local identity is `local.Glacier.Development`, signing
is ad hoc, and the artifact is not notarized. Do not put a local archive behind
the website's Download action.

## Build and archive the local candidate

Use a clean committed checkout. The packager verifies that source state remains
unchanged during the build, retains the previous `dist/Glacier.app` and receipt,
and runs a network-denied local headless smoke check. Its helper gate requires
an included, relocatable runtime and its license inventory. These commands do
not install, use signing-account credentials, notarize, or upload anything.

```sh
uv run --offline --no-project python Scripts/run_tests.py -- -j 4
uv run --no-project Scripts/package_glacier.py
bash Scripts/archive_local_candidate.sh
```

The archive script requires the optimized `dist/Glacier.app` receipt to match
`HEAD`. It writes a `Glacier-LOCAL-NOT-NOTARIZED-arm64-<commit>.zip`, a matching
source tarball, checksums, and a JSON archive receipt under ignored `dist/`.
Keep all four together. The ZIP name and receipt explicitly say it is local.
The corresponding source tarball is a snapshot of the same clean commit; it is
not a substitute for a public source repository or distribution compliance
review.

## Building a history-free source snapshot

Public source snapshots omit local cross-repository agent instructions and Git
history. They retain the source, tests, resources, dependency locks, notices
and build scripts. The original development repository is not itself the
publication payload; its history can contain private author metadata.

`swift build --product glacier --disable-index-store -j 4` works in an extracted
snapshot. The app packager also needs a clean Git checkout to record source
provenance. For a local rebuild from an archive, initialize a repository in the
extracted directory and commit the snapshot using your own configured Git
identity before running the packager:

```sh
git init
git add .
git commit -m "Import Glacier source snapshot"
uv run --no-project Scripts/package_glacier.py
```

The resulting package records your new local commit, not the original archive's
source revision. Keep the original archive and its checksum for comparison.
For a later public repository, initialize from the audited snapshot with the
approved public author identity rather than pushing the private development
history. Local agent instructions remain available in the private checkout;
`.gitattributes` excludes them from `git archive` exports.

## Identity and signing boundary for a later public candidate

The public name **Glacier** and direct GitHub distribution route are settled.
`com.glacierformac.Glacier` is a concrete proposed bundle identifier derived
from the chosen domain, **not yet activated**. Before changing the package
profile, settle its exact identifier and version, and review the linked
Keychain service `local.Glacier.Development` in
`Sources/GlacierConnections/ConnectionCredentials.swift`. Changing only the
bundle ID would leave credentials in a development namespace; changing the
service without a migration would make existing Glacier keys unavailable.
Treat the public profile and any data continuity rule as one release change.
Keep the local development profile isolated for tests and previews.

The current packager deliberately uses `codesign --sign - --timestamp=none`.
A public direct-download profile needs a Developer ID Application certificate,
hardened runtime, secure timestamp, notarization, and a stapled ticket. The
nested pronunciation Mach-O files and SwiftPM resource bundles must be signed
before the outer app, as the local packager already does. This is an
implementation and validation step for the public profile; the following is a
command outline, **not a tested release command or authorization to run it**:

```sh
# After the public bundle identity/version and signing profile are implemented:
# codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID_APPLICATION" <each nested Mach-O>
# codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID_APPLICATION" <each resource bundle>
# codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID_APPLICATION" <Glacier.app>
# codesign --verify --deep --strict --verbose=2 <Glacier.app>
# ditto -c -k --keepParent <Glacier.app> <notarization.zip>
# xcrun notarytool submit <notarization.zip> --keychain-profile <profile> --wait
# xcrun stapler staple <Glacier.app>
# xcrun stapler validate <Glacier.app>
# spctl -a -vvv -t exec <Glacier.app>
# Recreate the final download archive and checksum after stapling.
```

Do not copy a developer certificate, notary credential, or Keychain profile into
the repository or receipts. A public source release must carry the same commit,
license, notices, build scripts and corresponding source for the binary.

## Checks before a download link

- The local repository presentation is prepared: the README, usage guide,
  masked demo media, contribution guide, security boundaries, GPL license and
  third-party notices. Before opening the public repository, enable and verify
  a private vulnerability-reporting channel and replace the pending reporting
  section in `SECURITY.md` with its real route. No security address or public
  repository URL is assumed by these files.
- When the real repository and release exist, connect the website's temporary
  profile links to them and update the README's early-preview availability
  text. Do not turn the local candidate into a public download merely because
  its documentation is ready. Run the existing synthetic CI workflow in the
  actual repository before describing its CI status as passing.
- Run the full synthetic suite and release build from the frozen source commit.
- Review the tracked source tree and export history for private paths, secrets,
  credentials and assets. The existing synthetic sandbox checks are evidence
  for exercised runtime paths, not this publication review.
- Review redistribution obligations for the bundled helper and its notices.
  Its release license gate inventories dependencies and native components, but
  is not a rights-clearance certificate. The recorded zlib-ng notice exception
  relates to a system-linked zlib library, not a bundled zlib-ng binary; retain
  the explicit inventory and confirm it in the final audit.
- Test the signed, stapled archive after a quarantined download in a clean
  account on the advertised Apple Silicon/macOS versions. Include first-run
  permissions, shortcuts, offline tools, pronunciation, relocation and uninstall.
  Intel support need not be claimed unless separately built and verified.
- Verify the final ZIP, source archive, checksums, bundle identity/version/icon,
  source receipt, helper receipt, and Gatekeeper decision. Obtain explicit
  upload authorization before publishing any artifact or enabling Download.

The local candidate's passing tests, helper gate and ad hoc signature remain
valuable development evidence. They do not imply Developer ID, notarization,
clean-account, real-provider or public-release checks have passed.
