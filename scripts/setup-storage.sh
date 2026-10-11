#!/bin/bash
# Prepares the Mac for protected copies: the backup account, the receiver gate, its sudo rule, and the destination folders.
# Run with sudo as your own user. Every command is printed before it runs; --dry-run only prints.
set -euo pipefail

cd "$(dirname "$0")/.."

ACCOUNT="_backupeverything"
USER_NAME="${SUDO_USER:-$(id -un)}"
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

is_dangerous_root() {
  if [ "$1" = "/" ] || [ "$1" = "$HOME_REAL" ]; then
    return 0
  fi
  case "$HOME_REAL/" in
    "$1"/*) return 0 ;;
  esac
  return 1
}

[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
[ "$USER_NAME" != "root" ] || { echo "run as your own user with sudo, not as root"; exit 1; }
[ -x /opt/homebrew/bin/rsync ] || { echo "rsync from Homebrew is missing: run 'brew install rsync' as $USER_NAME first"; exit 1; }

HOME_DIR=$(dscl . -read "/Users/$USER_NAME" NFSHomeDirectory | awk '{print $2}')
HOME_REAL=$(cd "$HOME_DIR" && pwd -P)
CONFIG="${BACKUP_EVERYTHING_HOME:-$HOME_DIR/BackupEverything}/config.json"

echo "== 1. backup account $ACCOUNT"
if ! id "$ACCOUNT" >/dev/null 2>&1; then
  run sysadminctl -addUser "$ACCOUNT" -fullName "Backup Everything" -roleAccount -shell /usr/bin/false -home /var/empty
  if [ "$DRY_RUN" = 0 ]; then
    id "$ACCOUNT" >/dev/null 2>&1 || { echo "the account $ACCOUNT was not created"; exit 1; }
  fi
fi

echo "== 2. receiver gate"
run sudo -H -u "$USER_NAME" swift build -c release --package-path BackupCore --product backup-receiver
run mkdir -p "$LIBEXEC"
run install -o root -g wheel -m 755 BackupCore/.build/release/backup-receiver "$RECEIVER"

echo "== 3. sudo rule with the binary's SHA-256"
trap 'if [ -e "$SUDOERS.tmp" ]; then /opt/homebrew/bin/trash "$SUDOERS.tmp" 2>/dev/null || true; fi' EXIT
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
fi

echo "== 4. destinations from $CONFIG"
ROOTS=$(python3 -c '
import json, sys, os
config = json.load(open(sys.argv[1]))
home = sys.argv[2]
for destination in config["destinations"]:
    kind = destination.get("kind", {})
    if "localFolder" not in kind:
        print("skip destination %s: not a local folder" % destination.get("name", "?"), file=sys.stderr)
        continue
    path = kind["localFolder"]["path"]
    if path == "~" or path.startswith("~/"):
        path = home + path[1:]
    print(path)
' "$CONFIG" "$HOME_DIR")

while IFS= read -r ROOT; do
  [ -n "$ROOT" ] || continue
  case "$ROOT" in
    /Volumes/*)
      VOLUME="/Volumes/$(echo "$ROOT" | cut -d/ -f3)"
      if [ ! -d "$VOLUME" ]; then
        echo "skip $ROOT: disk not connected ($VOLUME is not there)"
        continue
      fi
      ;;
  esac
  if [ "$(basename "$ROOT")" = "/" ] || is_dangerous_root "$ROOT"; then
    echo "skip $ROOT: refusing to take over the root of the disk or your home folder"
    continue
  fi
  if ! PARENT=$(cd "$(dirname "$ROOT")" 2>/dev/null && pwd -P); then
    echo "skip $ROOT: parent folder is not there (disk not connected?)"
    continue
  fi
  ROOT="$PARENT/$(basename "$ROOT")"
  if [ -d "$ROOT" ]; then
    ROOT=$(cd "$ROOT" && pwd -P)
  fi
  if is_dangerous_root "$ROOT"; then
    echo "skip $ROOT: refusing to take over the root of the disk or your home folder"
    continue
  fi
  case "$ROOT" in
    /Volumes/*)
      if ! run diskutil enableOwnership "$VOLUME"; then
        echo "skip $ROOT: ownership cannot be enabled on $VOLUME (exFAT/FAT volumes do not support it)"
        continue
      fi
      ;;
  esac
  run mkdir -p "$ROOT"
  if [ -d "$ROOT" ]; then
    SYSTEM_LOCKED=$(find "$ROOT" \( -flags +schg -o -flags +sappnd \) 2>/dev/null | head -n 20 || true)
    if [ -n "$SYSTEM_LOCKED" ]; then
      echo "skip $ROOT: files with system flags cannot be unlocked from a normal boot, for example:"
      echo "$SYSTEM_LOCKED"
      continue
    fi
    while IFS= read -r LOCKED; do
      run chflags nouchg,nouappnd "$LOCKED"
    done < <(find "$ROOT" \( -flags +uchg -o -flags +uappnd \) 2>/dev/null)
    while IFS= read -r COPY; do
      if [ ! -e "$COPY/_snapshot.json" ] || [ -e "$COPY/_unfinished" ] || [ -e "$COPY/.complete" ]; then
        continue
      fi
      run touch "$COPY/.complete"
    done < <(find "$ROOT" -mindepth 2 -maxdepth 2 -type d -name '20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]_[0-9][0-9][0-9][0-9][0-9][0-9]*')
  fi
  echo "ownership of $ROOT and everything under it changes to $ACCOUNT:staff"
  run chown -R "$ACCOUNT:staff" "$ROOT"
  run chmod 755 "$ROOT"
done <<< "$ROOTS"

echo "== done. Check in the app: Destinations → Setup."
