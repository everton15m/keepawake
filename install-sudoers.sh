#!/bin/bash
# One-time setup: lets KeepAwake run `sudo -n pmset -a disablesleep 0|1` without a password.
# Usage:  sudo ./install-sudoers.sh            install
#         sudo ./install-sudoers.sh --uninstall
set -euo pipefail

F=/etc/sudoers.d/keepawake   # no "." in the name, or sudo skips it

if [[ $EUID -ne 0 ]]; then
  echo "Run: sudo $0 ${1:-}"; exit 1
fi

if [[ "${1:-}" == "--uninstall" ]]; then
  rm -f "$F"; echo "Removed $F"; exit 0
fi

U="${SUDO_USER:-}"
if [[ -z "$U" || "$U" == "root" ]]; then
  echo "Run it with sudo from your own user account (not as root directly)."; exit 1
fi
if [[ ! "$U" =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ ]]; then
  echo "Unexpected username: $U"; exit 1
fi
if ! grep -q '^[#@]includedir.*sudoers.d' /etc/sudoers; then
  echo "/etc/sudoers has no includedir for sudoers.d; aborting."; exit 1
fi

tmp=$(mktemp)
ok=0
# On any failure after install, remove the file so sudo is never left in a bad state.
trap 'rm -f "$tmp"; [[ $ok == 1 ]] || rm -f "$F"' EXIT
echo "$U ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1" > "$tmp"

visudo -cf "$tmp" >/dev/null            # validate BEFORE installing: a bad file breaks sudo
install -m 0440 -o root -g wheel "$tmp" "$F"
visudo -c >/dev/null
if ! sudo -u "$U" sudo -n -l /usr/bin/pmset -a disablesleep 1 >/dev/null 2>&1; then   # smoke test, no side effects
  echo "Smoke test failed; removing $F"; exit 1   # trap removes the file
fi
ok=1
echo "OK: installed $F for user $U"
