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

run_test test_framing_socat
run_test test_framing_tio
run_test test_hex_norm
run_test test_devctl_valid_hex
run_test test_devctl_emit
run_test test_devctl_addr

n="$(wc -l <"$fails" | tr -d ' ')"
printf '\n%s failure(s)\n' "$n"
[ "$n" -eq 0 ]
