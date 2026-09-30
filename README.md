# Backup Everything

Личное macOS-приложение для управления бэкапами: живёт в menu bar, бэкапит папки, результаты команд и ручные экспорты на диски и в облака (rclone), хранит копии по схеме GFS.

- `BackupCore/` — ядро без UI (Swift Package).
- `App/` — приложение (SwiftUI).
- `docs/superpowers/specs/` — спецификация.

## Сборка и запуск

```bash
./scripts/build-app.sh
open dist/BackupEverything.app
```

Нужны Xcode 16+, macOS 15+. Для облачных назначений: `brew install rclone`.

## Тесты

```bash
swift test --package-path BackupCore
swift test --package-path App
```

## Данные

Настройки, история и шаблоны: `~/BackupEverything/`. Рабочие файлы: `~/Library/Application Support/BackupEverything/`.
