#!/usr/bin/env python3
"""A thin App Store Connect API client.

Credentials come from the environment, never from this file:

    set -a; source ~/.claude/skills/marcs-vibe-coding/credentials.env; set +a

which supplies ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH. The key itself stays
where it is; nothing here copies it into the repository.
"""

from __future__ import annotations

import json
import os
import time
import urllib.error
import urllib.request

import jwt

BASE = "https://api.appstoreconnect.apple.com/v1"


def token() -> str:
    key_id = os.environ["ASC_KEY_ID"]
    issuer = os.environ["ASC_ISSUER_ID"]
    with open(os.environ["ASC_KEY_PATH"], "rb") as handle:
        private_key = handle.read()
    now = int(time.time())
    return jwt.encode(
        # Twenty minutes is the maximum Apple accepts, and `aud` is required.
        {"iss": issuer, "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"},
        private_key,
        algorithm="ES256",
        headers={"kid": key_id, "typ": "JWT"},
    )


def call(method: str, path: str, body: dict | None = None) -> dict:
    url = path if path.startswith("http") else f"{BASE}{path}"
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(url, data=data, method=method)
    request.add_header("Authorization", f"Bearer {token()}")
    request.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            raw = response.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as error:
        detail = error.read().decode(errors="replace")
        raise SystemExit(f"{method} {url} -> HTTP {error.code}\n{detail}") from error


if __name__ == "__main__":
    import sys

    method = sys.argv[1] if len(sys.argv) > 1 else "GET"
    path = sys.argv[2] if len(sys.argv) > 2 else "/apps?limit=200"
    body = json.loads(sys.argv[3]) if len(sys.argv) > 3 else None
    print(json.dumps(call(method, path, body), indent=2))
