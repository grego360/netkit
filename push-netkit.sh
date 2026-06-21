#!/usr/bin/env bash
# push-netkit.sh — deploy the local netkit script to the Raspberry Pi.
# Lints first (never ship a broken script), scp's to /tmp, then installs it to
# /usr/local/bin/netkit via sudo and prints the running version.
#
# Usage:  ./push-netkit.sh                 # use the default Pi below
#         ./push-netkit.sh user@host       # override target
#         NETKIT_PI=user@host ./push-netkit.sh
set -euo pipefail

PI="${1:-${NETKIT_PI:-terminosa@10.1.20.176}}"
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

echo "▶ Copying to $PI:/tmp/netkit"
scp "$SRC" "$PI:/tmp/netkit"

echo "▶ Installing to /usr/local/bin/netkit (sudo on the Pi)"
# -t forces a TTY so sudo on the Pi can prompt for its password.
ssh -t "$PI" 'sudo install -m 0755 /tmp/netkit /usr/local/bin/netkit \
  && head -1 /usr/local/bin/netkit \
  && /usr/local/bin/netkit version'

echo "✓ Deployed to $PI"
