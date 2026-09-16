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
EMBEDDED_RUNNER_NAME='PikminPilotEmbeddedRunner.ipa'
EMBEDDED_RUNNER_METADATA_NAME='PikminPilotEmbeddedRunnerMetadata.plist'

for f in "$INPUT_IPA" "$PROFILE_APP" "$PROFILE_TUNNEL" "$PROFILE_RUNNER"; do
  [[ -s "$f" ]] || die "missing/empty input: $f"
done

log "Input IPA: $(basename "$INPUT_IPA") ($(stat -f%z "$INPUT_IPA") bytes)"
log "Signing identity: $SIGNING_IDENTITY"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
OUTER="$WORK/outer"
RUNNER_WORK="$WORK/runner"
mkdir -p "$OUTER" "$RUNNER_WORK"

bundle_id_from_plist() {
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1" 2>/dev/null || true
}

find_bundle_exact_under() {
  local root="$1" wanted="$2" plist bid
  while IFS= read -r -d '' plist; do
    bid="$(bundle_id_from_plist "$plist")"
    if [[ "$bid" == "$wanted" ]]; then
      dirname "$plist"
      return 0
    fi
  done < <(find "$root" -type f -name 'Info.plist' -print0)
  return 1
}

extract_entitlements() {
  local target="$1" out="$2"
  /usr/bin/codesign -d --entitlements :- "$target" > "$out" 2>/dev/null || true
  grep -q '<plist' "$out" || die "Unable to extract entitlements from $target"
}

sign_plain() {
  /usr/bin/codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none "$1"
}

sign_with_entitlements() {
  local target="$1" ent="$2"
  /usr/bin/codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none --entitlements "$ent" "$target"
}

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

profile_decode() {
  local profile="$1" out="$2"
  /usr/bin/security cms -D -i "$profile" > "$out" || die "Cannot decode provisioning profile: $profile"
}

profile_check() {
  local label="$1" profile="$2" wanted="$3" decoded="$WORK/profile-$label.plist" appid
  profile_decode "$profile" "$decoded"
  appid="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "$decoded" 2>/dev/null || true)"
  [[ -n "$appid" ]] || die "$label profile has no application-identifier entitlement"
  case "$appid" in
    *.$wanted) ;;
    *) die "$label profile application-identifier '$appid' does not match '$wanted'" ;;
  esac
  log "$label profile OK: $appid"
}

# ---------- Validate generated profiles first ----------
log 'Validating generated provisioning profiles...'
profile_check app "$PROFILE_APP" "$APP_ID"
profile_check tunnel "$PROFILE_TUNNEL" "$TUNNEL_ID"
profile_check runner "$PROFILE_RUNNER" "$RUNNER_ID"

# ---------- Outer host IPA ----------
log 'Extracting outer Pikmin Pilot IPA...'
/usr/bin/ditto -x -k "$INPUT_IPA" "$OUTER" || die 'ditto failed to extract outer IPA'
ROOT_APP="$(find "$OUTER/Payload" -maxdepth 1 -type d -name '*.app' -print -quit 2>/dev/null || true)"
[[ -n "$ROOT_APP" ]] || die 'No Payload/*.app found in baseline IPA'
log "Root payload app: $ROOT_APP"

APP_PATH="$(find_bundle_exact_under "$ROOT_APP" "$APP_ID" || true)"
TUNNEL_PATH="$(find_bundle_exact_under "$ROOT_APP" "$TUNNEL_ID" || true)"
[[ -n "$APP_PATH" ]] || die "Could not locate outer App bundle id $APP_ID"
[[ -n "$TUNNEL_PATH" ]] || die "Could not locate Tunnel bundle id $TUNNEL_ID"
log "Host App: $APP_PATH"
log "Tunnel:   $TUNNEL_PATH"

# The known-good 11.5.4.17 host stores 1153-xfix Runner as a nested IPA resource.
EMBEDDED_RUNNER_IPA="$(find "$ROOT_APP" -type f -name "$EMBEDDED_RUNNER_NAME" -print -quit 2>/dev/null || true)"
if [[ -z "$EMBEDDED_RUNNER_IPA" ]]; then
  log 'IPA resources found under host app:'
  find "$ROOT_APP" -type f -name '*.ipa' -print | sed 's/^/[RC5-SIGN]   /' || true
  die "$EMBEDDED_RUNNER_NAME not found inside host app"
fi
log "Embedded Runner IPA: $EMBEDDED_RUNNER_IPA ($(stat -f%z "$EMBEDDED_RUNNER_IPA") bytes)"

APP_ENT="$WORK/app.entitlements.plist"
TUNNEL_ENT="$WORK/tunnel.entitlements.plist"
log 'Extracting known-good host/tunnel entitlements...'
extract_entitlements "$APP_PATH" "$APP_ENT"
extract_entitlements "$TUNNEL_PATH" "$TUNNEL_ENT"

# ---------- Nested 1153-xfix Runner IPA ----------
log 'Extracting embedded 1153-xfix Runner IPA...'
/usr/bin/ditto -x -k "$EMBEDDED_RUNNER_IPA" "$RUNNER_WORK" || die 'ditto failed to extract embedded Runner IPA'
RUNNER_PATH="$(find_bundle_exact_under "$RUNNER_WORK" "$RUNNER_ID" || true)"
if [[ -z "$RUNNER_PATH" ]]; then
  log 'Bundle identifiers found in embedded Runner IPA:'
  while IFS= read -r -d '' plist; do
    bid="$(bundle_id_from_plist "$plist")"
    [[ -n "$bid" ]] && printf '[RC5-SIGN]   %s -> %s\n' "$bid" "$(dirname "$plist")"
  done < <(find "$RUNNER_WORK" -type f -name 'Info.plist' -print0)
  die "Could not locate exact embedded Runner bundle id $RUNNER_ID"
fi
log "1153-xfix Runner: $RUNNER_PATH"

RUNNER_ENT="$WORK/runner.entitlements.plist"
log 'Extracting exact entitlements from known-good 1153-xfix Runner...'
extract_entitlements "$RUNNER_PATH" "$RUNNER_ENT"

# Replace only the Runner app's provisioning profile. Nested xctest/frameworks keep
# their payload/entitlements and are re-signed with the same Development identity.
cp "$PROFILE_RUNNER" "$RUNNER_PATH/embedded.mobileprovision"

log 'Re-signing Runner dylibs (deepest first)...'
while IFS= read -r p; do
  [[ -n "$p" ]] || continue
  sign_plain "$p"
done < <(find "$RUNNER_PATH" -type f -name '*.dylib' -print | awk '{ print length, $0 }' | sort -rn | cut -d' ' -f2-)

log 'Re-signing Runner frameworks (deepest first)...'
while IFS= read -r p; do
  [[ -n "$p" ]] || continue
  sign_plain "$p"
done < <(find "$RUNNER_PATH" -type d -name '*.framework' -print | awk '{ print length, $0 }' | sort -rn | cut -d' ' -f2-)

log 'Re-signing Runner nested bundles while preserving known-good entitlements...'
while IFS= read -r p; do
  [[ -n "$p" ]] || continue
  [[ "$p" == "$RUNNER_PATH" ]] && continue
  resign_preserving "$p"
done < <(find "$RUNNER_PATH" -type d \( -name '*.xctest' -o -name '*.appex' -o -name '*.app' -o -name '*.xctrunner' \) -print | awk '{ print length, $0 }' | sort -rn | cut -d' ' -f2-)

log 'Signing 1153-xfix Runner with preserved entitlements + NEW Runner profile...'
sign_with_entitlements "$RUNNER_PATH" "$RUNNER_ENT"
/usr/bin/codesign --verify --strict --verbose=2 "$RUNNER_PATH" || die 'Runner codesign verification failed'
[[ "$(bundle_id_from_plist "$RUNNER_PATH/Info.plist")" == "$RUNNER_ID" ]] || die 'Runner bundle id changed unexpectedly'

# Repack the nested IPA back into the exact host-app resource location.
rm -f "$EMBEDDED_RUNNER_IPA"
log 'Packing refreshed embedded Runner IPA back into host app...'
(
  cd "$RUNNER_WORK"
  /usr/bin/zip -qry -y "$EMBEDDED_RUNNER_IPA" .
)
[[ -s "$EMBEDDED_RUNNER_IPA" ]] || die 'Refreshed embedded Runner IPA was not created'
log "Refreshed embedded Runner IPA: $(stat -f%z "$EMBEDDED_RUNNER_IPA") bytes"

# Refresh display metadata if this resource exists. Failure here is non-fatal;
# it is UI metadata only and does not affect provisioning/signature validity.
RUNNER_META="$(find "$ROOT_APP" -type f -name "$EMBEDDED_RUNNER_METADATA_NAME" -print -quit 2>/dev/null || true)"
if [[ -n "$RUNNER_META" ]]; then
  RUNNER_PROFILE_DECODED="$WORK/profile-runner-meta.plist"
  profile_decode "$PROFILE_RUNNER" "$RUNNER_PROFILE_DECODED"
  TEAM_ID="$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$RUNNER_PROFILE_DECODED" 2>/dev/null || true)"
  EXPIRATION="$(/usr/libexec/PlistBuddy -c 'Print :ExpirationDate' "$RUNNER_PROFILE_DECODED" 2>/dev/null || true)"
  log "Embedded Runner metadata resource found: $RUNNER_META"
  [[ -n "$TEAM_ID" ]] && /usr/libexec/PlistBuddy -c "Set :TeamIdentifier $TEAM_ID" "$RUNNER_META" >/dev/null 2>&1 || true
  # PlistBuddy date formatting varies; keep existing ExpirationDate if it cannot be safely replaced.
  log "Runner profile team=$TEAM_ID expiration=$EXPIRATION"
else
  log 'Embedded Runner metadata plist not found; skipping metadata refresh.'
fi

# ---------- Re-sign outer Tunnel + host App ----------
cp "$PROFILE_TUNNEL" "$TUNNEL_PATH/embedded.mobileprovision"
cp "$PROFILE_APP" "$APP_PATH/embedded.mobileprovision"

log 'Re-signing outer dylibs (deepest first)...'
while IFS= read -r p; do
  [[ -n "$p" ]] || continue
  sign_plain "$p"
done < <(find "$ROOT_APP" -type f -name '*.dylib' -print | awk '{ print length, $0 }' | sort -rn | cut -d' ' -f2-)

log 'Re-signing outer frameworks (deepest first)...'
while IFS= read -r p; do
  [[ -n "$p" ]] || continue
  sign_plain "$p"
done < <(find "$ROOT_APP" -type d -name '*.framework' -print | awk '{ print length, $0 }' | sort -rn | cut -d' ' -f2-)

log 'Re-signing other outer nested bundles while preserving entitlements...'
while IFS= read -r p; do
  [[ -n "$p" ]] || continue
  [[ "$p" == "$APP_PATH" || "$p" == "$TUNNEL_PATH" ]] && continue
  resign_preserving "$p"
done < <(find "$ROOT_APP" -type d \( -name '*.xctest' -o -name '*.appex' -o -name '*.app' -o -name '*.xctrunner' \) -print | awk '{ print length, $0 }' | sort -rn | cut -d' ' -f2-)

log 'Signing Tunnel with preserved known-good entitlements + NEW Tunnel profile...'
sign_with_entitlements "$TUNNEL_PATH" "$TUNNEL_ENT"
log 'Signing root App last with preserved known-good entitlements + NEW App profile...'
sign_with_entitlements "$APP_PATH" "$APP_ENT"

log 'Verifying outer signatures...'
/usr/bin/codesign --verify --strict --verbose=2 "$TUNNEL_PATH" || die 'Tunnel codesign verification failed'
/usr/bin/codesign --verify --strict --verbose=2 "$APP_PATH" || die 'App codesign verification failed'
[[ "$(bundle_id_from_plist "$APP_PATH/Info.plist")" == "$APP_ID" ]] || die 'App bundle id changed unexpectedly'
[[ "$(bundle_id_from_plist "$TUNNEL_PATH/Info.plist")" == "$TUNNEL_ID" ]] || die 'Tunnel bundle id changed unexpectedly'

# Build to a private temporary path first, then atomically copy to OUTPUT_IPA.
# This avoids any cwd/path ambiguity while zip is running inside $OUTER.
FINAL_TMP="$WORK/PikminPilot.final.ipa"
rm -f "$FINAL_TMP" "$OUTPUT_IPA"
mkdir -p "$(dirname "$OUTPUT_IPA")"
log 'Packing final signed Pikmin Pilot IPA...'
(
  cd "$OUTER"
  /usr/bin/zip -qry -y "$FINAL_TMP" .
)
[[ -s "$FINAL_TMP" ]] || die "Temporary final IPA was not created: $FINAL_TMP"
cp -f "$FINAL_TMP" "$OUTPUT_IPA"
[[ -s "$OUTPUT_IPA" ]] || die "Output IPA was not created at requested path: $OUTPUT_IPA"
log "Created: $OUTPUT_IPA ($(stat -f%z "$OUTPUT_IPA") bytes)"
log "SHA256: $(shasum -a 256 "$OUTPUT_IPA" | awk '{print $1}')"
