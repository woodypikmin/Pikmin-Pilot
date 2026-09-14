#!/usr/bin/env python3
from __future__ import annotations

import argparse
import html
import json
import plistlib
import shutil
import sys
import urllib.parse
import zipfile
from pathlib import Path


def read_app_info(ipa: Path) -> dict:
    with zipfile.ZipFile(ipa, "r") as zf:
        infos = [n for n in zf.namelist() if n.startswith("Payload/") and n.count("/") == 2 and n.endswith(".app/Info.plist")]
        if not infos:
            # Typical path is Payload/Foo.app/Info.plist (3 slash-separated components, 2 slashes)
            infos = [n for n in zf.namelist() if n.startswith("Payload/") and n.endswith(".app/Info.plist")]
        if not infos:
            raise RuntimeError("IPA does not contain Payload/*.app/Info.plist")
        # Prefer the shallowest app Info.plist (host app, not nested bundles).
        info_name = sorted(infos, key=lambda s: (s.count("/"), len(s)))[0]
        return plistlib.loads(zf.read(info_name))


def normalize_base_url(url: str) -> str:
    url = url.strip()
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme.lower() != "https" or not parsed.netloc:
        raise ValueError("base URL must be a public HTTPS URL, e.g. https://example.com/pikminpilot/")
    if not url.endswith("/"):
        url += "/"
    return url


def main() -> int:
    ap = argparse.ArgumentParser(description="Create an iOS OTA install site from a signed Pikmin Pilot IPA")
    ap.add_argument("--ipa", required=True, type=Path)
    ap.add_argument("--base-url", required=True, help="Public HTTPS URL where the generated folder will be hosted")
    ap.add_argument("--output", default="ota-site", type=Path)
    ap.add_argument("--title", default=None)
    args = ap.parse_args()

    ipa = args.ipa.resolve()
    if not ipa.is_file():
        raise SystemExit(f"IPA not found: {ipa}")

    base = normalize_base_url(args.base_url)
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)

    info = read_app_info(ipa)
    bundle_id = str(info.get("CFBundleIdentifier") or "")
    version = str(info.get("CFBundleShortVersionString") or info.get("CFBundleVersion") or "1")
    build = str(info.get("CFBundleVersion") or version)
    title = args.title or str(info.get("CFBundleDisplayName") or info.get("CFBundleName") or "Pikmin Pilot")

    if not bundle_id:
        raise RuntimeError("CFBundleIdentifier missing from IPA Info.plist")

    ipa_name = "PikminPilot.ipa"
    manifest_name = "manifest.plist"
    ipa_url = urllib.parse.urljoin(base, ipa_name)
    manifest_url = urllib.parse.urljoin(base, manifest_name)

    shutil.copy2(ipa, out / ipa_name)

    manifest = {
        "items": [
            {
                "assets": [
                    {"kind": "software-package", "url": ipa_url},
                ],
                "metadata": {
                    "bundle-identifier": bundle_id,
                    "bundle-version": build,
                    "kind": "software",
                    "title": title,
                },
            }
        ]
    }
    with open(out / manifest_name, "wb") as f:
        plistlib.dump(manifest, f, fmt=plistlib.FMT_XML, sort_keys=False)

    install_url = "itms-services://?action=download-manifest&url=" + urllib.parse.quote(manifest_url, safe="")
    install_attr = html.escape(install_url, quote=True)

    page = f"""<!doctype html>
<html lang=\"zh-Hant\">
<head>
<meta charset=\"utf-8\">
<meta name=\"viewport\" content=\"width=device-width,initial-scale=1,viewport-fit=cover\">
<title>{html.escape(title)}</title>
<style>
body{{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;margin:0;background:#f2f2f7;color:#111}}
main{{max-width:560px;margin:0 auto;padding:48px 22px}}
.card{{background:#fff;border-radius:22px;padding:28px;box-shadow:0 8px 32px rgba(0,0,0,.08)}}
h1{{font-size:30px;margin:0 0 10px}} p{{line-height:1.55;color:#555}}
a.install{{display:block;text-align:center;margin-top:26px;padding:16px 20px;background:#007aff;color:white;text-decoration:none;border-radius:14px;font-weight:700;font-size:19px}}
.meta{{font-size:13px;color:#777;margin-top:22px;word-break:break-all}}
</style>
</head>
<body><main><div class=\"card\">
<h1>{html.escape(title)}</h1>
<p>版本 {html.escape(version)}（build {html.escape(build)}）</p>
<p>請用已註冊在此 provisioning profile 的 iPhone / iPad Safari 開啟本頁。安裝後如系統要求，請啟用 Developer Mode。</p>
<a class=\"install\" href=\"{install_attr}\">安裝 Pikmin Pilot</a>
<div class=\"meta\">Bundle ID: {html.escape(bundle_id)}</div>
</div></main></body></html>
"""
    (out / "index.html").write_text(page, encoding="utf-8")

    metadata = {
        "title": title,
        "bundle_id": bundle_id,
        "version": version,
        "build": build,
        "base_url": base,
        "ipa_url": ipa_url,
        "manifest_url": manifest_url,
        "install_url": install_url,
    }
    (out / "ota-metadata.json").write_text(json.dumps(metadata, ensure_ascii=False, indent=2), encoding="utf-8")

    print(f"OTA package created: {out}")
    print(f"Install page: {urllib.parse.urljoin(base, 'index.html')}")
    print(f"Bundle: {bundle_id}  Version: {version} ({build})")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as e:
        print(f"ERROR: {e}", file=sys.stderr)
        raise
