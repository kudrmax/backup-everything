#!/bin/bash
# Protects a destination folder: the backup account, the receiver gate, its sudo rule, and the folder handed to the account.
# Run with sudo as your own user: sudo scripts/setup-storage.sh "/Volumes/Disk/Backups". Every command is printed before it runs; --dry-run only prints.
set -euo pipefail
cd "$(dirname "$0")/.."

ACCOUNT="_backupeverything"
USER_NAME="${SUDO_USER:-}"
RECEIVER="/usr/local/libexec/backup-everything/backup-receiver"
SUDOERS="/etc/sudoers.d/backup-everything"
DRY_RUN=0
if [ "${1:-}" = "--dry-run" ]; then
  DRY_RUN=1
  shift
fi
FOLDER="${1:-}"

run() {
  echo "+ $*"
  [ "$DRY_RUN" = 1 ] || "$@"
}

[ "$(id -u)" = 0 ] && [ -n "$USER_NAME" ] || { echo "run as your own user with sudo"; exit 1; }
[ -n "$FOLDER" ] || { echo "usage: sudo scripts/setup-storage.sh [--dry-run] <destination folder>"; exit 1; }
[ -d "$FOLDER" ] || { echo "$FOLDER is not there: create the folder first"; exit 1; }
[ -x /opt/homebrew/bin/rsync ] || { echo "rsync from Homebrew is missing: brew install rsync"; exit 1; }
FOLDER=$(cd "$FOLDER" && pwd -P)
USER_HOME=$(eval echo "~$USER_NAME")
case "$FOLDER" in
  /Volumes/*/*) VOLUME="/Volumes/$(echo "$FOLDER" | cut -d/ -f3)" ;;
  "$USER_HOME"/*) VOLUME="" ;;
  *) echo "$FOLDER is neither on an external disk nor inside your home folder"; exit 1 ;;
esac

echo "== 1. backup account $ACCOUNT"
id "$ACCOUNT" >/dev/null 2>&1 || run sysadminctl -addUser "$ACCOUNT" -fullName "Backup Everything" -roleAccount -shell /usr/bin/false -home /var/empty

echo "== 2. receiver gate"
run sudo -H -u "$USER_NAME" swift build -c release --package-path BackupCore --product backup-receiver
run mkdir -p "$(dirname "$RECEIVER")"
run install -o root -g wheel -m 755 BackupCore/.build/release/backup-receiver "$RECEIVER"

echo "== 3. sudo rule: $USER_NAME may run the gate as $ACCOUNT without a password"
DIGEST=$({ shasum -a 256 "$RECEIVER" 2>/dev/null || echo "<sha256 of the installed gate>"; } | awk '{print $1}')
RULE="$USER_NAME ALL=($ACCOUNT) NOPASSWD: sha256:$DIGEST $RECEIVER"
echo "+ $SUDOERS: $RULE"
if [ "$DRY_RUN" = 0 ]; then
  printf '%s\n' "$RULE" > "$SUDOERS.tmp"
  visudo -cf "$SUDOERS.tmp"
  install -o root -g wheel -m 440 "$SUDOERS.tmp" "$SUDOERS"
  /opt/homebrew/bin/trash "$SUDOERS.tmp" || true
fi

echo "== 4. hand $FOLDER to $ACCOUNT"
[ -z "$VOLUME" ] || run diskutil enableOwnership "$VOLUME"
run chown -R "$ACCOUNT:staff" "$FOLDER"
run chmod 755 "$FOLDER"

echo "== done. Check in the app: Destinations → Setup."
