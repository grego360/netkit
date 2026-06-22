# SNMP/PoE in Reports Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fold v2c SNMP switch data (system summary, interface table, PoE budget) into `netkit`'s markdown reports, driven by site config silently or by interactive prompt.

**Architecture:** A new `snmp_report_block <host> <community>` helper renders a markdown section (or nothing when no host) by reusing the existing `snmp_if_table` and `snmp_poe` functions over a v2c session. `gen_report`/`gen_sweep` gain optional `[host] [community]` args; the CLI/Quick paths pass site defaults, the interactive menu prompts with site defaults prefilled. `snmp_if_table` is upgraded to fall back to `ifHighSpeed` for 10G+ links.

**Tech Stack:** bash (`set -uo pipefail`), net-snmp CLI (`snmpget`/`snmpwalk` from Debian `snmp` package), awk.

## Global Constraints

- `set -uo pipefail` (no `-e`). Every new global MUST be initialised so `set -u` is satisfied.
- Both `bash -n netkit` AND `shellcheck -s bash netkit` MUST produce **zero output** before any commit. State that it was linted.
- `printf` format strings containing markdown fences (```` ``` ````) MUST be **single-quoted** so backticks stay literal (no command substitution). Values pass as `%s` args.
- `.conf` files are whitelist-parsed, **never sourced** — do not change that boundary.
- apt-first; no new compiled dependencies. `snmpget`/`snmpwalk` ship in the existing `snmp` package.
- Runs as normal user; SNMP reads need no sudo.
- Reuse `snmp_if_table` / `snmp_poe` verbatim from `snmp_report_block` (DRY) — do not reimplement their walks.
- Source of truth is the `netkit` script; line numbers below are anchors that may drift as edits land — re-grep if a hunk doesn't match.

---

### Task 1: Add the `SNMP_TARGET` site field

**Files:**
- Modify: `netkit:221-222` (top-level `SITE_*` init block)
- Modify: `netkit:232-233` (the `SITE_*` reset block inside `load_site`)
- Modify: `netkit:243-254` (the `load_site` whitelist `case`)
- Modify: `netkit:265-289` (`site_new` — prompt + writer)

**Interfaces:**
- Produces: global `SITE_SNMP_TARGET` (string, "" when unset), populated by `load_site` from a `SNMP_TARGET=` line in the active site `.conf`. Consumed by Tasks 4 and 5.

- [ ] **Step 1: Add the global to the top-level init block**

In `netkit` around line 221-222, the block reads:

```bash
SITE_SMTP=""; SITE_SMTP_PORT=""; SITE_SNMP_COMMUNITY=""; SITE_MQTT=""
SITE_SPEED_MIN=""; SITE_DNS_DOMAIN=""; SITE_HTTP_URL=""; SITE_PEER=""; SITE_LOGO=""
```

Change the first line to add `SITE_SNMP_TARGET=""`:

```bash
SITE_SMTP=""; SITE_SMTP_PORT=""; SITE_SNMP_COMMUNITY=""; SITE_SNMP_TARGET=""; SITE_MQTT=""
SITE_SPEED_MIN=""; SITE_DNS_DOMAIN=""; SITE_HTTP_URL=""; SITE_PEER=""; SITE_LOGO=""
```

- [ ] **Step 2: Add the same reset inside `load_site`**

Around line 232-233 the identical reset block appears inside `load_site()`. Apply the exact same edit (add `SITE_SNMP_TARGET=""` after `SITE_SNMP_COMMUNITY=""`):

```bash
  SITE_SMTP=""; SITE_SMTP_PORT=""; SITE_SNMP_COMMUNITY=""; SITE_SNMP_TARGET=""; SITE_MQTT=""
  SITE_SPEED_MIN=""; SITE_DNS_DOMAIN=""; SITE_HTTP_URL=""; SITE_PEER=""; SITE_LOGO=""
```

- [ ] **Step 3: Parse the field in the `load_site` whitelist**

In the `case "$key" in` block (around line 244-253), after the `SNMP_COMMUNITY)` line, add a new case:

```bash
      SNMP_COMMUNITY) SITE_SNMP_COMMUNITY="$val" ;;
      SNMP_TARGET) SITE_SNMP_TARGET="$val" ;;
```

- [ ] **Step 4: Add the prompt and writer to `site_new`**

In `site_new()`, after the community prompt line `comm="$(ask 'SNMP community:' 'public')"` (around line 271), add:

```bash
  tgt="$(ask 'SNMP switch IP for reports (blank ok):' '')"
```

Add `tgt` to the function's `local` declaration line (line 266, `local name smtp port comm mqtt spd dom url peer logo`):

```bash
  local name smtp port comm tgt mqtt spd dom url peer logo
```

Then in the writer heredoc-style block (around line 282), change the SNMP line to also write the target:

```bash
    echo "SMTP=$smtp"; echo "SMTP_PORT=$port"; echo "SNMP_COMMUNITY=$comm"
    echo "SNMP_TARGET=$tgt"
```

- [ ] **Step 5: Lint**

Run: `bash -n netkit && shellcheck -s bash netkit && echo CLEAN`
Expected: `CLEAN` (zero lint output above it).

- [ ] **Step 6: Spot-check the parse end-to-end**

Run:

```bash
mkdir -p /tmp/nkcfg/sites && printf 'SNMP_TARGET=10.0.0.9\nSNMP_COMMUNITY=secret\n' > /tmp/nkcfg/sites/t.conf && echo t > /tmp/nkcfg/active-site
XDG_CONFIG_HOME=/tmp/nkcfg bash -c 'source <(sed -n "/^load_site()/,/^}/p" ./netkit); NETKIT_CFG_DIR=/tmp/nkcfg/netkit site_dir=/tmp/nkcfg/netkit/sites; mkdir -p "$site_dir"; cp /tmp/nkcfg/sites/t.conf "$site_dir/"; echo t > "$NETKIT_CFG_DIR/active-site"; load_site; echo "target=[$SITE_SNMP_TARGET] comm=[$SITE_SNMP_COMMUNITY]"'
```

Expected: `target=[10.0.0.9] comm=[secret]`. (If the harness is awkward, a manual grep that the new `SNMP_TARGET)` case exists is acceptable — the real gate is Step 5.)

- [ ] **Step 7: Commit**

```bash
git add netkit
git commit -m "feat(site): add SNMP_TARGET field for report SNMP/PoE

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Upgrade `snmp_if_table` for high-speed links + fix PoE label

**Files:**
- Modify: `netkit:1033-1049` (`snmp_if_table`)
- Modify: `netkit:1056` (`snmp_poe` cosmetic label)

**Interfaces:**
- Produces: `snmp_if_table <host>` — unchanged signature; now prints correct speed (e.g. `10G`) for interfaces whose `ifSpeed` is at the 32-bit cap, using `ifHighSpeed`. Consumed by Task 3.

- [ ] **Step 1: Write the failing test**

```bash
cat > /tmp/nk_iftest.sh <<'EOF'
G_SNMP_ARGS=(-v2c -c public -t 2 -r 1)
snmpwalk() {                       # stub: synthetic rows keyed by trailing OID arg
  local oid="${@: -1}"
  case "$oid" in
    1.3.6.1.2.1.2.2.1.2)     echo ".1.3.6.1.2.1.2.2.1.2.1 TenGigE0/1" ;;   # ifDescr
    1.3.6.1.2.1.2.2.1.8)     echo ".1.3.6.1.2.1.2.2.1.8.1 1" ;;            # ifOperStatus=up
    1.3.6.1.2.1.2.2.1.5)     echo ".1.3.6.1.2.1.2.2.1.5.1 4294967295" ;;   # ifSpeed=capped
    1.3.6.1.2.1.31.1.1.1.15) echo ".1.3.6.1.2.1.31.1.1.1.15.1 10000" ;;    # ifHighSpeed=10000 Mbps
  esac
}
source <(sed -n '/^snmp_if_table()/,/^}/p' ./netkit)
snmp_if_table 1.2.3.4
EOF
bash /tmp/nk_iftest.sh
```

- [ ] **Step 2: Run it to confirm it FAILS (current behaviour)**

Run: `bash /tmp/nk_iftest.sh`
Expected (before the fix): the row shows `4294967295` in the speed column (the `ifHighSpeed` walk is not consulted).

- [ ] **Step 3: Apply the `ifHighSpeed` fix**

Replace the pipeline + awk in `snmp_if_table` (lines 1037-1048) with this (adds a 4th walk and `hspd` handling):

```bash
  {
    "${SW[@]}" 1.3.6.1.2.1.2.2.1.2; echo "---S---"
    "${SW[@]}" 1.3.6.1.2.1.2.2.1.8; echo "---S---"
    "${SW[@]}" 1.3.6.1.2.1.2.2.1.5; echo "---S---"
    "${SW[@]}" 1.3.6.1.2.1.31.1.1.1.15
  } | awk '
    /---S---/ { sect++; next }
    { idx=$1; sub(/.*\./,"",idx); v=$2; for(i=3;i<=NF;i++) v=v" "$i
      if(sect==0) name[idx]=v; else if(sect==1) oper[idx]=v; else if(sect==2) spd[idx]=v; else hspd[idx]=v; seen[idx]=1 }
    END{ for(i in seen){
      s=oper[i]+0; st=(s==1?"up":s==2?"down":s==3?"testing":s==7?"lowerdn":"?")
      sp=spd[i]+0; hsp=hspd[i]+0
      if(sp>=4294967295 || sp==0){ if(hsp>0) sp=hsp*1e6 }
      if(sp>=1e9) hs=sprintf("%gG",sp/1e9); else if(sp>=1e6) hs=sprintf("%gM",sp/1e6); else hs=sp
      printf "%-6s %-26s %-8s %s\n", i, name[i], st, hs } }' | sort -n
```

- [ ] **Step 4: Run the test to confirm it PASSES**

Run: `bash /tmp/nk_iftest.sh`
Expected: the row now reads `1      TenGigE0/1                 up       10G`.

- [ ] **Step 5: Fix the cosmetic PoE label**

In `snmp_poe` at line 1056, change `pethMainPseConsumption` to `pethMainPseConsumptionPower` (the real RFC 3621 object name; OID unchanged):

```bash
  printf 'consumed (pethMainPseConsumptionPower): '; "${SW[@]}" 1.3.6.1.2.1.105.1.3.1.1.4 2>/dev/null | awk '{print $2}' | paste -sd' ' -
```

- [ ] **Step 6: Lint**

Run: `bash -n netkit && shellcheck -s bash netkit && echo CLEAN`
Expected: `CLEAN`.

- [ ] **Step 7: Commit**

```bash
git add netkit
git commit -m "fix(snmp): ifHighSpeed fallback for 10G+ links; correct PoE label

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Add the `snmp_report_block` helper

**Files:**
- Modify: `netkit` — insert a new function immediately after `snmp_poe` ends (after line ~1066, before the `snmp_rate` function at 1068)
- Test: `/tmp/nk_blocktest.sh` (throwaway)

**Interfaces:**
- Consumes: `snmp_if_table`, `snmp_poe` (Task 2), `have`, the `snmpget`/`snmpwalk` binaries, global `G_SNMP_ARGS`.
- Produces: `snmp_report_block <host> <community>` — prints a markdown section to stdout (`## Switch <host> (SNMP v2c)` with `### System`/`### Interfaces`/`### PoE` fenced blocks), or nothing when `<host>` is empty. Always returns 0; never leaks stderr. Consumed by Task 4.

- [ ] **Step 1: Write the failing test**

```bash
cat > /tmp/nk_blocktest.sh <<'EOF'
have() { return 0; }
snmpget() { return 0; }              # host reachable
snmpwalk() { echo "sysDescr ..."; }
snmp_if_table() { echo "iface table"; }
snmp_poe() { echo "poe table"; }
G_SNMP_ARGS=()
source <(sed -n '/^snmp_report_block()/,/^}/p' ./netkit)
out="$(snmp_report_block '')";        [ -z "$out" ] && echo "PASS empty" || echo "FAIL empty: [$out]"
have() { return 1; }
snmp_report_block 1.2.3.4 public | grep -q 'not installed' && echo "PASS notinstalled" || echo "FAIL notinstalled"
have() { return 0; }
snmp_report_block 1.2.3.4 public | grep -q '## Switch 1.2.3.4 (SNMP v2c)' && echo "PASS render" || echo "FAIL render"
EOF
bash /tmp/nk_blocktest.sh
```

- [ ] **Step 2: Run it to confirm it FAILS**

Run: `bash /tmp/nk_blocktest.sh`
Expected: the `sed` extraction finds nothing (function not added yet), so `snmp_report_block` is undefined → "command not found" errors / FAIL lines.

- [ ] **Step 3: Add the function**

Insert this block immediately after the closing `}` of `snmp_poe` (line ~1066), before `snmp_rate()`:

```bash
# snmp_report_block <host> <community> -> markdown switch section on stdout (v2c).
# Empty host -> nothing. Never aborts the caller; never leaks stderr. Reuses
# snmp_if_table + snmp_poe (both read G_SNMP_ARGS and print plain text).
snmp_report_block() {
  local h="$1" comm="${2:-public}"
  [ -n "$h" ] || return 0
  if ! have snmpwalk; then
    printf '## Switch (SNMP)\n```\nsnmp tools not installed (run: netkit setup)\n```\n'
    return 0
  fi
  G_SNMP_ARGS=(-v2c -c "$comm" -t 2 -r 1)
  unset SNMPCONFPATH 2>/dev/null || true   # drop the v3 conf in NETKIT_CFG_DIR off the search path (the -v2c flag forces the version)
  if ! snmpget "${G_SNMP_ARGS[@]}" "$h" 1.3.6.1.2.1.1.5.0 >/dev/null 2>&1; then
    printf '## Switch %s (SNMP v2c)\n```\nno SNMP response (check IP / community / v2c enabled)\n```\n' "$h"
    return 0
  fi
  local sys ifs poe
  sys="$(snmpwalk "${G_SNMP_ARGS[@]}" "$h" 1.3.6.1.2.1.1 2>/dev/null)"
  ifs="$(snmp_if_table "$h" 2>/dev/null)"
  poe="$(snmp_poe "$h" 2>/dev/null)"
  printf '## Switch %s (SNMP v2c)\n\n### System\n```\n%s\n```\n\n### Interfaces\n```\n%s\n```\n\n### PoE\n```\n%s\n```\n' \
    "$h" "$sys" "$ifs" "$poe"
}
```

- [ ] **Step 4: Run the test to confirm it PASSES**

Run: `bash /tmp/nk_blocktest.sh`
Expected three lines: `PASS empty`, `PASS notinstalled`, `PASS render`.

- [ ] **Step 5: Lint**

Run: `bash -n netkit && shellcheck -s bash netkit && echo CLEAN`
Expected: `CLEAN`.

- [ ] **Step 6: Commit**

```bash
git add netkit
git commit -m "feat(report): add snmp_report_block (v2c switch/PoE markdown section)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Wire the section into `gen_report` and `gen_sweep`

**Files:**
- Modify: `netkit:1558-1614` (`gen_report`)
- Modify: `netkit:1616-1694` (`gen_sweep`)

**Interfaces:**
- Consumes: `snmp_report_block` (Task 3).
- Produces: `gen_report [host] [community]` and `gen_sweep [host] [community]` — both accept optional SNMP target args; with no args (or empty host) the report has no Switch section. Consumed by Task 5.

- [ ] **Step 1: Add params + section capture to `gen_report`**

In `gen_report` (line 1558), the head is:

```bash
gen_report() {
  need_iface || return
  local dir f ts; dir="$(report_dir)"; ts="$(date +%Y%m%d-%H%M)"; f="$dir/snapshot-$ts.md"
  clear
  echo "Gathering snapshot (arp-scan + nmap ping sweep)… a few seconds."
  local arp nmap_sn bt
```

Change the first `local` line to also read the args, and add a section-capture `local` after the `bt` line:

```bash
gen_report() {
  need_iface || return
  local snmp_h="${1:-}" snmp_c="${2:-public}"
  local dir f ts; dir="$(report_dir)"; ts="$(date +%Y%m%d-%H%M)"; f="$dir/snapshot-$ts.md"
  clear
  echo "Gathering snapshot (arp-scan + nmap ping sweep)… a few seconds."
  local arp nmap_sn bt snmp_section
  arp="$(sudo arp-scan --interface="$IFACE" --localnet 2>/dev/null | grep -E '^[0-9]' || echo 'arp-scan unavailable')"
  nmap_sn="$(sudo nmap -sn "${CIDR:-$IFACE}" 2>/dev/null | grep -E 'Nmap scan report' || echo 'nmap unavailable')"
  bt="$(bt_neighbourhood)"
  snmp_section="$(snmp_report_block "$snmp_h" "$snmp_c")"
```

(Only two real changes: the new `local snmp_h/snmp_c` line; appending `snmp_section` to the existing `local arp nmap_sn bt` and adding the `snmp_section="$(...)"` capture after the `bt=` line. The `arp=`/`nmap_sn=` lines are shown only for context — leave them as-is.)

- [ ] **Step 2: Insert the section into the `gen_report` heredoc after LLDP**

In the heredoc, find the LLDP block ending and the Bluetooth heading (around lines 1596-1601):

```
## LLDP neighbour (switch / port / VLAN)
\`\`\`
$(sudo lldpcli show neighbors 2>/dev/null || echo 'no LLDP neighbour seen')
\`\`\`

## Bluetooth neighbourhood
```

Insert `$snmp_section` between the LLDP closing fence and the Bluetooth heading:

```
## LLDP neighbour (switch / port / VLAN)
\`\`\`
$(sudo lldpcli show neighbors 2>/dev/null || echo 'no LLDP neighbour seen')
\`\`\`

$snmp_section

## Bluetooth neighbourhood
```

(When the target is unset, `$snmp_section` expands to empty — just blank lines, no heading.)

- [ ] **Step 3: Add params + section capture to `gen_sweep`**

In `gen_sweep` (line 1616), the head is:

```bash
gen_sweep() {
  need_iface || return
  local dir f ts; dir="$(report_dir)"; ts="$(date +%Y%m%d-%H%M)"; f="$dir/sweep-$ts.md"
  clear; echo "Running full sweep — this can take a minute…"
  local arp nmap_sn lldp dhcp wan hosts logo bt
```

Apply the same two changes: add the args line, append `snmp_section` to the `local` list, and capture it after the `bt="$(bt_neighbourhood)"` line (around line 1628):

```bash
gen_sweep() {
  need_iface || return
  local snmp_h="${1:-}" snmp_c="${2:-public}"
  local dir f ts; dir="$(report_dir)"; ts="$(date +%Y%m%d-%H%M)"; f="$dir/sweep-$ts.md"
  clear; echo "Running full sweep — this can take a minute…"
  local arp nmap_sn lldp dhcp wan hosts logo bt snmp_section
```

Then, immediately after the existing `bt="$(bt_neighbourhood)"` line, add:

```bash
  snmp_section="$(snmp_report_block "$snmp_h" "$snmp_c")"
```

- [ ] **Step 4: Insert the section into the `gen_sweep` heredoc after LLDP**

In the `gen_sweep` heredoc, find the LLDP block and the following `## WAN throughput` heading (around lines 1671-1677):

```
## LLDP neighbour (switch / port / VLAN)
\`\`\`
$lldp
\`\`\`

## WAN throughput
```

Insert `$snmp_section` between them:

```
## LLDP neighbour (switch / port / VLAN)
\`\`\`
$lldp
\`\`\`

$snmp_section

## WAN throughput
```

- [ ] **Step 5: Lint**

Run: `bash -n netkit && shellcheck -s bash netkit && echo CLEAN`
Expected: `CLEAN`.

- [ ] **Step 6: Verify no-arg backward compatibility (no Switch section)**

Run:

```bash
grep -n 'snmp_report_block "\$snmp_h" "\$snmp_c"' netkit
```

Expected: two matches (one in `gen_report`, one in `gen_sweep`). Full report generation can't run on this Mac (no `arp-scan`/`nmap`/live iface) — the gate is the lint above plus this wiring check. Behaviour: called with no args, `snmp_h=""` → `snmp_report_block` prints nothing → report omits the Switch section. Bench the full report on the Pi against a real switch before a client site.

- [ ] **Step 7: Commit**

```bash
git add netkit
git commit -m "feat(report): include SNMP/PoE switch section in snapshot + sweep

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Wire the call sites (CLI, Quick, interactive prompt)

**Files:**
- Modify: `netkit` — add globals `RP_HOST`/`RP_COMM` near `NETKIT_LAST_OUTPUT` (line ~188)
- Modify: `netkit` — add `report_snmp_prompt` just above `m_report` (line ~1317)
- Modify: `netkit:1327-1328` (`m_report` snap/sweep dispatch)
- Modify: `netkit:1965` (`quick_run` sweep)
- Modify: `netkit:2039-2040` (CLI dispatch report/sweep)

**Interfaces:**
- Consumes: `gen_report`/`gen_sweep` args (Task 4), `SITE_SNMP_TARGET` (Task 1), `SITE_SNMP_COMMUNITY`.
- Produces: globals `RP_HOST`/`RP_COMM` (set by `report_snmp_prompt`); the interactive report paths prompt, the CLI/Quick paths pass site defaults silently.

- [ ] **Step 1: Add the runtime globals**

Find `NETKIT_LAST_OUTPUT=""` (line ~188) and add directly below it:

```bash
NETKIT_LAST_OUTPUT=""
RP_HOST=""; RP_COMM=""   # interactive report SNMP target (set by report_snmp_prompt)
```

- [ ] **Step 2: Add `report_snmp_prompt` above `m_report`**

Immediately before `m_report() {` (line 1317), insert:

```bash
# report_snmp_prompt — interactive: set RP_HOST (blank = skip) + RP_COMM, prefilled
# from the active site. Used by the snapshot/sweep menu actions only; CLI/Quick
# pass site defaults silently.
report_snmp_prompt() {
  RP_HOST="$(ask 'Switch IP for SNMP/PoE (blank = skip):' "${SITE_SNMP_TARGET:-}")"
  RP_COMM="${SITE_SNMP_COMMUNITY:-public}"
  [ -z "$RP_HOST" ] && return
  RP_COMM="$(ask 'SNMP community:' "${SITE_SNMP_COMMUNITY:-public}")"
  [ -z "$RP_COMM" ] && RP_COMM=public
}
```

- [ ] **Step 3: Update the `m_report` snap/sweep dispatch**

At lines 1327-1328, change:

```bash
      snap) gen_report ;;
      sweep) gen_sweep ;;
```

to:

```bash
      snap) report_snmp_prompt; gen_report "$RP_HOST" "$RP_COMM" ;;
      sweep) report_snmp_prompt; gen_sweep "$RP_HOST" "$RP_COMM" ;;
```

- [ ] **Step 4: Update `quick_run` sweep (silent site defaults)**

At line ~1965, change:

```bash
    sweep)    gen_sweep ;;
```

to:

```bash
    sweep)    gen_sweep "$SITE_SNMP_TARGET" "${SITE_SNMP_COMMUNITY:-public}" ;;
```

- [ ] **Step 5: Update the CLI dispatch (silent site defaults)**

At lines 2039-2040, change:

```bash
  report) gen_report; exit 0 ;;
  sweep) gen_sweep; exit 0 ;;
```

to:

```bash
  report) gen_report "$SITE_SNMP_TARGET" "${SITE_SNMP_COMMUNITY:-public}"; exit 0 ;;
  sweep) gen_sweep "$SITE_SNMP_TARGET" "${SITE_SNMP_COMMUNITY:-public}"; exit 0 ;;
```

- [ ] **Step 6: Lint**

Run: `bash -n netkit && shellcheck -s bash netkit && echo CLEAN`
Expected: `CLEAN`. (Confirms no `set -u` violation — `RP_HOST`/`RP_COMM` are initialised in Step 1, and `SITE_SNMP_TARGET` exists from Task 1.)

- [ ] **Step 7: Verify the wiring**

Run:

```bash
grep -n 'report_snmp_prompt; gen_report\|report_snmp_prompt; gen_sweep\|gen_sweep "\$SITE_SNMP_TARGET"\|gen_report "\$SITE_SNMP_TARGET"' netkit
```

Expected: five matches — interactive snap (`report_snmp_prompt; gen_report`), interactive sweep (`report_snmp_prompt; gen_sweep`), quick sweep, CLI report, CLI sweep (the last three via `"$SITE_SNMP_TARGET"`).

- [ ] **Step 8: Commit**

```bash
git add netkit
git commit -m "feat(report): prompt SNMP target interactively, use site config for CLI/Quick

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Docs — selftest, README, CLAUDE.md

**Files:**
- Modify: `netkit:1807-1810` (`do_selftest` extras array)
- Modify: `README.md` (Reporting + Site-profile rows)
- Modify: `CLAUDE.md` (site-profile description)

**Interfaces:**
- Consumes: nothing. Documentation/diagnostics only.

- [ ] **Step 1: Add `snmpget` to the selftest extras**

In `do_selftest` the extras array (line 1807) begins:

```bash
  local x extras=(gping bandwhich xh librespeed-cli mosquitto_sub ethtool snmpwalk fping
```

Add `snmpget` after `snmpwalk` (the report reachability probe depends on it; same `snmp` package):

```bash
  local x extras=(gping bandwhich xh librespeed-cli mosquitto_sub ethtool snmpwalk snmpget fping
```

- [ ] **Step 2: Lint the script**

Run: `bash -n netkit && shellcheck -s bash netkit && echo CLEAN`
Expected: `CLEAN`.

- [ ] **Step 3: Update README**

In `README.md`, find the Reporting row of the category table (the line containing `📊 Reporting`) and the Site-profile row (`🏷 Site profile`). Update them to mention the new capability and field. Reporting row — append to its description:

```
, **switch SNMP/PoE section** (v2c; from the site's SNMP_TARGET or an interactive prompt)
```

Site-profile row — append:

```
, SNMP_TARGET (switch IP for report SNMP/PoE)
```

Also, in the site-profile prose/fields section (search for `SNMP_COMMUNITY`), add a line documenting `SNMP_TARGET` next to it:

```
- `SNMP_TARGET` — switch IP queried (v2c) for the report's switch/PoE section
```

- [ ] **Step 4: Update CLAUDE.md**

In `CLAUDE.md`, find the Site-profiles description (the bullet listing `SITE_*` fields / `load_site`). Add a short note that the whitelist now includes `SNMP_TARGET`:

```
`SNMP_TARGET` (switch IP for the report SNMP/PoE section) is among the whitelisted keys.
```

- [ ] **Step 5: Commit**

```bash
git add netkit README.md CLAUDE.md
git commit -m "docs: SNMP_TARGET site field, snmpget in selftest, report SNMP/PoE

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Final verification (after all tasks)

- [ ] `bash -n netkit && shellcheck -s bash netkit && echo CLEAN` → `CLEAN`.
- [ ] `bash /tmp/nk_iftest.sh` → speed shows `10G`.
- [ ] `bash /tmp/nk_blocktest.sh` → `PASS empty`, `PASS notinstalled`, `PASS render`.
- [ ] Clean up scratch files: `rm -f /tmp/nk_iftest.sh /tmp/nk_blocktest.sh; rm -rf /tmp/nkcfg`.
- [ ] **Honest caveat to report to the user:** linted + helper-tested off-hardware, NOT run against a real switch on aarch64. Bench `netkit report`/`netkit sweep` with a configured `SNMP_TARGET` on the Pi against live SNMP gear before a client site.

## Notes for the implementer

- This is a single self-contained bash file with no test framework. The `/tmp/nk_*.sh` harnesses extract one function via `sed` and `source` it with stubs — that is the off-hardware regression check; do not source the whole `netkit` (its main loop runs at the bottom).
- Every `printf` markdown-fence format string MUST stay single-quoted.
- Do not reimplement `snmp_if_table`/`snmp_poe` inside `snmp_report_block` — call them.
- Line numbers are anchors from the spec date; re-grep (`grep -n`) if a hunk doesn't match after earlier tasks shift lines.
```
