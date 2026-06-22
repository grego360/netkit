# Device Control Category — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `🎛 Device Control` category to `netkit` for RS232/TCP/UDP device control — one-shot send+read, live interactive sessions, a per-device saved command library, and a PJLink probe.

**Architecture:** Everything lands in the single `netkit` bash file, built from existing helpers (`menu`, `ask*`, `require`, `run`, `page`). A NUL-safe byte-streaming engine drives `socat` for one-shot send+read, `tio`/`ncat` for interactive sessions. Saved devices are per-device whitelist-parsed `.conf` files mirroring the site-profile security model.

**Tech Stack:** bash (`set -uo pipefail`), `socat`, `tio` (2.5, Bookworm aarch64), `ncat`, `xxd`. Target: Raspberry Pi 5, Raspberry Pi OS Bookworm, aarch64.

**Spec:** `docs/superpowers/specs/2026-06-22-netkit-device-control-design.md`

## Global Constraints

- `set -uo pipefail` (no `-e`). Every new global initialised in the global block.
- Runs as the normal user; `sudo` only where needed. Never run the whole script as root.
- apt-first, aarch64 Bookworm packages; never compile on the Pi.
- Optional tools gated behind `require <cmd> <pkg>`; degrade cleanly.
- **`bash -n netkit` AND `shellcheck -s bash netkit` must produce ZERO output before any commit.** Targeted `# shellcheck disable=SCxxxx` only with a justifying comment.
- `run`/`runsh` wrap interactive/streaming commands; `page` wraps batch output only (captures into a shell var → never wrap a TUI; mangles binary/NUL).
- All array expansions double-quoted; guard with `[ "${#arr[@]}" -gt 0 ]` before expanding (portable `set -u` safety).
- Encoded command bytes must STREAM (never stored in a variable / command substitution) — NUL-safe.
- New deps: `tio`, `xxd` (socat, ncat already assumed present).

## Verification model (read once)

netkit has no runtime test framework. Per task:

1. **Lint gate (mandatory, every task):** both commands silent:
   ```bash
   bash -n netkit && shellcheck -s bash netkit && echo LINT-OK
   ```
   Expected output: `LINT-OK` and nothing else.
2. **Pure-function tests (where noted):** extract one function with `awk` and run it in a clean bash, asserting exact output — this gives a real red→green cycle without hardware. Pattern:
   ```bash
   bash -c "$(awk '/^FUNC_NAME\(\) \{/,/^\}/' netkit); FUNC_NAME ARGS"
   ```
   Run on this Mac with bash ≥5 if available (`/opt/homebrew/bin/bash`); otherwise the lint gate stands and the function is bench-verified on the Pi.
3. **Interactive/hardware paths:** lint + manual review only; flagged honestly as "linted, not hardware-run."

---

### Task 1: Globals + serial-framing helpers

**Files:**
- Modify: `netkit` — insert globals after the `SITE_*` block; insert helpers after the live-network-facts block (before `# ---------- categories ----------`).

**Interfaces:**
- Produces: globals `device_dir`, `DEV_NAME DEV_TRANSPORT DEV_DEV DEV_BAUD DEV_FRAMING DEV_HOST DEV_PORT DEV_READ_TIMEOUT DEV_EOL DEV_FORMAT`, arrays `DEV_CMD_LABEL DEV_CMD_FMT DEV_CMD_PAYLOAD DEV_CMD_EOL`.
- Produces: `framing_socat <framing> → "cs8,parenb=0,cstopb=0"` (rc 1 on bad); `framing_tio <framing> → "-d 8 -p none -s 1"` (rc 1 on bad).

- [ ] **Step 1: Write the failing test for `framing_socat`**

```bash
bash -c "$(awk '/^framing_socat\(\) \{/,/^\}/' netkit); framing_socat 8E1; echo; framing_socat 7O1; echo"
```
Expected now: FAIL (function not found / empty), because it isn't written yet.

- [ ] **Step 2: Add the globals block**

Insert immediately after the `SITE_*` initialisation lines (the block ending `SITE_SPEED_MIN=""; SITE_DNS_DOMAIN=""; SITE_HTTP_URL=""; SITE_PEER=""; SITE_LOGO=""`):

```bash
# ---------- device control (RS232 / IP) ----------
device_dir="$NETKIT_CFG_DIR/devices"
DEV_NAME=""; DEV_TRANSPORT=""; DEV_DEV=""; DEV_BAUD=""; DEV_FRAMING=""
DEV_HOST=""; DEV_PORT=""; DEV_READ_TIMEOUT=""; DEV_EOL=""; DEV_FORMAT=""
DEV_CMD_LABEL=(); DEV_CMD_FMT=(); DEV_CMD_PAYLOAD=(); DEV_CMD_EOL=()
```

- [ ] **Step 3: Add `framing_socat` and `framing_tio`**

Insert after the `WIRED="$(…)"` detection block, before `# ---------- categories ----------`:

```bash
# ---------- device-control helpers ----------
# framing_socat 8N1 -> "cs8,parenb=0,cstopb=0"  (rc 1 on bad framing)
framing_socat() {
  local f="$1" bits par stop out
  case "$f" in [78][NEOneo][12]) ;; *) return 1 ;; esac
  bits="${f:0:1}"; par="${f:1:1}"; stop="${f:2:1}"
  out="cs$bits"
  case "$par" in
    N|n) out="$out,parenb=0" ;;
    E|e) out="$out,parenb=1,parodd=0" ;;
    O|o) out="$out,parenb=1,parodd=1" ;;
  esac
  case "$stop" in 1) out="$out,cstopb=0" ;; 2) out="$out,cstopb=1" ;; esac
  printf '%s' "$out"
}

# framing_tio 8N1 -> "-d 8 -p none -s 1"  (rc 1 on bad framing)
framing_tio() {
  local f="$1" bits par stop p
  case "$f" in [78][NEOneo][12]) ;; *) return 1 ;; esac
  bits="${f:0:1}"; par="${f:1:1}"; stop="${f:2:1}"
  case "$par" in N|n) p=none ;; E|e) p=even ;; O|o) p=odd ;; esac
  printf '%s' "-d $bits -p $p -s $stop"
}
```

- [ ] **Step 4: Run the pure-function tests (green)**

```bash
bash -c "$(awk '/^framing_socat\(\) \{/,/^\}/' netkit); framing_socat 8E1; echo; framing_socat 7O1; echo; framing_socat 8N1; echo"
```
Expected:
```
cs8,parenb=1,parodd=0,cstopb=0
cs7,parenb=1,parodd=1,cstopb=0
cs8,parenb=0,cstopb=0
```
```bash
bash -c "$(awk '/^framing_tio\(\) \{/,/^\}/' netkit); framing_tio 8N1; echo; framing_tio 7E1; echo"
```
Expected:
```
-d 8 -p none -s 1
-d 7 -p even -s 1
```

- [ ] **Step 5: Lint gate**

```bash
bash -n netkit && shellcheck -s bash netkit && echo LINT-OK
```
Expected: `LINT-OK`

- [ ] **Step 6: Commit**

```bash
git add netkit && git commit -m "feat(devctl): globals + serial framing helpers"
```

---

### Task 2: Byte encoder + hex validation

**Files:**
- Modify: `netkit` — append to the device-control helpers section (after `framing_tio`).

**Interfaces:**
- Consumes: `xxd` (apt).
- Produces: `devctl_emit <format> <payload> <eol> → raw bytes on stdout` (format ascii|hex; eol none|cr|lf|crlf); `devctl_valid_hex <string> → rc 0 if valid even-length hex`.

- [ ] **Step 1: Write the failing test**

```bash
bash -c "$(awk '/^devctl_emit\(\) \{/,/^\}/' netkit); devctl_emit hex '01 0a ff' cr | xxd -p"
```
Expected now: FAIL (function not found).

- [ ] **Step 2: Implement `devctl_emit` and `devctl_valid_hex`**

```bash
# devctl_emit format payload eol -> raw bytes on STDOUT (streamed; NUL-safe)
devctl_emit() {
  case "$1" in
    ascii) printf '%s' "$2" ;;
    hex)   printf '%s' "$2" | tr -d ' ' | sed 's/0[xX]//g' | xxd -r -p ;;
  esac
  case "$3" in cr) printf '\r' ;; lf) printf '\n' ;; crlf) printf '\r\n' ;; esac
}

# devctl_valid_hex string -> rc 0 if even-length hex (spaces / 0x prefixes allowed)
devctl_valid_hex() {
  local h; h="$(printf '%s' "$1" | tr -d ' ' | sed 's/0[xX]//g')"
  [ -n "$h" ] || return 1
  case "$h" in *[!0-9A-Fa-f]*) return 1 ;; esac
  [ $(( ${#h} % 2 )) -eq 0 ]
}
```

- [ ] **Step 3: Run pure-function tests (green)**

```bash
bash -c "$(awk '/^devctl_emit\(\) \{/,/^\}/' netkit); devctl_emit hex '01 0a ff' cr | xxd -p"
```
Expected: `010aff0d`
```bash
bash -c "$(awk '/^devctl_emit\(\) \{/,/^\}/' netkit); devctl_emit ascii 'PWR ON' lf | xxd -p"
```
Expected: `505752204f4e0a`
```bash
bash -c "$(awk '/^devctl_valid_hex\(\) \{/,/^\}/' netkit); devctl_valid_hex '01 0a ff' && echo OK; devctl_valid_hex '0g' || echo BAD; devctl_valid_hex '010' || echo ODD"
```
Expected:
```
OK
BAD
ODD
```

- [ ] **Step 4: Lint gate**

```bash
bash -n netkit && shellcheck -s bash netkit && echo LINT-OK
```
Expected: `LINT-OK`

- [ ] **Step 5: Commit**

```bash
git add netkit && git commit -m "feat(devctl): NUL-safe byte encoder + hex validation"
```

---

### Task 3: Device library — parser + listing

**Files:**
- Modify: `netkit` — append to device-control helpers section.

**Interfaces:**
- Consumes: `device_dir`, `DEV_*` globals/arrays (Task 1).
- Produces: `load_device <name>` (rc 1 if no file; populates `DEV_*` + `DEV_CMD_*` arrays); `device_list` (prints device names, one per line); `device_show_file <name>` (cats the conf).

- [ ] **Step 1: Write the failing test**

```bash
mkdir -p /tmp/nkdev && cat > /tmp/nkdev/proj.conf <<'EOF'
# netkit device profile: proj
TRANSPORT=tcp
HOST=10.0.0.5
PORT=4352
READ_TIMEOUT=2
EOL=cr
FORMAT=ascii
CMD=Power On|ascii|PWR ON|cr
CMD=Raw Probe|hex|01 0a|none
EOF
bash -c "$(awk '/^load_device\(\) \{/,/^\}/' netkit)
device_dir=/tmp/nkdev
DEV_NAME=; DEV_TRANSPORT=; DEV_DEV=; DEV_BAUD=; DEV_FRAMING=; DEV_HOST=; DEV_PORT=; DEV_READ_TIMEOUT=; DEV_EOL=; DEV_FORMAT=
DEV_CMD_LABEL=(); DEV_CMD_FMT=(); DEV_CMD_PAYLOAD=(); DEV_CMD_EOL=()
load_device proj; echo \"\$DEV_TRANSPORT \$DEV_HOST \$DEV_PORT | \${DEV_CMD_LABEL[1]} = \${DEV_CMD_PAYLOAD[1]} (\${DEV_CMD_FMT[1]})\""
```
Expected now: FAIL (function not found).

- [ ] **Step 2: Implement `load_device`, `device_list`, `device_show_file`**

```bash
# load_device name -> rc 0 and populate DEV_* + DEV_CMD_* arrays; rc 1 if no file.
# Whitelist line parser — the .conf is NEVER sourced (security boundary).
load_device() {
  DEV_NAME=""; DEV_TRANSPORT=""; DEV_DEV=""; DEV_BAUD=""; DEV_FRAMING=""
  DEV_HOST=""; DEV_PORT=""; DEV_READ_TIMEOUT=""; DEV_EOL=""; DEV_FORMAT=""
  DEV_CMD_LABEL=(); DEV_CMD_FMT=(); DEV_CMD_PAYLOAD=(); DEV_CMD_EOL=()
  local cf="$device_dir/$1.conf"
  [ -f "$cf" ] || return 1
  DEV_NAME="$1"
  local line key val l f p e
  while IFS= read -r line; do
    case "$line" in ''|\#*) continue ;; esac
    key="${line%%=*}"; val="${line#*=}"; key="${key// /}"
    case "$key" in
      TRANSPORT) DEV_TRANSPORT="$val" ;;
      DEV) DEV_DEV="$val" ;;
      BAUD) DEV_BAUD="$val" ;;
      FRAMING) DEV_FRAMING="$val" ;;
      HOST) DEV_HOST="$val" ;;
      PORT) DEV_PORT="$val" ;;
      READ_TIMEOUT) DEV_READ_TIMEOUT="$val" ;;
      EOL) DEV_EOL="$val" ;;
      FORMAT) DEV_FORMAT="$val" ;;
      CMD) IFS='|' read -r l f p e <<< "$val"
           DEV_CMD_LABEL+=("$l"); DEV_CMD_FMT+=("$f")
           DEV_CMD_PAYLOAD+=("$p"); DEV_CMD_EOL+=("$e") ;;
      *) : ;;
    esac
  done < "$cf"
}

device_list() { find "$device_dir" -maxdepth 1 -name '*.conf' -printf '%f\n' 2>/dev/null | sed 's/\.conf$//'; }
device_show_file() { cat "$device_dir/$1.conf" 2>/dev/null; }
```

- [ ] **Step 3: Run the parser test (green)**

Re-run the Step 1 command. Expected:
```
tcp 10.0.0.5 4352 | Raw Probe = 01 0a (hex)
```
Cleanup: `rm -rf /tmp/nkdev`

- [ ] **Step 4: Lint gate**

```bash
bash -n netkit && shellcheck -s bash netkit && echo LINT-OK
```
Expected: `LINT-OK`

- [ ] **Step 5: Commit**

```bash
git add netkit && git commit -m "feat(devctl): whitelist device-profile parser + listing"
```

---

### Task 4: Send engine + address builder + interactive sessions

**Files:**
- Modify: `netkit` — append to device-control helpers section.

**Interfaces:**
- Consumes: `framing_socat` (Task 1), `devctl_emit` (Task 2), helpers `page`, `run`, `require`.
- Produces: `devctl_addr <transport> <a> <b> [c] → socat address` (serial: a=dev b=baud c=framing; tcp/udp: a=host b=port; rc 1 on bad framing); `devctl_pipe <fmt> <payload> <eol> <timeout> <addr>` (emit|socat, for use under `page`); `devctl_send <transport> <addr> <fmt> <payload> <eol> <timeout>` (text reply via page, binary reply via tmpfile+xxd); `devctl_live <transport> <a> <b> [c]` (tio/ncat interactive).

- [ ] **Step 1: Write the failing test for `devctl_addr`**

```bash
bash -c "$(awk '/^framing_socat\(\) \{/,/^\}/' netkit)
$(awk '/^devctl_addr\(\) \{/,/^\}/' netkit)
devctl_addr serial /dev/ttyUSB0 9600 8N1; echo; devctl_addr tcp 10.0.0.5 4352; echo"
```
Expected now: FAIL (devctl_addr not found).

- [ ] **Step 2: Implement the engine functions**

```bash
# devctl_addr transport a b [c] -> socat address  (serial: dev baud framing | ip: host port)
devctl_addr() {
  case "$1" in
    serial) local fr; fr="$(framing_socat "$4")" || return 1
            printf '%s,b%s,rawer,echo=0,clocal=1,%s,crtscts=0' "$2" "$3" "$fr" ;;
    tcp)    printf 'TCP:%s:%s' "$2" "$3" ;;
    udp)    printf 'UDP:%s:%s' "$2" "$3" ;;
    *)      return 1 ;;
  esac
}

# devctl_pipe fmt payload eol timeout addr  — streamed emit|socat; run UNDER page (ascii reply).
# -T<N> = inactivity/read timeout (send, then read reply up to N s, exit). -t0 = drain on EOF.
devctl_pipe() {
  devctl_emit "$1" "$2" "$3" | socat -T"$4" -t0 - "$5"
}

# devctl_send transport addr fmt payload eol timeout
# ascii -> page (text, capture-safe). hex -> tmpfile + xxd (binary reply, NUL-safe).
devctl_send() {
  local fmt="$3" payload="$4" eol="$5" to="$6" addr="$2"
  if [ "$fmt" = hex ]; then
    local tmpf; tmpf="$(mktemp)"
    devctl_emit "$fmt" "$payload" "$eol" | socat -T"$to" -t0 - "$addr" >"$tmpf" 2>/dev/null
    if [ -s "$tmpf" ]; then page xxd "$tmpf"
    else clear; echo "No reply bytes (device may be write-only, or check wiring/addr)."; pause; fi
    rm -f "$tmpf"
  else
    page devctl_pipe "$fmt" "$payload" "$eol" "$to" "$addr"
  fi
}

# devctl_live transport a b [c]  — interactive session (owns terminal -> run).
devctl_live() {
  case "$1" in
    serial) require tio tio || return
            local ta; read -ra ta <<< "$(framing_tio "$4")"
            run tio "$2" -b "$3" "${ta[@]}" -f none ;;
    tcp)    require ncat ncat || return; run ncat "$2" "$3" ;;
    udp)    require ncat ncat || return; run ncat -u "$2" "$3" ;;
  esac
}
```

- [ ] **Step 3: Run the `devctl_addr` test (green)**

Re-run the Step 1 command. Expected:
```
/dev/ttyUSB0,b9600,rawer,echo=0,clocal=1,cs8,parenb=0,cstopb=0,crtscts=0
TCP:10.0.0.5:4352
```
(The socat/tio/ncat live paths in `devctl_pipe`/`devctl_send`/`devctl_live` are not unit-testable without hardware/peers — covered by the lint gate + manual review; bench-test on the Pi.)

- [ ] **Step 4: Lint gate**

```bash
bash -n netkit && shellcheck -s bash netkit && echo LINT-OK
```
Expected: `LINT-OK`. Note: `read -ra ta <<< "$(framing_tio …)"` is the shellcheck-clean way to expand tio flags (no SC2086 word-split disable needed).

- [ ] **Step 5: Commit**

```bash
git add netkit && git commit -m "feat(devctl): socat send engine + interactive sessions"
```

---

### Task 5: Device CRUD (create / add / remove / delete)

**Files:**
- Modify: `netkit` — append to device-control helpers section.

**Interfaces:**
- Consumes: `load_device`, `devctl_valid_hex`, helpers `ask`/`ask_req`/`ask_num`/`ask_ip`/`menu`/`pause`, global `GW`.
- Produces: `device_new`; `device_add_cmd <name>`; `device_del_cmd <name>`; `device_delete <name>`.

- [ ] **Step 1: Implement the CRUD functions**

(No automated test — all are interactive prompt flows; gate is lint + manual review. `device_del_cmd`'s rewrite logic is exercised manually in Step 2.)

```bash
device_new() {
  local name tr dev baud fr host port to eol fmt
  name="$(ask_req 'Device name (no spaces):' '')" || return
  name="${name// /-}"
  tr="$(menu 'Transport' 'serial|Serial (RS232)' 'tcp|TCP' 'udp|UDP')"; [ -z "$tr" ] && return
  if [ "$tr" = serial ]; then
    dev="$(ask 'Serial device:' '/dev/ttyUSB0')"
    baud="$(ask_num 'Baud:' '9600')" || return
    fr="$(ask 'Framing (8N1/8E1/7E1…):' '8N1')"
  else
    host="$(ask_ip 'Host IP:' "$GW")" || return
    port="$(ask_num 'Port:' '4998')" || return
  fi
  to="$(ask_num 'Read timeout (s):' '2')" || return
  eol="$(menu 'Default line ending' 'cr|CR' 'lf|LF' 'crlf|CRLF' 'none|none')"; [ -z "$eol" ] && eol=cr
  fmt="$(menu 'Default command format' 'ascii|ASCII text' 'hex|Hex bytes')"; [ -z "$fmt" ] && fmt=ascii
  mkdir -p "$device_dir"
  local f="$device_dir/$name.conf"
  {
    echo "# netkit device profile: $name"
    echo "TRANSPORT=$tr"
    echo "DEV=${dev:-}"; echo "BAUD=${baud:-}"; echo "FRAMING=${fr:-}"
    echo "HOST=${host:-}"; echo "PORT=${port:-}"
    echo "READ_TIMEOUT=$to"; echo "EOL=$eol"; echo "FORMAT=$fmt"
  } > "$f"
  clear; echo "Created device: $name"; echo; cat "$f"; pause
}

device_add_cmd() {
  local name="$1" label fmt payload eol
  label="$(ask_req 'Command label:' '')" || return
  case "$label" in *'|'*) clear; echo "Label cannot contain '|'."; pause; return ;; esac
  fmt="$(menu 'Format' 'ascii|ASCII text' 'hex|Hex bytes')"; [ -z "$fmt" ] && return
  payload="$(ask_req 'Payload:' "${DEV_FORMAT:+}")" || return
  case "$payload" in *'|'*) clear; echo "Payload cannot contain '|'."; pause; return ;; esac
  if [ "$fmt" = hex ] && ! devctl_valid_hex "$payload"; then
    clear; echo "Invalid hex (need an even count of hex digits)."; pause; return
  fi
  eol="$(menu 'Line ending' 'cr|CR' 'lf|LF' 'crlf|CRLF' 'none|none')"; [ -z "$eol" ] && eol="${DEV_EOL:-none}"
  printf 'CMD=%s|%s|%s|%s\n' "$label" "$fmt" "$payload" "$eol" >> "$device_dir/$name.conf"
  clear; echo "Added command: $label"; pause
}

device_del_cmd() {
  local name="$1"; load_device "$name" || { clear; echo "No such device."; pause; return; }
  [ "${#DEV_CMD_LABEL[@]}" -gt 0 ] || { clear; echo "No commands to remove."; pause; return; }
  local pairs=() i
  for i in "${!DEV_CMD_LABEL[@]}"; do pairs+=("$i|${DEV_CMD_LABEL[$i]}"); done
  local sel; sel="$(menu 'Remove which command?' "${pairs[@]}")"; [ -z "$sel" ] && return
  local f="$device_dir/$name.conf" tmpf; tmpf="$(mktemp)"
  grep -v '^CMD=' "$f" > "$tmpf"
  for i in "${!DEV_CMD_LABEL[@]}"; do
    [ "$i" = "$sel" ] && continue
    printf 'CMD=%s|%s|%s|%s\n' "${DEV_CMD_LABEL[$i]}" "${DEV_CMD_FMT[$i]}" \
      "${DEV_CMD_PAYLOAD[$i]}" "${DEV_CMD_EOL[$i]}" >> "$tmpf"
  done
  mv "$tmpf" "$f"
  clear; echo "Removed."; pause
}

device_delete() {
  local a; a="$(ask "Delete device '$1'? (y/N):" "N")"
  case "$a" in y|Y|yes|YES) rm -f "$device_dir/$1.conf"; clear; echo "Deleted $1."; pause ;;
               *) clear; echo "Cancelled."; pause ;; esac
}
```

- [ ] **Step 2: Manual rewrite sanity check for `device_del_cmd`**

```bash
mkdir -p /tmp/nkdev2 && cat > /tmp/nkdev2/x.conf <<'EOF'
# netkit device profile: x
TRANSPORT=tcp
HOST=1.2.3.4
PORT=23
CMD=A|ascii|aaa|cr
CMD=B|ascii|bbb|cr
CMD=C|ascii|ccc|cr
EOF
bash -c "$(awk '/^load_device\(\) \{/,/^\}/' netkit)
device_dir=/tmp/nkdev2
DEV_NAME=; DEV_TRANSPORT=; DEV_DEV=; DEV_BAUD=; DEV_FRAMING=; DEV_HOST=; DEV_PORT=; DEV_READ_TIMEOUT=; DEV_EOL=; DEV_FORMAT=
DEV_CMD_LABEL=(); DEV_CMD_FMT=(); DEV_CMD_PAYLOAD=(); DEV_CMD_EOL=()
load_device x
# simulate removing index 1 (B): rebuild like device_del_cmd does
tmpf=\$(mktemp); grep -v '^CMD=' /tmp/nkdev2/x.conf > \$tmpf
for i in \"\${!DEV_CMD_LABEL[@]}\"; do [ \"\$i\" = 1 ] && continue
  printf 'CMD=%s|%s|%s|%s\n' \"\${DEV_CMD_LABEL[\$i]}\" \"\${DEV_CMD_FMT[\$i]}\" \"\${DEV_CMD_PAYLOAD[\$i]}\" \"\${DEV_CMD_EOL[\$i]}\"; done >> \$tmpf
grep '^CMD=' \$tmpf; rm -f \$tmpf"
```
Expected (B removed, A and C remain):
```
CMD=A|ascii|aaa|cr
CMD=C|ascii|ccc|cr
```
Cleanup: `rm -rf /tmp/nkdev2`

- [ ] **Step 3: Lint gate**

```bash
bash -n netkit && shellcheck -s bash netkit && echo LINT-OK
```
Expected: `LINT-OK`

- [ ] **Step 4: Commit**

```bash
git add netkit && git commit -m "feat(devctl): device profile CRUD"
```

---

### Task 6: PJLink probe

**Files:**
- Modify: `netkit` — append to device-control helpers section.

**Interfaces:**
- Consumes: `require`, `ask_ip`, `pause`, global `GW`, `NETKIT_LAST_OUTPUT`, `socat`.
- Produces: `pjlink_probe` (TCP 4352; skips the `PJLINK 0` greeting; detects `PJLINK 1` auth and reports unsupported).

- [ ] **Step 1: Implement `pjlink_probe`**

(Live behaviour needs a projector — gate is lint + manual review. The greeting-detection branch is reasoned through in Step 2.)

```bash
pjlink_probe() {
  require socat socat || return
  local host; host="$(ask_ip 'Projector IP:' "$GW")" || return
  # The projector emits a greeting line on connect BEFORE accepting a command:
  #   "PJLINK 0"           -> no auth
  #   "PJLINK 1 <nonce>"   -> auth required (unsupported in v1)
  local greet
  greet="$(printf '' | socat -T2 -t0 - TCP:"$host":4352 2>/dev/null | head -n1)"
  if [ -z "$greet" ]; then
    clear; echo "No response from $host:4352 (not a PJLink device, or unreachable)."; pause; return
  fi
  case "$greet" in
    "PJLINK 1"*) clear; echo "Projector requires PJLink authentication — not supported in v1."; pause; return ;;
  esac
  local q line out=""
  for q in POWR INPT AVMT LAMP NAME INF1 CLSS; do
    # Each query is its own connection; grep '^%1' drops the greeting, keeps the response.
    line="$({ sleep 0.2; printf '%%1%s ?\r' "$q"; } | socat -T2 -t0 - TCP:"$host":4352 2>/dev/null | grep '^%1' | head -n1)"
    out="$out$(printf '%-5s %s' "$q" "${line:-<no reply>}")"$'\n'
  done
  NETKIT_LAST_OUTPUT="$out"
  clear
  printf 'PJLink probe — %s (TCP 4352)\n------------------------------------------\n%s' "$host" "$out"
  pause
}
```

- [ ] **Step 2: Reason-check the greeting handling**

Confirm by reading the code: (a) the initial empty-send reads only the greeting (`head -n1`); (b) `PJLINK 1` short-circuits with the auth message; (c) per-query, `grep '^%1'` excludes the `PJLINK 0` greeting (which starts with `P`, not `%`) and keeps the `%1POWR=…` response. No code change expected.

- [ ] **Step 3: Lint gate**

```bash
bash -n netkit && shellcheck -s bash netkit && echo LINT-OK
```
Expected: `LINT-OK`

- [ ] **Step 4: Commit**

```bash
git add netkit && git commit -m "feat(devctl): PJLink projector probe (greeting-aware)"
```

---

### Task 7: Menus + ad-hoc actions + main-loop wiring

**Files:**
- Modify: `netkit` — append menu functions to device-control helpers section; edit the main `while` category menu + dispatch; edit `show_help`.

**Interfaces:**
- Consumes: everything from Tasks 1–6.
- Produces: `devctl_send_adhoc`, `devctl_live_adhoc`, `device_fire <name>`, `device_actions <name>`, `device_pick`, `m_devctl`; new `devctl` branch in the main loop.

- [ ] **Step 1: Implement the ad-hoc + saved-device + menu functions**

```bash
devctl_send_adhoc() {
  require socat socat || return
  local tr; tr="$(menu 'Transport' 'serial|Serial' 'tcp|TCP' 'udp|UDP')"; [ -z "$tr" ] && return
  local addr fmt payload eol to dev baud fr host port
  if [ "$tr" = serial ]; then
    dev="$(ask 'Serial device:' '/dev/ttyUSB0')"
    [ -e "$dev" ] || { clear; echo "No such device: $dev"; pause; return; }
    baud="$(ask_num 'Baud:' '9600')" || return
    fr="$(ask 'Framing:' '8N1')"
    addr="$(devctl_addr serial "$dev" "$baud" "$fr")" || { clear; echo "Bad framing: $fr"; pause; return; }
  else
    host="$(ask_ip 'Host:' "$GW")" || return
    port="$(ask_num 'Port:' '4998')" || return
    addr="$(devctl_addr "$tr" "$host" "$port")"
  fi
  fmt="$(menu 'Format' 'ascii|ASCII text' 'hex|Hex bytes')"; [ -z "$fmt" ] && return
  payload="$(ask_req 'Command:' '')" || return
  if [ "$fmt" = hex ] && ! devctl_valid_hex "$payload"; then clear; echo "Invalid hex."; pause; return; fi
  eol="$(menu 'Line ending' 'cr|CR' 'lf|LF' 'crlf|CRLF' 'none|none')"; [ -z "$eol" ] && eol=none
  to="$(ask_num 'Read timeout (s):' '2')" || return
  devctl_send "$tr" "$addr" "$fmt" "$payload" "$eol" "$to"
}

devctl_live_adhoc() {
  local tr; tr="$(menu 'Transport' 'serial|Serial' 'tcp|TCP' 'udp|UDP')"; [ -z "$tr" ] && return
  local dev baud fr host port
  if [ "$tr" = serial ]; then
    dev="$(ask 'Serial device:' '/dev/ttyUSB0')"
    [ -e "$dev" ] || { clear; echo "No such device: $dev"; pause; return; }
    baud="$(ask_num 'Baud:' '9600')" || return
    fr="$(ask 'Framing:' '8N1')"
    devctl_live serial "$dev" "$baud" "$fr"
  else
    host="$(ask_ip 'Host:' "$GW")" || return
    port="$(ask_num 'Port:' '4998')" || return
    devctl_live "$tr" "$host" "$port"
  fi
}

device_fire() {  # name; DEV_* already loaded by caller
  [ "${#DEV_CMD_LABEL[@]}" -gt 0 ] || { clear; echo "No commands yet — add one first."; pause; return; }
  local pairs=() i; for i in "${!DEV_CMD_LABEL[@]}"; do pairs+=("$i|${DEV_CMD_LABEL[$i]}"); done
  local sel; sel="$(menu 'Send which command?' "${pairs[@]}")"; [ -z "$sel" ] && return
  local addr to="${DEV_READ_TIMEOUT:-2}"
  if [ "$DEV_TRANSPORT" = serial ]; then
    [ -e "$DEV_DEV" ] || { clear; echo "No such device: $DEV_DEV"; pause; return; }
    addr="$(devctl_addr serial "$DEV_DEV" "$DEV_BAUD" "$DEV_FRAMING")" || { clear; echo "Bad framing."; pause; return; }
  else
    addr="$(devctl_addr "$DEV_TRANSPORT" "$DEV_HOST" "$DEV_PORT")"
  fi
  require socat socat || return
  devctl_send "$DEV_TRANSPORT" "$addr" "${DEV_CMD_FMT[$sel]}" "${DEV_CMD_PAYLOAD[$sel]}" "${DEV_CMD_EOL[$sel]}" "$to"
}

device_actions() {  # name
  load_device "$1" || { clear; echo "Could not load device $1."; pause; return; }
  while true; do
    local k; k="$(menu "🎛 $1 (${DEV_TRANSPORT:-?})" \
      "fire|Send a saved command" \
      "live|Live interactive session" \
      "add|Add a command" \
      "del|Remove a command" \
      "rm|Delete this device" \
      "show|Show profile" \
      "back|‹ back")"
    case "$k" in
      fire) device_fire "$1" ;;
      live) if [ "$DEV_TRANSPORT" = serial ]; then devctl_live serial "$DEV_DEV" "$DEV_BAUD" "$DEV_FRAMING"
            else devctl_live "$DEV_TRANSPORT" "$DEV_HOST" "$DEV_PORT"; fi ;;
      add) device_add_cmd "$1"; load_device "$1" ;;
      del) device_del_cmd "$1"; load_device "$1" ;;
      rm) device_delete "$1"; return ;;
      show) clear; device_show_file "$1"; pause ;;
      *) return ;;
    esac
  done
}

device_pick() {
  local names n pairs=()
  names="$(device_list)"
  [ -z "$names" ] && { clear; echo "No devices yet — use 'Create device profile'."; pause; return; }
  while IFS= read -r n; do [ -n "$n" ] && pairs+=("$n|$n"); done <<< "$names"
  local sel; sel="$(menu 'Select device' "${pairs[@]}")"; [ -z "$sel" ] && return
  device_actions "$sel"
}

m_devctl() {
  local k; k="$(menu '🎛 Device Control' \
    "send|Quick send (ad-hoc) → read reply" \
    "live|Live interactive session" \
    "dev|Saved devices (recall & fire)" \
    "newdev|Create device profile" \
    "pjlink|PJLink projector probe (TCP 4352)" \
    "back|‹ back")"
  case "$k" in
    send) devctl_send_adhoc ;;
    live) devctl_live_adhoc ;;
    dev) device_pick ;;
    newdev) device_new ;;
    pjlink) pjlink_probe ;;
    *) return ;;
  esac
}
```

- [ ] **Step 2: Wire into the main category menu**

In the main `while true` loop's `menu "Pick a category" …`, add this line immediately after the `"lldp|🔌 Switch Port (LLDP / SNMP)"` line:

```bash
    "devctl|🎛 Device Control (RS232 / IP)" \
```

And in that loop's `case "$k" in` dispatch, add immediately after the `lldp) m_lldp ;;` line:

```bash
    devctl) m_devctl ;;
```

- [ ] **Step 3: Add a help entry**

In `show_help`, in the `CATEGORIES` block, add after the `LLDP/SNMP …` line:

```
  DevCtrl      RS232/TCP/UDP send+read, live session, saved devices, PJLink
```

- [ ] **Step 4: Lint gate**

```bash
bash -n netkit && shellcheck -s bash netkit && echo LINT-OK
```
Expected: `LINT-OK`

- [ ] **Step 5: Smoke-check the menu renders (no hardware needed)**

```bash
printf '\n' | NO_COLOR=1 bash netkit >/tmp/nk.out 2>&1 &
sleep 1; kill %1 2>/dev/null; grep -c 'Device Control' /tmp/nk.out; rm -f /tmp/nk.out
```
Expected: a non-zero count (the category label appears). If gum isn't installed locally this may differ — the lint gate is the authority; verify the menu on the Pi.

- [ ] **Step 6: Commit**

```bash
git add netkit && git commit -m "feat(devctl): menus, ad-hoc actions, main-loop wiring"
```

---

### Task 8: Setup / selftest integration

**Files:**
- Modify: `netkit` — `do_setup` (pkgs array + dialout step), `do_selftest` (extras list).

**Interfaces:**
- Consumes: existing `do_setup`/`do_selftest` structure.
- Produces: `tio`, `xxd` installed by setup; `$USER` added to `dialout`; selftest reports the three tools.

- [ ] **Step 1: Add `tio` and `xxd` to the setup package list**

In `do_setup`, change the `pkgs` array assignment from:

```bash
  local pkgs=(mosquitto-clients ethtool snmp fping ipcalc wakeonlan unzip
              bluez bluez-tools rtl-433 rtl-sdr swaks)
```
to:
```bash
  local pkgs=(mosquitto-clients ethtool snmp fping ipcalc wakeonlan unzip
              bluez bluez-tools rtl-433 rtl-sdr swaks tio xxd)
```

- [ ] **Step 2: Add the dialout group step**

In `do_setup`, immediately after the existing `bluetooth` group block (the `if getent group bluetooth …` block ending with its `fi`), add:

```bash
  if getent group dialout >/dev/null 2>&1; then
    sudo usermod -aG dialout "$USER" 2>/dev/null \
      && ok "added $USER to 'dialout' group (serial port access)"
    echo "    (log out/in, or run 'newgrp dialout', for serial access to take effect)"
  fi
```

- [ ] **Step 3: Add the tools to selftest**

In `do_selftest`, change the `extras` array from:

```bash
  local x extras=(gping bandwhich xh librespeed-cli mosquitto_sub ethtool snmpwalk fping
                  ipcalc wakeonlan bluetoothctl btmon rtl_433 rtl_power swaks
                  omping ptp4l rdisc6)
```
to (append `tio socat xxd`):
```bash
  local x extras=(gping bandwhich xh librespeed-cli mosquitto_sub ethtool snmpwalk fping
                  ipcalc wakeonlan bluetoothctl btmon rtl_433 rtl_power swaks
                  omping ptp4l rdisc6 tio socat xxd)
```

- [ ] **Step 4: Lint gate**

```bash
bash -n netkit && shellcheck -s bash netkit && echo LINT-OK
```
Expected: `LINT-OK`

- [ ] **Step 5: Verify the version-string + usage still parse and bump version**

Bump `NETKIT_VERSION="4.1.1"` to `NETKIT_VERSION="4.2.0"` (new feature, minor bump), then:
```bash
bash netkit version
```
Expected: `netkit v4.2.0`

- [ ] **Step 6: Commit**

```bash
git add netkit && git commit -m "feat(devctl): setup installs tio+xxd, dialout group, selftest; v4.2.0"
```

---

### Task 9: README documentation

**Files:**
- Modify: `README.md` — version line, command/category tables, dependencies, caveats.

**Interfaces:** none (docs only).

- [ ] **Step 1: Update the version + dashboard-categories table**

Change `**Current version: 4.1.1**` to `**Current version: 4.2.0**`.

In the "Dashboard categories" table, add a row after the LLDP/SNMP row:

```
| 🎛 Device Control | RS232/TCP/UDP send+read (ASCII/hex), live interactive session (tio/ncat), per-device saved command library, PJLink projector probe |
```

- [ ] **Step 2: Update the dependencies section**

In the "**apt (core extras):**" list, add `tio xxd` to the enumerated packages, and note in prose: "`tio` (interactive serial terminal) and `xxd` (hex encode / binary reply display) back the Device Control category; `socat`/`ncat` (already present) drive send+read and interactive IP."

- [ ] **Step 3: Add a caveat**

In "Caveats / known limitations", add:
```
- **Device Control** needs a USB-serial adapter for RS232 (user must be in the
  `dialout` group — `netkit setup` adds you; re-login or `newgrp dialout`). PJLink
  probe is v1 unauthenticated-only. Binary (hex) replies are shown via `xxd`.
```

- [ ] **Step 4: Verify markdown + commit**

```bash
git add README.md && git commit -m "docs: document Device Control category (v4.2.0)"
```

---

## Self-Review

**Spec coverage** (each spec §, mapped to a task):
- §4.1 top menu → Task 7 (`m_devctl`). §4.2 device action menu → Task 7 (`device_actions`).
- §4.3 byte-streaming engine → Task 2 (`devctl_emit`) + Task 4 (`devctl_pipe`/`devctl_send`). §4.4 text-vs-binary reply → Task 4 (`devctl_send`).
- §4.5 address builder + framing → Task 1 (`framing_*`) + Task 4 (`devctl_addr`). §4.6 interactive → Task 4 (`devctl_live`) + Task 7 (ad-hoc/saved). §4.7 PJLink → Task 6.
- §5 saved library → Task 3 (parser/list) + Task 5 (CRUD). §6 integration → Task 7 (menus/main loop) + Task 8 (setup/selftest). §7 error handling → distributed (hex validation Task 2/5, `[ -e ]` checks Task 7, `|` rejection Task 5, PJLink auth Task 6). §8 shellcheck/`set -u` → lint gate every task + count-guarded array expansions. §9 deps → Task 8. §10 verification → lint gate + pure-function tests throughout.

No gaps.

**Placeholder scan:** No TBD/TODO/"handle errors"/"similar to" — every code step contains complete code; every test step contains an exact command + expected output.

**Type/name consistency:** `framing_socat`/`framing_tio` (Task 1) consumed by `devctl_addr`/`devctl_live` (Task 4). `devctl_emit` (Task 2) consumed by `devctl_pipe`/`devctl_send` (Task 4). `load_device` + `DEV_CMD_*` arrays (Task 3) consumed by `device_fire`/`device_del_cmd`/`device_actions` (Tasks 5, 7). `devctl_addr` arity (serial: dev/baud/framing; tcp/udp: host/port) consistent across `devctl_send_adhoc`/`device_fire`. `device_show_file` (Task 3) used by `device_actions` (Task 7). All names align.
