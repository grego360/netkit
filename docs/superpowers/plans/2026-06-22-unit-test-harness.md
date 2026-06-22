# Unit-Test Harness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a zero-dependency, off-hardware unit-test harness (`tests/run.sh`) that exercises `netkit`'s pure helper functions on any dev machine.

**Architecture:** A one-line `NETKIT_LIB` source guard in `netkit` lets `tests/run.sh` do `NETKIT_LIB=1 source ./netkit` to load all functions without running the dashboard. The runner is plain bash with a tiny assert library; each function's tests run in a subshell for stub isolation; failures are tallied via a mktemp file and set the exit code.

**Tech Stack:** bash (`set -uo pipefail`), standard coreutils. No test framework.

## Global Constraints

- `netkit` runs under `set -uo pipefail`; `source`-ing it propagates that into the runner, so **`tests/run.sh` must initialise every variable it uses** before use.
- Both `bash -n netkit` AND `shellcheck -s bash netkit` MUST produce **zero output** before any commit; `tests/run.sh` MUST also pass `shellcheck -s bash`.
- The source guard MUST be exactly `[ "${NETKIT_LIB:-0}" = 1 ] && return 0` — the `&&` short-circuit form (a bare top-level `return` runtime-errors on normal execution).
- Failure-count check MUST use arithmetic `-eq` (macOS `wc -l` left-pads its output; strip with `tr -d ' '`).
- The runner's per-test dispatcher MUST be named `run_test`, NOT `run` — `netkit` defines its own `run()` helper, which sourcing pulls in.
- External commands in a test path are either **stubbed** (bash function shadow inside the test's subshell) or **gated** (`command -v <tool>` → skip-with-note). The only gated tool is `xxd` (for `devctl_emit` hex).
- The harness is dev-machine only — not shipped to the Pi, not in `netkit setup`.
- Run everything from the repo root (`/Users/moonshaper/developer/scripts/netkit`).
- Source of truth is the `netkit` script; line anchors below may drift — re-grep if a hunk doesn't match.

---

### Task 1: Source guard + runner skeleton (proves the harness detects failures)

**Files:**
- Modify: `netkit:2085-2086` (insert guard at the top of the main block)
- Create: `tests/run.sh`

**Interfaces:**
- Produces: `NETKIT_LIB=1 source ./netkit` loads all functions and returns before dispatch. `tests/run.sh` exposes `assert_eq`, `assert_empty`, `assert_contains`, `assert_rc`, and `run_test <fn>`; appends one line per failure to `$fails`; exits non-zero iff any assert failed. Consumed by Tasks 2-6.

- [ ] **Step 1: Add the source guard to netkit**

The main block currently begins (line 2085):

```bash
# ---------- main ----------
load_site
```

Insert the guard line between them:

```bash
# ---------- main ----------
# Tests source this file with NETKIT_LIB=1 to load functions without running the
# dashboard or any subcommand. Must be the && short-circuit form: a bare top-level
# `return` would runtime-error on normal execution.
[ "${NETKIT_LIB:-0}" = 1 ] && return 0
load_site
```

- [ ] **Step 2: Verify the guard doesn't break normal execution or linting**

Run: `bash -n netkit && shellcheck -s bash netkit && echo CLEAN`
Expected: `CLEAN`.

Run: `bash netkit version`
Expected: `netkit v4.3.0` (guard is false → normal execution unaffected).

- [ ] **Step 3: Create `tests/run.sh` with the harness + a deliberate failing self-check**

Create `tests/run.sh`:

```bash
#!/usr/bin/env bash
# Off-hardware unit tests for netkit's pure helpers. Zero deps. Run from repo root:
#   bash tests/run.sh
# Sources netkit via the NETKIT_LIB guard, then exercises pure functions with
# subshell-isolated command stubs. Exit 0 = all pass; non-zero = a failure.

NETKIT_LIB=1 source ./netkit || { echo "cannot source ./netkit (run from repo root)"; exit 2; }

fails="$(mktemp)"; trap 'rm -f "$fails"' EXIT

assert_eq()       { if [ "$1" = "$2" ]; then printf '  ok: %s\n' "$3"; else printf '  FAIL: %s (want [%s] got [%s])\n' "$3" "$1" "$2"; echo x >>"$fails"; fi; }
assert_empty()    { if [ -z "$1" ]; then printf '  ok: %s\n' "$2"; else printf '  FAIL: %s (got [%s])\n' "$2" "$1"; echo x >>"$fails"; fi; }
assert_contains() { case "$1" in *"$2"*) printf '  ok: %s\n' "$3" ;; *) printf '  FAIL: %s (missing [%s])\n' "$3" "$2"; echo x >>"$fails" ;; esac; }
assert_rc()       { if [ "$1" = "$2" ]; then printf '  ok: %s\n' "$3"; else printf '  FAIL: %s (want rc %s got %s)\n' "$3" "$1" "$2"; echo x >>"$fails"; fi; }

# run_test, NOT run — netkit defines its own run() helper, which we just sourced.
run_test() { printf '== %s ==\n' "$1"; ( "$1" ); }

test_selfcheck() { assert_eq a b "DELIBERATE failure — proves the harness detects failures"; }

run_test test_selfcheck

n="$(wc -l <"$fails" | tr -d ' ')"
printf '\n%s failure(s)\n' "$n"
[ "$n" -eq 0 ]
```

- [ ] **Step 4: Run the suite and confirm it FAILS (proves failure detection)**

Run: `bash tests/run.sh; echo "exit=$?"`
Expected: a `FAIL:` line for the selfcheck, `1 failure(s)`, and `exit=1`.

- [ ] **Step 5: Replace the deliberate failure with a real passing smoke test**

In `tests/run.sh`, replace the `test_selfcheck` line and its `run_test` call:

```bash
test_smoke() { assert_eq "8" "8" "harness sanity"; }

run_test test_smoke
```

(Delete the old `test_selfcheck` function and its `run_test test_selfcheck` line.)

- [ ] **Step 6: Run the suite and confirm it PASSES + lint the runner**

Run: `bash tests/run.sh; echo "exit=$?"`
Expected: `ok: harness sanity`, `0 failure(s)`, `exit=0`.

Run: `shellcheck -s bash tests/run.sh && echo CLEAN`
Expected: `CLEAN`.

- [ ] **Step 7: Commit**

```bash
git add netkit tests/run.sh
git commit -m "test: add NETKIT_LIB source guard + zero-dep test harness skeleton

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: framing_socat + framing_tio tests

**Files:**
- Modify: `tests/run.sh`

**Interfaces:**
- Consumes: `framing_socat`/`framing_tio` (sourced), `assert_eq`/`assert_rc`/`run_test` (Task 1).

- [ ] **Step 1: Add the test functions**

In `tests/run.sh`, before the `n="$(wc -l …)"` summary line, add:

```bash
test_framing_socat() {
  assert_eq "cs8,parenb=0,cstopb=0"         "$(framing_socat 8N1)" "socat 8N1"
  assert_eq "cs8,parenb=1,parodd=0,cstopb=0" "$(framing_socat 8E1)" "socat 8E1"
  assert_eq "cs7,parenb=1,parodd=1,cstopb=0" "$(framing_socat 7O1)" "socat 7O1"
  assert_eq "cs8,parenb=0,cstopb=1"         "$(framing_socat 8N2)" "socat 8N2 (2 stop bits)"
  framing_socat 9N1 >/dev/null 2>&1; assert_rc 1 "$?" "socat rejects bad framing 9N1"
}

test_framing_tio() {
  assert_eq "-d 8 -p none -s 1" "$(framing_tio 8N1)" "tio 8N1"
  assert_eq "-d 8 -p even -s 1" "$(framing_tio 8E1)" "tio 8E1"
  assert_eq "-d 7 -p odd -s 1"  "$(framing_tio 7O1)" "tio 7O1"
  framing_tio 9N1 >/dev/null 2>&1; assert_rc 1 "$?" "tio rejects bad framing 9N1"
}
```

And add their `run_test` calls after `run_test test_smoke`:

```bash
run_test test_framing_socat
run_test test_framing_tio
```

- [ ] **Step 2: Run the suite**

Run: `bash tests/run.sh; echo "exit=$?"`
Expected: `ok:` lines for all framing assertions, `0 failure(s)`, `exit=0`.

- [ ] **Step 3: Lint the runner**

Run: `shellcheck -s bash tests/run.sh && echo CLEAN`
Expected: `CLEAN`.

- [ ] **Step 4: Commit**

```bash
git add tests/run.sh
git commit -m "test: cover framing_socat + framing_tio

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: hex_norm + devctl_valid_hex tests

**Files:**
- Modify: `tests/run.sh`

**Interfaces:**
- Consumes: `hex_norm`/`devctl_valid_hex` (sourced), `assert_eq`/`assert_rc`/`run_test`.

- [ ] **Step 1: Add the test functions**

Before the summary line, add:

```bash
test_hex_norm() {
  assert_eq "4142"  "$(hex_norm '0x41 0x42')" "hex_norm strips per-token 0x + spaces"
  assert_eq "AABB"  "$(hex_norm '  AA BB ')"  "hex_norm strips surrounding/inner whitespace"
  assert_eq "a0xb"  "$(hex_norm 'a0xb')"      "hex_norm leaves mid-token 0x intact (anchored)"
}

test_devctl_valid_hex() {
  devctl_valid_hex "4142";       assert_rc 0 "$?" "valid even-length hex"
  devctl_valid_hex "0x41 0x42";  assert_rc 0 "$?" "valid hex with 0x + spaces"
  devctl_valid_hex "414";        assert_rc 1 "$?" "reject odd-length hex"
  devctl_valid_hex "zz";         assert_rc 1 "$?" "reject non-hex garbage"
  devctl_valid_hex "";           assert_rc 1 "$?" "reject empty"
}
```

And the `run_test` calls (after the framing ones):

```bash
run_test test_hex_norm
run_test test_devctl_valid_hex
```

- [ ] **Step 2: Run the suite**

Run: `bash tests/run.sh; echo "exit=$?"`
Expected: `ok:` lines for all hex assertions, `0 failure(s)`, `exit=0`.

- [ ] **Step 3: Lint the runner**

Run: `shellcheck -s bash tests/run.sh && echo CLEAN`
Expected: `CLEAN`.

- [ ] **Step 4: Commit**

```bash
git add tests/run.sh
git commit -m "test: cover hex_norm + devctl_valid_hex

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: devctl_emit + devctl_addr tests

**Files:**
- Modify: `tests/run.sh`

**Interfaces:**
- Consumes: `devctl_emit`/`devctl_addr` (sourced), `assert_eq`/`assert_rc`/`run_test`. `devctl_emit` hex path needs `xxd` → gated.

- [ ] **Step 1: Add the test functions**

Before the summary line, add:

```bash
test_devctl_emit() {
  assert_eq "$(printf 'AT\r')"   "$(devctl_emit ascii AT cr)"   "emit ascii + CR"
  assert_eq "$(printf 'AT\n')"   "$(devctl_emit ascii AT lf)"   "emit ascii + LF"
  assert_eq "$(printf 'AT\r\n')" "$(devctl_emit ascii AT crlf)" "emit ascii + CRLF"
  if command -v xxd >/dev/null 2>&1; then
    assert_eq "$(printf 'AB')" "$(devctl_emit hex 4142 none)" "emit hex 4142 -> AB"
  else
    printf '  SKIP: emit hex (xxd absent)\n'
  fi
}

test_devctl_addr() {
  assert_eq "/dev/ttyUSB0,b9600,rawer,echo=0,clocal=1,cs8,parenb=0,cstopb=0,crtscts=0" \
            "$(devctl_addr serial /dev/ttyUSB0 9600 8N1)" "serial addr 8N1"
  assert_eq "TCP:1.2.3.4:4998" "$(devctl_addr tcp 1.2.3.4 4998)" "tcp addr"
  assert_eq "UDP:1.2.3.4:4998" "$(devctl_addr udp 1.2.3.4 4998)" "udp addr"
  devctl_addr serial x 9600 9N1 >/dev/null 2>&1; assert_rc 1 "$?" "serial addr rejects bad framing"
}
```

And the `run_test` calls:

```bash
run_test test_devctl_emit
run_test test_devctl_addr
```

- [ ] **Step 2: Run the suite**

Run: `bash tests/run.sh; echo "exit=$?"`
Expected: `ok:` lines for emit/addr (the hex line shows `ok:` on macOS where `xxd` is present, or `SKIP:` if absent), `0 failure(s)`, `exit=0`.

- [ ] **Step 3: Lint the runner**

Run: `shellcheck -s bash tests/run.sh && echo CLEAN`
Expected: `CLEAN`.

- [ ] **Step 4: Commit**

```bash
git add tests/run.sh
git commit -m "test: cover devctl_emit + devctl_addr

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: load_site + load_device tests (incl. security boundary)

**Files:**
- Modify: `tests/run.sh`

**Interfaces:**
- Consumes: `load_site`/`load_device` (sourced), the `SITE_*`/`DEV_*`/`DEV_CMD_*` globals, `assert_eq`/`assert_empty`/`run_test`. Each test sets `NETKIT_CFG_DIR`/`site_dir`/`device_dir` to temp dirs (subshell-local).

- [ ] **Step 1: Add the test functions**

Before the summary line, add:

```bash
test_load_site() {
  local d; d="$(mktemp -d)"
  NETKIT_CFG_DIR="$d"; site_dir="$d/sites"; mkdir -p "$site_dir"
  printf 'SNMP_TARGET=10.0.0.5\nSNMP_COMMUNITY=sec\nBOGUS=ignored\nEVIL=$(touch %s/pwned)\n' "$d" > "$site_dir/foo.conf"
  echo foo > "$d/active-site"
  load_site
  assert_eq "10.0.0.5" "$SITE_SNMP_TARGET"    "load_site parses SNMP_TARGET"
  assert_eq "sec"      "$SITE_SNMP_COMMUNITY"  "load_site parses SNMP_COMMUNITY"
  assert_eq "foo"      "$NETKIT_SITE"          "load_site sets active site"
  [ -e "$d/pwned" ]; assert_rc 1 "$?" "load_site does NOT execute \$(...) in a .conf (security boundary)"
  rm -rf "$d"
}

test_load_device() {
  local d; d="$(mktemp -d)"
  device_dir="$d/devices"; mkdir -p "$device_dir"
  printf 'TRANSPORT=tcp\nHOST=1.2.3.4\nPORT=502\nCMD=Power On|ascii|PWR1|cr\nCMD=Power Off|ascii|PWR0|cr\n' > "$device_dir/proj.conf"
  load_device proj
  assert_eq "tcp"     "$DEV_TRANSPORT"           "load_device parses TRANSPORT"
  assert_eq "1.2.3.4" "$DEV_HOST"                "load_device parses HOST"
  assert_eq "502"     "$DEV_PORT"                "load_device parses PORT"
  assert_eq "2"       "${#DEV_CMD_LABEL[@]}"     "load_device parses 2 CMD rows"
  assert_eq "Power On" "${DEV_CMD_LABEL[0]}"     "load_device first CMD label"
  assert_eq "PWR0"    "${DEV_CMD_PAYLOAD[1]}"    "load_device second CMD payload"
  rm -rf "$d"
}
```

And the `run_test` calls:

```bash
run_test test_load_site
run_test test_load_device
```

- [ ] **Step 2: Run the suite**

Run: `bash tests/run.sh; echo "exit=$?"`
Expected: `ok:` lines for all parser assertions (including the security-boundary one), `0 failure(s)`, `exit=0`.

- [ ] **Step 3: Lint the runner**

Run: `shellcheck -s bash tests/run.sh && echo CLEAN`
Expected: `CLEAN`. (If shellcheck flags `site_dir`/`device_dir`/`SITE_*`/`DEV_*` as assigned-but-unused inside the test, that is incorrect here — they are read by the sourced functions; if it does flag, add a targeted `# shellcheck disable=SC2034` above the assignment with a comment. Verify whether it actually fires before adding any directive.)

- [ ] **Step 4: Commit**

```bash
git add tests/run.sh
git commit -m "test: cover load_site + load_device incl. no-exec security boundary

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: snmp_if_table + snmp_report_block tests (stubbed snmpwalk)

**Files:**
- Modify: `tests/run.sh`

**Interfaces:**
- Consumes: `snmp_if_table`/`snmp_report_block` (sourced), the `G_SNMP_ARGS` global, `assert_contains`/`assert_empty`/`run_test`. Each test stubs `snmpwalk`/`snmpget`/`have` in its subshell.

- [ ] **Step 1: Add the test functions**

Before the summary line, add:

```bash
test_snmp_if_table() {
  G_SNMP_ARGS=(-v2c -c public -t 2 -r 1)
  snmpwalk() {                       # synthetic rows keyed by trailing OID arg
    local oid="${@: -1}"
    case "$oid" in
      1.3.6.1.2.1.2.2.1.2)     printf '%s\n%s\n' ".1.3.6.1.2.1.2.2.1.2.1 TenGigE0/1" ".1.3.6.1.2.1.2.2.1.2.2 GigE0/2" ;;
      1.3.6.1.2.1.2.2.1.8)     printf '%s\n%s\n' ".1.3.6.1.2.1.2.2.1.8.1 1" ".1.3.6.1.2.1.2.2.1.8.2 1" ;;
      1.3.6.1.2.1.2.2.1.5)     printf '%s\n%s\n' ".1.3.6.1.2.1.2.2.1.5.1 4294967295" ".1.3.6.1.2.1.2.2.1.5.2 1000000000" ;;
      1.3.6.1.2.1.31.1.1.1.15) printf '%s\n%s\n' ".1.3.6.1.2.1.31.1.1.1.15.1 10000" ".1.3.6.1.2.1.31.1.1.1.15.2 1000" ;;
    esac
  }
  local out; out="$(snmp_if_table 1.2.3.4)"
  assert_contains "$out" "TenGigE0/1" "if_table lists interface name"
  assert_contains "$out" "10G"        "if_table uses ifHighSpeed for capped 10G link"
  assert_contains "$out" "1G"         "if_table formats a normal 1G link"
}

test_snmp_report_block() {
  have()     { return 0; }
  snmpget()  { return 0; }
  snmpwalk() { echo "x"; }
  assert_empty "$(snmp_report_block '')" "report_block: empty host -> no section"
  ( have() { return 1; }; snmp_report_block 1.2.3.4 public ) | grep -q 'not installed' \
    && printf '  ok: %s\n' "report_block: missing snmpwalk -> not-installed note" \
    || { printf '  FAIL: %s\n' "report_block not-installed note"; echo x >>"$fails"; }
  assert_contains "$(snmp_report_block 1.2.3.4 public)" "## Switch 1.2.3.4 (SNMP v2c)" "report_block renders section header"
}
```

And the `run_test` calls:

```bash
run_test test_snmp_if_table
run_test test_snmp_report_block
```

- [ ] **Step 2: Run the suite**

Run: `bash tests/run.sh; echo "exit=$?"`
Expected: `ok:` lines for all SNMP assertions, `0 failure(s)`, `exit=0`.

- [ ] **Step 3: Lint the runner**

Run: `shellcheck -s bash tests/run.sh && echo CLEAN`
Expected: `CLEAN`. (Note: `${@: -1}` inside the `snmpwalk` stub is intentional; if shellcheck emits SC2124/SC2199-type noise, add a targeted disable with a comment — verify it actually fires first.)

- [ ] **Step 4: Commit**

```bash
git add tests/run.sh
git commit -m "test: cover snmp_if_table (incl. 10G fallback) + snmp_report_block

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: Integration (docs + push-netkit.sh)

**Files:**
- Modify: `CLAUDE.md:24-30` (Mandatory verification section)
- Modify: `README.md:22` (the verification bullet)
- Modify: `push-netkit.sh:30-36` (lint section → also run tests)

**Interfaces:**
- Consumes: `tests/run.sh` (Tasks 1-6).

- [ ] **Step 1: Add the test command to push-netkit.sh**

The lint block (lines 30-36) ends before `echo "▶ Copying…"`. After the shellcheck `fi` (line 36), add a test step:

```bash
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -s bash "$SRC"
else
  echo "  (shellcheck not installed locally — skipped; bash -n passed)"
fi

echo "▶ Running unit tests"
( cd "$HERE" && bash tests/run.sh )
```

(`$HERE` is the script's own dir, already computed near the top of `push-netkit.sh`; running from there lets `tests/run.sh` find `./netkit`. `set -e` in push-netkit.sh aborts the deploy if the tests exit non-zero.)

- [ ] **Step 2: Verify push-netkit.sh still lints clean and its test step works**

Run: `bash -n push-netkit.sh && shellcheck -s bash push-netkit.sh && echo CLEAN`
Expected: `CLEAN`.

Run: `( cd . && bash tests/run.sh >/dev/null 2>&1 ); echo "tests exit=$?"`
Expected: `tests exit=0`.

- [ ] **Step 3: Update CLAUDE.md "Mandatory verification"**

The section (around lines 24-30) shows the two lint commands in a fenced block. Add the test line to that block so it reads:

```bash
bash -n netkit                    # syntax check
shellcheck -s bash netkit         # lint
bash tests/run.sh                 # off-hardware unit tests (pure helpers)
```

- [ ] **Step 4: Update README.md verification bullet**

Line 22 currently reads:

```
- **Every change must pass both** `bash -n netkit` **and** `shellcheck -s bash netkit`
```

Change it to include the tests:

```
- **Every change must pass** `bash -n netkit`, `shellcheck -s bash netkit`, **and** `bash tests/run.sh`
```

- [ ] **Step 5: Commit**

```bash
git add CLAUDE.md README.md push-netkit.sh
git commit -m "ci: run tests/run.sh in push-netkit.sh; document in verification steps

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Final verification (after all tasks)

- [ ] `bash -n netkit && shellcheck -s bash netkit && echo CLEAN` → `CLEAN`.
- [ ] `shellcheck -s bash tests/run.sh && echo CLEAN` → `CLEAN`.
- [ ] `bash netkit version` → `netkit v4.3.0` (guard doesn't affect normal run).
- [ ] `bash tests/run.sh; echo "exit=$?"` → ends with `0 failure(s)` and `exit=0`; every `test_*` group prints `ok:` lines (the `devctl_emit hex` line may print `SKIP:` if `xxd` is absent).
- [ ] **Honest caveat to report:** the harness runs and passes on the dev machine (macOS). The functions it covers are pure/logic-only, so the coverage is meaningful off-hardware; the menu actions that drive real tools still require the Pi. Bench `bash tests/run.sh` on the Pi too before relying on it in `push-netkit.sh`.

## Notes for the implementer

- Tests run in subshells (`run_test` calls `( "$1" )`), so command stubs (`snmpwalk(){…}`) and global mutations (`SITE_*`, `G_SNMP_ARGS`, `site_dir`) never leak between tests.
- Do NOT name the dispatcher `run` — `netkit`'s own `run()` is in scope after sourcing.
- The failure tally relies on `$fails` (a mktemp path) being visible to subshells: it is, because a `( … )` subshell is a fork of the current shell and inherits all variables and functions (not just exported ones). Appends to that file from inside a subshell are seen by the parent's `wc -l`.
- Keep every new variable in `tests/run.sh` initialised — `set -uo pipefail` is in effect (inherited from `netkit`).
