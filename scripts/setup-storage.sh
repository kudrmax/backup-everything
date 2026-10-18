#!/bin/bash
# Protects Backup Everything copies: they live in a folder owned by a separate account, so the app can add copies but
# never delete or change them. Each step says what it does, shows its exact commands and asks before running them.
#   sudo setup-storage.sh "<folder>" | --undo "<folder>" | --uninstall
set -euo pipefail

ACCOUNT=_backupeverything
LIBEXEC=/usr/local/libexec/backup-everything
GATE="$LIBEXEC/backup-receiver"
RULE_FILE=/etc/sudoers.d/backup-everything
OWNER="${SUDO_USER:-}"
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
SKIPPED=()
usage() { echo "usage: sudo $0 \"<folder>\" | --undo \"<folder>\" | --uninstall"; exit 1; }
q() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
step() { echo; echo "$1"; local title=$1; shift; printf '+ %s\n' "$@"; read -rp "Run? [y/N] " a </dev/tty
  case "$a" in y|Y|yes) for c in "$@"; do eval "$c"; done ;; *) echo "skipped"; SKIPPED+=("$title") ;; esac; }
ran() { [ "${#SKIPPED[@]}" = 0 ] || [ "${SKIPPED[${#SKIPPED[@]}-1]}" != "$1" ]; }
finish() { echo; if [ "${#SKIPPED[@]}" = 0 ]; then echo "Done. Check in the app: Destinations → Setup."
  else echo "Skipped:"; printf '  %s\n' "${SKIPPED[@]}"; echo "Run the script again to finish."; fi; exit 0; }

case "$#:${1:-}" in
  1:--uninstall) MODE=uninstall ;;
  2:--undo) MODE=undo; FOLDER=$2 ;;
  1:[!-]*) MODE=protect; FOLDER=$1 ;;
  *) usage ;;
esac
[ "$(id -u)" = 0 ] && [ -n "$OWNER" ] && [ "$OWNER" != root ] || { echo "run it with sudo as your own user"; exit 1; }
if [ "$MODE" = uninstall ]; then
  if [ -e "$RULE_FILE" ]; then step "Remove the sudo rule: the app can no longer write copies." "/usr/bin/trash $RULE_FILE || mv $RULE_FILE $RULE_FILE.removed"; fi
  if [ -e "$LIBEXEC" ]; then step "Remove the receiver gate." "/usr/bin/trash $LIBEXEC"; fi
  if id "$ACCOUNT" >/dev/null 2>&1; then step "Remove the account $ACCOUNT (UID $(id -u "$ACCOUNT")); its folders \
show this number as owner until --undo." "dscl . -delete /Users/$ACCOUNT"; fi
  finish
fi

[ -d "$FOLDER" ] || { echo "$FOLDER is not there"; exit 1; }
FOLDER=$(cd "$FOLDER" && pwd -P)
OWNER_HOME=$(dscl -plist . -read "/Users/$OWNER" NFSHomeDirectory | plutil -extract 'dsAttrTypeStandard:NFSHomeDirectory.0' raw -)
case "$FOLDER" in
  /Volumes/*/*) VOLUME="/Volumes/$(echo "$FOLDER" | cut -d/ -f3)" ;;
  "$OWNER_HOME"/*) VOLUME="" ;;
  *) echo "$FOLDER is neither on an external disk nor inside your home folder"; exit 1 ;;
esac
if [ "$MODE" = undo ]; then
  step "The folder and everything in it become yours again; you can delete copies there." "chown -R $OWNER:staff $(q "$FOLDER")"
  finish
fi

[ -x /opt/homebrew/bin/rsync ] || { echo "rsync from Homebrew is missing: brew install rsync"; exit 1; }
SOURCE_GATE="$ROOT/Helpers/backup-receiver"
[ -x "$SOURCE_GATE" ] || SOURCE_GATE="$ROOT/BackupCore/.build/release/backup-receiver"
[ -x "$SOURCE_GATE" ] || { echo "the receiver gate is not built: build the app first (scripts/build-app.sh)"; exit 1; }
if ! id "$ACCOUNT" >/dev/null 2>&1; then
  ID=$(dscl . -list /Users UniqueID | awk '{print $2}' | sort -n | awk 'BEGIN{n=450} $1==n{n++} END{print n}')
  [ "$ID" -lt 500 ] || { echo "no free user ID between 450 and 499"; exit 1; }
  step "Create the account $ACCOUNT (ID $ID): it cannot log in and owns the copies." \
    "sysadminctl -addUser $ACCOUNT -UID $ID -roleAccount -shell /usr/bin/false -home /var/empty"
fi
id "$ACCOUNT" >/dev/null 2>&1 || { echo "the account $ACCOUNT is missing; the next steps need it"; exit 1; }
[ "$(stat -f %u /usr/local)" = 0 ] && [ "$(stat -f %u /usr/local/libexec 2>/dev/null || echo 0)" = 0 ] ||
  { echo "/usr/local is not owned by root; the sudo rule would not be safe"; exit 1; }
step "Install the receiver gate, owned by root: it lets rsync only add new copies, as $ACCOUNT." \
  "install -d -o root -g wheel -m 755 $LIBEXEC" "install -o root -g wheel -m 755 $(q "$SOURCE_GATE") $GATE"
RULE="$OWNER ALL=($ACCOUNT) NOPASSWD: $GATE"
step "Let $OWNER run the gate as $ACCOUNT without a password (the sudo rule)." \
  "RULE_TMP=\$(mktemp)" "printf '%s\\n' $(q "$RULE") > \"\$RULE_TMP\"" "visudo -cf \"\$RULE_TMP\"" \
  "install -o root -g wheel -m 440 \"\$RULE_TMP\" $RULE_FILE" "/usr/bin/trash \"\$RULE_TMP\" || true"
if [ -n "$VOLUME" ]; then
  step "Make $VOLUME honour file owners, so the protection holds there; this also makes the disk honour the owners \
recorded on every other file on it." "diskutil enableOwnership $(q "$VOLUME")"
fi
holds_data() { [ "$(stat -f %u "$1")" != "$2" ] && [ -n "$(ls -A "$1" | grep -Fvx .DS_Store)" ]; }
if holds_data "$FOLDER" "$(id -u "$ACCOUNT")"; then
  ITEMS=$(find "$FOLDER" -mindepth 1 | wc -l | tr -d ' ') || ITEMS="?"
  HANDOVER="Hand $FOLDER AND everything inside it ($ITEMS items, currently owned by $(stat -f %Su "$FOLDER")) to \
$ACCOUNT: you keep reading (files inside get read for the group, nobody but the account can write), you can no \
longer delete or change anything there without sudo (--undo gives it back). Folders without a .complete marker \
inside it will show in the app as unfinished attempts."
  COMMANDS=("chown -R $ACCOUNT:staff $(q "$FOLDER")" "chmod -R g+rX,go-w $(q "$FOLDER")" "chmod -R -N $(q "$FOLDER")" \
    "chmod 750 $(q "$FOLDER")")
else
  HANDOVER="Hand $FOLDER to $ACCOUNT: only it can write there, you keep reading through the group staff."
  COMMANDS=("chown $ACCOUNT:staff $(q "$FOLDER")" "chmod 750 $(q "$FOLDER")" "chmod -N $(q "$FOLDER")")
fi
step "$HANDOVER" "${COMMANDS[@]}"
if ran "$HANDOVER" && ! sudo -u "$ACCOUNT" /bin/test -r "$FOLDER" -a -w "$FOLDER" -a -x "$FOLDER"; then
  echo "the account cannot reach $FOLDER: a parent folder is private (700). Pick a folder outside Desktop, Documents, \
Downloads, or run: chmod o+x <parent>"
  echo "run: sudo $0 --undo $(q "$FOLDER") to take the folder back"; exit 1
fi
finish
