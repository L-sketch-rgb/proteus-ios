#!/usr/bin/env bash
# Publish the iOS tree to the public mirror repo, which is where the iOS build
# actually runs: standard runners are free on public repositories, and the
# private repo's macOS minutes are not.
#
# usage: scripts/publish-ios-mirror.sh [ref] [-m "message"]
#
#   ref        commit or branch to publish (default: HEAD)
#   -m         commit message for the mirror (default: describes the source commit)
#
# The mirror gets ios/, protocol/, scripts/owner-scan.sh, the ios workflow and
# LICENSE, and nothing else. Its own README.md and .gitignore are maintained in
# the mirror and are not touched. History is not carried over: the mirror is a
# snapshot, one commit per publish.
#
# Two guards: the source tree must pass the owner-data scan, and the mirror
# working copy must have no uncommitted changes of its own.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Sibling of the current worktree by default; no absolute path, which the
# owner-data scan (rightly) flags on sight.
mirror="${PROTEUS_IOS_MIRROR:-$repo_root/../ios-mirror}"
ref="HEAD"
message=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        -m) message="${2:?-m needs a message}"; shift 2 ;;
        -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) ref="$1"; shift ;;
    esac
done

if [ ! -d "$mirror/.git" ]; then
    echo "publish-ios-mirror: no mirror repo at $mirror" >&2
    exit 1
fi

cd "$repo_root"
sha="$(git rev-parse --short "$ref")"
subject="$(git log -1 --format=%s "$ref")"

# Refuse to publish what the scan would fail on in CI anyway.
scripts/owner-scan.sh --generic-only "$repo_root/ios" "$repo_root/protocol" \
    "$repo_root/scripts" "$repo_root/README.md"

cd "$mirror"
if [ -n "$(git status --porcelain)" ]; then
    echo "publish-ios-mirror: $mirror has uncommitted changes; resolve them first" >&2
    exit 1
fi

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT INT TERM
git -C "$repo_root" archive "$ref" ios protocol scripts/owner-scan.sh \
    .github/workflows/ios.yml LICENSE | tar -x -C "$stage"

rsync -a --delete \
    --exclude '.git/' --exclude 'README.md' --exclude '.gitignore' \
    "$stage"/ "$mirror"/

if [ -z "$(git status --porcelain)" ]; then
    echo "publish-ios-mirror: mirror already matches $sha; nothing to publish"
    exit 0
fi

[ -n "$message" ] || message="Mirror of $sha: $subject"
git add -A
git -c user.name=dev -c user.email=dev@local commit -q -m "$message"
git push -q origin HEAD
echo "publish-ios-mirror: pushed $sha to $(git remote get-url origin)"
echo "  $(gh run list --limit 1 --json url --jq '.[0].url' 2>/dev/null || echo 'run: gh run list')"
