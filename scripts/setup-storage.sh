#!/bin/bash
# Prepares the Mac for protected copies: the backup account, the receiver gate, its sudo rule, and the destination folders.
# Run with sudo from the repository root. Every command is printed before it runs; --dry-run only prints.
set -euo pipefail

ACCOUNT="_backupeverything"
USER_NAME="${SUDO_USER:-$(id -un)}"
HOME_DIR=$(dscl . -read "/Users/$USER_NAME" NFSHomeDirectory | awk '{print $2}')
CONFIG="${BACKUP_EVERYTHING_HOME:-$HOME_DIR/BackupEverything}/config.json"
LIBEXEC="/usr/local/libexec/backup-everything"
RECEIVER="$LIBEXEC/backup-receiver"
SUDOERS="/etc/sudoers.d/backup-everything"
DRY_RUN=0
if [ "${1:-}" = "--dry-run" ]; then
  DRY_RUN=1
fi

run() {
  echo "+ $*"
  if [ "$DRY_RUN" = 0 ]; then
    "$@"
  fi
}

[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
[ -x /opt/homebrew/bin/rsync ] || { echo "rsync from Homebrew is missing: run 'brew install rsync' as $USER_NAME first"; exit 1; }

echo "== 1. backup account $ACCOUNT"
if ! id "$ACCOUNT" >/dev/null 2>&1; then
  run sysadminctl -addUser "$ACCOUNT" -fullName "Backup Everything" -roleAccount -shell /usr/bin/false -home /var/empty
fi

echo "== 2. receiver gate"
run sudo -u "$USER_NAME" swift build -c release --package-path BackupCore --product backup-receiver
run mkdir -p "$LIBEXEC"
run install -o root -g wheel -m 755 BackupCore/.build/release/backup-receiver "$RECEIVER"

echo "== 3. sudo rule with the binary's SHA-256"
if [ "$DRY_RUN" = 0 ]; then
  DIGEST=$(shasum -a 256 "$RECEIVER" | awk '{print $1}')
else
  DIGEST="<sha256 of the installed receiver>"
fi
RULE="$USER_NAME ALL=($ACCOUNT) NOPASSWD: sha256:$DIGEST $RECEIVER"
echo "+ write $SUDOERS: $RULE"
if [ "$DRY_RUN" = 0 ]; then
  printf '%s\n' "$RULE" > "$SUDOERS.tmp"
  visudo -cf "$SUDOERS.tmp"
  install -o root -g wheel -m 440 "$SUDOERS.tmp" "$SUDOERS"
  /opt/homebrew/bin/trash "$SUDOERS.tmp" 2>/dev/null || true
fi

echo "== 4. destinations from $CONFIG"
ROOTS=$(python3 -c '
import json, sys, os
config = json.load(open(sys.argv[1]))
for destination in config["destinations"]:
    print(os.path.expanduser(destination["kind"]["localFolder"]["path"]))
' "$CONFIG")

while IFS= read -r ROOT; do
  [ -n "$ROOT" ] || continue
  if ! PARENT=$(cd "$(dirname "$ROOT")" 2>/dev/null && pwd -P); then
    echo "skip $ROOT: parent folder is not there (disk not connected?)"
    continue
  fi
  ROOT="$PARENT/$(basename "$ROOT")"
  case "$ROOT" in
    /Volumes/*)
      VOLUME="/Volumes/$(echo "$ROOT" | cut -d/ -f3)"
      run diskutil enableOwnership "$VOLUME"
      ;;
  esac
  run mkdir -p "$ROOT"
  if [ -d "$ROOT" ]; then
    while IFS= read -r COPY; do
      if [ -e "$COPY/_unfinished" ] || [ -e "$COPY/.complete" ]; then
        continue
      fi
      run touch "$COPY/.complete"
    done < <(find "$ROOT" -mindepth 2 -maxdepth 2 -type d -name '20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]_[0-9][0-9][0-9][0-9][0-9][0-9]*')
  fi
  run chown -R "$ACCOUNT:staff" "$ROOT"
  run chmod 755 "$ROOT"
done <<< "$ROOTS"

echo "== done. Check in the app: Destinations → Setup."
