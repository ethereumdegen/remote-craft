#!/usr/bin/env python3
"""Create the developer-portal bundle id and the App Store Connect app record.

A first TestFlight upload needs both to exist, and both are otherwise a click
path through two websites. Everything here is idempotent: run it twice and the
second run reports what already exists and changes nothing.

    pip3 install pyjwt cryptography
    ./scripts/asc-bootstrap.py            # report only
    ./scripts/asc-bootstrap.py --create   # actually create what is missing

Credentials come from deploy.env, the same three values deploy-testflight.sh
uses. An app record is close to permanent — it reserves the name and cannot be
deleted once a build has been submitted — which is why creating one takes an
explicit flag.
"""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import sys
import time
import urllib.error
import urllib.request

try:
    import jwt
except ImportError:  # pragma: no cover - a setup error, not a runtime one
    sys.exit("pip3 install pyjwt cryptography")

ROOT = pathlib.Path(__file__).resolve().parent.parent
API = "https://api.appstoreconnect.apple.com"

BUNDLE_ID = "com.remotecraft.ios"
APP_NAME = "Remote Craft"
SKU = "remote-craft-ios"
LOCALE = "en-US"


def load_env() -> dict[str, str]:
    path = ROOT / "deploy.env"
    if not path.exists():
        sys.exit(f"{path} not found — copy deploy.env.example and fill it in")
    env: dict[str, str] = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            key, value = line.split("=", 1)
            env[key.strip()] = value.strip()
    for required in ("ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_KEY_PATH"):
        if required not in env:
            sys.exit(f"{required} missing from deploy.env")
    return env


def token(env: dict[str, str]) -> str:
    key = pathlib.Path(os.path.expanduser(env["ASC_KEY_PATH"])).read_text()
    return jwt.encode(
        {
            "iss": env["ASC_ISSUER_ID"],
            "exp": int(time.time()) + 600,
            "aud": "appstoreconnect-v1",
        },
        key,
        algorithm="ES256",
        headers={"kid": env["ASC_KEY_ID"], "typ": "JWT"},
    )


def call(bearer: str, method: str, path: str, body: dict | None = None) -> dict:
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(API + path, data=data, method=method)
    request.add_header("Authorization", f"Bearer {bearer}")
    if data:
        request.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(request) as response:
            raw = response.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as error:
        detail = error.read().decode(errors="replace")
        try:
            errors = json.loads(detail)["errors"]
            detail = "; ".join(
                f"{e.get('title')}: {e.get('detail')}" for e in errors
            )
        except Exception:
            pass
        raise SystemExit(f"{method} {path} -> HTTP {error.code}: {detail}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--create", action="store_true",
                        help="create what is missing instead of only reporting")
    args = parser.parse_args()

    bearer = token(load_env())

    ids = call(bearer, "GET", f"/v1/bundleIds?limit=200&filter[identifier]={BUNDLE_ID}")
    bundle = ids["data"][0] if ids["data"] else None
    print(f"bundle id {BUNDLE_ID}: {'present' if bundle else 'MISSING'}")

    apps = call(bearer, "GET", f"/v1/apps?limit=200&filter[bundleId]={BUNDLE_ID}")
    app = apps["data"][0] if apps["data"] else None
    print(f"app record  {BUNDLE_ID}: "
          f"{'present (id ' + app['id'] + ')' if app else 'MISSING'}")

    if bundle and app:
        return 0
    if not args.create:
        print("\nnothing created — rerun with --create")
        return 1

    if not bundle:
        print(f"creating bundle id {BUNDLE_ID}…")
        bundle = call(bearer, "POST", "/v1/bundleIds", {
            "data": {
                "type": "bundleIds",
                "attributes": {
                    "identifier": BUNDLE_ID,
                    "name": APP_NAME.replace(" ", ""),
                    "platform": "IOS",
                },
            }
        })["data"]
        print(f"  created {bundle['id']}")

    if not app:
        # Apple does not expose app-record creation: POST /v1/apps answers
        # "The resource 'apps' does not allow 'CREATE'". The bundle id above is
        # the part that can be automated; the record itself is a web form, once
        # per app, forever. Say so plainly rather than retrying something the
        # API will never permit.
        print()
        print(f"The app record must be created by hand — the App Store Connect")
        print(f"API does not allow creating one. It takes about a minute:")
        print()
        print(f"  1. https://appstoreconnect.apple.com/apps  ->  +  ->  New App")
        print(f"  2. Platform   iOS")
        print(f"  3. Name       {APP_NAME}         (must be unique across the store)")
        print(f"  4. Language   {LOCALE}")
        print(f"  5. Bundle ID  {BUNDLE_ID}   (registered, id {bundle['id']})")
        print(f"  6. SKU        {SKU}")
        print()
        print("Then rerun this script to confirm, and ./deploy-testflight.sh to ship.")
        return 1

    print("\nready — run ./deploy-testflight.sh")
    return 0


if __name__ == "__main__":
    sys.exit(main())
