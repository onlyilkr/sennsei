#!/bin/bash
# Builds the release artifacts for one version into dist/ (nothing is published):
#   Sennsei-<version>.zip   Sennsei.app, universal (arm64 + x86_64), ad-hoc signed, with the sennsei command
#                           line tool inside at Contents/Resources/sennsei (covered by the app's signature)
#   sennsei                 the same command line tool as a loose file
#   checksums.txt           SHA-256 of the zip and the loose tool
#   sennsei.rb              the Homebrew cask for that zip
#   release-notes.md        that version's CHANGELOG.md section
# Usage: scripts/package-release.sh 1.2.3
#
# Architecture decision: universal. `swift build --arch arm64 --arch x86_64` itself works, but it goes
# through the Xcode build system, which compiles Localizable.xcstrings away (the app reads the .xcstrings
# JSON from its resource bundle at runtime) and puts the const-values files in other places. So
# Tools/app/build_app.sh (UNIVERSAL=1) builds each architecture natively and joins the two with lipo. The
# App Intents metadata processor runs once, on the arm64 const values: the metadata describes Swift
# declarations, not machine code (an x86_64 run differs only in the order of resolvableInputTypes).
# The x86_64 slice is only checked to link and to run the CLI under Rosetta; the app itself has not been
# exercised on an Intel Mac.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/package-release.sh <version>}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
    echo "not a version: $VERSION" >&2
    exit 2
fi
# Only 0.0.0-* versions are dry runs (CI, `make dist VERSION=0.0.0-test`): they skip the checks that tie
# a version to the source tree. CFBundleVersion is derived by build_app.sh (digits and dots only).
DRY_RUN=0
[[ "$VERSION" == 0.0.0-* ]] && DRY_RUN=1
if [[ "$DRY_RUN" == 0 && -n "$(git status --porcelain 2>/dev/null)" ]]; then
    echo "WARNING: the git tree has uncommitted changes; this release is not built from a clean checkout of a commit." >&2
fi

UNIVERSAL=1 EMBED_CLI=1 VERSION="$VERSION" bash Tools/app/build_app.sh

APP="build/Sennsei.app"
for bin in "$APP/Contents/MacOS/SennseiApp" "$APP/Contents/Resources/sennsei" build/sennsei; do
    archs="$(lipo -archs "$bin")"
    [[ "$archs" == *arm64* && "$archs" == *x86_64* ]] || { echo "error: $bin is not universal: $archs" >&2; exit 1; }
done
[[ -d "$APP/Contents/Resources/Metadata.appintents" ]] || { echo "error: Metadata.appintents missing from $APP" >&2; exit 1; }

# The version the CLI prints is a constant in the source, not stamped by the build.
if [[ "$DRY_RUN" == 0 ]]; then
    cli_version="$(build/sennsei --version)"
    [[ "$cli_version" == "sennsei $VERSION" ]] || {
        echo "error: 'sennsei --version' prints '$cli_version'; set CLIVersion.current in Packages/HeadsetKit/Sources/SennseiCLICore/CLIVersion.swift to $VERSION" >&2
        exit 1
    }
fi

rm -rf dist
mkdir -p dist
ZIP="Sennsei-$VERSION.zip"
# ditto keeps the bundle's symlinks, permissions and signature intact; zip would not.
ditto -c -k --sequesterRsrc --keepParent "$APP" "dist/$ZIP"
cp build/sennsei dist/sennsei
(cd dist && shasum -a 256 "$ZIP" sennsei > checksums.txt)
SHA="$(grep " $ZIP\$" dist/checksums.txt | cut -d' ' -f1)"

sed -e "s/__VERSION__/$VERSION/g" -e "s/__SHA256__/$SHA/g" packaging/sennsei.rb.template > dist/sennsei.rb

# The section between "## [<version>]" and the next "## [" heading.
awk -v v="$VERSION" '
    index($0, "## [" v "]") == 1 { on = 1; next }
    on && /^## \[/ { exit }
    on { print }
' CHANGELOG.md > dist/release-notes.md
if [[ ! -s dist/release-notes.md ]]; then
    if [[ "$DRY_RUN" == 1 ]]; then
        echo "warning: no CHANGELOG.md section for $VERSION; writing a placeholder (dry run)." >&2
        echo "See CHANGELOG.md." > dist/release-notes.md
    else
        echo "error: CHANGELOG.md has no '## [$VERSION]' section (or it is empty)." >&2
        exit 1
    fi
fi

ls -l dist
