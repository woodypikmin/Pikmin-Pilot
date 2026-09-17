#!/usr/bin/env bash
set -euo pipefail

IPA="${1:?usage: make-release-kit.sh <signed-ipa> <output-dir>}"
OUT="${2:?usage: make-release-kit.sh <signed-ipa> <output-dir>}"
VERSION="${PIKMIN_RELEASE_VERSION:-11.5.4.12}"
BUILD="${PIKMIN_RELEASE_BUILD:-1153}"
PAIRING_MODE="${PIKMIN_PAIRING_MODE:-GENERIC}"

rm -rf "$OUT"
mkdir -p "$OUT"
cp "$IPA" "$OUT/PikminPilot-${VERSION}.ipa"
cp Distribution/README_FIRST.txt "$OUT/README_FIRST.txt"
cp Distribution/PAIRING_MODES.txt "$OUT/PAIRING_MODES.txt"

SHA256="$(shasum -a 256 "$OUT/PikminPilot-${VERSION}.ipa" | awk '{print $1}')"
cat > "$OUT/SHA256.txt" <<TXT
${SHA256}  PikminPilot-${VERSION}.ipa
TXT

python3 - "$OUT/RELEASE-INFO.json" "$VERSION" "$BUILD" "$PAIRING_MODE" "$SHA256" <<'PY'
import json, sys
from pathlib import Path
out, version, build, mode, sha = sys.argv[1:]
obj = {
  "product": "Pikmin Pilot",
  "marketing_version": version,
  "build": build,
  "baseline": "Stage 11.5.3",
  "runner_revision": "1153-xfix",
  "pairing_mode": mode,
  "integrated_tunnel": True,
  "cellular_model": "persistent RSD warm session; cold bootstrap may require temporary Airplane Mode",
  "ipa_sha256": sha,
}
Path(out).write_text(json.dumps(obj, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
PY

# Safety: end-user kit must not accidentally contain signing secrets or raw profile files.
if find "$OUT" -type f \( -name '*.p12' -o -name '*.mobileprovision' -o -name 'rp_pairing_file.plist' \) | grep -q .; then
  echo "Refusing to package sensitive signing/pairing material" >&2
  exit 9
fi

printf 'Release kit ready: %s\n' "$OUT"
