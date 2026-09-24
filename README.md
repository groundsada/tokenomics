# Tokenonomics

A macOS menu-bar widget (Hammerspoon) that shows your **VPN status and AI/API spend at a glance**, for the two networks you commonly sit behind:

- **ESnet-style gateway** → green pill + ESnet orb + **$ this month** (fetched **silently** from the gateway's public Prometheus metrics — no credentials, no logs in)
- **LBL/CBorg-style gateway** → green pill + lab mark + **$ this month** (via the spend API, cached when off-net)
- **Both disconnected** → red pill (defaults to showing the ESnet figure)

Click the pill → menu with both rows; **each row is a one-click connect/disconnect toggle** (the two tunnels are mutually exclusive, enforced), plus a per-model spend breakdown.

## Features

- **Real spend numbers, no API keys.** The ESnet gateway exposes standard Prometheus metrics at `/metrics/`; the widget sums the spend series for your account email. Nothing stored, nothing least-privilege-violating.
- **Survives reboots** (Hammerspoon auto-starts, state on disk), **offline windows** (counters live on the server — the math self-heals), and **gateway restarts** (counter reset is detected and the month figure is carried forward exactly).
- **Honest labels**: `(gateway)` = fresh from the live counter; `(cached)` = last known (usually because the spend API is IP-allowlisted and you're off the lab network — also the only time spend can stop, so the freeze is real, not a bug).
- **No brand assets committed.** The repo ships with no logos — see [assets/README.md](assets/README.md).

## Requirements

- macOS (menu bar widget)
- [Hammerspoon](https://www.hammerspoon.org/)
- **Viscosity** (or any OpenVPN client with AppleScript control) and/or **Cisco Secure Client**
- Python 3 (stdlib only) + `swiftc` (part of Xcode CLT) to compile the pill renderer

## Installation

```bash
git clone https://github.com/<you>/tokenonomics.git ~/Tokenonomics
cd ~/Tokenonomics
cp tokenonomics.env.example tokenonomics.env
$EDITOR tokenonomics.env            # fill in YOUR values (see below)
chmod +x scripts/vpnctl
swiftc -O -o scripts/makeblob scripts/render_blob.swift
# optional: drop your logo PNGs into assets/ (see assets/README.md)
```

Wire the widget into Hammerspoon:

```bash
mkdir -p ~/.hammerspoon
cp hammerspoon/tokenonomics.lua ~/.hammerspoon/tokenonomics.lua
```

Add to your `~/.hammerspoon/init.lua`:

```lua
require("tokenonomics")
```

Reload Hammerspoon (or run `hs -c "require('tokenonomics')"` to test first).

## Configuration

All instance-specific values live in `tokenonomics.env` (never committed). Key entries:

| Key | Meaning |
|---|---|
| `TOK_DIR` | absolute path to this repo |
| `ES_BASE_URL` | base URL of your LiteLLM-style gateway (spend fetcher hits `<base>/metrics/`) |
| `ES_SPEND_EMAIL` | your gateway account email — the per-user spend series are filtered by it |
| `ES_SPEND_BUDGET` | monthly budget shown in the menu |
| `CBORG_BASE_URL`, `CBORG_API_KEY` | optional second gateway (leave empty to disable) |
| `VISC_CONNECTION_NAME` | Viscosity connection name for your ESnet-style VPN |
| `ESNET_PING_TARGET` | IP used as the tunnel liveness check |
| `CISCO_APP_PATH`, `CISCO_PROFILE` | Cisco Secure Client bundle + profile (from `vpn hosts`) |
| `LOGO_ESNET`, `LOGO_LBL`, `LOGO_CBORG` | paths to your logo PNGs |

## How the spend math works (short version)

The gateway's `/metrics/` counters only exist since the gateway process last started (they reset on restart), so the widget tracks:

```
month spend = baseline + (counter now − counter at baseline)
```

- `baseline`/`counter at baseline` are snapshotted in `state/` at month rollover (or seeded once from your dashboard's Usage View).
- A counter **drop** (gateway restart) is detected and carried forward — the month figure never collapses.
- Per-model breakdowns use the same carry logic and are labeled with the window the split covers.

No credentials, no third-party services, no logs.

## What is NOT included (deliberately)

- **Logos / brand assets** — see [assets/README.md](assets/README.md) for why and how to add your own.
- **Any API keys or emails** — the config template has placeholders only.
- **Your actual spend data** — `state/` is git-ignored.
- **Laptop-specific paths** — everything stems from `tokenonomics.env`.

## License

MIT — see [LICENSE](LICENSE). Note: this license covers *code only*; brand assets are not included and are subject to their owners' terms.
