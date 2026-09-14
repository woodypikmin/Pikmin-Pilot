from pathlib import Path
import re
import sys

if len(sys.argv) != 2:
    raise SystemExit("usage: patch_idevice_pair.py <idevice_pair src dir>")

src = Path(sys.argv[1])
known = src / "known_apps.rs" if src.is_dir() else src
if not known.exists():
    raise SystemExit(f"known_apps.rs not found: {known}")

text = known.read_text(encoding="utf-8")

DISPLAY = "Pikmin Pilot"
BUNDLE = "com.woodypikmin.pikminpilot"
PAIRING_FILE = "rp_pairing_file.plist"


def rust_strings(s: str):
    return list(re.finditer(r'"(?:\\.|[^"\\])*"', s, re.S))


def matching_open_for_pos(s: str, pos: int, opener: str, closer: str):
    # Build delimiter pairs while ignoring strings and comments well enough for this static table.
    stack = []
    pairs = []
    i = 0
    in_str = False
    esc = False
    line_comment = False
    block_depth = 0
    while i < len(s):
        c = s[i]
        n = s[i + 1] if i + 1 < len(s) else ""
        if line_comment:
            if c == "\n":
                line_comment = False
            i += 1
            continue
        if block_depth:
            if c == "/" and n == "*":
                block_depth += 1; i += 2; continue
            if c == "*" and n == "/":
                block_depth -= 1; i += 2; continue
            i += 1; continue
        if in_str:
            if esc:
                esc = False
            elif c == "\\":
                esc = True
            elif c == '"':
                in_str = False
            i += 1; continue
        if c == "/" and n == "/":
            line_comment = True; i += 2; continue
        if c == "/" and n == "*":
            block_depth = 1; i += 2; continue
        if c == '"':
            in_str = True; i += 1; continue
        if c == opener:
            stack.append(i)
        elif c == closer and stack:
            op = stack.pop()
            pairs.append((op, i))
        i += 1
    enclosing = [(a,b) for a,b in pairs if a < pos < b]
    if not enclosing:
        return None
    # Smallest enclosing composite is the list item / struct literal / tuple we want.
    return min(enclosing, key=lambda p: p[1]-p[0])


def expand_item_start(s: str, open_idx: int) -> int:
    # If this is StructName { ... }, include the StructName in the cloned item.
    line_start = s.rfind("\n", 0, open_idx) + 1
    prefix = s[line_start:open_idx]
    # Preserve indentation, then include trailing path/identifier before the opener.
    m = re.search(r'([A-Za-z_][A-Za-z0-9_:<>]*)\s*$', prefix)
    if m:
        return line_start + m.start(1)
    return open_idx


def item_bounds_for_anchor(s: str, anchor: str):
    m = re.search(r'"' + re.escape(anchor) + r'(?:[^"\\]|\\.)*"', s)
    if not m:
        return None
    pos = m.start()
    candidates = []
    for op, cl in [("{", "}"), ("(", ")")]:
        pair = matching_open_for_pos(s, pos, op, cl)
        if pair:
            a, b = pair
            # Reject huge outer containers. App entries should be reasonably small.
            if b - a < 5000:
                candidates.append((a, b))
    if not candidates:
        return None
    a, b = min(candidates, key=lambda p: p[1]-p[0])
    start = expand_item_start(s, a)
    end = b + 1
    j = end
    while j < len(s) and s[j] in " \t":
        j += 1
    if j < len(s) and s[j] == ',':
        end = j + 1
    return start, end


def transform_item(item: str, anchor: str) -> str:
    out = item
    # Display label.
    out, n_name = re.subn(r'"' + re.escape(anchor) + r'(?:[^"\\]|\\.)*"', f'"{DISPLAY}"', out, count=1)
    if not n_name:
        raise RuntimeError("failed to replace display name in cloned known-app item")

    # Prefer field-aware replacement for the bundle identifier.
    bundle_patterns = [
        r'((?:bundle_id|bundle_identifier|bundle_identifiers|identifier|bundle)\s*:\s*)"[^"]+"',
    ]
    n_bundle = 0
    for pat in bundle_patterns:
        out, n_bundle = re.subn(pat, lambda m: m.group(1) + f'"{BUNDLE}"', out, count=1, flags=re.I)
        if n_bundle:
            break

    # Fallback: replace the first bundle-looking literal in the cloned entry.
    if not n_bundle:
        lits = rust_strings(out)
        for lm in lits:
            val = lm.group(0)[1:-1]
            if val == DISPLAY:
                continue
            if re.fullmatch(r'[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+){2,}', val):
                out = out[:lm.start()] + f'"{BUNDLE}"' + out[lm.end():]
                n_bundle = 1
                break
    if not n_bundle:
        raise RuntimeError("could not identify bundle identifier field in cloned known-app item")

    # Replace pairing-file path/name. Field-aware first, then any plist literal.
    path_field = re.compile(
        r'((?:rp_?pairing(?:_file|_path|_filename)?|remote_?pairing(?:_file|_path|_filename)?|pairing_?file|file_?name|path)\s*:\s*)"[^"]*\.plist"',
        re.I,
    )
    out, n_path = path_field.subn(lambda m: m.group(1) + f'"{PAIRING_FILE}"', out, count=1)
    if not n_path:
        m = re.search(r'"[^"\n]*\.plist"', out)
        if m:
            out = out[:m.start()] + f'"{PAIRING_FILE}"' + out[m.end():]
            n_path = 1

    # Some upstream app records use a filename constant / non-plist path. If so,
    # look for a remote-pairing field and replace its value conservatively.
    if not n_path:
        pat = re.compile(
            r'((?:rp_?pairing(?:_file|_path|_filename)?|remote_?pairing(?:_file|_path|_filename)?)\s*:\s*)(?:Some\()?\s*(?:"[^"]*"|[A-Za-z_][A-Za-z0-9_:]*)\s*\)?',
            re.I,
        )
        out, n_path = pat.subn(lambda m: m.group(1) + f'Some("{PAIRING_FILE}")', out, count=1)

    # If there is still no path marker, abort instead of generating a button that writes the wrong file.
    if not n_path and PAIRING_FILE not in out:
        raise RuntimeError("could not identify remote-pairing filename/path in cloned known-app item")

    return out


if DISPLAY in text and BUNDLE in text and PAIRING_FILE in text:
    print(f"Pikmin Pilot known-app entry already present in {known}")
else:
    anchors = ["Auto Capture", "StikDebug"]
    last_error = None
    patched = False
    for anchor in anchors:
        bounds = item_bounds_for_anchor(text, anchor)
        if not bounds:
            continue
        start, end = bounds
        item = text[start:end]
        try:
            cloned = transform_item(item, anchor)
        except Exception as exc:
            last_error = exc
            print(f"Anchor {anchor!r} found but could not be cloned: {exc}", file=sys.stderr)
            continue
        indent_start = text.rfind("\n", 0, start) + 1
        indent = re.match(r'[ \t]*', text[indent_start:start]).group(0)
        # Keep one blank-free line separation; cloned item already contains its own indentation internally.
        insertion = "\n" + indent + cloned.lstrip()
        text = text[:end] + insertion + text[end:]
        known.write_text(text, encoding="utf-8")
        print(f"Patched {known} by cloning the {anchor!r} known-app entry")
        print("--- inserted Pikmin Pilot entry ---")
        print(cloned)
        patched = True
        break
    if not patched:
        print("Could not create Pikmin Pilot entry from known_apps.rs.", file=sys.stderr)
        print("--- known_apps.rs diagnostics ---", file=sys.stderr)
        for i, line in enumerate(text.splitlines(), 1):
            if any(k in line for k in ("Auto Capture", "StikDebug", "KnownApp", "Remote", "pair", "plist")):
                print(f"{i:4}: {line}", file=sys.stderr)
        if last_error:
            print(f"Last clone error: {last_error}", file=sys.stderr)
        raise SystemExit("Pikmin Pilot known-app patch target not found")

# Best-effort window title branding; never block the build on this cosmetic detail.
all_rs = sorted(src.rglob("*.rs")) if src.is_dir() else [src]
for path in all_rs:
    t = path.read_text(encoding="utf-8")
    original = t
    t = t.replace('&format!("idevice pair v{}", env!("CARGO_PKG_VERSION")),', '"Pikmin Pilot Pairing Setup",', 1)
    t = re.sub(
        r'&?format!\(\s*"idevice(?:_| )pair v\{\}"\s*,\s*env!\("CARGO_PKG_VERSION"\)\s*\)',
        '"Pikmin Pilot Pairing Setup"',
        t,
        count=1,
    )
    if t != original:
        path.write_text(t, encoding="utf-8")
        print(f"Applied window-title branding in {path}")
        break

final = known.read_text(encoding="utf-8")
missing = [x for x in (DISPLAY, BUNDLE, PAIRING_FILE) if x not in final]
if missing:
    raise SystemExit(f"patch verification failed; missing in known_apps.rs: {missing}")
print("Verified Pikmin Pilot known-app destination:")
print(f"  display={DISPLAY}")
print(f"  bundle={BUNDLE}")
print(f"  remote_pairing_file={PAIRING_FILE}")
