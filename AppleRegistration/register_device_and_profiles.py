#!/usr/bin/env python3
import argparse, base64, datetime as dt, json, os, pathlib, sys, time
import jwt
import requests

API = "https://api.appstoreconnect.apple.com"
BUNDLES = {
    "APP": "com.woodypikmin.pikminpilot",
    "TUNNEL": "com.woodypikmin.pikminpilot.tunnel",
    "XCTRUNNER": "com.woodypikmin.pikminpilot.runner.xctrunner",
}


def need(name):
    value = os.environ.get(name, "").strip()
    if not value:
        raise SystemExit(f"missing env {name}")
    return value


def make_token():
    issuer = need("ASC_ISSUER_ID")
    key_id = need("ASC_KEY_ID")
    key_raw = base64.b64decode(need("ASC_PRIVATE_KEY_B64"))
    now = int(time.time())
    return jwt.encode(
        {"iss": issuer, "iat": now, "exp": now + 15 * 60, "aud": "appstoreconnect-v1"},
        key_raw,
        algorithm="ES256",
        headers={"kid": key_id, "typ": "JWT"},
    )


def api(method, path, *, params=None, body=None):
    r = requests.request(
        method,
        API + path,
        params=params,
        json=body,
        headers={"Authorization": f"Bearer {make_token()}", "Content-Type": "application/json"},
        timeout=90,
    )
    if r.status_code >= 400:
        raise RuntimeError(f"Apple API {method} {path} -> {r.status_code}: {r.text}")
    return r.json() if r.text else {}


def register_device(udid, name):
    existing = api("GET", "/v1/devices", params={"filter[udid]": udid, "limit": 10}).get("data", [])
    if existing:
        d = existing[0]
        print(f"device already registered: {d['id']} {d.get('attributes', {}).get('name')}")
        return d["id"]
    body = {"data": {"type": "devices", "attributes": {"name": name, "platform": "IOS", "udid": udid}}}
    d = api("POST", "/v1/devices", body=body)["data"]
    print(f"registered device: {d['id']}")
    return d["id"]


def pick_certificate():
    explicit = os.environ.get("ASC_CERTIFICATE_ID", "").strip()
    if explicit:
        return explicit
    data = api("GET", "/v1/certificates", params={"limit": 200}).get("data", [])
    now = dt.datetime.now(dt.timezone.utc)
    candidates = []
    wanted_serial = os.environ.get("ASC_CERTIFICATE_SERIAL", "").replace(":", "").upper().lstrip("0")
    for c in data:
        a = c.get("attributes", {})
        if a.get("certificateType") not in ("DEVELOPMENT", "IOS_DEVELOPMENT"):
            continue
        if wanted_serial:
            api_serial = str(a.get("serialNumber", "")).replace(":", "").upper().lstrip("0")
            if api_serial != wanted_serial:
                continue
        exp = a.get("expirationDate")
        try:
            expiry = dt.datetime.fromisoformat(exp.replace("Z", "+00:00")) if exp else now
        except Exception:
            expiry = now
        if a.get("activated", True) and expiry > now:
            candidates.append((expiry, c))
    if not candidates:
        suffix = f" matching serial {wanted_serial}" if wanted_serial else ""
        raise RuntimeError(f"No active Apple Development certificate found{suffix}; set ASC_CERTIFICATE_ID explicitly if needed")
    candidates.sort(key=lambda x: x[0], reverse=True)
    chosen = candidates[0][1]
    print("certificate:", chosen["id"], chosen.get("attributes", {}).get("displayName"))
    return chosen["id"]


def bundle_resource_id(identifier):
    data = api("GET", "/v1/bundleIds", params={"filter[identifier]": identifier, "limit": 10}).get("data", [])
    if len(data) != 1:
        raise RuntimeError(f"Expected exactly one bundleId resource for {identifier}, got {len(data)}")
    return data[0]["id"]


def enabled_ios_device_ids():
    data = api("GET", "/v1/devices", params={"filter[platform]": "IOS", "filter[status]": "ENABLED", "limit": 200}).get("data", [])
    if not data:
        raise RuntimeError("No enabled iOS/iPadOS devices found")
    return [d["id"] for d in data]


def create_profile(label, identifier, cert_id, device_ids):
    bid = bundle_resource_id(identifier)
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%d-%H%M%S")
    body = {
        "data": {
            "type": "profiles",
            "attributes": {"name": f"PikminPilot Auto {label} {stamp}", "profileType": "IOS_APP_DEVELOPMENT"},
            "relationships": {
                "bundleId": {"data": {"type": "bundleIds", "id": bid}},
                "certificates": {"data": [{"type": "certificates", "id": cert_id}]},
                "devices": {"data": [{"type": "devices", "id": d} for d in device_ids]},
            },
        }
    }
    result = api("POST", "/v1/profiles", body=body)["data"]
    content = result.get("attributes", {}).get("profileContent")
    if not content:
        raise RuntimeError(f"Apple profile response for {label} had no profileContent")
    print(f"created {label} profile id={result['id']}")
    return content


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--udid", required=True)
    p.add_argument("--name", required=True)
    p.add_argument("--out", default="generated-profiles")
    args = p.parse_args()

    register_device(args.udid, args.name)
    cert = pick_certificate()
    devices = enabled_ios_device_ids()
    out = pathlib.Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    manifest = {}
    for label, identifier in BUNDLES.items():
        profile_b64 = create_profile(label, identifier, cert, devices)
        filename = {"APP": "App.mobileprovision", "TUNNEL": "Tunnel.mobileprovision", "XCTRUNNER": "XCTRunner.mobileprovision"}[label]
        (out / filename).write_bytes(base64.b64decode(profile_b64))
        manifest[label] = {"bundle": identifier, "file": filename, "profileContent": profile_b64}
    (out / "profiles.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    print("profiles generated for", len(devices), "enabled IOS devices")


if __name__ == "__main__":
    main()
