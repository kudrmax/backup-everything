# Backup Everything

Личное macOS-приложение для бэкапов. Живёт в menu bar, по расписанию копирует папки, результаты команд и ручные экспорты на диски и в папки, хранит версии по GFS и показывает, что просрочено. Копии — обычные папки, которые пишет rsync; приложение не может их удалить или изменить: папка назначения принадлежит отдельной учётке, и это гарантирует файловая система, а не код.

## Как устроено

- `BackupCore/` — ядро без UI (Swift Package, macOS 14+): источники, расписание, доставка, правило хранения, работа с rsync.
- `BackupCore/Sources/backup-receiver/` — шлюз `backup-receiver`: единственная программа, которой разрешено писать в назначения от служебной учётки.
- `App/` — приложение на SwiftUI (macOS 15+): menu bar и окно с разделами Overview, Sources, Destinations, History, Settings.
- `scripts/build-app.sh` — сборка `.app`.
- `scripts/setup-storage.sh` — установка хранилища (учётка, шлюз, правило sudo, права на папку назначения).
- `docs/superpowers/specs/` — спецификации: `2026-09-30-backup-manager-design.md` (поведение) и `2026-10-07-storage-rework-design.md` (хранение копий и защита).

Источник — список шагов: “Copy folder”, “Run command”, “Get a file from you”, “Connect device”. Шаблоны источников (GitHub, Obsidian, Bitwarden, Google Photos, Claude и другие) лежат файлами в `~/BackupEverything/templates/`. Назначение одного типа: папка, в том числе на внешнем диске. Облачных назначений нет: они убраны при переработке хранения и вернутся отдельной задачей.

## Хранение копий

```
<папка назначения>/            принадлежит _backupeverything
    <slug источника>/
        2026-10-07_143000/     готовая копия: файлы и пустой файл-метка .complete
        2026-10-08_143000/     неизменившиеся файлы — жёсткие ссылки на прошлую копию
        2026-10-09_143000/     без .complete — прерванная попытка
```

- Копирует rsync 3.5 из Homebrew с `--link-dest`: неизменившиеся файлы не копируются, а становятся жёсткими ссылками на прошлую копию.
- Отправитель rsync работает от пользователя, получатель — от скрытой учётки `_backupeverything` через шлюз `backup-receiver` по правилу sudo без пароля. Шлюз сверяет аргументы с allow-list и запускает `rsync --server`; команд удаления у него нет.
- Папка с `.complete` — полноценная копия, откуда бы она ни взялась: ручные бэкапы и копии прошлых версий приложения достаточно положить как `<slug>/<дата>/` и создать в них метку.
- Копии сверх правила хранения приложение только показывает в разделе Destinations → “Excess copies” вместе с командой удаления; удаляет пользователь сам.
- Изменить или удалить копию руками можно только с паролем администратора (Finder его спросит, `sudo` тоже). У приложения такого пути нет.

## Сборка и запуск

Нужны Xcode 16+, macOS 15+, `brew install rsync trash`.

```bash
./scripts/build-app.sh
```

```bash
open dist/BackupEverything.app
```

Сборка кладёт в `dist/BackupEverything.app` приложение, шлюз (`Contents/Helpers/backup-receiver`) и скрипт установки (`Contents/Resources/setup-storage.sh`), подписывает бандл и отправляет предыдущую сборку в Корзину.

## Установка хранилища

Один раз на каждую папку назначения. Папка должна существовать и не лежать внутри Desktop, Documents, Downloads и других приватных папок (`700`): служебная учётка до неё не дойдёт. Что именно не хватает каждой папке, приложение показывает в полосе “Setup” раздела Destinations вместе с готовой командой.

```bash
sudo dist/BackupEverything.app/Contents/Resources/setup-storage.sh "<папка назначения>"
```

Скрипт идёт по шагам, перед каждым печатает точные команды и спрашивает `Run? [y/N]`: учётка `_backupeverything`, шлюз в `/usr/local/libexec/backup-everything/`, правило в `/etc/sudoers.d/backup-everything`, учёт владельцев на внешнем диске (`diskutil enableOwnership`), передача папки учётке. Содержимое папки переносить не нужно: оно остаётся на месте и попадает под защиту.

Вернуть папку себе или убрать всё:

```bash
sudo dist/BackupEverything.app/Contents/Resources/setup-storage.sh --undo "<папка>"
```

```bash
sudo dist/BackupEverything.app/Contents/Resources/setup-storage.sh --uninstall
```

## Тесты

```bash
swift test --package-path BackupCore
```

```bash
swift test --package-path App
```

## Данные

- `~/BackupEverything/` — `config.json`, `state.json`, `history/`, `templates/`, `icons/`. Папка бэкапится как обычный источник “Backup Everything settings”.
- `~/Library/Application Support/BackupEverything/` — рабочие файлы: `pending/` (пакеты для назначений, которых не было на связи), `staging/`, `chains/`, `scratch/`.
- Секретов в настройках нет: команды берут их из Связки ключей или из авторизации утилит (`bw`, `gh`).
