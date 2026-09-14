#!/usr/bin/env python3
import argparse
import plistlib
import subprocess
from pathlib import Path


def decode_profile(path: Path) -> dict:
    proc = subprocess.run(
        ["security", "cms", "-D", "-i", str(path)],
        check=True,
        stdout=subprocess.PIPE,
    )
    return plistlib.loads(proc.stdout)


def main() -> int:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("extract-entitlements")
    p.add_argument("profile", type=Path)
    p.add_argument("output", type=Path)
    p.add_argument("--expect-bundle-id", required=True)
    p.add_argument("--require-packet-tunnel", action="store_true")

    p = sub.add_parser("metadata")
    p.add_argument("profile", type=Path)
    p.add_argument("output", type=Path)

    p = sub.add_parser("summary")
    p.add_argument("profile", type=Path)
    p.add_argument("label")
    p.add_argument("--expect-bundle-id", required=True)
    p.add_argument("--require-packet-tunnel", action="store_true")

    args = ap.parse_args()
    src = decode_profile(args.profile)
    ent = src.get("Entitlements", {}) or {}
    app_id = str(ent.get("application-identifier", ""))
    teams = src.get("TeamIdentifier") or []
    team = str(teams[0]) if teams else str(ent.get("com.apple.developer.team-identifier", ""))
    bundle = app_id[len(team)+1:] if team and app_id.startswith(team + ".") else app_id

    if getattr(args, "expect_bundle_id", None) and bundle != args.expect_bundle_id:
        raise SystemExit(
            f"Profile bundle id mismatch: expected {args.expect_bundle_id}, got {bundle} (profile={src.get('Name','')})"
        )

    if getattr(args, "require_packet_tunnel", False):
        values = ent.get("com.apple.developer.networking.networkextension", []) or []
        if "packet-tunnel-provider" not in values:
            raise SystemExit(
                f"Profile {src.get('Name','')} does not contain packet-tunnel-provider entitlement: {values}"
            )

    if args.cmd == "extract-entitlements":
        args.output.write_bytes(plistlib.dumps(ent, fmt=plistlib.FMT_XML))
        return 0

    if args.cmd == "metadata":
        out = {
            "ExpirationDate": src.get("ExpirationDate"),
            "CreationDate": src.get("CreationDate"),
            "TeamIdentifier": team,
            "ApplicationIdentifier": app_id,
            "ProfileName": src.get("Name", ""),
        }
        args.output.write_bytes(plistlib.dumps(out, fmt=plistlib.FMT_XML))
        return 0

    if args.cmd == "summary":
        exp = src.get("ExpirationDate")
        print(f"{args.label}: profile={src.get('Name','')} team={team} bundle={bundle} expires={exp}")
        return 0

    return 2

if __name__ == "__main__":
    raise SystemExit(main())
