# Off-hardware unit-test harness — design

**Date:** 2026-06-22
**Component:** new `tests/run.sh` + a one-line source guard in `netkit`
**Status:** approved for planning

## Goal

Give `netkit`'s pure, hardware-independent helper functions real regression
coverage that runs on any dev machine (macOS + the Pi) with **zero dependencies**
— no test framework to install, nothing shipped to the Pi, not part of
`netkit setup`.

## Locked decisions

- **Plain bash, zero deps.** A self-contained `tests/run.sh` with a tiny assert
  library. No bats / shunit2 (both add install + learning cost for no gain here).
- **Source the real functions** via a one-line guard in `netkit`, rather than
  `sed`-extracting functions one at a time (fragile; can't compose dependent
  functions like `snmp_report_block` → `snmp_if_table`).
- **Full pure set** in scope (see Coverage).

## Out of scope (YAGNI)

- The interactive validators `ask_num` / `ask_ip` / `ask_cidr` (they loop on
  input; need an input-queue stub for `ask`).
- Anything needing live network, real hardware, or a real SNMP/serial peer.
- Mocking `gum`. Tests exercise logic, not the menu UI.
- TAP output. If wanted later, shunit2 is the least-invasive upgrade path.

## Architecture

### 1. Source guard (in `netkit`)

One line at the top of the `# ---------- main ----------` block, **before**
`load_site`:

```bash
[ "${NETKIT_LIB:-0}" = 1 ] && return 0   # tests source this to load functions without running
```

- `NETKIT_LIB=1 source ./netkit` loads every function then returns before any
  dispatch — no `load_site`, no subcommand `case`, no `trap`, no `while` loop.
- Normal execution (`NETKIT_LIB` unset) is unaffected: the `[...]` test is false,
  `&&` short-circuits, `return` is never reached.
- **The `&&` form is mandatory.** A bare top-level `return 0` would runtime-error
  (`can only 'return' from a function or sourced script`) on normal execution.
  The short-circuit form is the correct, shellcheck-clean idiom (shellcheck does
  not warn on top-level `return`).
- Sourcing still runs the harmless top-level setup (globals, colour block, the
  `ip`/sysfs live-fact detection — all `2>/dev/null`, yielding empty vars on
  macOS with no hang or error spew).

### 2. Runner: `tests/run.sh`

Single self-contained file, `#!/usr/bin/env bash`, run as `bash tests/run.sh`
from the repo root. Structure:

```bash
#!/usr/bin/env bash
# Off-hardware unit tests for netkit's pure helpers. Zero deps; run from repo root.
NETKIT_LIB=1 source ./netkit || { echo "cannot source ./netkit"; exit 2; }

fails="$(mktemp)"; trap 'rm -f "$fails"' EXIT

assert_eq()       { if [ "$1" = "$2" ]; then printf '  ok: %s\n' "$3"; else printf '  FAIL: %s (want [%s] got [%s])\n' "$3" "$1" "$2"; echo x >>"$fails"; fi; }
assert_empty()    { if [ -z "$1" ]; then printf '  ok: %s\n' "$2"; else printf '  FAIL: %s (got [%s])\n' "$2" "$1"; echo x >>"$fails"; fi; }
assert_contains() { case "$1" in *"$2"*) printf '  ok: %s\n' "$3" ;; *) printf '  FAIL: %s (missing [%s])\n' "$3" "$2"; echo x >>"$fails" ;; esac; }
assert_rc()       { if [ "$1" = "$2" ]; then printf '  ok: %s\n' "$3"; else printf '  FAIL: %s (want rc %s got %s)\n' "$3" "$1" "$2"; echo x >>"$fails"; fi; }

# run_test, NOT run — netkit defines its own run() helper, which we just sourced.
run_test() { printf '== %s ==\n' "$1"; ( "$1" ); }   # subshell isolates stubs + globals

# … test_<fn> functions …

run_test test_framing_socat
run_test test_framing_tio
# … etc …

n="$(wc -l <"$fails" | tr -d ' ')"
printf '\n%s failure(s)\n' "$n"
[ "$n" -eq 0 ]
```

Key properties (all verified by the senior review):

- **Subshell per test** (`( "$1" )`) isolates command-stubs and any
  `G_*`/`SITE_*`/`DEV_*` mutations — they never leak between tests.
- **Failure count via a mktemp file.** Subshells can't mutate a parent counter,
  so each failed assert appends a line; the parent tallies with
  `wc -l | tr -d ' '` (macOS left-pads `wc -l`; strip it) and exits non-zero if
  any failed.
- **Runner is `-u`-clean.** `set -uo pipefail` propagates from the sourced
  `netkit`, so every variable the runner uses is initialised before use.
- The final `[ "$n" -eq 0 ]` is the script's exit status (arithmetic `-eq`, not
  string `=`).

### 3. Stubbing

External commands are shadowed by defining bash functions of the same name
inside a test's subshell (bash resolves functions before PATH binaries; the
shadow is discarded when the subshell exits). No tested function uses
`command <name>` to bypass function lookup, so shadows always take effect.

- `snmp_if_table` / `snmp_report_block`: stub `snmpwalk` to emit synthetic rows
  keyed by the trailing OID arg (`oid="${@: -1}"`); stub `snmpget`; stub `have`.
  Real `snmp_if_table` / `snmp_poe` run against the stubbed `snmpwalk`.
- `load_site` / `load_device`: set `NETKIT_CFG_DIR` / `site_dir` /
  `device_dir` to `mktemp -d` dirs, write a `.conf`, call, assert globals.

## Coverage (the full pure set)

| Function | Assertions |
| --- | --- |
| `framing_socat` | `8N1`→`cs8,parenb=0,…,cstopb=0`; `8E1`/`7O1` parity/stop bits; bad framing (`9X2`) → rc 1 |
| `framing_tio` | `8N1`→`-d 8 -p none -s 1`; `8E1`→`even`, `7O1`→`odd`; bad framing → rc 1 |
| `hex_norm` | strips whitespace + per-token `0x`/`0X`; leaves embedded hex intact (`a0xb`→`a0xb` per the anchored rule) |
| `devctl_valid_hex` | even-length hex → rc 0; odd length → rc 1; non-hex garbage → rc 1; empty → rc 1; `0x`/spaces tolerated |
| `devctl_emit` | ascii passthrough + CR/LF/CRLF endings; hex→bytes **(gated by `command -v xxd`; skip-with-note if absent)** |
| `devctl_addr` | `serial`/`tcp`/`udp` address strings well-formed; bad serial framing → rc 1 |
| `load_site` | temp `.conf` populates `SITE_*` (incl. `SNMP_TARGET`); a non-whitelisted key and a `$(…)` line are ignored (security boundary) |
| `load_device` | temp `.conf` populates `DEV_*` and the `DEV_CMD_*` arrays from `CMD=` lines |
| `snmp_if_table` | normal speed formats (`1G`/`100M`); `ifSpeed=4294967295` + `ifHighSpeed=10000` → `10G` |
| `snmp_report_block` | empty host → empty output; `have`→false → "not installed"; reachable → renders `## Switch … (SNMP v2c)` with System/Interfaces/PoE |

## Portability / error handling

- Tests requiring an absent tool (`xxd`) print `SKIP …` and return 0 rather than
  fail. `xxd` is present on macOS by default and is installed by netkit's
  `do_setup` on the Pi.
- The runner must not depend on `ip`, `snmpwalk`, etc. being installed — every
  external dependency in a test path is either stubbed or gated.

## Integration

- Add `bash tests/run.sh` to the "Mandatory verification" note in `CLAUDE.md` and
  `README.md`, alongside `bash -n` + `shellcheck`.
- Run `bash tests/run.sh` in `push-netkit.sh` before the `scp`/install step
  (fail the deploy if tests fail), next to its existing lint check.
- `tests/run.sh` itself must pass `shellcheck -s bash`.
- The harness is dev-machine only — not shipped to the Pi, not in `netkit setup`.

## Senior-review sign-off

Reviewed 2026-06-22 against current bash semantics + tooling: verdict
*correct-with-fixes*, no blocking issues. Confirmed: the `&& return 0` guard is
correct and shellcheck-clean; macOS sourcing is side-effect-safe; subshell
function-shadow mocking and mktemp failure-counting are sound; plain bash is the
right tool over bats/shunit2. The three folded fixes — mandatory `&&` form (not
bare `return`), `wc -l` whitespace strip + arithmetic `-eq`, and a `-u`-clean
runner — are incorporated above.
