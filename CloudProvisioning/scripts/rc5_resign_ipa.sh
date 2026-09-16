#!/bin/bash
set -euo pipefail

log() { printf '[RC5-SIGN] %s\n' "$*"; }
die() { printf '[RC5-SIGN] ERROR: %s\n' "$*" >&2; exit 1; }

: "${INPUT_IPA:?INPUT_IPA is required}"
: "${OUTPUT_IPA:?OUTPUT_IPA is required}"
: "${PROFILE_APP:?PROFILE_APP is required}"
: "${PROFILE_TUNNEL:?PROFILE_TUNNEL is required}"
: "${PROFILE_RUNNER:?PROFILE_RUNNER is required}"
: "${SIGNING_IDENTITY:?SIGNING_IDENTITY is required}"

APP_ID='com.woodypikmin.pikminpilot'
TUNNEL_ID='com.woodypikmin.pikminpilot.tunnel'
RUNNER_ID='com.woodypikmin.pikminpilot.runner.xctrunner'

for f in "$INPUT_IPA" "$PROFILE_APP" "$PROFILE_TUNNEL" "$PROFILE_RUNNER"; do
  [[ -s "$f" ]] || die "missing/empty input: $f"
done

log "Input IPA: $(basename "$INPUT_IPA") ($(stat -f%z "$INPUT_IPA") bytes)"
log "Signing identity: $SIGNING_IDENTITY"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/unpacked"

log 'Extracting IPA...'
/usr/bin/ditto -x -k "$INPUT_IPA" "$WORK/unpacked" || die 'ditto failed to extract IPA'
ROOT_APP="$(find "$WORK/unpacked/Payload" -maxdepth 1 -type d -name '*.app' -print -quit 2>/dev/null || true)"
[[ -n "$ROOT_APP" ]] || die 'No Payload/*.app found in baseline IPA'
log "Root payload app directory: $ROOT_APP"

bundle_id_from_plist() {
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1" 2>/dev/null || true
}

# Search every Info.plist, not just directories with selected suffixes. This is
# intentional: XCTest runner/package layouts can vary while CFBundleIdentifier
# is the stable identity we actually care about.
find_bundle_exact() {
  local wanted="$1" plist bid dir
  while IFS= read -r -d '' plist; do
    bid="$(bundle_id_from_plist "$plist")"
    if [[ "$bid" == "$wanted" ]]; then
      dir="$(dirname "$plist")"
      printf '%s\n' "$dir"
      return 0
    fi
  done < <(find "$ROOT_APP" -type f -name 'Info.plist' -print0)
  return 1
}

log 'Enumerating relevant bundle identifiers in baseline IPA...'
while IFS= read -r -d '' plist; do
  bid="$(bundle_id_from_plist "$plist")"
  case "$bid" in
    com.woodypikmin.pikminpilot*) printf '[RC5-SIGN]   %s -> %s\n' "$bid" "$(dirname "$plist")" ;;
  esac
done < <(find "$ROOT_APP" -type f -name 'Info.plist' -print0)

APP_PATH="$(find_bundle_exact "$APP_ID" || true)"
TUNNEL_PATH="$(find_bundle_exact "$TUNNEL_ID" || true)"
RUNNER_PATH="$(find_bundle_exact "$RUNNER_ID" || true)"

[[ -n "$APP_PATH" ]] || die "Could not locate exact bundle id $APP_ID"
[[ -n "$TUNNEL_PATH" ]] || die "Could not locate exact bundle id $TUNNEL_ID"
[[ -n "$RUNNER_PATH" ]] || die "Could not locate exact bundle id $RUNNER_ID"

log "App:    $APP_PATH"
log "Tunnel: $TUNNEL_PATH"
log "Runner: $RUNNER_PATH"

extract_entitlements() {
  local target="$1" out="$2"
  /usr/bin/codesign -d --entitlements :- "$target" > "$out" 2>/dev/null || true
  grep -q '<plist' "$out" || die "Unable to extract entitlements from $target"
}

APP_ENT="$WORK/app.entitlements.plist"
TUNNEL_ENT="$WORK/tunnel.entitlements.plist"
RUNNER_ENT="$WORK/runner.entitlements.plist"
log 'Extracting exact entitlements from known-good payload...'
extract_entitlements "$APP_PATH" "$APP_ENT"
extract_entitlements "$TUNNEL_PATH" "$TUNNEL_ENT"
extract_entitlements "$RUNNER_PATH" "$RUNNER_ENT"

profile_check() {
  local label="$1" profile="$2" wanted="$3" decoded="$WORK/profile-$label.plist" appid
  /usr/bin/security cms -D -i "$profile" > "$decoded" || die "Cannot decode $label provisioning profile"
  appid="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "$decoded" 2>/dev/null || true)"
  [[ -n "$appid" ]] || die "$label profile has no application-identifier entitlement"
  case "$appid" in
    *.$wanted) ;;
    *) die "$label profile application-identifier '$appid' does not match '$wanted'" ;;
  esac
  log "$label profile OK: $appid"
}

log 'Validating generated provisioning profiles...'
profile_check app "$PROFILE_APP" "$APP_ID"
profile_check tunnel "$PROFILE_TUNNEL" "$TUNNEL_ID"
profile_check runner "$PROFILE_RUNNER" "$RUNNER_ID"

cp "$PROFILE_APP" "$APP_PATH/embedded.mobileprovision"
cp "$PROFILE_TUNNEL" "$TUNNEL_PATH/embedded.mobileprovision"
cp "$PROFILE_RUNNER" "$RUNNER_PATH/embedded.mobileprovision"

sign_plain() {
  /usr/bin/codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none "$1"
}

sign_with_entitlements() {
  local target="$1" ent="$2"
  /usr/bin/codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none --entitlements "$ent" "$target"
}

log 'Re-signing dylibs (deepest first)...'
while IFS= read -r p; do
  [[ -n "$p" ]] || continue
  sign_plain "$p"
done < <(find "$ROOT_APP" -type f -name '*.dylib' -print | awk '{ print length, $0 }' | sort -rn | cut -d' ' -f2-)

log 'Re-signing frameworks (deepest first)...'
while IFS= read -r p; do
  [[ -n "$p" ]] || continue
  sign_plain "$p"
done < <(find "$ROOT_APP" -type d -name '*.framework' -print | awk '{ print length, $0 }' | sort -rn | cut -d' ' -f2-)

resign_preserving() {
  local p="$1" ent="$WORK/preserve.$RANDOM.$RANDOM.plist"
  /usr/bin/codesign -d --entitlements :- "$p" > "$ent" 2>/dev/null || true
  if grep -q '<plist' "$ent"; then
    sign_with_entitlements "$p" "$ent"
  else
    sign_plain "$p"
  fi
  rm -f "$ent"
}

log 'Re-signing other nested bundles deepest-first while preserving their entitlements...'
while IFS= read -r p; do
  [[ -n "$p" ]] || continue
  [[ "$p" == "$APP_PATH" || "$p" == "$TUNNEL_PATH" || "$p" == "$RUNNER_PATH" ]] && continue
  resign_preserving "$p"
done < <(find "$ROOT_APP" -type d \( -name '*.xctest' -o -name '*.appex' -o -name '*.app' -o -name '*.xctrunner' \) -print | awk '{ print length, $0 }' | sort -rn | cut -d' ' -f2-)

log 'Signing Tunnel with preserved known-good entitlements + new profile...'
sign_with_entitlements "$TUNNEL_PATH" "$TUNNEL_ENT"
log 'Signing Runner with preserved 1153-xfix entitlements + new profile...'
sign_with_entitlements "$RUNNER_PATH" "$RUNNER_ENT"
log 'Signing root app last...'
sign_with_entitlements "$APP_PATH" "$APP_ENT"

log 'Verifying signatures...'
/usr/bin/codesign --verify --strict --verbose=2 "$TUNNEL_PATH" || die 'Tunnel codesign verification failed'
/usr/bin/codesign --verify --strict --verbose=2 "$RUNNER_PATH" || die 'Runner codesign verification failed'
/usr/bin/codesign --verify --strict --verbose=2 "$APP_PATH" || die 'App codesign verification failed'

[[ "$(bundle_id_from_plist "$APP_PATH/Info.plist")" == "$APP_ID" ]] || die 'App bundle id changed unexpectedly'
[[ "$(bundle_id_from_plist "$TUNNEL_PATH/Info.plist")" == "$TUNNEL_ID" ]] || die 'Tunnel bundle id changed unexpectedly'
[[ "$(bundle_id_from_plist "$RUNNER_PATH/Info.plist")" == "$RUNNER_ID" ]] || die 'Runner bundle id changed unexpectedly'

rm -f "$OUTPUT_IPA"
log 'Packing signed IPA...'
(
  cd "$WORK/unpacked"
  /usr/bin/zip -qry -y "$OUTPUT_IPA" .
)
[[ -s "$OUTPUT_IPA" ]] || die 'Output IPA was not created'
log "Created: $OUTPUT_IPA ($(stat -f%z "$OUTPUT_IPA") bytes)"
log "SHA256: $(shasum -a 256 "$OUTPUT_IPA" | awk '{print $1}')"
