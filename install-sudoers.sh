#!/bin/bash
# One-time setup: lets KeepAwake run `sudo -n pmset -a disablesleep 0|1` without a password.
# Usage:  sudo ./install-sudoers.sh            install
#         sudo ./install-sudoers.sh --uninstall   restore sleep, remove login item, remove the rule
set -euo pipefail

F=/etc/sudoers.d/keepawake   # no "." in the name, or sudo skips it
LABEL=local.keepawake

if [[ $EUID -ne 0 ]]; then
  echo "Run: sudo $0 ${1:-}"; exit 1
fi

case "${1:-}" in
  ''|--uninstall) ;;
  *) echo "Usage: sudo $0 [--uninstall]"; exit 2 ;;
esac

U="${SUDO_USER:-}"
valid_user() { [[ -n "$U" && "$U" != "root" && "$U" =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ ]]; }

if [[ "${1:-}" == "--uninstall" ]]; then
  # Order matters: restore sleep first, stop the app while the rule still exists, remove the rule last.
  /usr/bin/pmset -a disablesleep 0 || true
  if valid_user; then
    uid=$(id -u "$U" 2>/dev/null || true)
    home=$(dscl . -read "/Users/$U" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
    [[ -n "$uid" ]] && { launchctl bootout "gui/$uid/$LABEL" 2>/dev/null || true; }
    [[ -n "$home" ]] && rm -f "$home/Library/LaunchAgents/$LABEL.plist"
  fi
  pkill -TERM -x KeepAwake 2>/dev/null || true
  sleep 1
  rm -f "$F"
  echo "Done: sleep restored, login item removed, $F removed."
  exit 0
fi

if ! valid_user; then
  echo "Run it with sudo from your own user account (not as root directly)."; exit 1
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
