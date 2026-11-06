#!/bin/bash
# Archive an already-packaged Glacier development candidate for local review.
# This script never signs, notarizes, installs, uploads, or changes the app.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

if [[ -n "$(git status --porcelain=v1 --untracked-files=all)" ]]; then
  echo "Local archiving requires clean committed source" >&2
  exit 1
fi

revision="$(git rev-parse HEAD)"
short_revision="${revision:0:7}"
app_path="dist/Glacier.app"
package_receipt="dist/package-receipt.json"
archive_stem="Glacier-LOCAL-NOT-NOTARIZED-arm64-${short_revision}"
app_archive="${archive_stem}.zip"
source_archive="Glacier-source-LOCAL-${short_revision}.tar.gz"
archive_receipt="${archive_stem}.receipt.json"
checksums="SHA256SUMS-LOCAL-${short_revision}.txt"

if [[ ! -d "$app_path" || ! -f "$package_receipt" ]]; then
  echo "Package the optimized app before archiving" >&2
  exit 1
fi
if ! jq -e --arg revision "$revision" \
  '.sourceRevision == $revision and .sourceDirty == false and .configuration == "release" and .signing == "ad-hoc-local-development-only" and .notarized == false and .distribution == "LOCAL-ONLY-NOT-NOTARIZED" and .pronunciation_bundled == true and .helperReleaseGate == true' \
  "$package_receipt" >/dev/null; then
  echo "Package receipt is not a matching complete local candidate" >&2
  exit 1
fi
if [[ "$(plutil -extract CFBundleIconFile raw -o - "$app_path/Contents/Info.plist")" != "GlacierAppIcon.icns" \
      || ! -f "$app_path/Contents/Resources/GlacierAppIcon.icns" ]]; then
  echo "The packaged app is missing its declared Finder icon" >&2
  exit 1
fi
codesign --verify --deep --strict "$app_path"
uv run --offline --no-project python -B Scripts/package_glacier.py --verify-local-candidate

for output in "$app_archive" "$source_archive" "$archive_receipt" "$checksums"; do
  if [[ -e "dist/$output" ]]; then
    echo "Archive output already exists: dist/$output" >&2
    exit 1
  fi
done

stage="$(mktemp -d "dist/.local-archive-${short_revision}.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
ditto -c -k --keepParent --sequesterRsrc "$app_path" "$stage/$app_archive"
git archive --format=tar.gz --prefix="Glacier-source/" --output="$stage/$source_archive" HEAD
unzip -tq "$stage/$app_archive" >/dev/null
tar -tzf "$stage/$source_archive" >/dev/null

app_sha="$(shasum -a 256 "$stage/$app_archive" | cut -d ' ' -f 1)"
source_sha="$(shasum -a 256 "$stage/$source_archive" | cut -d ' ' -f 1)"
package_sha="$(shasum -a 256 "$package_receipt" | cut -d ' ' -f 1)"
jq -n \
  --arg revision "$revision" \
  --arg app "$app_archive" --arg app_sha "$app_sha" \
  --arg source "$source_archive" --arg source_sha "$source_sha" \
  --arg package_sha "$package_sha" \
  '{sourceRevision:$revision, status:"LOCAL-ONLY-NOT-NOTARIZED", publicDownloadReady:false,
    sourcePublicationReview:"not-run",
    signing:"ad-hoc-local-development-only", appArchive:{file:$app,sha256:$app_sha},
    correspondingSource:{file:$source,sha256:$source_sha},
    packageReceiptSHA256:$package_sha}' >"$stage/$archive_receipt"
printf '%s  %s\n%s  %s\n' "$app_sha" "$app_archive" "$source_sha" "$source_archive" >"$stage/$checksums"

mv "$stage/$app_archive" "$stage/$source_archive" "$stage/$archive_receipt" "$stage/$checksums" dist/
echo "dist/$app_archive"
echo "dist/$source_archive"
echo "dist/$archive_receipt"
echo "dist/$checksums"
