# netkit `🎛 Device Control` — Design Spec

- **Date:** 2026-06-22
- **Status:** Approved (pending implementation plan)
- **Target:** `netkit` (single bash script), Raspberry Pi 5 handheld, Raspberry Pi OS Bookworm, aarch64
- **Author:** brainstormed with the maintainer; tool APIs validated by a senior-engineer review (web-sourced, see §10)

## 1. Purpose

Add an RS232 + IP device-control category to netkit so the Pi handheld doubles as
a field bench for testing and building control commands against AV gear
(Crestron / Control4 / Savant integrator workflows). Covers serial (RS232) and IP
(TCP/UDP) transports, one-shot send-and-read **and** live interactive sessions, a
per-device saved command library, and a one-tap PJLink projector probe.

## 2. Scope

**In scope (v1):**
- Transports: serial, TCP, UDP.
- One-shot **send command → read reply**, captured into netkit reports.
- **Live interactive** session per transport.
- **Saved device library**: per-device profiles with named commands (ASCII or hex,
  selectable line terminator).
- **PJLink probe**: unauthenticated (auth-disabled) class-1 projectors, TCP 4352.

**Out of scope (v1) — deferrable without reworking the core:**
- PJLink password authentication.
- Scripted multi-command macros / sequences.
- Automatic checksum calculation.
- Protocol auto-detection.
- Sending commands that contain NUL **via the saved library's `|`-delimited
  storage** (the live send path streams bytes and *is* NUL-safe; see §4).

## 3. Hard constraints inherited from the project

- `set -uo pipefail` (no `-e`). **Every new global initialised** in the global
  block so `set -u` is satisfied.
- Runs as the normal user; `sudo` only where needed. Never run the whole script as root.
- **apt-first**, aarch64 Bookworm packages; never compile on the Pi.
- Optional tools gated behind `require <cmd> <pkg>`; degrade cleanly.
- `bash -n netkit` **and** `shellcheck -s bash netkit` must produce **zero output**.
- Helper discipline: `run`/`runsh` wrap interactive/streaming commands that own the
  terminal; `page` wraps **batch** output only (it captures stdout+stderr into a
  shell variable → **must not** wrap a TUI, and **mangles binary/NUL output**).

## 4. Architecture

A new category function `m_devctl` plus focused helpers, all built from the existing
vocabulary (`menu`, `ask*`, `require`, `run`, `page`). Wired into the main loop and
`show_help`.

### 4.1 Top menu (`m_devctl`)
- `send`   — Quick send (ad-hoc) → read reply
- `live`   — Live interactive session
- `dev`    — Saved devices (recall & fire commands)
- `newdev` — Create device profile
- `pjlink` — PJLink projector probe (TCP 4352)
- `back`

### 4.2 Saved-device action menu (after selecting a device)
- fire any saved command (captured)
- live interactive session to this device
- add a command
- remove a command / delete device
- show profile
- back

### 4.3 Byte-streaming send engine (NUL-safe)

Encoded bytes **stream directly into the pipe** — never through `$(…)`, which
silently drops NUL bytes.

```bash
devctl_emit() {   # $1=format  $2=payload  $3=eol  → raw bytes on STDOUT
  case "$1" in
    ascii) printf '%s' "$2" ;;                                   # %s, NOT %b
    hex)   printf '%s' "$2" | tr -d ' ' | sed 's/0[xX]//g' | xxd -r -p ;;
  esac
  case "$3" in cr) printf '\r';; lf) printf '\n';; crlf) printf '\r\n';; esac
}
```

- **ASCII** uses `%s` (not `%b`) so literal backslashes in user text are not expanded.
- **Hex** uses `xxd -r -p`, which correctly emits arbitrary bytes incl. `00`.
- **EOL** bytes appended explicitly (`none`/`cr`/`lf`/`crlf`).

One-shot send + read (corrected socat timeout flags):

```bash
devctl_emit "$fmt" "$payload" "$eol" | socat -T"$timeout" -t0 - "$ADDRESS"
```

- `-T<N>` = **inactivity/read timeout** (terminate after N seconds of silence).
  This is the correct flag for "send, then read reply for up to N s, exit" and is
  essential for UDP (no EOF) and serial. (The naive `-t<N>` is only the EOF-drain
  delay and would hang on a device that never closes.)
- `-t0` = drain immediately once EOF *does* arrive.
- Default `$timeout` = 2s (per-device `READ_TIMEOUT`, or `ask_num`).

### 4.4 Reply display — text vs binary

`page` captures into a shell variable, so it corrupts binary replies. Reply view
**follows the command's format**:

- **ascii command → text reply:** `page bash -c '<emit> | socat …'` — safe and
  capturable to reports.
- **hex command → binary reply:** stream socat output to a tmpfile, then
  `page xxd "$tmpf"` (xxd output is ASCII → pages and captures cleanly); `rm -f` the
  tmpfile afterward. Never capture raw binary into a variable.

### 4.5 Address builder + framing

Serial socat address, 8N1 example — **all boolean options explicit `=0`/`=1`**,
`rawer` (not obsolete `raw`):

```
/dev/ttyUSB0,b9600,rawer,echo=0,clocal=1,cs8,parenb=0,cstopb=0,crtscts=0
```

Bare option names only *enable* a flag, leaving the "no parity / 1 stop bit" case in
an undefined prior state — so the parser always emits the explicit disabled form.

`framing_socat` / `framing_tio` parse an `8N1`-style string into the full option set:

| Framing | socat options                          | tio flags            |
|---------|----------------------------------------|----------------------|
| 8N1     | `cs8,parenb=0,cstopb=0`                 | `-d 8 -p none -s 1`  |
| 8E1     | `cs8,parenb=1,parodd=0,cstopb=0`        | `-d 8 -p even -s 1`  |
| 8O1     | `cs8,parenb=1,parodd=1,cstopb=0`        | `-d 8 -p odd  -s 1`  |
| 8N2     | `cs8,parenb=0,cstopb=1`                 | `-d 8 -p none -s 2`  |
| 7E1     | `cs7,parenb=1,parodd=0,cstopb=0`        | `-d 7 -p even -s 1`  |
| 7O1     | `cs7,parenb=1,parodd=1,cstopb=0`        | `-d 7 -p odd  -s 1`  |
| 7N1     | `cs7,parenb=0,cstopb=0`                 | `-d 7 -p none -s 1`  |

(Serial addresses always also carry `b<baud>,rawer,echo=0,clocal=1,crtscts=0`.)
TCP address: `TCP:host:port`. UDP address: `UDP:host:port`.

### 4.6 Interactive sessions

Own the terminal → wrapped in `run`, never `page`:

- **serial:** `require tio tio || return; run tio "$dev" -b "$baud" -d D -p PARITY -s STOP -f none`
  (tio 2.5, the Bookworm aarch64 version; flags confirmed).
- **TCP:** `run ncat "$host" "$port"`
- **UDP:** `run ncat -u "$host" "$port"`

No `socat READLINE` fallback — readline is disabled in Debian's socat build, so it
cannot work. `tio` is installed by `netkit setup`; if the user declines, the action
bails cleanly via `require`. (`microcom` noted as an optional manual alternative; not
wired in.)

### 4.7 PJLink probe

On TCP connect the projector first emits a greeting line (`PJLINK 0\r`, or
`PJLINK 1 <nonce>\r` when auth is enabled) **before** accepting a command — it
precedes the reply on every connection and must not be mistaken for the response.
The mandatory space before `?` is preserved. Per-query, **one connection** — the
conservative choice that works whether or not the projector keeps the session open
(some gear accepts only one command per connection):

```bash
raw="$({ sleep 0.2; printf '%%1POWR ?\r'; } | socat -T2 -t0 - TCP:"$host":4352)"
printf '%s\n' "$raw" | tr '\r' '\n' | grep '^%1' | head -n1
```

Two correctness details learned in review/verification, baked into the
implementation:

- **CR line endings.** PJLink terminates lines with `\r`, not `\n`, so the whole
  reply is a single `\n`-line beginning `PJLINK …` — `grep '^%1'` would never match.
  Translate `\r`→`\n` (`tr '\r' '\n'`) before `grep`.
- **No separate greeting probe.** Auth is detected **inline on the first query's raw
  output** (`case "$raw" in *"PJLINK 1"*) …`) rather than opening an extra
  send-nothing connection. One fewer connection, and avoids projectors that error on
  a command-less session.

Loop a small class-1 query set — `POWR INPT AVMT LAMP NAME INF1 CLSS` — accumulate
output, `page` the result. **v1 handles unauthenticated (auth-disabled) projectors
only**; an authenticated greeting (`PJLINK 1 …`) is detected on the first query and
reported as "auth required — not supported in v1."

## 5. Saved device library

Mirror the site-profile security model: per-device file, **whitelist line-parsed,
never sourced**.

- Dir: `~/.config/netkit/devices/`, one `<name>.conf` per device.

```
# netkit device profile: <name>
TRANSPORT=serial            # serial | tcp | udp
DEV=/dev/ttyUSB0            # serial
BAUD=9600
FRAMING=8N1
HOST=                       # tcp/udp
PORT=
READ_TIMEOUT=2
EOL=cr                      # device default terminator
FORMAT=ascii                # device default command format
CMD=Power On|ascii|PWR ON|cr
CMD=Input HDMI1|hex|02 01 00 01|none
```

- `load_device <name>` — whitelist line parser like `load_site`. Header keys →
  `DEV_*` globals; repeated `CMD=` lines → parallel arrays
  `DEV_CMD_LABEL[] DEV_CMD_FMT[] DEV_CMD_PAYLOAD[] DEV_CMD_EOL[]`.
- `|` is the field delimiter; `|` is **rejected in label/payload on input**.
- CRUD helpers: `device_new`, `device_add_cmd`, `device_del_cmd` (rewrite file
  without the chosen line), `device_delete`, `device_show`.
- EOL/FORMAT stored per command (self-contained); device-level `EOL`/`FORMAT` used as
  prompt prefills when adding a command.

## 6. Integration points (existing script)

- **Main loop + `show_help`:** add the `🎛 Device Control` category line + dispatch.
- **`do_setup`:** `pkgs += (tio xxd)`; add `sudo usermod -aG dialout "$USER"` (correct
  group for `/dev/ttyUSB*` and `/dev/ttyACM*`); **print a re-login / `newgrp dialout`
  note** so the group change takes effect. (`socat`, `ncat` already assumed present.)
- **`do_selftest`:** extras list `+= (tio socat xxd)`.
- **Global block (~line 93):** initialise all new `DEV_*` scalars and arrays empty.

## 7. Error handling

- Cancelled/empty prompts abort cleanly (`ask_req` / `ask_num` semantics).
- Bad hex (odd length / non-hex chars) → `warn` + reprompt; never reaches the wire.
- Missing serial path validated with `[ -e "$DEV" ]` before building the address.
- `|` in a label/payload rejected on input.
- No device files yet → friendly "create one" message.
- socat/tio/ncat exit codes surfaced to the user.
- Authenticated PJLink greeting → reported as unsupported, not a silent wrong answer.

## 8. shellcheck / `set -u` discipline

- All boolean socat options explicit (`=0`/`=1`).
- All array expansions double-quoted (`"${arr[@]}"`, `"${arr[$i]}"`).
- New globals + arrays initialised in the global block; index access bounds-checked.
- `devctl_emit` streams to stdout — encoded bytes are **never** stored in a variable,
  so NULs survive to the wire and command substitution can't mangle them.
- ASCII payloads sent with `%s`, not `%b` (no accidental escape expansion).
- Validate device-path / host input before composing socat address strings (a stray
  comma/colon would break socat option parsing).

## 9. New dependencies

| Tool   | apt package | Why                                  | Notes                         |
|--------|-------------|--------------------------------------|-------------------------------|
| `tio`  | `tio`       | interactive serial (live hex, reconnect) | Bookworm 2.5-1, aarch64 ✓ |
| `xxd`  | `xxd`       | hex→bytes encode, binary reply display   | tiny, apt ✓                |

`socat` and `ncat` are already part of netkit's assumed base toolset.

## 10. Verification

- `bash -n netkit` → zero output.
- `shellcheck -s bash netkit` → zero output (targeted `# shellcheck disable` only with
  a justifying comment).
- **Honest caveat:** linted, **not** run on aarch64 hardware. Bench-test on the Pi
  with a USB-FTDI dongle + a real device (and a TCP/UDP-controllable device or the
  PJLink target) before a client site. On-Pi checks: `netkit selftest` (tools present)
  and a live send to a known device.

## 11. Source citations (tool-API validation)

- socat timeout (`-T` vs `-t`) + serial options: socat(1), Debian Bookworm manpage.
- `tio` 2.5 flags + Bookworm aarch64 availability: tio(1) Bookworm manpage, tio GitHub.
- `ncat` package + interactive flags: ncat(1) Bookworm manpage.
- PJLink class-1 wire format, greeting line, port 4352: PJLink spec v1.04.
- bash NUL-in-`$(…)` drop: GNU bash mailing-list threads.
- `dialout` group for `/dev/ttyUSB*` on Raspberry Pi OS: RPi forums / hardware-permissions guides.
