from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit("usage: patch_idevice_pair.py <src/main.rs>")

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

func = text.find("fn supported_apps_for_mode")
if func < 0:
    raise SystemExit("supported_apps_for_mode() not found")

remote = text.find("PairingMode::RemotePairing => {", func)
if remote < 0:
    raise SystemExit("RemotePairing supported-app branch not found")

insert_at = remote + len("PairingMode::RemotePairing => {")
entry = '\n        supported_apps.insert("Pikmin Pilot".to_string(), RP_PAIRING_FILE_NAME.to_string());'
if '"Pikmin Pilot".to_string()' not in text[func:]:
    text = text[:insert_at] + entry + text[insert_at:]

old_title = '&format!("idevice pair v{}", env!("CARGO_PKG_VERSION")),'
if old_title in text:
    text = text.replace(old_title, '"Pikmin Pilot Pairing Setup",', 1)

path.write_text(text, encoding="utf-8")
patched = path.read_text(encoding="utf-8")

if 'supported_apps.insert("Pikmin Pilot".to_string(), RP_PAIRING_FILE_NAME.to_string());' not in patched:
    raise SystemExit("Pikmin Pilot RemotePairing app entry was not added")
if "Pikmin Pilot Pairing Setup" not in patched:
    raise SystemExit("Window title patch was not applied")

print("Patched idevice_pair for Pikmin Pilot")
