#!/bin/bash
# Builds SennseiProbe, wraps it in a signed .app (Bluetooth permission is granted to the bundle),
# runs it, and prints the app's messages and the new log's path. Logs accumulate in Application Support;
# inspect it before copying anything into Fixtures/. Not meant to be run from a bare shell binary.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
app="$root/build/SennseiProbe.app"
out="$HOME/Library/Application Support/Sennsei/probe"

swift build --package-path "$root/Packages/HeadsetKit" -c release --product SennseiProbe
bin="$(swift build --package-path "$root/Packages/HeadsetKit" -c release --show-bin-path)/SennseiProbe"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$bin" "$app/Contents/MacOS/SennseiProbe"
cp "$root/Tools/probe/Info.plist" "$app/Contents/Info.plist"
codesign -s - --force "$app"

# Old logs are kept. Mark the start of this run; the log written by this run is newer than the marker.
mkdir -p "$out"
marker="$(mktemp "$out/.run-marker.XXXXXX")"
trap 'rm -f "$marker"' EXIT
: > "$out/probe.out"
: > "$out/probe.err"
env_args=()
[ -n "${SENNSEI_MODE:-}" ] && env_args+=(--env "SENNSEI_MODE=$SENNSEI_MODE")
for v in SENNSEI_EQ_SNAPSHOT SENNSEI_EQ_GAINS SENNSEI_EQ_BASS; do
    [ -n "${!v:-}" ] && env_args+=(--env "$v=${!v}")
done
[ -n "${SENNSEI_DEVICE_NAME:-}" ] && env_args+=(--env "SENNSEI_DEVICE_NAME=$SENNSEI_DEVICE_NAME")
open -W --stdout "$out/probe.out" --stderr "$out/probe.err" ${env_args[@]+"${env_args[@]}"} "$app"
cat "$out/probe.out" "$out/probe.err"

# Diagnostic mode: report and print the new SDP dump; the normal log logic below is not involved.
if [ "${SENNSEI_MODE:-}" = "dump-sdp" ]; then
    new_dumps=()
    while IFS= read -r f; do new_dumps+=("$f"); done < <(find "$out" -maxdepth 1 -name 'sdp-dump-*.txt' -newer "$marker" | sort)
    if [ ${#new_dumps[@]} -eq 0 ]; then
        echo "No SDP dump written. The probe exited early; see the message above." >&2
        exit 1
    fi
    for f in "${new_dumps[@]}"; do
        printf 'SDP dump: %s\n' "$f"
        cat "$f"
    done
    exit 0
fi

# EQ verification modes: print the result file this run wrote (per mode; eq1-before-*.json is never the result).
eq_pattern=""
case "${SENNSEI_MODE:-}" in
    eq1-read) eq_pattern='eq1-snapshot-*.json' ;;
    eq1-write) eq_pattern='eq1-write-*.json' ;;
    eq1-restore) eq_pattern='eq1-restore-*.json' ;;
esac
if [ -n "$eq_pattern" ]; then
    while IFS= read -r f; do printf 'Pre-write state saved: %s\n' "$f"; done < <(find "$out" -maxdepth 1 -name 'eq1-before-*.json' -newer "$marker" | sort)
    new_eq=()
    while IFS= read -r f; do new_eq+=("$f"); done < <(find "$out" -maxdepth 1 -name "$eq_pattern" -newer "$marker" | sort)
    if [ ${#new_eq[@]} -eq 0 ]; then
        echo "No eq1 result written. The probe exited early or failed; see the message above." >&2
        exit 1
    fi
    for f in "${new_eq[@]}"; do
        printf 'EQ result: %s\n' "$f"
        cat "$f"
    done
    exit 0
fi

new_logs=()
while IFS= read -r f; do new_logs+=("$f"); done < <(find "$out" -maxdepth 1 -name 'accentum-*.jsonl' -newer "$marker" | sort)
if [ ${#new_logs[@]} -eq 0 ]; then
    echo "No log written. The probe exited early; see the message above." >&2
    exit 1
fi
printf 'Log: %s\n' "${new_logs[@]}"
