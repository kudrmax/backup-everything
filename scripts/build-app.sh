#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/BackupEverything.app"

swift build -c release --package-path "$ROOT/App"
BINARY="$(swift build -c release --package-path "$ROOT/App" --show-bin-path)/BackupEverything"

STAGE="$(mktemp -d)/BackupEverything.app"
mkdir -p "$STAGE/Contents/MacOS"
cp "$BINARY" "$STAGE/Contents/MacOS/BackupEverything"
cp "$ROOT/App/Info.plist" "$STAGE/Contents/Info.plist"
codesign --force --sign - "$STAGE"

mkdir -p "$ROOT/dist"
if [ -e "$APP" ]; then
    trash "$APP"
fi
mv "$STAGE" "$APP"
echo "$APP"
