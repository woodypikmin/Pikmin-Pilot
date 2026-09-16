#!/bin/bash
set -euo pipefail

: "${INPUT_IPA:?}"
: "${OUTPUT_IPA:?}"
: "${PROFILE_APP:?}"
: "${PROFILE_TUNNEL:?}"
: "${PROFILE_RUNNER:?}"
: "${SIGNING_IDENTITY:?}"

APP_ID='com.woodypikmin.pikminpilot'
TUNNEL_ID='com.woodypikmin.pikminpilot.tunnel'
RUNNER_ID='com.woodypikmin.pikminpilot.runner.xctrunner'

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
/usr/bin/ditto -x -k "$INPUT_IPA" "$WORK/unpacked"
ROOT_APP="$(find "$WORK/unpacked/Payload" -maxdepth 1 -type d -name '*.app' -print -quit)"
[[ -n "$ROOT_APP" ]] || { echo 'No Payload/*.app found'; exit 2; }

bundle_id() {
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Info.plist" 2>/dev/null || true
}

find_bundle() {
  local wanted="$1"
  while IFS= read -r -d '' p; do
    if [[ "$(bundle_id "$p")" == "$wanted" ]]; then
      printf '%s\n' "$p"
      return 0
    fi
  done < <(find "$ROOT_APP" -type d \( -name '*.app' -o -name '*.appex' \) -print0)
  return 1
}

APP_PATH="$(find_bundle "$APP_ID")"
TUNNEL_PATH="$(find_bundle "$TUNNEL_ID")"
RUNNER_PATH="$(find_bundle "$RUNNER_ID")"
[[ -n "$APP_PATH" && -n "$TUNNEL_PATH" && -n "$RUNNER_PATH" ]] || {
  echo 'Could not locate all three verified bundle IDs.'
  echo "app=$APP_PATH tunnel=$TUNNEL_PATH runner=$RUNNER_PATH"
  exit 3
}

echo "Root app: $APP_PATH"
echo "Tunnel:   $TUNNEL_PATH"
echo "Runner:   $RUNNER_PATH"

# Freeze the exact entitlements from the known-good 11.5.4.17 payload BEFORE re-signing.
# New registered devices change provisioning profiles, not the app's entitlement design.
extract_entitlements() {
  local target="$1" out="$2"
  /usr/bin/codesign -d --entitlements :- "$target" > "$out" 2>/dev/null || true
  if ! grep -q '<plist' "$out"; then
    echo "Unable to extract entitlements from $target" >&2
    exit 4
  fi
}

APP_ENT="$WORK/app.entitlements.plist"
TUNNEL_ENT="$WORK/tunnel.entitlements.plist"
RUNNER_ENT="$WORK/runner.entitlements.plist"
extract_entitlements "$APP_PATH" "$APP_ENT"
extract_entitlements "$TUNNEL_PATH" "$TUNNEL_ENT"
extract_entitlements "$RUNNER_PATH" "$RUNNER_ENT"

cp "$PROFILE_APP" "$APP_PATH/embedded.mobileprovision"
cp "$PROFILE_TUNNEL" "$TUNNEL_PATH/embedded.mobileprovision"
cp "$PROFILE_RUNNER" "$RUNNER_PATH/embedded.mobileprovision"

# Frameworks / dylibs first. They normally have no app entitlements.
while IFS= read -r -d '' f; do
  /usr/bin/codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none "$f"
done < <(find "$ROOT_APP" \( -type d -name '*.framework' -o -type f -name '*.dylib' \) -print0)

# Preserve exact entitlements for nested XCTest/apps/appex that are NOT the three targets.
resign_preserving() {
  local p="$1" ent="$WORK/preserve.$RANDOM.$RANDOM.plist"
  /usr/bin/codesign -d --entitlements :- "$p" > "$ent" 2>/dev/null || true
  if grep -q '<plist' "$ent"; then
    /usr/bin/codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none --entitlements "$ent" "$p"
  else
    /usr/bin/codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none "$p"
  fi
  rm -f "$ent"
}

# Deepest nested code first so outer signatures remain valid.
while IFS= read -r p; do
  [[ "$p" == "$APP_PATH" || "$p" == "$TUNNEL_PATH" || "$p" == "$RUNNER_PATH" ]] && continue
  resign_preserving "$p"
done < <(find "$ROOT_APP" -type d \( -name '*.xctest' -o -name '*.appex' -o -name '*.app' \) -print | awk '{ print length, $0 }' | sort -rn | cut -d' ' -f2-)

/usr/bin/codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none --entitlements "$TUNNEL_ENT" "$TUNNEL_PATH"
/usr/bin/codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none --entitlements "$RUNNER_ENT" "$RUNNER_PATH"
/usr/bin/codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none --entitlements "$APP_ENT" "$APP_PATH"

/usr/bin/codesign --verify --strict --verbose=2 "$TUNNEL_PATH"
/usr/bin/codesign --verify --strict --verbose=2 "$RUNNER_PATH"
/usr/bin/codesign --verify --strict --verbose=2 "$APP_PATH"

# Prove bundle identifiers were not changed.
[[ "$(bundle_id "$APP_PATH")" == "$APP_ID" ]]
[[ "$(bundle_id "$TUNNEL_PATH")" == "$TUNNEL_ID" ]]
[[ "$(bundle_id "$RUNNER_PATH")" == "$RUNNER_ID" ]]

rm -f "$OUTPUT_IPA"
(
  cd "$WORK/unpacked"
  /usr/bin/zip -qry -y "$OUTPUT_IPA" .
)

echo "Created: $OUTPUT_IPA"
