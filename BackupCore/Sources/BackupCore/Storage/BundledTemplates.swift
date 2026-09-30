import Foundation

enum BundledTemplates {
    static let all: [SourceTemplate] = [obsidian, github, bitwarden, applePasswords, googlePhotos, claude, claudeCode, iosFinance]

    private static let downloads = "~/Downloads"

    private static let obsidian = SourceTemplate(
        id: "obsidian",
        name: "Obsidian",
        kind: .folder(path: "~/Documents/Obsidian", excludes: [".trash", ".obsidian/workspace*.json"]),
        schedule: .daily,
        retention: .standard,
        description: "Все заметки и настройки хранилища, кроме корзины и состояния окон.",
        instructions: "Укажите путь к папке своего хранилища Obsidian."
    )

    private static let github = SourceTemplate(
        id: "github",
        name: "GitHub",
        kind: .command(
            command: #"""
            set -euo pipefail

            # Не бэкапить эти репозитории: по одному в строке, в виде владелец/имя
            IGNORE="
            "

            # Обрыв сети не должен губить весь запуск: каждый репозиторий пробуется до трёх раз
            clone() {
              local attempt
              for attempt in 1 2 3; do
                git -c credential.helper= -c credential.helper='!gh auth git-credential' clone --quiet --mirror "https://github.com/$1.git" "$2" && return 0
                sleep 10
              done
              return 1
            }

            repos=($(gh repo list --limit 1000 --json nameWithOwner --jq '.[].nameWithOwner' | { grep -vxF -f <(printf '%s\n' $=IGNORE) || true; }))
            n=0
            for repo in $repos; do
              n=$((n + 1))
              echo "$n из ${#repos} · $repo"
              clone "$repo" "$BACKUP_SCRATCH_DIR/$repo.git"
              mkdir -p "$BACKUP_OUTPUT_DIR/$(dirname "$repo")"
              git -C "$BACKUP_SCRATCH_DIR/$repo.git" bundle create --quiet "$BACKUP_OUTPUT_DIR/$repo.bundle" --all || [ -z "$(git -C "$BACKUP_SCRATCH_DIR/$repo.git" for-each-ref)" ]
            done
            """#,
            timeoutSeconds: 3600
        ),
        schedule: .weekly,
        retention: RetentionRules(daily: 0, weekly: 4, monthly: 6, yearly: 0),
        description: "Все твои репозитории. Каждый сохраняется одним файлом .bundle со всей историей. Восстановление: git clone имя.bundle",
        instructions: """
        Один раз выполните в терминале:

        1. `brew install gh`
        2. `gh auth login`

        Чтобы пропустить репозитории, впишите их в `IGNORE` в начале команды — по одному в строке, в виде `владелец/имя`.
        """
    )

    private static let bitwarden = SourceTemplate(
        id: "bitwarden",
        name: "Bitwarden",
        kind: .command(
            command: #"""
            set -euo pipefail
            export BW_PASSWORD="$(security find-generic-password -s backup-everything-bitwarden -w)"
            export BW_SESSION="$(bw unlock --raw --passwordenv BW_PASSWORD)"
            bw sync
            bw export --format json --output "$BACKUP_OUTPUT_DIR/bitwarden.json"
            """#,
            timeoutSeconds: 300
        ),
        schedule: .weekly,
        retention: RetentionRules(daily: 0, weekly: 8, monthly: 12, yearly: 0),
        description: "Все записи хранилища паролей одним файлом JSON. Экспорт не зашифрован — направляйте его только в назначения, которым доверяете.",
        instructions: """
        Один раз выполните в терминале:

        1. `brew install bitwarden-cli`
        2. `bw login`
        3. `security add-generic-password -s backup-everything-bitwarden -a bitwarden -w` — введите мастер-пароль, он сохранится в Связке ключей.
        """
    )

    private static let applePasswords = SourceTemplate(
        id: "apple-passwords",
        name: "Пароли (macOS)",
        kind: .manualExport(watchPath: downloads, filePattern: "Passwords*.csv", fileMode: .single, removeOriginal: true),
        schedule: .monthly,
        retention: RetentionRules(daily: 0, weekly: 0, monthly: 12, yearly: 0),
        description: "Все пароли из приложения «Пароли» одним файлом CSV. Файл не зашифрован — направляйте его только в назначения, которым доверяете.",
        instructions: """
        1. Откройте приложение «Пароли».
        2. Файл → Экспортировать все пароли в файл…
        3. Сохраните файл в «Загрузки», не меняя имя.

        Приложение заберёт его из «Загрузок» само.
        """
    )

    private static let googlePhotos = SourceTemplate(
        id: "google-photos",
        name: "Google Photos",
        kind: .manualExport(watchPath: downloads, filePattern: "takeout-*.zip", fileMode: .multiple, removeOriginal: true),
        schedule: .monthly,
        retention: RetentionRules(daily: 0, weekly: 0, monthly: 3, yearly: 0),
        description: "Все фото и видео из Google Фото — архивы Google Takeout.",
        instructions: """
        1. Откройте https://takeout.google.com
        2. Нажмите «Отменить выбор» и отметьте только Google Фото.
        3. Формат .zip, размер частей 50 ГБ, «Создать экспорт».
        4. Когда придёт письмо, скачайте все части в «Загрузки».
        5. Когда все части скачаны, нажмите «Готово, забрать».
        """
    )

    private static let claude = SourceTemplate(
        id: "claude",
        name: "Claude",
        kind: .manualExport(watchPath: downloads, filePattern: "data-*.zip", fileMode: .single, removeOriginal: true),
        schedule: .monthly,
        retention: RetentionRules(daily: 0, weekly: 0, monthly: 12, yearly: 0),
        description: "Все чаты и данные аккаунта Claude одним архивом.",
        instructions: """
        1. Откройте https://claude.ai → Settings → Privacy → Export data.
        2. Дождитесь письма со ссылкой и скачайте архив в «Загрузки».

        Если имя архива не начинается с `data-`, поправьте маску файла в настройках источника.
        """
    )

    private static let claudeCode = SourceTemplate(
        id: "claude-code",
        name: "Claude Code",
        kind: .command(
            command: #"""
            set -euo pipefail
            src="$HOME/.claude"

            # Ссылки в никуда пропускаются, остальные ссылки заменяются настоящими файлами
            (cd "$src" && find -L . -type l | sed 's|^\.||') > "$BACKUP_SCRATCH_DIR/broken-links"

            rsync -aL --exclude-from="$BACKUP_SCRATCH_DIR/broken-links" \
              --exclude '/downloads/' --exclude '/cache/' --exclude '/plugins/cache/' --exclude '/plugins/marketplaces/' \
              --exclude '/telemetry/' --exclude '/statsig/' --exclude '/debug/' --exclude '/shell-snapshots/' \
              --exclude '/session-env/' --exclude '/sessions/' --exclude '/paste-cache/' --exclude '/ide/' --exclude '/jobs/' \
              --exclude '/daemon*' --exclude '/backups/' --exclude '/.credentials.json' --exclude '*-cache.json' \
              --exclude '.DS_Store' --exclude '/.last-cleanup' \
              "$src/" "$BACKUP_OUTPUT_DIR/dot-claude/" || [ $? -eq 24 ]

            if [ -f "$HOME/.claude.json" ]; then cp "$HOME/.claude.json" "$BACKUP_OUTPUT_DIR/dot-claude.json"; fi
            """#,
            timeoutSeconds: 900
        ),
        schedule: .weekly,
        retention: RetentionRules(daily: 0, weekly: 4, monthly: 6, yearly: 0),
        description: "Настройки, инструкции CLAUDE.md, навыки, память и история сессий Claude Code: папка ~/.claude и файл ~/.claude.json. Кэши и загрузки не копируются. В настройках могут быть ключи MCP-серверов — направляйте только в назначения, которым доверяете.",
        instructions: """
        Настраивать ничего не нужно.

        Восстановление: папку `dot-claude` скопировать в `~/.claude`, файл `dot-claude.json` — в `~/.claude.json`, затем войти заново командой `claude /login`.
        """
    )

    private static let iosFinance = SourceTemplate(
        id: "ios-finance",
        name: "Финансы (iOS)",
        kind: .manualExport(watchPath: downloads, filePattern: "", fileMode: .single, removeOriginal: true),
        schedule: .monthly,
        retention: RetentionRules(daily: 0, weekly: 0, monthly: 24, yearly: 0),
        description: "Выгрузка операций из приложения финансов на iPhone в CSV.",
        instructions: """
        1. В приложении на iPhone откройте экспорт данных в CSV.
        2. Отправьте файл на Mac через AirDrop — он попадёт в «Загрузки».

        Обязательно укажите маску файла по имени, которое даёт ваше приложение, например `MoneyManager*.csv`. Пока маска пустая, ничего не подхватывается. Маску `*.csv` не используйте: под неё попадут любые CSV, включая экспорт паролей.
        """
    )
}
