from __future__ import annotations

import argparse
import asyncio
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import zipfile
from datetime import datetime, timezone
from pathlib import Path

MARKERS = ("pikminpilotrunner", "pikminpilotrunneruitests", ".xctrunner")
P12_PASSWORD = "pikminpilot"


def decode_output(data: bytes | None) -> str:
    """Decode CLI output deterministically on Windows.

    go-ios/OpenSSL emit UTF-8 even when the Windows ANSI code page is cp950.
    Never let subprocess use the locale codec implicitly.
    """
    if not data:
        return ""
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        # Preserve diagnostics instead of aborting the signing flow.
        return data.decode("utf-8", errors="replace")


class FixError(RuntimeError):
    pass


def log(step: str, text: str) -> None:
    print(f"[{step}] {text}", flush=True)


def find_openssl() -> str:
    found = shutil.which("openssl")
    if found:
        return found
    for cand in (
        Path("C:/Program Files/Git/mingw64/bin/openssl.exe"),
        Path("C:/Program Files/Git/usr/bin/openssl.exe"),
    ):
        if cand.exists():
            return str(cand)
    raise FixError(
        "OpenSSL not found. Git for Windows normally provides it at "
        r"C:\Program Files\Git\mingw64\bin\openssl.exe."
    )


def sideloadly_identity() -> tuple[Path, Path]:
    base = Path(os.environ.get("APPDATA", "")) / "Sideloadly"
    key = base / "key.pem"
    certs = sorted(base.glob("cert-*.pem"), key=lambda p: p.stat().st_mtime, reverse=True)
    if not key.exists() or not certs:
        raise FixError(
            f"Sideloadly signing identity not found in {base}. "
            "Use Sideloadly to sign/install the Runner once, then rerun this fix."
        )
    return key, certs[0]


def build_p12(openssl: str, key: Path, certs: list[Path], dest: Path) -> Path:
    errors: list[str] = []
    for cert in certs:
        proc = subprocess.run(
            [
                openssl,
                "pkcs12",
                "-export",
                "-out",
                str(dest),
                "-inkey",
                str(key),
                "-in",
                str(cert),
                "-passout",
                f"pass:{P12_PASSWORD}",
                "-name",
                "PikminPilotRunner",
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=False,
            timeout=30,
        )
        stdout = decode_output(proc.stdout)
        stderr = decode_output(proc.stderr)
        if proc.returncode == 0 and dest.exists():
            log("p12", f"matched Sideloadly cert {cert.name}")
            return dest
        errors.append(f"{cert.name}: {(stderr or stdout).strip()[-300:]}")
    raise FixError("No Sideloadly certificate matched key.pem. " + " | ".join(errors))


def parse_mobileprovision(data: bytes) -> dict:
    start = data.find(b"<?xml")
    end = data.find(b"</plist>")
    if start < 0 or end < 0:
        raise FixError("not a provisioning profile")
    plist = plistlib.loads(data[start : end + len(b"</plist>")])
    ent = plist.get("Entitlements", {}) or {}
    app_id = str(ent.get("application-identifier", ""))
    teams = plist.get("TeamIdentifier") or []
    team_id = str(teams[0]) if teams else str(ent.get("com.apple.developer.team-identifier", ""))
    bundle_id = app_id[len(team_id) + 1 :] if team_id and app_id.startswith(team_id + ".") else app_id
    exp = plist.get("ExpirationDate")
    return {
        "name": str(plist.get("Name", "")),
        "app_id": app_id,
        "bundle_id": bundle_id,
        "team_id": team_id,
        "expires": exp,
        "udids": list(plist.get("ProvisionedDevices", []) or []),
    }


def expiry_utc(info: dict) -> datetime:
    exp = info.get("expires")
    if not isinstance(exp, datetime):
        return datetime.min.replace(tzinfo=timezone.utc)
    return exp if exp.tzinfo else exp.replace(tzinfo=timezone.utc)


def is_runner_profile(info: dict) -> bool:
    hay = (info.get("app_id") or "").lower()
    return any(m in hay for m in MARKERS)


async def read_profiles_from_phone(serial: str | None) -> tuple[list[bytes], str | None]:
    try:
        from pymobiledevice3.lockdown import create_using_usbmux
        from pymobiledevice3.services.misagent import MisagentService
    except ImportError as exc:
        raise FixError("pymobiledevice3 is missing") from exc

    lockdown = await create_using_usbmux(serial=serial)
    udid = (
        getattr(lockdown, "udid", None)
        or getattr(lockdown, "identifier", None)
        or getattr(lockdown, "serial", None)
        or serial
    )
    profiles = await MisagentService(lockdown=lockdown).copy_all()
    return [bytes(p.buf) for p in profiles], str(udid) if udid else None


def select_profile(raw_profiles: list[bytes], udid: str | None) -> tuple[dict, bytes]:
    now = datetime.now(timezone.utc)
    matches: list[tuple[dict, bytes]] = []
    for raw in raw_profiles:
        try:
            info = parse_mobileprovision(raw)
        except Exception:
            continue
        if not is_runner_profile(info):
            continue
        if expiry_utc(info) <= now:
            continue
        if udid and info["udids"] and udid not in info["udids"]:
            continue
        matches.append((info, raw))
    if not matches:
        raise FixError(
            "No valid PikminPilotRunner provisioning profile was found on the phone. "
            "First install/sign the unsigned Runner IPA once with Sideloadly using the same Apple ID, "
            "leave the phone unlocked, then rerun this BAT."
        )
    matches.sort(key=lambda pair: expiry_utc(pair[0]), reverse=True)
    return matches[0]


def inspect_runner_ipa(ipa: Path) -> dict:
    if not ipa.exists() or ipa.suffix.lower() != ".ipa":
        raise FixError(f"Runner IPA not found: {ipa}")
    with zipfile.ZipFile(ipa) as z:
        names = z.namelist()
        app_infos = [n for n in names if n.startswith("Payload/") and n.count("/") == 2 and n.endswith(".app/Info.plist")]
        if not app_infos:
            # Typical zip names don't include directory entries; search by pattern instead.
            app_infos = [n for n in names if n.startswith("Payload/") and ".app/Info.plist" in n and "/PlugIns/" not in n]
        if not app_infos:
            raise FixError("IPA has no Payload/*.app/Info.plist")
        info_path = sorted(app_infos, key=len)[0]
        outer = plistlib.loads(z.read(info_path))
        app_root = info_path.rsplit("/Info.plist", 1)[0] + "/"
        xctest_infos = [n for n in names if n.startswith(app_root + "PlugIns/") and n.endswith(".xctest/Info.plist")]
        if not xctest_infos:
            raise FixError("Runner IPA has no PlugIns/*.xctest test bundle")
        xinfo_path = xctest_infos[0]
        xinfo = plistlib.loads(z.read(xinfo_path))
        xroot = xinfo_path.rsplit("/Info.plist", 1)[0] + "/"
        xexec = xinfo.get("CFBundleExecutable")
        if not xexec or (xroot + xexec) not in names:
            raise FixError("Nested .xctest exists but its CFBundleExecutable is missing")
        return {
            "outer_bundle_id": str(outer.get("CFBundleIdentifier", "")),
            "test_bundle_id": str(xinfo.get("CFBundleIdentifier", "")),
            "test_executable": str(xexec),
        }


def find_ios() -> str:
    exe = shutil.which("ios") or shutil.which("ios.exe")
    if not exe:
        raise FixError("go-ios command 'ios' not found. Run: npm install -g go-ios")
    return exe


def run_sign_install(ios: str, ipa: Path, p12: Path, profile: Path, bundle_id: str, signed_output: Path) -> str:
    args = [
        ios,
        "sign",
        "app",
        f"--path={ipa}",
        f"--p12file={p12}",
        f"--profile={profile}",
        f"--p12password={P12_PASSWORD}",
        f"--bundleid={bundle_id}",
        f"--output={signed_output}",
        "--install",
    ]
    proc = subprocess.run(
        args,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=False,
        timeout=300,
    )
    stdout = decode_output(proc.stdout)
    stderr = decode_output(proc.stderr)
    out = (stdout + "\n" + stderr).strip()
    if proc.returncode != 0:
        raise FixError("go-ios recursive sign/install failed:\n" + out[-3000:])
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description="Recursively sign Pikmin Pilot's nested .xctest using Sideloadly's own identity/profile.")
    ap.add_argument("runner_ipa", type=Path)
    ap.add_argument("--udid", default=None)
    args = ap.parse_args()

    try:
        ipa = args.runner_ipa.resolve()
        meta = inspect_runner_ipa(ipa)
        log("ipa", f"outer={meta['outer_bundle_id']}")
        log("ipa", f"nested={meta['test_bundle_id']} exec={meta['test_executable']}")

        openssl = find_openssl()
        ios = find_ios()
        appdata = Path(os.environ.get("APPDATA", "")) / "Sideloadly"
        key = appdata / "key.pem"
        certs = sorted(appdata.glob("cert-*.pem"), key=lambda p: p.stat().st_mtime, reverse=True)
        if not key.exists() or not certs:
            raise FixError(
                f"No Sideloadly cert/key found in {appdata}. Sign/install the Runner once in Sideloadly first."
            )

        log("phone", "reading installed provisioning profiles over USB; nothing stays resident")
        raws, detected_udid = asyncio.run(read_profiles_from_phone(args.udid))
        if detected_udid:
            log("phone", f"device={detected_udid}")
        info, profile_raw = select_profile(raws, args.udid or detected_udid)
        exp = expiry_utc(info)
        log("profile", f"{info['name']} • app-id={info['app_id']} • expires={exp.isoformat()}")
        if not info.get("bundle_id") or info["bundle_id"] == "*":
            raise FixError("Runner provisioning profile is wildcard/has no concrete bundle id; cannot safely overwrite installed Runner")

        with tempfile.TemporaryDirectory(prefix="PikminPilotRunnerSign-") as td:
            td = Path(td)
            profile = td / "Runner.mobileprovision"
            p12 = td / "Runner.p12"
            profile.write_bytes(profile_raw)
            build_p12(openssl, key, certs, p12)

            log("sign", "recursively signing outer Runner + PlugIns/*.xctest with the SAME Team ID")
            signed_output = ipa.with_name(ipa.stem + "-SIGNED.ipa")
            out = run_sign_install(ios, ipa, p12, profile, info["bundle_id"], signed_output)
            tail = "\n".join(out.splitlines()[-12:])
            if tail:
                print(tail)

        if not signed_output.exists():
            raise FixError(f"go-ios reported success but signed IPA was not created: {signed_output}")
        log("done", f"installed recursively-signed Runner as {info['bundle_id']}")
        log("output", f"SIGNED IPA SAVED: {signed_output}")
        log("pilot", "Copy that *-SIGNED.ipa to iPhone Files to test Pikmin Pilot Stage 9.1 phone-local self-install/update")
        log("next", "Close this window. On iPhone: LocalDevVPN -> Pikmin Pilot -> CONNECT PHONE-LOCAL RSD -> RUN XCTEST -> PIKMIN CENTER TAP")
        return 0
    except subprocess.TimeoutExpired as exc:
        print(f"ERROR: command timed out: {exc}", file=sys.stderr)
        return 20
    except (FixError, OSError, zipfile.BadZipFile) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 21
    except Exception as exc:
        import traceback
        print(f"ERROR: unexpected {type(exc).__name__}: {exc}", file=sys.stderr)
        traceback.print_exc()
        return 22


if __name__ == "__main__":
    raise SystemExit(main())
