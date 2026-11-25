#!/usr/bin/env bash
# Writes <dir>/update.json (the version, plus the size and SHA-256 of every release file) and <dir>/update.json.sig,
# its Ed25519 signature. The app installs an update only if this verifies against lib/update/update_key.dart.
#   UPDATE_SIGNING_KEY="$(cat update-signing-key.pem)" tool/sign_update.sh <dir> 1.2.3
set -euo pipefail
dir=$1
version=$2
if [ -z "${UPDATE_SIGNING_KEY:-}" ]; then
  echo "::error::The secret UPDATE_SIGNING_KEY is not set (see README). Refusing to publish a release the app cannot verify." >&2
  exit 1
fi
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
(umask 077 && printf '%s\n' "$UPDATE_SIGNING_KEY" > "$tmp/key.pem")

# It must be the key the app trusts, or nobody could install this release from inside the app.
public=$(openssl pkey -in "$tmp/key.pem" -pubout -outform DER | tail -c 32 | base64 -w0)
if ! grep -qF "'$public'" "$root/lib/update/update_key.dart"; then
  echo "::error::UPDATE_SIGNING_KEY does not match the public key in lib/update/update_key.dart" >&2
  exit 1
fi

rm -f "$dir/update.json" "$dir/update.json.sig"
python3 -I - "$dir" "$version" <<'PY'
import hashlib, json, os, sys
folder, version = sys.argv[1], sys.argv[2]
files = {}
for name in sorted(os.listdir(folder)):
    path = os.path.join(folder, name)
    if os.path.isfile(path):
        h = hashlib.sha256()
        with open(path, "rb") as f:
            for block in iter(lambda: f.read(1 << 20), b""):
                h.update(block)
        files[name] = {"size": os.path.getsize(path), "sha256": h.hexdigest()}
if not files:
    sys.exit("no release files in " + folder)
with open(os.path.join(folder, "update.json"), "w") as f:
    json.dump({"version": version, "files": files}, f, indent=2)
PY
openssl pkeyutl -sign -inkey "$tmp/key.pem" -rawin -in "$dir/update.json" -out "$tmp/sig"
openssl pkey -in "$tmp/key.pem" -pubout -out "$tmp/pub.pem"
openssl pkeyutl -verify -pubin -inkey "$tmp/pub.pem" -rawin -in "$dir/update.json" -sigfile "$tmp/sig" >/dev/null
base64 -w0 "$tmp/sig" > "$dir/update.json.sig"
echo "Signed update.json for $version"
