# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Read first

`README.md` contains the authoritative "For Claude Code — read this first" section
(conventions, environment, deployment quirks). Read it. **The `netkit` script itself
is the source of truth** — if README and script disagree, the script wins.

This is a **bash** project. It is not a Next.js / SwiftUI / React project; none of
those conventions, agents, or skills apply here.

## What this is

A single 1100-line bash script (`netkit`) that is a categorised network
testing/inspection/reporting dashboard for a Raspberry Pi 5 handheld (aarch64,
Raspberry Pi OS Bookworm). No build step, no package, no in-script dependencies.
"Installing" = copying the one file to `/usr/local/bin/netkit`. `older_versions/`
holds prior iterations for reference only — don't edit them.

## Mandatory verification (every change)

Both must produce **zero output** before delivering:

```bash
bash -n netkit                    # syntax check
shellcheck -s bash netkit         # lint
```

Say explicitly that it was linted. Targeted `# shellcheck disable=SCxxxx` is allowed
only for genuinely intentional cases, each with a comment explaining why. There is no
runtime test suite — the script needs real aarch64 hardware + network peers; on the Pi
the equivalents are `netkit selftest` (tools + live network) and `netkit doctor`
(prebuilt-binary matchers). Be honest that work is "linted but not run on hardware."

## Hard constraints

- `set -uo pipefail` (no `-e`). **Every new global must be initialised** so `set -u`
  is satisfied (see the site-variable block around line 93).
- Runs as the **normal user**; call `sudo` only for the few actions needing it (raw
  sockets, systemd, setcap). Never require running the whole script as root.
- **apt-first.** Use Debian aarch64 packages where they exist. Third-party repos /
  prebuilt GitHub binaries only where apt has no good package. **Never compile on the Pi.**
- Optional tools are always gated behind `have <cmd>` / `require <cmd>` and degrade
  gracefully.
- Prefer a single self-contained deliverable per change.

## Architecture of the one file (top → bottom)

1. **Header + globals** — shebang, `set -uo pipefail`, `NETKIT_VERSION`, paths
   (`NETKIT_CFG_DIR`, `site_dir`).
2. **Helpers** (top of file) — the vocabulary every menu action is built from:
   `have`, `require <cmd> [hint]` (offer-to-setup guard for optional tools),
   one colour palette (`C_OK/C_WARN/C_ERR/C_HDR/C_RST`, honours `NO_COLOR`/non-tty),
   `menu "Header" "key|Label" …` (gum chooser; arrow/scroll list, returns chosen key),
   `ask`/`ask_req`/`ask_pw` and validating `ask_num`/`ask_ip`/`ask_cidr`, `pause`,
   `run` (clear → echo command → run → pause; **array-form, never a shell string** —
   there is deliberately no `runsh`/`bash -c` wrapper, as it invited command injection
   from prompt input; when a redirect or compound command is genuinely needed, write an
   inline `clear`/`echo`/`cmd`/`pause` block with quoted args), `page` (capture + pager
   for long **batch** output), `spin` (gum progress for slow hidden-output steps),
   `say`/`ok`/`warn`/`bad`, `need_iface`. **`run` must not be confused with `page`:
   `page` captures stdout and must only wrap batch commands** — wavemon, termshark,
   gping, btmon, tcpdump etc. own the terminal and corrupt if captured; call those via
   `run` only. A single `trap … INT` near the main loop makes Ctrl-C abort the
   current action and return to the menu rather than kill netkit.
3. **Site profiles** (~line 91–195) — per-location defaults in
   `~/.config/netkit/sites/<name>.conf`. `load_site` is a **whitelist `key=value`
   parser** — the `.conf` is *never* sourced/executed (security boundary; don't replace
   it with `source`). Fields populate `SITE_*` globals consumed by menu actions.
   Whitelisted keys include `SNMP_TARGET` (switch IP for the report SNMP/PoE section).
4. **Live network facts** (~line 225–241) — `IFACE`, `GW`, `CIDR`, `SELFIP`, `WIFACE`,
   `WIRED` detected at launch from `ip`/sysfs. Re-detected every run; menus read these.
5. **Category menus** `m_*` (~line 244–719) — one function per dashboard category
   (`m_discovery`, `m_link`, `m_wifi`, `m_packet`, `m_dns`, `m_lldp`, `m_snmp`,
   `m_avoip`, `m_iot`, `m_rf`, `m_report`, `m_system`, `m_site`, `m_ot`). Each builds a
   `menu` and dispatches to actions wrapped in `run`/`page`.
6. **Report generators** — `gen_report` (snapshot), `gen_sweep` (branded commissioning
   sweep), `run_dash` (tmux tiled view). Output goes under `report_dir`:
   `~/netkit-reports/<site|default>/<date>/`.
7. **Prebuilt-binary registry** (~line 862) — four parallel arrays
   `PREBUILT_REPOS / PREBUILT_RX / PREBUILT_BIN / PREBUILT_NAME` for the GitHub-release
   tools (`librespeed-cli`, `gping`, `bandwhich`, `xh`). Shared by `install_release_bin`
   (used by `do_setup`) and `do_doctor`. **When a project renames its release asset, the
   fix is a one-line regex edit in `PREBUILT_RX`** — netkit falls back to the base tool
   meanwhile. `netkit doctor` exists to catch this drift proactively.
8. **Subcommands** — `do_setup`, `do_selftest`, `do_doctor`, `do_update`,
   `do_uninstall`, `do_autostart`, `usage`.
9. **Main dispatch** (~line 1077) — `load_site`, then a `case` on `$1` for subcommands;
   no arg → the interactive category loop.

### Adding a feature
Add the action inside the relevant `m_*` menu (a new `"key|Label"` line + a `case`
branch). Use array-form `run` for interactive/streaming commands and `page` for finite
batch output. Never build a shell string from prompt input (no `bash -c`); if a redirect
or compound command is needed, write an inline `clear`/`echo`/`cmd`/`pause` block with
quoted args. Gate any optional tool with `require <cmd> "<pkg>" || return` (not a
hand-rolled "not installed" message). For a curated one-tap action, add an id to
`quick_run` + a line to `m_quick` — no `m_*` rewrite needed. If it needs a new apt
package, add it to the `pkgs` array in `do_setup` and the `extras` list in
`do_selftest`. If it needs a GitHub-release binary, add a row to all four `PREBUILT_*`
arrays. Verify package names / asset naming / tool flags by web search before depending
on them — asset naming drifts.

## Common commands

```bash
netkit              # interactive dashboard (default)
netkit setup        # install apt packages + prebuilt aarch64 binaries
netkit selftest     # confirm tools present + gateway/subnet reachable
netkit doctor       # confirm the 4 GitHub-binary matchers still resolve
netkit dash | report | sweep | site [name] | autostart on|off | update [URL]
```

Deploy/update from this Mac folder (keep it out of `~/Downloads|Desktop|Documents` —
macOS TCC blocks Terminal there):

```bash
scp netkit terminosa@<pi-ip>:/tmp/netkit
ssh terminosa@<pi-ip> 'sudo install -m 0755 /tmp/netkit /usr/local/bin/netkit && netkit version'
```
