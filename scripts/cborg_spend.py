#!/usr/bin/env python3
"""CBorg-style gateway spend fetcher (key-level) — optional second source.

Reads CBORG_API_KEY from tokenonomics.env and calls GET {CBORG_BASE_URL}/user/info.
Results are cached to $TOK_STATE_DIR/cborg.json. Off-net or unauthenticated
failures keep the last cached value (the widget labels it "(cached)").

If CBORG_API_KEY is empty or CBORG_BASE_URL unset, this script does nothing
(best effort: writes nothing, exits 0).
"""

import json
import os
import sys
import urllib.request


def load_env(path):
    env = {}
    if not path or not os.path.exists(path):
        return env
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip().strip('"').strip("'")
    return env


SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
ENV_FILE = os.environ.get("TOKENONOMICS_ENV",
                          os.path.join(SCRIPT_DIR, "..", "tokenonomics.env"))
ENV = load_env(ENV_FILE)

TOK_DIR = os.path.expanduser(ENV.get("TOK_DIR", os.path.join(SCRIPT_DIR, "..")))
STATE_DIR = os.path.expanduser(ENV.get("TOK_STATE_DIR", os.path.join(TOK_DIR, "state")))
BASE = ENV.get("CBORG_BASE_URL", "").rstrip("/")
KEY = ENV.get("CBORG_API_KEY", "")
BUDGET = float(ENV.get("CBORG_MAX_BUDGET", "500") or 500)
OUT = os.path.join(STATE_DIR, "cborg.json")

if not BASE or not KEY:
    sys.exit(0)


def main():
    try:
        req = urllib.request.Request(BASE + "/user/info", headers={
            "Authorization": "Bearer " + KEY,
            "User-Agent": "tokenonomics/1.0",
        })
        with urllib.request.urlopen(req, timeout=30) as r:
            data = json.loads(r.read().decode("utf-8"))
        # adapt to the shape of your gateway's /user/info response
        spend = data.get("spend", 0.0) if isinstance(data, dict) else 0.0
    except Exception:
        return "offline or unauthorized — keeping cache"

    os.makedirs(STATE_DIR, exist_ok=True)
    import datetime
    with open(OUT, "w") as f:
        json.dump({
            "spend": spend,
            "budget": BUDGET,
            "updated": datetime.datetime.now(datetime.timezone.utc).isoformat(
                timespec="seconds"),
        }, f, indent=1)
    return "ok spend=%.2f" % spend


print(main())
