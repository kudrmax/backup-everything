import Foundation

enum BundledTemplates {
    static let all: [SourceTemplate] = [obsidian, github, bitwarden, applePasswords, appleContacts, googlePhotos, claude, claudeCode, iosFinance]

    private static let downloads = "~/Downloads"

    private static let obsidian = SourceTemplate(
        id: "obsidian",
        name: "Obsidian",
        steps: [.folder("~/Documents/Obsidian", excludes: [".trash", ".obsidian/workspace*.json"])],
        schedule: .daily,
        retention: .standard,
        description: "All notes and vault settings, except the trash and window state.",
        instructions: "Enter the path to your Obsidian vault folder."
    )

    private static let github = SourceTemplate(
        id: "github",
        name: "GitHub",
        steps: [.command(
            #"""
            set -euo pipefail

            # Do not back up these repositories: one per line, as owner/name
            IGNORE="
            "

            # A network drop must not ruin the whole run: each repository is tried up to three times
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
              echo "$n of ${#repos} · $repo"
              clone "$repo" "$BACKUP_SCRATCH_DIR/$repo.git"
              mkdir -p "$BACKUP_OUTPUT_DIR/$(dirname "$repo")"
              git -C "$BACKUP_SCRATCH_DIR/$repo.git" bundle create --quiet "$BACKUP_OUTPUT_DIR/$repo.bundle" --all || [ -z "$(git -C "$BACKUP_SCRATCH_DIR/$repo.git" for-each-ref)" ]
            done
            """#,
            timeoutSeconds: 3600,
            name: "Clone repositories"
        )],
        schedule: .weekly,
        retention: RetentionRules(daily: 0, weekly: 4, monthly: 6, yearly: 0),
        description: "All your repositories. Each one is saved as a single .bundle file with its full history. To restore: git clone name.bundle",
        instructions: """
        Run once in Terminal:

        1. `brew install gh`
        2. `gh auth login`

        To skip repositories, list them in `IGNORE` at the top of the command — one per line, as `owner/name`.
        """
    )

    private static let bitwarden = SourceTemplate(
        id: "bitwarden",
        name: "Bitwarden",
        steps: [.command(
            #"""
            set -euo pipefail
            export BW_PASSWORD="$(security find-generic-password -s backup-everything-bitwarden -w)"
            export BW_SESSION="$(bw unlock --raw --passwordenv BW_PASSWORD)"
            bw sync
            bw export --format json --output "$BACKUP_OUTPUT_DIR/bitwarden.json"
            """#,
            timeoutSeconds: 300,
            name: "Export vault"
        )],
        schedule: .weekly,
        retention: RetentionRules(daily: 0, weekly: 8, monthly: 12, yearly: 0),
        description: "All password vault items as a single JSON file. The export is not encrypted — send it only to destinations you trust.",
        instructions: """
        Run once in Terminal:

        1. `brew install bitwarden-cli`
        2. `bw login`
        3. `security add-generic-password -s backup-everything-bitwarden -a bitwarden -w` — enter your master password; it will be saved in the Keychain.
        """
    )

    private static let applePasswords = SourceTemplate(
        id: "apple-passwords",
        name: "Passwords (Apple)",
        steps: [
            .file(
                "Passwords*.csv",
                in: downloads,
                mode: .single,
                instructions: """
                1. Open the Passwords app.
                2. File → Export All Passwords to File…
                3. Save the file to Downloads without renaming it.

                The app will pick it up from Downloads on its own.
                """,
                name: "Export passwords"
            ),
        ],
        schedule: .monthly,
        retention: RetentionRules(daily: 0, weekly: 0, monthly: 12, yearly: 0),
        description: "All passwords from the Passwords app as a single CSV file. The file is not encrypted — send it only to destinations you trust.",
        instructions: ""
    )

    private static let appleContacts = SourceTemplate(
        id: "apple-contacts",
        name: "Contacts (Apple)",
        steps: [
            .file(
                "*.vcf",
                in: downloads,
                mode: .single,
                instructions: """
                From the iPhone (recommended):

                1. Open Contacts and tap Lists at the top left.
                2. Touch and hold All Contacts → Export → select all fields → Export.
                3. AirDrop the file to this Mac — it will land in Downloads.

                Or from the Mac:

                1. Open Contacts, choose All Contacts and select everything (⌘A).
                2. File → Export → Export vCard…
                3. Save the file to Downloads.

                The app will pick it up from Downloads on its own.
                """,
                name: "Export contacts"
            ),
        ],
        schedule: .monthly,
        retention: RetentionRules(daily: 0, weekly: 0, monthly: 12, yearly: 0),
        description: "All contacts as a single vCard file. To restore: open the file on an iPhone or Mac.",
        instructions: ""
    )

    private static let googlePhotos = SourceTemplate(
        id: "google-photos",
        name: "Google Photos",
        steps: [
            .file(
                "takeout-*.zip",
                in: downloads,
                mode: .multiple,
                instructions: """
                1. Open https://takeout.google.com
                2. Click “Deselect all” and tick only Google Photos.
                3. Choose .zip, 50 GB parts, then “Create export”.
                4. When the email arrives, download all parts to Downloads.
                5. When all parts are downloaded, click “Pick up”.
                """,
                name: "Export Takeout"
            ),
        ],
        schedule: .monthly,
        retention: RetentionRules(daily: 0, weekly: 0, monthly: 3, yearly: 0),
        description: "All photos and videos from Google Photos — Google Takeout archives.",
        instructions: ""
    )

    private static let claude = SourceTemplate(
        id: "claude",
        name: "Claude",
        steps: [
            SourceStep(
                id: UUID(uuidString: "C1A0DE00-0000-4000-8000-000000000001")!,
                name: "Request export",
                kind: .file(
                    instructions: """
                    1. Open https://claude.ai → Settings → Privacy → Export data.
                    2. Wait for the email and follow the link in it.
                    3. Download the manifest file to Downloads without renaming it.

                    The app downloads the archives itself through the default browser: you must be signed in to claude.ai there, and download renaming must be turned off.
                    """,
                    watchPath: downloads,
                    filePattern: "manifest-*.json",
                    fileMode: .single,
                    includeInCopy: false,
                    removeOriginal: true
                )
            ),
            SourceStep(
                id: UUID(uuidString: "C1A0DE00-0000-4000-8000-000000000002")!,
                name: "Download archives",
                kind: .command(
                    command: #"""
                    set -euo pipefail
                    downloads="${BACKUP_DOWNLOADS_DIR:-$HOME/Downloads}"
                    opener=(${=BACKUP_OPEN_COMMAND:-open -g})
                    wait_seconds="${BACKUP_WAIT_SECONDS:-3300}"

                    manifest=("$BACKUP_INPUT_DIR"/manifest-*.json(N.om[1]))
                    [ ${#manifest} -eq 1 ] || { echo "Export manifest not found." >&2; exit 1; }
                    created="$(plutil -extract created_at raw -o - "$manifest")"
                    since="$(date -j -u -f '%Y-%m-%dT%H:%M:%S' "${created[1,19]}" +%s)"
                    total="$(plutil -extract data_files raw -o - "$manifest")"

                    names=(); urls=()
                    for ((i = 0; i < total; i++)); do
                      names+=("${$(plutil -extract "data_files.$i.filename" raw -o - "$manifest"):t}")
                      urls+=("$(plutil -extract "data_files.$i.export_url" raw -o - "$manifest")")
                    done

                    # The browser sets the file's modification date from the server, so its age also counts from when it appeared on disk
                    age_mark() {
                      local born changed
                      born="$(stat -f %B "$1")"; changed="$(stat -f %m "$1")"
                      echo $(( born > changed ? born : changed ))
                    }
                    # Firefox appends .part, Chrome and Arc .crdownload, Safari .download
                    in_progress() {
                      local suffix
                      for suffix in part crdownload download; do
                        if [ -e "$downloads/$1.$suffix" ]; then return 0; fi
                      done
                      return 1
                    }
                    downloaded() {
                      [ -s "$downloads/$1" ] && ! in_progress "$1" && [ "$(age_mark "$downloads/$1")" -gt "$since" ]
                    }

                    # Moves a downloaded archive into the copy; also succeeds when it is already there
                    collect() {
                      [ -s "$BACKUP_OUTPUT_DIR/$1" ] && return 0
                      downloaded "$1" || return 1
                      mv "$downloads/$1" "$BACKUP_OUTPUT_DIR/$1"
                    }

                    for ((i = 1; i <= total; i++)); do
                      collect "$names[i]" && continue
                      if [ -e "$downloads/$names[i]" ] && ! in_progress "$names[i]" && [ "$(age_mark "$downloads/$names[i]")" -le "$since" ]; then
                        echo "The downloads folder has an old file $names[i]. Remove it and repeat the step." >&2
                        exit 1
                      fi
                    done
                    for ((i = 1; i <= total; i++)); do
                      [ -s "$BACKUP_OUTPUT_DIR/$names[i]" ] || in_progress "$names[i]" || $opener "$urls[i]"
                    done

                    deadline=$(( $(date +%s) + wait_seconds ))
                    reported=-1
                    while true; do
                      left=()
                      for name in $names; do collect "$name" || left+=("$name"); done
                      ready=$(( total - ${#left} ))
                      if [ "$ready" -ne "$reported" ]; then echo "downloaded $ready of $total"; reported=$ready; fi
                      [ ${#left} -eq 0 ] && break
                      if [ "$(date +%s)" -ge "$deadline" ]; then
                        busy=()
                        for name in $left; do
                          if in_progress "$name"; then busy+=("$name"); fi
                        done
                        advice="Request the export again."
                        if [ ${#busy} -gt 0 ]; then
                          advice="Still downloading: ${(j:, :)busy}. When the download finishes, repeat the step; if it was interrupted, delete the unfinished files in the downloads folder and repeat the step."
                        fi
                        echo "Archives not downloaded: ${(j:, :)left}. $advice" >&2
                        exit 1
                      fi
                      sleep 2
                    done
                    """#,
                    timeoutSeconds: 3600
                )
            ),
        ],
        schedule: .monthly,
        retention: RetentionRules(daily: 0, weekly: 0, monthly: 12, yearly: 0),
        description: "All chats, projects and memory of the Claude account — archives from the official export.",
        instructions: "The export takes two steps: you download the manifest, and the app downloads the archives from the links in it."
    )

    private static let claudeCode = SourceTemplate(
        id: "claude-code",
        name: "Claude Code",
        steps: [.command(
            #"""
            set -euo pipefail
            src="$HOME/.claude"

            # Broken links are skipped, other links are replaced with the real files
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
            timeoutSeconds: 900,
            name: "Copy ~/.claude"
        )],
        schedule: .weekly,
        retention: RetentionRules(daily: 0, weekly: 4, monthly: 6, yearly: 0),
        description: "Claude Code settings, CLAUDE.md instructions, skills, memory and session history: the ~/.claude folder and the ~/.claude.json file. Caches and downloads are not copied. The settings may contain MCP server keys — send them only to destinations you trust.",
        instructions: """
        Nothing to set up.

        To restore: copy the `dot-claude` folder to `~/.claude` and the `dot-claude.json` file to `~/.claude.json`, then sign in again with `claude /login`.
        """
    )

    private static let iosFinance = SourceTemplate(
        id: "ios-finance",
        name: "Finance (iOS)",
        steps: [
            .file(
                "",
                in: downloads,
                mode: .single,
                instructions: """
                1. In the app on your iPhone, open the CSV data export.
                2. AirDrop the file to the Mac — it will land in Downloads.

                Be sure to set a file pattern matching the name your app gives the file, for example `MoneyManager*.csv`. While the pattern is empty, nothing is picked up. Do not use `*.csv`: it matches any CSV, including the passwords export.
                """,
                name: "Export CSV"
            ),
        ],
        schedule: .monthly,
        retention: RetentionRules(daily: 0, weekly: 0, monthly: 24, yearly: 0),
        description: "Transactions exported from a finance app on the iPhone as CSV.",
        instructions: ""
    )
}
