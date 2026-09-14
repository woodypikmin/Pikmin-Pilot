from pathlib import Path
import re
import sys

if len(sys.argv) != 2:
    raise SystemExit("usage: patch_idevice_pair.py <idevice_pair src dir | .rs file>")

target = Path(sys.argv[1])
if target.is_file():
    files = [target]
elif target.is_dir():
    files = sorted(target.rglob("*.rs"))
else:
    raise SystemExit(f"source path not found: {target}")

if not files:
    raise SystemExit(f"no Rust source files found under: {target}")

APP_LINE = 'supported_apps.insert("Pikmin Pilot".to_string(), RP_PAIRING_FILE_NAME.to_string());'
GENERIC_APP_LINE = '{var}.insert("Pikmin Pilot".to_string(), RP_PAIRING_FILE_NAME.to_string());'

# Already patched?
for path in files:
    text = path.read_text(encoding="utf-8")
    if '"Pikmin Pilot"' in text and "RP_PAIRING_FILE_NAME" in text:
        print(f"Pikmin Pilot destination already present in {path}")
        break
else:
    patched = False

    # Strategy 1: current/master-style helper function.
    for path in files:
        text = path.read_text(encoding="utf-8")
        func = text.find("fn supported_apps_for_mode")
        if func < 0:
            continue
        remote = text.find("PairingMode::RemotePairing => {", func)
        if remote < 0:
            continue
        insert_at = remote + len("PairingMode::RemotePairing => {")
        entry = "\n        " + APP_LINE
        text = text[:insert_at] + entry + text[insert_at:]
        path.write_text(text, encoding="utf-8")
        print(f"Patched RemotePairing app map via supported_apps_for_mode in {path}")
        patched = True
        break

    # Strategy 2: locate the Remote Pairing map by a known RPPairing destination.
    # This tolerates upstream moving/renaming supported_apps_for_mode().
    if not patched:
        known_patterns = [
            re.compile(
                r'(?P<var>[A-Za-z_][A-Za-z0-9_]*)\.insert\(\s*'
                r'"StikDebug \(Sideloaded\)"\.to_string\(\),\s*'
                r'RP_PAIRING_FILE_NAME\.to_string\(\),?\s*\);',
                re.S,
            ),
            re.compile(
                r'(?P<var>[A-Za-z_][A-Za-z0-9_]*)\.insert\(\s*'
                r'"Auto Capture"\.to_string\(\),\s*'
                r'"rpPairingFile\.plist"\.to_string\(\),?\s*\);',
                re.S,
            ),
        ]
        for path in files:
            text = path.read_text(encoding="utf-8")
            for pattern in known_patterns:
                m = pattern.search(text)
                if not m:
                    continue
                var = m.group("var")
                # Prefer insertion immediately after an existing RPPairing app entry.
                insert_at = m.end()
                indent_start = text.rfind("\n", 0, m.start()) + 1
                indent = re.match(r"[ \t]*", text[indent_start:m.start()]).group(0)
                entry = "\n" + indent + GENERIC_APP_LINE.format(var=var)
                text = text[:insert_at] + entry + text[insert_at:]
                path.write_text(text, encoding="utf-8")
                print(f"Patched RemotePairing app map via known app anchor in {path} (map={var})")
                patched = True
                break
            if patched:
                break

    # Strategy 3: find a map insertion that stores RP_PAIRING_FILE_NAME inside a
    # RemotePairing source region. Useful for minor upstream refactors.
    if not patched:
        rp_insert = re.compile(
            r'(?P<var>[A-Za-z_][A-Za-z0-9_]*)\.insert\([^;]{0,600}?RP_PAIRING_FILE_NAME\.to_string\(\)[^;]{0,100}?\);',
            re.S,
        )
        for path in files:
            text = path.read_text(encoding="utf-8")
            for m in rp_insert.finditer(text):
                before = text[max(0, m.start() - 5000):m.start()]
                # Require evidence this is the RemotePairing app list, not unrelated code.
                if "RemotePairing" not in before or "PairingMode" not in before:
                    continue
                var = m.group("var")
                indent_start = text.rfind("\n", 0, m.start()) + 1
                indent = re.match(r"[ \t]*", text[indent_start:m.start()]).group(0)
                entry = "\n" + indent + GENERIC_APP_LINE.format(var=var)
                text = text[:m.end()] + entry + text[m.end():]
                path.write_text(text, encoding="utf-8")
                print(f"Patched RemotePairing app map via RP_PAIRING_FILE_NAME anchor in {path} (map={var})")
                patched = True
                break
            if patched:
                break

    if not patched:
        print("Could not locate Remote Pairing supported-app map. Diagnostics:", file=sys.stderr)
        for path in files:
            text = path.read_text(encoding="utf-8", errors="replace")
            hits = []
            for needle in ("PairingMode", "RemotePairing", "RP_PAIRING_FILE_NAME", "Auto Capture", "StikDebug"):
                if needle in text:
                    hits.append(needle)
            if hits:
                print(f"  {path}: {', '.join(hits)}", file=sys.stderr)
        raise SystemExit("Pikmin Pilot RemotePairing destination patch target not found")

# Best-effort window title branding; never fail the build if upstream changes this UI detail.
for path in files:
    text = path.read_text(encoding="utf-8")
    original = text
    old_title = '&format!("idevice pair v{}", env!("CARGO_PKG_VERSION")),'
    if old_title in text:
        text = text.replace(old_title, '"Pikmin Pilot Pairing Setup",', 1)
    # Alternate literal forms used by some upstream revisions.
    text = re.sub(
        r'&?format!\(\s*"idevice(?:_| )pair v\{\}"\s*,\s*env!\("CARGO_PKG_VERSION"\)\s*\)',
        '"Pikmin Pilot Pairing Setup"',
        text,
        count=1,
    )
    if text != original:
        path.write_text(text, encoding="utf-8")
        print(f"Applied window-title branding in {path}")
        break

# Verify destination was really added somewhere in source.
verified = False
for path in files:
    text = path.read_text(encoding="utf-8")
    if '"Pikmin Pilot".to_string()' in text and "RP_PAIRING_FILE_NAME.to_string()" in text:
        verified = True
        print(f"Verified Pikmin Pilot RPPairing destination in {path}")
        break

if not verified:
    raise SystemExit("patch completed but Pikmin Pilot RPPairing destination was not verified")

print("Patched idevice_pair for Pikmin Pilot")
