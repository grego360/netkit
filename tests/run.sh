#!/usr/bin/env bash
# Off-hardware unit tests for netkit's pure helpers. Zero deps. Run from repo root:
#   bash tests/run.sh
# Sources netkit via the NETKIT_LIB guard, then exercises pure functions with
# subshell-isolated command stubs. Exit 0 = all pass; non-zero = a failure.

# Dynamic source: netkit defines functions we load conditionally; cannot be statically traced by shellcheck.
# shellcheck disable=SC1091
NETKIT_LIB=1 source ./netkit || { echo "cannot source ./netkit (run from repo root)"; exit 2; }

fails="$(mktemp)"; trap 'rm -f "$fails"' EXIT

assert_eq()       { if [ "$1" = "$2" ]; then printf '  ok: %s\n' "$3"; else printf '  FAIL: %s (want [%s] got [%s])\n' "$3" "$1" "$2"; echo x >>"$fails"; fi; }
assert_empty()    { if [ -z "$1" ]; then printf '  ok: %s\n' "$2"; else printf '  FAIL: %s (got [%s])\n' "$2" "$1"; echo x >>"$fails"; fi; }
assert_contains() { case "$1" in *"$2"*) printf '  ok: %s\n' "$3" ;; *) printf '  FAIL: %s (missing [%s])\n' "$3" "$2"; echo x >>"$fails" ;; esac; }
assert_rc()       { if [ "$1" = "$2" ]; then printf '  ok: %s\n' "$3"; else printf '  FAIL: %s (want rc %s got %s)\n' "$3" "$1" "$2"; echo x >>"$fails"; fi; }

# run_test, NOT run — netkit defines its own run() helper, which we just sourced.
run_test() { printf '== %s ==\n' "$1"; ( "$1" ); }

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

test_load_site() {
  local d; d="$(mktemp -d)"
  # shellcheck disable=SC2034
  NETKIT_CFG_DIR="$d"; site_dir="$d/sites"; mkdir -p "$site_dir"
  # shellcheck disable=SC2016
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

# shellcheck disable=SC2329,SC2034  # snmpwalk stub + G_SNMP_ARGS are used indirectly by the sourced snmp_if_table
test_snmp_if_table() {
  G_SNMP_ARGS=(-v2c -c public -t 2 -r 1)
  snmpwalk() {                       # synthetic rows keyed by trailing OID arg
    # shellcheck disable=SC2124
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

# shellcheck disable=SC2329  # have/snmpget/snmpwalk stubs are invoked indirectly by the sourced snmp_report_block
test_snmp_report_block() {
  have()     { return 0; }
  snmpget()  { return 0; }
  snmpwalk() { echo "x"; }
  assert_empty "$(snmp_report_block '')" "report_block: empty host -> no section"
  local out_ni
  out_ni="$( have() { return 1; }; snmp_report_block 1.2.3.4 public )"
  assert_contains "$out_ni" "not installed" "report_block: missing snmpwalk -> not-installed note"
  assert_contains "$(snmp_report_block 1.2.3.4 public)" "## Switch 1.2.3.4 (SNMP v2c)" "report_block renders section header"
}

test_on_console() {
  ( TERM=linux; unset NETKIT_CONSOLE; on_console ); assert_rc 0 "$?" "on_console: TERM=linux is the VT"
  ( TERM=tmux-256color NETKIT_CONSOLE=1; on_console ); assert_rc 0 "$?" "on_console: NETKIT_CONSOLE=1 inside tmux on the VT"
  ( TERM=xterm-256color; unset NETKIT_CONSOLE; on_console ); assert_rc 1 "$?" "on_console: xterm is not the VT"
}

test_vt_plain() {
  assert_eq "Discovery"        "$( TERM=linux; unset NETKIT_CONSOLE; vt_plain '🔍 Discovery' )"   "vt_plain strips emoji on the VT"
  assert_eq "Site - none"      "$( TERM=linux; unset NETKIT_CONSOLE; vt_plain '🏷 Site — none' )" "vt_plain maps em dash to hyphen on the VT"
  assert_eq "🔍 Discovery"     "$( TERM=xterm; unset NETKIT_CONSOLE; vt_plain '🔍 Discovery' )"   "vt_plain leaves headers alone off the VT"
}

test_ui_glyphs() {
  local vt; vt="$( TERM=linux; unset NETKIT_CONSOLE; NO_COLOR=1; ui_glyphs_init; ok hi; bad no; printf '%s' "$G_CUR" )"
  assert_contains "$vt" "+ hi" "ui_glyphs: ok() uses ASCII tick on the VT"
  assert_contains "$vt" "x no" "ui_glyphs: bad() uses ASCII cross on the VT"
  assert_contains "$vt" "> "   "ui_glyphs: menu cursor is ASCII on the VT"
  local tty; tty="$( TERM=xterm; unset NETKIT_CONSOLE; NO_COLOR=1; ui_glyphs_init; ok hi )"
  assert_contains "$tty" "✓ hi" "ui_glyphs: ok() keeps the Unicode tick off the VT"
}

test_autostart_block() {
  local b; b="$(autostart_block)"
  assert_contains "$b" "# >>> netkit autostart >>>" "autostart_block: opening marker"
  assert_contains "$b" "# <<< netkit autostart <<<" "autostart_block: closing marker"
  assert_contains "$b" '"$(tty)" = "/dev/tty1"'     "autostart_block: only fires on tty1"
  assert_contains "$b" 'SSH_TTY'                     "autostart_block: never fires over SSH"
  assert_contains "$b" 'export NETKIT_CONSOLE=1'     "autostart_block: marks the console for glyph fallback"
  assert_contains "$b" 'exec tmux new-session -A -s netkit netkit' "autostart_block: wraps netkit in a tmux session"
  assert_contains "$b" 'exec netkit'                 "autostart_block: falls back to bare netkit without tmux"
}

test_run_dash_nested() {
  have()       { [ "$1" = tmux ]; }
  need_iface() { return 0; }
  tmux()       { printf 'tmux %s\n' "$*"; }
  IFACE=eth0; GW=10.0.0.1
  local nested; nested="$( TMUX=/tmp/tmux-1/default,1,0; run_dash )"
  assert_contains "$nested" "new-window" "run_dash inside tmux opens a window in the current session"
  case "$nested" in *"attach"*) printf '  FAIL: run_dash inside tmux must not nest attach\n'; echo x >>"$fails" ;; *) printf '  ok: run_dash inside tmux does not nest attach\n' ;; esac
  local top; top="$( unset TMUX; run_dash )"
  assert_contains "$top" "new-session -d -s netkit-dash" "run_dash outside tmux creates its own session"
  assert_contains "$top" "attach -t netkit-dash"         "run_dash outside tmux attaches to it"
}

# PocketTerm35 hardware probes read sysfs/procfs only; point them at a fake tree.
test_hw_check() {
  local root; root="$(mktemp -d)"
  NETKIT_SYS="$root/sys"; NETKIT_PROC="$root/proc"
  mkdir -p "$NETKIT_SYS/class/drm/card1-HDMI-A-1" "$NETKIT_PROC/bus/input" "$NETKIT_PROC/device-tree/cooling_fan" \
           "$NETKIT_SYS/class/thermal/thermal_zone0" "$NETKIT_SYS/class/rtc/rtc0" "$NETKIT_SYS/class/power_supply" "$NETKIT_SYS/class/hwmon"
  echo connected > "$NETKIT_SYS/class/drm/card1-HDMI-A-1/status"; echo 640x480 > "$NETKIT_SYS/class/drm/card1-HDMI-A-1/modes"
  printf 'N: Name="My Company My Custom Pico Keyboard"\nN: Name="Goodix Capacitive TouchScreen"\n' > "$NETKIT_PROC/bus/input/devices"
  printf 'disabled\0' > "$NETKIT_PROC/device-tree/cooling_fan/status"
  echo 61150 > "$NETKIT_SYS/class/thermal/thermal_zone0/temp"
  echo rpi-rtc > "$NETKIT_SYS/class/rtc/rtc0/name"
  have() { [ "$1" = rpi-eeprom-config ]; }
  rpi-eeprom-config() { printf 'NET_INSTALL_AT_POWER_ON=1\n'; }
  local out; out="$(hw_check)"
  assert_contains "$out" "display HDMI-A-1 connected 640x480" "hw: display connector + mode"
  assert_contains "$out" "touch Goodix"                       "hw: Goodix touch present"
  assert_contains "$out" "keyboard Pico"                      "hw: Pico USB keyboard present"
  assert_contains "$out" "fan NOT detected"                   "hw: fan disabled in device-tree is flagged"
  assert_contains "$out" "rtc rpi-rtc"                        "hw: RTC named"
  assert_contains "$out" "battery not exposed"                "hw: no power_supply -> battery warning"
  assert_contains "$out" "SoC 61"                             "hw: SoC temperature in C"
  assert_contains "$out" "NET_INSTALL_AT_POWER_ON=1"          "hw: EEPROM net-install flagged"
  assert_contains "$out" "PSU_MAX_CURRENT unset"              "hw: EEPROM PSU cap flagged"
  # healthy variants
  printf 'okay\0' > "$NETKIT_PROC/device-tree/cooling_fan/status"
  mkdir -p "$NETKIT_SYS/class/hwmon/hwmon3"; echo pwmfan > "$NETKIT_SYS/class/hwmon/hwmon3/name"; echo 3200 > "$NETKIT_SYS/class/hwmon/hwmon3/fan1_input"
  assert_contains "$(hw_fan)" "fan 3200 rpm" "hw: fan rpm from hwmon"
  mkdir -p "$NETKIT_SYS/class/power_supply/bat"; echo Battery > "$NETKIT_SYS/class/power_supply/bat/type"
  echo 77 > "$NETKIT_SYS/class/power_supply/bat/capacity"; echo Discharging > "$NETKIT_SYS/class/power_supply/bat/status"
  assert_contains "$(hw_battery)" "battery 77% Discharging" "hw: battery capacity + status"
  rpi-eeprom-config() { printf 'NET_INSTALL_AT_POWER_ON=0\nPSU_MAX_CURRENT=5000\n'; }
  assert_contains "$(hw_eeprom)" "PSU_MAX_CURRENT=5000" "hw: EEPROM settings applied"
  echo disconnected > "$NETKIT_SYS/class/drm/card1-HDMI-A-1/status"
  assert_contains "$(hw_display)" "display HDMI-A-1 disconnected" "hw: display disconnected is flagged"
  rm -rf "$root"
}

test_confirm() {
  have() { return 1; }   # plain-read path (gum confirm needs a tty)
  confirm "Go?" <<<"y";   assert_rc 0 "$?" "confirm: y -> yes"
  confirm "Go?" <<<"YES"; assert_rc 0 "$?" "confirm: YES -> yes"
  confirm "Go?" <<<"n";   assert_rc 1 "$?" "confirm: n -> no"
  confirm "Go?" <<<"";    assert_rc 1 "$?" "confirm: empty -> no (default)"
  confirm "Go?" <<<"Ny";  assert_rc 1 "$?" "confirm: stray text -> no"
}

test_sbin_on_path() {
  # Debian Trixie leaves /usr/sbin off a normal user's PATH; arp-scan, ethtool,
  # rfkill, iw, lldpcli, ptp4l live there, so netkit must add it itself.
  # PATH is set as a separate statement: a prefix on `source` does not persist.
  local out; out="$( PATH=/usr/local/bin:/usr/bin:/bin; NETKIT_LIB=1 source ./netkit; echo ":$PATH:" )"
  case "$out" in *:/usr/sbin:*) printf '  ok: %s\n' "sbin: /usr/sbin appended to PATH on load" ;; *) printf '  FAIL: sbin: /usr/sbin missing from PATH (%s)\n' "$out"; echo x >>"$fails" ;; esac
  case "$out" in *:/sbin:*)     printf '  ok: %s\n' "sbin: /sbin appended to PATH on load" ;;     *) printf '  FAIL: sbin: /sbin missing from PATH (%s)\n' "$out"; echo x >>"$fails" ;; esac
  out="$( PATH=/usr/sbin:/usr/bin; NETKIT_LIB=1 source ./netkit; echo "$PATH" )"
  assert_eq "/usr/sbin:/usr/bin:/usr/local/sbin:/sbin" "$out" "sbin: dirs already present are not duplicated"
}

test_menu_height() {
  assert_eq 24 "$(menu_height 30 0)" "menu_height: 30 rows, no banner -> 24"
  assert_eq 14 "$(menu_height 20 0)" "menu_height: 20 rows (24x12 console font) -> 14"
  assert_eq 16 "$(menu_height 22 0)" "menu_height: 22 rows (foot 12pt) -> 16"
  assert_eq 24 "$(menu_height 60 1)" "menu_height: tall terminal with banner caps at 24"
  assert_eq 19 "$(menu_height 30 1)" "menu_height: banner costs 5 rows"
  assert_eq 5  "$(menu_height 8 0)"  "menu_height: never below 5"
  menu_show_banner 40; assert_rc 0 "$?" "menu_show_banner: 40 rows shows the banner"
  menu_show_banner 30; assert_rc 1 "$?" "menu_show_banner: 30 rows (panel) hides it"
}

test_tmux_tune() {
  tmux() { printf 'tmux %s\n' "$*"; }
  tput() { echo "${FAKE_ROWS:-50}"; }
  assert_empty "$( unset TMUX; tmux_tune )" "tmux_tune: no-op outside tmux"
  assert_contains "$( TMUX=x NETKIT_CONSOLE=1 tmux_tune )" "set-option status off" "tmux_tune: hides the bar on the console"
  assert_contains "$( TMUX=x FAKE_ROWS=22 tmux_tune )"     "set-option status off" "tmux_tune: hides the bar on a short terminal"
  assert_empty "$( TMUX=x FAKE_ROWS=50 tmux_tune )" "tmux_tune: keeps the bar on a tall terminal"
}

test_autostart_block_kiosk() {
  local b; b="$(autostart_block)"
  assert_contains "$b" 'command -v cage'                     "autostart_block: kiosk only when cage is installed"
  assert_contains "$b" 'cage -- foot -e tmux new-session -A -s netkit netkit' "autostart_block: cage runs foot running the tmux-wrapped netkit"
  assert_contains "$b" '-lt 5'                               "autostart_block: a fast-failing cage falls back to the console"
  assert_contains "$b" 'exec tmux new-session -A -s netkit netkit' "autostart_block: console path still present"
}

test_menu_default_label() {
  assert_eq "Alpha" "$(menu_default_label "-|── hdr ──" "a|Alpha" "b|Beta")" "menu_default_label skips the section header"
  assert_eq "Alpha" "$(menu_default_label "a|Alpha" "b|Beta")"              "menu_default_label: first item when no header"
  assert_empty "$(menu_default_label "-|── hdr ──")"                          "menu_default_label: only headers -> empty"
}

test_page_sudo_prime() {
  # sudo -v prompts for a password even under NOPASSWD (sudo 1.9.16), so page must
  # only fall back to it when a non-interactive sudo fails.
  clear() { :; }; pause() { :; }; tput() { echo 50; }; have() { return 1; }
  sudo() { printf 'sudo %s\n' "$*"; [ "$1" = -n ] && return "${SUDO_N_RC:-0}"; return 0; }
  local out; out="$( SUDO_N_RC=0 page sudo arp-scan --localnet )"
  assert_contains "$out" "sudo -n true" "page: primes with a non-interactive sudo first"
  case "$out" in *"sudo -v"*) printf '  FAIL: page: must not call sudo -v when NOPASSWD works\n'; echo x >>"$fails" ;; *) printf '  ok: page: no sudo -v when NOPASSWD works\n' ;; esac
  out="$( SUDO_N_RC=1 page sudo arp-scan --localnet )"
  assert_contains "$out" "sudo -v" "page: falls back to sudo -v when a password is needed"
}

test_arpscan_file_args() {
  local d; d="$(mktemp -d)"; : > "$d/oui.txt"
  assert_eq "--ouifile=$d/oui.txt" "$(arpscan_file_args "$d/oui.txt" "$d/missing.txt")" "arpscan_file_args: only existing files become flags"
  : > "$d/mac.txt"
  assert_eq "--ouifile=$d/oui.txt --macfile=$d/mac.txt" "$(arpscan_file_args "$d/oui.txt" "$d/mac.txt" | paste -sd" " -)" "arpscan_file_args: both files"
  assert_empty "$(arpscan_file_args "$d/none" "$d/none2")" "arpscan_file_args: nothing when neither exists"
  rm -rf "$d"
}

test_show_output() {
  clear() { :; }; pause() { echo PAUSED; }; tput() { echo 12; }; have() { return 1; }
  less() { echo "LESS:"; cat; }
  local out; out="$(show_output "my cmd" "$(printf 'l1\nl2\nl3')")"
  assert_contains "$out" "\$ my cmd" "show_output: inline shows the command title"
  assert_contains "$out" "PAUSED"   "show_output: inline waits for Enter"
  case "$out" in *LESS:*) printf '  FAIL: show_output: short text must not open the pager\n'; echo x >>"$fails" ;; *) printf '  ok: show_output: short text stays inline\n' ;; esac
  out="$(show_output "long cmd" "$(seq 1 20)")"
  assert_contains "$out" "LESS:"     "show_output: long text opens the pager"
  assert_contains "$out" "\$ long cmd" "show_output: pager content starts with the title"
  case "$out" in *PAUSED*) printf '  FAIL: show_output: pager path must not also pause\n'; echo x >>"$fails" ;; *) printf '  ok: show_output: pager path does not pause\n' ;; esac
  show_output "x" "kept" >/dev/null; assert_eq "kept" "$NETKIT_LAST_OUTPUT" "show_output: retains text for save_last_report"
}

run_test test_framing_socat
run_test test_framing_tio
run_test test_hex_norm
run_test test_devctl_valid_hex
run_test test_devctl_emit
run_test test_devctl_addr
run_test test_load_site
run_test test_load_device
run_test test_snmp_if_table
run_test test_snmp_report_block
run_test test_on_console
run_test test_vt_plain
run_test test_ui_glyphs
run_test test_autostart_block
run_test test_run_dash_nested
run_test test_hw_check
run_test test_confirm
run_test test_sbin_on_path
run_test test_menu_height
run_test test_tmux_tune
run_test test_autostart_block_kiosk
run_test test_menu_default_label
run_test test_page_sudo_prime
run_test test_arpscan_file_args
run_test test_show_output

n="$(wc -l <"$fails" | tr -d ' ')"
printf '\n%s failure(s)\n' "$n"
[ "$n" -eq 0 ]
