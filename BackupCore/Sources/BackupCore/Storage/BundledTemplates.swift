import Foundation

enum BundledTemplates {
    static let all: [SourceTemplate] = [obsidian, github, bitwarden, applePasswords, googlePhotos, claude, iosFinance]

    private static let downloads = "~/Downloads"

    private static let obsidian = SourceTemplate(
        id: "obsidian",
        name: "Obsidian",
        kind: .folder(path: "~/Documents/Obsidian", excludes: [".trash", ".obsidian/workspace*.json"]),
        schedule: .daily,
        retention: .standard,
        instructions: "Укажите путь к папке хранилища Obsidian. Копируются все заметки и настройки, кроме корзины и состояния окон."
    )

    private static let github = SourceTemplate(
        id: "github",
        name: "GitHub",
        kind: .command(
            command: #"""
            set -euo pipefail
            gh repo list --limit 1000 --json nameWithOwner --jq '.[].nameWithOwner' | while read -r repo; do
              gh repo clone "$repo" "$BACKUP_SCRATCH_DIR/$repo.git" -- --quiet --mirror
              mkdir -p "$BACKUP_OUTPUT_DIR/$(dirname "$repo")"
              git -C "$BACKUP_SCRATCH_DIR/$repo.git" bundle create "$BACKUP_OUTPUT_DIR/$repo.bundle" --all || [ -z "$(git -C "$BACKUP_SCRATCH_DIR/$repo.git" for-each-ref)" ]
            done
            """#,
            timeoutSeconds: 3600
        ),
        schedule: .weekly,
        retention: RetentionRules(daily: 0, weekly: 4, monthly: 6, yearly: 0),
        instructions: """
        Один раз выполните в терминале:

        1. `brew install gh`
        2. `gh auth login`

        Каждый репозиторий сохраняется одним файлом `.bundle` со всей историей. Восстановление: `git clone имя.bundle`.

        Чтобы бэкапить только часть репозиториев, замените `gh repo list …` на `printf '%s\\n' owner/repo1 owner/repo2`.
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
        instructions: """
        Один раз выполните в терминале:

        1. `brew install bitwarden-cli`
        2. `bw login`
        3. `security add-generic-password -s backup-everything-bitwarden -a bitwarden -w` — введите мастер-пароль, он сохранится в Связке ключей.

        Экспорт не зашифрован. Направляйте его только в назначения, которым доверяете.
        """
    )

    private static let applePasswords = SourceTemplate(
        id: "apple-passwords",
        name: "Пароли (macOS)",
        kind: .manualExport(watchPath: downloads, filePattern: "Passwords*.csv", fileMode: .single, removeOriginal: true),
        schedule: .monthly,
        retention: RetentionRules(daily: 0, weekly: 0, monthly: 12, yearly: 0),
        instructions: """
        1. Откройте приложение «Пароли».
        2. Файл → Экспортировать все пароли в файл…
        3. Сохраните файл в «Загрузки», не меняя имя.

        Файл не зашифрован. Приложение заберёт его из «Загрузок» само.
        """
    )

    private static let googlePhotos = SourceTemplate(
        id: "google-photos",
        name: "Google Photos",
        kind: .manualExport(watchPath: downloads, filePattern: "takeout-*.zip", fileMode: .multiple, removeOriginal: true),
        schedule: .monthly,
        retention: RetentionRules(daily: 0, weekly: 0, monthly: 3, yearly: 0),
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
        instructions: """
        1. Откройте https://claude.ai → Settings → Privacy → Export data.
        2. Дождитесь письма со ссылкой и скачайте архив в «Загрузки».

        Если имя архива не начинается с `data-`, поправьте маску файла в настройках источника.
        """
    )

    private static let iosFinance = SourceTemplate(
        id: "ios-finance",
        name: "Финансы (iOS)",
        kind: .manualExport(watchPath: downloads, filePattern: "", fileMode: .single, removeOriginal: true),
        schedule: .monthly,
        retention: RetentionRules(daily: 0, weekly: 0, monthly: 24, yearly: 0),
        instructions: """
        1. В приложении на iPhone откройте экспорт данных в CSV.
        2. Отправьте файл на Mac через AirDrop — он попадёт в «Загрузки».

        Обязательно укажите маску файла по имени, которое даёт ваше приложение, например `MoneyManager*.csv`. Пока маска пустая, ничего не подхватывается. Маску `*.csv` не используйте: под неё попадут любые CSV, включая экспорт паролей.
        """
    )
}
