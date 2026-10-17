#!/bin/bash
# Protects Backup Everything copies: they live in a folder owned by a separate account, so the app can add copies but
# never delete or change them. Each step says what it does, shows its exact commands and asks before running them.
#   sudo setup-storage.sh "<empty folder>" | --undo "<folder>" | --uninstall
set -euo pipefail

ACCOUNT=_backupeverything
LIBEXEC=/usr/local/libexec/backup-everything
GATE="$LIBEXEC/backup-receiver"
RULE_FILE=/etc/sudoers.d/backup-everything
OWNER="${SUDO_USER:-}"
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
usage() { echo "usage: sudo $0 \"<empty folder>\" | --undo \"<folder>\" | --uninstall"; exit 1; }
q() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
step() { echo; echo "$1"; shift; printf '+ %s\n' "$@"; read -rp "Run? [y/N] " a </dev/tty
  if [ "$a" = y ]; then for c in "$@"; do eval "$c"; done; else echo "skipped"; fi; }

case "$#:${1:-}" in
  1:--uninstall) MODE=uninstall ;;
  2:--undo) MODE=undo; FOLDER=$2 ;;
  1:[!-]*) MODE=protect; FOLDER=$1 ;;
  *) usage ;;
esac
[ "$(id -u)" = 0 ] && [ -n "$OWNER" ] || { echo "run it with sudo as your own user"; exit 1; }
if [ "$MODE" = uninstall ]; then
  step "Remove the sudo rule: the app can no longer write copies." "/usr/bin/trash $RULE_FILE"
  step "Remove the receiver gate." "/usr/bin/trash $LIBEXEC"
  step "Remove the account $ACCOUNT; its folders show a number as owner until --undo." "dscl . -delete /Users/$ACCOUNT"
  exit 0
fi

[ -d "$FOLDER" ] || { echo "$FOLDER is not there"; exit 1; }
FOLDER=$(cd "$FOLDER" && pwd -P)
OWNER_HOME=$(dscl . -read "/Users/$OWNER" NFSHomeDirectory | awk '{print $2}')
case "$FOLDER" in
  /Volumes/*/*) VOLUME="/Volumes/$(echo "$FOLDER" | cut -d/ -f3)" ;;
  "$OWNER_HOME"/*) VOLUME="" ;;
  *) echo "$FOLDER is neither on an external disk nor inside your home folder"; exit 1 ;;
esac
if [ "$MODE" = undo ]; then
  step "The folder and everything in it become yours again; the app can then delete copies there." \
    "chown -R $OWNER:staff $(q "$FOLDER")"
  exit 0
fi

[ -x /opt/homebrew/bin/rsync ] || { echo "rsync from Homebrew is missing: brew install rsync"; exit 1; }
[ -z "$(ls -A "$FOLDER" | grep -Fvx .DS_Store)" ] || [ "$(stat -f %Su "$FOLDER")" = "$ACCOUNT" ] ||
  { echo "move your files out of $FOLDER first; the script protects an empty folder"; exit 1; }
SOURCE_GATE="$ROOT/Helpers/backup-receiver"
[ -x "$SOURCE_GATE" ] || SOURCE_GATE="$ROOT/BackupCore/.build/release/backup-receiver"
[ -x "$SOURCE_GATE" ] || { echo "the receiver gate is not built: build the app first (scripts/build-app.sh)"; exit 1; }
if ! id "$ACCOUNT" >/dev/null 2>&1; then
  ID=$(dscl . -list /Users UniqueID | awk '{print $2}' | sort -n | awk 'BEGIN{n=450} $1==n{n++} END{print n}')
  [ "$ID" -lt 500 ] || { echo "no free user ID between 450 and 499"; exit 1; }
  step "Create the account $ACCOUNT (ID $ID): it cannot log in and owns the copies." \
    "sysadminctl -addUser $ACCOUNT -UID $ID -roleAccount -shell /usr/bin/false -home /var/empty"
  id "$ACCOUNT" >/dev/null 2>&1 || { echo "the account $ACCOUNT is missing; the next steps need it"; exit 1; }
fi
step "Install the receiver gate, owned by root: it lets rsync only add new copies, as $ACCOUNT." \
  "install -d -o root -g wheel -m 755 $LIBEXEC" "install -o root -g wheel -m 755 $(q "$SOURCE_GATE") $GATE"
RULE="$OWNER ALL=($ACCOUNT) NOPASSWD: $GATE"
step "Let $OWNER run the gate as $ACCOUNT without a password (the sudo rule)." \
  "RULE_TMP=\$(mktemp)" "printf '%s\\n' $(q "$RULE") > \"\$RULE_TMP\"" "visudo -cf \"\$RULE_TMP\"" \
  "install -o root -g wheel -m 440 \"\$RULE_TMP\" $RULE_FILE" "/usr/bin/trash \"\$RULE_TMP\" || true"
if [ -n "$VOLUME" ]; then
  step "Make $VOLUME honour file owners, so the protection holds there." "diskutil enableOwnership $(q "$VOLUME")"
fi
step "Hand $FOLDER to $ACCOUNT: only it can write there, you keep reading through the group staff." \
  "chown $ACCOUNT:staff $(q "$FOLDER")" "chmod 750 $(q "$FOLDER")"
echo; echo "Done. Check in the app: Destinations → Setup."
