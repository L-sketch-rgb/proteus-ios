#!/usr/bin/env bash
# The ONE sanctioned way to build a mirror commit for the public proteus-ios repo.
# usage: scripts/mirror-ios.sh <source-ref> <mirror-clone-dir>
# Makes a LOCAL commit only. Never pushes. The owner runs the push.
# Env: MIRROR_ALLOW_DELETIONS  newline/space list of mirror ios/ files allowed to be deleted.
set -euo pipefail

die() { echo "mirror-ios: REFUSED: $*" >&2; exit 1; }

[ "$#" -eq 2 ] || { echo "usage: $0 <source-ref> <mirror-clone-dir>" >&2; exit 2; }
ref="$1"; dir="$2"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -d "$dir/.git" ] || die "$dir is not a git clone"
dir="$(cd "$dir" && pwd)"

src_sha="$(git -C "$root" rev-parse --verify "$ref^{commit}")" || die "unknown source ref $ref"
short="$(git -C "$root" rev-parse --short "$src_sha")"
subject="$(git -C "$root" log -1 --format=%s "$src_sha")"

# (a) last mirrored sha must be an ancestor of the source ref
# Ignore Revert commits and any "Mirror of <sha>" that a Revert undid.
reverted="$(git -C "$dir" log --format=%s --grep='^Revert "Mirror of ' | sed -n 's/^Revert "Mirror of \([0-9a-f]\{7,40\}\).*/\1/p')"
last_sha=""
while IFS= read -r subj; do
    case "$subj" in "Mirror of "*) ;; *) continue ;; esac
    cand="$(printf '%s\n' "$subj" | sed -n 's/^Mirror of \([0-9a-f]\{7,40\}\).*/\1/p')"
    [ -n "$cand" ] || continue
    if printf '%s\n' "$reverted" | grep -qx "$cand"; then continue; fi
    last_sha="$cand"; break
done < <(git -C "$dir" log --format=%s)
if [ -n "$last_sha" ]; then
    full="$(git -C "$root" rev-parse --verify "$last_sha^{commit}" 2>/dev/null)" \
        || die "last mirrored sha $last_sha is not in this repo"
    git -C "$root" merge-base --is-ancestor "$full" "$src_sha" \
        || die "last mirrored $last_sha is NOT an ancestor of $ref ($short). This would roll the mirror back onto another line. Use the iOS design line (ios-v19 or its descendant)."
else
    echo "mirror-ios: note: no earlier 'Mirror of' commit; skipping ancestor check" >&2
fi

# (c) first, on a fresh export of the new tree (also used for (b))
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
git -C "$root" archive "$src_sha" ios protocol scripts .github | tar -x -C "$tmp"
"$tmp/scripts/owner-scan.sh" --generic-only "$tmp/ios" "$tmp/protocol" "$tmp/scripts" "$tmp/.github" >/dev/null 2>&1 \
    || { "$tmp/scripts/owner-scan.sh" --generic-only "$tmp/ios" "$tmp/protocol" "$tmp/scripts" "$tmp/.github" 2>&1 | head -20 >&2; die "owner-scan --generic-only failed on the new tree"; }

# (b) deletions
old="$(git -C "$dir" ls-files ios | sort)"
new="$(cd "$tmp" && find ios -type f | sort)"
gone="$(comm -23 <(printf '%s\n' "$old") <(printf '%s\n' "$new") | sed '/^$/d')"
if [ -n "$gone" ]; then
    allow="$(printf '%s\n' ${MIRROR_ALLOW_DELETIONS:-} | sed '/^$/d' | sort)"
    unexpected="$(comm -23 <(printf '%s\n' "$gone") <(printf '%s\n' "$allow"))"
    if [ -n "$unexpected" ]; then
        echo "mirror-ios: these mirror files would be DELETED:" >&2
        printf '  %s\n' $unexpected >&2
        die "unexpected deletions; list them in MIRROR_ALLOW_DELETIONS if intended"
    fi
fi

# apply: replace the four trees, keep README/LICENSE/.gitignore
for t in ios protocol scripts .github; do rm -rf "$dir/$t"; cp -a "$tmp/$t" "$dir/$t"; done
git -C "$dir" add -A ios protocol scripts .github
if git -C "$dir" diff --cached --quiet; then echo "mirror-ios: nothing to mirror ($short already in)"; exit 0; fi

ident=()
git -C "$dir" config user.name >/dev/null || ident+=(-c user.name="${GIT_AUTHOR_NAME:-${GIT_COMMITTER_NAME:-proteus-mirror}}")
git -C "$dir" config user.email >/dev/null || ident+=(-c user.email="${GIT_AUTHOR_EMAIL:-${GIT_COMMITTER_EMAIL:-mirror@example.com}}")
git -C "$dir" "${ident[@]}" commit -q -m "Mirror of $short: $subject"
echo "mirrored $short into $dir (local commit only)"
echo "now run: git push origin HEAD:main in $dir"
