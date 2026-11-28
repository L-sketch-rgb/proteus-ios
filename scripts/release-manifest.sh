#!/bin/sh
# release-manifest.sh <tag> <asset...> — write and sign a release manifest.
#
# Owner-only tool (v14 §4): `manifest.json` lists the version, commit, commit
# count and every asset's sha256; `manifest.sig` is the Ed25519 signature over
# the exact manifest.json bytes, made with release-key/publisher.key (generated
# by scripts/release-keygen.sh). Upload both files beside the assets.
#
# Refuses to run in CI: the signing key must never reach an automated job.
set -eu

if [ -n "${CI:-}" ]; then
  echo "release-manifest: refusing to run in CI" >&2
  exit 1
fi
if [ "$#" -lt 2 ]; then
  echo "usage: scripts/release-manifest.sh <tag> <asset...>" >&2
  exit 1
fi

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
KEY=${PROTEUS_RELEASE_KEY:-"$ROOT/release-key/publisher.key"}
if [ ! -f "$KEY" ]; then
  echo "release-manifest: no private key at $KEY (run scripts/release-keygen.sh)" >&2
  exit 1
fi

TAG=$1
shift
COMMIT=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo "")
COMMIT=$(printf '%s' "$COMMIT" | cut -c1-12)
COUNT=$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 0)

cd "$ROOT/hub"
GIT_COMMIT="$COMMIT" GIT_COUNT="$COUNT" node --input-type=module -e '
import { readFileSync, writeFileSync } from "node:fs";
import { basename } from "node:path";
import { createHash } from "node:crypto";
import { ed25519 } from "@noble/curves/ed25519.js";
const [tag, keyPath, ...files] = process.argv.slice(1);
const secret = Buffer.from(readFileSync(keyPath, "utf8").trim(), "hex");
if (secret.length !== 32) {
  console.error("release-manifest: the private key must be 32 bytes of hex");
  process.exit(1);
}
const assets = files.map((path) => {
  const bytes = readFileSync(path);
  return {
    name: basename(path),
    sha256: createHash("sha256").update(bytes).digest("hex"),
    size: bytes.length,
  };
});
const manifest = {
  version: tag.replace(/^v/, ""),
  tag,
  commit: process.env.GIT_COMMIT ?? "",
  count: Number.parseInt(process.env.GIT_COUNT ?? "0", 10) || 0,
  assets,
};
const bytes = Buffer.from(JSON.stringify(manifest, null, 2) + "\n");
writeFileSync("manifest.json", bytes);
writeFileSync("manifest.sig", Buffer.from(ed25519.sign(bytes, secret)).toString("hex") + "\n");
console.log("wrote hub/manifest.json (version " + manifest.version + ", " + assets.length + " asset(s))");
console.log("wrote hub/manifest.sig");
' "$TAG" "$KEY" "$@"
