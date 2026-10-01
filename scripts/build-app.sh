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
# Постоянный сертификат нужен, чтобы macOS помнила выданные разрешения (например, на «Загрузки») между сборками.
# Без него подпись ad-hoc: она у каждой сборки своя, и разрешения спрашиваются заново.
IDENTITY="Backup Everything Local"
if security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
    codesign --force --sign "$IDENTITY" "$STAGE"
else
    echo "Сертификат «$IDENTITY» не найден — подпись ad-hoc, разрешения macOS будут спрашиваться после каждой сборки." >&2
    codesign --force --sign - "$STAGE"
fi

mkdir -p "$ROOT/dist"
if [ -e "$APP" ]; then
    trash "$APP"
fi
mv "$STAGE" "$APP"
echo "$APP"
