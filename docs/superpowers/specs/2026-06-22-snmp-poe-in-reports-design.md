# SNMP/PoE in reports — design

**Date:** 2026-06-22
**Component:** `netkit` report generators (`gen_report`, `gen_sweep`)
**Status:** approved for planning

## Goal

Fold the existing interactive SNMP switch data (system summary, interface
status/speed table, PoE budget + per-port status) into the markdown reports so a
commissioning report can document the switch a site is plugged into — not just
the hosts on the wire.

## Locked decisions

- **SNMP v2c only.** Community strings live safely in the site profile; v3
  auth/priv passphrases must never sit in a plaintext `.conf`, so v3 stays
  interactive-only in the SNMP menu (`m_snmp`). No passphrase handling in reports.
- **Both generators.** The section is added to `gen_report` (snapshot) and
  `gen_sweep` (commissioning). It is skipped entirely when no target is
  configured, so the snapshot stays light by default.
- **Hybrid target sourcing.** Site config drives the silent CLI / Quick path;
  the interactive menu prompts with site defaults prefilled. Blank skips.

## Out of scope (YAGNI)

- SNMP v3 in reports.
- Live per-port traffic rates (`snmp_rate`) — not static-report material.
- Arbitrary-OID capture (`snmp_walk`) and subnet SNMP discovery (`snmp_scan`).
- Multiple switch targets per report (single target only).

## Architecture

### New site field: `SNMP_TARGET`

Switch IP for report SNMP. Community already exists as `SNMP_COMMUNITY` →
`SITE_SNMP_COMMUNITY`.

- Add `SITE_SNMP_TARGET=""` to **both** `SITE_*` reset blocks (the top-of-file
  init block and the reset at the head of `load_site`) so `set -u` is satisfied.
- Add `SNMP_TARGET) SITE_SNMP_TARGET="$val" ;;` to the `load_site` whitelist
  parser. The `.conf` remains whitelist-parsed, **never sourced** — security
  boundary unchanged.
- `site_new`: add a prompt
  `tgt="$(ask 'SNMP switch IP for reports (blank ok):' '')"` and write
  `echo "SNMP_TARGET=$tgt"` into the generated profile.
- `site_show` cats the file verbatim — no change needed.

### New helper: `snmp_report_block <host> <community>`

Emits a markdown section on stdout, or nothing. Self-contained; never aborts the
caller; never leaks stderr.

```
snmp_report_block() {
  local h="$1" comm="${2:-public}"
  [ -n "$h" ] || return 0                       # no target -> no section
  if ! have snmpwalk; then
    printf '## Switch (SNMP)\n```\nsnmp tools not installed (run: netkit setup)\n```\n'
    return 0
  fi
  G_SNMP_ARGS=(-v2c -c "$comm" -t 2 -r 1)
  unset SNMPCONFPATH 2>/dev/null || true        # force v2c; ignore any leftover v3 conf
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

Reuses `snmp_if_table` and `snmp_poe` **verbatim** (both read `G_SNMP_ARGS` and
print plain text suitable for fenced blocks). The reachability probe uses
`snmpget` (ships with the same `snmp` apt package as `snmpwalk`).

### Generator changes

`gen_report` and `gen_sweep` gain optional positional args:

```
local snmp_h="${1:-}" snmp_c="${2:-public}"
local snmp_section; snmp_section="$(snmp_report_block "$snmp_h" "$snmp_c")"
```

`$snmp_section` is interpolated into the heredoc **immediately after the LLDP
section** (LLDP identifies the switch/port; SNMP details that switch). When the
section string is empty the report simply has nothing there.

### Call sites

| Caller | Behaviour |
| --- | --- |
| CLI `netkit report` / `netkit sweep` | `gen_report "$SITE_SNMP_TARGET" "${SITE_SNMP_COMMUNITY:-public}"` — silent; no target → no section |
| ⚡ Quick → Full sweep (`quick_run sweep`) | same site-default call as CLI |
| Interactive `m_report → snap` / `sweep` | `report_snmp_prompt; gen_report "$RP_HOST" "$RP_COMM"` (host may be empty = skip) |

```
report_snmp_prompt() {                 # sets RP_HOST / RP_COMM for the caller
  RP_HOST="$(ask 'Switch IP for SNMP/PoE (blank = skip):' "${SITE_SNMP_TARGET:-}")"
  RP_COMM="${SITE_SNMP_COMMUNITY:-public}"
  [ -z "$RP_HOST" ] && return
  RP_COMM="$(ask 'SNMP community:' "${SITE_SNMP_COMMUNITY:-public}")"
  [ -z "$RP_COMM" ] && RP_COMM=public
}
```

`RP_HOST`/`RP_COMM` are new globals, initialised empty at the top for `set -u`.
The empty-host case unifies naturally: "no site target" and "user blanked the
prompt" both produce an empty host → no section.

## Error handling

- Every SNMP call is `2>/dev/null` and gated behind the `snmpget` probe.
- Tool absent, host unreachable, wrong community, or non-PoE switch all degrade
  to an explanatory line *inside* the report; the report always completes.
- `snmp_poe` already prints a "no PoE data" explanation for non-PoE switches.

## Testing

- **Mandatory:** `bash -n netkit` and `shellcheck -s bash netkit` produce zero
  output. State that it was linted.
- **Off-hardware (candidate for the unit-test track):** `snmp_report_block ""`
  must print nothing and return 0; `snmp_report_block "x" "y"` with `snmpwalk`
  stubbed-absent must print the "not installed" note.
- **Honest caveat:** not run against a real switch. Bench on the Pi against live
  SNMP gear before a client site.

## Docs touched

- `selftest`: add `snmpget` to the optional-extras list (same package as
  `snmpwalk`; the report probe depends on it).
- README: mention `SNMP_TARGET` in the site-profile and Reporting rows.
- CLAUDE.md: note the new site field where site profiles are described.
- Broader doc-drift cleanup (stale `runsh`, line counts, 4→5 matchers) stays in
  its own separate track.
