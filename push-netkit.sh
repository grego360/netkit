#!/usr/bin/env bash
# push-netkit.sh — deploy the local netkit script to the Raspberry Pi.
# Lints first (never ship a broken script), scp's to /tmp, then installs it to
# /usr/local/bin/netkit via sudo and prints the running version.
#
# Usage:  ./push-netkit.sh                 # local Pi (default)
#         ./push-netkit.sh local           # local Pi, explicit (SSH alias "terminosa")
#         ./push-netkit.sh remote          # remote Pi (pocket-term-rpi)
#         ./push-netkit.sh user@host       # literal target override
#         NETKIT_PI=user@host ./push-netkit.sh   # override the default (no-arg) target
set -euo pipefail

PI_LOCAL="terminosa"                  # ~/.ssh/config alias (HostName, User, IdentityFile live there)
PI_REMOTE="terminosa@pocket-term-rpi" # hostname-resolved address (VPN / SSH config / mDNS)

# Resolve the target: a bare 'local'/'remote' picks a known Pi; anything else is
# treated as a literal user@host; no arg keeps the env-override-or-local default.
case "${1:-}" in
  "")      PI="${NETKIT_PI:-$PI_LOCAL}" ;;
  local)   PI="$PI_LOCAL" ;;
  remote)  PI="$PI_REMOTE" ;;
  *)       PI="$1" ;;
esac

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/netkit"

[ -f "$SRC" ] || { echo "netkit not found next to this script ($SRC)"; exit 1; }

echo "▶ Linting $SRC"
bash -n "$SRC"
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -s bash "$SRC"
else
  echo "  (shellcheck not installed locally — skipped; bash -n passed)"
fi

echo "▶ Running unit tests"
( cd "$HERE" && bash tests/run.sh )

echo "▶ Copying to $PI:/tmp/netkit"
scp "$SRC" "$PI:/tmp/netkit"

echo "▶ Installing to /usr/local/bin/netkit (sudo on the Pi)"
# -t forces a TTY so sudo on the Pi can prompt for its password.
ssh -t "$PI" 'sudo install -m 0755 /tmp/netkit /usr/local/bin/netkit \
  && head -1 /usr/local/bin/netkit \
  && /usr/local/bin/netkit version'

echo "✓ Deployed to $PI"
