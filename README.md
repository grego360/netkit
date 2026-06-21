# netkit

A single-file terminal **network testing / inspection / reporting** tool for a
Raspberry Pi 5 handheld, used on-site for network + AV installs, UniFi sites,
link/throughput testing, switch-port identification, and client reports.

The whole app is one bash script: [`netkit`](./netkit). There is no package,
no build step, and no dependencies *inside* the script — "installing" it means
copying that one file to `/usr/local/bin/netkit` and marking it executable.
The tools it drives (nmap, iperf3, snmpwalk, …) are installed separately by
`netkit setup`.

**Current version: 4.1.0**

---

## ⭐ For Claude Code — read this first

- **`netkit` (the script) is the source of truth.** Read it for current
  behaviour, categories, and helpers before changing anything. This README is
  durable context, not a spec; if they disagree, the script wins.
- **Every change must pass both** `bash -n netkit` **and** `shellcheck -s bash netkit`
  **with zero output.** Verify before delivering and say it's been linted.
  Targeted `# shellcheck disable=SCxxxx` is allowed only for genuinely
  intentional cases, with a comment saying why.
- **`set -uo pipefail`** (no `-e`). All new globals must be initialised so
  `set -u` is satisfied.
- **apt-first.** Use Debian packages where they exist for aarch64. Only use
  third-party repos (Charm) or prebuilt GitHub binaries where apt has no good
  package. **Never compile on the Pi.**
- **Runs as the normal user**, calling `sudo` only where needed (raw sockets,
  systemd, setcap). Never require running the whole script as root.
- **Verify, don't assume.** Web-search to confirm package names, release-asset
  naming, and tool flags before depending on them. Asset naming drifts per
  project (this is what broke the `gping` matcher once); `netkit doctor` exists
  to catch that proactively.
- **Prefer a single self-contained deliverable** per change.
- **Be honest about caveats** — especially "linted but not run on real aarch64
  hardware; bench-test before a client site."
- This is a **bash** project. The maintainer also writes SwiftUI / React /
  Next.js, but those conventions do not apply here.

### Script conventions (helpers)
- `have <cmd>` — is a command available
- `require <cmd> [hint]` — guard for an optional tool: if missing, offers to run
  `netkit setup` on the spot, then proceeds if it got installed. Use
  `require X "<pkg>" || return` instead of hand-rolled "not installed" messages.
- `menu [--filter] "Header" "key|Label" …` — gum-backed chooser, returns the chosen
  key. `--filter` switches to type-to-filter (`gum filter`) for long menus.
- `ask <prompt> <default>` / `ask_req …` (aborts on empty) / `ask_pw <prompt>` (hidden)
- `ask_num` / `ask_ip` / `ask_cidr` — validating prompts (loop until valid or cancelled)
- `pause` — "Enter to return"
- `run <cmd> …` — clears, echoes `$ …`, runs `"$@"`, pauses. **Do not pipe/tee
  interactive TUIs through this** — it would corrupt them.
- `runsh "<string>"` — same but via `bash -c` (for shell syntax / filters)
- `page <cmd> …` — like `run` but captures finite output and shows it through a pager
  when it overflows the screen. **Batch commands only** — never an interactive TUI
  (it captures stdout/stderr). Retains output for Reporting → "Save last output".
- `spin "<title>" <cmd> …` — `gum spin` progress wrapper for slow, output-hidden steps
  (used by `setup` / binary downloads).
- `say` / `ok` / `warn` / `bad` — status output
- `need_iface` — guard for actions needing a live interface
- Optional tools are always gated behind `have …` / `require …` and degrade gracefully.
- Colour comes from one palette (`C_OK/C_WARN/C_ERR/C_HDR/C_RST`) that honours
  `NO_COLOR` and a non-tty stdout. `Ctrl-C` stops the running check and returns to the
  menu rather than quitting netkit.

---

## Environment (assume this; don't re-ask)

- **Device:** Raspberry Pi 5 handheld, Raspberry Pi OS Bookworm, 64-bit (aarch64).
- **Access:** Pi user `terminosa`, reached via SSH from a Mac (user `moonshaper`)
  or directly. Small screen — keep output concise.
- **Layout:** `netkit` at `/usr/local/bin/netkit`; config at
  `~/.config/netkit/`; reports under `~/netkit-reports/`.
- **Connectivity:** WiFi (`wlan0`) and/or wired (`eth0`); netkit re-detects the
  active interface each launch.
- **Status bar:** shows iface / IP / gateway / WiFi / active site, plus a
  `bat: NN%` readout when a UPS/HAT exposes a battery via `/sys/class/power_supply`.

---

## Install (first time)

netkit lives in this folder. Get it onto the Pi, then install its tools.

### Method A — direct `scp` (preferred)

Keep this folder **outside** `~/Downloads`, `~/Desktop`, `~/Documents` (macOS
TCC blocks Terminal from reading those — see Deployment quirk below). From here:

```bash
scp netkit terminosa@<pi-ip>:/tmp/netkit
ssh terminosa@<pi-ip> 'sudo install -m 0755 /tmp/netkit /usr/local/bin/netkit && head -1 /usr/local/bin/netkit'
```

`head -1` must print `#!/usr/bin/env bash`. Land in `/tmp` first because
`/usr/local/bin` needs root and `scp` connects as a normal user; `sudo install`
then moves it into place and sets the executable bit in one step.

### Method B — gist fallback (when SCP isn't convenient)

Paste the script into a GitHub **secret gist** → open **Raw** → copy that URL → on the Pi:

```bash
curl -fsSL '<RAW_URL>' | sudo tee /usr/local/bin/netkit >/dev/null
sudo chmod +x /usr/local/bin/netkit
head -1 /usr/local/bin/netkit
```

Use the **Raw** URL (`gist.githubusercontent.com/.../raw/...`), not the gist web
page. If `head -1` shows HTML or a tiny line count, you grabbed the web page.

### Then install the tools it drives

```bash
netkit setup        # apt packages + prebuilt aarch64 binaries
netkit selftest     # confirm tools present + gateway/subnet reachable
netkit doctor       # confirm the 4 GitHub binary matchers still resolve
```

---

## Updating

**Push from the Mac** (this folder), simplest while iterating — use the included
[`push-netkit.sh`](./push-netkit.sh):

```bash
./push-netkit.sh                 # deploy to the default Pi (terminosa@10.1.20.176)
./push-netkit.sh user@host       # or override the target
NETKIT_PI=user@host ./push-netkit.sh
```

It lints the script locally first (`bash -n`, plus `shellcheck` if installed), then
`scp`s it to `/tmp`, `sudo install`s it to `/usr/local/bin/netkit`, and prints the
shebang + running version. Equivalent one-liner if you'd rather do it by hand:

```bash
scp netkit terminosa@10.1.20.176:/tmp/netkit
ssh terminosa@10.1.20.176 'sudo install -m 0755 /tmp/netkit /usr/local/bin/netkit && netkit version'
```

**Pull on the Pi** (`netkit update`) is the alternative when you can't easily
SSH in — it re-pulls from a stored Raw gist URL and refuses anything whose first
line isn't the bash shebang:

```bash
netkit update 'https://gist.githubusercontent.com/<user>/<id>/raw/netkit'   # URL remembered after first use
netkit update                                                                # reuse stored URL
```

---

## Commands

```
netkit               interactive dashboard
netkit dash          tiled live view (tmux)
netkit report        markdown site snapshot
netkit sweep         full commissioning sweep → branded report
netkit setup         install/refresh extra deps
netkit selftest      bench check (tools + live network)
netkit doctor        check prebuilt-binary matchers vs GitHub
netkit site [name]   site profiles (prefill prompts per location)
netkit autostart on|off   boot the unit straight into netkit
netkit update [URL]  re-pull this script from a Raw gist URL
netkit uninstall     remove the netkit binary
netkit version       print version
netkit help          usage
```

## Dashboard categories

| Category | What it covers |
|---|---|
| ⚡ Quick checks | Curated one-tap commissioning actions (ping gateway, ARP sweep, nmap ping sweep, LLDP neighbour, self-test, full sweep) |
| 🔍 Discovery | arp-scan, fping, nmap `-sn`/`-sV`, DHCP rogue check, mDNS/Bonjour, AV gear (Dante/NDI/AirPlay/Sonos), IPv6 (neighbours/routers) |
| 🔗 Link & Throughput | iperf3 server/client, **iperf3 PASS/FAIL vs threshold**, WAN speed (librespeed), mtr, ping graph (gping) |
| 📡 WiFi | wavemon, AP scan (nmcli / iw) |
| 🧰 Packet Inspection | termshark, tcpdump, iftop, bandwhich |
| 🌐 DNS / HTTP / Mail | dig, PTR, HTTP headers, port check, SMTP reachability (EHLO) + test send (swaks) |
| 🔌 Switch Port (LLDP / SNMP) | LLDP neighbours; SNMP monitor (system, interface table, live bps, PoE budget, OID walk, subnet scan) — **v2c and v3** |
| 🎚 AV-over-IP | IGMP querier watch, multicast group discovery, joined groups, omping flow test, PTP traffic watch, PTP offset monitor |
| 🏠 Smart Home / IoT | MQTT sub/pub, Wake-on-LAN |
| 📶 Bluetooth / RF | BLE/classic scan, adapter info, btmon, RTL-SDR 433/868 decode, sub-GHz→MQTT, spectrum sweep, RTL-SDR dongle presence test |
| 📊 Reporting | site snapshot, full sweep, save last viewed output, vnstat, asciinema recording |
| ⚙️ System / Network info | interfaces, ethtool, ipcalc, routes, DNS status, tmux dashboard |
| 🏷 Site profile | select / create / show / clear active site |
| ❓ Help / keys | In-app cheat-sheet: navigation keys, category overview, where reports land |

---

## Dependencies

Installed by `netkit setup`. apt-first; prebuilt binaries only where apt lacks a
good aarch64 package.

**apt (core extras):** `mosquitto-clients ethtool snmp fping ipcalc wakeonlan
unzip bluez bluez-tools rtl-433 rtl-sdr swaks`
(plus base tools assumed present: nmap, arp-scan, avahi-utils, iperf3, mtr-tiny,
lldpd, termshark/tshark/tcpdump/iftop, wavemon/iw/network-manager,
dnsutils/curl/ncat/socat, vnstat/pandoc/asciinema, tmux/jq/git, gum + glow).

**apt (best-effort — skipped cleanly if not in the repo):**
`omping linuxptp ndisc6`

**Prebuilt aarch64 GitHub release binaries:** `librespeed-cli gping bandwhich xh`
— resolved by a shared matcher registry (`PREBUILT_*` arrays) used by both
`setup` and `doctor`. If a project renames its release asset, the fix is a
one-line regex update for that tool; netkit falls back to its base tool meanwhile.

---

## Site profiles

`netkit site new` saves per-location defaults so prompts pre-fill instead of
re-typing them each visit.

- Stored at `~/.config/netkit/sites/<name>.conf` as plain `key=value`.
- Active site name in `~/.config/netkit/active-site`; loaded at every launch.
- Fields: `SMTP`, `SMTP_PORT`, `SNMP_COMMUNITY`, `MQTT`, `SPEED_MIN`,
  `DNS_DOMAIN`, `HTTP_URL`, `PEER`, `LOGO`.
- The active site shows in the status bar and routes reports into
  `~/netkit-reports/<site>/<date>/`.
- **Security:** the `.conf` is read by a whitelist `key=value` parser and is
  **never sourced or executed** — a tampered profile can't run commands.

> When no site is active, a few prompts fall back to baked-in client defaults
> (the DNS and HTTP checks prefill `modalav.co.uk`). Set `DNS_DOMAIN` / `HTTP_URL`
> in a site profile, or just type over the default, to use something else.

---

## Reports

Written under `~/netkit-reports/<site>/<date>/` (site = `default` if none active):

- `snapshot-*.md` — quick site snapshot (`netkit report`)
- `sweep-*.md` — full commissioning sweep, optional logo header, PDF-ready
  (`netkit sweep`)
- `captures-*.md` — ad-hoc command output saved on demand (Reporting → "Save last
  output"; only actions that page their output can be captured)
- `session-*.cast` — asciinema recording
- `sweep-*.csv` — RTL-SDR spectrum sweep

Convert any report to PDF: `pandoc <file>.md -o <file>.pdf`.

---

## Deployment quirk (remember this)

macOS TCC blocks the Mac's Terminal from reading `~/Downloads` (also `~/Desktop`,
`~/Documents`), so `scp` from there fails with "No such file." Keep this project
folder somewhere else (e.g. `~/code/netkit/`) and `scp` works directly. The gist
method (Method B) is only a workaround for when the file is stuck in a blocked
folder.

---

## Caveats / known limitations

- **Linted, not hardware-run here.** Always run `netkit selftest` on the Pi
  after deploying; bench-test before a client site.
- **omping** may be absent from Bookworm apt — installed best-effort; the
  single-device multicast checks (IGMP watch, group discovery, joined groups)
  work without it.
- **PTP offset monitor** runs a real `ptp4l` client and may step the system
  clock. The passive PTP traffic watch does not — prefer it unless you need the
  offset reading.
- **SNMP v3** passphrases are stored plaintext in a mode-600 file under
  `~/.config/netkit` (kept off the command line / process list deliberately).
- **RTL-SDR / PTP / omping** need their respective hardware or a peer device.
- **`netkit autostart`** edits system config (systemd getty autologin +
  `~/.bash_profile`); it's gated behind a confirmation and fully reversible with
  `netkit autostart off`.
- Overlay-root, the Pi 5 RTC, and hotspot/AP mode are intentionally **not**
  automated — documented as manual steps rather than applied by the script.

---

## Roadmap / ideas not yet built

- Overlay-root (read-only SD) for crash-safe field use — manual `raspi-config`
  step for now.
- Pi 5 onboard RTC enablement for offline-accurate report timestamps.
- Hotspot/AP mode (`nmcli`) to SSH in from a phone without joining the client LAN.

Deliberately **out of scope:** cable TDR / physical certification (needs
dedicated hardware), BT/Zigbee promiscuous sniffing (needs Ubertooth/nRF),
long-running monitoring daemon (belongs on the UniFi controller / a real NMS).
