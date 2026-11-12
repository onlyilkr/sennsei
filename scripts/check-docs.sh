#!/bin/bash
# Documentation checks, run from anywhere (it changes to the repository root):
#   1. The README's "Command line" section covers every command and exit code that `build/sennsei --help`
#      lists (counts are derived from that output, nothing is hard-coded), and every `sennsei ...` example in
#      a fenced block of README.md is valid for the CLI's usage (tag a deliberately invalid one with
#      `# error example` to skip it).
#   2. Every relative link and image in the markdown files, and every repository path mentioned in
#      .github files, exists; every #anchor resolves to a heading (GitHub's slug rules).
#   3. No forbidden string (a retired bundle id, a home folder path, the author's handle, a Bluetooth
#      address) in any tracked or untracked, non-ignored file.
# `make check` builds build/sennsei first; run it before this script. Nothing here talks to the app.
set -euo pipefail
cd "$(dirname "$0")/.."

fail=0
problem() { echo "check-docs: $*" >&2; fail=1; }

# Prints a markdown file without its fenced code blocks.
strip_fences() { awk '/^```/ { f = !f; next } !f { print }' "$1"; }

# Prints the lines inside fenced blocks (fence lines themselves are dropped); for `text` fences the
# language is printed as a first line "@@text".
fenced_lines() { awk '/^```/ { if (f) { f = 0 } else { f = 1; lang = substr($0, 4); print "@@" lang }; next } f { print }' "$1"; }

# --- 1. CLI help against the README -------------------------------------------------------------------
CLI=build/sennsei
if [[ ! -x "$CLI" ]]; then
    echo "check-docs: $CLI is missing. Run 'make app' (or 'make check') first." >&2
    exit 2
fi
help_text="$("$CLI" --help)"

commands=()
codes=()
section=""
set -f   # no globbing while splitting usage lines into words
while IFS= read -r line; do
    case "$line" in
        Commands:*) section=commands; continue ;;
        "Exit codes:"*) section=codes; continue ;;
        "") continue ;;
    esac
    [[ "$line" == " "* ]] || continue
    read -r -a words <<< "$line"
    if [[ "$section" == commands ]]; then commands+=("${words[0]}"); fi
    if [[ "$section" == codes ]]; then codes+=("${words[0]}"); fi
done <<< "$help_text"
set +f

[[ ${#commands[@]} -gt 0 ]] || problem "parsed no commands from '$CLI --help'"
[[ ${#codes[@]} -gt 0 ]] || problem "parsed no exit codes from '$CLI --help'"

# The README's "## Command line" section, and its fenced `text` usage block.
cli_section="$(awk '/^## / { on = ($0 == "## Command line") } on { print }' README.md)"
[[ -n "$cli_section" ]] || problem "README.md has no '## Command line' section"
usage_block="$(printf '%s\n' "$cli_section" | awk '/^```text/ { f = 1; next } /^```/ { if (f) exit } f { print }')"
[[ -n "$usage_block" ]] || problem "README.md '## Command line' has no fenced text usage block"

for cmd in "${commands[@]}"; do
    printf '%s\n' "$usage_block" | grep -qE "^sennsei $cmd( |$)" \
        || problem "README.md usage block does not list: sennsei $cmd"
done
for n in "${codes[@]}"; do
    printf '%s\n' "$cli_section" | grep -qE "^\| $n \|" || problem "README.md does not document exit code $n"
done

# Examples in fenced blocks other than the usage block: `sennsei <command> ...`.
valid_example() { # $1 = line; prints a reason and returns 1 when invalid
    local text="$1"
    text="${text%%#*}"; text="${text%%|*}"
    local args=()
    while IFS= read -r a; do args+=("$a"); done < <(printf '%s\n' "$text" | xargs -n1 2>/dev/null || true)
    local cmd="${args[1]:-}" n=$(( ${#args[@]} - 2 ))
    local known=0 c
    for c in "${commands[@]}"; do [[ "$cmd" == "$c" ]] && known=1; done
    [[ $known == 1 ]] || { echo "unknown command '$cmd'"; return 1; }
    case "$cmd" in
        noise) [[ $n == 1 && "${args[2]}" =~ ^(anc|transparency|off|next)$ ]] || { echo "usage: noise <anc|transparency|off|next>"; return 1; } ;;
        anc|pause|auto) [[ $n == 1 && "${args[2]}" =~ ^(on|off)$ ]] || { echo "usage: $cmd <on|off>"; return 1; } ;;
        eq|scene) [[ $n == 1 ]] || { echo "usage: $cmd takes exactly one argument"; return 1; } ;;
        status) [[ $n == 0 || ( $n == 1 && "${args[2]}" == "--json" ) ]] || { echo "usage: status [--json]"; return 1; } ;;
        *) [[ $n == 0 ]] || { echo "usage: $cmd takes no arguments"; return 1; } ;;
    esac
    return 0
}
in_usage=0
set -f
while IFS= read -r line; do
    if [[ "$line" == "@@"* ]]; then in_usage=0; [[ "$line" == "@@text" ]] && in_usage=1; continue; fi
    [[ $in_usage == 1 ]] && continue
    [[ "$line" == sennsei\ * ]] || continue
    [[ "$line" == *"# error example"* ]] && continue
    reason="$(valid_example "$line")" || problem "README.md example is not valid: $line ($reason)"
done < <(fenced_lines README.md)
set +f

# --- 2. Links, images, paths and anchors --------------------------------------------------------------
docs=(README.md CONTRIBUTING.md SECURITY.md RELEASING.md CHANGELOG.md)
for f in docs/*.md; do docs+=("$f"); done
while IFS= read -r f; do docs+=("$f"); done < <(find .github -name '*.md' | sort)

# GitHub heading slugs of a file, one per line (duplicates get -1, -2, ...).
slugs_of() {
    strip_fences "$1" | awk '
        /^#+ / {
            t = $0; sub(/^#+ +/, "", t); t = tolower(t)
            gsub(/[^a-z0-9 _-]/, "", t); gsub(/ /, "-", t)
            n = seen[t]++
            print (n ? t "-" n : t)
        }'
}

for f in "${docs[@]}"; do
    [[ -f "$f" ]] || { problem "missing documentation file: $f"; continue; }
    dir="$(dirname "$f")"
    # [text](target), ![alt](target), src="..." and srcset="..." outside code fences.
    while IFS= read -r target; do
        case "$target" in
            http://*|https://*|mailto:*|"") continue ;;
        esac
        path="${target%%#*}"
        anchor=""
        [[ "$target" == *"#"* ]] && anchor="${target#*#}"
        path="${path%%\?*}"
        if [[ -z "$path" ]]; then dest="$f"; else
            dest="$dir/$path"
            [[ -e "$dest" ]] || { problem "$f: link target does not exist: $target"; continue; }
        fi
        if [[ -n "$anchor" && -f "$dest" && "$dest" == *.md ]]; then
            slugs_of "$dest" | grep -qxF "$anchor" || problem "$f: no heading for anchor: $target"
        fi
    done < <(
        { strip_fences "$f" | grep -oE '\]\([^) ]+\)' | sed -E 's/^\]\((.*)\)$/\1/'
          strip_fences "$f" | grep -oE '(src|srcset)="[^"]+"' | sed -E 's/^[a-z]+="(.*)"$/\1/'
        } || true)
done

# Repository paths mentioned in .github files (templates point at README, CONTRIBUTING, Tools/...).
while IFS= read -r f; do
    while IFS= read -r p; do
        p="${p%%[.,;:)\`\'\"]}"
        [[ -e "$p" ]] || problem "$f mentions a path that does not exist: $p"
    done < <(grep -oE '\b((README|CONTRIBUTING|SECURITY|CHANGELOG|RELEASING)\.md|(docs|Tools|scripts|Fixtures|Packages|packaging)/[A-Za-z0-9_./-]*[A-Za-z0-9_])' "$f" | sort -u || true)
done < <(find .github -type f \( -name '*.md' -o -name '*.yml' \) | sort)

# --- 3. Forbidden strings -----------------------------------------------------------------------------
# The check itself, and the test that asserts the absence of a home folder path in sample data (it has to
# spell the string), are excluded. The handle onlyilkr is fine: the pattern is 'ilkerg', not 'ilker'.
forbidden='dev\.sennsei\.app|/Users/|/home/|guldali|ilkerg|([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}'
hits="$(git grep -nIiE --untracked "$forbidden" -- . \
    ':!scripts/check-docs.sh' \
    ':!Packages/HeadsetKit/Tests/SennseiCoreTests/PreviewSampleDataTests.swift' || true)"
if [[ -n "$hits" ]]; then
    problem "forbidden strings found:"
    echo "$hits" >&2
fi

if [[ $fail -ne 0 ]]; then
    echo "check-docs: FAILED" >&2
    exit 1
fi
echo "check-docs: ok (${#commands[@]} commands, ${#codes[@]} exit codes, ${#docs[@]} markdown files)"
