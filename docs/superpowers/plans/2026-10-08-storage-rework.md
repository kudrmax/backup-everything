# Хранение копий через rsync и защищённые назначения: план реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Заменить самописный слой хранения копий на rsync, который пишет в папки назначения, принадлежащие служебной учётке `_backupeverything`, через шлюз `backup-receiver`; приложение теряет всякую возможность удалять или менять готовые копии.

**Architecture:** Копия это папка `<корень>/<slug>/<дата>/` с файлом-меткой `.complete`, записанная rsync 3.5 с `--link-dest` на прошлую копию. Отправитель rsync работает от пользователя, получатель от `_backupeverything`: его запускает `sudo` без пароля через корневой бинарник-шлюз с allow-list аргументов. Приложение читает папки назначений напрямую (статус, правило хранения), а для отключённых назначений держит кеш последнего увиденного. Долги, сверка, манифесты, клоны, привязка к диску и облако удаляются.

**Tech Stack:** Swift 6 (SwiftPM, macOS 14+), Swift Testing (`import Testing`), rsync 3.5 из Homebrew (`/opt/homebrew/bin/rsync`), bash для скрипта установки.

**Spec:** `docs/superpowers/specs/2026-10-07-storage-rework-design.md` (согласованная версия также в Claude Docs). Разделы прежней спеки `docs/superpowers/specs/2026-09-30-backup-manager-design.md`, которые он заменяет: 4.2–4.4, 5.3, 5.3.1, часть 5.4 и 7.

## Global Constraints

- Ветка `storage-rework`. Прод-приложение (`dist/BackupEverything.app`, `~/BackupEverything/`) не трогать; `scripts/build-app.sh` не запускать, пока Макс не согласовал скрипт установки.
- Удалять файлы только через `trash` (не `rm`, не `git rm`): `trash <путь>`, затем `git add -A`.
- Перед каждым коммитом: `swift test --package-path BackupCore` и `swift test --package-path App` зелёные, `swift build --package-path App` успешен. Проверять код возврата каждой команды отдельно.
- Имя служебной учётки: `_backupeverything`. Путь шлюза: `/usr/local/libexec/backup-everything/backup-receiver`. rsync: `/opt/homebrew/bin/rsync`.
- Имя метки готовой копии: `.complete`. Имя папки копии: `SnapshotNaming` без изменений (`yyyy-MM-dd_HHmmss`, со смещением в повторяющийся час).
- Флаги rsync при записи: `-a -A -X --inplace --mkpath`, плюс `--link-dest=<прошлая копия>` и `--exclude=<маска>` на каждое исключение. Никогда: `--delete*`, `--remove-source-files`.
- Приложение не удаляет и не переименовывает ничего в папках назначений. В коде ядра и приложения не появляется ни одного вызова `removeItem`, `unlink`, `rename`, `moveItem` с путём внутри назначения.
- Комментарии в коде только там, где без них не обойтись; тексты интерфейса на английском, как в существующем коде.
- Тесты не скипать; упавший тест, в том числе старый, это блокер, о нём сообщать.

## Review Focus

1. Источник с файлом или папкой `.complete` на верхнем уровне: копия не должна считаться готовой до конца записи. Тест: Task 6 (`BackupEngine` отказывает с `SourceError.reservedName`).
2. Прерванная запись (rsync упал на середине): папка без метки остаётся, прошлые копии не тронуты, следующий прогон дописывает в ту же папку и ставит метку. Тест: Task 5 (`LocalFolderDestination`).
3. Назначение на томе с `noowners` или папка не того владельца: приложение считает назначение неготовым и ничего туда не пишет, а в окне показывает, что сделать. Тест: Task 4 (`SystemDestinationAccess`) и Task 12 (`StorageSetup`).
4. Отключённый HDD с правилом «раз в N дней»: статус и напоминание считаются от даты из кеша, а не от «нет копии». Тест: Task 9 (`StatusReporter` с кешем) и Task 10 (координатор обновляет кеш при подключении).
5. Шлюз получает аргументы с `--delete`, с целью в готовой копии или вне папки `_backupeverything`: отказ до запуска rsync. Тест: Task 1 (`ReceiverGate`).

## Структура файлов

Новое:

- `BackupCore/Sources/ReceiverGate/Gate.swift`: разбор и проверка аргументов шлюза (чистая логика, без BackupCore).
- `BackupCore/Sources/ReceiverGate/GateEnvironment.swift`: протокол доступа к системе (владелец, флаги тома, существование файла) и его системная реализация.
- `BackupCore/Sources/backup-receiver/main.swift`: исполняемый файл шлюза: `--check`, иначе `Gate` и `execv` rsync.
- `BackupCore/Tests/ReceiverGateTests/GateTests.swift`.
- `BackupCore/Sources/BackupCore/Destinations/CopyFolder.swift`: чтение копий назначения (папки с датой и меткой).
- `BackupCore/Sources/BackupCore/Destinations/DestinationAccess.swift`: проверка «папка принадлежит `_backupeverything` на томе с учётом владельцев».
- `BackupCore/Sources/BackupCore/Destinations/RsyncTransfer.swift`: запуск rsync (запись копии, запись метки).
- `BackupCore/Sources/BackupCore/Application/StorageSetup.swift`: проверка установки (rsync, учётка, шлюз, правило sudo, назначения).
- `BackupCore/Sources/BackupCore/Retention/ExcessCopies.swift`: копии сверх правила с размером и командой для удаления.
- `scripts/setup-storage.sh`.
- `App/Sources/BackupEverything/Presentation/SetupTexts.swift`, `App/Sources/BackupEverything/Views/SetupSection.swift`, `App/Sources/BackupEverything/Views/ExcessCopiesSection.swift`.

Переписывается: `LocalFolderDestination.swift`, `DestinationStore.swift`, `BackupEngine.swift`, `BackupCoordinator.swift`, `AppState.swift`, `StateReducer.swift`, `SchedulePlanner.swift`, `StatusReporter.swift`, `Notice.swift`, `Factories.swift`, `CoreAssembly.swift`, `Destination.swift`, `Source.swift` (без `savesSpace`), `Snapshot.swift` (без манифеста), `Store.swift` (состояние v2), `Package.swift` обоих пакетов; в приложении `AppModel.swift`, `StatusSnapshot.swift`, `CopyGaps.swift`, `DestinationCondition.swift`, `DeliveryState.swift`, `NoticeText.swift`, `DestinationsView.swift`, `SourcesView.swift`, `OverviewView.swift`, `Drafts.swift`.

Удаляется (через `trash`): `SnapshotWriter.swift`, `SpaceSaving.swift`, `FileCloning.swift`, `ContentHash.swift`, `UnfinishedMark.swift`, `RcloneDestination.swift`, `RcloneLocator.swift`, `Disks.swift`, `DiskFormat.swift`, `VolumeMounts.swift` и их тесты; `App/.../Presentation/SpaceSaving.swift`, `App/Tests/.../DiskConfirmationTests.swift`, `SpaceSavingTests.swift`, `UnverifiablePlaceSnapshotTests.swift`.

Остаётся без изменений: домен шагов, `StepsSource`, `StepExecutor` (он копирует шаг “Copy folder” через `PayloadCopier`, поэтому `PayloadCopier`, `WrittenCopy`, `PayloadWalker`, `FolderRemoval` остаются), `ManualExportInbox`, `StepChainRunner`, `RetentionPolicy`, `SnapshotNaming`, `ReminderPlanner`, шаблоны.

---

### Task 1: Логика шлюза `ReceiverGate`

**Files:**
- Modify: `BackupCore/Package.swift`
- Create: `BackupCore/Sources/ReceiverGate/GateEnvironment.swift`
- Create: `BackupCore/Sources/ReceiverGate/Gate.swift`
- Test: `BackupCore/Tests/ReceiverGateTests/GateTests.swift`

**Interfaces:**
- Produces: `Gate.plan(arguments: [String], environment: any GateEnvironment) -> Result<[String], GateError>` — `arguments` это argv шлюза без argv[0] (как его вызывает rsync через `--rsh`: `<host> rsync --server …`). Успех возвращает argv для rsync (без пути к rsync). `GateError: Error, Equatable` с `message: String`.
- Produces: `protocol GateEnvironment { var currentUID: uid_t { get }; func ownerUID(ofPath: String) -> uid_t?; func volumeHonoursOwners(atPath: String) -> Bool; func fileExists(atPath: String) -> Bool }`, `struct SystemGateEnvironment: GateEnvironment`.

- [ ] **Step 1: Добавить цели в `BackupCore/Package.swift`**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BackupCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BackupCore", targets: ["BackupCore"]),
        .executable(name: "backup-receiver", targets: ["backup-receiver"]),
    ],
    targets: [
        .target(name: "BackupCore"),
        .target(name: "ReceiverGate"),
        .executableTarget(name: "backup-receiver", dependencies: ["ReceiverGate"]),
        .testTarget(name: "BackupCoreTests", dependencies: ["BackupCore"]),
        .testTarget(name: "ReceiverGateTests", dependencies: ["ReceiverGate"]),
    ]
)
```

- [ ] **Step 2: Написать падающие тесты**

`BackupCore/Tests/ReceiverGateTests/GateTests.swift`:

```swift
import Foundation
import Testing
@testable import ReceiverGate

struct FakeEnvironment: GateEnvironment {
    var currentUID: uid_t = 497
    var owners: [String: uid_t] = [:]
    var noOwners: Set<String> = []
    var existing: Set<String> = []

    func ownerUID(ofPath path: String) -> uid_t? { owners[path] }
    func volumeHonoursOwners(atPath path: String) -> Bool { !noOwners.contains(path) }
    func fileExists(atPath path: String) -> Bool { existing.contains(path) || owners[path] != nil }
}

struct GateTests {
    private let root = "/Volumes/HDD/Backups"
    private var environment: FakeEnvironment {
        FakeEnvironment(owners: ["/Volumes/HDD/Backups": 497, "/Volumes/HDD/Backups/obsidian": 497])
    }
    private let server = ["backup", "rsync", "--server", "-logDtpAXre.iLsfxCIvu", "--link-dest", "/Volumes/HDD/Backups/obsidian/2026-10-07_100000", "--inplace", "--mkpath", "."]

    @Test func passesACopyIntoAnUnfinishedFolder() {
        let plan = Gate.plan(arguments: server + ["/Volumes/HDD/Backups/obsidian/2026-10-08_100000/"], environment: environment)
        #expect(plan == .success(Array(server.dropFirst(2)) + ["/Volumes/HDD/Backups/obsidian/2026-10-08_100000/"]))
    }

    @Test func passesTheCompletionMarker() {
        let plan = Gate.plan(
            arguments: ["backup", "rsync", "--server", "-logDtpAXre.iLsfxCIvu", ".", "/Volumes/HDD/Backups/obsidian/2026-10-08_100000/.complete"],
            environment: environment
        )
        #expect(plan == .success(["--server", "-logDtpAXre.iLsfxCIvu", ".", "/Volumes/HDD/Backups/obsidian/2026-10-08_100000/.complete"]))
    }

    @Test(arguments: ["--delete", "--delete-after", "--remove-source-files", "--sender", "--rsync-path=/bin/sh", "--files-from=/etc/passwd", "--backup-dir=/tmp"])
    func refusesAnyOptionOutsideTheList(option: String) {
        let plan = Gate.plan(arguments: server + [option, "/Volumes/HDD/Backups/obsidian/2026-10-08_100000/"], environment: environment)
        #expect(plan == .failure(GateError(message: "refused option \(option)")))
    }

    @Test func refusesWithoutServerMode() {
        let plan = Gate.plan(arguments: ["backup", "rsync", "-a", ".", "/Volumes/HDD/Backups/x/"], environment: environment)
        #expect(plan == .failure(GateError(message: "only rsync --server is accepted")))
    }

    @Test func refusesATargetInAFinishedCopy() {
        var environment = environment
        environment.existing.insert("/Volumes/HDD/Backups/obsidian/2026-10-08_100000/.complete")
        let plan = Gate.plan(arguments: server + ["/Volumes/HDD/Backups/obsidian/2026-10-08_100000/"], environment: environment)
        #expect(plan == .failure(GateError(message: "/Volumes/HDD/Backups/obsidian/2026-10-08_100000 is a finished copy")))
    }

    @Test func refusesATargetOutsideAFolderOfTheRoleAccount() {
        let plan = Gate.plan(arguments: server + ["/Users/max/Documents/x/"], environment: environment)
        #expect(plan == .failure(GateError(message: "/Users/max/Documents/x is not inside a folder of the backup account")))
    }

    @Test func refusesATargetOnAVolumeIgnoringOwners() {
        var environment = environment
        environment.noOwners.insert("/Volumes/HDD/Backups/obsidian")
        let plan = Gate.plan(arguments: server + ["/Volumes/HDD/Backups/obsidian/2026-10-08_100000/"], environment: environment)
        #expect(plan == .failure(GateError(message: "the volume of /Volumes/HDD/Backups/obsidian/2026-10-08_100000 ignores file owners")))
    }

    @Test func refusesAPathThatClimbsOut() {
        let plan = Gate.plan(arguments: server + ["/Volumes/HDD/Backups/obsidian/../../x/"], environment: environment)
        #expect(plan == .failure(GateError(message: "path must be absolute without “..”")))
    }

    @Test func refusesASecondPath() {
        let plan = Gate.plan(arguments: server + ["/Volumes/HDD/Backups/obsidian/a/", "/Volumes/HDD/Backups/obsidian/b/"], environment: environment)
        #expect(plan == .failure(GateError(message: "exactly one destination path is accepted")))
    }
}
```

- [ ] **Step 3: Запустить и убедиться, что тесты не компилируются**

Run: `swift test --package-path BackupCore --filter GateTests`
Expected: ошибка компиляции, `Gate` и `GateEnvironment` не определены.

- [ ] **Step 4: Написать `GateEnvironment.swift`**

```swift
import Darwin
import Foundation

public protocol GateEnvironment {
    var currentUID: uid_t { get }
    func ownerUID(ofPath path: String) -> uid_t?
    func volumeHonoursOwners(atPath path: String) -> Bool
    func fileExists(atPath path: String) -> Bool
}

public struct SystemGateEnvironment: GateEnvironment {
    public init() {}

    public var currentUID: uid_t { geteuid() }

    public func ownerUID(ofPath path: String) -> uid_t? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return info.st_uid
    }

    public func volumeHonoursOwners(atPath path: String) -> Bool {
        var volume = statfs()
        guard statfs(path, &volume) == 0 else { return false }
        return volume.f_flags & UInt32(MNT_IGNORE_OWNERSHIP) == 0
    }

    public func fileExists(atPath path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }
}
```

- [ ] **Step 5: Написать `Gate.swift`**

```swift
import Foundation

public struct GateError: Error, Equatable {
    public let message: String

    public init(message: String) {
        self.message = message
    }
}

/// What rsync may ask the receiver to do: copy into an unfinished copy folder owned by the backup account. Nothing else.
public enum Gate {
    public static let completionMarker = ".complete"
    private static let allowedLongOptions: Set<String> = ["--server", "--inplace", "--mkpath"]
    private static let optionsWithValue: Set<String> = ["--link-dest"]

    public static func plan(arguments: [String], environment: any GateEnvironment) -> Result<[String], GateError> {
        var rest = arguments.dropFirst()
        if rest.first == "rsync" { rest = rest.dropFirst() }
        guard rest.first == "--server" else { return .failure(GateError(message: "only rsync --server is accepted")) }
        var argv: [String] = []
        var paths: [String] = []
        var expectingValue = false
        for argument in rest {
            if expectingValue {
                argv.append(argument)
                expectingValue = false
                continue
            }
            if allowedLongOptions.contains(argument) || isShortCluster(argument) || argument == "." {
                argv.append(argument)
            } else if optionsWithValue.contains(argument) {
                argv.append(argument)
                expectingValue = true
            } else if argument.hasPrefix("-") {
                return .failure(GateError(message: "refused option \(argument)"))
            } else {
                paths.append(argument)
                argv.append(argument)
            }
        }
        guard paths.count == 1, let target = paths.first else {
            return .failure(GateError(message: "exactly one destination path is accepted"))
        }
        if let problem = check(target: target, environment: environment) { return .failure(problem) }
        return .success(argv)
    }

    private static func isShortCluster(_ argument: String) -> Bool {
        argument.count > 1 && argument.hasPrefix("-") && !argument.hasPrefix("--")
            && argument.dropFirst().allSatisfy { $0.isASCII && ($0.isLetter || $0 == ".") }
    }

    /// The target must sit under a folder of the backup account, on a volume that honours owners, and must not be
    /// (or lie in) a finished copy.
    private static func check(target: String, environment: any GateEnvironment) -> GateError? {
        guard target.hasPrefix("/"), !target.split(separator: "/").contains("..") else {
            return GateError(message: "path must be absolute without “..”")
        }
        let folder = target.hasSuffix("/") ? String(target.dropLast()) : (target as NSString).deletingLastPathComponent
        if environment.fileExists(atPath: folder + "/" + completionMarker) {
            return GateError(message: "\(folder) is a finished copy")
        }
        guard let existing = nearestExisting(folder, environment: environment) else {
            return GateError(message: "\(folder) is not inside a folder of the backup account")
        }
        guard environment.ownerUID(ofPath: existing) == environment.currentUID else {
            return GateError(message: "\(folder) is not inside a folder of the backup account")
        }
        guard environment.volumeHonoursOwners(atPath: existing) else {
            return GateError(message: "the volume of \(folder) ignores file owners")
        }
        return nil
    }

    private static func nearestExisting(_ path: String, environment: any GateEnvironment) -> String? {
        var current = path
        while !current.isEmpty, current != "/" {
            if environment.fileExists(atPath: current) { return current }
            current = (current as NSString).deletingLastPathComponent
        }
        return nil
    }
}
```

- [ ] **Step 6: Запустить тесты**

Run: `swift test --package-path BackupCore --filter GateTests`
Expected: все тесты `GateTests` PASS. Обратить внимание: в тесте `refusesATargetOnAVolumeIgnoringOwners` ближайший существующий предок цели это `/Volumes/HDD/Backups/obsidian`, и именно он в `noOwners`.

- [ ] **Step 7: Коммит**

```bash
git add BackupCore/Package.swift BackupCore/Sources/ReceiverGate BackupCore/Tests/ReceiverGateTests
git commit -m "Add the receiver gate: rsync --server into unfinished copy folders only"
```

### Task 2: Исполняемый файл `backup-receiver`

**Files:**
- Create: `BackupCore/Sources/backup-receiver/main.swift`

**Interfaces:**
- Consumes: `Gate.plan`, `SystemGateEnvironment`.
- Produces: бинарник `backup-receiver`. `backup-receiver --check` → код 0, печатает `ok`. Иначе argv проверяется `Gate` и выполняется `execv("/opt/homebrew/bin/rsync", …)`. Отказ: сообщение в stderr, код 2.

- [ ] **Step 1: Написать `main.swift`**

```swift
import Darwin
import Foundation
import ReceiverGate

let rsync = "/opt/homebrew/bin/rsync"
let arguments = Array(CommandLine.arguments.dropFirst())

if arguments == ["--check"] {
    print("ok")
    exit(0)
}

switch Gate.plan(arguments: arguments, environment: SystemGateEnvironment()) {
case let .failure(error):
    FileHandle.standardError.write(Data("backup-receiver: \(error.message)\n".utf8))
    exit(2)
case let .success(argv):
    let cArgs = ([rsync] + argv).map { strdup($0) } + [nil]
    execv(rsync, cArgs)
    FileHandle.standardError.write(Data("backup-receiver: cannot start \(rsync): \(String(cString: strerror(errno)))\n".utf8))
    exit(2)
}
```

- [ ] **Step 2: Собрать и проверить руками без sudo**

Run:
```bash
swift build --package-path BackupCore --product backup-receiver && BackupCore/.build/debug/backup-receiver --check && BackupCore/.build/debug/backup-receiver backup rsync --server -a . /tmp/x/; echo "exit=$?"
```
Expected: `ok`, затем `backup-receiver: /tmp/x is not inside a folder of the backup account`, `exit=2`.

- [ ] **Step 3: Проверить полный проход через rsync от своего имени**

Папка, принадлежащая текущему пользователю, для шлюза «своя» (uid совпадает), том системного диска учитывает владельцев:
```bash
T=$(mktemp -d); mkdir -p "$T/src" "$T/dst/obsidian"; echo hi > "$T/src/a.txt"
/opt/homebrew/bin/rsync -aAX --inplace --mkpath --rsh="$PWD/BackupCore/.build/debug/backup-receiver" "$T/src/" "backup:$T/dst/obsidian/2026-10-08_100000/"; echo "exit=$?"; ls "$T/dst/obsidian/2026-10-08_100000"
/opt/homebrew/bin/rsync -a --delete --rsh="$PWD/BackupCore/.build/debug/backup-receiver" "$T/src/" "backup:$T/dst/obsidian/2026-10-08_100000/"; echo "exit=$?"
trash "$T"
```
Expected: первый rsync `exit=0` и `a.txt` на месте; второй печатает `refused option --delete`, exit не 0.

- [ ] **Step 4: Коммит**

```bash
git add BackupCore/Sources/backup-receiver
git commit -m "Add the backup-receiver executable"
```

### Task 3: Чтение копий назначения: `CopyFolder`

**Files:**
- Create: `BackupCore/Sources/BackupCore/Destinations/CopyFolder.swift`
- Test: `BackupCore/Tests/BackupCoreTests/CopyFolderTests.swift`

**Interfaces:**
- Produces: `public struct CopyFolder: Sendable { public init(root: URL, naming: SnapshotNaming); public static let completionMarker = ".complete"; public func copies(of slug: String) throws -> [Snapshot]; public func unfinished(of slug: String) throws -> [Snapshot]; public func url(of snapshot: Snapshot, slug: String) throws -> URL; public func newestCopy(of slug: String) throws -> Snapshot? }`. Список отсортирован по дате по возрастанию. Папка источника отсутствует → `[]`. Папка, которую нельзя прочитать → ошибка (`CocoaError`). `slug` проверяется через `Slug.folderName`.

- [ ] **Step 1: Написать падающие тесты**

```swift
import Foundation
import Testing
@testable import BackupCore

struct CopyFolderTests {
    private let temp = try! TempDirectory()
    private var folder: CopyFolder { CopyFolder(root: temp.url, naming: Fixtures.naming) }

    @Test func listsOnlyDatedFoldersWithTheMarker() throws {
        defer { temp.remove() }
        try temp.file("obsidian/2026-10-07_100000/.complete", "")
        try temp.file("obsidian/2026-10-07_100000/a.md")
        try temp.file("obsidian/2026-10-08_100000/a.md")
        try temp.directory("obsidian/notes")
        try temp.file("obsidian/2026-10-06_100000", "a file, not a folder")
        #expect(try folder.copies(of: "obsidian") == [Fixtures.snapshot("2026-10-07 10:00:00")])
        #expect(try folder.unfinished(of: "obsidian") == [Fixtures.snapshot("2026-10-08 10:00:00")])
        #expect(try folder.newestCopy(of: "obsidian") == Fixtures.snapshot("2026-10-07 10:00:00"))
    }

    @Test func sortsCopiesByDate() throws {
        defer { temp.remove() }
        try temp.file("obsidian/2026-10-08_100000/.complete", "")
        try temp.file("obsidian/2026-10-01_100000/.complete", "")
        #expect(try folder.copies(of: "obsidian").map(\.name) == ["2026-10-01_100000", "2026-10-08_100000"])
    }

    @Test func missingSourceFolderMeansNoCopies() throws {
        defer { temp.remove() }
        #expect(try folder.copies(of: "obsidian") == [])
        #expect(try folder.newestCopy(of: "obsidian") == nil)
    }

    @Test func refusesASlugThatLeadsOutside() throws {
        defer { temp.remove() }
        #expect(throws: DestinationError.invalidFolderName("../x")) { try folder.copies(of: "../x") }
    }

    @Test func urlOfACopy() throws {
        defer { temp.remove() }
        let url = try folder.url(of: Fixtures.snapshot("2026-10-07 10:00:00"), slug: "obsidian")
        #expect(url == temp.url.appendingPathComponent("obsidian/2026-10-07_100000", isDirectory: true))
    }
}
```

- [ ] **Step 2: Запустить, убедиться, что не компилируется**

Run: `swift test --package-path BackupCore --filter CopyFolderTests`
Expected: ошибка компиляции: `CopyFolder` не определён.

- [ ] **Step 3: Написать `CopyFolder.swift`**

```swift
import Foundation

/// The copies of sources inside a destination root, read from the folders themselves: a copy is a folder named by its
/// date that holds the completion marker; a dated folder without it is an unfinished copy.
public struct CopyFolder: Sendable {
    public static let completionMarker = ".complete"

    public let root: URL
    private let naming: SnapshotNaming

    public init(root: URL, naming: SnapshotNaming) {
        self.root = root
        self.naming = naming
    }

    public func copies(of slug: String) throws -> [Snapshot] {
        try datedFolders(of: slug).filter { isComplete($0.url) }.map(\.snapshot)
    }

    public func unfinished(of slug: String) throws -> [Snapshot] {
        try datedFolders(of: slug).filter { !isComplete($0.url) }.map(\.snapshot)
    }

    public func newestCopy(of slug: String) throws -> Snapshot? {
        try copies(of: slug).last
    }

    public func url(of snapshot: Snapshot, slug: String) throws -> URL {
        try sourceFolder(slug).appendingPathComponent(snapshot.name, isDirectory: true)
    }

    public func sourceFolder(_ slug: String) throws -> URL {
        root.appendingPathComponent(try Slug.folderName(slug), isDirectory: true)
    }

    private func isComplete(_ folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(Self.completionMarker).path)
    }

    private func datedFolders(of slug: String) throws -> [(url: URL, snapshot: Snapshot)] {
        let folder = try sourceFolder(slug)
        let items: [URL]
        do {
            items = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])
        } catch CocoaError.fileReadNoSuchFile {
            return []
        }
        return items
            .compactMap { url -> (URL, Snapshot)? in
                guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                      let snapshot = naming.snapshot(named: url.lastPathComponent) else { return nil }
                return (url, snapshot)
            }
            .sorted { $0.1.date < $1.1.date }
    }
}
```

- [ ] **Step 4: Запустить тесты**

Run: `swift test --package-path BackupCore --filter CopyFolderTests`
Expected: PASS.

- [ ] **Step 5: Коммит**

```bash
git add BackupCore/Sources/BackupCore/Destinations/CopyFolder.swift BackupCore/Tests/BackupCoreTests/CopyFolderTests.swift
git commit -m "Read copies of a destination from dated folders with a completion marker"
```

### Task 4: Проверка готовности папки назначения: `DestinationAccess`

**Files:**
- Create: `BackupCore/Sources/BackupCore/Destinations/DestinationAccess.swift`
- Test: `BackupCore/Tests/BackupCoreTests/DestinationAccessTests.swift`

**Interfaces:**
- Produces: `public enum DestinationReadiness: Equatable, Sendable { case ready; case folderMissing; case notOwnedByBackupAccount(owner: String); case volumeIgnoresOwners; case accountMissing }`, `public protocol DestinationAccess: Sendable { func readiness(of root: URL) -> DestinationReadiness }`, `public struct SystemDestinationAccess: DestinationAccess { public init(roleAccount: String = "_backupeverything") }`, `public struct AlwaysReadyAccess: DestinationAccess` (для тестов и песочницы: `ready`, если папка существует, иначе `folderMissing`).

- [ ] **Step 1: Написать падающие тесты**

```swift
import Foundation
import Testing
@testable import BackupCore

struct DestinationAccessTests {
    private let temp = try! TempDirectory()

    @Test func missingFolderIsReported() {
        defer { temp.remove() }
        #expect(SystemDestinationAccess(roleAccount: "root").readiness(of: temp.path("none")) == .folderMissing)
        #expect(AlwaysReadyAccess().readiness(of: temp.path("none")) == .folderMissing)
    }

    @Test func folderOwnedByAnotherAccountIsNotReady() throws {
        defer { temp.remove() }
        let root = try temp.directory("dest")
        #expect(SystemDestinationAccess(roleAccount: "root").readiness(of: root) == .notOwnedByBackupAccount(owner: NSUserName()))
    }

    @Test func unknownAccountIsReported() throws {
        defer { temp.remove() }
        let root = try temp.directory("dest")
        #expect(SystemDestinationAccess(roleAccount: "_no_such_account_be").readiness(of: root) == .accountMissing)
    }

    @Test func ownFolderOnTheSystemDiskIsReadyForTheOwner() throws {
        defer { temp.remove() }
        let root = try temp.directory("dest")
        #expect(SystemDestinationAccess(roleAccount: NSUserName()).readiness(of: root) == .ready)
        #expect(AlwaysReadyAccess().readiness(of: root) == .ready)
    }
}
```

- [ ] **Step 2: Запустить, убедиться в ошибке компиляции**

Run: `swift test --package-path BackupCore --filter DestinationAccessTests`
Expected: `DestinationReadiness` не определён.

- [ ] **Step 3: Написать `DestinationAccess.swift`**

```swift
import Darwin
import Foundation

public enum DestinationReadiness: Equatable, Sendable {
    case ready
    case folderMissing
    case notOwnedByBackupAccount(owner: String)
    case volumeIgnoresOwners
    case accountMissing
}

public protocol DestinationAccess: Sendable {
    func readiness(of root: URL) -> DestinationReadiness
}

/// A destination is usable only where the file system itself keeps the app out: the root belongs to the backup account
/// on a volume that honours owners (external disks ignore them until `diskutil enableOwnership`).
public struct SystemDestinationAccess: DestinationAccess {
    public static let roleAccount = "_backupeverything"

    private let roleAccount: String

    public init(roleAccount: String = SystemDestinationAccess.roleAccount) {
        self.roleAccount = roleAccount
    }

    public func readiness(of root: URL) -> DestinationReadiness {
        var info = stat()
        guard lstat(root.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return .folderMissing }
        guard let account = getpwnam(roleAccount) else { return .accountMissing }
        var volume = statfs()
        guard statfs(root.path, &volume) == 0, volume.f_flags & UInt32(MNT_IGNORE_OWNERSHIP) == 0 else { return .volumeIgnoresOwners }
        guard info.st_uid == account.pointee.pw_uid else {
            let owner = getpwuid(info.st_uid).map { String(cString: $0.pointee.pw_name) } ?? String(info.st_uid)
            return .notOwnedByBackupAccount(owner: owner)
        }
        return .ready
    }
}

/// For tests and the sandbox: any existing folder is ready.
public struct AlwaysReadyAccess: DestinationAccess {
    public init() {}

    public func readiness(of root: URL) -> DestinationReadiness {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) && isDirectory.boolValue ? .ready : .folderMissing
    }
}
```

- [ ] **Step 4: Запустить тесты**

Run: `swift test --package-path BackupCore --filter DestinationAccessTests`
Expected: PASS. Если `unknownAccountIsReported` падает из-за порядка проверок, проверять учётку до `statfs`, как в коде выше.

- [ ] **Step 5: Коммит**

```bash
git add BackupCore/Sources/BackupCore/Destinations/DestinationAccess.swift BackupCore/Tests/BackupCoreTests/DestinationAccessTests.swift
git commit -m "Tell whether a destination root belongs to the backup account on a volume that honours owners"
```

### Task 5: Запуск rsync: `RsyncTransfer`

**Files:**
- Create: `BackupCore/Sources/BackupCore/Destinations/RsyncTransfer.swift`
- Test: `BackupCore/Tests/BackupCoreTests/RsyncTransferTests.swift`

**Interfaces:**
- Consumes: `ProcessRunner`, `Payload`, `CopyFolder.completionMarker`.
- Produces:
  ```swift
  public struct ReceiverCommand: Sendable, Equatable { public let rsh: String; public static let standard: ReceiverCommand }
  public struct RsyncTransfer: Sendable {
      public static let homebrewRsync = URL(fileURLWithPath: "/opt/homebrew/bin/rsync")
      public init(rsync: URL, receiver: ReceiverCommand?, runner: any ProcessRunner)
      public func write(_ payload: Payload, into copy: URL, linkDest: URL?) async throws
      public func markComplete(_ copy: URL) async throws
  }
  ```
  `receiver == nil` → rsync локально (тесты, песочница). `ReceiverCommand.standard.rsh == "/usr/bin/sudo -n -u _backupeverything /usr/local/libexec/backup-everything/backup-receiver"`. Ошибка rsync → `DestinationError.commandFailed(<последние 2000 символов stderr>)`; rsync не найден → `DestinationError.rsyncMissing`.

- [ ] **Step 1: Добавить в `DestinationError` случай `rsyncMissing`**

В `BackupCore/Sources/BackupCore/Destinations/DestinationStore.swift` (enum `DestinationError`) добавить случай и текст; старые случаи пока не трогать (они уйдут в Task 6):

```swift
    case rsyncMissing
```
и в `errorDescription`:
```swift
        case .rsyncMissing:
            "rsync 3 is not installed. Install it with “brew install rsync”."
```

- [ ] **Step 2: Написать падающие тесты**

Тесты используют настоящий rsync из Homebrew; если его нет, тест падает с понятным сообщением (блокер окружения, а не скип).

```swift
import Foundation
import Testing
@testable import BackupCore

struct RsyncTransferTests {
    private let temp = try! TempDirectory()
    private var transfer: RsyncTransfer {
        RsyncTransfer(rsync: RsyncTransfer.homebrewRsync, receiver: nil, runner: SystemProcessRunner())
    }

    @Test func rsyncFromHomebrewIsInstalled() {
        #expect(FileManager.default.isExecutableFile(atPath: RsyncTransfer.homebrewRsync.path), "brew install rsync")
    }

    @Test func writesAFolderWithExclusionsAndMarksItComplete() async throws {
        defer { temp.remove() }
        try temp.file("src/a.md", "alpha")
        try temp.file("src/cache/b.tmp", "beta")
        try temp.file("src/.DS_Store", "x")
        let copy = temp.path("dst/obsidian/2026-10-08_100000")
        let payload = Payload(root: temp.path("src"), excludes: ["cache", ".DS_Store"], collectedAt: Date())
        try await transfer.write(payload, into: copy, linkDest: nil)
        #expect(temp.names(in: "dst/obsidian/2026-10-08_100000") == ["a.md"])
        try await transfer.markComplete(copy)
        #expect(temp.names(in: "dst/obsidian/2026-10-08_100000") == [".complete", "a.md"])
    }

    @Test func unchangedFilesBecomeHardLinksOfThePreviousCopy() async throws {
        defer { temp.remove() }
        try temp.file("src/a.md", "alpha")
        try temp.file("src/b.md", "beta")
        let first = temp.path("dst/obsidian/2026-10-07_100000")
        let second = temp.path("dst/obsidian/2026-10-08_100000")
        try await transfer.write(Payload(root: temp.path("src"), collectedAt: Date()), into: first, linkDest: nil)
        try await transfer.markComplete(first)
        try Data("beta2".utf8).write(to: temp.path("src/b.md"))
        try await transfer.write(Payload(root: temp.path("src"), collectedAt: Date()), into: second, linkDest: first)
        let inode = { (relative: String) in try FileManager.default.attributesOfItem(atPath: temp.path(relative).path)[.systemFileNumber] as? UInt64 }
        #expect(try inode("dst/obsidian/2026-10-07_100000/a.md") == inode("dst/obsidian/2026-10-08_100000/a.md"))
        #expect(try inode("dst/obsidian/2026-10-07_100000/b.md") != inode("dst/obsidian/2026-10-08_100000/b.md"))
        #expect(try String(contentsOf: temp.path("dst/obsidian/2026-10-07_100000/b.md"), encoding: .utf8) == "beta")
    }

    @Test func writesASingleFileIntoTheCopyFolder() async throws {
        defer { temp.remove() }
        try temp.file("export.csv", "a,b")
        let copy = temp.path("dst/finance/2026-10-08_100000")
        try await transfer.write(Payload(root: temp.path("export.csv"), collectedAt: Date()), into: copy, linkDest: nil)
        #expect(temp.names(in: "dst/finance/2026-10-08_100000") == ["export.csv"])
    }

    @Test func missingSourceFailsWithRsyncError() async throws {
        defer { temp.remove() }
        let copy = temp.path("dst/x/2026-10-08_100000")
        await #expect(throws: DestinationError.self) {
            try await transfer.write(Payload(root: temp.path("gone"), collectedAt: Date()), into: copy, linkDest: nil)
        }
        #expect(!temp.exists("dst/x/2026-10-08_100000/.complete"))
    }

    @Test func missingRsyncIsToldAsSuch() async throws {
        defer { temp.remove() }
        let transfer = RsyncTransfer(rsync: temp.path("no-rsync"), receiver: nil, runner: SystemProcessRunner())
        await #expect(throws: DestinationError.rsyncMissing) {
            try await transfer.markComplete(temp.path("dst/x/2026-10-08_100000"))
        }
    }

    @Test func receiverCommandBecomesTheRshOption() async throws {
        defer { temp.remove() }
        let runner = FakeProcessRunner()
        let transfer = RsyncTransfer(rsync: RsyncTransfer.homebrewRsync, receiver: .standard, runner: runner)
        try await transfer.write(Payload(root: temp.path("src"), collectedAt: Date()), into: temp.path("dst/obsidian/2026-10-08_100000"), linkDest: temp.path("dst/obsidian/2026-10-07_100000"))
        let arguments = runner.calls.last?.arguments ?? []
        #expect(arguments.contains("--rsh=/usr/bin/sudo -n -u _backupeverything /usr/local/libexec/backup-everything/backup-receiver"))
        #expect(arguments.contains("--link-dest=\(temp.path("dst/obsidian/2026-10-07_100000").path)"))
        #expect(arguments.last == "backup:\(temp.path("dst/obsidian/2026-10-08_100000").path)/")
        #expect(arguments.contains("--inplace") && arguments.contains("--mkpath") && arguments.contains("-aAX"))
        #expect(!arguments.contains { $0.hasPrefix("--delete") })
    }
}
```

`FakeProcessRunner()` без аргументов отвечает кодом 0 на любой вызов и копит вызовы в `calls` (поле `arguments`); фейк не менять.

- [ ] **Step 3: Запустить, убедиться в ошибке компиляции**

Run: `swift test --package-path BackupCore --filter RsyncTransferTests`
Expected: `RsyncTransfer` не определён.

- [ ] **Step 4: Написать `RsyncTransfer.swift`**

```swift
import Foundation

/// How rsync reaches the receiver that runs as the backup account.
public struct ReceiverCommand: Sendable, Equatable {
    public let rsh: String

    public init(rsh: String) {
        self.rsh = rsh
    }

    public static let standard = ReceiverCommand(
        rsh: "/usr/bin/sudo -n -u \(SystemDestinationAccess.roleAccount) /usr/local/libexec/backup-everything/backup-receiver"
    )
}

/// Writes a copy with rsync: everything of the payload into the copy folder, unchanged files as hard links of the previous
/// copy, then the completion marker. Nothing is ever deleted or renamed.
public struct RsyncTransfer: Sendable {
    public static let homebrewRsync = URL(fileURLWithPath: "/opt/homebrew/bin/rsync")
    private static let errorTailLength = 2000
    private static let host = "backup"

    private let rsync: URL
    private let receiver: ReceiverCommand?
    private let runner: any ProcessRunner

    public init(rsync: URL, receiver: ReceiverCommand?, runner: any ProcessRunner) {
        self.rsync = rsync
        self.receiver = receiver
        self.runner = runner
    }

    public func write(_ payload: Payload, into copy: URL, linkDest: URL?) async throws {
        var arguments = ["-aAX", "--inplace", "--mkpath"]
        if let linkDest { arguments.append("--link-dest=\(linkDest.path)") }
        arguments += payload.excludes.map { "--exclude=\($0)" }
        let source = PayloadWalker().isDirectory(payload) ? payload.root.path + "/" : payload.root.path
        try await run(arguments + [source, destination(copy.path + "/")])
    }

    public func markComplete(_ copy: URL) async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("complete-\(UUID().uuidString)")
        try Data().write(to: marker)
        defer { try? FileManager.default.trashItem(at: marker, resultingItemURL: nil) }
        try await run([marker.path, destination(copy.path + "/" + CopyFolder.completionMarker)])
    }

    private func destination(_ path: String) -> String {
        receiver == nil ? path : "\(Self.host):\(path)"
    }

    private func run(_ arguments: [String]) async throws {
        guard FileManager.default.isExecutableFile(atPath: rsync.path) else { throw DestinationError.rsyncMissing }
        let rsh = receiver.map { ["--rsh=\($0.rsh)"] } ?? []
        let result = try await runner.run(executable: rsync, arguments: rsh + arguments, environment: [:], timeout: nil)
        guard result.exitCode == 0 else {
            throw DestinationError.commandFailed(String(result.stderr.suffix(Self.errorTailLength)))
        }
    }
}
```

Временный файл метки убирается через `trashItem`, не через `removeItem` (правило проекта). Если `trashItem` для `temporaryDirectory` на машине падает, заменить на запись маркера в рабочую папку приложения, передаваемую в `init` (параметр `scratch: URL`), и оставить его там: пустой файл.

- [ ] **Step 5: Запустить тесты**

Run: `swift test --package-path BackupCore --filter RsyncTransferTests`
Expected: PASS.

- [ ] **Step 6: Коммит**

```bash
git add BackupCore/Sources/BackupCore/Destinations/RsyncTransfer.swift BackupCore/Sources/BackupCore/Destinations/DestinationStore.swift BackupCore/Tests/BackupCoreTests/RsyncTransferTests.swift
git commit -m "Write copies with rsync: hard links to the previous copy, completion marker last"
```

### Task 6: Переключение ядра на новую модель хранения

Это одна задача с одним коммитом в конце: промежуточные шаги ломают сборку приложения, а коммитить красную сборку нельзя. Порядок шагов внутри важен: сначала домен и хранилище, потом движок, состояние, планировщик, статус, координатор, сборка, удаление старого, тесты ядра, затем минимальная правка приложения (Step 12), чтобы оба пакета собирались и тесты были зелёными.

**Files:**
- Modify: `BackupCore/Sources/BackupCore/Domain/Destination.swift`, `Source.swift`, `Snapshot.swift`, `AppState.swift`, `RunRecord.swift` (только документация `catchUp`)
- Modify: `BackupCore/Sources/BackupCore/Destinations/DestinationStore.swift`, `LocalFolderDestination.swift`
- Modify: `BackupCore/Sources/BackupCore/Engine/BackupEngine.swift`, `Factories.swift`
- Modify: `BackupCore/Sources/BackupCore/Scheduling/SchedulePlanner.swift`, `StateReducer.swift`
- Modify: `BackupCore/Sources/BackupCore/Status/StatusReporter.swift`, `Notice.swift`
- Modify: `BackupCore/Sources/BackupCore/Application/BackupCoordinator.swift`, `CoreAssembly.swift`
- Modify: `BackupCore/Sources/BackupCore/Storage/Store.swift`
- Delete (trash): `Destinations/SnapshotWriter.swift`, `SpaceSaving.swift`, `FileCloning.swift`, `ContentHash.swift`, `UnfinishedMark.swift`, `RcloneDestination.swift`, `RcloneLocator.swift`, `Disks.swift`, `DiskFormat.swift`, `VolumeMounts.swift`; тесты `CloneSnapshotsTests.swift`, `DiskIdentityTests.swift`, `DiskImageIdentityTests.swift`, `RcloneDestinationTests.swift`, `RcloneIntegrationTests.swift`, `SnapshotFilesTests.swift`, `UnfinishedAttemptTests.swift`, `UnverifiablePlaceTests.swift`, `CoordinatorDestinationTests.swift`, `Support/RecordingCloning.swift`, `Support/DiskImage.swift` (если его используют только удалённые тесты)
- Rewrite tests: `LocalFolderDestinationTests.swift`, `BackupEngineTests.swift`, `StateReducerTests.swift`, `SchedulePlannerTests.swift`, `StatusReporterTests.swift`, `BackupCoordinatorTests.swift`, `StoreTests.swift`, `DomainTests.swift`, `Support/EngineFakes.swift`
- App (минимум для сборки): `App/Sources/BackupEverything/Model/AppModel.swift`, `Model/Drafts.swift`, `Presentation/*.swift`, `Views/DestinationsView.swift`, `Views/SourcesView.swift`, `Views/OverviewView.swift`, `App/Tests/**`

**Interfaces (итог задачи):**

```swift
// Destinations/DestinationStore.swift
public enum DestinationError: Error, Equatable, LocalizedError {
    case notReady(DestinationReadiness)   // папка не готова: нет, чужой владелец, том без владельцев, нет учётки
    case rsyncMissing
    case commandFailed(String)
    case invalidFolderName(String)
}
public protocol DestinationStore: Sendable {
    func readiness() async -> DestinationReadiness
    func copies(of slug: String) async throws -> [Snapshot]            // готовые, по возрастанию даты
    func unfinishedCopies(of slug: String) async throws -> [Snapshot]
    func write(_ payload: Payload, sourceSlug: String, snapshotName: String) async throws
    func usedBytes() async throws -> Int64
    func url(of snapshot: Snapshot, sourceSlug: String) throws -> URL
}
extension DestinationStore { public func isAvailable() async -> Bool { await readiness() == .ready } }

// Destinations/LocalFolderDestination.swift
public struct LocalFolderDestination: DestinationStore {
    public init(root: URL, naming: SnapshotNaming, access: any DestinationAccess, transfer: RsyncTransfer)
}

// Engine/Factories.swift
public struct DefaultDestinationStoreFactory: DestinationStoreFactory {
    public init(naming: SnapshotNaming, access: any DestinationAccess, transfer: RsyncTransfer)
}

// Engine/BackupEngine.swift
public struct BackupEngine: Sendable {
    public init(providers: any SourceProviderFactory, stores: any DestinationStoreFactory, naming: SnapshotNaming, time: any TimeSource, progress: @escaping ProgressHandler = { _ in })
    public func run(source: Source, destinations: [Destination], trigger: RunTrigger) async -> RunRecord
}

// Domain/AppState.swift
public struct CachedCopy: Codable, Sendable, Equatable { public var name: String; public var date: Date }
public struct CopyCacheEntry: Codable, Sendable, Equatable { public var copies: [CachedCopy]; public var seenAt: Date; public var newest: Date? }
public struct AppState: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 2
    public var schemaVersion: Int
    public var sources: [String: SourceState]
    public var lastReminders: [String: Date]
    public var copyCache: [String: CopyCacheEntry]
    public static func deliveryKey(sourceId: UUID, destinationId: UUID) -> String
    public func sourceState(_ id: UUID) -> SourceState
    public mutating func updateSource(_ id: UUID, _ change: (inout SourceState) -> Void)
    public func cachedCopies(sourceId: UUID, destinationId: UUID) -> CopyCacheEntry?
    public func newestCopyDate(sourceId: UUID, destinationId: UUID) -> Date?
    public mutating func recordCopies(sourceId: UUID, destinationId: UUID, _ copies: [Snapshot], seenAt: Date)
    public mutating func forgetCopies(destinationId: UUID)
}

// Scheduling/StateReducer.swift
public struct StateReducer: Sendable {
    public func apply(_ record: RunRecord, to state: inout AppState)
    public func dropOrphans(config: Config, state: inout AppState)
}

// Scheduling/SchedulePlanner.swift
public struct SchedulePlanner: Sendable {
    public static let retryInterval: TimeInterval = 3600
    public init(calendar: Calendar)
    public func dueDate(for source: Source, state: SourceState) -> Date?
    public func isDue(_ source: Source, state: SourceState, now: Date) -> Bool
    public func awaitsFile(_ source: Source, state: SourceState, now: Date) -> Bool
    public func dueDateReached(_ source: Source, state: SourceState, now: Date) -> Bool
    public func destinationsNeedingCopy(of source: Source, in config: Config, newest: (UUID) -> Date?, now: Date) -> [Destination]
    public func isCopyFresh(_ source: Source, on destination: Destination, copiedAt: Date?, now: Date) -> Bool
    public func connectDeadline(for destination: Destination, newestCopy: Date?) -> Date?
    public func isSeverelyOverdue(_ source: Source, on destinations: [Destination], newest: (UUID) -> Date?, hasRun: Bool, now: Date) -> Bool
    public func nextWake(config: Config, state: AppState, now: Date, needsAttention: Bool) -> Date?
}

// Status/StatusReporter.swift: AttentionItem без .deliveryWarning; StatusReporter.report(config:state:now:unavailableDestinations:inboxScans:missingDevices:)
// Status/Notice.swift: Notice без .copiesMissing и .destinationCaughtUp
// Application/BackupCoordinator.swift: tick(), runNow(sourceId:), runAllNow(), confirmPickup, restartChain, cancelWaiting, statusReport(), currentStatus(), nextWake()
// Application/CoreAssembly.swift
public static func makeCoordinator(dataDirectory: URL, workDirectory: URL, timeZone: TimeZone = .current, runner: any ProcessRunner = SystemProcessRunner(), time: any TimeSource = SystemTimeSource(), rsync: URL = RsyncTransfer.homebrewRsync, receiver: ReceiverCommand? = .standard, access: any DestinationAccess = SystemDestinationAccess(), quit: any QuitSignal = ProcessGroups.shared, trash: @escaping ManualExportInbox.Trash = …, progress: @escaping ProgressHandler = { _ in }) -> BackupCoordinator
```

- [ ] **Step 1: Домен: назначение без диска и облака, источник без `savesSpace`, снимок без манифеста**

`Domain/Destination.swift` целиком:

```swift
import Foundation

public enum ExpectedEvery: Codable, Sendable, Equatable {
    case always
    case days(Int)
}

public enum DestinationKind: Codable, Sendable, Equatable {
    case localFolder(path: String)

    private enum CodingKeys: String, CodingKey {
        case localFolder, rclone
    }

    private enum LocalFolderKeys: String, CodingKey {
        case path
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.rclone) {
            throw DecodingError.dataCorruptedError(forKey: .rclone, in: container, debugDescription: "Cloud destinations are not supported by this version.")
        }
        let folder = try container.nestedContainer(keyedBy: LocalFolderKeys.self, forKey: .localFolder)
        self = .localFolder(path: try folder.decode(String.self, forKey: .path))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        var folder = container.nestedContainer(keyedBy: LocalFolderKeys.self, forKey: .localFolder)
        if case let .localFolder(path) = self { try folder.encode(path, forKey: .path) }
    }
}

public struct Destination: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var kind: DestinationKind
    public var expectedEvery: ExpectedEvery

    public init(id: UUID = UUID(), name: String, kind: DestinationKind, expectedEvery: ExpectedEvery = .always) {
        self.id = id
        self.name = name
        self.kind = kind
        self.expectedEvery = expectedEvery
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, expectedEvery
    }

    public var path: String {
        if case let .localFolder(path) = kind { return path }
        return ""
    }
}
```

Явные `CodingKeys` без `disk` отбрасывают поле `disk` старых настроек при чтении и не пишут его. `path` нужен приложению и `ExcessCopies`.

`Domain/Source.swift`: удалить свойство `savesSpace`, параметр `init`, строку в `CodingKeys` оставить (`case savesSpace` не нужен: ключ просто игнорируется), убрать `savesSpace = …` из `init(from:)` и `encode`, убрать doc-комментарий.

`Domain/Snapshot.swift`: оставить только `Snapshot` и `SnapshotNaming`; `SnapshotManifest` и `SnapshotFile` удалить. Перенести проверку служебного имени в `CopyFolder`:

```swift
// добавить в CopyFolder.swift
extension CopyFolder {
    /// A source item named like the completion marker at the top of a copy would mark the copy complete before it is.
    public static func checkTopLevelNames(of entries: [PayloadEntry]) throws {
        let reserved = GlobPattern(completionMarker)
        if let clash = entries.first(where: { !$0.relativePath.contains("/") && reserved.matches($0.relativePath) }) {
            throw SourceError.reservedName(clash.relativePath)
        }
    }
}
```

`Store.loadConfig`: ошибку декодирования облачного назначения показать словами. Заменить тело `guard let config = try? …decode… else { throw .corrupted }` на:

```swift
        let config: Config
        do {
            config = try JSONCoding.decoder().decode(Config.self, from: data)
        } catch let DecodingError.dataCorrupted(context) where context.debugDescription.contains("Cloud destinations") {
            throw StoreError.cloudDestinationUnsupported
        } catch {
            throw StoreError.corrupted(file: configURL.lastPathComponent)
        }
```
и в `StoreError` случай `cloudDestinationUnsupported` с текстом: `"config.json contains a cloud (rclone) destination. This version keeps copies only in folders: remove the cloud destination from config.json."`.

- [ ] **Step 2: Протокол назначения и локальная папка**

`Destinations/DestinationStore.swift` целиком:

```swift
import Foundation

public enum DestinationError: Error, Equatable, LocalizedError {
    case notReady(DestinationReadiness)
    case rsyncMissing
    case commandFailed(String)
    case invalidFolderName(String)

    public var errorDescription: String? {
        switch self {
        case let .notReady(readiness):
            Self.describe(readiness)
        case .rsyncMissing:
            "rsync 3 is not installed. Install it with “brew install rsync”."
        case let .commandFailed(output):
            "rsync failed: \(output)"
        case let .invalidFolderName(name):
            "The folder for copies of this source is named “\(name)”, which is not a single folder name. Nothing was read or written. Fix “slug” of the source in config.json."
        }
    }

    public static func describe(_ readiness: DestinationReadiness) -> String {
        switch readiness {
        case .ready: "The destination is ready."
        case .folderMissing: "The destination folder is not there (disk not connected?)."
        case let .notOwnedByBackupAccount(owner): "The destination folder belongs to “\(owner)”, not to the backup account. Run the setup script."
        case .volumeIgnoresOwners: "The disk ignores file owners, so copies there cannot be protected. Run the setup script: it enables ownership on the disk."
        case .accountMissing: "The backup account “\(SystemDestinationAccess.roleAccount)” does not exist. Run the setup script."
        }
    }
}

public protocol DestinationStore: Sendable {
    func readiness() async -> DestinationReadiness
    /// Finished copies in the folder of the slug, oldest first.
    func copies(of slug: String) async throws -> [Snapshot]
    func unfinishedCopies(of slug: String) async throws -> [Snapshot]
    func write(_ payload: Payload, sourceSlug: String, snapshotName: String) async throws
    func usedBytes() async throws -> Int64
    func url(of snapshot: Snapshot, sourceSlug: String) throws -> URL
}

extension DestinationStore {
    public func isAvailable() async -> Bool {
        await readiness() == .ready
    }
}
```

`Destinations/LocalFolderDestination.swift` целиком:

```swift
import Foundation

/// A folder owned by the backup account. The app only reads it; rsync writes into it through the receiver, and a copy
/// counts once its completion marker is there. Nothing here deletes or renames.
public struct LocalFolderDestination: DestinationStore {
    private let folder: CopyFolder
    private let access: any DestinationAccess
    private let transfer: RsyncTransfer

    public init(root: URL, naming: SnapshotNaming, access: any DestinationAccess, transfer: RsyncTransfer) {
        folder = CopyFolder(root: root, naming: naming)
        self.access = access
        self.transfer = transfer
    }

    public func readiness() async -> DestinationReadiness {
        access.readiness(of: folder.root)
    }

    public func copies(of slug: String) async throws -> [Snapshot] {
        try folder.copies(of: slug)
    }

    public func unfinishedCopies(of slug: String) async throws -> [Snapshot] {
        try folder.unfinished(of: slug)
    }

    public func write(_ payload: Payload, sourceSlug: String, snapshotName: String) async throws {
        let readiness = await readiness()
        guard readiness == .ready else { throw DestinationError.notReady(readiness) }
        let target = try folder.sourceFolder(sourceSlug).appendingPathComponent(snapshotName, isDirectory: true)
        let previous = try folder.newestCopy(of: sourceSlug).map { try folder.url(of: $0, slug: sourceSlug) }
        try await transfer.write(payload, into: target, linkDest: previous)
        try await transfer.markComplete(target)
    }

    public func usedBytes() async throws -> Int64 {
        let readiness = await readiness()
        guard readiness == .ready else { throw DestinationError.notReady(readiness) }
        return try DestinationUsage().bytes(under: folder.root)
    }

    public func url(of snapshot: Snapshot, sourceSlug: String) throws -> URL {
        try folder.url(of: snapshot, slug: sourceSlug)
    }
}
```

`DestinationUsage.bytes` бросает `DestinationError.unavailable`, которого больше нет: заменить на `DestinationError.notReady(.folderMissing)`. Добавить в `DestinationUsage.add` учёт жёстких ссылок: файл с `st_nlink > 1` считать один раз по `(st_dev, st_ino)`:

```swift
    private func add(_ directory: String, to total: inout Int64, countedClones: inout Set<UInt64>, countedLinks: inout Set<String>) { … 
            case S_IFREG:
                if info.st_nlink > 1 {
                    guard countedLinks.insert("\(info.st_dev):\(info.st_ino)").inserted else { continue }
                }
                …
```
(и завести `var countedLinks: Set<String> = []` в `bytes(under:)`).

`Engine/Factories.swift`: заменить `DefaultDestinationStoreFactory` на

```swift
public struct DefaultDestinationStoreFactory: DestinationStoreFactory {
    private let naming: SnapshotNaming
    private let access: any DestinationAccess
    private let transfer: RsyncTransfer

    public init(naming: SnapshotNaming, access: any DestinationAccess, transfer: RsyncTransfer) {
        self.naming = naming
        self.access = access
        self.transfer = transfer
    }

    public func store(for destination: Destination) -> any DestinationStore {
        switch destination.kind {
        case let .localFolder(path):
            LocalFolderDestination(root: Paths.url(path), naming: naming, access: access, transfer: transfer)
        }
    }
}
```

- [ ] **Step 3: Движок: только запись**

`Engine/BackupEngine.swift` целиком:

```swift
import Foundation

public struct BackupEngine: Sendable {
    private let providers: any SourceProviderFactory
    private let stores: any DestinationStoreFactory
    private let naming: SnapshotNaming
    private let time: any TimeSource
    private let progress: ProgressHandler
    private let walker = PayloadWalker()

    public init(
        providers: any SourceProviderFactory,
        stores: any DestinationStoreFactory,
        naming: SnapshotNaming,
        time: any TimeSource,
        progress: @escaping ProgressHandler = { _ in }
    ) {
        self.providers = providers
        self.stores = stores
        self.naming = naming
        self.time = time
        self.progress = progress
    }

    public func run(source: Source, destinations: [Destination], trigger: RunTrigger) async -> RunRecord {
        let record = await perform(source: source, destinations: destinations, trigger: trigger)
        progress(.finished(sourceId: source.id))
        return record
    }

    private func perform(source: Source, destinations: [Destination], trigger: RunTrigger) async -> RunRecord {
        var record = RunRecord(sourceId: source.id, sourceName: source.name, trigger: trigger, startedAt: time.now, finishedAt: time.now)
        var reachable: [UUID: any DestinationStore] = [:]
        for destination in destinations {
            let store = stores.store(for: destination)
            if await store.isAvailable() { reachable[destination.id] = store }
        }
        guard !reachable.isEmpty else {
            record.deliveries = destinations.map { Delivery(destinationId: $0.id, destinationName: $0.name, outcome: .unavailable) }
            record.finishedAt = time.now
            return record
        }

        let provider = providers.provider(for: source)
        let payload: Payload
        progress(.collecting(sourceId: source.id))
        do {
            payload = try await provider.collect(at: record.startedAt) { [progress] text in
                progress(.status(sourceId: source.id, text: text))
            }
        } catch {
            record.collectError = error.localizedDescription
            record.finishedAt = time.now
            return record
        }
        let stats: PayloadStats
        do {
            let entries = try walker.entries(of: payload)
            try CopyFolder.checkTopLevelNames(of: entries)
            stats = walker.stats(of: entries)
            guard stats.fileCount > 0 else { throw SourceError.emptyResult }
        } catch {
            record.collectError = error.localizedDescription
            if let problem = release(payload, of: provider, delivered: .nowhere) {
                record.collectError = "\(error.localizedDescription) \(problem)"
            }
            record.finishedAt = time.now
            return record
        }

        let snapshotName = naming.name(for: payload.collectedAt)
        record.snapshotName = snapshotName
        record.collectedAt = payload.collectedAt
        record.fileCount = stats.fileCount
        record.totalBytes = stats.totalBytes
        record.details = payload.details
        record.deliversAnOlderCopy = payload.madeEarlier

        for destination in destinations {
            let outcome: DeliveryOutcome
            if let store = reachable[destination.id] {
                progress(.delivering(sourceId: source.id, destinationId: destination.id))
                outcome = await deliver(payload, snapshotName: snapshotName, slug: source.slug, to: store)
            } else {
                outcome = .unavailable
            }
            record.deliveries.append(Delivery(destinationId: destination.id, destinationName: destination.name, outcome: outcome))
        }
        if let problem = release(payload, of: provider, delivered: record.payloadDelivery) {
            record.deliveries = record.deliveries.map { delivery in
                var delivery = delivery
                delivery.outcome = delivery.outcome.adding(problem)
                return delivery
            }
        }
        record.finishedAt = time.now
        return record
    }

    /// A copy of this name already there (the same package delivered earlier) counts as delivered.
    private func deliver(_ payload: Payload, snapshotName: String, slug: String, to store: any DestinationStore) async -> DeliveryOutcome {
        do {
            if try await !store.copies(of: slug).contains(where: { $0.name == snapshotName }) {
                try await store.write(payload, sourceSlug: slug, snapshotName: snapshotName)
            }
            return .delivered(pruned: 0, warning: nil)
        } catch {
            return .failed(message: error.localizedDescription)
        }
    }

    private func release(_ payload: Payload, of provider: any SourceProvider, delivered: PayloadDelivery) -> String? {
        do {
            try provider.finish(payload, delivered: delivered)
            return nil
        } catch {
            return "Could not clear the work folder: \(error.localizedDescription)"
        }
    }
}

private extension RunRecord {
    var payloadDelivery: PayloadDelivery {
        if deliveries.allSatisfy(\.outcome.isDelivered) { return .everywhere }
        return deliveries.contains(where: \.outcome.isDelivered) ? .partly : .nowhere
    }
}
```

`DeliveryOutcome.delivered(pruned:warning:)` остаётся ради чтения старой истории; новые записи всегда `pruned: 0, warning: nil`.

- [ ] **Step 4: Состояние v2 и редьюсер**

`Domain/AppState.swift`: оставить `RunStart`, `ChainState`, `SourceState` как есть; удалить `DestinationState`, `Debt`; `AppState` переписать:

```swift
public struct CachedCopy: Codable, Sendable, Equatable {
    public var name: String
    public var date: Date

    public init(name: String, date: Date) {
        self.name = name
        self.date = date
    }
}

/// What the copies of a source on a destination looked like when the destination was last reachable. For showing and
/// reminding while the destination is away; never a ground for writing.
public struct CopyCacheEntry: Codable, Sendable, Equatable {
    public var copies: [CachedCopy]
    public var seenAt: Date

    public init(copies: [CachedCopy], seenAt: Date) {
        self.copies = copies
        self.seenAt = seenAt
    }

    public var newest: Date? { copies.map(\.date).max() }
}

public struct AppState: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public var sources: [String: SourceState]
    public var lastReminders: [String: Date]
    public var copyCache: [String: CopyCacheEntry]

    public init() {
        schemaVersion = Self.currentSchemaVersion
        sources = [:]
        lastReminders = [:]
        copyCache = [:]
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, sources, lastReminders, copyCache
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        sources = try container.decodeIfPresent([String: SourceState].self, forKey: .sources) ?? [:]
        lastReminders = try container.decodeIfPresent([String: Date].self, forKey: .lastReminders) ?? [:]
        copyCache = try container.decodeIfPresent([String: CopyCacheEntry].self, forKey: .copyCache) ?? [:]
    }

    public static func deliveryKey(sourceId: UUID, destinationId: UUID) -> String {
        "\(sourceId.uuidString)|\(destinationId.uuidString)"
    }

    public func sourceState(_ id: UUID) -> SourceState {
        sources[id.uuidString] ?? SourceState()
    }

    public mutating func updateSource(_ id: UUID, _ change: (inout SourceState) -> Void) {
        var value = sourceState(id)
        change(&value)
        sources[id.uuidString] = value
    }

    public func cachedCopies(sourceId: UUID, destinationId: UUID) -> CopyCacheEntry? {
        copyCache[Self.deliveryKey(sourceId: sourceId, destinationId: destinationId)]
    }

    public func newestCopyDate(sourceId: UUID, destinationId: UUID) -> Date? {
        cachedCopies(sourceId: sourceId, destinationId: destinationId)?.newest
    }

    public mutating func recordCopies(sourceId: UUID, destinationId: UUID, _ copies: [Snapshot], seenAt: Date) {
        copyCache[Self.deliveryKey(sourceId: sourceId, destinationId: destinationId)] = CopyCacheEntry(
            copies: copies.map { CachedCopy(name: $0.name, date: $0.date) },
            seenAt: seenAt
        )
    }

    public mutating func forgetCopies(destinationId: UUID) {
        let suffix = "|" + destinationId.uuidString
        copyCache = copyCache.filter { !$0.key.hasSuffix(suffix) }
    }
}
```

Состояние прежней версии (`schemaVersion: 1`) читается этим же декодером: лишние ключи (`debts`, `lastDelivered`, …) отбрасываются, `copyCache` пуст. В `Store.loadState` убрать ветку `learningDeliveryDates` и после чтения ставить `schemaVersion = AppState.currentSchemaVersion`:

```swift
        guard state.schemaVersion <= AppState.currentSchemaVersion else {
            throw StoreError.unsupportedVersion(file: stateURL.lastPathComponent, version: state.schemaVersion)
        }
        var current = state
        current.schemaVersion = AppState.currentSchemaVersion
        return current
```

`Scheduling/StateReducer.swift` целиком:

```swift
import Foundation

public struct StateReducer: Sendable {
    public init() {}

    /// What a run says about its source: when it ran, when it last succeeded, what failed and when to try again.
    /// Nothing about copies: those are read from the destinations.
    public func apply(_ record: RunRecord, to state: inout AppState) {
        state.updateSource(record.sourceId) {
            $0.lastRun = record.startedAt
            if let failure = record.firstFailure {
                $0.lastError = failure
                $0.retryAfter = record.finishedAt.addingTimeInterval(SchedulePlanner.retryInterval)
            } else {
                $0.lastError = nil
                $0.retryAfter = nil
            }
            if record.deliveries.contains(where: \.outcome.isDelivered) {
                $0.lastSuccess = max($0.lastSuccess ?? .distantPast, record.copyCollectedAt)
            }
        }
    }

    public func dropOrphans(config: Config, state: inout AppState) {
        let sourceKeys = Set(config.sources.map(\.id.uuidString))
        state.sources = state.sources.filter { sourceKeys.contains($0.key) }
        let pairs = Set(config.sources.flatMap { source in
            config.destinations(of: source).map { AppState.deliveryKey(sourceId: source.id, destinationId: $0.id) }
        })
        state.copyCache = state.copyCache.filter { pairs.contains($0.key) }
    }
}
```

- [ ] **Step 5: Планировщик**

`Scheduling/SchedulePlanner.swift` целиком:

```swift
import Foundation

public struct SchedulePlanner: Sendable {
    public static let retryInterval: TimeInterval = 3600

    private let calendar: Calendar

    public init(calendar: Calendar) {
        self.calendar = calendar
    }

    public func dueDate(for source: Source, state: SourceState) -> Date? {
        guard source.enabled, source.schedule != .manual else { return nil }
        guard let lastRun = state.lastRun else { return source.createdAt }
        return source.schedule.nextDue(after: lastRun, calendar: calendar)
    }

    public func isDue(_ source: Source, state: SourceState, now: Date) -> Bool {
        guard let due = dueDate(for: source, state: state), due <= now else { return false }
        return mayRetry(state, now: now)
    }

    public func mayRetry(_ state: SourceState, now: Date) -> Bool {
        state.retryAfter.map { $0 <= now } ?? true
    }

    /// A manual step at the start of a source is accepted only when it is awaited: the time has come or the button was pressed.
    public func awaitsFile(_ source: Source, state: SourceState, now: Date) -> Bool {
        state.armedAt != nil || dueDateReached(source, state: state, now: now)
    }

    public func dueDateReached(_ source: Source, state: SourceState, now: Date) -> Bool {
        dueDate(for: source, state: state).map { $0 <= now } ?? false
    }

    /// Destinations of the source whose newest copy is older than one interval of the schedule, or that hold none.
    /// `newest` tells the date of the newest copy on a destination. A source without a schedule needs nothing by itself.
    public func destinationsNeedingCopy(of source: Source, in config: Config, newest: (UUID) -> Date?, now: Date) -> [Destination] {
        guard source.enabled, source.schedule != .manual else { return [] }
        return config.destinations(of: source).filter { destination in
            guard let copiedAt = newest(destination.id),
                  let next = source.schedule.nextDue(after: copiedAt, calendar: calendar) else { return true }
            return next <= now
        }
    }

    /// Whether the newest copy on the destination is within its rhythm (5.5): on a disk that can stay unplugged, until
    /// its connect deadline; elsewhere, until the next backup by the schedule plus the time a run takes.
    public func isCopyFresh(_ source: Source, on destination: Destination, copiedAt: Date?, now: Date) -> Bool {
        guard let copiedAt else { return false }
        switch destination.expectedEvery {
        case .days:
            return connectDeadline(for: destination, newestCopy: copiedAt).map { $0 > now } ?? true
        case .always:
            guard let next = source.schedule.nextDue(after: copiedAt, calendar: calendar) else { return true }
            return next.addingTimeInterval(Self.retryInterval) > now
        }
    }

    /// When a “from time to time” disk should be connected again: its interval after the newest copy on it.
    public func connectDeadline(for destination: Destination, newestCopy: Date?) -> Date? {
        guard case let .days(days) = destination.expectedEvery, let newestCopy else { return nil }
        return calendar.date(byAdding: .day, value: days, to: newestCopy)
    }

    /// Long overdue: two backups by the schedule were missed after the end of the rhythm of every copy of the source.
    /// Without any copy, each destination counts from the creation of the source.
    public func isSeverelyOverdue(_ source: Source, on destinations: [Destination], newest: (UUID) -> Date?, hasRun: Bool, now: Date) -> Bool {
        guard source.enabled, hasRun, !destinations.isEmpty else { return false }
        let deadlines = destinations.map { severeDeadline(source, on: $0, copiedAt: newest($0.id) ?? source.createdAt) }
        guard deadlines.allSatisfy({ $0 != nil }) else { return false }
        return deadlines.compactMap { $0 }.allSatisfy { now > $0 }
    }

    private func severeDeadline(_ source: Source, on destination: Destination, copiedAt: Date) -> Date? {
        guard let due = source.schedule.nextDue(after: copiedAt, calendar: calendar) else { return nil }
        let rhythmEnd = max(due, connectDeadline(for: destination, newestCopy: copiedAt) ?? due)
        guard let first = source.schedule.nextDue(after: rhythmEnd, calendar: calendar) else { return nil }
        return source.schedule.nextDue(after: first, calendar: calendar)
    }

    public func nextWake(config: Config, state: AppState, now: Date, needsAttention: Bool) -> Date? {
        var candidates: [Date] = []
        for source in config.sources where source.enabled {
            let sourceState = state.sourceState(source.id)
            if let retryAfter = sourceState.retryAfter { candidates.append(retryAfter) }
            for destination in config.destinations(of: source) {
                guard let copiedAt = state.newestCopyDate(sourceId: source.id, destinationId: destination.id) else { continue }
                if let next = source.schedule.nextDue(after: copiedAt, calendar: calendar) { candidates.append(next) }
                if let deadline = connectDeadline(for: destination, newestCopy: copiedAt) { candidates.append(deadline) }
            }
            if let due = dueDate(for: source, state: sourceState) { candidates.append(due) }
        }
        if needsAttention { candidates.append(now.addingTimeInterval(Self.retryInterval)) }
        return candidates.filter { $0 > now }.min()
    }
}
```

- [ ] **Step 6: Статус и уведомления**

`Status/Notice.swift`: удалить случаи `destinationCaughtUp` и `copiesMissing`. Остальное без изменений.

`Status/StatusReporter.swift`: удалить случай `AttentionItem.deliveryWarning` (и его ветки в `severity`, `sourceId`); `report` переписать:

```swift
    public func report(
        config: Config,
        state: AppState,
        now: Date,
        unavailableDestinations: Set<UUID>,
        inboxScans: [UUID: InboxScan],
        missingDevices: Set<UUID> = []
    ) -> StatusReport {
        var items: [AttentionItem] = []
        var fresh: Set<UUID> = []
        var expected: Set<UUID> = []
        for source in config.sources where source.enabled {
            let sourceState = state.sourceState(source.id)
            let destinations = config.destinations(of: source)
            if destinations.isEmpty {
                items.append(.noDestinations(sourceId: source.id))
                continue
            }
            let newest = { (id: UUID) in state.newestCopyDate(sourceId: source.id, destinationId: id) }
            let copies = destinations.map { newest($0.id) }
            let newestCopy = copies.compactMap { $0 }.max()
            if sourceState.lastRun != nil || newestCopy != nil {
                expected.insert(source.id)
                let outdated = zip(destinations, copies)
                    .filter { !planner.isCopyFresh(source, on: $0, copiedAt: $1, now: now) }
                    .map(\.0.id)
                if outdated.isEmpty {
                    fresh.insert(source.id)
                } else {
                    items.append(.copiesOutdated(sourceId: source.id, OutdatedCopies(
                        destinationIds: outdated,
                        freshElsewhere: outdated.count < destinations.count,
                        noCopyAnywhere: newestCopy == nil
                    )))
                }
            }
            let scan = inboxScans[source.id]
            let heldBack = scan.flatMap { $0.downloadInProgress && !$0.files.isEmpty ? $0 : nil }
            if let message = (heldBack == nil ? sourceState.chain?.failure : nil) ?? sourceState.lastError {
                items.append(.runFailed(sourceId: source.id, message: message))
            }
            if planner.isSeverelyOverdue(source, on: destinations, newest: newest, hasRun: sourceState.lastRun != nil, now: now) {
                items.append(.severelyOverdue(sourceId: source.id))
            }
            guard source.needsHuman else { continue }
            if let heldBack {
                items.append(.filesAwaitingPickup(sourceId: source.id, fileCount: heldBack.files.count, totalBytes: heldBack.totalBytes, downloadInProgress: true))
                continue
            }
            items.append(contentsOf: humanStepItems(source, state: sourceState, scan: scan, deviceMissing: missingDevices.contains(source.id), now: now))
        }
        for destination in config.destinations where unavailableDestinations.contains(destination.id) {
            let users = config.sources.filter { $0.enabled && $0.destinationIds.contains(destination.id) }
            guard !users.isEmpty else { continue }
            switch destination.expectedEvery {
            case .always:
                items.append(.destinationUnavailable(destinationId: destination.id))
            case .days:
                let deadlines = users.map { source in
                    planner.connectDeadline(for: destination, newestCopy: state.newestCopyDate(sourceId: source.id, destinationId: destination.id)) ?? now
                }
                if let earliest = deadlines.min(), earliest <= now {
                    items.append(.connectDestination(destinationId: destination.id))
                }
            }
        }
        return StatusReport(items: items, fresh: fresh, expected: expected)
    }
```

`humanStepItems` без изменений. Убрать `state.pausingDisabledSources` (метода больше нет).

- [ ] **Step 7: Координатор**

`Application/BackupCoordinator.swift` целиком. Логика цепочек ручных шагов (`advanceChain`, `retriesByItself`, `stepFailure`, `performConfirmPickup`, `performRestartChain`, `performCancelWaiting`, `startsWithoutWaiting`, `enqueue`, `announce`, `forgetRemovedSources`) переносится из нынешнего файла без изменений, кроме мест, где упоминались `Debt`/`hasDebt` (в `.completed` цикл по `destinations where !state.hasDebt` убрать целиком: долги больше не заводятся). Остальное:

```swift
import Foundation

public struct CurrentStatus: Sendable, Equatable {
    public let config: Config
    public let state: AppState
    public let report: StatusReport
}

public actor BackupCoordinator {
    private let store: Store
    private let engine: BackupEngine
    private let inbox: ManualExportInbox
    private let chains: StepChainRunner
    private let stores: any DestinationStoreFactory
    private let time: any TimeSource
    private let quit: any QuitSignal
    private let progress: ProgressHandler
    private let planner: SchedulePlanner
    private let reporter: StatusReporter
    private let reminders = ReminderPlanner()
    private let reducer = StateReducer()
    private var queueTail: Task<Void, Never>?

    private enum ChainMode { case tick, runAll, runNow, confirm }

    public init(store: Store, engine: BackupEngine, inbox: ManualExportInbox, chains: StepChainRunner, stores: any DestinationStoreFactory,
                time: any TimeSource, calendar: Calendar, quit: any QuitSignal = ProcessGroups.shared, progress: @escaping ProgressHandler = { _ in }) {
        // как сейчас
    }

    /// Sources the check will certainly run are marked “queued” right away, before their turn.
    public func tick() async throws -> TickResult {
        var announced: Set<UUID> = []
        if let config = try? store.loadConfig(), let state = try? loadState(for: config) {
            let foreseen = await foreseenWork(config: config, state: state, now: time.now)
            announce(foreseen)
            announced = Set(foreseen.map(\.id))
        }
        return try await enqueue { [announced] in try await self.performTick(announced: announced) }
    }

    public func runNow(sourceId: UUID) async throws -> TickResult {
        if let config = try? store.loadConfig(), let source = config.source(sourceId), !config.destinations(of: source).isEmpty, startsWithoutWaiting(source) {
            announce([source])
        }
        return try await enqueue { try await self.performRunNow(sourceId: sourceId) }
    }

    public func runAllNow() async throws -> TickResult {
        if let config = try? store.loadConfig() {
            announce(config.sources.filter { $0.enabled && !config.destinations(of: $0).isEmpty && startsWithoutWaiting($0) })
        }
        return try await enqueue { try await self.performRunAllNow() }
    }

    public func confirmPickup(sourceId: UUID) async throws -> TickResult { try await enqueue { try await self.performConfirmPickup(sourceId: sourceId) } }
    public func restartChain(sourceId: UUID) async throws -> TickResult { try await enqueue { try await self.performRestartChain(sourceId: sourceId) } }
    public func cancelWaiting(sourceId: UUID) async throws -> TickResult { try await enqueue { try await self.performCancelWaiting(sourceId: sourceId) } }

    public func statusReport() async throws -> StatusReport { try await currentStatus().report }

    /// The settings, the state with the copy cache refreshed from every reachable destination, and the status from both.
    public func currentStatus() async throws -> CurrentStatus {
        let config = try store.loadConfig()
        var state = try loadState(for: config)
        let unavailable = await refreshCache(config: config, state: &state)
        try store.saveState(state)
        return CurrentStatus(config: config, state: state, report: await report(config: config, state: state, unavailable: unavailable, now: time.now))
    }

    public func nextWake() async throws -> Date? {
        let current = try await currentStatus()
        return planner.nextWake(config: current.config, state: current.state, now: time.now, needsAttention: current.report.overall != .ok)
    }

    /// The saved state without what the settings no longer know.
    private func loadState(for config: Config) throws -> AppState {
        var state = try store.loadState()
        reducer.dropOrphans(config: config, state: &state)
        return state
    }

    /// Lists the copies of every source on every reachable destination into the cache. Returns the unreachable destinations.
    private func refreshCache(config: Config, state: inout AppState) async -> Set<UUID> {
        var unavailable: Set<UUID> = []
        let now = time.now
        for destination in config.destinations {
            let store = stores.store(for: destination)
            guard await store.isAvailable() else {
                unavailable.insert(destination.id)
                continue
            }
            for source in config.sources where source.destinationIds.contains(destination.id) {
                guard let copies = try? await store.copies(of: source.slug) else { continue }
                state.recordCopies(sourceId: source.id, destinationId: destination.id, copies, seenAt: now)
            }
        }
        return unavailable
    }

    private func foreseenWork(config: Config, state: AppState, now: Date) async -> [Source] {
        var work: [Source] = []
        for source in config.sources where source.enabled && !source.needsHuman {
            let targets = await targets(of: source, config: config, state: state, now: now)
            if !targets.isEmpty { work.append(source) }
        }
        return work
    }

    /// Reachable destinations of the source that need a copy now, by the copies actually there.
    private func targets(of source: Source, config: Config, state: AppState, now: Date) async -> [Destination] {
        guard planner.mayRetry(state.sourceState(source.id), now: now) else { return [] }
        let needing = planner.destinationsNeedingCopy(of: source, in: config, newest: { state.newestCopyDate(sourceId: source.id, destinationId: $0) }, now: now)
        var reachable: [Destination] = []
        for destination in needing where await stores.store(for: destination).isAvailable() {
            reachable.append(destination)
        }
        return reachable
    }

    private func performTick(announced: Set<UUID> = []) async throws -> TickResult {
        let config = try store.loadConfig()
        var state = try loadState(for: config)
        forgetRemovedSources(config)
        var runs: [RunRecord] = []
        var notices: [Notice] = []
        _ = await refreshCache(config: config, state: &state)
        var planned: [(Source, [Destination])] = []
        for source in config.sources where source.enabled && !source.needsHuman {
            let targets = await targets(of: source, config: config, state: state, now: time.now)
            if !targets.isEmpty { planned.append((source, targets)) }
        }
        announce(planned.map(\.0).filter { !announced.contains($0.id) })
        for (source, targets) in planned {
            try await execute(source, targets, .scheduled, state: &state, runs: &runs)
        }
        for source in config.sources where source.enabled && source.needsHuman {
            try await advanceChain(source, config: config, mode: .tick, state: &state, runs: &runs, notices: &notices)
        }
        let unavailable = await refreshCache(config: config, state: &state)
        notices += failureNotices(runs) + (await reminderNotices(config: config, state: &state, unavailable: unavailable))
        try store.saveState(state)
        return TickResult(runs: runs, notices: notices)
    }

    private func performRunNow(sourceId: UUID) async throws -> TickResult {
        let config = try store.loadConfig()
        var state = try loadState(for: config)
        var runs: [RunRecord] = []
        guard let source = config.source(sourceId) else { return TickResult() }
        let destinations = config.destinations(of: source)
        guard !destinations.isEmpty else { return TickResult() }
        guard source.needsHuman else {
            try await execute(source, destinations, .manual, state: &state, runs: &runs)
            try store.saveState(state)
            return TickResult(runs: runs, notices: failureNotices(runs))
        }
        if state.sourceState(source.id).chain == nil {
            state.updateSource(source.id) { $0.armedAt = $0.armedAt ?? self.time.now }
            try store.saveState(state)
        }
        var notices: [Notice] = []
        try await advanceChain(source, config: config, mode: .runNow, state: &state, runs: &runs, notices: &notices)
        try store.saveState(state)
        return TickResult(runs: runs, notices: notices + failureNotices(runs))
    }

    private func performRunAllNow() async throws -> TickResult {
        let config = try store.loadConfig()
        var state = try loadState(for: config)
        var runs: [RunRecord] = []
        let sources = config.sources.filter { $0.enabled && !$0.needsHuman && !config.destinations(of: $0).isEmpty }
        announce(sources)
        for source in sources {
            try await execute(source, config.destinations(of: source), .manual, state: &state, runs: &runs)
        }
        var notices: [Notice] = []
        for source in config.sources where source.enabled && source.needsHuman {
            try await advanceChain(source, config: config, mode: .runAll, state: &state, runs: &runs, notices: &notices)
        }
        try store.saveState(state)
        return TickResult(runs: runs, notices: notices + failureNotices(runs))
    }

    private func execute(_ source: Source, _ destinations: [Destination], _ trigger: RunTrigger, state: inout AppState, runs: inout [RunRecord]) async throws {
        let record = await engine.run(source: source, destinations: destinations, trigger: trigger)
        try register(record, trigger: trigger, state: &state, runs: &runs)
    }

    /// Once the app is quitting, a run's outcome is not recorded: its commands were stopped by the quit, not broken.
    private func register(_ record: RunRecord, trigger: RunTrigger, state: inout AppState, runs: inout [RunRecord]) throws {
        guard !quit.isQuitting else { return }
        reducer.apply(record, to: &state)
        try store.saveState(state)
        if record.isDeferredOnly && trigger != .manual { return }
        try store.appendRun(record)
        runs.append(record)
    }

    private func reminderNotices(config: Config, state: inout AppState, unavailable: Set<UUID>) async -> [Notice] {
        let now = time.now
        let report = await report(config: config, state: state, unavailable: unavailable, now: now)
        let reminded = reminders.dueReminders(in: report, state: state, now: now)
        reminders.record(reminded, report: report, state: &state, now: now)
        var notices: [Notice] = []
        for item in reminded {
            switch item {
            case let .manualExportDue(sourceId):
                if let source = config.source(sourceId) { notices.append(.manualExportDue(sourceId: sourceId, sourceName: source.name)) }
            case let .deviceDue(sourceId):
                if let source = config.source(sourceId) { notices.append(.deviceDue(sourceId: sourceId, sourceName: source.name)) }
            case let .connectDestination(destinationId):
                guard let destination = config.destination(destinationId) else { continue }
                let onlyHere = config.sources.filter { source in
                    source.enabled && source.destinationIds.contains(destinationId) && !config.destinations(of: source).contains { other in
                        other.id != destinationId && state.newestCopyDate(sourceId: source.id, destinationId: other.id) != nil
                    }
                }
                notices.append(.connectDestination(destinationId: destinationId, destinationName: destination.name, onlyCopyOf: onlyHere.map(\.name)))
            default:
                break
            }
        }
        return notices
    }

    private func failureNotices(_ runs: [RunRecord]) -> [Notice] {
        runs.compactMap { run in run.firstFailure.map { .runFailed(sourceId: run.sourceId, sourceName: run.sourceName, message: $0) } }
    }

    private func report(config: Config, state: AppState, unavailable: Set<UUID>, now: Date) async -> StatusReport {
        var scans: [UUID: InboxScan] = [:]
        var missingDevices: Set<UUID> = []
        for source in config.sources where source.enabled && source.needsHuman {
            let sourceState = state.sourceState(source.id)
            guard sourceState.chain != nil || planner.awaitsFile(source, state: sourceState, now: now) else { continue }
            scans[source.id] = chains.awaitedFiles(source, chain: sourceState.chain, lastPickup: sourceState.lastPickup)
            if chains.awaitsDevice(source, chain: sourceState.chain) { missingDevices.insert(source.id) }
        }
        return reporter.report(config: config, state: state, now: now, unavailableDestinations: unavailable, inboxScans: scans, missingDevices: missingDevices)
    }
}
```

В `advanceChain` при `.completed` вызывать `execute(source, destinations, .pickup, state: &state, runs: &runs)` со всеми назначениями источника: движок сам пропустит те, где копия с этим именем уже есть, а недоступные получат `.unavailable`, и пакет останется в `pending` (`PayloadDelivery.partly`). Сигнатуры `advanceChain` и `execute` меняются: параметр `config:` у `execute` больше не нужен.

`Application/CoreAssembly.swift`: сигнатура из блока Interfaces выше; тело:

```swift
        let naming = SnapshotNaming(timeZone: timeZone)
        let inbox = ManualExportInbox(pendingRoot: pendingDirectory(in: workDirectory), naming: naming)
        let chains = StepChainRunner(chainsRoot: chainsDirectory(in: workDirectory), inbox: inbox, runner: runner, time: time, trash: trash, progress: progress)
        let transfer = RsyncTransfer(rsync: rsync, receiver: receiver, runner: runner)
        let stores = DefaultDestinationStoreFactory(naming: naming, access: access, transfer: transfer)
        let engine = BackupEngine(
            providers: DefaultSourceProviderFactory(runner: runner, stagingRoot: stagingDirectory(in: workDirectory), inbox: inbox, quit: quit, trash: trash, progress: progress),
            stores: stores, naming: naming, time: time, progress: progress
        )
        return BackupCoordinator(store: Store(dataDirectory: dataDirectory), engine: engine, inbox: inbox, chains: chains, stores: stores, time: time, calendar: calendar, quit: quit, progress: progress)
```

- [ ] **Step 8: Удалить старый слой хранения**

```bash
cd BackupCore/Sources/BackupCore/Destinations && trash SnapshotWriter.swift SpaceSaving.swift FileCloning.swift ContentHash.swift UnfinishedMark.swift RcloneDestination.swift RcloneLocator.swift Disks.swift DiskFormat.swift VolumeMounts.swift && cd -
cd BackupCore/Tests/BackupCoreTests && trash CloneSnapshotsTests.swift DiskIdentityTests.swift DiskImageIdentityTests.swift RcloneDestinationTests.swift RcloneIntegrationTests.swift SnapshotFilesTests.swift UnfinishedAttemptTests.swift UnverifiablePlaceTests.swift CoordinatorDestinationTests.swift Support/RecordingCloning.swift && cd -
```

Затем `swift build --package-path BackupCore` и устранить оставшиеся ссылки: `grep -rn "SnapshotManifest\|UnfinishedMark\|VolumeMounts\|DiskCheck\|DiskLocating\|RcloneLocator\|FileCloning\|savesSpace\|hasDebt\|debts\|deliveredCopyDate\|lastDelivered\|pausingDisabledSources" BackupCore/Sources`. Ожидаемые места: `ForeignFileSystemTests.swift` (оставить только тесты про источники на exFAT/FAT; тесты про отказ назначения удалить), `PayloadCopier.swift` (ссылка на `SnapshotManifest.serviceFileNames`, если есть, заменить на `[CopyFolder.completionMarker]`), `WrittenCopy.swift`/`RecreatedFileTests.swift`/`CopyCollisionTests.swift`/`VanishingSourceTests.swift` (если они строят `LocalFolderDestination` старой сигнатурой, переписать на `PayloadCopier` напрямую или удалить дубли, покрытые `RsyncTransferTests`). `Support/DiskImage.swift` оставить, если им пользуется `ForeignFileSystemTests`.

- [ ] **Step 9: Переписать фейки и тесты ядра**

`Tests/Support/EngineFakes.swift`: `FakeDestinationStore` заменить на

```swift
final class FakeDestinationStore: DestinationStore, @unchecked Sendable {
    var readinessValue: DestinationReadiness = .ready
    var snapshots: [Snapshot] = []
    var writeError: Error?
    var listError: Error?
    private(set) var log: [String] = []
    private(set) var writtenPayloads: [Payload] = []

    func readiness() async -> DestinationReadiness { readinessValue }

    func copies(of slug: String) async throws -> [Snapshot] {
        if let listError { throw listError }
        return snapshots.sorted { $0.date < $1.date }
    }

    func unfinishedCopies(of slug: String) async throws -> [Snapshot] { [] }

    func write(_ payload: Payload, sourceSlug: String, snapshotName: String) async throws {
        if let writeError { throw writeError }
        log.append("write:\(snapshotName)")
        writtenPayloads.append(payload)
        snapshots.append(Snapshot(name: snapshotName, date: payload.collectedAt))
    }

    func usedBytes() async throws -> Int64 { 0 }

    func url(of snapshot: Snapshot, sourceSlug: String) throws -> URL {
        URL(fileURLWithPath: "/fake/\(sourceSlug)/\(snapshot.name)", isDirectory: true)
    }
}
```

`LocalFolderDestinationTests.swift` (новый, на настоящем rsync без шлюза):

```swift
import Foundation
import Testing
@testable import BackupCore

struct LocalFolderDestinationTests {
    private let temp = try! TempDirectory()
    private var destination: LocalFolderDestination {
        LocalFolderDestination(
            root: temp.path("dest"),
            naming: Fixtures.naming,
            access: AlwaysReadyAccess(),
            transfer: RsyncTransfer(rsync: RsyncTransfer.homebrewRsync, receiver: nil, runner: SystemProcessRunner())
        )
    }

    @Test func writesACompleteCopyAndListsIt() async throws {
        defer { temp.remove() }
        try temp.directory("dest")
        try temp.file("src/a.md", "alpha")
        let payload = Payload(root: temp.path("src"), collectedAt: Fixtures.date("2026-10-08 10:00:00"))
        try await destination.write(payload, sourceSlug: "obsidian", snapshotName: "2026-10-08_100000")
        #expect(temp.names(in: "dest/obsidian/2026-10-08_100000") == [".complete", "a.md"])
        #expect(try await destination.copies(of: "obsidian") == [Fixtures.snapshot("2026-10-08 10:00:00")])
    }

    @Test func secondCopyLinksUnchangedFilesToTheFirst() async throws {
        defer { temp.remove() }
        try temp.directory("dest")
        try temp.file("src/a.md", "alpha")
        try await destination.write(Payload(root: temp.path("src"), collectedAt: Fixtures.date("2026-10-07 10:00:00")), sourceSlug: "obsidian", snapshotName: "2026-10-07_100000")
        try await destination.write(Payload(root: temp.path("src"), collectedAt: Fixtures.date("2026-10-08 10:00:00")), sourceSlug: "obsidian", snapshotName: "2026-10-08_100000")
        let links = try FileManager.default.attributesOfItem(atPath: temp.path("dest/obsidian/2026-10-08_100000/a.md").path)[.referenceCount] as? Int
        #expect(links == 2)
    }

    @Test func interruptedCopyStaysUnfinishedAndIsResumed() async throws {
        defer { temp.remove() }
        try temp.directory("dest")
        try temp.file("src/a.md", "alpha")
        try temp.file("dest/obsidian/2026-10-08_100000/stale.md", "left by a crash")
        #expect(try await destination.unfinishedCopies(of: "obsidian") == [Fixtures.snapshot("2026-10-08 10:00:00")])
        #expect(try await destination.copies(of: "obsidian") == [])
        try await destination.write(Payload(root: temp.path("src"), collectedAt: Fixtures.date("2026-10-08 10:00:00")), sourceSlug: "obsidian", snapshotName: "2026-10-08_100000")
        #expect(temp.names(in: "dest/obsidian/2026-10-08_100000") == [".complete", "a.md", "stale.md"])
    }

    @Test func failedCopyLeavesNoMarkerAndTouchesNoOtherCopy() async throws {
        defer { temp.remove() }
        try temp.directory("dest")
        try temp.file("dest/obsidian/2026-10-07_100000/.complete", "")
        try temp.file("dest/obsidian/2026-10-07_100000/a.md", "old")
        await #expect(throws: DestinationError.self) {
            try await destination.write(Payload(root: temp.path("gone"), collectedAt: Fixtures.date("2026-10-08 10:00:00")), sourceSlug: "obsidian", snapshotName: "2026-10-08_100000")
        }
        #expect(!temp.exists("dest/obsidian/2026-10-08_100000/.complete"))
        #expect(try String(contentsOf: temp.path("dest/obsidian/2026-10-07_100000/a.md"), encoding: .utf8) == "old")
    }

    @Test func notReadyFolderRefusesToWrite() async throws {
        defer { temp.remove() }
        try temp.file("src/a.md", "alpha")
        await #expect(throws: DestinationError.notReady(.folderMissing)) {
            try await destination.write(Payload(root: temp.path("src"), collectedAt: Date()), sourceSlug: "obsidian", snapshotName: "2026-10-08_100000")
        }
        #expect(!temp.exists("dest"))
    }
}
```

`StateReducerTests.swift`: оставить/переписать три случая: ошибка сбора ставит `lastError` и `retryAfter = finishedAt + 3600`; успешная доставка снимает ошибку и ставит `lastSuccess`; `dropOrphans` убирает источники и пары кеша, которых нет в настройках.

`SchedulePlannerTests.swift`: добавить таблицу для `destinationsNeedingCopy` (нет копии → нужна; копия вчера при `daily` → нужна; копия сегодня → нет; `manual` → пусто; выключенный источник → пусто) и для `isCopyFresh` (`.days(30)`: копия 10 дней назад свежа, 31 день нет; `.always`, `daily`: копия 25 часов назад свежа (интервал + час), 26 часов нет; без копии нет). Убрать тесты про долги и `shouldVerify`.

`StatusReporterTests.swift`: статус строится из `state.copyCache`: заполнять через `state.recordCopies(...)`. Удалить ожидания `.deliveryWarning`. Добавить: отключённый диск `.days(14)` с копией 20 дней назад в кеше даёт `.connectDestination`, с копией 5 дней назад не даёт; `.always` недоступный с источником даёт `.destinationUnavailable`.

`BackupEngineTests.swift`: убрать ожидания про чистку (`delete:`), `removeIncomplete`, `copy(from:)`, `reusingStoredFiles`, манифесты. Добавить: `deliversOnlyWhereTheCopyIsMissing` (у одного из двух фейков уже есть снимок с этим именем: `log` без `write`), `refusesACompletionMarkerAtTheTop` (файл `.complete` в источнике → `collectError` содержит `has the name Backup Everything gives`).

`BackupCoordinatorTests.swift`: конструктор координатора собирать через `CoreAssembly.makeCoordinator(dataDirectory:workDirectory:timeZone:runner:time:rsync:receiver:access:quit:trash:progress:)` с `receiver: nil`, `access: AlwaysReadyAccess()`, `timeZone: Fixtures.utc`. Проверять, что ни один тест не ждёт удаления копий. Ключевые новые тесты:

```swift
    @Test func diskPluggedInLaterGetsItsOwnFreshCopy() async throws {
        defer { temp.remove() }
        try store.saveConfig(Config(sources: [vault([cloud, disk])], destinations: [cloud, disk]))
        _ = try await coordinator.tick()
        #expect(temp.names(in: "cloud/obsidian") == ["2026-09-28_100000"])
        #expect(!temp.exists("hdd"))
        time.advance(3 * 86_400)
        try temp.directory("hdd")
        let result = try await coordinator.tick()
        #expect(result.runs.count == 1)
        #expect(temp.names(in: "hdd/obsidian") == ["2026-10-01_100000"])
        #expect(temp.names(in: "cloud/obsidian") == ["2026-09-28_100000", "2026-10-01_100000"])
    }

    @Test func unpluggedDiskKeepsItsCacheAndRemindsAfterItsInterval() async throws {
        defer { temp.remove() }
        try temp.directory("hdd")
        try store.saveConfig(Config(sources: [vault([disk])], destinations: [disk]))
        _ = try await coordinator.tick()
        try FileManager.default.moveItem(at: temp.path("hdd"), to: temp.path("hdd-unplugged"))
        time.advance(10 * 86_400)
        let early = try await coordinator.currentStatus()
        #expect(early.state.newestCopyDate(sourceId: early.config.sources[0].id, destinationId: disk.id) == start)
        #expect(!early.report.items.contains(.connectDestination(destinationId: disk.id)))
        time.advance(21 * 86_400)
        let late = try await coordinator.tick()
        #expect(late.notices.contains { if case .connectDestination = $0 { true } else { false } })
    }

    @Test func nothingIsEverDeletedFromADestination() async throws {
        defer { temp.remove() }
        var source = vault([cloud])
        source.retention = RetentionRules(daily: 1, weekly: 0, monthly: 0, yearly: 0)
        try store.saveConfig(Config(sources: [source], destinations: [cloud]))
        for _ in 0..<3 {
            _ = try await coordinator.tick()
            time.advance(86_400)
        }
        #expect(temp.names(in: "cloud/obsidian").count == 3)
    }
```

(`temp.path("hdd")` в фикстуре должен указывать на папку, которую можно создать и убрать; `moveItem` во временной папке теста допустим: это не данные назначения Макса.)

`StoreTests.swift`: тест, что состояние v1 с `debts` и `lastDelivered` читается в v2 без ошибок и с пустым `copyCache`; тест, что настройки с облачным назначением дают `StoreError.cloudDestinationUnsupported`.

`DomainTests.swift`: убрать проверки `disk`/`DestinationLocation`; добавить, что `Destination` с полем `disk` в JSON читается и при записи поля нет.

- [ ] **Step 10: Прогнать тесты ядра**

Run: `swift test --package-path BackupCore`
Expected: все зелёные. Упавший старый тест чинить, не отключать; если он проверяет удалённое поведение (чистка, манифест, диск), удалить его целиком с пометкой в сообщении коммита.

- [ ] **Step 11: Приложение: убрать опору на удалённые понятия (минимум для сборки)**

Цель шага: `swift build --package-path App` и `swift test --package-path App` зелёные. Поведение интерфейса дорабатывается в Task 10; здесь только убрать то, чего больше нет.

`Model/AppModel.swift`:
- Убрать свойства `diskChecks`, `destinationSharing`, `rclone`, `disks`, `stores` типа `DefaultDestinationStoreFactory` заменить на `any DestinationStoreFactory`; параметры `init`: `rclone`, `disks` убрать, добавить `access: any DestinationAccess = SystemDestinationAccess()`, `receiver: ReceiverCommand? = .standard`, `rsync: URL = RsyncTransfer.homebrewRsync`; `coordinator = CoreAssembly.makeCoordinator(dataDirectory:workDirectory:runner:rsync:receiver:access:trash:progress:)`; `stores = DefaultDestinationStoreFactory(naming: SnapshotNaming(), access: access, transfer: RsyncTransfer(rsync: rsync, receiver: receiver, runner: runner))`.
- Удалить методы `confirmConnectedDisk`, `diskLocation`, `readConnectedDisk`, `rcloneRemotes`, `isRcloneInstalled`, `isWaiting`, `isCoveredElsewhere`, `otherCopies`, `waitingSources`, `lastCaughtUp`, `rememberedSharing`, `sharingKey`, `missingFolder(of:check:)`.
- `lastBackup(of:)`: `source.destinationIds.compactMap { state.newestCopyDate(sourceId: source.id, destinationId: $0) }.max()`.
- `connectDeadline(of:)`: `config.sources.filter { $0.destinationIds.contains(destination.id) }.compactMap { planner.connectDeadline(for: destination, newestCopy: state.newestCopyDate(sourceId: $0.id, destinationId: destination.id)) }.min()`.
- `snapshots(of:in:)`: `(try? await stores.store(for: destination).copies(of: source.slug)) ?? []`, сортировка по убыванию.
- `openCopy`: без проверки диска: `reveal(folder)`; `localURL(of:source:in:)` через `stores.store(for: destination).url(of:sourceSlug:)`.
- `refreshAvailability`: `readiness` каждого назначения в новое свойство `private(set) var readiness: [UUID: DestinationReadiness]`; `unavailableDestinations` = те, у кого не `.ready`; `missingFolders[id] = readiness == .folderMissing ? MissingFolder(path: destination.path) : nil`.
- `refreshSpace`: убрать всё про `sharing`.
- `snapshot`: передавать `readiness` вместо `disks`.

`Presentation/DestinationCondition.swift`: случаи `otherDisk`, `diskNotConfirmed`, `diskUnidentified`, `unsupportedFormat` заменить одним `notReady(DestinationReadiness)`; `MissingFolder` без поля `disk`; `of(_:report:unavailable:readiness:missingFolder:)`: `.folderMissing` → `.folderMissing`, другие не-`ready` → `.notReady(readiness)`; `problem` для `.notReady`: `"not set up"`; `explanation`: `DestinationError.describe(readiness)`; `offersConfirmation`, `confirmTitle` удалить; `DiskTexts` удалить целиком, кроме `missing(_:)` (перенести в `DestinationCondition`).
`Presentation/SpaceSaving.swift`: удалить (`trash`). `Presentation/CopyGaps.swift`: убрать `disks`, `hasDebt`; причина без копии: `"no copy yet"`, с копией: `"last copy …"` по `state.newestCopyDate`. `Presentation/StatusSnapshot.swift`: `disks` → `readiness: [UUID: DestinationReadiness]`; `delivery(of:to:)` без долгов: нет копии → `.none`, свежая → `.delivered`, устаревшая → `.outdated`, последняя доставка `failed` в истории и копия не свежая → `.failed`. `Presentation/SourceStatus.swift`: убрать `.warning` и ветку `.deliveryWarning`. `Presentation/NoticeText.swift`: убрать два случая. `Presentation/MenuLines.swift`, `SourceLinks.swift`: `disks` убрать. `Presentation/DestinationTexts.swift`: `DestinationDetails.text` без `waitingSources`/`lastCaughtUp`/`isCoveredElsewhere`: строки «Available/Not connected now», и для `.days` напоминание по `connectDeadline`. `Presentation/StatusStyle.swift`: убрать `.rclone`. `Presentation/ConnectReminder.waitingLine` оставить (используется в `DeliveryText`).

`Model/Drafts.swift`: удалить `savesSpace` у черновика источника; у черновика назначения удалить `typeChoice`, `remote`, `remotePath`, `disk`, `diskConfirmed`; `kind` всегда `.localFolder(path:)`.

`Views/DestinationsView.swift`: убрать кнопку “Cloud (rclone)”, `rcloneRows`, `DiskConfirmation`, строку “Disk”; в заголовке “Add” одна кнопка “Folder or external disk”. `Views/SourcesView.swift`: убрать строку “Save space” и `spaceSaving`. `Views/OverviewView.swift`: `isCoveredElsewhere`/`otherCopies` заменить на `ConnectReminder.waitingLine(elsewhere: false, otherDestinations: [])`; `model.diskChecks` убрать; ветку `case .needsConnection, .unreachable, .otherDisk, …` заменить на `.needsConnection, .unreachable, .notReady, .folderMissing`.

`App/Tests`: `trash` для `DiskConfirmationTests.swift`, `SpaceSavingTests.swift`, `UnverifiablePlaceSnapshotTests.swift`; в `Support/ModelFixture.swift` убрать параметры `rclone`, `disks`, передавать `access: AlwaysReadyAccess(), receiver: nil`; в остальных тестах убрать ожидания про долги, диск, облако, `.warning`.

- [ ] **Step 12: Собрать и прогнать всё**

Run по очереди, проверяя код возврата каждой:
```bash
swift test --package-path BackupCore
swift test --package-path App
swift build --package-path App
```
Expected: всё зелёное.

- [ ] **Step 13: Коммит**

```bash
git add -A
git commit -m "Keep copies as plain folders written by rsync; the app can no longer delete or change a copy"
```

### Task 7: Копии сверх правила: `ExcessCopies`

**Files:**
- Create: `BackupCore/Sources/BackupCore/Retention/ExcessCopies.swift`
- Modify: `BackupCore/Sources/BackupCore/Application/BackupCoordinator.swift` (метод `excessCopies()`)
- Test: `BackupCore/Tests/BackupCoreTests/ExcessCopiesTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct ExcessCopies: Sendable, Equatable {
      public struct Item: Sendable, Equatable { public let snapshot: Snapshot; public let folder: URL; public let bytes: Int64 }
      public let sourceId: UUID; public let destinationId: UUID
      public let items: [Item]           // по возрастанию даты
      public let asOf: Date?             // nil: по реальным папкам сейчас; дата: по кешу, назначение недоступно
      public var totalBytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
      public static func command(for items: [Item], user: String) -> String
  }
  public struct ExcessCalculator: Sendable {
      public init(retention: RetentionPolicy)
      public func excess(of source: Source, on destination: Destination, copies: [Snapshot], folder: (Snapshot) throws -> URL, asOf: Date?) -> ExcessCopies
  }
  ```
  Координатор: `public func excessCopies() async throws -> [ExcessCopies]` (пары, где список непуст). Размер считается `DestinationUsage` по папке копии только при `asOf == nil` (доступное назначение); по кешу `bytes = 0`.
  Команда: `sudo chown -R <user> "<folder>" "<folder>" … && trash "<folder>" "<folder>" …`.

- [ ] **Step 1: Тесты**

```swift
import Foundation
import Testing
@testable import BackupCore

struct ExcessCopiesTests {
    private let calculator = ExcessCalculator(retention: RetentionPolicy(timeZone: Fixtures.utc))
    private let destination = Fixtures.localDestination("HDD", at: URL(fileURLWithPath: "/Volumes/HDD/Backups"))

    @Test func listsCopiesBeyondTheRuleOldestFirst() throws {
        var source = Fixtures.source(destinations: [destination])
        source.retention = RetentionRules(daily: 2, weekly: 0, monthly: 0, yearly: 0)
        let copies = ["2026-10-01 10:00:00", "2026-10-02 10:00:00", "2026-10-03 10:00:00"].map(Fixtures.snapshot)
        let excess = calculator.excess(of: source, on: destination, copies: copies, folder: { URL(fileURLWithPath: "/Volumes/HDD/Backups/obsidian/\($0.name)") }, asOf: nil)
        #expect(excess.items.map(\.snapshot) == [Fixtures.snapshot("2026-10-01 10:00:00")])
        #expect(excess.sourceId == source.id && excess.destinationId == destination.id)
    }

    @Test func commandHandsTheFoldersBackAndTrashesThem() {
        let item = ExcessCopies.Item(snapshot: Fixtures.snapshot("2026-10-01 10:00:00"), folder: URL(fileURLWithPath: "/Volumes/HDD/Backups/obsidian/2026-10-01_100000"), bytes: 0)
        #expect(ExcessCopies.command(for: [item], user: "max") == "sudo chown -R max \"/Volumes/HDD/Backups/obsidian/2026-10-01_100000\" && trash \"/Volumes/HDD/Backups/obsidian/2026-10-01_100000\"")
    }

    @Test func newestCopyIsNeverListed() {
        var source = Fixtures.source(destinations: [destination])
        source.retention = RetentionRules(daily: 0, weekly: 0, monthly: 0, yearly: 0)
        let excess = calculator.excess(of: source, on: destination, copies: [Fixtures.snapshot("2026-10-01 10:00:00")], folder: { URL(fileURLWithPath: "/x/\($0.name)") }, asOf: nil)
        #expect(excess.items.isEmpty)
    }
}
```

- [ ] **Step 2: Запустить, увидеть ошибку компиляции**

Run: `swift test --package-path BackupCore --filter ExcessCopiesTests`

- [ ] **Step 3: Реализация**

```swift
import Foundation

/// Copies of a source on a destination that the retention rule no longer keeps. The app only tells about them; the
/// person removes them with the command given here.
public struct ExcessCopies: Sendable, Equatable {
    public struct Item: Sendable, Equatable {
        public let snapshot: Snapshot
        public let folder: URL
        public let bytes: Int64

        public init(snapshot: Snapshot, folder: URL, bytes: Int64) {
            self.snapshot = snapshot
            self.folder = folder
            self.bytes = bytes
        }
    }

    public let sourceId: UUID
    public let destinationId: UUID
    public let items: [Item]
    public let asOf: Date?

    public init(sourceId: UUID, destinationId: UUID, items: [Item], asOf: Date?) {
        self.sourceId = sourceId
        self.destinationId = destinationId
        self.items = items
        self.asOf = asOf
    }

    public var totalBytes: Int64 { items.reduce(0) { $0 + $1.bytes } }

    public static func command(for items: [Item], user: String) -> String {
        let folders = items.map { "\"\($0.folder.path)\"" }.joined(separator: " ")
        return "sudo chown -R \(user) \(folders) && trash \(folders)"
    }
}

public struct ExcessCalculator: Sendable {
    private let retention: RetentionPolicy

    public init(retention: RetentionPolicy) {
        self.retention = retention
    }

    public func excess(of source: Source, on destination: Destination, copies: [Snapshot], folder: (Snapshot) throws -> URL, asOf: Date?) -> ExcessCopies {
        let doomed = retention.snapshotsToDelete(copies, rules: source.retention)
        let items = doomed.compactMap { snapshot -> ExcessCopies.Item? in
            guard let url = try? folder(snapshot) else { return nil }
            let bytes = asOf == nil ? (try? DestinationUsage().bytes(under: url)) ?? 0 : 0
            return ExcessCopies.Item(snapshot: snapshot, folder: url, bytes: bytes)
        }
        return ExcessCopies(sourceId: source.id, destinationId: destination.id, items: items, asOf: asOf)
    }
}
```

В координаторе новое свойство `private let excess: ExcessCalculator`, в `init`: `excess = ExcessCalculator(retention: RetentionPolicy(timeZone: calendar.timeZone))`:

```swift
    public func excessCopies() async throws -> [ExcessCopies] {
        let current = try await currentStatus()
        var result: [ExcessCopies] = []
        for source in current.config.sources where source.enabled {
            for destination in current.config.destinations(of: source) {
                let store = stores.store(for: destination)
                let available = await store.isAvailable()
                let copies: [Snapshot]
                let asOf: Date?
                if available, let listed = try? await store.copies(of: source.slug) {
                    copies = listed
                    asOf = nil
                } else if let cached = current.state.cachedCopies(sourceId: source.id, destinationId: destination.id) {
                    copies = cached.copies.map { Snapshot(name: $0.name, date: $0.date) }
                    asOf = cached.seenAt
                } else {
                    continue
                }
                let found = excess.excess(of: source, on: destination, copies: copies, folder: { try store.url(of: $0, sourceSlug: source.slug) }, asOf: asOf)
                if !found.items.isEmpty { result.append(found) }
            }
        }
        return result
    }
```

- [ ] **Step 4: Тесты**

Run: `swift test --package-path BackupCore --filter ExcessCopiesTests`
Expected: PASS. Затем полный прогон обоих пакетов.

- [ ] **Step 5: Коммит**

```bash
git add BackupCore/Sources/BackupCore/Retention/ExcessCopies.swift BackupCore/Sources/BackupCore/Application/BackupCoordinator.swift BackupCore/Tests/BackupCoreTests/ExcessCopiesTests.swift
git commit -m "Tell which copies are beyond the retention rule and how to remove them by hand"
```

### Task 8: Проверка установки: `StorageSetup`

**Files:**
- Create: `BackupCore/Sources/BackupCore/Application/StorageSetup.swift`
- Test: `BackupCore/Tests/BackupCoreTests/StorageSetupTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct StorageSetup: Sendable {
      public enum Problem: Equatable, Sendable {
          case rsyncMissing
          case accountMissing
          case receiverMissing
          case sudoRuleMissing
          case destinationNotReady(id: UUID, DestinationReadiness)
      }
      public static let receiverPath = "/usr/local/libexec/backup-everything/backup-receiver"
      public static let command = "sudo scripts/setup-storage.sh"
      public init(rsync: URL, receiver: URL, access: any DestinationAccess, runner: any ProcessRunner, roleAccountExists: @Sendable () -> Bool)
      public func check(_ destinations: [Destination]) async -> [Problem]
  }
  ```
  Правило sudo проверяется запуском `/usr/bin/sudo -n -u _backupeverything <receiver> --check` с таймаутом 10 с: код 0 → есть. `roleAccountExists` по умолчанию `{ getpwnam(SystemDestinationAccess.roleAccount) != nil }`.

- [ ] **Step 1: Тесты**

```swift
import Foundation
import Testing
@testable import BackupCore

struct StorageSetupTests {
    private let temp = try! TempDirectory()

    private func setup(rsync: URL? = nil, receiver: URL? = nil, sudoExit: Int32 = 0, account: Bool = true) throws -> StorageSetup {
        let rsync = try rsync ?? temp.file("rsync", "#!/bin/sh")
        let receiver = try receiver ?? temp.file("backup-receiver", "#!/bin/sh")
        return StorageSetup(
            rsync: rsync, receiver: receiver, access: AlwaysReadyAccess(),
            runner: FakeProcessRunner(handler: { _ in ProcessResult(exitCode: sudoExit) }),
            roleAccountExists: { account }
        )
    }

    @Test func everythingInPlace() async throws {
        defer { temp.remove() }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temp.path("rsync").path)
        let destination = Fixtures.localDestination("HDD", at: try temp.directory("hdd"))
        #expect(try await setup().check([destination]) == [])
    }

    @Test func reportsEachMissingPiece() async throws {
        defer { temp.remove() }
        let destination = Fixtures.localDestination("HDD", at: temp.path("missing"))
        let problems = try await setup(rsync: temp.path("no-rsync"), receiver: temp.path("no-receiver"), sudoExit: 1, account: false).check([destination])
        #expect(problems == [.rsyncMissing, .accountMissing, .receiverMissing, .sudoRuleMissing, .destinationNotReady(id: destination.id, .folderMissing)])
    }

    @Test func sudoRuleIsCheckedByRunningTheReceiver() async throws {
        defer { temp.remove() }
        let runner = FakeProcessRunner()
        let setup = StorageSetup(rsync: try temp.file("rsync", ""), receiver: try temp.file("backup-receiver", ""), access: AlwaysReadyAccess(), runner: runner, roleAccountExists: { true })
        _ = await setup.check([])
        #expect(runner.calls.last?.executable.path == "/usr/bin/sudo")
        #expect(runner.calls.last?.arguments == ["-n", "-u", "_backupeverything", temp.path("backup-receiver").path, "--check"])
    }
}
```

`temp.file` создаёт файл без бита исполнения: в тесте `everythingInPlace` выставить `0o755` обоим файлам (`rsync` и `backup-receiver`), проверка `rsyncMissing`/`receiverMissing` идёт через `isExecutableFile`.

- [ ] **Step 2: Реализация**

```swift
import Darwin
import Foundation

/// What the setup script must have done for copies to be written and protected; the app shows what is missing and the
/// command to run.
public struct StorageSetup: Sendable {
    public enum Problem: Equatable, Sendable {
        case rsyncMissing
        case accountMissing
        case receiverMissing
        case sudoRuleMissing
        case destinationNotReady(id: UUID, DestinationReadiness)
    }

    public static let receiverPath = "/usr/local/libexec/backup-everything/backup-receiver"
    public static let command = "sudo scripts/setup-storage.sh"
    private static let sudo = URL(fileURLWithPath: "/usr/bin/sudo")

    private let rsync: URL
    private let receiver: URL
    private let access: any DestinationAccess
    private let runner: any ProcessRunner
    private let roleAccountExists: @Sendable () -> Bool

    public init(
        rsync: URL = RsyncTransfer.homebrewRsync,
        receiver: URL = URL(fileURLWithPath: StorageSetup.receiverPath),
        access: any DestinationAccess = SystemDestinationAccess(),
        runner: any ProcessRunner = SystemProcessRunner(),
        roleAccountExists: @escaping @Sendable () -> Bool = { getpwnam(SystemDestinationAccess.roleAccount) != nil }
    ) {
        self.rsync = rsync
        self.receiver = receiver
        self.access = access
        self.runner = runner
        self.roleAccountExists = roleAccountExists
    }

    public func check(_ destinations: [Destination]) async -> [Problem] {
        var problems: [Problem] = []
        let fileManager = FileManager.default
        if !fileManager.isExecutableFile(atPath: rsync.path) { problems.append(.rsyncMissing) }
        if !roleAccountExists() { problems.append(.accountMissing) }
        if !fileManager.isExecutableFile(atPath: receiver.path) { problems.append(.receiverMissing) }
        if !(await sudoRuleWorks()) { problems.append(.sudoRuleMissing) }
        for destination in destinations {
            let readiness = access.readiness(of: Paths.url(destination.path))
            if readiness != .ready { problems.append(.destinationNotReady(id: destination.id, readiness)) }
        }
        return problems
    }

    private func sudoRuleWorks() async -> Bool {
        let arguments = ["-n", "-u", SystemDestinationAccess.roleAccount, receiver.path, "--check"]
        guard let result = try? await runner.run(executable: Self.sudo, arguments: arguments, environment: [:], timeout: 10) else { return false }
        return result.exitCode == 0
    }
}
```

- [ ] **Step 3: Тесты и коммит**

Run: `swift test --package-path BackupCore --filter StorageSetupTests` → PASS, затем полный прогон.

```bash
git add BackupCore/Sources/BackupCore/Application/StorageSetup.swift BackupCore/Tests/BackupCoreTests/StorageSetupTests.swift
git commit -m "Check what the storage setup still lacks"
```

### Task 9: Скрипт установки `scripts/setup-storage.sh`

**Files:**
- Create: `scripts/setup-storage.sh`
- Modify: `README` нет; описание в `CLAUDE.md` (Task 11)

**Interfaces:**
- Consumes: `config.json` (пути назначений), `backup-receiver` из пакета.
- Produces: учётка `_backupeverything`, `/usr/local/libexec/backup-everything/backup-receiver` (root:wheel 755), `/etc/sudoers.d/backup-everything` с SHA-256, учёт владельцев на внешних дисках, корни назначений и метки `.complete`, `chown -R`.

Скрипт согласуется с Максом отдельно до запуска (его комментарий в спеке); каждая команда печатается перед выполнением, запуск с `--dry-run` только печатает.

- [ ] **Step 1: Написать скрипт**

```bash
#!/bin/bash
# Prepares the Mac for protected copies: the backup account, the receiver gate, its sudo rule, and the destination folders.
# Run with sudo from the repository root. Every command is printed before it runs; --dry-run only prints.
set -euo pipefail

ACCOUNT="_backupeverything"
USER_NAME="${SUDO_USER:-$(id -un)}"
HOME_DIR=$(dscl . -read "/Users/$USER_NAME" NFSHomeDirectory | awk '{print $2}')
CONFIG="${BACKUP_EVERYTHING_HOME:-$HOME_DIR/BackupEverything}/config.json"
LIBEXEC="/usr/local/libexec/backup-everything"
RECEIVER="$LIBEXEC/backup-receiver"
SUDOERS="/etc/sudoers.d/backup-everything"
DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

run() {
  echo "+ $*"
  [ "$DRY_RUN" = 1 ] || "$@"
}

[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
[ -x /opt/homebrew/bin/rsync ] || { echo "rsync from Homebrew is missing: run 'brew install rsync' as $USER_NAME first"; exit 1; }

echo "== 1. backup account $ACCOUNT"
if ! id "$ACCOUNT" >/dev/null 2>&1; then
  run sysadminctl -addUser "$ACCOUNT" -fullName "Backup Everything" -roleAccount -shell /usr/bin/false -home /var/empty
fi

echo "== 2. receiver gate"
run sudo -u "$USER_NAME" swift build -c release --package-path BackupCore --product backup-receiver
run mkdir -p "$LIBEXEC"
run install -o root -g wheel -m 755 BackupCore/.build/release/backup-receiver "$RECEIVER"

echo "== 3. sudo rule with the binary's SHA-256"
DIGEST=$(shasum -a 256 "$RECEIVER" | awk '{print $1}')
RULE="$USER_NAME ALL=($ACCOUNT) NOPASSWD: sha256:$DIGEST $RECEIVER"
echo "+ write $SUDOERS: $RULE"
if [ "$DRY_RUN" = 0 ]; then
  printf '%s\n' "$RULE" > "$SUDOERS.tmp"
  visudo -cf "$SUDOERS.tmp"
  install -o root -g wheel -m 440 "$SUDOERS.tmp" "$SUDOERS"
  trash "$SUDOERS.tmp" 2>/dev/null || true
fi

echo "== 4. destinations from $CONFIG"
python3 - "$CONFIG" <<'PY' | while IFS= read -r ROOT; do
import json, sys, os
config = json.load(open(sys.argv[1]))
for destination in config["destinations"]:
    path = destination["kind"]["localFolder"]["path"]
    print(os.path.expanduser(path))
PY
  ROOT=$(cd "$(dirname "$ROOT")" 2>/dev/null && pwd -P)/$(basename "$ROOT") || { echo "skip $ROOT: parent folder is not there (disk not connected?)"; continue; }
  case "$ROOT" in
    /Volumes/*)
      VOLUME="/Volumes/$(echo "$ROOT" | cut -d/ -f3)"
      run diskutil enableOwnership "$VOLUME"
      ;;
  esac
  run mkdir -p "$ROOT"
  find "$ROOT" -mindepth 2 -maxdepth 2 -type d -name '20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]_[0-9][0-9][0-9][0-9][0-9][0-9]*' | while IFS= read -r COPY; do
    [ -e "$COPY/.complete" ] || run touch "$COPY/.complete"
  done
  run chown -R "$ACCOUNT:staff" "$ROOT"
  run chmod 755 "$ROOT"
done

echo "== done. Check in the app: Destinations → Setup."
```

- [ ] **Step 2: Проверить синтаксис и сухой прогон**

Run: `bash -n scripts/setup-storage.sh && chmod +x scripts/setup-storage.sh && sudo -n true 2>/dev/null || echo "dry run needs sudo; review the script by reading"`.
Настоящий запуск только после согласования с Максом; в этом плане не запускать.

- [ ] **Step 3: Коммит**

```bash
git add scripts/setup-storage.sh
git commit -m "Add the storage setup script: account, receiver, sudo rule, destination ownership"
```

### Task 10: Приложение: раздел установки и копии сверх правила

**Files:**
- Create: `App/Sources/BackupEverything/Presentation/SetupTexts.swift`
- Create: `App/Sources/BackupEverything/Presentation/ExcessCopiesText.swift`
- Create: `App/Sources/BackupEverything/Views/SetupSection.swift`
- Create: `App/Sources/BackupEverything/Views/ExcessCopiesSection.swift`
- Modify: `App/Sources/BackupEverything/Model/AppModel.swift`, `Views/DestinationsView.swift`, `Views/SourcesView.swift`, `App/Sources/BackupEverything/BackupEverythingApp.swift` (или `Model/AppPaths.swift`: переменная окружения песочницы)
- Test: `App/Tests/BackupEverythingTests/SetupTextsTests.swift`, `ExcessCopiesTextTests.swift`

**Interfaces:**
- Consumes: `StorageSetup.Problem`, `ExcessCopies`, `DestinationError.describe`.
- Produces в `AppModel`: `private(set) var setupProblems: [StorageSetup.Problem]`, `private(set) var excessCopies: [ExcessCopies]`, обновляются в `refresh()`; `var isStorageReady: Bool { setupProblems.isEmpty }`; `func excessCommand(for excess: ExcessCopies) -> String` (`ExcessCopies.command(for: excess.items, user: NSUserName())`).
- `enum SetupTexts { static func line(_ problem: StorageSetup.Problem, config: Config) -> String; static let intro: String; static let command: String }`.
- `enum ExcessCopiesText { static func summary(_ excess: [ExcessCopies], config: Config) -> String?; static func title(_ excess: ExcessCopies, config: Config) -> String }`.

- [ ] **Step 1: Тесты текстов**

```swift
import BackupCore
import Foundation
import Testing
@testable import BackupEverything

struct SetupTextsTests {
    @Test func linesNameWhatIsMissing() {
        let hdd = Destination(name: "HDD", kind: .localFolder(path: "/Volumes/HDD/Backups"))
        let config = Config(destinations: [hdd])
        #expect(SetupTexts.line(.rsyncMissing, config: config) == "rsync 3 is not installed (brew install rsync)")
        #expect(SetupTexts.line(.accountMissing, config: config) == "The backup account “_backupeverything” does not exist")
        #expect(SetupTexts.line(.receiverMissing, config: config) == "The receiver gate is not installed")
        #expect(SetupTexts.line(.sudoRuleMissing, config: config) == "The sudo rule for the receiver gate is missing or outdated")
        #expect(SetupTexts.line(.destinationNotReady(id: hdd.id, .volumeIgnoresOwners), config: config) == "“HDD”: the disk ignores file owners")
        #expect(SetupTexts.line(.destinationNotReady(id: hdd.id, .notOwnedByBackupAccount(owner: "max")), config: config) == "“HDD”: the folder belongs to “max”, not to the backup account")
    }

    @Test func commandIsTheSetupScript() {
        #expect(SetupTexts.command == "sudo scripts/setup-storage.sh")
    }
}

struct ExcessCopiesTextTests {
    @Test func summaryCountsCopiesAndBytes() {
        let hdd = Destination(name: "HDD", kind: .localFolder(path: "/Volumes/HDD/Backups"))
        let source = Source(name: "Obsidian", slug: "obsidian", steps: [.folder("/x")], schedule: .daily, destinationIds: [hdd.id], createdAt: Date())
        let config = Config(sources: [source], destinations: [hdd])
        let item = ExcessCopies.Item(snapshot: Snapshot(name: "2026-10-01_100000", date: Date()), folder: URL(fileURLWithPath: "/Volumes/HDD/Backups/obsidian/2026-10-01_100000"), bytes: 1_500_000_000)
        let excess = [ExcessCopies(sourceId: source.id, destinationId: hdd.id, items: [item, item], asOf: nil)]
        #expect(ExcessCopiesText.summary(excess, config: config) == "2 copies beyond the rules, up to 3 GB")
        #expect(ExcessCopiesText.title(excess[0], config: config) == "Obsidian on HDD: 2 copies, up to 3 GB")
        #expect(ExcessCopiesText.summary([], config: config) == nil)
    }

    @Test func cachedExcessSaysWhenItWasSeen() {
        let hdd = Destination(name: "HDD", kind: .localFolder(path: "/Volumes/HDD/Backups"))
        let source = Source(name: "Obsidian", slug: "obsidian", steps: [.folder("/x")], schedule: .daily, destinationIds: [hdd.id], createdAt: Date())
        let config = Config(sources: [source], destinations: [hdd])
        let item = ExcessCopies.Item(snapshot: Snapshot(name: "2026-10-01_100000", date: Date()), folder: URL(fileURLWithPath: "/x"), bytes: 0)
        let seen = Date().addingTimeInterval(-3 * 86_400)
        #expect(ExcessCopiesText.title(ExcessCopies(sourceId: source.id, destinationId: hdd.id, items: [item], asOf: seen), config: config) == "Obsidian on HDD: 1 copy (as seen 3 days ago)")
    }
}
```

`Texts.bytes` даёт «3 GB» для 3 000 000 000 (как Finder); `Texts.relative` даёт «3 days ago»; при расхождении подстроить ожидания под существующие функции, не наоборот.

- [ ] **Step 2: Реализация текстов**

`Presentation/SetupTexts.swift`:

```swift
import BackupCore
import Foundation

enum SetupTexts {
    static let intro = "Copies are protected by a separate account on this Mac: the app can only add copies, never delete or change them. The setup script creates that account and prepares the destination folders. Run it once in Terminal from the project folder:"
    static let command = StorageSetup.command

    static func line(_ problem: StorageSetup.Problem, config: Config) -> String {
        switch problem {
        case .rsyncMissing: "rsync 3 is not installed (brew install rsync)"
        case .accountMissing: "The backup account “\(SystemDestinationAccess.roleAccount)” does not exist"
        case .receiverMissing: "The receiver gate is not installed"
        case .sudoRuleMissing: "The sudo rule for the receiver gate is missing or outdated"
        case let .destinationNotReady(id, readiness):
            "“\(config.destination(id)?.name ?? "?")”: \(describe(readiness))"
        }
    }

    private static func describe(_ readiness: DestinationReadiness) -> String {
        switch readiness {
        case .ready: "ready"
        case .folderMissing: "the folder is not there (disk not connected?)"
        case let .notOwnedByBackupAccount(owner): "the folder belongs to “\(owner)”, not to the backup account"
        case .volumeIgnoresOwners: "the disk ignores file owners"
        case .accountMissing: "the backup account does not exist"
        }
    }
}
```

`Presentation/ExcessCopiesText.swift`:

```swift
import BackupCore
import Foundation

enum ExcessCopiesText {
    static let intro = "These copies are older than the retention rules allow. The app never deletes copies; run the command to hand them back to you and move them to the Trash."

    static func summary(_ excess: [ExcessCopies], config: Config) -> String? {
        let count = excess.reduce(0) { $0 + $1.items.count }
        guard count > 0 else { return nil }
        let bytes = excess.reduce(Int64(0)) { $0 + $1.totalBytes }
        return "\(Texts.copies(count)) beyond the rules" + (bytes > 0 ? ", up to \(Texts.bytes(bytes))" : "")
    }

    static func title(_ excess: ExcessCopies, config: Config) -> String {
        let source = config.source(excess.sourceId)?.name ?? "?"
        let destination = config.destination(excess.destinationId)?.name ?? "?"
        var text = "\(source) on \(destination): \(Texts.copies(excess.items.count))"
        if excess.totalBytes > 0 { text += ", up to \(Texts.bytes(excess.totalBytes))" }
        if let asOf = excess.asOf { text += " (as seen \(Texts.relative(asOf)))" }
        return text
    }
}
```

- [ ] **Step 3: Модель и виды**

`AppModel`: в `refresh()` после `refreshAvailability()`: `setupProblems = await StorageSetup(rsync: rsync, receiver: receiverURL, access: access, runner: runner).check(config.destinations)` и `excessCopies = (try? await coordinator.excessCopies()) ?? []` (оба через `Task`, как `refreshSpace`, чтобы не держать окно). Хранить `access`, `rsync`, `receiverURL` как `@ObservationIgnored` свойства из `init`.

`Views/SetupSection.swift`: секция в `DestinationsView` над списком назначений, видна, когда `!model.setupProblems.isEmpty`: заголовок “Setup”, `SetupTexts.intro`, маркированный список `SetupTexts.line` по каждой проблеме, строка с командой `SetupTexts.command` моноширинным шрифтом и кнопка “Copy command” (`NSPasteboard.general.clearContents(); NSPasteboard.general.setString(SetupTexts.command, forType: .string)`).

`Views/ExcessCopiesSection.swift`: секция в `DestinationsView` под списком, видна при непустом `model.excessCopies`: заголовок из `ExcessCopiesText.summary`, `ExcessCopiesText.intro`, по каждой паре `ExcessCopiesText.title` и под ней команда `model.excessCommand(for:)` с кнопкой “Copy command”; у пар с `asOf != nil` кнопки нет, подпись “connect the disk to get the command”.

`Views/SourcesView.swift`: превью правила хранения (`retentionPreview`) оставить как есть: оно только показывает, что останется и что сверх правила.

Песочница: в `BackupEverythingApp.swift` (где читается `BACKUP_EVERYTHING_HOME`) добавить чтение `BACKUP_EVERYTHING_DIRECT_RSYNC`: если переменная задана, `AppModel` создаётся с `access: AlwaysReadyAccess(), receiver: nil`. Так интерфейс проверяется без установки под sudo; прод-сборка переменную не задаёт.

- [ ] **Step 4: Сборка, тесты, живой просмотр**

Run по очереди: `swift test --package-path App`, `swift build -c release --package-path App`. Собрать песочницу по инструкции из `CLAUDE.md` с `BACKUP_EVERYTHING_DIRECT_RSYNC=1` и временной папкой; Макс смотрит сам (по памяти проекта скриншоты не нужны). В песочнице: добавить назначение-папку и источник-папку, нажать Run now, убедиться, что в папке назначения появилась копия с `.complete`, в разделе Destinations нет раздела Setup (в режиме песочницы) и после смены правила на `daily: 1` появляется раздел с копиями сверх правила и командой.

- [ ] **Step 5: Коммит**

```bash
git add -A
git commit -m "Show what the storage setup lacks and which copies are beyond the rules, with the commands to run"
```

### Task 11: Документация

**Files:**
- Modify: `docs/superpowers/specs/2026-09-30-backup-manager-design.md` (разделы 4.2–4.4, 5.3, 5.3.1, 5.4, 7, 8: заменить ссылкой на новую спеку и кратким содержанием; удалить описания клонов, манифестов, привязки к диску, долгов, сверки, облака)
- Modify: `CLAUDE.md` (сборка: `brew install rsync`; раздел «Установка хранилища»: `scripts/setup-storage.sh` под sudo, согласуется с Максом; песочница: `BACKUP_EVERYTHING_DIRECT_RSYNC=1`; правило «прод не должен потеряться»: пункт 4 дополнить «приложение не умеет удалять копии; команды из раздела Excess copies выполняет только Макс»)
- Modify: `docs/superpowers/specs/2026-10-07-storage-rework-design.md`: статус «на ревью» → «принято 2026-10-08», раздел 9 дополнить результатами Task 2 Step 3

- [ ] **Step 1: Внести правки, перечитать обе спеки на противоречия**
- [ ] **Step 2: Коммит**

```bash
git add docs CLAUDE.md
git commit -m "Describe the rsync storage layer in the design docs and the sandbox notes"
```

### Task 12: Проверка перед передачей в прод

Прод не трогается до согласования скрипта установки с Максом (его комментарий в спеке). Задача готовит всё к этому разговору.

- [ ] **Step 1: Полный прогон**: `swift test --package-path BackupCore`, `swift test --package-path App`, `swift build -c release --package-path App`; каждый код возврата проверить.
- [ ] **Step 2: Шлюз через sudo на образе диска** (без создания настоящей учётки: учётка `_betest` уже есть на Mac после spike): собрать `backup-receiver`, на временном APFS-образе (`hdiutil create -size 200m -fs APFS`) с `sudo diskutil enableOwnership`, папку корня `chown _betest`, и от своего имени запустить rsync с `--rsh="sudo -u _betest <путь к backup-receiver>"` (для этого разового теста правило sudo для `_betest` вводится паролем интерактивно в терминале Макса). Ожидание: копия и `.complete` на месте, владелец `_betest`; `rsync --delete` через шлюз отклонён; `touch` в копию от своего имени отказывает. Образ отключить, временные файлы в `trash`.
- [ ] **Step 3: Отчёт Максу**: что сделано, результат Step 2, текст `scripts/setup-storage.sh` построчно с пояснениями, список того, что изменится в `~/BackupEverything/config.json` (поле `disk` исчезнет при первой записи настроек) и в `state.json` (пересоздаётся), и что `_snapshot.json` вычищаются командой после миграции: `sudo find "<корень>" -name _snapshot.json -mindepth 3 -maxdepth 3 -exec trash {} +` (путь на каждое назначение; запускает Макс).
