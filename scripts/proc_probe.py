#!/usr/bin/env python3
"""proc_probe.py - zero-LLM RAM/CPU snapshot + evidence verdict for the
process menubar widget (hermes-agent + Tokenomics style).

Finds the process that actually holds memory (footprint INCLUDING compressed
pages, which `ps`/Activity Monitor RSS hide), cross-checks CPU/idle/clients,
and writes:
  ~/.hermes/state/proc_snap.json    (machine-readable snapshot)
  ~/.hermes/state/proc_verdict.txt  (short human verdict for the AI button)

Checklist encoded from macos-app-recovery reference `memory-hog-2026-09.md`:
top -o mem RPRVT > ps rss; footprint -p is ground truth; provenance via
cmdline/etime/lsof; idle+zero-clients = safe kill candidate.
"""
import json
import os
import re
import subprocess
import time

HOME = os.path.expanduser("~")
STATE = os.path.join(HOME, ".hermes/state")
SNAP = os.path.join(STATE, "proc_snap.json")
VERDICT = os.path.join(STATE, "proc_verdict.txt")
PAGE = 16384  # Apple Silicon


def run(cmd, timeout=25):
    try:
        r = subprocess.run(["/bin/bash", "-lc", cmd], capture_output=True,
                           text=True, timeout=timeout)
        return r.stdout
    except Exception:
        return ""


def parse_size_gb(s):
    """'22G'/'3739M'/'786K'/'N/A' -> GB float (top -o mem units)."""
    s = s.strip()
    if not s or s in ("N/A", "-", "0"):
        return 0.0
    try:
        if s[-1].upper() in "KMG":
            v = float(s[:-1])
            k = {"K": 1024 ** -2, "M": 1024 ** -1, "G": 1.0}[s[-1].upper()]
            return round(v * k, 2)
        return 0.0
    except Exception:
        return 0.0


def parse_footprint(pid):
    out = run(f"footprint -p {pid}", timeout=20)
    m = re.search(r"phys_footprint:\s*([\d.]+)\s*([KMG]?)B", out)
    if not m:
        return None
    v, u = float(m.group(1)), m.group(2).upper()
    if u == "G":
        return round(v, 1)
    if u == "M":
        return round(v / 1024, 1)
    return round(v / (1024 ** 2), 1)  # K or bytes


def clean_name(cmd):
    if not cmd:
        return "?"
    parts = cmd.split()
    base = ""
    for p in parts:
        if p == "-m" and len(parts) > parts.index(p) + 1:
            base = base or f"python -m {parts[parts.index(p) + 1]}"
    if not base:
        base = os.path.basename(parts[0]) if parts[0].startswith("/") else parts[0]
    return base[:38]


def main():
    os.makedirs(STATE, exist_ok=True)
    ts = int(time.time())

    # --- system totals ---
    mem_b = float(run("sysctl -n hw.memsize").strip() or 0)
    total_gb = round(mem_b / (1024 ** 3), 1)
    mp = run("memory_pressure")
    free_pct = 99.0
    m1 = re.search(r"free percentage:\s*([\d.]+)%", mp)
    if m1:
        free_pct = float(m1.group(1))
    vm = run("vm_stat")
    def pages(key):
        m = re.search(key + r":\s*([\d.]+)", vm)
        return int(float(m.group(1))) if m else 0
    pages_free = pages(r"Pages free")
    comp_pages = pages(r"Pages stored in compressor")
    comp_occ = pages(r"Pages occupied by compressor")
    free_gb = round(pages_free * PAGE / 1024 ** 3, 1)
    comp_gb = round(comp_occ * PAGE / 1024 ** 3, 1)
    used_pct = round(100 - free_pct, 1)

    # --- top consumers by private memory (RPRVT includes compressed) ---
    top = run("top -l 1 -o mem -n 12 -stats pid,command,rprvt,mem,cpu")
    rows = []
    for line in top.splitlines():
        line = line.strip()
        if not line or not re.match(r"^\d+\s", line):
            continue
        toks = line.split()
        if len(toks) < 5:
            continue
        try:
            pid = int(toks[0])
            cpu = float(toks[-1])
            mem = parse_size_gb(toks[-2])
            rprvt = parse_size_gb(toks[-3])
        except Exception:
            continue
        name = " ".join(toks[1:-3])
        rows.append({"pid": pid, "name": clean_name(name), "cmd": name[:110],
                     "mem_gb": mem, "rprvt_gb": rprvt, "cpu": cpu})
    rows.sort(key=lambda r: r["mem_gb"], reverse=True)
    top = rows[:8]

    # --- ground-truth footprint for top 3 + provenance for top 5 ---
    for i, r in enumerate(top[:5]):
        if i < 3:
            fp = parse_footprint(r["pid"])
            if fp:
                r["footprint_gb"] = fp
        ps = run(f"ps -p {r['pid']} -o etime=,ppid=,command=").strip()
        parts = ps.split()
        r["etime"] = parts[0] if parts else ""
        r["ppid"] = parts[1] if len(parts) > 1 else ""
        r["full_cmd"] = " ".join(parts[2:])[:160]
        listening = run(f"lsof -nP -i -sTCP:LISTEN -p {r['pid']} 2>/dev/null | grep -c LISTEN").strip()
        est = run(f"lsof -nP -i -sTCP:ESTABLISHED -p {r['pid']} 2>/dev/null | grep -c ESTABLISHED").strip()
        r["listen"] = int(listening or 0)
        r["clients"] = int(est or 0)

    # --- rule-based verdict ---
    level, lines = "ok", []
    big = [r for r in top if (r.get("footprint_gb") or r["mem_gb"]) > 0.15 * total_gb]
    if big:
        r0 = big[0]
        gb = r0.get("footprint_gb") or r0["mem_gb"]
        pct = round(100 * gb / total_gb)
        etime = r0.get("etime", "?")
        idle = r0["cpu"] < 3 and r0.get("clients", 0) == 0
        if idle:
            level = "bad" if gb > 0.3 * total_gb else "watch"
        else:
            level = "bad" if r0["cpu"] > 60 else "watch"
        lines.append(f"Largest consumer: {r0['name']} (pid {r0['pid']}) "
                     f"{gb} GB = {pct}% of {total_gb} GB RAM")
        if idle:
            lines.append("It is IDLE: CPU %.1f%%, %d client(s), up %s -> "
                         "leftover; safe to kill." % (r0["cpu"], r0["clients"], etime))
            if r0.get("full_cmd"):
                lines.append("cmd: " + r0["full_cmd"][:120])
        else:
            lines.append("It is ACTIVE (CPU %.1f%%): in use, do not kill." % r0["cpu"])
    else:
        lines.append(f"No single process over 15% of RAM. Top: " +
                     ", ".join(f"{r['name']} {r['mem_gb']}G" for r in top[:3]))

    verdict_text = "\n".join(lines)
    with open(VERDICT, "w") as f:
        f.write(verdict_text + "\n")
    snap = {
        "ts": ts, "total_gb": total_gb, "used_pct": used_pct, "free_gb": free_gb,
        "compressed_gb": comp_gb, "level": level,
        "top": [r for r in top if (r.get("footprint_gb") or r["mem_gb"]) > 0.1],
        "verdict": verdict_text,
    }
    with open(SNAP, "w") as f:
        json.dump(snap, f, indent=1)
    print(json.dumps(snap, indent=1))


if __name__ == "__main__":
    main()
