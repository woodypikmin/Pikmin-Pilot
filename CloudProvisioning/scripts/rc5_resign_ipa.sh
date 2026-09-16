#!/bin/bash
set -Eeuo pipefail

RC5_SIGN_SCRIPT_REVISION='2026-09-16.4-nounset-hardened'

log() { printf '[RC5-SIGN] %s\n' "$*"; }
die() { printf '[RC5-SIGN] ERROR: %s\n' "$*" >&2; exit 1; }

on_err() {
  local rc=$?
  local line="${BASH_LINENO[0]:-unknown}"
  local cmd="${BASH_COMMAND:-unknown}"
  trap - ERR
  printf '[RC5-SIGN] ERROR: command failed (exit=%s line=%s): %s\n' "$rc" "$line" "$cmd" >&2
  exit "$rc"
}
trap on_err ERR

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

log "Script revision: $RC5_SIGN_SCRIPT_REVISION"

for f in "$INPUT_IPA" "$PROFILE_APP" "$PROFILE_TUNNEL" "$PROFILE_RUNNER"; do
  [[ -s "$f" ]] || die "missing/empty input: $f"
done

for tool in /usr/bin/codesign /usr/bin/security /usr/bin/ditto /usr/bin/zip /usr/bin/shasum /usr/libexec/PlistBuddy; do
  [[ -x "$tool" ]] || die "required macOS tool missing: $tool"
done

mkdir -p "$(dirname "$OUTPUT_IPA")"
[[ -w "$(dirname "$OUTPUT_IPA")" ]] || die "output directory is not writable: $(dirname "$OUTPUT_IPA")"

log "Input IPA: $(basename "$INPUT_IPA") ($(stat -f%z "$INPUT_IPA") bytes)"
log "Requested output: $OUTPUT_IPA"
log "Signing identity: $SIGNING_IDENTITY"

if ! /usr/bin/security find-identity -v -p codesigning | grep -Fq "$SIGNING_IDENTITY"; then
  /usr/bin/security find-identity -v -p codesigning || true
  die "signing identity is not visible to codesign: $SIGNING_IDENTITY"
fi
log 'Signing identity is available.'

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
OUTER="$WORK/outer"
RUNNER_WORK="$WORK/runner"
mkdir -p "$OUTER" "$RUNNER_WORK"

bundle_id_from_plist() {
  local plist="$1"
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist" 2>/dev/null || true
}

find_bundle_exact_under() {
  local root="$1"
  local wanted="$2"
  local plist=''
  local bid=''
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
  local target="$1"
  local out="$2"
  /usr/bin/codesign -d --entitlements :- "$target" > "$out" 2>/dev/null || true
  grep -q '<plist' "$out" || die "Unable to extract entitlements from $target"
}

sign_plain() {
  local target="$1"
  /usr/bin/codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none "$target"
}

sign_with_entitlements() {
  local target="$1"
  local ent="$2"
  /usr/bin/codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none --entitlements "$ent" "$target"
}

resign_preserving() {
  local p="$1"
  local ent="$WORK/preserve.$RANDOM.$RANDOM.plist"
  /usr/bin/codesign -d --entitlements :- "$p" > "$ent" 2>/dev/null || true
  if grep -q '<plist' "$ent"; then
    sign_with_entitlements "$p" "$ent"
  else
    sign_plain "$p"
  fi
  rm -f "$ent"
}

profile_decode() {
  local profile="$1"
  local out="$2"
  /usr/bin/security cms -D -i "$profile" > "$out" || die "Cannot decode provisioning profile: $profile"
}

profile_check() {
  # IMPORTANT: declarations are deliberately split. With `set -u`, Bash expands
  # RHS expressions before assignments in a single `local` command.
  local label="$1"
  local profile="$2"
  local wanted="$3"
  local decoded="$WORK/profile-${label}.plist"
  local appid=''
  local team=''
  local uuid=''
  local expiry=''
  local expected=''

  profile_decode "$profile" "$decoded"
  appid="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "$decoded" 2>/dev/null || true)"
  team="$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$decoded" 2>/dev/null || true)"
  uuid="$(/usr/libexec/PlistBuddy -c 'Print :UUID' "$decoded" 2>/dev/null || true)"
  expiry="$(/usr/libexec/PlistBuddy -c 'Print :ExpirationDate' "$decoded" 2>/dev/null || true)"

  [[ -n "$appid" ]] || die "$label profile has no application-identifier entitlement"
  [[ -n "$team" ]] || die "$label profile has no TeamIdentifier"
  expected="${team}.${wanted}"
  [[ "$appid" == "$expected" ]] || die "$label profile application-identifier '$appid' != expected '$expected'"
  log "$label profile OK: appid=$appid uuid=${uuid:-unknown} expires=${expiry:-unknown}"
}

entitlements_check_identity() {
  local label="$1"
  local entitlements="$2"
  local profile="$3"
  local wanted="$4"
  local decoded="$WORK/profile-ent-${label}.plist"
  local old_appid=''
  local new_appid=''

  old_appid="$(/usr/libexec/PlistBuddy -c 'Print :application-identifier' "$entitlements" 2>/dev/null || true)"
  profile_decode "$profile" "$decoded"
  new_appid="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "$decoded" 2>/dev/null || true)"

  [[ -n "$new_appid" ]] || die "$label new profile has no application-identifier"
  case "$new_appid" in
    *".$wanted") ;;
    *) die "$label new profile application-identifier '$new_appid' does not target '$wanted'" ;;
  esac
  if [[ -n "$old_appid" && "$old_appid" != "$new_appid" ]]; then
    die "$label preserved entitlements use '$old_appid' but new profile requires '$new_appid'; refusing to produce a mismatched signature"
  fi
  log "$label preserved entitlement identity matches new profile: $new_appid"
}

log 'Validating generated provisioning profiles...'
profile_check app "$PROFILE_APP" "$APP_ID"
profile_check tunnel "$PROFILE_TUNNEL" "$TUNNEL_ID"
profile_check runner "$PROFILE_RUNNER" "$RUNNER_ID"

log 'Extracting outer Pikmin Pilot IPA...'
/usr/bin/ditto -x -k "$INPUT_IPA" "$OUTER"
ROOT_APP="$(find "$OUTER/Payload" -maxdepth 1 -type d -name '*.app' -print -quit 2>/dev/null || true)"
[[ -n "$ROOT_APP" ]] || die 'No Payload/*.app found in baseline IPA'
log "Root payload app: $ROOT_APP"

APP_PATH="$(find_bundle_exact_under "$ROOT_APP" "$APP_ID" || true)"
TUNNEL_PATH="$(find_bundle_exact_under "$ROOT_APP" "$TUNNEL_ID" || true)"
[[ -n "$APP_PATH" ]] || die "Could not locate outer App bundle id $APP_ID"
[[ -n "$TUNNEL_PATH" ]] || die "Could not locate Tunnel bundle id $TUNNEL_ID"
log "Host App: $APP_PATH"
log "Tunnel:   $TUNNEL_PATH"

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
entitlements_check_identity app "$APP_ENT" "$PROFILE_APP" "$APP_ID"
entitlements_check_identity tunnel "$TUNNEL_ENT" "$PROFILE_TUNNEL" "$TUNNEL_ID"

log 'Extracting embedded 1153-xfix Runner IPA...'
/usr/bin/ditto -x -k "$EMBEDDED_RUNNER_IPA" "$RUNNER_WORK"
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
entitlements_check_identity runner "$RUNNER_ENT" "$PROFILE_RUNNER" "$RUNNER_ID"

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
/usr/bin/codesign --verify --strict --verbose=2 "$RUNNER_PATH"
[[ "$(bundle_id_from_plist "$RUNNER_PATH/Info.plist")" == "$RUNNER_ID" ]] || die 'Runner bundle id changed unexpectedly'

rm -f "$EMBEDDED_RUNNER_IPA"
log 'Packing refreshed embedded Runner IPA back into host app...'
(
  cd "$RUNNER_WORK"
  /usr/bin/zip -qry -y "$EMBEDDED_RUNNER_IPA" .
)
[[ -s "$EMBEDDED_RUNNER_IPA" ]] || die 'Refreshed embedded Runner IPA was not created'
log "Refreshed embedded Runner IPA: $(stat -f%z "$EMBEDDED_RUNNER_IPA") bytes"

RUNNER_META="$(find "$ROOT_APP" -type f -name "$EMBEDDED_RUNNER_METADATA_NAME" -print -quit 2>/dev/null || true)"
if [[ -n "$RUNNER_META" ]]; then
  RUNNER_PROFILE_DECODED="$WORK/profile-runner-meta.plist"
  profile_decode "$PROFILE_RUNNER" "$RUNNER_PROFILE_DECODED"
  TEAM_ID="$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$RUNNER_PROFILE_DECODED" 2>/dev/null || true)"
  EXPIRATION="$(/usr/libexec/PlistBuddy -c 'Print :ExpirationDate' "$RUNNER_PROFILE_DECODED" 2>/dev/null || true)"
  log "Embedded Runner metadata resource found: $RUNNER_META"
  if [[ -n "$TEAM_ID" ]]; then
    /usr/libexec/PlistBuddy -c "Set :TeamIdentifier $TEAM_ID" "$RUNNER_META" >/dev/null 2>&1 || true
  fi
  log "Runner profile team=${TEAM_ID:-unknown} expiration=${EXPIRATION:-unknown}"
else
  log 'Embedded Runner metadata plist not found; skipping metadata refresh.'
fi

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
/usr/bin/codesign --verify --strict --verbose=2 "$TUNNEL_PATH"
/usr/bin/codesign --verify --strict --verbose=2 "$APP_PATH"
[[ "$(bundle_id_from_plist "$APP_PATH/Info.plist")" == "$APP_ID" ]] || die 'App bundle id changed unexpectedly'
[[ "$(bundle_id_from_plist "$TUNNEL_PATH/Info.plist")" == "$TUNNEL_ID" ]] || die 'Tunnel bundle id changed unexpectedly'

FINAL_TMP="$WORK/PikminPilot.final.ipa"
rm -f "$FINAL_TMP" "$OUTPUT_IPA"
log 'Packing final signed Pikmin Pilot IPA...'
(
  cd "$OUTER"
  /usr/bin/zip -qry -y "$FINAL_TMP" .
)
[[ -s "$FINAL_TMP" ]] || die "Temporary final IPA was not created: $FINAL_TMP"
cp -f "$FINAL_TMP" "$OUTPUT_IPA"
[[ -s "$OUTPUT_IPA" ]] || die "Output IPA was not created at requested path: $OUTPUT_IPA"
log "Created: $OUTPUT_IPA ($(stat -f%z "$OUTPUT_IPA") bytes)"
log "SHA256: $(/usr/bin/shasum -a 256 "$OUTPUT_IPA" | awk '{print $1}')"
log 'SUCCESS: re-sign completed and output handoff is ready.'
