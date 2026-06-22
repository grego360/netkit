# Building / OT protocols Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `🏭 Building / OT` dashboard category to `netkit` that can scan, find, and read/write Modbus, BACnet, and KNX, plus a one-tap ICS/OT fingerprint sweep.

**Architecture:** Additive change to the single `netkit` bash file. One new top-level menu entry dispatching to `m_ot`, which dispatches to per-protocol sub-menus (`m_modbus`, `m_bacnet`, `m_knx`) and an inline sweep action. Tools: `mbpoll` (apt) for Modbus, nmap NSE (apt core) for discovery/sweep, `rusty-bacnet` (prebuilt arm64 binary via the existing `PREBUILT_*` registry) for BACnet read/write, `knxtool` from `knxd-tools` (apt) for KNX.

**Tech Stack:** bash 5.2 (Raspberry Pi OS Bookworm, aarch64), `gum` (menu UI), `nmap`, `mbpoll`, `knxd-tools`/`knxtool`, `rusty-bacnet`.

## Global Constraints

- Single file `netkit`; `set -uo pipefail` (no `-e`). Every new global initialised before use (set -u safe).
- Runs as the normal user; `sudo` only per-action (raw sockets for nmap UDP/raw scans).
- Tool tiering: apt > prebuilt arm64 binary (`PREBUILT_*` registry) > compile (FORBIDDEN on the Pi). No Python venv.
- Optional tools gate behind `require <cmd> "<pkg-hint>" || return`.
- `run`/`runsh` = interactive/streaming TUIs (own the terminal). `page` = finite batch output only (captures stdout+stderr; corrupts a streaming/interactive command). Never wrap a streaming command in `page`.
- **Per-task verification gate (no runtime test harness exists):** `bash -n netkit` AND `shellcheck -s bash netkit` must both produce ZERO output. Targeted `# shellcheck disable=SCxxxx` only with a justifying comment. Work is "linted, not run on hardware" — say so in commits/handoff.
- `mbpoll` reads/writes MUST pass `-1` (poll once and exit) — mbpoll otherwise loops forever and would hang `page`.
- BACnet binds local UDP 47808 via `-i "$SELFIP"`; discovery and read/write must not run concurrently.
- KNX uses `ipt:<gateway-ip>` (tunnelling) by default; `ip:` (multicast routing) offered as an option.

---

### Task 1: Dependency & prebuilt-binary registry wiring

Installs the apt tools, registers the `rusty-bacnet` binary so `do_setup`/`do_doctor` handle it, and lists the new tools in `selftest` and `help`. No menu actions yet — this is the foundation later tasks gate on.

**Files:**
- Modify: `netkit` — `PREBUILT_*` arrays (~lines 1312–1320), `do_setup` `pkgs` (~line 1355), `do_selftest` `extras` (~lines 1402–1404), `show_help` CATEGORIES block (~lines 1572–1586).

**Interfaces:**
- Consumes: existing `install_release_bin` (its `case "$url"` already has a `*) cp "$tmp/dl" "$tmp/$bin"` fallback at netkit:1335, so a bare non-archive binary asset installs unchanged).
- Produces: `mbpoll`, `knxtool`, `bacnet` available on `PATH` after `netkit setup`; `bacnet` row visible to `netkit doctor`.

- [ ] **Step 1: Add the `bacnet` row to all four `PREBUILT_*` arrays**

Find (netkit ~1312–1320):

```bash
PREBUILT_REPOS=(librespeed/speedtest-cli orf/gping imsnif/bandwhich ducaale/xh)
PREBUILT_RX=(
  'linux_arm64\.tar\.gz$'
  '(aarch64|arm64).*linux.*tar\.gz$|linux.*(musl|gnu).*(aarch64|arm64).*tar\.gz$'
  'aarch64-unknown-linux-(musl|gnu).*tar\.gz$|aarch64.*linux.*tar\.gz$'
  'aarch64-unknown-linux-(musl|gnu).*tar\.gz$|aarch64.*linux.*tar\.gz$'
)
PREBUILT_BIN=(librespeed-cli gping bandwhich xh)
PREBUILT_NAME=('librespeed-cli (WAN speed test)' 'gping (ping graph)' 'bandwhich (per-process bw)' 'xh (modern curl)')
```

Replace with (one new element appended to each array — keep the arrays index-aligned):

```bash
PREBUILT_REPOS=(librespeed/speedtest-cli orf/gping imsnif/bandwhich ducaale/xh jscott3201/rusty-bacnet)
PREBUILT_RX=(
  'linux_arm64\.tar\.gz$'
  '(aarch64|arm64).*linux.*tar\.gz$|linux.*(musl|gnu).*(aarch64|arm64).*tar\.gz$'
  'aarch64-unknown-linux-(musl|gnu).*tar\.gz$|aarch64.*linux.*tar\.gz$'
  'aarch64-unknown-linux-(musl|gnu).*tar\.gz$|aarch64.*linux.*tar\.gz$'
  'bacnet-linux-arm64$'
)
PREBUILT_BIN=(librespeed-cli gping bandwhich xh bacnet)
PREBUILT_NAME=('librespeed-cli (WAN speed test)' 'gping (ping graph)' 'bandwhich (per-process bw)' 'xh (modern curl)' 'bacnet (rusty-bacnet)')
```

- [ ] **Step 2: Add `mbpoll` and `knxd-tools` to `do_setup` apt packages**

Find (netkit ~1355):

```bash
  local pkgs=(mosquitto-clients ethtool snmp fping ipcalc wakeonlan unzip
              bluez bluez-tools rtl-433 rtl-sdr swaks tio xxd)
```

Replace with:

```bash
  local pkgs=(mosquitto-clients ethtool snmp fping ipcalc wakeonlan unzip
              bluez bluez-tools rtl-433 rtl-sdr swaks tio xxd
              mbpoll knxd-tools)
```

- [ ] **Step 3: Add `mbpoll`, `knxtool`, `bacnet` to `do_selftest` extras**

Find (netkit ~1402–1404):

```bash
  local x extras=(gping bandwhich xh librespeed-cli mosquitto_sub ethtool snmpwalk fping
                  ipcalc wakeonlan bluetoothctl btmon rtl_433 rtl_power swaks
                  omping ptp4l rdisc6 tio socat xxd)
```

Replace with:

```bash
  local x extras=(gping bandwhich xh librespeed-cli mosquitto_sub ethtool snmpwalk fping
                  ipcalc wakeonlan bluetoothctl btmon rtl_433 rtl_power swaks
                  omping ptp4l rdisc6 tio socat xxd
                  mbpoll knxtool bacnet)
```

- [ ] **Step 4: Add a CATEGORIES line to `show_help`**

Find (netkit ~1581, inside the `show_help` heredoc):

```bash
  DevCtrl      RS232/TCP/UDP send+read, live session, saved devices, PJLink
```

Add immediately after it:

```bash
  OT/Building  Modbus (mbpoll), BACnet (nmap+rusty-bacnet), KNX (knxtool), ICS sweep
```

- [ ] **Step 5: Verify (lint + syntax)**

Run: `bash -n netkit && shellcheck -s bash netkit && echo OK`
Expected: `OK` and nothing else.

- [ ] **Step 6: Commit**

```bash
git add netkit
git commit -m "feat(ot): register mbpoll, knxd-tools, rusty-bacnet deps for Building/OT category"
```

---

### Task 2: `m_ot` category, main-loop wiring, and ICS/OT sweep

Adds the new top-level category and the standalone sweep action. The sub-menus (`m_modbus`/`m_bacnet`/`m_knx`) are added by Tasks 3–5; until then `m_ot` shows only the sweep + back, and every committed state is a fully working netkit.

**Files:**
- Modify: `netkit` — insert `ot_sweep` + `m_ot` after `m_system` (the `}` at netkit:1168, immediately before the `# ---------- report generators ----------` comment at netkit:1170); add a menu line + `case` branch in the main loop (~lines 1639–1672).

**Interfaces:**
- Consumes: `menu`, `ask_cidr`, `need_iface`, `page`, globals `CIDR`.
- Produces: `m_ot` (called from the main loop). Later tasks add `m_modbus`/`m_bacnet`/`m_knx` and extend `m_ot`'s menu + case.

- [ ] **Step 1: Insert `ot_sweep` and `m_ot`**

Insert this block on a new line directly after `m_system`'s closing `}` (netkit:1168) and before the `# ---------- report generators ----------` line:

```bash
# ---------- Building / OT protocols ----------
# ICS/OT fingerprint sweep: one nmap pass over the common OT ports. All four NSE
# scripts ship with Debian's nmap. Mixed T:/U: port list + -sU -sT is one scan.
ot_sweep() {
  need_iface || return
  local n; n="$(ask_cidr "Subnet:" "$CIDR")" || return
  page sudo nmap -sU -sT -p T:102,502,44818,U:47808 \
    --script s7-info,modbus-discover,enip-info,bacnet-info --host-timeout 30s "$n"
}

m_ot() {
  local k; k="$(menu "🏭 Building / OT" \
    "sweep|ICS/OT fingerprint sweep (nmap: S7/Modbus/EtherNet-IP/BACnet)" \
    "back|‹ back")"
  case "$k" in
    sweep) ot_sweep ;;
    *) return ;;
  esac
}
```

- [ ] **Step 2: Wire `m_ot` into the main category loop**

Find (netkit ~1650, inside the main `menu` call):

```bash
    "rf|📶 Bluetooth / RF" \
    "report|📊 Reporting" \
```

Replace with:

```bash
    "rf|📶 Bluetooth / RF" \
    "ot|🏭 Building / OT" \
    "report|📊 Reporting" \
```

Then find (netkit ~1667, in the dispatch `case`):

```bash
    rf) m_rf ;;
    report) m_report ;;
```

Replace with:

```bash
    rf) m_rf ;;
    ot) m_ot ;;
    report) m_report ;;
```

- [ ] **Step 3: Verify (lint + syntax)**

Run: `bash -n netkit && shellcheck -s bash netkit && echo OK`
Expected: `OK` and nothing else.

- [ ] **Step 4: Commit**

```bash
git add netkit
git commit -m "feat(ot): add Building/OT category with ICS/OT nmap fingerprint sweep"
```

---

### Task 3: Modbus sub-menu (`m_modbus`)

nmap discovery + ad-hoc `mbpoll` read/write over TCP or RTU serial, with the `-1` one-shot, parity, and address-base fixes from the review.

**Files:**
- Modify: `netkit` — add globals + `modbus_conn` + `modbus_rw` + `m_modbus` directly after `m_ot` (before the report-generators comment); add a `modbus` line + case branch to `m_ot`.

**Interfaces:**
- Consumes: `menu`, `ask`, `ask_ip`, `ask_num`, `ask_req`, `ask_cidr`, `page`, `pause`, globals `GW`/`CIDR`.
- Produces: `m_modbus` (called from `m_ot`). Uses module globals `G_MB_OPTS` (array) and `G_MB_TARGET` (string).

- [ ] **Step 1: Insert the Modbus functions**

Insert directly after `m_ot`'s closing `}` (and before `# ---------- report generators ----------`):

```bash
# Modbus connection prompt -> fills G_MB_OPTS (mbpoll option args) + G_MB_TARGET
# (positional host or serial device, which mbpoll wants LAST). rc1 on cancel.
G_MB_OPTS=(); G_MB_TARGET=""
modbus_conn() {
  G_MB_OPTS=(); G_MB_TARGET=""
  local tr; tr="$(menu "Transport" "tcp|Modbus TCP" "rtu|Modbus RTU (serial)")"
  [ -z "$tr" ] && return 1
  if [ "$tr" = tcp ]; then
    local host port
    host="$(ask_ip "Device IP:" "$GW")" || return 1
    port="$(ask_num "TCP port:" "502")" || return 1
    G_MB_OPTS=(-m tcp -p "$port"); G_MB_TARGET="$host"
  else
    local dev baud parity
    dev="$(ask "Serial device:" "/dev/ttyUSB0")"
    [ -e "$dev" ] || { clear; echo "No such device: $dev"; pause; return 1; }
    baud="$(ask_num "Baud:" "9600")" || return 1
    # mbpoll RTU parity DEFAULTS to even — default to none (8N1) which most gear uses.
    parity="$(menu "Parity" "none|None (8N1)" "even|Even (8E1)" "odd|Odd (8O1)")"
    [ -z "$parity" ] && parity=none
    G_MB_OPTS=(-m rtu -b "$baud" -P "$parity"); G_MB_TARGET="$dev"
  fi
  return 0
}

# modbus_rw read|write — ad-hoc poll/write. Always -1 (one-shot) so output is finite.
modbus_rw() {
  local mode="$1"
  modbus_conn || return
  local slave rtype addr base
  slave="$(ask_num "Slave/unit ID:" "1")" || return
  if [ "$mode" = read ]; then
    rtype="$(menu "Register type" \
      "0|Coil (RW)" "1|Discrete input (RO)" "3|Input register (RO)" "4|Holding register (RW)")"
  else
    rtype="$(menu "Register type" "0|Coil (RW)" "4|Holding register (RW)")"
  fi
  [ -z "$rtype" ] && return
  addr="$(ask_num "${mode^} address:" "1")" || return
  base="$(menu "Address base" "1|1-based (40001-style, default)" "0|0-based (raw PDU)")"
  [ "$base" = 0 ] && G_MB_OPTS+=(-0)
  if [ "$mode" = read ]; then
    local count; count="$(ask_num "Count:" "1")" || return
    page mbpoll "${G_MB_OPTS[@]}" -a "$slave" -t "$rtype" -r "$addr" -c "$count" -1 "$G_MB_TARGET"
  else
    local value a; value="$(ask_req "Value to write:" "")" || return
    a="$(ask "Write '$value' to $G_MB_TARGET (slave $slave, t$rtype @$addr)? (y/N):" "N")"
    case "$a" in y|Y|yes|YES) ;; *) clear; echo "Cancelled."; pause; return ;; esac
    # '--' guards a negative value from being parsed as an option.
    page mbpoll "${G_MB_OPTS[@]}" -a "$slave" -t "$rtype" -r "$addr" -1 "$G_MB_TARGET" -- "$value"
  fi
}

m_modbus() {
  require mbpoll "mbpoll" || return
  local k; k="$(menu "🔧 Modbus" \
    "scan|Scan for Modbus devices (nmap, TCP 502)" \
    "read|Read registers" \
    "write|Write a register" \
    "back|‹ back")"
  case "$k" in
    scan) local n; n="$(ask_cidr "Subnet:" "$CIDR")" || return
          page sudo nmap -p502 --open --script modbus-discover \
            --script-args modbus-discover.aggressive=true "$n" ;;
    read) modbus_rw read ;;
    write) modbus_rw write ;;
    *) return ;;
  esac
}
```

- [ ] **Step 2: Add the `modbus` entry to `m_ot`**

In `m_ot`, find:

```bash
    "sweep|ICS/OT fingerprint sweep (nmap: S7/Modbus/EtherNet-IP/BACnet)" \
    "back|‹ back")"
  case "$k" in
    sweep) ot_sweep ;;
```

Replace with:

```bash
    "modbus|Modbus (scan / read / write)" \
    "sweep|ICS/OT fingerprint sweep (nmap: S7/Modbus/EtherNet-IP/BACnet)" \
    "back|‹ back")"
  case "$k" in
    modbus) m_modbus ;;
    sweep) ot_sweep ;;
```

- [ ] **Step 3: Verify (lint + syntax)**

Run: `bash -n netkit && shellcheck -s bash netkit && echo OK`
Expected: `OK` and nothing else.
Note: if shellcheck flags `${mode^}` (parameter-expansion case), that is valid bash 4+/5.2; leave as-is (no disable needed — shellcheck accepts it).

- [ ] **Step 4: Commit**

```bash
git add netkit
git commit -m "feat(ot): add Modbus scan/read/write via nmap + mbpoll"
```

---

### Task 4: BACnet sub-menu (`m_bacnet`)

Zero-dependency nmap discovery (works before setup) plus `rusty-bacnet` WhoIs/read/write, all bound to the local interface.

**Files:**
- Modify: `netkit` — add `bacnet_read` + `bacnet_write` + `m_bacnet` after `m_modbus`; add a `bacnet` line + case branch to `m_ot`.

**Interfaces:**
- Consumes: `menu`, `ask`, `ask_req`, `ask_num`, `ask_cidr`, `require`, `need_iface`, `page`, `pause`, globals `IFACE`/`CIDR`/`SELFIP`.
- Produces: `m_bacnet` (called from `m_ot`). Invokes the `bacnet` binary as `bacnet -i "$SELFIP" <read|write|discover> …`.

- [ ] **Step 1: Insert the BACnet functions**

Insert directly after `m_modbus`'s closing `}`:

```bash
bacnet_read() {
  local tgt obj prop
  tgt="$(ask_req "Device (IP or instance):" "")" || return
  obj="$(ask_req "Object (e.g. ai:1 or analog-input,0):" "")" || return
  prop="$(ask_req "Property (e.g. pv):" "pv")" || return
  page bacnet -i "$SELFIP" read "$tgt" "$obj" "$prop"
}

bacnet_write() {
  local tgt obj prop val pri a
  tgt="$(ask_req "Device (IP or instance):" "")" || return
  obj="$(ask_req "Object (e.g. av:1):" "")" || return
  prop="$(ask_req "Property (e.g. pv):" "pv")" || return
  val="$(ask_req "Value to write:" "")" || return
  pri="$(ask_num "Priority (1-16):" "8")" || return
  a="$(ask "Write '$val' to $tgt $obj $prop @prio $pri? (y/N):" "N")"
  case "$a" in y|Y|yes|YES) ;; *) clear; echo "Cancelled."; pause; return ;; esac
  page bacnet -i "$SELFIP" write "$tgt" "$obj" "$prop" "$val" --priority "$pri"
}

# Discovery via nmap needs no setup; WhoIs/read/write need the rusty-bacnet binary.
# Run discovery and read/write sequentially — both bind local UDP 47808.
m_bacnet() {
  need_iface || return
  local k; k="$(menu "🏢 BACnet/IP ($IFACE)" \
    "nmap|Discover devices (nmap, no setup needed)" \
    "whois|Discover devices (WhoIs, rusty-bacnet)" \
    "read|Read a property" \
    "write|Write a property" \
    "back|‹ back")"
  case "$k" in
    nmap) local n; n="$(ask_cidr "Subnet:" "$CIDR")" || return
          page sudo nmap -sU -p47808 --open --script bacnet-info "$n" ;;
    whois) require bacnet "bacnet (rusty-bacnet)" || return
           local r; r="$(ask "Instance range (blank = all, e.g. 1-4000):" "")"
           if [ -n "$r" ]; then page bacnet -i "$SELFIP" discover "$r"
           else page bacnet -i "$SELFIP" discover; fi ;;
    read) require bacnet "bacnet (rusty-bacnet)" || return; bacnet_read ;;
    write) require bacnet "bacnet (rusty-bacnet)" || return; bacnet_write ;;
    *) return ;;
  esac
}
```

- [ ] **Step 2: Add the `bacnet` entry to `m_ot`**

In `m_ot`, find:

```bash
    "modbus|Modbus (scan / read / write)" \
    "sweep|ICS/OT fingerprint sweep (nmap: S7/Modbus/EtherNet-IP/BACnet)" \
    "back|‹ back")"
  case "$k" in
    modbus) m_modbus ;;
    sweep) ot_sweep ;;
```

Replace with:

```bash
    "modbus|Modbus (scan / read / write)" \
    "bacnet|BACnet/IP (discover / read / write)" \
    "sweep|ICS/OT fingerprint sweep (nmap: S7/Modbus/EtherNet-IP/BACnet)" \
    "back|‹ back")"
  case "$k" in
    modbus) m_modbus ;;
    bacnet) m_bacnet ;;
    sweep) ot_sweep ;;
```

- [ ] **Step 3: Verify (lint + syntax)**

Run: `bash -n netkit && shellcheck -s bash netkit && echo OK`
Expected: `OK` and nothing else.

- [ ] **Step 4: Commit**

```bash
git add netkit
git commit -m "feat(ot): add BACnet discovery (nmap) + read/write (rusty-bacnet)"
```

---

### Task 5: KNX sub-menu (`m_knx`)

KNXnet/IP bus monitor + group read/write via `knxtool`, defaulting to `ipt:` tunnelling.

**Files:**
- Modify: `netkit` — add `m_knx` after `m_bacnet`; add a `knx` line + case branch to `m_ot`.

**Interfaces:**
- Consumes: `menu`, `ask`, `ask_ip`, `ask_req`, `require`, `run`, `page`, `pause`, global `GW`.
- Produces: `m_knx` (called from `m_ot`). Uses `knxtool <applet> <url> …` with `url` = `ipt:<gw>` or `ip:`.

- [ ] **Step 1: Insert the KNX function**

Insert directly after `m_bacnet`'s closing `}`:

```bash
# knxtool talks KNXnet/IP directly from the URL — no running knxd daemon needed for
# one-shot commands. ipt:<gw> = tunnelling to a specific interface (default);
# ip: = multicast routing. vbusmonitor1 streams forever -> run (never page).
m_knx() {
  require knxtool "knxd-tools" || return
  local mode url gw
  mode="$(menu "Connection" \
    "ipt|Tunnelling to a gateway (ipt:)" "ip|Routing / multicast (ip:)")"
  [ -z "$mode" ] && return
  if [ "$mode" = ipt ]; then
    gw="$(ask_ip "KNXnet/IP gateway IP:" "$GW")" || return
    url="ipt:$gw"
  else
    url="ip:"
  fi
  local k; k="$(menu "🏗 KNX ($url)" \
    "mon|Bus monitor (live)" \
    "read|Group read" \
    "write|Group write" \
    "back|‹ back")"
  case "$k" in
    mon) run knxtool vbusmonitor1 "$url" ;;
    read) local ga; ga="$(ask_req "Group address (x/y/z):" "")" || return
          page knxtool groupread "$url" "$ga" ;;
    write) local ga val a
           ga="$(ask_req "Group address (x/y/z):" "")" || return
           val="$(ask_req "Value (decimal byte(s)):" "")" || return
           a="$(ask "Write '$val' to $ga via $url? (y/N):" "N")"
           case "$a" in y|Y|yes|YES) ;; *) clear; echo "Cancelled."; pause; return ;; esac
           page knxtool groupwrite "$url" "$ga" "$val" ;;
    *) return ;;
  esac
}
```

- [ ] **Step 2: Add the `knx` entry to `m_ot`**

In `m_ot`, find:

```bash
    "bacnet|BACnet/IP (discover / read / write)" \
    "sweep|ICS/OT fingerprint sweep (nmap: S7/Modbus/EtherNet-IP/BACnet)" \
    "back|‹ back")"
  case "$k" in
    modbus) m_modbus ;;
    bacnet) m_bacnet ;;
    sweep) ot_sweep ;;
```

Replace with:

```bash
    "bacnet|BACnet/IP (discover / read / write)" \
    "knx|KNX (monitor / group read / write)" \
    "sweep|ICS/OT fingerprint sweep (nmap: S7/Modbus/EtherNet-IP/BACnet)" \
    "back|‹ back")"
  case "$k" in
    modbus) m_modbus ;;
    bacnet) m_bacnet ;;
    knx) m_knx ;;
    sweep) ot_sweep ;;
```

- [ ] **Step 3: Verify (lint + syntax)**

Run: `bash -n netkit && shellcheck -s bash netkit && echo OK`
Expected: `OK` and nothing else.

- [ ] **Step 4: Commit**

```bash
git add netkit
git commit -m "feat(ot): add KNX bus monitor + group read/write via knxtool"
```

---

## Self-Review

**Spec coverage:**
- New `🏭 Building / OT` category + `m_ot` → Task 2. ✓
- Modbus scan/read/write (mbpoll `-1`, `-m tcp|rtu`, `-a`/`-t`/`-r`/`-c`, `-P none` default, address-base toggle, `--` before write value) → Task 3. ✓
- BACnet nmap discovery (zero-dep) + rusty-bacnet WhoIs/read/write with `-i "$SELFIP"`, write confirm → Task 4. ✓
- KNX `ipt:`/`ip:`, `vbusmonitor1` via `run`, group read/write via `page`, write confirm → Task 5. ✓
- ICS/OT sweep (`-sU -sT`, mixed `T:/U:` ports, four NSE scripts, `--host-timeout`) → Task 2. ✓
- Dependency wiring: `do_setup` pkgs (mbpoll, knxd-tools), `PREBUILT_*` row (bacnet), `do_selftest` extras, `do_doctor` auto-coverage, help text → Task 1. ✓
- Reporting integration: every finite action uses `page` (sets `NETKIT_LAST_OUTPUT`) → satisfied implicitly by Tasks 2–5 (only KNX `vbusmonitor1` uses `run`, correctly, as it streams). ✓
- `set -u` globals: `G_MB_OPTS`/`G_MB_TARGET` initialised at definition site → Task 3. ✓
- Caveats (rusty-bacnet profile, static-vs-glibc, token forms, ip/ipt, 47808 clash, slow UDP) are documented in the spec and surfaced as code comments; verified on-Pi via `selftest`/`doctor`. ✓

**Placeholder scan:** No TBD/TODO/"handle edge cases"/"similar to Task N". All steps show complete code and exact find/replace anchors. ✓

**Type/name consistency:** `m_ot`/`m_modbus`/`m_bacnet`/`m_knx`/`ot_sweep`/`modbus_conn`/`modbus_rw`/`bacnet_read`/`bacnet_write` consistent across definition and dispatch. `G_MB_OPTS`/`G_MB_TARGET` defined and used consistently. Menu keys (`modbus`/`bacnet`/`knx`/`sweep`) match their `case` branches in `m_ot`. ✓

**Out of scope (per spec):** saved Modbus register-map profiles, M-Bus/DNP3/LonWorks, BACnet COV/BBMD, KNX ETS/DPT decoding — intentionally excluded. ✓
