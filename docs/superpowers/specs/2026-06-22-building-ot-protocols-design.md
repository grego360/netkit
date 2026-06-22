# Building / OT protocols — design spec

**Date:** 2026-06-22
**Target:** `netkit` (single bash script, Raspberry Pi 5 handheld, aarch64, Raspberry Pi OS Bookworm)
**Status:** Approved design — ready for implementation plan

## Goal

Add a new top-level dashboard category, **`🏭 Building / OT`**, giving field commissioning
the ability to **scan, find, and update (read/write)** the building-automation / OT
protocols an AV/BMS integrator meets on site: **Modbus**, **BACnet**, **KNX**, plus a
one-tap **ICS/OT fingerprint sweep**.

This fits netkit's existing audience and adjacency (it already has PJLink, SNMP,
RS232/IP device control, Dante/AV-over-IP, PTP).

## Constraints (inherited, non-negotiable)

- Single bash file; `set -uo pipefail` (no `-e`). Every new global initialised for `set -u`.
- Runs as the normal user; `sudo` only per-action.
- **Tool-selection tiering:** (1) Debian Bookworm arm64 **apt** package, else
  (2) single **prebuilt aarch64 binary** via the `PREBUILT_*` registry, else
  (3) compile — **forbidden on the Pi**. A Python venv was considered and rejected.
- Optional tools gate behind `require <cmd> "<pkg-hint>" || return`.
- Output wrappers: `run`/`runsh` for interactive/streaming TUIs (own the terminal);
  `page` for **finite batch** output only (it captures stdout+stderr — capturing a
  streaming/interactive command corrupts the terminal).
- Mandatory pre-delivery verification: `bash -n netkit` and `shellcheck -s bash netkit`
  must both be zero-output. No hardware run is possible from the dev Mac; hardware
  checks deferred to `netkit selftest` / `netkit doctor` on the Pi.

## Tool decisions (researched, 2026)

| Protocol | Tool | Tier | Verdict |
|---|---|---|---|
| Modbus | `mbpoll` | apt (Bookworm main, arm64) | KEEP |
| BACnet read/write | `rusty-bacnet` (`bacnet` binary) | prebuilt arm64 binary | SWITCH (was venv) |
| BACnet discovery | nmap `bacnet-info` NSE | apt core | KEEP (zero-dep fallback) |
| KNX | `knxd-tools` (`knxtool`) | apt (Bookworm) | KEEP |
| Sweep / S7 / EtherNet-IP / Modbus discovery | nmap NSE | apt core | KEEP |

### Why rusty-bacnet over a Python (bacpypes3) venv

`python -m bacpypes3` is an **interactive REPL**, not a one-shot CLI — the original
venv plan would not have functioned without an embedded helper script plus venv
lifecycle management (PEP 668). `jscott3201/rusty-bacnet` (MIT, Rust, ASHRAE 135-2020)
publishes a `bacnet-linux-arm64` release binary and offers first-class one-shot
subcommands, collapsing the whole feature to a single `PREBUILT_*` row:

- Read: `bacnet -i <localip> read <target> <obj> <prop>` → e.g. `bacnet read 192.168.1.100 ai:1 pv`
- Write: `bacnet -i <localip> write <target> <obj> <prop> <value> --priority 8`
- Discover/WhoIs: `bacnet -i <localip> discover [low-high]`, optional `-b <broadcast-ip>`
- Object/prop accept shorthand (`ai`, `av`, `pv`) or kebab (`analog-input`, `present-value`).
- Global flags: `-i/--interface <IP>` (bind local NIC), `-p/--port` (default 47808),
  `-b/--broadcast <IP>`. On the multi-homed handheld we pass `-i "$SELFIP"`.

`install_release_bin`'s `case "$url"` already has a `*) cp "$tmp/dl" "$tmp/$bin"`
fallback (netkit:1335), so a **bare (non-tarball) binary asset installs with zero code
change** — only the registry row is needed.

## Architecture

A new `m_ot` function following the existing `m_*` pattern, plus one
`"ot|🏭 Building / OT"` line and `case` branch in the main category loop. Protocols
with several actions get their own nested `m_*` sub-menu; the sweep is a single action.

```
🏭 Building / OT  (m_ot)
  modbus → m_modbus   (scan · read · write; TCP + RTU serial)
  bacnet → m_bacnet   (discover · read · write)
  knx    → m_knx      (busmonitor · group read · group write)
  sweep  → ICS/OT fingerprint sweep (one nmap NSE batch)
  back
```

Each unit is independently understandable: a sub-menu builds a `menu`, dispatches keys
to actions, and depends only on the shared helpers (`require`, `ask_*`, `run`/`page`,
the live-fact globals `IFACE`/`GW`/`CIDR`/`SELFIP`).

## Component detail

### 1. Modbus — `m_modbus` (gate `require mbpoll "mbpoll"`)

Ad-hoc prompts (no saved register-map profiles in v1). Every read/write first asks
**TCP or RTU**, then host (`ask_ip`, default `$GW`) or serial device + baud + framing
(reusing the device-control serial prompt style).

- **scan** — `page sudo nmap -p502 --script modbus-discover --script-args modbus-discover.aggressive <subnet>`
  (`ask_cidr`, default `$CIDR`). Enumerates slave IDs + vendor/firmware. Finite → `page`.
- **read** — prompt slave ID, register type, start address, count → `page mbpoll … -1 …`.
- **write** — prompt slave ID, register type (coil/holding only), address, value, confirm
  → `mbpoll … -1 … -- <value>`.

mbpoll flags (verified against Bookworm manpage), baked-in fixes:
- `-m tcp|rtu` — **TCP is the default**, so RTU must pass `-m rtu`.
- **`-1` on every read/write** — mbpoll otherwise loops forever (re-polls every `-l` ms)
  and would hang/corrupt `page`. `-1` = poll once and exit → finite.
- `-a <slave>` (unit ID). `-t 0|1|3|4` = coil / discrete-input / input-reg / holding-reg.
- `-r <addr>` start, `-c <count>`. Default RTU parity is **even** → pass `-P none` by default.
- Explicit **address-base prompt** (1 = protocol/40001-style default, 0 = raw PDU via `-0`)
  to avoid off-by-one confusion.
- Write = value(s) as trailing args; **`--` separator before negative values**.

### 2. BACnet — `m_bacnet`

Discovery is zero-dependency (nmap, works before `netkit setup`); read/write gate behind
the `bacnet` binary. Discovery and read/write must run **sequentially** — both bind UDP
47808 and will collide if concurrent.

- **discover (nmap)** — `page sudo nmap -sU -p47808 --script bacnet-info <subnet>`. Always available.
- **discover (WhoIs, richer)** — `require bacnet "bacnet (rusty-bacnet)" || return`;
  `page bacnet -i "$SELFIP" discover [range]`, optional `-b <broadcast>`.
- **read** — prompt device/target, object (e.g. `ai:1`), property (e.g. `pv`) →
  `page bacnet -i "$SELFIP" read <target> <obj> <prop>`.
- **write** — prompt target, object, property, value, priority (default 8), confirm →
  `bacnet -i "$SELFIP" write <target> <obj> <prop> <value> --priority <pri>`.

### 3. KNX — `m_knx` (gate `require knxtool "knxd-tools"`)

Ad-hoc; talks KNXnet/IP directly — **no running knxd daemon required** for one-shot
commands (knxtool opens the connection from the URL and exits, confirmed).

- Connection prompt: **Tunnelling `ipt:<gateway-ip>` (default)** vs **Routing `ip:` (multicast)**.
  `ipt:` is correct for a specific KNXnet/IP interface; `ip:` is multicast routing and
  largely ignores the host.
- **busmonitor** — `run knxtool vbusmonitor1 <url>` (streams forever → `run`, **never `page`**).
- **group read** — `page knxtool groupread <url> <group-address>` (GA format `x/y/z`).
- **group write** — prompt GA + value, confirm → `page knxtool groupwrite <url> <ga> <value>`
  (`groupwrite` preferred over `groupswrite` for generic DPT values).

### 4. ICS/OT fingerprint sweep (single action)

`page sudo nmap -sU -sT -p T:102,502,44818,U:47808 --script s7-info,modbus-discover,enip-info,bacnet-info <subnet> --host-timeout <t>`

All four NSE scripts ship in stock Bookworm nmap (7.93); mixed `-p T:…,U:…` and `-sU -sT`
are valid. `--host-timeout` bounds the slow UDP leg. Finite → `page`-safe. Answers "what
OT/ICS gear is on this wire?" in one tap.

## Dependency & setup wiring

- `do_setup` `pkgs` array += `mbpoll`, `knxd-tools` (apt).
- `do_setup` prebuilt loop gets one new `PREBUILT_*` row (all four parallel arrays):
  - `PREBUILT_REPOS`: `jscott3201/rusty-bacnet`
  - `PREBUILT_RX`: `bacnet-linux-arm64` (bare binary asset — exact name match)
  - `PREBUILT_BIN`: `bacnet`
  - `PREBUILT_NAME`: `bacnet (rusty-bacnet)`
- `do_selftest` `extras` list += `mbpoll`, `knxtool`, `bacnet`.
- `do_doctor` covers the new `bacnet` row automatically (it iterates `PREBUILT_*`),
  giving us drift detection (asset rename / static-vs-dynamic check on-Pi).
- New globals initialised at the top for `set -u` if any module-level state is added
  (none currently required — all state is action-local).

## Reporting integration

Every finite action (nmap scans, `mbpoll` reads, `bacnet` read/discover, KNX group read,
the sweep) flows through `page`, which sets `NETKIT_LAST_OUTPUT`. So **"save last output →
report"** works for these with no extra code.

## Help text

Add a `BT/RF`-style one-liner block to `show_help` describing the new category:
`OT/Building  Modbus, BACnet, KNX, ICS fingerprint sweep`.

## Verification

- `bash -n netkit` → zero output.
- `shellcheck -s bash netkit` → zero output (targeted `# shellcheck disable=` only with a
  justifying comment, per repo policy).
- State explicitly in the deliverable that the change is **linted but not run on hardware**.
- On the Pi: `netkit setup` (installs mbpoll, knxd-tools, the bacnet binary), then
  `netkit selftest` (tool presence) and `netkit doctor` (bacnet asset matcher resolves +
  `file`/`ldd` sanity).

## Caveats (documented, not blockers)

1. **rusty-bacnet is low-profile (19★).** Pin the install to a known-good release tag;
   `netkit doctor` watches the `bacnet-linux-arm64` asset name for drift.
2. **Static vs glibc linking of the bacnet binary is unconfirmed** until `file` / `ldd`
   on the Pi. Rust release binaries are typically self-contained glibc-dynamic, fine on
   Bookworm. Verify during `doctor`.
3. **BACnet object/property token forms** (`ai:1 pv` vs `analog-input present-value`) are
   confirmed for rusty-bacnet's CLI but should be sanity-checked against real gear.
4. **KNX `ip:` vs `ipt:`** depends on whether the site device is a router (multicast) or
   an interface (tunnelling). Default `ipt:`, offer `ip:`.
5. **UDP 47808 bind clash** — run BACnet discovery and read/write sequentially, never
   concurrently.
6. **UDP sweeps over a /24 are slow** — `--host-timeout` mitigates; note in UX.

## Out of scope (v1 / YAGNI)

- Saved Modbus register-map profiles (named registers, recall-by-label) — possible v2.
- M-Bus, DNP3, LonWorks.
- BACnet COV subscriptions, BBMD/foreign-device registration.
- KNX ETS project import, DPT decoding beyond raw values.
