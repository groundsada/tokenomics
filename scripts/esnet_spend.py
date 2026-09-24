#!/usr/bin/env python3
"""Gateway spend fetcher — reads Prometheus metrics from a LiteLLM-style gateway.

Pulls <ES_BASE_URL>/metrics/ (public, no auth needed) and sums the spend counter
series for the email configured in tokenonomics.env. Works for any gateway that
exposes the standard `litellm_spend_metric_total` series with a user_email label.

The gateway counters only exist since the gateway process last started (they
reset on restart), but the month total is kept exact with a carry-forward:

    month_spend = base_spend + (counter_now - base_counter)

  * base_counter / base_spend are snapshotted at month rollover (or from an
    existing dashboard baseline) and stored on disk.
  * The counter lives on the server, so an offline machine or a reboot loses
    nothing; the next successful run recomputes exactly.
  * Gateway restart: the counter resets to 0. Detected via a counter DROP; on
    detection the accumulated spend is carried forward, so the month figure
    stays exact. Same logic applies to the per-model split.

Runtime state is written to $TOK_STATE_DIR. Nothing here ships credentials: the
metrics endpoint requires no auth, and the only personal input is your gateway
email in tokenonomics.env.

Usage: esnet_spend.py [--force]
"""

import datetime
import gzip
import io
import json
import os
import re
import socket
import time
import urllib.request


# ----------------------------- config loading -----------------------------

def load_env(path):
    """Minimal KEY=VALUE parser (quotes/whitespace tolerant, # comments)."""
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
STATE_DIR = os.path.expanduser(ENV.get("TOK_STATE_DIR",
                                       os.path.join(TOK_DIR, "state")))
HOST = "your-gateway.example.com"

BASE_URL = ENV.get("ES_BASE_URL", "https://" + HOST).rstrip("/")
METRICS_URL = BASE_URL + "/metrics/"
EMAIL = ENV.get("ES_SPEND_EMAIL", "you@example.com")
BUDGET = float(ENV.get("ES_SPEND_BUDGET", "500") or 500)

OUT = os.path.join(STATE_DIR, "spend.json")
STATE = os.path.join(STATE_DIR, "spend_state.json")
MIN_REFRESH = 240          # min seconds between network fetches


# ----------------------------- helpers -----------------------------

def load(path):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return None


def save(path, d):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(d, f, indent=1)
    os.replace(tmp, path)


def now_iso():
    return datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")


def month_key():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m")


def _patch_dns(cached):
    """Fallback: pin cached IPs if the hostname no longer resolves."""
    orig = socket.getaddrinfo

    def patched(host, port, *args, **kwargs):
        if host == HOST and cached:
            res = []
            for fam, ip in cached:
                if fam == socket.AF_INET6:
                    res.append((socket.AF_INET6, socket.SOCK_STREAM, 6, "",
                                (ip, port, 0, 0)))
                else:
                    res.append((socket.AF_INET, socket.SOCK_STREAM, 6, "",
                                (ip, port)))
            if res:
                return res
        return orig(host, port, *args, **kwargs)

    socket.getaddrinfo = patched


def fetch_metrics(retries=3):
    last = None
    for i in range(retries):
        try:
            req = urllib.request.Request(METRICS_URL, headers={
                "Accept-Encoding": "gzip",
                "User-Agent": "tokenonomics-spend/1.0",
            })
            with urllib.request.urlopen(req, timeout=45) as r:
                raw = r.read()
            if r.headers.get("Content-Encoding") == "gzip":
                raw = gzip.GzipFile(fileobj=io.BytesIO(raw)).read()
            return raw.decode("utf-8", "replace")
        except Exception as e:
            last = e
            time.sleep(2 * (i + 1))
    raise last


def parse(metric, txt):
    pat = re.compile(r"^" + re.escape(metric) + r"\{(.*)\} ([0-9.e+-]+)$", re.M)
    total = 0.0
    count = 0
    for m in pat.finditer(txt):
        if 'user_email="%s"' % EMAIL in m.group(1):
            total += float(m.group(2))
            count += 1
    return total, count


def parse_by_model(txt):
    """Per-model spend for our user, as {model: $}."""
    pat = re.compile(r"^litellm_spend_metric_total\{(.*)\} ([0-9.e+-]+)$", re.M)
    agg = {}
    for m in pat.finditer(txt):
        labels = m.group(1)
        if 'user_email="%s"' % EMAIL not in labels:
            continue
        mm = re.search(r'model="([^"]*)"', labels)
        if not mm:
            continue
        model = mm.group(1).replace("vertex_ai/", "")
        agg[model] = agg.get(model, 0.0) + float(m.group(2))
    return agg


# ----------------------------- main -----------------------------

def main(force=False):
    os.makedirs(STATE_DIR, exist_ok=True)
    out = load(OUT)
    now = time.time()
    if not force and out and out.get("updated"):
        try:
            age = now - datetime.datetime.fromisoformat(out["updated"]).timestamp()
            if age < MIN_REFRESH and out.get("month") == month_key():
                out["age_sec"] = int(age)
                save(OUT, out)
                return "skip (fresh, %ds)" % int(age)
        except Exception:
            pass

    st = load(STATE) or {}
    cached = st.get("cached_addrs", [])

    # Resolve (any family; some gateways are AAAA-only via scoped DNS).
    try:
        res = socket.getaddrinfo(HOST, 443)
        ips0 = []
        for fam, _t, _p, _c, sa in res:
            ip = sa[0]
            if ip.startswith(("fe80:", "169.254")):
                continue
            ips0.append((fam, ip))
        if ips0:
            cached = ips0
            st["cached_addrs"] = ips0
    except OSError:
        if cached:
            _patch_dns(cached)
        else:
            return "no-dns (offline) — keeping last state"

    try:
        txt = fetch_metrics()
    except Exception as e:
        if out and out.get("month") == month_key():
            try:
                age = now - datetime.datetime.fromisoformat(out["updated"]).timestamp()
                out["age_sec"] = int(age)
                save(OUT, out)
            except Exception:
                pass
        return "fetch failed: %s" % e

    spend, nseries = parse("litellm_spend_metric_total", txt)
    reqs, _ = parse("litellm_requests_metric_total", txt)
    toks, _ = parse("litellm_total_tokens_metric_total", txt)
    curr_models = parse_by_model(txt)

    curr = month_key()
    restarted = False
    prev_counter = st.get("prev_counter")

    mb_spend = st.get("m_base_spend", {}) or {}
    mb_ctr = st.get("m_base_ctr", {}) or {}
    m_prev = st.get("m_prev", {}) or {}

    if st.get("month") == curr and st.get("base_counter") is not None:
        base_counter = st["base_counter"]
        base_spend = st.get("base_spend", 0.0)
        if prev_counter is not None and spend < prev_counter - 0.01:
            base_spend = base_spend + (prev_counter - base_counter)
            base_counter = spend
            restarted = True
            mb = dict(mb_spend)
            for m, v in m_prev.items():
                mb[m] = round(mb.get(m, 0.0) + (v - mb_ctr.get(m, 0.0)), 4)
            mb_spend = mb
            mb_ctr = {}
    else:
        base_counter = spend
        base_spend = 0.0
        if out and out.get("month") == curr and out.get("spend") is not None:
            base_spend = out["spend"]  # one-time baseline from the dashboard
        mb_spend = {}
        mb_ctr = curr_models

    month_spend = base_spend + (spend - base_counter)

    by_model = []
    seen = set()
    for m in list(mb_spend) + list(curr_models):
        if m in seen:
            continue
        seen.add(m)
        v = mb_spend.get(m, 0.0) + (curr_models.get(m, 0.0) - mb_ctr.get(m, 0.0))
        if v > 0.005:
            by_model.append({"model": m, "spend": round(v, 2)})
    by_model.sort(key=lambda x: -x["spend"])
    by_model = by_model[:6]

    model_since = curr + "-01"
    if st.get("month") != curr:
        model_since = curr + "-01"

    st.update({
        "month": curr,
        "base_counter": base_counter,
        "base_spend": base_spend,
        "prev_counter": spend,
        "m_base_spend": mb_spend,
        "m_base_ctr": mb_ctr,
        "m_prev": dict(curr_models),
        "gateway_restart_detected": st.get("gateway_restart_detected", False) or restarted,
    })
    save(STATE, st)

    save(OUT, {
        "month": curr,
        "spend": round(month_spend, 4),
        "requests": int(reqs),
        "tokens": int(toks),
        "budget": BUDGET,
        "src": "gateway metrics (public /metrics/)",
        "by_model": by_model,
        "by_model_since": model_since,
        "restarted": restarted,
        "counter_spend": round(spend, 4),
        "age_sec": 0,
        "updated": now_iso(),
    })
    return "ok spend=%.4f (counter %.4f%s) reqs=%d" % (
        month_spend, spend, " RESTART-CARRY" if restarted else "", reqs)


if __name__ == "__main__":
    import sys
    print(main(force="--force" in sys.argv))
