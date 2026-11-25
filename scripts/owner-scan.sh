#!/usr/bin/env bash
# Owner-data scan (v11 §5). Fails when shipped code contains personal data:
# the owner's denylist (an untracked local file) plus generic patterns.
#
# usage: scripts/owner-scan.sh [--generic-only] [path...]
#
#   --generic-only  skip the local denylist (CI and public export)
#   path...         files or folders to scan (default: the shipped trees)
#
# The denylist path can be overridden with PROTEUS_OWNER_DENYLIST (tests use
# this); its default is $XDG_CONFIG_HOME/proteus-dev/owner-denylist. It is
# never committed and never printed as a whole.
#
# Generic patterns: /mnt/ paths, /home/<name>/ (except /home/user/), IPv4
# addresses outside the documentation ranges, and emails other than
# @example.com. Test fixtures may keep fake data; the scan does not know
# which lines are fixtures, so use /home/user, 192.0.2.x and @example.com.
set -euo pipefail

generic_only=0
if [ "${1:-}" = "--generic-only" ]; then
    generic_only=1
    shift
fi

script_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
repo_root="$(cd "$(dirname "$script_path")/.." && pwd)"

if [ "$#" -eq 0 ]; then
    set -- "$repo_root/hub" "$repo_root/linux" "$repo_root/ios" \
           "$repo_root/protocol" "$repo_root/scripts"
    for extra in README.md INSTALL.md CHANGELOG.md LICENSE VERSION; do
        [ -f "$repo_root/$extra" ] && set -- "$@" "$repo_root/$extra"
    done
fi

skip_path() {
    case "$1" in
        */node_modules/*|*/.git/*|*/build/*|*/3rdparty/*|*/docs/*|*/art/*|*/export/*)
            return 0 ;;
        *.png|*.jpg|*.jpeg|*.gif|*.webp|*.ico|*.icns|*.pdf|*.zip|*.gz|*.xz)
            return 0 ;;
        "$script_path")
            return 0 ;;
    esac
    return 1
}

collect() {
    for path in "$@"; do
        if [ -d "$path" ]; then
            while IFS= read -r file; do
                skip_path "$file" || printf '%s\n' "$file"
            done < <(find "$path" -type f 2>/dev/null)
        elif [ -f "$path" ]; then
            skip_path "$path" || printf '%s\n' "$path"
        fi
    done
}

files="$(mktemp)"
deny_patterns=""
cleanup() {
    rm -f "$files"
    if [ -n "$deny_patterns" ]; then
        rm -f "$deny_patterns"
    fi
}
trap cleanup EXIT INT TERM
collect "$@" > "$files"

hits=0
report_hit() {
    printf '%s\n' "$1"
    hits=$((hits + 1))
}

# --- the owner's untracked denylist ---------------------------------------
if [ "$generic_only" -eq 0 ]; then
    denylist="${PROTEUS_OWNER_DENYLIST:-${XDG_CONFIG_HOME:-$HOME/.config}/proteus-dev/owner-denylist}"
    if [ -f "$denylist" ]; then
        deny_patterns="$(mktemp)"
        grep -vE '^[[:space:]]*(#|$)' "$denylist" > "$deny_patterns" || true
        if [ -s "$deny_patterns" ]; then
            while IFS= read -r file; do
                while IFS= read -r line; do
                    [ -n "$line" ] && report_hit "denylist: $file: $line"
                done < <(grep -nFi -f "$deny_patterns" "$file" 2>/dev/null || true)
            done < "$files"
        fi
    fi
fi

# --- generic patterns ------------------------------------------------------
while IFS= read -r file; do
    while IFS= read -r line; do
        report_hit "home path: $file: $line"
    done < <(grep -nIE '/(home|Users)/[A-Za-z0-9._-]+' "$file" 2>/dev/null \
                 | grep -vE '/(home|Users)/user([^A-Za-z0-9._-]|$)' || true)

    while IFS= read -r line; do
        report_hit "mnt path: $file: $line"
    done < <(grep -nIF '/mnt/' "$file" 2>/dev/null || true)

    while IFS= read -r line; do
        report_hit "email: $file: $line"
    done < <(grep -nIoE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' "$file" 2>/dev/null \
                 | grep -viE '@example\.com$' || true)

    while IFS=: read -r line ip; do
        [ -n "$ip" ] || continue
        case "$ip" in
            127.*|0.0.0.0|192.0.2.*|198.51.100.*|203.0.113.*|100.64.0.1|255.255.255.255)
                ;;
            *)
                report_hit "non-documentation IP: $file: $line: $ip"
                ;;
        esac
    done < <(grep -nIoE '([0-9]{1,3}\.){3}[0-9]{1,3}' "$file" 2>/dev/null || true)
done < "$files"

if [ "$hits" -ne 0 ]; then
    echo "owner-scan: $hits hit(s); remove them or add a fake fixture value" >&2
    exit 1
fi
echo "owner-scan: clean"
