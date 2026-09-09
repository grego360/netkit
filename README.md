# netkit

A single-file terminal **network testing / inspection / reporting** tool for a
Raspberry Pi 5 handheld, used on-site for network + AV installs, UniFi sites,
link/throughput testing, switch-port identification, and client reports.

The whole app is one bash script: [`netkit`](./netkit). There is no package,
no build step, and no dependencies *inside* the script — "installing" it means
copying that one file to `/usr/local/bin/netkit` and marking it executable.
The tools it drives (nmap, iperf3, snmpwalk, …) are installed separately by
`netkit setup`.

**Current version: 4.8.0**

---

## ⭐ For Claude Code — read this first

- **`netkit` (the script) is the source of truth.** Read it for current
  behaviour, categories, and helpers before changing anything. This README is
  durable context, not a spec; if they disagree, the script wins.
- **Every change must pass** `bash -n netkit` **and** `shellcheck -s bash netkit`
  **with zero output**, plus `bash tests/run.sh` **ending in `0 failure(s)` (exit 0)**.
  Verify before delivering and say it's been linted and tested.
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
- `menu "Header" "key|Label" …` — gum-backed chooser (arrow/scroll list via
  `gum choose`), returns the chosen key
- `ask <prompt> <default>` / `ask_req …` (aborts on empty) / `ask_pw <prompt>` (hidden)
- `ask_num` / `ask_ip` / `ask_cidr` — validating prompts (loop until valid or cancelled)
- `pause` — "Enter to return"
- `run <cmd> …` — clears, echoes `$ …`, runs `"$@"`, pauses. **Always array-form
  (`run cmd arg …`), never a shell string** — there is deliberately no `runsh`/`bash -c`
  wrapper (it invited command injection from prompt input). When a redirect or compound
  command is genuinely needed, write an inline `clear`/`echo`/`cmd`/`pause` block with
  quoted args. **Do not pipe/tee interactive TUIs through `run`** — it would corrupt them.
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

- **Device:** Waveshare [PocketTerm35](https://docs.waveshare.com/PocketTerm35) handheld
  with a Raspberry Pi 5 inside, Raspberry Pi OS (Debian 13 Trixie), 64-bit (aarch64),
  desktop image with lightdm + labwc installed. Hardware map (all verified on the unit,
  re-check any time with `netkit hw`):
  - 3.5" 640x480 IPS panel fed over **HDMI-A-1** (the speaker rides HDMI audio,
    PipeWire default sink "Built-in Audio Digital Stereo (HDMI)");
  - **Goodix GT911** capacitive touch on `i2c-1` (needs `dtparam=i2c_arm=on` +
    `dtoverlay=waveshare-35dpi-5b` from Waveshare's `3.5HDMI_E_DTBO.zip`; the docs
    also add the `-4b` overlay, whose second Goodix node fails with `-EBUSY` on a Pi 5
    — harmless);
  - 67-key keyboard + trackpad = an RP2040 **"My Custom Pico Keyboard"/"Pico Mouse"**
    USB device on the Pi's USB-C port (needs `dtoverlay=dwc2,dr_mode=host`); Fn+−/+
    drives the backlight in hardware (no `/sys/class/backlight`);
  - Pi5 Active Cooler B on the FAN header — the Pi 5 firmware does **not** detect
    this cooler (`/proc/device-tree/cooling_fan/status` stays `disabled`, fan never
    spins, SoC idles above 60°C). `dtparam=cooling_fan=on` in `/boot/firmware/config.txt`
    forces the pwm-fan driver and the fan runs (~5300 rpm at boot);
  - UPS board + 5000 mAh cell: no fuel gauge exposed to Linux (`/sys/class/power_supply`
    is empty), battery state comes from the board LEDs only; short-press the Pi 5's
    silicone button to shut down, then double-press the top power button to cut power;
  - Pi 5 onboard RTC (`rpi-rtc`), no backup cell;
  - EEPROM: Waveshare's FAQ wants `NET_INSTALL_AT_POWER_ON=0` (the net-install splash
    corrupts the panel) and `PSU_MAX_CURRENT=5000` (the UPS is not a PD supply).
- **Access:** Pi user `terminosa`, reached via SSH from a Mac (user `moonshaper`)
  or directly. Small screen — keep output concise.
- **Layout:** `netkit` at `/usr/local/bin/netkit`; config at
  `~/.config/netkit/`; reports under `~/netkit-reports/`.
- **Connectivity:** WiFi (`wlan0`) and/or wired (`eth0`); netkit re-detects the
  active interface each launch.
- **Status bar:** shows iface / IP / gateway / WiFi / active site, a green ● / red ●
  gateway-reachability dot (cached ~15s so redraws stay snappy), plus a `bat: NN%`
  readout when a UPS/HAT exposes a battery via `/sys/class/power_supply`.

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
netkit doctor       # prebuilt binaries: run + version vs latest release; `doctor fix` reinstalls
```

---

## Updating

**Push from the Mac** (this folder), simplest while iterating — use the included
[`push-netkit.sh`](./push-netkit.sh):

```bash
./push-netkit.sh                 # deploy to the local Pi (SSH alias "terminosa")
./push-netkit.sh remote          # deploy to the remote Pi (terminosa@pocket-term-rpi)
./push-netkit.sh local           # local Pi, explicit
./push-netkit.sh user@host       # or a literal target override
NETKIT_PI=user@host ./push-netkit.sh   # override the default (no-arg) target
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
netkit selftest      bench check (tools + live network + hardware)
netkit hw            PocketTerm35 hardware check (display, touch, keyboard, fan…)
netkit doctor [fix]  prebuilt binaries vs latest GitHub release; fix = reinstall stale/broken
netkit site [name]   site profiles (prefill prompts per location)
netkit autostart on|off   boot the unit straight into netkit
netkit brand [name]  show / set the brand shown above netKit (menus, launch splash)
netkit splash [off]  install the brand as the plymouth boot splash / restore Pi OS's
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
| 🎛 Device Control | RS232/TCP/UDP send+read (ASCII or hex, selectable line ending), live interactive session (tio / ncat), per-device saved command library, PJLink projector probe (TCP 4352) |
| 🎚 AV-over-IP | IGMP querier watch, multicast group discovery, joined groups, omping flow test, PTP traffic watch, PTP offset monitor |
| 🏠 Smart Home / IoT | MQTT sub/pub, Wake-on-LAN |
| 📶 Bluetooth / RF | BLE/classic scan (live, **name + address + RSSI + type**, LE/classic filter), per-device drill-down, adapter info, btmon live trace **or capture to `.btsnoop`**, RTL-SDR 433/868 decode, sub-GHz→MQTT, spectrum sweep, RTL-SDR dongle presence test |
| 📊 Reporting | site snapshot, full sweep, save last viewed output, vnstat, asciinema recording — snapshot/sweep include a **switch SNMP/PoE section** (v2c; from the site's `SNMP_TARGET` or an interactive prompt) |
| ⚙️ System / Network info | interfaces, ethtool, ipcalc, routes, DNS status, tmux dashboard |
| 🏷 Site profile | select / create / show / clear active site |
| ❓ Help / keys | In-app cheat-sheet: navigation keys, category overview, where reports land |

---

## Dependencies

Installed by `netkit setup`. apt-first; prebuilt binaries only where apt lacks a
good aarch64 package.

**apt (core extras):** `mosquitto-clients ethtool snmp fping ipcalc wakeonlan
unzip bluez bluez-tools rtl-433 rtl-sdr swaks tio xxd`
(plus base tools assumed present: nmap, arp-scan, avahi-utils, iperf3, mtr-tiny,
lldpd, termshark/tshark/tcpdump/iftop, wavemon/iw/network-manager,
dnsutils/curl/ncat/socat, vnstat/pandoc/asciinema, tmux/jq/git, gum + glow).

`tio` (interactive serial terminal) and `xxd` (hex→bytes encode / binary reply
display) back the **Device Control** category; `socat` and `ncat` (already present)
drive its send+read and interactive IP sessions.

**apt (best-effort — skipped cleanly if not in the repo):**
`omping linuxptp ndisc6`

**Prebuilt aarch64 GitHub release binaries:** `librespeed-cli gping bandwhich xh bacnet`
— resolved by a shared matcher registry (`PREBUILT_*` arrays) used by both
`setup` and `doctor`. If a project renames its release asset, the fix is a
one-line regex update for that tool; netkit falls back to its base tool meanwhile.

---

## Site profiles

`netkit site new` saves per-location defaults so prompts pre-fill instead of
re-typing them each visit.

- Stored at `~/.config/netkit/sites/<name>.conf` as plain `key=value`.
- Active site name in `~/.config/netkit/active-site`; loaded at every launch.
- Fields: `SMTP`, `SMTP_PORT`, `SNMP_COMMUNITY`, `SNMP_TARGET`, `MQTT`,
  `SPEED_MIN`, `DNS_DOMAIN`, `HTTP_URL`, `PEER`, `LOGO`.
  - `SNMP_TARGET` — switch IP queried (v2c) for the report's switch/PoE section.
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
- **Device Control** needs a USB-serial adapter for RS232; the user must be in the
  `dialout` group (`netkit setup` adds you — re-login or run `newgrp dialout`). The
  PJLink probe is v1 unauthenticated-only. Binary (hex) replies are shown via `xxd`;
  ASCII replies are captured to reports like other paged output.
- **`netkit autostart`** edits system config (systemd getty autologin +
  `~/.bash_profile`); it's gated behind a confirmation and fully reversible with
  `netkit autostart off`. The tty1 login runs netkit inside a tmux session named
  `netkit` (bare netkit if tmux is missing) and exports `NETKIT_CONSOLE=1`, so:
  - an SSH login can drive the same screen the HDMI monitor shows with
    `tmux attach -t netkit`;
  - menu headers drop their emoji and `✓ ✗ ❯` become `+ x >` — the Linux VT has no
    glyphs for them (also triggers on a bare `TERM=linux` login);
  - the tiled dashboard opens as a tmux *window* of that session (Ctrl-b & closes
    it) instead of nesting a second `tmux attach`, which tmux refuses.
  On a desktop image the greeter owns the panel, so autostart only shows if the
  unit boots to the console (`sudo systemctl set-default multi-user.target`, or
  raspi-config → System → Boot).
- **Panel kiosk.** When `cage` + `foot` are installed (`netkit setup` adds them),
  the tty1 login runs `cage -- foot -e tmux … netkit` instead of the bare console:
  anti-aliased JetBrains Mono at 12pt (64x22 cells), emoji headers, true colour,
  tap/drag scrolling. netkit quitting relaunches the kiosk; a cage that dies within
  5 s falls back to the plain console automatically. Font size and colours live in
  `~/.config/foot/foot.ini` (seeded once by `netkit autostart on`; `size=13` → 58x20,
  `size=11` → 71x24). Menus size themselves to the terminal: status line + header +
  list, banner only on terminals ≥ 40 rows; tmux's status bar is hidden under 40
  rows. `netkit autostart on` is idempotent — re-run it after upgrading to refresh
  the launcher block. The VT/console fallback stays at the stock 8x16 font (80x30).
- **Branding.** `~/.config/netkit/netkit.conf` (`BRAND=Modal AV`, whitelist-parsed
  like site profiles, never sourced) sets the integrator/customer name shown above
  the fixed **netKit** wordmark: on every menu's top line (or in the banner box on
  tall terminals), on the launch splash, and — via `netkit splash` / System →
  Branding — as the plymouth boot splash (ImageMagick renders a 640x480 PNG, the
  theme copies Pi OS's pix scaling script; `netkit splash off` restores pix).
  The launch splash is ASCII text art so it looks the same in foot, tmux, the
  Linux console and over SSH: the brand in figlet's `standard` face (`small` when
  standard is wider than the terminal) with the last word of a multi-word brand
  in the accent green (figlet'd on its own and joined line by line, `logo_art`),
  **netKit** in the small face under it, then the version. Without a brand netKit
  is the big line, all in green. Centring is done in-script (`center_lines`) —
  `gum style` strips ANSI colour from its input, so it cannot centre the coloured
  art. No figlet → plain text. netKit itself is not configurable. (A sixel/chafa
  bitmap splash was tried in 4.6.0 and dropped in 4.7.0 in favour of text art.)
- **Idle screen & panel off.** Two stages, set in System → Idle screen (or
  `IDLE_SECS=90` / `BLANK_SECS=300` in `netkit.conf`, 0 disables a stage): after
  IDLE_SECS the branded screensaver (`netkit screensaver`: wordmark, clock, site,
  address, moved every 30 s), after BLANK_SECS the panel output is switched off.
  In the kiosk `cage -- netkit kiosk` starts `swayidle` next to foot; it takes
  idleness from cage's idle notifier, which counts keyboard, mouse **and touch**
  (tmux never sees the touchscreen). Stage 1 is `tmux lock-session` with the saver
  as the lock command: it owns the terminal, so the key or tap that wakes the unit
  is consumed and never reaches the menu; any input → `netkit idle-wake` turns the
  output back on (`wlr-randr --on`; cage lacks the output-power protocol, so
  wlopm does not work, but disabling the output drives DPMS Off and the WS-35-640
  panel drops its backlight) and kills the saver, which unlocks tmux. Neither
  stage fires while an action is in the foreground (`idle_can_lock`: only
  bash/gum/netkit/sh count as idle), so a running capture or throughput test is
  never hidden. Console fallback: tmux's own `lock-after-time` starts the saver
  (keyboard idle only, no blanking). Re-run `netkit autostart on` after upgrading
  to 4.8.0 so the launcher block runs `netkit kiosk`; a running tty1 login shell
  keeps its old loop until `sudo systemctl restart getty@tty1` (or a reboot).
- **Long output scrolls, it doesn't fly past.** Finite commands (arp-scan, nmap,
  iw scan, ethtool, dig, swaks, …) go through `page`, which shows the output inline
  when it fits and otherwise opens gum's pager (↑/↓ scroll, q closes). Actions that
  build their own text (Bluetooth scan table, self-test, hardware check, fping,
  IPv6 neighbours, PJLink probe, report fallback) hand it to `show_output <title>
  <text>`, the display half of `page`. Only live TUIs and streams (wavemon, mtr,
  tcpdump, btmon, ping, iperf3 …) use `run`. Never print-then-`pause` a result: on
  the 20-row panel the top is gone before the pause.
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
