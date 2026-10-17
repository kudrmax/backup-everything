#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/BackupEverything.app"

swift build -c release --package-path "$ROOT/App"
BINARY="$(swift build -c release --package-path "$ROOT/App" --show-bin-path)/BackupEverything"
swift build -c release --package-path "$ROOT/BackupCore" --product backup-receiver
GATE="$(swift build -c release --package-path "$ROOT/BackupCore" --show-bin-path)/backup-receiver"

STAGE="$(mktemp -d)/BackupEverything.app"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Helpers" "$STAGE/Contents/Resources"
cp "$BINARY" "$STAGE/Contents/MacOS/BackupEverything"
cp "$GATE" "$STAGE/Contents/Helpers/backup-receiver"
install -m 755 "$ROOT/scripts/setup-storage.sh" "$STAGE/Contents/Resources/setup-storage.sh"
cp "$ROOT/App/Info.plist" "$STAGE/Contents/Info.plist"
# A persistent certificate lets macOS remember granted permissions (e.g. for Downloads) between builds.
# Without it the signature is ad-hoc: each build gets its own, and permissions are asked again.
IDENTITY="Backup Everything Local"
if security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
    codesign --force --sign "$IDENTITY" "$STAGE"
else
    echo "Certificate “$IDENTITY” not found — signing ad-hoc, macOS will ask for permissions after every build." >&2
    codesign --force --sign - "$STAGE"
fi

mkdir -p "$ROOT/dist"
if [ -e "$APP" ]; then
    trash "$APP"
fi
mv "$STAGE" "$APP"
echo "$APP"
