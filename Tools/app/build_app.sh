#!/bin/bash
# Builds the Sennsei menu bar app and assembles an ad-hoc signed build/Sennsei.app.
# Does NOT launch the app. Bluetooth permission belongs to the .app bundle.
#
# Environment (all optional; the defaults are the single-architecture developer build):
#   UNIVERSAL=1   build arm64 + x86_64 instead of the host architecture only
#   VERSION=x.y.z stamp CFBundleShortVersionString / CFBundleVersion (scripts/package-release.sh does this)
#   EMBED_CLI=1   also copy the sennsei command line tool into Sennsei.app/Contents/Resources/sennsei,
#                 before signing, so the signature covers it (the Homebrew cask links it from there)
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
pkg="$root/Packages/HeadsetKit"
app="$root/build/Sennsei.app"

# App Intents need the Swift compiler's const-value extraction for the AppIntents protocols; the
# metadata processor below reads the resulting SennseiApp.swiftconstvalues.
if ! xcrun --find appintentsmetadataprocessor > /dev/null 2>&1; then
    echo "error: appintentsmetadataprocessor not found. It ships with Xcode (not the Command Line Tools alone):" >&2
    echo "       install Xcode and select it with 'sudo xcode-select -s /Applications/Xcode.app'." >&2
    exit 1
fi

intents_work="$root/build/intents-work"
rm -rf "$intents_work"
mkdir -p "$intents_work"
printf '%s\n' '["AppIntent","AppEnum","AppEntity","EntityQuery","AppShortcutsProvider","DynamicOptionsProvider","TransientEntity","AppIntentsPackage","EntityPropertyQuery","EntityStringQuery","IntentValueQuery","EntityIdentifierQuery","UniqueAppEntity"]' > "$intents_work/protocols.json"

build_for() { # $1 = extra swift build flags (e.g. --arch arm64), possibly empty
    # shellcheck disable=SC2086
    swift build --package-path "$pkg" -c release --product SennseiApp $1 \
        -Xswiftc -emit-const-values \
        -Xswiftc -Xfrontend -Xswiftc -const-gather-protocols-file \
        -Xswiftc -Xfrontend -Xswiftc "$intents_work/protocols.json"
    # shellcheck disable=SC2086
    swift build --package-path "$pkg" -c release --product sennsei $1
    # Fail on weak async specializations that modules (ours and dependencies) define with different
    # context sizes; the linker would mix them and the app would abort at run time. See docs/ARCHITECTURE.md.
    # shellcheck disable=SC2086
    python3 "$root/scripts/check-async-odr.py" "$(swift build --package-path "$pkg" -c release --show-bin-path $1)"
}

if [ "${UNIVERSAL:-}" = 1 ]; then
    # Two native builds joined with lipo, not `swift build --arch arm64 --arch x86_64`: that one goes
    # through the Xcode build system, which compiles Localizable.xcstrings into .strings files, and
    # Strings.swift reads the .xcstrings JSON from the resource bundle directly. arm64 supplies the resource
    # bundles and the const values (the intents metadata describes Swift declarations, not machine code).
    build_for "--arch arm64"
    build_for "--arch x86_64"
    bin_dir="$(swift build --package-path "$pkg" -c release --arch arm64 --show-bin-path)"
    x86_dir="$(swift build --package-path "$pkg" -c release --arch x86_64 --show-bin-path)"
    mkdir -p "$root/build/universal"
    lipo -create "$bin_dir/SennseiApp" "$x86_dir/SennseiApp" -output "$root/build/universal/SennseiApp"
    lipo -create "$bin_dir/sennsei" "$x86_dir/sennsei" -output "$root/build/universal/sennsei"
    app_bin="$root/build/universal/SennseiApp"
    cli_bin="$root/build/universal/sennsei"
else
    build_for ""
    bin_dir="$(swift build --package-path "$pkg" -c release --show-bin-path)"
    app_bin="$bin_dir/SennseiApp"
    cli_bin="$bin_dir/sennsei"
fi

# SwiftPM resource bundle of SennseiCore (named <package>_SennseiCore.bundle). Exactly one must match.
bundles=()
while IFS= read -r b; do bundles+=("$b"); done < <(find "$bin_dir" -maxdepth 1 -name '*_SennseiCore.bundle' -type d | sort)
if [ ${#bundles[@]} -ne 1 ]; then
    echo "error: expected exactly one *_SennseiCore.bundle in $bin_dir, found ${#bundles[@]}" >&2
    exit 1
fi
bundle_path="${bundles[0]}"
bundle_name="$(basename "$bundle_path")"

# SwiftPM resource bundle of the KeyboardShortcuts dependency (Recorder localization). Exactly one must match.
ks_bundles=()
while IFS= read -r b; do ks_bundles+=("$b"); done < <(find "$bin_dir" -maxdepth 1 -name '*_KeyboardShortcuts.bundle' -type d | sort)
if [ ${#ks_bundles[@]} -ne 1 ]; then
    echo "error: expected exactly one *_KeyboardShortcuts.bundle in $bin_dir, found ${#ks_bundles[@]}" >&2
    exit 1
fi
ks_bundle_path="${ks_bundles[0]}"
ks_bundle_name="$(basename "$ks_bundle_path")"

rm -rf "$app"
# The command line tool is a separate artifact: build/sennsei, never inside Sennsei.app.
mkdir -p "$root/build"
cp "$cli_bin" "$root/build/sennsei"
codesign -s - --force "$root/build/sennsei"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$app_bin" "$app/Contents/MacOS/SennseiApp"
cp "$root/Tools/app/Info.plist" "$app/Contents/Info.plist"
# Must live in Contents/Resources (a bundle at the .app root breaks signing; SennseiCore looks here first).
cp -R "$bundle_path" "$app/Contents/Resources/$bundle_name"
cp -R "$ks_bundle_path" "$app/Contents/Resources/$ks_bundle_name"
# App icon (generated by Tools/icon/make_icon.swift); copied before signing so the signature covers it.
cp "$root/Tools/app/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"

if [ -n "${VERSION:-}" ]; then
    plutil -replace CFBundleShortVersionString -string "$VERSION" "$app/Contents/Info.plist"
    # CFBundleVersion must be numbers and dots only: 1.2.0-rc.1 becomes 1.2.0.
    plutil -replace CFBundleVersion -string "${VERSION%%[-+]*}" "$app/Contents/Info.plist"
fi
if [ "${EMBED_CLI:-}" = 1 ]; then
    cp "$root/build/sennsei" "$app/Contents/Resources/sennsei"
fi

plutil -lint "$app/Contents/Info.plist"

# --- App Intents (Shortcuts) -------------------------------------------------------------------
# SwiftPM has no App Intents support, so run Xcode's metadata processor by hand. Shortcuts finds the
# actions through Contents/Resources/Metadata.appintents (the processor appends that directory name).
const_values="$bin_dir/SennseiApp.build/SennseiApp.swiftconstvalues"
if [ ! -s "$const_values" ]; then
    echo "error: $const_values missing; the const-values build flags did not take effect" >&2
    exit 1
fi
find "$pkg/Sources/SennseiApp" -name '*.swift' | sort > "$intents_work/sources.txt"
printf '%s\n' "$const_values" > "$intents_work/constvalues.txt"
toolchain="$(dirname "$(dirname "$(dirname "$(xcrun --find appintentsmetadataprocessor)")")")"
if [ "${UNIVERSAL:-}" = 1 ]; then arch=arm64; else case "$(uname -m)" in arm64) arch=arm64 ;; *) arch=x86_64 ;; esac; fi
xcrun appintentsmetadataprocessor \
    --output "$app/Contents/Resources" \
    --toolchain-dir "$toolchain" \
    --module-name SennseiApp \
    --sdk-root "$(xcrun --show-sdk-path)" \
    --xcode-version "$(xcodebuild -version | awk '/Build version/ {print $3}')" \
    --platform-family macOS \
    --deployment-target 14.0 \
    --target-triple "$arch-apple-macos14.0" \
    --source-file-list "$intents_work/sources.txt" \
    --swift-const-vals-list "$intents_work/constvalues.txt"

for intent in ApplySceneIntent SetNoiseControlIntent SetEqualizerPresetIntent GetBatteryLevelIntent; do
    if ! grep -q "\"$intent\"" "$app/Contents/Resources/Metadata.appintents/extract.actionsdata"; then
        echo "error: $intent missing from Metadata.appintents/extract.actionsdata" >&2
        exit 1
    fi
done

# App Intents resolve titles (LocalizedStringResource keys) from the app bundle's own .lproj
# Localizable.strings, not from the SennseiCore SwiftPM bundle, so derive them from the catalog.
python3 - "$pkg/Sources/SennseiCore/Resources/Localizable.xcstrings" "$app/Contents/Resources" <<'PY'
import json, os, sys
catalog = json.load(open(sys.argv[1]))["strings"]
for lang in ("en", "tr"):
    folder = os.path.join(sys.argv[2], lang + ".lproj")
    os.makedirs(folder, exist_ok=True)
    with open(os.path.join(folder, "Localizable.strings"), "w", encoding="utf-8") as out:
        for key in sorted(k for k in catalog if k.startswith("intent.")):
            value = catalog[key]["localizations"][lang]["stringUnit"]["value"]
            out.write(json.dumps(key, ensure_ascii=False) + " = " + json.dumps(value, ensure_ascii=False) + ";\n")
PY

# Sign after all content is in place.
codesign -s - --force --deep "$app"
codesign --verify --deep --strict "$app"

# Without the bundle the shipped app would fall through to Bundle.module and crash on other machines.
if [ ! -d "$app/Contents/Resources/$bundle_name" ]; then
    echo "error: resource bundle missing from $app/Contents/Resources/$bundle_name" >&2
    exit 1
fi
if [ ! -d "$app/Contents/Resources/$ks_bundle_name" ]; then
    echo "error: $ks_bundle_name missing from $app/Contents/Resources" >&2
    exit 1
fi
if [ ! -f "$app/Contents/Resources/$bundle_name/Localizable.xcstrings" ]; then
    echo "error: Localizable.xcstrings missing inside $bundle_name" >&2
    exit 1
fi

if [ ! -s "$app/Contents/Resources/Metadata.appintents/extract.actionsdata" ]; then
    echo "error: Metadata.appintents/extract.actionsdata missing or empty" >&2
    exit 1
fi

echo "Built: $app ($(lipo -archs "$app/Contents/MacOS/SennseiApp"))"
echo "Built: $root/build/sennsei ($(lipo -archs "$root/build/sennsei"))"
