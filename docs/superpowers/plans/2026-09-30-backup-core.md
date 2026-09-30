# Backup Everything: ядро (BackupCore) — план реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Swift Package `BackupCore` — вся логика бэкапов без UI: источники, назначения, хранение по GFS, долги и догон, расписание, статус, напоминания, хранение настроек и истории.

**Architecture:** Чистые расчёты (`RetentionPolicy`, `SchedulePlanner`, `StateReducer`, `StatusReporter`) отделены от ввода-вывода (`SourceProvider`, `DestinationStore`, `Store`). `BackupEngine` выполняет один прогон и возвращает `RunRecord`; актор `BackupCoordinator` — единственная точка входа для приложения: его `tick()` делает всё, что пора сделать, строго по одному прогону за раз. Процессы и время спрятаны за `ProcessRunner` и `TimeSource`; файловые операции тестируются на настоящих временных папках.

**Tech Stack:** Swift 6.1 (language mode 6, strict concurrency), Swift Package Manager, Foundation, Swift Testing (`import Testing`), rclone (внешний бинарник). Сторонних Swift-зависимостей нет.

**Spec:** `docs/superpowers/specs/2026-09-30-backup-manager-design.md`

**Scope:** это первый из двух планов. Второй план (приложение) пишется после выполнения этого и покрывает: таймер до `nextWake()`, события пробуждения и монтирования, `FolderWatcher` (FSEvents), уведомления, автозапуск, menu bar и окно, превью хранения, занятое место в назначениях, «Показать в Finder». Всё это вызывает API, созданный здесь, и ядро не меняет.

## Global Constraints

- macOS 14+, Swift tools 6.0, язык Swift 6. Сборка без предупреждений.
- Пакет лежит в `BackupCore/`. Все команды запускаются из корня репозитория: `swift test --package-path BackupCore`.
- Ветка `backup-core`, создаётся от `design-spec`. Коммит после каждой задачи.
- Сторонние Swift-пакеты не добавлять.
- `BackupCore` не импортирует SwiftUI, AppKit и UserNotifications.
- Тесты не пропускать и не отключать. Интеграционный тест rclone требует установленный rclone и падает без него — это намеренно.
- Комментарии в коде — только там, где без них не обойтись.
- Тексты ошибок и уведомлений — на русском, человеческим языком.
- Удаление файлов в shell-командах исполнителя — только через `trash`, не `rm`.
- Имя снапшота: `yyyy-MM-dd_HHmmss`. Манифест: `_snapshot.json`, пишется последним. Снапшот без манифеста не существует.
- Папка данных: `config.json`, `state.json`, `history/YYYY-MM.jsonl`, `templates/*.json`. Рабочая папка: `pending/<sourceId>/<timestamp>/`, `staging/`.
- Хранение по умолчанию: 7 / 4 / 12 / 0. Повтор после сбоя: через 3600 с. Напоминание: раз в 86 400 с. Таймаут проверки rclone: 15 с. Хвост вывода команды: 4096 символов. Отстой файла ручного экспорта: 5 с.
- Секреты в `config.json` не хранятся.

## Review Focus

Условия, которые спека подразумевает и которые сильнее всего ударят по пользователю. Каждое закреплено тестом в задаче-владельце.

1. **Внешний диск не подключён.** Корня назначения нет — приложение не должно создать `/Volumes/HDD/...` на внутреннем диске и писать туда. Task 5: `missingRootIsUnavailableAndNeverCreated`.
2. **Источник исчез или опустел** (хранилище переехало, команда ничего не выгрузила). Пустой снапшот не создаётся, старые копии не чистятся. Task 7: `folderSourceFailsWhenPathIsGone`; Task 9: `emptySourceNeverProducesSnapshotOrPrunesOldOnes`.
3. **В папке назначения лежит чужое или недописанное.** Удаляются только папки с именем снапшота; недописанный снапшот не учитывается хранением. Task 5: `snapshotWithoutManifestIsIncomplete`, `deletesOnlySnapshotDirectories`; Task 6: `purgesOnlyIncompleteSnapshotDirectories`.
4. **В «Загрузках» лежат старые, пустые или недокачанные файлы под маску.** Они не подхватываются. Task 8: `ignoresFilesOlderThanLastPickupAndEmptyPlaceholders`, `unfinishedDownloadBlocksPickup`, `freshlyWrittenFileIsNotSettledYet`.
5. **Пробуждение и монтирование диска приходят одновременно.** Два `tick()` не должны дать два прогона. Task 12: `overlappingTicksRunTheSourceOnlyOnce`.

Дополнительно: имена с кириллицей и разным регистром в масках (Task 5: `appliesExcludesToNamesAndPathsIncludingCyrillic`), вывод команды больше буфера канала (Task 4: `handlesOutputLargerThanPipeBuffer`).

## File Structure

```
.gitignore
BackupCore/
  Package.swift
  Sources/BackupCore/
    Domain/          RetentionRules, Schedule, Source, Destination, Config, AppState, Snapshot, RunRecord, SourceTemplate
    Support/         JSONCoding, Slug, Paths, GlobPattern
    Retention/       RetentionPolicy
    Infrastructure/  TimeSource, ProcessRunner
    Storage/         Store
    Payload/         Payload, PayloadWalker
    Destinations/    DestinationStore, LocalFolderDestination, RcloneLocator, RcloneDestination
    Providers/       SourceError, SourceProvider, FolderSource, CommandSource, ManualExportInbox, ManualExportSource
    Engine/          Factories, BackupEngine
    Scheduling/      StateReducer, SchedulePlanner
    Status/          StatusReporter, ReminderPlanner, Notice
    Application/     BackupCoordinator, Bootstrap, CoreAssembly
    Resources/Templates/   7 шаблонов источников
  Tests/BackupCoreTests/
    Support/         Fixtures, TempDirectory, FakeTimeSource, FakeProcessRunner, EngineFakes
    *Tests.swift     по файлу на компонент
```

---

### Task 1: Каркас пакета и модель предметной области

**Files:**
- Create: `.gitignore`, `BackupCore/Package.swift`
- Create: `BackupCore/Sources/BackupCore/Domain/{RetentionRules,Schedule,Source,Destination,Config,AppState,Snapshot,RunRecord,SourceTemplate}.swift`
- Create: `BackupCore/Sources/BackupCore/Support/{JSONCoding,Slug}.swift`
- Test: `BackupCore/Tests/BackupCoreTests/Support/Fixtures.swift`, `BackupCore/Tests/BackupCoreTests/DomainTests.swift`

**Interfaces:**
- Produces: `RetentionRules(daily:weekly:monthly:yearly:)`, `.standard`; `Schedule.nextDue(after:calendar:) -> Date?`; `Source`, `SourceKind`, `FileMode`; `Destination`, `DestinationKind`, `ExpectedEvery`; `Config` с `source(_:)`, `destination(_:)`, `destinations(of:)`; `AppState`, `SourceState`, `DestinationState`, `Debt`; `Snapshot`, `SnapshotManifest`, `SnapshotNaming.name(for:)/date(from:)/snapshot(named:)`; `RunRecord`, `Delivery`, `DeliveryOutcome`, `RunTrigger`; `SourceTemplate`; `Slug.make(from:existing:)`; внутренний `JSONCoding.encoder(pretty:)/decoder()`.
- Тестовые помощники `Fixtures.date(_:)`, `Fixtures.snapshot(_:)`, `Fixtures.source(...)`, `Fixtures.localDestination(_:at:expectedEvery:)`, `Fixtures.utc`, `Fixtures.calendar`, `Fixtures.naming` используются всеми следующими задачами.

- [ ] **Step 1: Подготовить окружение и ветку**

```bash
brew install rclone
rclone version
git checkout -b backup-core design-spec
```

Expected: `rclone version` печатает версию.

- [ ] **Step 2: Создать каркас пакета**

**`.gitignore`**

```
.build/
.swiftpm/
.DS_Store
xcuserdata/
DerivedData/
```

**`BackupCore/Package.swift`**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BackupCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BackupCore", targets: ["BackupCore"]),
    ],
    targets: [
        .target(name: "BackupCore"),
        .testTarget(
            name: "BackupCoreTests",
            dependencies: ["BackupCore"]
        ),
    ]
)
```

- [ ] **Step 3: Написать падающие тесты**

**`BackupCore/Tests/BackupCoreTests/Support/Fixtures.swift`**

```swift
import Foundation
@testable import BackupCore

enum Fixtures {
    static let utc = TimeZone(identifier: "UTC")!
    static let naming = SnapshotNaming(timeZone: utc)

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = utc
        return calendar
    }

    static func date(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = utc
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: text)!
    }

    static func snapshot(_ text: String) -> Snapshot {
        let date = date(text)
        return Snapshot(name: naming.name(for: date), date: date)
    }

    static func source(
        name: String = "Obsidian",
        kind: SourceKind = .folder(path: "/tmp/none", excludes: []),
        schedule: Schedule = .daily,
        retention: RetentionRules = .standard,
        destinations: [Destination] = [],
        createdAt: Date = date("2026-09-01 00:00:00")
    ) -> Source {
        Source(
            name: name,
            slug: Slug.make(from: name, existing: []),
            kind: kind,
            schedule: schedule,
            retention: retention,
            destinationIds: destinations.map(\.id),
            createdAt: createdAt
        )
    }

    static func localDestination(_ name: String, at url: URL, expectedEvery: ExpectedEvery = .always) -> Destination {
        Destination(name: name, kind: .localFolder(path: url.path), expectedEvery: expectedEvery)
    }
}
```

**`BackupCore/Tests/BackupCoreTests/DomainTests.swift`**

```swift
import Foundation
import Testing
@testable import BackupCore

struct DomainTests {
    @Test func slugKeepsLettersOfAnyScriptAndCollapsesSeparators() {
        #expect(Slug.make(from: "Настройки Backup  Everything!", existing: []) == "настройки-backup-everything")
    }

    @Test func slugAvoidsCollisions() {
        #expect(Slug.make(from: "GitHub", existing: ["github", "github-2"]) == "github-3")
    }

    @Test func slugFallsBackWhenNameHasNoLetters() {
        #expect(Slug.make(from: "!!!", existing: []) == "source")
    }

    @Test func snapshotNameRoundTrips() {
        let date = Fixtures.date("2026-09-28 14:30:05")
        let name = Fixtures.naming.name(for: date)
        #expect(name == "2026-09-28_143005")
        #expect(Fixtures.naming.date(from: name) == date)
    }

    @Test(arguments: ["Photos", "2026-09-28", "2026-13-40_000000", "2026-09-28_143005 copy"])
    func snapshotNamingRejectsForeignNames(name: String) {
        #expect(Fixtures.naming.date(from: name) == nil)
    }

    @Test func scheduleComputesNextDue() {
        let start = Fixtures.date("2026-01-31 10:00:00")
        #expect(Schedule.daily.nextDue(after: start, calendar: Fixtures.calendar) == Fixtures.date("2026-02-01 10:00:00"))
        #expect(Schedule.weekly.nextDue(after: start, calendar: Fixtures.calendar) == Fixtures.date("2026-02-07 10:00:00"))
        #expect(Schedule.monthly.nextDue(after: start, calendar: Fixtures.calendar) == Fixtures.date("2026-02-28 10:00:00"))
        #expect(Schedule.manual.nextDue(after: start, calendar: Fixtures.calendar) == nil)
    }

    @Test func configRoundTripsThroughJSON() throws {
        let disk = Destination(name: "HDD", kind: .localFolder(path: "/Volumes/HDD/Backups"), expectedEvery: .days(30))
        let cloud = Destination(name: "Cloud", kind: .rclone(remote: "gdrive", path: "backups"))
        let config = Config(
            sources: [
                Fixtures.source(name: "Obsidian", kind: .folder(path: "~/Obsidian", excludes: [".trash"]), destinations: [disk, cloud]),
                Fixtures.source(name: "GitHub", kind: .command(command: "gh repo list", timeoutSeconds: 60), schedule: .weekly),
                Fixtures.source(
                    name: "Photos",
                    kind: .manualExport(watchPath: "~/Downloads", filePattern: "takeout-*.zip", fileMode: .multiple, removeOriginal: true),
                    schedule: .monthly
                ),
            ],
            destinations: [disk, cloud]
        )
        let data = try JSONCoding.encoder().encode(config)
        #expect(try JSONCoding.decoder().decode(Config.self, from: data) == config)
    }

    @Test func sourceKindHasReadableJSONShape() throws {
        let json = #"{"folder":{"path":"~/Obsidian","excludes":[".trash"]}}"#
        let kind = try JSONCoding.decoder().decode(SourceKind.self, from: Data(json.utf8))
        #expect(kind == .folder(path: "~/Obsidian", excludes: [".trash"]))
    }
}
```

- [ ] **Step 4: Убедиться, что тесты не собираются**

Run: `swift test --package-path BackupCore --filter DomainTests`
Expected: ошибка сборки `cannot find 'SnapshotNaming' in scope` (и другие отсутствующие типы).

- [ ] **Step 5: Реализовать модель**

**`BackupCore/Sources/BackupCore/Domain/RetentionRules.swift`**

```swift
import Foundation

public struct RetentionRules: Codable, Sendable, Equatable {
    public var daily: Int
    public var weekly: Int
    public var monthly: Int
    public var yearly: Int

    public static let standard = RetentionRules(daily: 7, weekly: 4, monthly: 12, yearly: 0)

    public init(daily: Int, weekly: Int, monthly: Int, yearly: Int) {
        self.daily = daily
        self.weekly = weekly
        self.monthly = monthly
        self.yearly = yearly
    }
}
```

**`BackupCore/Sources/BackupCore/Domain/Schedule.swift`**

```swift
import Foundation

public enum Schedule: String, Codable, Sendable, CaseIterable {
    case daily
    case weekly
    case monthly
    case manual

    public func nextDue(after date: Date, calendar: Calendar) -> Date? {
        switch self {
        case .daily: calendar.date(byAdding: .day, value: 1, to: date)
        case .weekly: calendar.date(byAdding: .day, value: 7, to: date)
        case .monthly: calendar.date(byAdding: .month, value: 1, to: date)
        case .manual: nil
        }
    }
}
```

**`BackupCore/Sources/BackupCore/Domain/Source.swift`**

```swift
import Foundation

public enum FileMode: String, Codable, Sendable, CaseIterable {
    case single
    case multiple
}

public enum SourceKind: Codable, Sendable, Equatable {
    case folder(path: String, excludes: [String])
    case command(command: String, timeoutSeconds: Int)
    case manualExport(watchPath: String, filePattern: String, fileMode: FileMode, removeOriginal: Bool)
}

public struct Source: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var slug: String
    public var kind: SourceKind
    public var schedule: Schedule
    public var retention: RetentionRules
    public var destinationIds: [UUID]
    public var instructions: String
    public var enabled: Bool
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        slug: String,
        kind: SourceKind,
        schedule: Schedule,
        retention: RetentionRules = .standard,
        destinationIds: [UUID] = [],
        instructions: String = "",
        enabled: Bool = true,
        createdAt: Date
    ) {
        self.id = id
        self.name = name
        self.slug = slug
        self.kind = kind
        self.schedule = schedule
        self.retention = retention
        self.destinationIds = destinationIds
        self.instructions = instructions
        self.enabled = enabled
        self.createdAt = createdAt
    }

    public var isManualExport: Bool {
        if case .manualExport = kind { return true }
        return false
    }
}
```

**`BackupCore/Sources/BackupCore/Domain/Destination.swift`**

```swift
import Foundation

public enum ExpectedEvery: Codable, Sendable, Equatable {
    case always
    case days(Int)
}

public enum DestinationKind: Codable, Sendable, Equatable {
    case localFolder(path: String)
    case rclone(remote: String, path: String)
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
}
```

**`BackupCore/Sources/BackupCore/Domain/Config.swift`**

```swift
import Foundation

public struct Config: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var sources: [Source]
    public var destinations: [Destination]

    public init(sources: [Source] = [], destinations: [Destination] = []) {
        self.schemaVersion = Self.currentSchemaVersion
        self.sources = sources
        self.destinations = destinations
    }

    public func source(_ id: UUID) -> Source? {
        sources.first { $0.id == id }
    }

    public func destination(_ id: UUID) -> Destination? {
        destinations.first { $0.id == id }
    }

    public func destinations(of source: Source) -> [Destination] {
        source.destinationIds.compactMap(destination)
    }
}
```

**`BackupCore/Sources/BackupCore/Domain/AppState.swift`**

```swift
import Foundation

public struct SourceState: Codable, Sendable, Equatable {
    public var lastRun: Date?
    public var lastPickup: Date?
    public var lastError: String?
    public var retryAfter: Date?

    public init(lastRun: Date? = nil, lastPickup: Date? = nil, lastError: String? = nil, retryAfter: Date? = nil) {
        self.lastRun = lastRun
        self.lastPickup = lastPickup
        self.lastError = lastError
        self.retryAfter = retryAfter
    }
}

public struct DestinationState: Codable, Sendable, Equatable {
    public var lastCaughtUp: Date?

    public init(lastCaughtUp: Date? = nil) {
        self.lastCaughtUp = lastCaughtUp
    }
}

public struct Debt: Codable, Sendable, Equatable {
    public var sourceId: UUID
    public var destinationId: UUID
    public var since: Date
    public var lastAttempt: Date?

    public init(sourceId: UUID, destinationId: UUID, since: Date, lastAttempt: Date? = nil) {
        self.sourceId = sourceId
        self.destinationId = destinationId
        self.since = since
        self.lastAttempt = lastAttempt
    }
}

public struct AppState: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var sources: [String: SourceState]
    public var destinations: [String: DestinationState]
    public var debts: [Debt]
    public var lastReminders: [String: Date]

    public init() {
        self.schemaVersion = Self.currentSchemaVersion
        self.sources = [:]
        self.destinations = [:]
        self.debts = []
        self.lastReminders = [:]
    }

    public func sourceState(_ id: UUID) -> SourceState {
        sources[id.uuidString] ?? SourceState()
    }

    public mutating func updateSource(_ id: UUID, _ change: (inout SourceState) -> Void) {
        var value = sourceState(id)
        change(&value)
        sources[id.uuidString] = value
    }

    public func destinationState(_ id: UUID) -> DestinationState {
        destinations[id.uuidString] ?? DestinationState()
    }

    public mutating func updateDestination(_ id: UUID, _ change: (inout DestinationState) -> Void) {
        var value = destinationState(id)
        change(&value)
        destinations[id.uuidString] = value
    }

    public func debts(forDestination id: UUID) -> [Debt] {
        debts.filter { $0.destinationId == id }
    }
}
```

**`BackupCore/Sources/BackupCore/Domain/Snapshot.swift`**

```swift
import Foundation

public struct Snapshot: Sendable, Equatable, Hashable {
    public let name: String
    public let date: Date

    public init(name: String, date: Date) {
        self.name = name
        self.date = date
    }
}

public struct SnapshotManifest: Codable, Sendable, Equatable {
    public static let fileName = "_snapshot.json"

    public var sourceId: UUID
    public var sourceName: String
    public var collectedAt: Date
    public var fileCount: Int
    public var totalBytes: Int64

    public init(sourceId: UUID, sourceName: String, collectedAt: Date, fileCount: Int, totalBytes: Int64) {
        self.sourceId = sourceId
        self.sourceName = sourceName
        self.collectedAt = collectedAt
        self.fileCount = fileCount
        self.totalBytes = totalBytes
    }
}

public struct SnapshotNaming: Sendable {
    private let timeZone: TimeZone

    public init(timeZone: TimeZone = .current) {
        self.timeZone = timeZone
    }

    public func name(for date: Date) -> String {
        formatter().string(from: date)
    }

    public func date(from name: String) -> Date? {
        let formatter = formatter()
        guard let date = formatter.date(from: name), formatter.string(from: date) == name else { return nil }
        return date
    }

    public func snapshot(named name: String) -> Snapshot? {
        date(from: name).map { Snapshot(name: name, date: $0) }
    }

    private func formatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        return formatter
    }
}
```

**`BackupCore/Sources/BackupCore/Domain/RunRecord.swift`**

```swift
import Foundation

public enum RunTrigger: String, Codable, Sendable {
    case scheduled
    case manual
    case catchUp
    case pickup
}

public enum DeliveryOutcome: Codable, Sendable, Equatable {
    case delivered(pruned: Int, warning: String?)
    case unavailable
    case failed(message: String)

    public var isDelivered: Bool {
        if case .delivered = self { return true }
        return false
    }
}

public struct Delivery: Codable, Sendable, Equatable {
    public var destinationId: UUID
    public var destinationName: String
    public var outcome: DeliveryOutcome

    public init(destinationId: UUID, destinationName: String, outcome: DeliveryOutcome) {
        self.destinationId = destinationId
        self.destinationName = destinationName
        self.outcome = outcome
    }
}

public struct RunRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var sourceId: UUID
    public var sourceName: String
    public var trigger: RunTrigger
    public var startedAt: Date
    public var finishedAt: Date
    public var snapshotName: String?
    public var fileCount: Int?
    public var totalBytes: Int64?
    public var collectError: String?
    public var details: String?
    public var deliveries: [Delivery]

    public init(
        id: UUID = UUID(),
        sourceId: UUID,
        sourceName: String,
        trigger: RunTrigger,
        startedAt: Date,
        finishedAt: Date,
        snapshotName: String? = nil,
        fileCount: Int? = nil,
        totalBytes: Int64? = nil,
        collectError: String? = nil,
        details: String? = nil,
        deliveries: [Delivery] = []
    ) {
        self.id = id
        self.sourceId = sourceId
        self.sourceName = sourceName
        self.trigger = trigger
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.snapshotName = snapshotName
        self.fileCount = fileCount
        self.totalBytes = totalBytes
        self.collectError = collectError
        self.details = details
        self.deliveries = deliveries
    }

    public var firstFailure: String? {
        if let collectError { return collectError }
        for delivery in deliveries {
            if case let .failed(message) = delivery.outcome { return message }
        }
        return nil
    }

    public var isDeferredOnly: Bool {
        collectError == nil && deliveries.allSatisfy { $0.outcome == .unavailable }
    }
}
```

**`BackupCore/Sources/BackupCore/Domain/SourceTemplate.swift`**

```swift
import Foundation

public struct SourceTemplate: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var kind: SourceKind
    public var schedule: Schedule
    public var retention: RetentionRules
    public var instructions: String

    public init(id: String, name: String, kind: SourceKind, schedule: Schedule, retention: RetentionRules, instructions: String) {
        self.id = id
        self.name = name
        self.kind = kind
        self.schedule = schedule
        self.retention = retention
        self.instructions = instructions
    }
}
```

**`BackupCore/Sources/BackupCore/Support/JSONCoding.swift`**

```swift
import Foundation

enum JSONCoding {
    static func encoder(pretty: Bool = true) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = pretty
            ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            : [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
```

**`BackupCore/Sources/BackupCore/Support/Slug.swift`**

```swift
import Foundation

public enum Slug {
    public static func make(from name: String, existing: Set<String>) -> String {
        let mapped = name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let joined = String(mapped).split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        let base = joined.isEmpty ? "source" : joined
        var candidate = base
        var suffix = 2
        while existing.contains(candidate) {
            candidate = "\(base)-\(suffix)"
            suffix += 1
        }
        return candidate
    }
}
```

- [ ] **Step 6: Убедиться, что тесты проходят**

Run: `swift test --package-path BackupCore --filter DomainTests`
Expected: PASS, 8 тестов.

- [ ] **Step 7: Commit**

```bash
git add .gitignore BackupCore
git commit -m "Add BackupCore package with domain model"
```

---

### Task 2: Правило хранения GFS

**Files:**
- Create: `BackupCore/Sources/BackupCore/Retention/RetentionPolicy.swift`
- Test: `BackupCore/Tests/BackupCoreTests/RetentionPolicyTests.swift`

**Interfaces:**
- Consumes: `Snapshot`, `RetentionRules`, `Fixtures`.
- Produces: `RetentionPolicy(timeZone:)`, `snapshotsToKeep(_:rules:) -> Set<Snapshot>`, `snapshotsToDelete(_:rules:) -> [Snapshot]` (от старых к новым).

Семантика как у restic и borg: в каждой календарной корзине (день, ISO-неделя, месяц, год) остаётся самый свежий снапшот; берутся N последних непустых корзин; самый свежий снапшот остаётся всегда.

- [ ] **Step 1: Написать падающие тесты**

**`BackupCore/Tests/BackupCoreTests/RetentionPolicyTests.swift`**

```swift
import Foundation
import Testing
@testable import BackupCore

struct RetentionPolicyTests {
    private let policy = RetentionPolicy(timeZone: Fixtures.utc)

    private func dailySnapshots(from start: String, days: Int) -> [Snapshot] {
        let first = Fixtures.date(start)
        return (0..<days).map { offset in
            let date = Fixtures.calendar.date(byAdding: .day, value: offset, to: first)!
            return Snapshot(name: Fixtures.naming.name(for: date), date: date)
        }
    }

    private func keptDays(_ snapshots: [Snapshot], _ rules: RetentionRules) -> [String] {
        policy.snapshotsToKeep(snapshots, rules: rules).map { String($0.name.prefix(10)) }.sorted()
    }

    @Test func keepsDailyWeeklyAndMonthlyTiers() {
        let snapshots = dailySnapshots(from: "2026-07-31 12:00:00", days: 60)
        #expect(keptDays(snapshots, RetentionRules(daily: 7, weekly: 4, monthly: 12, yearly: 0)) == [
            "2026-07-31", "2026-08-31", "2026-09-13", "2026-09-20",
            "2026-09-22", "2026-09-23", "2026-09-24", "2026-09-25", "2026-09-26", "2026-09-27", "2026-09-28",
        ])
    }

    @Test func gapsDoNotConsumeQuota() {
        let snapshots = ["2026-09-28 12:00:00", "2026-09-20 12:00:00", "2026-08-02 12:00:00"].map(Fixtures.snapshot)
        #expect(keptDays(snapshots, RetentionRules(daily: 3, weekly: 0, monthly: 0, yearly: 0)) == [
            "2026-08-02", "2026-09-20", "2026-09-28",
        ])
    }

    @Test func keepsNewestOfEachDay() {
        let morning = Fixtures.snapshot("2026-09-28 08:00:00")
        let evening = Fixtures.snapshot("2026-09-28 20:00:00")
        let kept = policy.snapshotsToKeep([morning, evening], rules: RetentionRules(daily: 5, weekly: 0, monthly: 0, yearly: 0))
        #expect(kept == [evening])
    }

    @Test func newestSnapshotSurvivesZeroRules() {
        let snapshots = dailySnapshots(from: "2026-09-01 12:00:00", days: 5)
        let rules = RetentionRules(daily: 0, weekly: 0, monthly: 0, yearly: 0)
        #expect(keptDays(snapshots, rules) == ["2026-09-05"])
        #expect(policy.snapshotsToDelete(snapshots, rules: rules).count == 4)
    }

    @Test func isoWeekSpansYearBoundary() {
        let snapshots = ["2026-12-31 12:00:00", "2027-01-01 12:00:00", "2027-01-04 12:00:00"].map(Fixtures.snapshot)
        #expect(keptDays(snapshots, RetentionRules(daily: 0, weekly: 2, monthly: 0, yearly: 0)) == ["2027-01-01", "2027-01-04"])
    }

    @Test func yearlyTierKeepsLastSnapshotOfEachYear() {
        let snapshots = ["2024-05-01 12:00:00", "2025-03-01 12:00:00", "2025-11-01 12:00:00", "2026-02-01 12:00:00"].map(Fixtures.snapshot)
        #expect(keptDays(snapshots, RetentionRules(daily: 0, weekly: 0, monthly: 0, yearly: 3)) == [
            "2024-05-01", "2025-11-01", "2026-02-01",
        ])
    }

    @Test func emptyAndSingleInputs() {
        #expect(policy.snapshotsToKeep([], rules: .standard).isEmpty)
        let only = Fixtures.snapshot("2026-09-28 12:00:00")
        #expect(policy.snapshotsToDelete([only], rules: .standard).isEmpty)
    }
}
```

- [ ] **Step 2: Убедиться, что тесты не собираются**

Run: `swift test --package-path BackupCore --filter RetentionPolicyTests`
Expected: ошибка сборки `cannot find 'RetentionPolicy' in scope`.

- [ ] **Step 3: Реализовать**

**`BackupCore/Sources/BackupCore/Retention/RetentionPolicy.swift`**

```swift
import Foundation

public struct RetentionPolicy: Sendable {
    private enum Level: CaseIterable {
        case day, week, month, year

        func limit(in rules: RetentionRules) -> Int {
            switch self {
            case .day: rules.daily
            case .week: rules.weekly
            case .month: rules.monthly
            case .year: rules.yearly
            }
        }

        func bucket(of date: Date, calendar: Calendar) -> String {
            switch self {
            case .day:
                let parts = calendar.dateComponents([.year, .month, .day], from: date)
                return "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
            case .week:
                let parts = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
                return "\(parts.yearForWeekOfYear ?? 0)-W\(parts.weekOfYear ?? 0)"
            case .month:
                let parts = calendar.dateComponents([.year, .month], from: date)
                return "\(parts.year ?? 0)-\(parts.month ?? 0)"
            case .year:
                return "\(calendar.component(.year, from: date))"
            }
        }
    }

    private let calendar: Calendar

    public init(timeZone: TimeZone = .current) {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = timeZone
        self.calendar = calendar
    }

    public func snapshotsToKeep(_ snapshots: [Snapshot], rules: RetentionRules) -> Set<Snapshot> {
        let sorted = snapshots.sorted { $0.date > $1.date }
        guard let newest = sorted.first else { return [] }
        var keep: Set<Snapshot> = [newest]
        for level in Level.allCases {
            let limit = level.limit(in: rules)
            guard limit > 0 else { continue }
            var seen: Set<String> = []
            for snapshot in sorted {
                let bucket = level.bucket(of: snapshot.date, calendar: calendar)
                if seen.contains(bucket) { continue }
                if seen.count == limit { break }
                seen.insert(bucket)
                keep.insert(snapshot)
            }
        }
        return keep
    }

    public func snapshotsToDelete(_ snapshots: [Snapshot], rules: RetentionRules) -> [Snapshot] {
        let keep = snapshotsToKeep(snapshots, rules: rules)
        return snapshots.filter { !keep.contains($0) }.sorted { $0.date < $1.date }
    }
}
```

- [ ] **Step 4: Убедиться, что тесты проходят**

Run: `swift test --package-path BackupCore --filter RetentionPolicyTests`
Expected: PASS, 7 тестов.

- [ ] **Step 5: Commit**

```bash
git add BackupCore
git commit -m "Add GFS retention policy"
```

---

### Task 3: Хранилище настроек, истории и шаблонов

**Files:**
- Create: `BackupCore/Sources/BackupCore/Storage/Store.swift`
- Create: `BackupCore/Sources/BackupCore/Resources/Templates/{obsidian,github,bitwarden,apple-passwords,google-photos,claude,ios-finance}.json`
- Modify: `BackupCore/Package.swift` (ресурсы)
- Test: `BackupCore/Tests/BackupCoreTests/Support/TempDirectory.swift`, `BackupCore/Tests/BackupCoreTests/StoreTests.swift`

**Interfaces:**
- Consumes: `Config`, `AppState`, `RunRecord`, `SourceTemplate`, `JSONCoding`.
- Produces: `Store(dataDirectory:)`; `hasConfig`; `loadConfig() throws`, `saveConfig(_:) throws`; `loadState() throws`, `saveState(_:) throws`; `appendRun(_:) throws`, `loadRuns(limit:) -> [RunRecord]` (новые первыми); `loadTemplates() -> [SourceTemplate]`, `installBundledTemplates() throws`; `configURL`, `stateURL`, `historyDirectory`, `templatesDirectory`; `StoreError.corrupted(file:)`, `.unsupportedVersion(file:version:)`.
- Тестовый помощник `TempDirectory` (`path`, `directory`, `file(_:_:modified:)`, `exists`, `names(in:)`, `remove`) используется всеми следующими задачами.

Поведение при повреждении: `config.json` не трогаем и бросаем ошибку (настройки нельзя молча сбросить); `state.json` переименовываем в `state.json.corrupt-<unix time>` и начинаем с пустого состояния; битая строка истории пропускается.

- [ ] **Step 1: Написать падающие тесты**

**`BackupCore/Tests/BackupCoreTests/Support/TempDirectory.swift`**

```swift
import Foundation

struct TempDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackupCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    func path(_ relative: String) -> URL {
        url.appendingPathComponent(relative)
    }

    @discardableResult
    func directory(_ relative: String) throws -> URL {
        let target = path(relative)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return target
    }

    @discardableResult
    func file(_ relative: String, _ content: String = "content", modified: Date? = nil) throws -> URL {
        let target = path(relative)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: target)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified, .creationDate: modified], ofItemAtPath: target.path)
        }
        return target
    }

    func exists(_ relative: String) -> Bool {
        FileManager.default.fileExists(atPath: path(relative).path)
    }

    func names(in relative: String = "") -> [String] {
        let target = relative.isEmpty ? url : path(relative)
        return ((try? FileManager.default.contentsOfDirectory(atPath: target.path)) ?? []).sorted()
    }
}
```

**`BackupCore/Tests/BackupCoreTests/StoreTests.swift`**

```swift
import Foundation
import Testing
@testable import BackupCore

struct StoreTests {
    private let temp: TempDirectory
    private let store: Store

    init() throws {
        temp = try TempDirectory()
        store = Store(dataDirectory: temp.path("data"))
    }

    @Test func missingFilesYieldDefaults() throws {
        defer { temp.remove() }
        #expect(try store.loadConfig() == Config())
        #expect(try store.loadState() == AppState())
        #expect(store.loadRuns().isEmpty)
        #expect(!store.hasConfig)
    }

    @Test func configAndStateRoundTrip() throws {
        defer { temp.remove() }
        let config = Config(sources: [Fixtures.source()], destinations: [])
        var state = AppState()
        state.updateSource(config.sources[0].id) { $0.lastRun = Fixtures.date("2026-09-28 10:00:00") }
        state.debts = [Debt(sourceId: config.sources[0].id, destinationId: UUID(), since: Fixtures.date("2026-09-28 10:00:00"))]
        try store.saveConfig(config)
        try store.saveState(state)
        #expect(try store.loadConfig() == config)
        #expect(try store.loadState() == state)
        #expect(store.hasConfig)
    }

    @Test func corruptedConfigIsReportedAndLeftUntouched() throws {
        defer { temp.remove() }
        try temp.file("data/config.json", "{ not json")
        #expect(throws: StoreError.corrupted(file: "config.json")) { try store.loadConfig() }
        #expect(try String(contentsOf: store.configURL, encoding: .utf8) == "{ not json")
    }

    @Test func corruptedStateIsSetAsideAndReset() throws {
        defer { temp.remove() }
        try temp.file("data/state.json", "garbage")
        #expect(try store.loadState() == AppState())
        #expect(temp.names(in: "data").contains { $0.hasPrefix("state.json.corrupt-") })
        #expect(!temp.exists("data/state.json"))
    }

    @Test func newerSchemaIsRejected() throws {
        defer { temp.remove() }
        try temp.file("data/config.json", #"{"schemaVersion":99,"sources":[],"destinations":[]}"#)
        #expect(throws: StoreError.unsupportedVersion(file: "config.json", version: 99)) { try store.loadConfig() }
    }

    @Test func historyIsAppendedPerMonthAndReadNewestFirst() throws {
        defer { temp.remove() }
        let sourceId = UUID()
        let starts = ["2026-08-31 23:00:00", "2026-09-01 08:00:00", "2026-09-02 08:00:00"].map(Fixtures.date)
        for start in starts {
            try store.appendRun(RunRecord(sourceId: sourceId, sourceName: "Obsidian", trigger: .scheduled, startedAt: start, finishedAt: start))
        }
        #expect(temp.names(in: "data/history") == ["2026-08.jsonl", "2026-09.jsonl"])
        #expect(store.loadRuns().map(\.startedAt) == starts.reversed())
        #expect(store.loadRuns(limit: 2).map(\.startedAt) == [starts[2], starts[1]])
    }

    @Test func damagedHistoryLineIsSkipped() throws {
        defer { temp.remove() }
        let start = Fixtures.date("2026-09-01 08:00:00")
        try store.appendRun(RunRecord(sourceId: UUID(), sourceName: "A", trigger: .manual, startedAt: start, finishedAt: start))
        let handle = try FileHandle(forWritingTo: temp.path("data/history/2026-09.jsonl"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{broken\n".utf8))
        try handle.close()
        try store.appendRun(RunRecord(sourceId: UUID(), sourceName: "B", trigger: .manual, startedAt: start.addingTimeInterval(60), finishedAt: start))
        #expect(store.loadRuns().map(\.sourceName) == ["B", "A"])
    }

    @Test func bundledTemplatesInstallOnceAndAllDecode() throws {
        defer { temp.remove() }
        try store.installBundledTemplates()
        #expect(temp.names(in: "data/templates") == [
            "apple-passwords.json", "bitwarden.json", "claude.json", "github.json",
            "google-photos.json", "ios-finance.json", "obsidian.json",
        ])
        #expect(store.loadTemplates().count == 7)

        try temp.file("data/templates/obsidian.json", "edited by user")
        try store.installBundledTemplates()
        #expect(try String(contentsOf: temp.path("data/templates/obsidian.json"), encoding: .utf8) == "edited by user")
        #expect(store.loadTemplates().count == 6)
    }
}
```

- [ ] **Step 2: Убедиться, что тесты не собираются**

Run: `swift test --package-path BackupCore --filter StoreTests`
Expected: ошибка сборки `cannot find 'Store' in scope`.

- [ ] **Step 3: Подключить ресурсы в `BackupCore/Package.swift`**

Заменить `.target(name: "BackupCore"),` на:

```swift
        .target(
            name: "BackupCore",
            resources: [.copy("Resources/Templates")]
        ),
```

- [ ] **Step 4: Добавить шаблоны**

Формат `kind` — синтезированный `Codable` перечисления: `{"folder": {...}}`, `{"command": {...}}`, `{"manualExport": {...}}`.

**`BackupCore/Sources/BackupCore/Resources/Templates/obsidian.json`**

```json
{
  "id": "obsidian",
  "name": "Obsidian",
  "kind": { "folder": { "path": "~/Documents/Obsidian", "excludes": [".trash", ".obsidian/workspace*.json"] } },
  "schedule": "daily",
  "retention": { "daily": 7, "weekly": 4, "monthly": 12, "yearly": 0 },
  "instructions": "Укажите путь к папке хранилища Obsidian. Копируются все заметки и настройки, кроме корзины и состояния окон."
}
```

**`BackupCore/Sources/BackupCore/Resources/Templates/github.json`**

```json
{
  "id": "github",
  "name": "GitHub",
  "kind": { "command": { "command": "set -euo pipefail\ngh repo list --limit 1000 --json nameWithOwner --jq '.[].nameWithOwner' | while read -r repo; do\n  gh repo clone \"$repo\" \"$BACKUP_SCRATCH_DIR/$repo.git\" -- --quiet --mirror\n  mkdir -p \"$BACKUP_OUTPUT_DIR/$(dirname \"$repo\")\"\n  git -C \"$BACKUP_SCRATCH_DIR/$repo.git\" bundle create \"$BACKUP_OUTPUT_DIR/$repo.bundle\" --all || [ -z \"$(git -C \"$BACKUP_SCRATCH_DIR/$repo.git\" for-each-ref)\" ]\ndone", "timeoutSeconds": 3600 } },
  "schedule": "weekly",
  "retention": { "daily": 0, "weekly": 4, "monthly": 6, "yearly": 0 },
  "instructions": "Один раз выполните в терминале:\n\n1. `brew install gh`\n2. `gh auth login`\n\nКаждый репозиторий сохраняется одним файлом `.bundle` со всей историей. Восстановление: `git clone имя.bundle`.\n\nЧтобы бэкапить только часть репозиториев, замените `gh repo list …` на `printf '%s\\n' owner/repo1 owner/repo2`."
}
```

**`BackupCore/Sources/BackupCore/Resources/Templates/bitwarden.json`**

```json
{
  "id": "bitwarden",
  "name": "Bitwarden",
  "kind": { "command": { "command": "set -euo pipefail\nexport BW_PASSWORD=\"$(security find-generic-password -s backup-everything-bitwarden -w)\"\nexport BW_SESSION=\"$(bw unlock --raw --passwordenv BW_PASSWORD)\"\nbw sync\nbw export --format json --output \"$BACKUP_OUTPUT_DIR/bitwarden.json\"", "timeoutSeconds": 300 } },
  "schedule": "weekly",
  "retention": { "daily": 0, "weekly": 8, "monthly": 12, "yearly": 0 },
  "instructions": "Один раз выполните в терминале:\n\n1. `brew install bitwarden-cli`\n2. `bw login`\n3. `security add-generic-password -s backup-everything-bitwarden -a bitwarden -w` — введите мастер-пароль, он сохранится в Связке ключей.\n\nЭкспорт не зашифрован. Направляйте его только в назначения, которым доверяете."
}
```

**`BackupCore/Sources/BackupCore/Resources/Templates/apple-passwords.json`**

```json
{
  "id": "apple-passwords",
  "name": "Пароли (macOS)",
  "kind": { "manualExport": { "watchPath": "~/Downloads", "filePattern": "Passwords*.csv", "fileMode": "single", "removeOriginal": true } },
  "schedule": "monthly",
  "retention": { "daily": 0, "weekly": 0, "monthly": 12, "yearly": 0 },
  "instructions": "1. Откройте приложение «Пароли».\n2. Файл → Экспортировать все пароли в файл…\n3. Сохраните файл в «Загрузки», не меняя имя.\n\nФайл не зашифрован. Приложение заберёт его из «Загрузок» само."
}
```

**`BackupCore/Sources/BackupCore/Resources/Templates/google-photos.json`**

```json
{
  "id": "google-photos",
  "name": "Google Photos",
  "kind": { "manualExport": { "watchPath": "~/Downloads", "filePattern": "takeout-*.zip", "fileMode": "multiple", "removeOriginal": true } },
  "schedule": "monthly",
  "retention": { "daily": 0, "weekly": 0, "monthly": 3, "yearly": 0 },
  "instructions": "1. Откройте https://takeout.google.com\n2. Нажмите «Отменить выбор» и отметьте только Google Фото.\n3. Формат .zip, размер частей 50 ГБ, «Создать экспорт».\n4. Когда придёт письмо, скачайте все части в «Загрузки».\n5. Когда все части скачаны, нажмите «Готово, забрать»."
}
```

**`BackupCore/Sources/BackupCore/Resources/Templates/claude.json`**

```json
{
  "id": "claude",
  "name": "Claude",
  "kind": { "manualExport": { "watchPath": "~/Downloads", "filePattern": "data-*.zip", "fileMode": "single", "removeOriginal": true } },
  "schedule": "monthly",
  "retention": { "daily": 0, "weekly": 0, "monthly": 12, "yearly": 0 },
  "instructions": "1. Откройте https://claude.ai → Settings → Privacy → Export data.\n2. Дождитесь письма со ссылкой и скачайте архив в «Загрузки».\n\nЕсли имя архива не начинается с `data-`, поправьте маску файла в настройках источника."
}
```

**`BackupCore/Sources/BackupCore/Resources/Templates/ios-finance.json`**

```json
{
  "id": "ios-finance",
  "name": "Финансы (iOS)",
  "kind": { "manualExport": { "watchPath": "~/Downloads", "filePattern": "*.csv", "fileMode": "single", "removeOriginal": true } },
  "schedule": "monthly",
  "retention": { "daily": 0, "weekly": 0, "monthly": 24, "yearly": 0 },
  "instructions": "1. В приложении на iPhone откройте экспорт данных в CSV.\n2. Отправьте файл на Mac через AirDrop — он попадёт в «Загрузки».\n\nЗамените маску `*.csv` на имя файла вашего приложения, например `MoneyManager*.csv`, иначе будут подхватываться любые CSV."
}
```

- [ ] **Step 5: Реализовать `Store`**

**`BackupCore/Sources/BackupCore/Storage/Store.swift`**

```swift
import Foundation

public enum StoreError: Error, Equatable, LocalizedError {
    case corrupted(file: String)
    case unsupportedVersion(file: String, version: Int)

    public var errorDescription: String? {
        switch self {
        case let .corrupted(file):
            "Файл \(file) повреждён и не читается."
        case let .unsupportedVersion(file, version):
            "Файл \(file) создан более новой версией приложения (формат \(version))."
        }
    }
}

public struct Store: Sendable {
    public let dataDirectory: URL

    public init(dataDirectory: URL) {
        self.dataDirectory = dataDirectory
    }

    public var configURL: URL { dataDirectory.appendingPathComponent("config.json") }
    public var stateURL: URL { dataDirectory.appendingPathComponent("state.json") }
    public var historyDirectory: URL { dataDirectory.appendingPathComponent("history", isDirectory: true) }
    public var templatesDirectory: URL { dataDirectory.appendingPathComponent("templates", isDirectory: true) }

    public var hasConfig: Bool {
        FileManager.default.fileExists(atPath: configURL.path)
    }

    public func loadConfig() throws -> Config {
        guard let data = try? Data(contentsOf: configURL) else { return Config() }
        guard let config = try? JSONCoding.decoder().decode(Config.self, from: data) else {
            throw StoreError.corrupted(file: configURL.lastPathComponent)
        }
        guard config.schemaVersion <= Config.currentSchemaVersion else {
            throw StoreError.unsupportedVersion(file: configURL.lastPathComponent, version: config.schemaVersion)
        }
        return config
    }

    public func saveConfig(_ config: Config) throws {
        try write(config, to: configURL)
    }

    public func loadState() throws -> AppState {
        guard let data = try? Data(contentsOf: stateURL) else { return AppState() }
        guard let state = try? JSONCoding.decoder().decode(AppState.self, from: data) else {
            try setAside(stateURL)
            return AppState()
        }
        guard state.schemaVersion <= AppState.currentSchemaVersion else {
            throw StoreError.unsupportedVersion(file: stateURL.lastPathComponent, version: state.schemaVersion)
        }
        return state
    }

    public func saveState(_ state: AppState) throws {
        try write(state, to: stateURL)
    }

    public func appendRun(_ record: RunRecord) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: historyDirectory, withIntermediateDirectories: true)
        let url = historyDirectory.appendingPathComponent("\(Self.month(of: record.startedAt)).jsonl")
        var line = try JSONCoding.encoder(pretty: false).encode(record)
        line.append(0x0A)
        guard fileManager.fileExists(atPath: url.path) else {
            try line.write(to: url, options: .atomic)
            return
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    public func loadRuns(limit: Int? = nil) -> [RunRecord] {
        let decoder = JSONCoding.decoder()
        var records: [RunRecord] = []
        for url in jsonFiles(in: historyDirectory, extension: "jsonl").sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let month = text.split(separator: "\n").compactMap { try? decoder.decode(RunRecord.self, from: Data($0.utf8)) }
            records.append(contentsOf: month.sorted { $0.startedAt > $1.startedAt })
            if let limit, records.count >= limit { return Array(records.prefix(limit)) }
        }
        return records
    }

    public func loadTemplates() -> [SourceTemplate] {
        let decoder = JSONCoding.decoder()
        return jsonFiles(in: templatesDirectory, extension: "json")
            .compactMap { try? decoder.decode(SourceTemplate.self, from: Data(contentsOf: $0)) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func installBundledTemplates() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: templatesDirectory, withIntermediateDirectories: true)
        for bundled in Bundle.module.urls(forResourcesWithExtension: "json", subdirectory: "Templates") ?? [] {
            let target = templatesDirectory.appendingPathComponent(bundled.lastPathComponent)
            if !fileManager.fileExists(atPath: target.path) {
                try fileManager.copyItem(at: bundled, to: target)
            }
        }
    }

    private func write<Value: Encodable>(_ value: Value, to url: URL) throws {
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        try JSONCoding.encoder().encode(value).write(to: url, options: .atomic)
    }

    private func setAside(_ url: URL) throws {
        let stamp = Int(Date().timeIntervalSince1970)
        let target = url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent).corrupt-\(stamp)")
        try FileManager.default.moveItem(at: url, to: target)
    }

    private func jsonFiles(in directory: URL, extension ext: String) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return items.filter { $0.pathExtension == ext }
    }

    private static func month(of date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }
}
```

- [ ] **Step 6: Убедиться, что тесты проходят**

Run: `swift test --package-path BackupCore --filter StoreTests`
Expected: PASS, 8 тестов.

- [ ] **Step 7: Commit**

```bash
git add BackupCore
git commit -m "Add store for config, state, history and source templates"
```

---

### Task 4: Время и запуск процессов

**Files:**
- Create: `BackupCore/Sources/BackupCore/Infrastructure/{TimeSource,ProcessRunner}.swift`
- Test: `BackupCore/Tests/BackupCoreTests/Support/{FakeTimeSource,FakeProcessRunner}.swift`, `BackupCore/Tests/BackupCoreTests/ProcessRunnerTests.swift`

**Interfaces:**
- Produces: `protocol TimeSource { var now: Date { get } }`, `SystemTimeSource`; `ProcessResult(exitCode:stdout:stderr:timedOut:)`; `protocol ProcessRunner { func run(executable: URL, arguments: [String], environment: [String: String], timeout: TimeInterval?) async throws -> ProcessResult }`; `SystemProcessRunner`.
- Тестовые подделки: `FakeTimeSource(_:)` с `advance(_:)`; `FakeProcessRunner(handler:)` с `calls` и вложенным `Call`; `LockedBox<Value>`.

Вывод процесса пишется во временные файлы, а не в каналы: так нет взаимной блокировки на большом выводе и нет зависания, если после таймаута остался дочерний процесс с открытым каналом. Переданные переменные окружения накладываются поверх унаследованных.

- [ ] **Step 1: Написать подделки и падающие тесты**

**`BackupCore/Tests/BackupCoreTests/Support/FakeTimeSource.swift`**

```swift
import Foundation
@testable import BackupCore

final class FakeTimeSource: TimeSource, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ date: Date) {
        current = date
    }

    var now: Date {
        lock.withLock { current }
    }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }
}
```

**`BackupCore/Tests/BackupCoreTests/Support/FakeProcessRunner.swift`**

```swift
import Foundation
@testable import BackupCore

final class FakeProcessRunner: ProcessRunner, @unchecked Sendable {
    struct Call: Equatable {
        let executable: URL
        let arguments: [String]
        let environment: [String: String]
        let timeout: TimeInterval?
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    private let handler: @Sendable (Call) throws -> ProcessResult

    init(handler: @escaping @Sendable (Call) throws -> ProcessResult = { _ in ProcessResult(exitCode: 0) }) {
        self.handler = handler
    }

    var calls: [Call] {
        lock.withLock { recorded }
    }

    func run(executable: URL, arguments: [String], environment: [String: String], timeout: TimeInterval?) async throws -> ProcessResult {
        let call = Call(executable: executable, arguments: arguments, environment: environment, timeout: timeout)
        lock.withLock { recorded.append(call) }
        return try handler(call)
    }
}

final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func get() -> Value {
        lock.withLock { value }
    }

    func set(_ newValue: Value) {
        lock.withLock { value = newValue }
    }
}
```

**`BackupCore/Tests/BackupCoreTests/ProcessRunnerTests.swift`**

```swift
import Foundation
import Testing
@testable import BackupCore

struct ProcessRunnerTests {
    private let runner = SystemProcessRunner()
    private let shell = URL(fileURLWithPath: "/bin/sh")

    @Test func capturesOutputAndExitCode() async throws {
        let result = try await runner.run(
            executable: shell,
            arguments: ["-c", "echo out; echo err >&2; exit 3"],
            environment: [:],
            timeout: nil
        )
        #expect(result == ProcessResult(exitCode: 3, stdout: "out\n", stderr: "err\n", timedOut: false))
    }

    @Test func passesEnvironmentOnTopOfInherited() async throws {
        let result = try await runner.run(
            executable: shell,
            arguments: ["-c", "echo \"$BACKUP_TEST_VALUE:${HOME:+home}\""],
            environment: ["BACKUP_TEST_VALUE": "42"],
            timeout: nil
        )
        #expect(result.stdout == "42:home\n")
    }

    @Test func stopsProcessOnTimeout() async throws {
        let started = Date()
        let result = try await runner.run(executable: shell, arguments: ["-c", "exec sleep 30"], environment: [:], timeout: 0.5)
        #expect(result.timedOut)
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test func handlesOutputLargerThanPipeBuffer() async throws {
        let result = try await runner.run(
            executable: shell,
            arguments: ["-c", "head -c 300000 /dev/zero | tr '\\0' 'a'"],
            environment: [:],
            timeout: 20
        )
        #expect(result.stdout.count == 300_000)
    }

    @Test func missingExecutableThrows() async {
        await #expect(throws: (any Error).self) {
            try await runner.run(executable: URL(fileURLWithPath: "/nonexistent/tool"), arguments: [], environment: [:], timeout: nil)
        }
    }
}
```

- [ ] **Step 2: Убедиться, что тесты не собираются**

Run: `swift test --package-path BackupCore --filter ProcessRunnerTests`
Expected: ошибка сборки `cannot find type 'TimeSource' in scope`.

- [ ] **Step 3: Реализовать**

**`BackupCore/Sources/BackupCore/Infrastructure/TimeSource.swift`**

```swift
import Foundation

public protocol TimeSource: Sendable {
    var now: Date { get }
}

public struct SystemTimeSource: TimeSource {
    public init() {}

    public var now: Date { Date() }
}
```

**`BackupCore/Sources/BackupCore/Infrastructure/ProcessRunner.swift`**

```swift
import Foundation
import os

public struct ProcessResult: Sendable, Equatable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool

    public init(exitCode: Int32, stdout: String = "", stderr: String = "", timedOut: Bool = false) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }
}

public protocol ProcessRunner: Sendable {
    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval?
    ) async throws -> ProcessResult
}

public struct SystemProcessRunner: ProcessRunner {
    public init() {}

    public func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval?
    ) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(with: Result {
                    try Self.runBlocking(
                        executable: executable,
                        arguments: arguments,
                        environment: environment,
                        timeout: timeout
                    )
                })
            }
        }
    }

    private static func runBlocking(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval?
    ) throws -> ProcessResult {
        let fileManager = FileManager.default
        let capture = fileManager.temporaryDirectory.appendingPathComponent("process-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: capture, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: capture) }

        let stdoutURL = capture.appendingPathComponent("stdout")
        let stderrURL = capture.appendingPathComponent("stderr")
        fileManager.createFile(atPath: stdoutURL.path, contents: nil)
        fileManager.createFile(atPath: stderrURL.path, contents: nil)

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = try FileHandle(forWritingTo: stdoutURL)
        process.standardError = try FileHandle(forWritingTo: stderrURL)
        try process.run()

        let timedOut = OSAllocatedUnfairLock(initialState: false)
        var deadline: DispatchWorkItem?
        if let timeout {
            let pid = process.processIdentifier
            let item = DispatchWorkItem {
                timedOut.withLock { $0 = true }
                kill(pid, SIGTERM)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: item)
            deadline = item
        }
        process.waitUntilExit()
        deadline?.cancel()

        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: (try? String(contentsOf: stdoutURL, encoding: .utf8)) ?? "",
            stderr: (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? "",
            timedOut: timedOut.withLock { $0 }
        )
    }
}
```

- [ ] **Step 4: Убедиться, что тесты проходят**

Run: `swift test --package-path BackupCore --filter ProcessRunnerTests`
Expected: PASS, 5 тестов.

- [ ] **Step 5: Commit**

```bash
git add BackupCore
git commit -m "Add time source and process runner"
```

---

### Task 5: Содержимое снапшота и локальное назначение

**Files:**
- Create: `BackupCore/Sources/BackupCore/Support/GlobPattern.swift`
- Create: `BackupCore/Sources/BackupCore/Providers/SourceError.swift`
- Create: `BackupCore/Sources/BackupCore/Payload/{Payload,PayloadWalker}.swift`
- Create: `BackupCore/Sources/BackupCore/Destinations/{DestinationStore,LocalFolderDestination}.swift`
- Test: `BackupCore/Tests/BackupCoreTests/{PayloadWalkerTests,LocalFolderDestinationTests}.swift`

**Interfaces:**
- Consumes: `Snapshot`, `SnapshotManifest`, `SnapshotNaming`, `JSONCoding`, `TempDirectory`, `Fixtures`.
- Produces: `Payload(root:excludes:collectedAt:details:)`; `PayloadEntry(url:relativePath:kind:size:)` с `Kind` `.file/.directory/.symlink`; `PayloadStats(fileCount:totalBytes:)`; `PayloadWalker.isDirectory(_:)`, `entries(of:) throws -> [PayloadEntry]`, `stats(of:)`; внутренний `GlobPattern(_:).matches(_:)`; `SourceError` (`pathMissing`, `commandFailed`, `commandTimedOut`, `emptyResult`, `nothingToCollect`); `DestinationError` (`unavailable`, `outOfSpace`, `rcloneMissing`, `commandFailed`); протокол `DestinationStore`:

```swift
func isAvailable() async -> Bool
func listSnapshots(sourceSlug: String) async throws -> [Snapshot]
func removeIncomplete(sourceSlug: String) async throws
func write(_ payload: Payload, manifest: SnapshotManifest, sourceSlug: String, snapshotName: String) async throws
func delete(_ snapshot: Snapshot, sourceSlug: String) async throws
```

- `LocalFolderDestination(root:naming:)`.

Правила:
- `Payload.root` — папка (копируется её содержимое) или один файл.
- Маска исключения сравнивается и с относительным путём, и с именем; без учёта регистра и формы Unicode. Исключённая папка не обходится.
- Корень назначения никогда не создаётся. Папка источника и папка снапшота создаются без промежуточных каталогов, чтобы исчезнувший том не был воссоздан на внутреннем диске.
- `listSnapshots`, `removeIncomplete` и `delete` работают только с папками, имя которых разбирается как имя снапшота.

- [ ] **Step 1: Написать падающие тесты**

**`BackupCore/Tests/BackupCoreTests/PayloadWalkerTests.swift`**

```swift
import Foundation
import Testing
@testable import BackupCore

struct PayloadWalkerTests {
    private let temp: TempDirectory
    private let walker = PayloadWalker()
    private let date = Fixtures.date("2026-09-28 14:30:00")

    init() throws {
        temp = try TempDirectory()
    }

    @Test func listsFilesDirectoriesAndSymlinks() throws {
        defer { temp.remove() }
        try temp.file("vault/a.md", "12345")
        try temp.file("vault/sub/b.md", "123")
        try temp.directory("vault/empty")
        try FileManager.default.createSymbolicLink(at: temp.path("vault/link.md"), withDestinationURL: temp.path("vault/a.md"))

        let entries = try walker.entries(of: Payload(root: temp.path("vault"), collectedAt: date))
        #expect(entries.map(\.relativePath) == ["a.md", "empty", "link.md", "sub", "sub/b.md"])
        #expect(entries.map(\.kind) == [.file, .directory, .symlink, .directory, .file])
        #expect(walker.stats(of: entries) == PayloadStats(fileCount: 3, totalBytes: 8))
    }

    @Test func appliesExcludesToNamesAndPathsIncludingCyrillic() throws {
        defer { temp.remove() }
        try temp.file("vault/keep.md")
        try temp.file("vault/.trash/old.md")
        try temp.file("vault/.obsidian/workspace.json")
        try temp.file("vault/.obsidian/app.json")
        try temp.file("vault/Черновики/й.md")

        let payload = Payload(root: temp.path("vault"), excludes: [".trash", ".obsidian/workspace*.json", "черновики"], collectedAt: date)
        let files = try walker.entries(of: payload).filter { $0.kind == .file }.map(\.relativePath)
        #expect(files == [".obsidian/app.json", "keep.md"])
    }

    @Test func singleFilePayloadYieldsOneEntry() throws {
        defer { temp.remove() }
        let file = try temp.file("export.csv", "1234")
        let entries = try walker.entries(of: Payload(root: file, collectedAt: date))
        #expect(entries.map(\.relativePath) == ["export.csv"])
        #expect(walker.stats(of: entries) == PayloadStats(fileCount: 1, totalBytes: 4))
    }

    @Test func missingRootThrows() {
        defer { temp.remove() }
        let missing = temp.path("nope")
        #expect(throws: SourceError.pathMissing(missing.path)) {
            try walker.entries(of: Payload(root: missing, collectedAt: date))
        }
    }
}
```

**`BackupCore/Tests/BackupCoreTests/LocalFolderDestinationTests.swift`**

```swift
import Foundation
import Testing
@testable import BackupCore

struct LocalFolderDestinationTests {
    private let temp: TempDirectory
    private let destination: LocalFolderDestination
    private let date = Fixtures.date("2026-09-28 14:30:00")
    private let name = "2026-09-28_143000"

    init() throws {
        temp = try TempDirectory()
        try temp.directory("disk")
        destination = LocalFolderDestination(root: temp.path("disk"), naming: Fixtures.naming)
    }

    private func manifest() -> SnapshotManifest {
        SnapshotManifest(sourceId: UUID(), sourceName: "Obsidian", collectedAt: date, fileCount: 2, totalBytes: 10)
    }

    private func vaultPayload() throws -> Payload {
        try temp.file("vault/a.md", "alpha")
        try temp.file("vault/sub/b.md", "beta")
        try temp.directory("vault/empty")
        return Payload(root: temp.path("vault"), collectedAt: date)
    }

    @Test func writesFilesAsIsWithManifestLast() async throws {
        defer { temp.remove() }
        try await destination.write(try vaultPayload(), manifest: manifest(), sourceSlug: "obsidian", snapshotName: name)

        #expect(try String(contentsOf: temp.path("disk/obsidian/\(name)/sub/b.md"), encoding: .utf8) == "beta")
        #expect(temp.exists("disk/obsidian/\(name)/empty"))
        let stored = try JSONCoding.decoder().decode(
            SnapshotManifest.self,
            from: Data(contentsOf: temp.path("disk/obsidian/\(name)/_snapshot.json"))
        )
        #expect(stored.fileCount == 2)
        #expect(try await destination.listSnapshots(sourceSlug: "obsidian") == [Snapshot(name: name, date: date)])
    }

    @Test func writesSingleFilePayload() async throws {
        defer { temp.remove() }
        let file = try temp.file("export.csv", "1;2")
        try await destination.write(Payload(root: file, collectedAt: date), manifest: manifest(), sourceSlug: "finance", snapshotName: name)
        #expect(temp.names(in: "disk/finance/\(name)") == ["_snapshot.json", "export.csv"])
    }

    @Test func snapshotWithoutManifestIsIncomplete() async throws {
        defer { temp.remove() }
        try temp.file("disk/obsidian/2026-09-27_100000/a.md")
        try temp.file("disk/obsidian/Мои заметки/keep.md")
        try temp.file("disk/obsidian/notes.txt")

        #expect(try await destination.listSnapshots(sourceSlug: "obsidian").isEmpty)
        try await destination.removeIncomplete(sourceSlug: "obsidian")
        #expect(temp.names(in: "disk/obsidian") == ["notes.txt", "Мои заметки"])
    }

    @Test func missingRootIsUnavailableAndNeverCreated() async throws {
        defer { temp.remove() }
        let unplugged = LocalFolderDestination(root: temp.path("Volumes/HDD/Backups"), naming: Fixtures.naming)
        #expect(await unplugged.isAvailable() == false)
        let payload = try vaultPayload()
        await #expect(throws: DestinationError.unavailable) {
            try await unplugged.write(payload, manifest: manifest(), sourceSlug: "obsidian", snapshotName: name)
        }
        #expect(!temp.exists("Volumes"))
        #expect(try await unplugged.listSnapshots(sourceSlug: "obsidian").isEmpty)
    }

    @Test func deletesOnlySnapshotDirectories() async throws {
        defer { temp.remove() }
        try await destination.write(try vaultPayload(), manifest: manifest(), sourceSlug: "obsidian", snapshotName: name)
        try temp.file("disk/obsidian/Photos/keep.jpg")

        try await destination.delete(Snapshot(name: "Photos", date: date), sourceSlug: "obsidian")
        #expect(temp.exists("disk/obsidian/Photos/keep.jpg"))

        try await destination.delete(Snapshot(name: name, date: date), sourceSlug: "obsidian")
        #expect(temp.names(in: "disk/obsidian") == ["Photos"])
    }

    @Test func failedWriteLeavesNoManifest() async throws {
        defer { temp.remove() }
        let payload = Payload(root: temp.path("missing-source"), collectedAt: date)
        await #expect(throws: SourceError.pathMissing(temp.path("missing-source").path)) {
            try await destination.write(payload, manifest: manifest(), sourceSlug: "obsidian", snapshotName: name)
        }
        #expect(try await destination.listSnapshots(sourceSlug: "obsidian").isEmpty)
        try await destination.removeIncomplete(sourceSlug: "obsidian")
        #expect(temp.names(in: "disk/obsidian").isEmpty)
    }
}
```

- [ ] **Step 2: Убедиться, что тесты не собираются**

Run: `swift test --package-path BackupCore --filter "PayloadWalkerTests|LocalFolderDestinationTests"`
Expected: ошибка сборки `cannot find 'PayloadWalker' in scope`.

- [ ] **Step 3: Реализовать содержимое снапшота**

**`BackupCore/Sources/BackupCore/Support/GlobPattern.swift`**

```swift
import Foundation

struct GlobPattern: Sendable {
    private let pattern: String

    init(_ pattern: String) {
        self.pattern = Self.normalize(pattern)
    }

    func matches(_ text: String) -> Bool {
        fnmatch(pattern, Self.normalize(text), 0) == 0
    }

    private static func normalize(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.lowercased()
    }
}
```

**`BackupCore/Sources/BackupCore/Providers/SourceError.swift`**

```swift
import Foundation

public enum SourceError: Error, Equatable, LocalizedError {
    case pathMissing(String)
    case commandFailed(exitCode: Int32, output: String)
    case commandTimedOut(seconds: Int, output: String)
    case emptyResult
    case nothingToCollect

    public var errorDescription: String? {
        switch self {
        case let .pathMissing(path):
            "Не найден путь источника: \(path)"
        case let .commandFailed(exitCode, output):
            "Команда завершилась с кодом \(exitCode). \(output)"
        case let .commandTimedOut(seconds, output):
            "Команда не уложилась в \(seconds) с и была остановлена. \(output)"
        case .emptyResult:
            "Источник не дал ни одного файла. Пустая копия не создаётся."
        case .nothingToCollect:
            "Нет подхваченных файлов для этого источника."
        }
    }
}
```

**`BackupCore/Sources/BackupCore/Payload/Payload.swift`**

```swift
import Foundation

public struct Payload: Sendable, Equatable {
    public let root: URL
    public let excludes: [String]
    public let collectedAt: Date
    public let details: String?

    public init(root: URL, excludes: [String] = [], collectedAt: Date, details: String? = nil) {
        self.root = root
        self.excludes = excludes
        self.collectedAt = collectedAt
        self.details = details
    }
}

public struct PayloadEntry: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case file
        case directory
        case symlink
    }

    public let url: URL
    public let relativePath: String
    public let kind: Kind
    public let size: Int64
}

public struct PayloadStats: Sendable, Equatable {
    public let fileCount: Int
    public let totalBytes: Int64
}
```

**`BackupCore/Sources/BackupCore/Payload/PayloadWalker.swift`**

```swift
import Foundation

public struct PayloadWalker: Sendable {
    public init() {}

    public func isDirectory(_ payload: Payload) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: payload.root.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    public func entries(of payload: Payload) throws -> [PayloadEntry] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: payload.root.path) else {
            throw SourceError.pathMissing(payload.root.path)
        }
        guard isDirectory(payload) else {
            let size = (try fileManager.attributesOfItem(atPath: payload.root.path)[.size] as? NSNumber)?.int64Value ?? 0
            return [PayloadEntry(url: payload.root, relativePath: payload.root.lastPathComponent, kind: .file, size: size)]
        }
        guard let enumerator = fileManager.enumerator(atPath: payload.root.path) else {
            throw SourceError.pathMissing(payload.root.path)
        }
        let excludes = payload.excludes.map(GlobPattern.init)
        var entries: [PayloadEntry] = []
        while let relativePath = enumerator.nextObject() as? String {
            let attributes = enumerator.fileAttributes ?? [:]
            let type = attributes[.type] as? FileAttributeType
            let name = (relativePath as NSString).lastPathComponent
            if excludes.contains(where: { $0.matches(relativePath) || $0.matches(name) }) {
                if type == .typeDirectory { enumerator.skipDescendants() }
                continue
            }
            let kind: PayloadEntry.Kind
            switch type {
            case FileAttributeType.typeDirectory: kind = .directory
            case FileAttributeType.typeSymbolicLink: kind = .symlink
            case FileAttributeType.typeRegular: kind = .file
            default: continue
            }
            entries.append(PayloadEntry(
                url: payload.root.appendingPathComponent(relativePath),
                relativePath: relativePath,
                kind: kind,
                size: kind == .file ? (attributes[.size] as? NSNumber)?.int64Value ?? 0 : 0
            ))
        }
        return entries.sorted { $0.relativePath < $1.relativePath }
    }

    public func stats(of entries: [PayloadEntry]) -> PayloadStats {
        let files = entries.filter { $0.kind != .directory }
        return PayloadStats(fileCount: files.count, totalBytes: files.reduce(0) { $0 + $1.size })
    }
}
```

- [ ] **Step 4: Реализовать локальное назначение**

**`BackupCore/Sources/BackupCore/Destinations/DestinationStore.swift`**

```swift
import Foundation

public enum DestinationError: Error, Equatable, LocalizedError {
    case unavailable
    case outOfSpace
    case rcloneMissing
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            "Назначение недоступно."
        case .outOfSpace:
            "В назначении закончилось место."
        case .rcloneMissing:
            "rclone не установлен. Установите его командой «brew install rclone»."
        case let .commandFailed(output):
            "rclone завершился с ошибкой: \(output)"
        }
    }
}

public protocol DestinationStore: Sendable {
    func isAvailable() async -> Bool
    func listSnapshots(sourceSlug: String) async throws -> [Snapshot]
    func removeIncomplete(sourceSlug: String) async throws
    func write(_ payload: Payload, manifest: SnapshotManifest, sourceSlug: String, snapshotName: String) async throws
    func delete(_ snapshot: Snapshot, sourceSlug: String) async throws
}
```

**`BackupCore/Sources/BackupCore/Destinations/LocalFolderDestination.swift`**

```swift
import Foundation

public struct LocalFolderDestination: DestinationStore {
    private let root: URL
    private let naming: SnapshotNaming
    private let walker = PayloadWalker()

    public init(root: URL, naming: SnapshotNaming) {
        self.root = root
        self.naming = naming
    }

    public func isAvailable() async -> Bool {
        var isDirectory: ObjCBool = false
        let fileManager = FileManager.default
        return fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
            && fileManager.isWritableFile(atPath: root.path)
    }

    public func listSnapshots(sourceSlug: String) async throws -> [Snapshot] {
        snapshotDirectories(sourceSlug).filter { hasManifest($0.url) }.map(\.snapshot)
    }

    public func removeIncomplete(sourceSlug: String) async throws {
        for directory in snapshotDirectories(sourceSlug) where !hasManifest(directory.url) {
            try FileManager.default.removeItem(at: directory.url)
        }
    }

    public func write(_ payload: Payload, manifest: SnapshotManifest, sourceSlug: String, snapshotName: String) async throws {
        guard await isAvailable() else { throw DestinationError.unavailable }
        let fileManager = FileManager.default
        let sourceDirectory = directory(sourceSlug)
        let snapshotDirectory = sourceDirectory.appendingPathComponent(snapshotName, isDirectory: true)
        do {
            if !fileManager.fileExists(atPath: sourceDirectory.path) {
                try fileManager.createDirectory(at: sourceDirectory, withIntermediateDirectories: false)
            }
            try fileManager.createDirectory(at: snapshotDirectory, withIntermediateDirectories: false)
            for entry in try walker.entries(of: payload) {
                let target = snapshotDirectory.appendingPathComponent(entry.relativePath)
                if entry.kind == .directory {
                    try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
                } else {
                    try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fileManager.copyItem(at: entry.url, to: target)
                }
            }
            let manifestURL = snapshotDirectory.appendingPathComponent(SnapshotManifest.fileName)
            try JSONCoding.encoder().encode(manifest).write(to: manifestURL, options: .atomic)
        } catch let error as CocoaError where error.code == .fileWriteOutOfSpace {
            throw DestinationError.outOfSpace
        }
    }

    public func delete(_ snapshot: Snapshot, sourceSlug: String) async throws {
        guard naming.date(from: snapshot.name) != nil else { return }
        try FileManager.default.removeItem(at: directory(sourceSlug).appendingPathComponent(snapshot.name, isDirectory: true))
    }

    private func directory(_ sourceSlug: String) -> URL {
        root.appendingPathComponent(sourceSlug, isDirectory: true)
    }

    private func hasManifest(_ snapshotDirectory: URL) -> Bool {
        FileManager.default.fileExists(atPath: snapshotDirectory.appendingPathComponent(SnapshotManifest.fileName).path)
    }

    private func snapshotDirectories(_ sourceSlug: String) -> [(url: URL, snapshot: Snapshot)] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: directory(sourceSlug),
            includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        return items.compactMap { url in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let snapshot = naming.snapshot(named: url.lastPathComponent) else { return nil }
            return (url, snapshot)
        }
    }
}
```

- [ ] **Step 5: Убедиться, что тесты проходят**

Run: `swift test --package-path BackupCore --filter "PayloadWalkerTests|LocalFolderDestinationTests"`
Expected: PASS, 10 тестов.

- [ ] **Step 6: Commit**

```bash
git add BackupCore
git commit -m "Add payload walker and local folder destination"
```

---

### Task 6: Назначение rclone

**Files:**
- Create: `BackupCore/Sources/BackupCore/Destinations/{RcloneLocator,RcloneDestination}.swift`
- Test: `BackupCore/Tests/BackupCoreTests/{RcloneDestinationTests,RcloneIntegrationTests}.swift`

**Interfaces:**
- Consumes: `DestinationStore`, `DestinationError`, `ProcessRunner`, `ProcessResult`, `PayloadWalker`, `SnapshotNaming`, `FakeProcessRunner`, `LockedBox`.
- Produces: `RcloneLocator(candidates:)`, `find() -> URL?`; `RcloneDestination(executable:remote:path:runner:naming:)`.

Команды rclone:

| Операция | Команда |
|---|---|
| доступность | `lsf <remote>: --max-depth 1 --contimeout 10s --retries 1`, таймаут 15 с |
| готовые снапшоты | `lsf <remote>:<path>/<slug> --files-only --recursive --max-depth 2 --include "/*/_snapshot.json"` |
| все папки | `lsf <remote>:<path>/<slug> --dirs-only` |
| запись папки | `copy <root> <remote>:<path>/<slug>/<name> --files-from-raw <список>` |
| запись файла | `copy <file> <remote>:<path>/<slug>/<name>` |
| манифест | `copyto <tmp>/_snapshot.json <remote>:<path>/<slug>/<name>/_snapshot.json` |
| удаление | `purge <remote>:<path>/<slug>/<name>` |

Код возврата 3 у `lsf` означает «папки нет» и трактуется как пустой список. Список файлов для `--files-from-raw` строится тем же `PayloadWalker`, что и локальная копия, поэтому исключения работают одинаково. Символические ссылки и пустые папки в облако не уходят. `executable == nil` (rclone не установлен) — назначение недоступно, операции бросают `DestinationError.rcloneMissing`.

Интеграционный тест использует настоящий rclone с бэкендом `:local` и не ходит в сеть.

- [ ] **Step 1: Написать падающие тесты**

**`BackupCore/Tests/BackupCoreTests/RcloneDestinationTests.swift`**

```swift
import Foundation
import Testing
@testable import BackupCore

struct RcloneDestinationTests {
    private let executable = URL(fileURLWithPath: "/opt/homebrew/bin/rclone")
    private let date = Fixtures.date("2026-09-28 14:30:00")
    private let name = "2026-09-28_143000"

    private func destination(_ runner: FakeProcessRunner, path: String = "backups/") -> RcloneDestination {
        RcloneDestination(executable: executable, remote: "gdrive:", path: path, runner: runner, naming: Fixtures.naming)
    }

    @Test func listsOnlySnapshotsThatHaveManifest() async throws {
        let runner = FakeProcessRunner { _ in
            ProcessResult(exitCode: 0, stdout: "2026-09-27_100000/_snapshot.json\n\(name)/_snapshot.json\nPhotos/_snapshot.json\n")
        }
        let snapshots = try await destination(runner).listSnapshots(sourceSlug: "obsidian")
        #expect(snapshots.map(\.name) == ["2026-09-27_100000", name])
        #expect(runner.calls.map(\.arguments) == [[
            "lsf", "gdrive:backups/obsidian", "--files-only", "--recursive", "--max-depth", "2", "--include", "/*/_snapshot.json",
        ]])
    }

    @Test func missingSourceDirectoryMeansNoSnapshots() async throws {
        let runner = FakeProcessRunner { _ in ProcessResult(exitCode: 3, stderr: "directory not found") }
        #expect(try await destination(runner).listSnapshots(sourceSlug: "obsidian").isEmpty)
        try await destination(runner).removeIncomplete(sourceSlug: "obsidian")
        #expect(!runner.calls.contains { $0.arguments.first == "purge" })
    }

    @Test func purgesOnlyIncompleteSnapshotDirectories() async throws {
        let runner = FakeProcessRunner { call in
            if call.arguments.contains("--dirs-only") {
                return ProcessResult(exitCode: 0, stdout: "2026-09-26_100000/\n2026-09-27_100000/\nPhotos/\n")
            }
            if call.arguments.first == "lsf" {
                return ProcessResult(exitCode: 0, stdout: "2026-09-27_100000/_snapshot.json\n")
            }
            return ProcessResult(exitCode: 0)
        }
        try await destination(runner).removeIncomplete(sourceSlug: "obsidian")
        #expect(runner.calls.filter { $0.arguments.first == "purge" }.map(\.arguments) == [
            ["purge", "gdrive:backups/obsidian/2026-09-26_100000"],
        ])
    }

    @Test func copiesListedFilesThenManifest() async throws {
        let temp = try TempDirectory()
        defer { temp.remove() }
        try temp.file("vault/a.md")
        try temp.file("vault/sub/b.md")
        try temp.file("vault/.trash/old.md")
        let listedFiles = LockedBox<String>("")
        let runner = FakeProcessRunner { call in
            if let index = call.arguments.firstIndex(of: "--files-from-raw") {
                listedFiles.set((try? String(contentsOfFile: call.arguments[index + 1], encoding: .utf8)) ?? "")
            }
            return ProcessResult(exitCode: 0)
        }
        let payload = Payload(root: temp.path("vault"), excludes: [".trash"], collectedAt: date)
        let manifest = SnapshotManifest(sourceId: UUID(), sourceName: "Obsidian", collectedAt: date, fileCount: 2, totalBytes: 14)

        try await destination(runner).write(payload, manifest: manifest, sourceSlug: "obsidian", snapshotName: name)

        #expect(listedFiles.get() == "a.md\nsub/b.md")
        #expect(runner.calls.count == 2)
        #expect(Array(runner.calls[0].arguments.prefix(4)) == ["copy", temp.path("vault").path, "gdrive:backups/obsidian/\(name)", "--files-from-raw"])
        #expect(runner.calls[1].arguments.first == "copyto")
        #expect(runner.calls[1].arguments.last == "gdrive:backups/obsidian/\(name)/_snapshot.json")
    }

    @Test func manifestIsNotUploadedWhenCopyFails() async throws {
        let temp = try TempDirectory()
        defer { temp.remove() }
        let file = try temp.file("export.csv")
        let runner = FakeProcessRunner { _ in ProcessResult(exitCode: 1, stderr: "quota exceeded") }
        let manifest = SnapshotManifest(sourceId: UUID(), sourceName: "Finance", collectedAt: date, fileCount: 1, totalBytes: 7)
        await #expect(throws: DestinationError.commandFailed("quota exceeded")) {
            try await destination(runner).write(Payload(root: file, collectedAt: date), manifest: manifest, sourceSlug: "finance", snapshotName: name)
        }
        #expect(runner.calls.map(\.arguments) == [["copy", file.path, "gdrive:backups/finance/\(name)"]])
    }

    @Test func deleteRefusesForeignNames() async throws {
        let runner = FakeProcessRunner()
        try await destination(runner).delete(Snapshot(name: "Photos", date: date), sourceSlug: "obsidian")
        try await destination(runner, path: "").delete(Snapshot(name: name, date: date), sourceSlug: "obsidian")
        #expect(runner.calls.map(\.arguments) == [["purge", "gdrive:obsidian/\(name)"]])
    }

    @Test func availabilityFollowsRcloneExitCode() async {
        #expect(await destination(FakeProcessRunner()).isAvailable())
        #expect(await destination(FakeProcessRunner { _ in ProcessResult(exitCode: 1) }).isAvailable() == false)
        #expect(await destination(FakeProcessRunner { _ in ProcessResult(exitCode: 0, timedOut: true) }).isAvailable() == false)
    }

    @Test func missingRcloneIsUnavailableAndExplained() async {
        let runner = FakeProcessRunner()
        let orphan = RcloneDestination(executable: nil, remote: "gdrive", path: "backups", runner: runner, naming: Fixtures.naming)
        #expect(await orphan.isAvailable() == false)
        await #expect(throws: DestinationError.rcloneMissing) {
            try await orphan.listSnapshots(sourceSlug: "obsidian")
        }
        #expect(runner.calls.isEmpty)
    }
}
```

**`BackupCore/Tests/BackupCoreTests/RcloneIntegrationTests.swift`**

```swift
import Foundation
import Testing
@testable import BackupCore

struct RcloneIntegrationTests {
    @Test func roundTripsThroughRealRcloneLocalBackend() async throws {
        let executable = try #require(RcloneLocator().find(), "Нужен rclone: brew install rclone")
        let temp = try TempDirectory()
        defer { temp.remove() }
        try temp.file("vault/a.md", "alpha")
        try temp.file("vault/sub/b.md", "beta")
        try temp.file("vault/.trash/old.md", "old")
        try temp.directory("remote")
        let destination = RcloneDestination(
            executable: executable,
            remote: ":local",
            path: temp.path("remote").path,
            runner: SystemProcessRunner(),
            naming: Fixtures.naming
        )
        let date = Fixtures.date("2026-09-28 14:30:00")
        let name = "2026-09-28_143000"
        let payload = Payload(root: temp.path("vault"), excludes: [".trash"], collectedAt: date)
        let manifest = SnapshotManifest(sourceId: UUID(), sourceName: "Obsidian", collectedAt: date, fileCount: 2, totalBytes: 9)

        #expect(await destination.isAvailable())
        #expect(try await destination.listSnapshots(sourceSlug: "obsidian").isEmpty)

        try temp.file("remote/obsidian/2026-09-27_100000/partial.md")
        try await destination.removeIncomplete(sourceSlug: "obsidian")
        #expect(!temp.exists("remote/obsidian/2026-09-27_100000"))

        try await destination.write(payload, manifest: manifest, sourceSlug: "obsidian", snapshotName: name)
        #expect(try String(contentsOf: temp.path("remote/obsidian/\(name)/sub/b.md"), encoding: .utf8) == "beta")
        #expect(!temp.exists("remote/obsidian/\(name)/.trash"))
        #expect(try await destination.listSnapshots(sourceSlug: "obsidian") == [Snapshot(name: name, date: date)])

        try await destination.delete(Snapshot(name: name, date: date), sourceSlug: "obsidian")
        #expect(try await destination.listSnapshots(sourceSlug: "obsidian").isEmpty)
    }
}
```

- [ ] **Step 2: Убедиться, что тесты не собираются**

Run: `swift test --package-path BackupCore --filter Rclone`
Expected: ошибка сборки `cannot find 'RcloneDestination' in scope`.

- [ ] **Step 3: Реализовать**

**`BackupCore/Sources/BackupCore/Destinations/RcloneLocator.swift`**

```swift
import Foundation

public struct RcloneLocator: Sendable {
    private let candidates: [String]

    public init(candidates: [String] = ["/opt/homebrew/bin/rclone", "/usr/local/bin/rclone", "/usr/bin/rclone"]) {
        self.candidates = candidates
    }

    public func find() -> URL? {
        candidates
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }
}
```

**`BackupCore/Sources/BackupCore/Destinations/RcloneDestination.swift`**

```swift
import Foundation

public struct RcloneDestination: DestinationStore {
    private static let directoryNotFoundExitCode: Int32 = 3
    private static let availabilityTimeout: TimeInterval = 15
    private static let errorTailLength = 2000

    private let executable: URL?
    private let remote: String
    private let path: String
    private let runner: any ProcessRunner
    private let naming: SnapshotNaming
    private let walker = PayloadWalker()

    public init(executable: URL?, remote: String, path: String, runner: any ProcessRunner, naming: SnapshotNaming) {
        self.executable = executable
        self.remote = remote.hasSuffix(":") ? String(remote.dropLast()) : remote
        self.path = path
        self.runner = runner
        self.naming = naming
    }

    public func isAvailable() async -> Bool {
        let arguments = ["lsf", "\(remote):", "--max-depth", "1", "--contimeout", "10s", "--retries", "1"]
        guard let result = try? await rclone(arguments, timeout: Self.availabilityTimeout) else { return false }
        return result.exitCode == 0 && !result.timedOut
    }

    public func listSnapshots(sourceSlug: String) async throws -> [Snapshot] {
        let result = try await rclone([
            "lsf", target(sourceSlug),
            "--files-only", "--recursive", "--max-depth", "2",
            "--include", "/*/\(SnapshotManifest.fileName)",
        ])
        if result.exitCode == Self.directoryNotFoundExitCode { return [] }
        try check(result)
        return lines(result.stdout).compactMap { line in
            line.split(separator: "/").first.flatMap { naming.snapshot(named: String($0)) }
        }
    }

    public func removeIncomplete(sourceSlug: String) async throws {
        let result = try await rclone(["lsf", target(sourceSlug), "--dirs-only"])
        if result.exitCode == Self.directoryNotFoundExitCode { return }
        try check(result)
        let complete = Set(try await listSnapshots(sourceSlug: sourceSlug).map(\.name))
        let directories = lines(result.stdout).map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
        for name in directories where naming.date(from: name) != nil && !complete.contains(name) {
            try check(try await rclone(["purge", target(sourceSlug, name)]))
        }
    }

    public func write(_ payload: Payload, manifest: SnapshotManifest, sourceSlug: String, snapshotName: String) async throws {
        let fileManager = FileManager.default
        let scratch = fileManager.temporaryDirectory.appendingPathComponent("rclone-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scratch) }

        let destination = target(sourceSlug, snapshotName)
        var arguments = ["copy", payload.root.path, destination]
        if walker.isDirectory(payload) {
            let files = try walker.entries(of: payload).filter { $0.kind == .file }.map(\.relativePath)
            let listURL = scratch.appendingPathComponent("files.txt")
            try files.joined(separator: "\n").write(to: listURL, atomically: true, encoding: .utf8)
            arguments += ["--files-from-raw", listURL.path]
        }
        try check(try await rclone(arguments))

        let manifestURL = scratch.appendingPathComponent(SnapshotManifest.fileName)
        try JSONCoding.encoder().encode(manifest).write(to: manifestURL)
        try check(try await rclone(["copyto", manifestURL.path, "\(destination)/\(SnapshotManifest.fileName)"]))
    }

    public func delete(_ snapshot: Snapshot, sourceSlug: String) async throws {
        guard naming.date(from: snapshot.name) != nil else { return }
        try check(try await rclone(["purge", target(sourceSlug, snapshot.name)]))
    }

    private func target(_ components: String...) -> String {
        var base = path
        while base.count > 1, base.hasSuffix("/") { base.removeLast() }
        let parts = (base.isEmpty ? [] : [base]) + components
        return "\(remote):" + parts.joined(separator: "/")
    }

    private func rclone(_ arguments: [String], timeout: TimeInterval? = nil) async throws -> ProcessResult {
        guard let executable else { throw DestinationError.rcloneMissing }
        return try await runner.run(executable: executable, arguments: arguments, environment: [:], timeout: timeout)
    }

    private func check(_ result: ProcessResult) throws {
        guard result.exitCode == 0 else {
            throw DestinationError.commandFailed(String(result.stderr.suffix(Self.errorTailLength)))
        }
    }

    private func lines(_ text: String) -> [String] {
        text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }
}
```

- [ ] **Step 4: Убедиться, что тесты проходят**

Run: `swift test --package-path BackupCore --filter Rclone`
Expected: PASS, 9 тестов. Если `roundTripsThroughRealRcloneLocalBackend` падает на флагах rclone, сверить их с `rclone lsf --help` и `rclone copy --help` установленной версии и поправить реализацию вместе с ожиданиями в `RcloneDestinationTests`; тест не отключать.

- [ ] **Step 5: Commit**

```bash
git add BackupCore
git commit -m "Add rclone destination"
```

---

### Task 7: Источники «Папка» и «Команда»

**Files:**
- Create: `BackupCore/Sources/BackupCore/Support/Paths.swift`
- Create: `BackupCore/Sources/BackupCore/Providers/{SourceProvider,FolderSource,CommandSource}.swift`
- Test: `BackupCore/Tests/BackupCoreTests/SourceProviderTests.swift`

**Interfaces:**
- Consumes: `Payload`, `SourceError`, `ProcessRunner`, `FakeProcessRunner`, `SystemProcessRunner`.
- Produces: протокол `SourceProvider`:

```swift
func collect(at date: Date) async throws -> Payload
func finish(_ payload: Payload, deliveredEverywhere: Bool)
```

- `FolderSource(path:excludes:)`; `CommandSource(command:timeoutSeconds:stagingRoot:runner:)`; внутренний `Paths.url(_:)` с раскрытием `~`.

`CommandSource` создаёт `<stagingRoot>/<uuid>/output` и `<stagingRoot>/<uuid>/scratch`, запускает `/bin/zsh -lc <command>` с `BACKUP_OUTPUT_DIR` и `BACKUP_SCRATCH_DIR`, возвращает `output` как `Payload.root`. При ошибке и в `finish` удаляет `<stagingRoot>/<uuid>` целиком. Пустой результат проверяет движок (Task 9), не источник.

- [ ] **Step 1: Написать падающие тесты**

**`BackupCore/Tests/BackupCoreTests/SourceProviderTests.swift`**

```swift
import Foundation
import Testing
@testable import BackupCore

struct SourceProviderTests {
    private let temp: TempDirectory
    private let date = Fixtures.date("2026-09-28 14:30:00")

    init() throws {
        temp = try TempDirectory()
    }

    @Test func folderSourceReturnsFolderItself() async throws {
        defer { temp.remove() }
        try temp.file("vault/a.md")
        let payload = try await FolderSource(path: temp.path("vault").path, excludes: [".trash"]).collect(at: date)
        #expect(payload == Payload(root: temp.path("vault"), excludes: [".trash"], collectedAt: date))
    }

    @Test func folderSourceFailsWhenPathIsGone() async {
        defer { temp.remove() }
        let missing = temp.path("moved-vault").path
        await #expect(throws: SourceError.pathMissing(missing)) {
            try await FolderSource(path: missing, excludes: []).collect(at: date)
        }
    }

    @Test func commandSourceRunsShellAndCollectsOutputDirectory() async throws {
        defer { temp.remove() }
        let source = CommandSource(
            command: "echo hello > \"$BACKUP_OUTPUT_DIR/out.txt\"; test -d \"$BACKUP_SCRATCH_DIR\"; echo done",
            timeoutSeconds: 30,
            stagingRoot: temp.path("staging"),
            runner: SystemProcessRunner()
        )
        let payload = try await source.collect(at: date)
        #expect(try String(contentsOf: payload.root.appendingPathComponent("out.txt"), encoding: .utf8) == "hello\n")
        #expect(payload.details?.hasSuffix("done") == true)

        source.finish(payload, deliveredEverywhere: true)
        #expect(temp.names(in: "staging").isEmpty)
    }

    @Test func commandSourceReportsFailureWithOutputAndCleansUp() async {
        defer { temp.remove() }
        let runner = FakeProcessRunner { _ in ProcessResult(exitCode: 2, stdout: "step 1\n", stderr: "auth required\n") }
        let source = CommandSource(command: "gh repo list", timeoutSeconds: 30, stagingRoot: temp.path("staging"), runner: runner)
        await #expect(throws: SourceError.commandFailed(exitCode: 2, output: "step 1\nauth required")) {
            try await source.collect(at: date)
        }
        #expect(temp.names(in: "staging").isEmpty)
        #expect(runner.calls.first?.executable.path == "/bin/zsh")
        #expect(runner.calls.first?.arguments == ["-lc", "gh repo list"])
        #expect(runner.calls.first?.timeout == 30)
    }

    @Test func commandSourceReportsTimeout() async {
        defer { temp.remove() }
        let runner = FakeProcessRunner { _ in ProcessResult(exitCode: 15, timedOut: true) }
        let source = CommandSource(command: "sleep 100", timeoutSeconds: 5, stagingRoot: temp.path("staging"), runner: runner)
        await #expect(throws: SourceError.commandTimedOut(seconds: 5, output: "")) {
            try await source.collect(at: date)
        }
    }
}
```

- [ ] **Step 2: Убедиться, что тесты не собираются**

Run: `swift test --package-path BackupCore --filter SourceProviderTests`
Expected: ошибка сборки `cannot find 'FolderSource' in scope`.

- [ ] **Step 3: Реализовать**

**`BackupCore/Sources/BackupCore/Support/Paths.swift`**

```swift
import Foundation

enum Paths {
    static func url(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }
}
```

**`BackupCore/Sources/BackupCore/Providers/SourceProvider.swift`**

```swift
import Foundation

public protocol SourceProvider: Sendable {
    func collect(at date: Date) async throws -> Payload
    func finish(_ payload: Payload, deliveredEverywhere: Bool)
}
```

**`BackupCore/Sources/BackupCore/Providers/FolderSource.swift`**

```swift
import Foundation

public struct FolderSource: SourceProvider {
    private let path: String
    private let excludes: [String]

    public init(path: String, excludes: [String]) {
        self.path = path
        self.excludes = excludes
    }

    public func collect(at date: Date) async throws -> Payload {
        let root = Paths.url(path)
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw SourceError.pathMissing(root.path)
        }
        return Payload(root: root, excludes: excludes, collectedAt: date)
    }

    public func finish(_ payload: Payload, deliveredEverywhere: Bool) {}
}
```

**`BackupCore/Sources/BackupCore/Providers/CommandSource.swift`**

```swift
import Foundation

public struct CommandSource: SourceProvider {
    private static let shell = URL(fileURLWithPath: "/bin/zsh")
    private static let outputTailLength = 4096

    private let command: String
    private let timeoutSeconds: Int
    private let stagingRoot: URL
    private let runner: any ProcessRunner

    public init(command: String, timeoutSeconds: Int, stagingRoot: URL, runner: any ProcessRunner) {
        self.command = command
        self.timeoutSeconds = timeoutSeconds
        self.stagingRoot = stagingRoot
        self.runner = runner
    }

    public func collect(at date: Date) async throws -> Payload {
        let fileManager = FileManager.default
        let session = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let output = session.appendingPathComponent("output", isDirectory: true)
        let scratch = session.appendingPathComponent("scratch", isDirectory: true)
        try fileManager.createDirectory(at: output, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        do {
            let result = try await runner.run(
                executable: Self.shell,
                arguments: ["-lc", command],
                environment: ["BACKUP_OUTPUT_DIR": output.path, "BACKUP_SCRATCH_DIR": scratch.path],
                timeout: TimeInterval(timeoutSeconds)
            )
            let tail = Self.tail(of: result)
            if result.timedOut {
                throw SourceError.commandTimedOut(seconds: timeoutSeconds, output: tail)
            }
            guard result.exitCode == 0 else {
                throw SourceError.commandFailed(exitCode: result.exitCode, output: tail)
            }
            return Payload(root: output, collectedAt: date, details: tail.isEmpty ? nil : tail)
        } catch {
            try? fileManager.removeItem(at: session)
            throw error
        }
    }

    public func finish(_ payload: Payload, deliveredEverywhere: Bool) {
        try? FileManager.default.removeItem(at: payload.root.deletingLastPathComponent())
    }

    private static func tail(of result: ProcessResult) -> String {
        let combined = [result.stdout, result.stderr]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return String(combined.suffix(outputTailLength))
    }
}
```

- [ ] **Step 4: Убедиться, что тесты проходят**

Run: `swift test --package-path BackupCore --filter SourceProviderTests`
Expected: PASS, 5 тестов.

- [ ] **Step 5: Commit**

```bash
git add BackupCore
git commit -m "Add folder and command sources"
```

---

### Task 8: Ручной экспорт

**Files:**
- Create: `BackupCore/Sources/BackupCore/Providers/{ManualExportInbox,ManualExportSource}.swift`
- Test: `BackupCore/Tests/BackupCoreTests/ManualExportInboxTests.swift`

**Interfaces:**
- Consumes: `SourceProvider`, `SourceError`, `Payload`, `SnapshotNaming`, `GlobPattern`, `Paths`.
- Produces: `InboxScan(files:totalBytes:downloadInProgress:)`, `.empty`, `isReady`; `PendingPackage(directory:collectedAt:)`; `ManualExportInbox(pendingRoot:naming:trash:)` с методами:

```swift
func scan(watchPath: String, filePattern: String, since: Date, now: Date) -> InboxScan
func pickUp(sourceId: UUID, files: [URL], removeOriginal: Bool, at date: Date) throws -> PendingPackage
func pendingPackage(for sourceId: UUID) -> PendingPackage?
func removePackage(for sourceId: UUID, toTrash: Bool) throws
```

- `ManualExportInbox.settleSeconds == 5`; `ManualExportSource(sourceId:removeOriginal:inbox:)`.

Правила `scan`:
- файл подходит, если имя совпало с маской, это обычный непустой файл и `max(дата изменения, дата создания) > since`;
- любой элемент папки с расширением `crdownload`, `download`, `part`, `tmp` ставит `downloadInProgress`;
- подходящий файл, изменённый меньше 5 секунд назад, не попадает в `files` и ставит `downloadInProgress`;
- папки нет — пустой результат.

Правила пакета:
- `pickUp` сначала убирает предыдущий пакет источника, затем перемещает (`removeOriginal == true`) или копирует файлы в `<pendingRoot>/<sourceId>/<имя снапшота>/`;
- `removePackage(toTrash: true)` отправляет файлы пакета в Корзину через замыкание `trash`; `toTrash: false` удаляет копии;
- `ManualExportSource.collect` отдаёт ожидающий пакет со временем подхвата, иначе `SourceError.nothingToCollect`; `finish` убирает пакет только при `deliveredEverywhere == true`.

Замыкание `trash` подменяется в тестах, чтобы тесты не трогали настоящую Корзину.

- [ ] **Step 1: Написать падающие тесты**

**`BackupCore/Tests/BackupCoreTests/ManualExportInboxTests.swift`**

```swift
import Foundation
import Testing
@testable import BackupCore

struct ManualExportInboxTests {
    private let temp: TempDirectory
    private let inbox: ManualExportInbox
    private let created = Fixtures.date("2026-09-01 00:00:00")
    private let now = Fixtures.date("2026-09-28 14:30:00")
    private let sourceId = UUID()

    init() throws {
        let temp = try TempDirectory()
        self.temp = temp
        try temp.directory("Downloads")
        try temp.directory("trash")
        inbox = ManualExportInbox(pendingRoot: temp.path("pending"), naming: Fixtures.naming) { url in
            try FileManager.default.moveItem(at: url, to: temp.path("trash/\(url.lastPathComponent)"))
        }
    }

    private func scan(_ pattern: String = "takeout-*.zip", since: Date? = nil) -> InboxScan {
        inbox.scan(watchPath: temp.path("Downloads").path, filePattern: pattern, since: since ?? created, now: now)
    }

    @Test func findsNewMatchingFilesCaseInsensitively() throws {
        defer { temp.remove() }
        try temp.file("Downloads/takeout-001.zip", "12345", modified: now.addingTimeInterval(-600))
        try temp.file("Downloads/Takeout-002.ZIP", "123", modified: now.addingTimeInterval(-300))
        try temp.file("Downloads/other.pdf", "x", modified: now.addingTimeInterval(-300))

        let result = scan()
        #expect(result.files.map(\.lastPathComponent) == ["Takeout-002.ZIP", "takeout-001.zip"])
        #expect(result.totalBytes == 8)
        #expect(result.isReady)
    }

    @Test func ignoresFilesOlderThanLastPickupAndEmptyPlaceholders() throws {
        defer { temp.remove() }
        try temp.file("Downloads/takeout-old.zip", "old", modified: created.addingTimeInterval(-86_400))
        try temp.file("Downloads/takeout-empty.zip", "", modified: now.addingTimeInterval(-600))
        #expect(scan() == .empty)
    }

    @Test(arguments: ["Unconfirmed 1234.crdownload", "takeout-002.zip.part", "takeout-002.zip.download"])
    func unfinishedDownloadBlocksPickup(name: String) throws {
        defer { temp.remove() }
        try temp.file("Downloads/takeout-001.zip", "12345", modified: now.addingTimeInterval(-600))
        try temp.file("Downloads/\(name)", "partial", modified: now.addingTimeInterval(-1))
        let result = scan()
        #expect(result.files.count == 1)
        #expect(result.downloadInProgress)
        #expect(!result.isReady)
    }

    @Test func freshlyWrittenFileIsNotSettledYet() throws {
        defer { temp.remove() }
        try temp.file("Downloads/takeout-001.zip", "12345", modified: now.addingTimeInterval(-2))
        let result = scan()
        #expect(result.files.isEmpty)
        #expect(result.downloadInProgress)
    }

    @Test func missingWatchFolderIsEmptyScan() {
        defer { temp.remove() }
        #expect(inbox.scan(watchPath: temp.path("nope").path, filePattern: "*", since: created, now: now) == .empty)
    }

    @Test func pickUpMovesFilesAndTrashesThemAfterDelivery() throws {
        defer { temp.remove() }
        let file = try temp.file("Downloads/takeout-001.zip", "12345", modified: now.addingTimeInterval(-600))
        let package = try inbox.pickUp(sourceId: sourceId, files: [file], removeOriginal: true, at: now)

        #expect(!temp.exists("Downloads/takeout-001.zip"))
        #expect(package.collectedAt == now)
        #expect(inbox.pendingPackage(for: sourceId) == package)
        #expect(FileManager.default.fileExists(atPath: package.directory.appendingPathComponent("takeout-001.zip").path))

        try inbox.removePackage(for: sourceId, toTrash: true)
        #expect(inbox.pendingPackage(for: sourceId) == nil)
        #expect(temp.names(in: "trash") == ["takeout-001.zip"])
    }

    @Test func pickUpCopiesWhenOriginalMustStay() throws {
        defer { temp.remove() }
        let file = try temp.file("Downloads/Passwords.csv", "secret", modified: now.addingTimeInterval(-600))
        _ = try inbox.pickUp(sourceId: sourceId, files: [file], removeOriginal: false, at: now)
        #expect(temp.exists("Downloads/Passwords.csv"))

        try inbox.removePackage(for: sourceId, toTrash: false)
        #expect(temp.names(in: "trash").isEmpty)
        #expect(temp.exists("Downloads/Passwords.csv"))
        #expect(scan("Passwords*.csv", since: now) == .empty)
    }

    @Test func newerPackageReplacesUndeliveredOne() throws {
        defer { temp.remove() }
        let first = try temp.file("Downloads/takeout-a.zip", "first", modified: now.addingTimeInterval(-600))
        _ = try inbox.pickUp(sourceId: sourceId, files: [first], removeOriginal: true, at: now)
        let later = now.addingTimeInterval(86_400)
        let second = try temp.file("Downloads/takeout-b.zip", "second", modified: later.addingTimeInterval(-600))
        let package = try inbox.pickUp(sourceId: sourceId, files: [second], removeOriginal: true, at: later)

        #expect(inbox.pendingPackage(for: sourceId) == package)
        #expect(temp.names(in: "pending/\(sourceId.uuidString)") == [Fixtures.naming.name(for: later)])
        #expect(temp.names(in: "trash") == ["takeout-a.zip"])
    }

    @Test func manualSourceCollectsPendingPackageAndKeepsItUntilDeliveredEverywhere() async throws {
        defer { temp.remove() }
        let source = ManualExportSource(sourceId: sourceId, removeOriginal: true, inbox: inbox)
        await #expect(throws: SourceError.nothingToCollect) { try await source.collect(at: now) }

        let file = try temp.file("Downloads/takeout-001.zip", "12345", modified: now.addingTimeInterval(-600))
        let package = try inbox.pickUp(sourceId: sourceId, files: [file], removeOriginal: true, at: now)
        let payload = try await source.collect(at: now.addingTimeInterval(3600))
        #expect(payload == Payload(root: package.directory, collectedAt: now))

        source.finish(payload, deliveredEverywhere: false)
        #expect(inbox.pendingPackage(for: sourceId) != nil)
        source.finish(payload, deliveredEverywhere: true)
        #expect(inbox.pendingPackage(for: sourceId) == nil)
    }
}
```

- [ ] **Step 2: Убедиться, что тесты не собираются**

Run: `swift test --package-path BackupCore --filter ManualExportInboxTests`
Expected: ошибка сборки `cannot find type 'ManualExportInbox' in scope`.

- [ ] **Step 3: Реализовать**

**`BackupCore/Sources/BackupCore/Providers/ManualExportInbox.swift`**

```swift
import Foundation

public struct InboxScan: Sendable, Equatable {
    public var files: [URL]
    public var totalBytes: Int64
    public var downloadInProgress: Bool

    public static let empty = InboxScan(files: [], totalBytes: 0, downloadInProgress: false)

    public init(files: [URL], totalBytes: Int64, downloadInProgress: Bool) {
        self.files = files
        self.totalBytes = totalBytes
        self.downloadInProgress = downloadInProgress
    }

    public var isReady: Bool {
        !files.isEmpty && !downloadInProgress
    }
}

public struct PendingPackage: Sendable, Equatable {
    public let directory: URL
    public let collectedAt: Date
}

public struct ManualExportInbox: Sendable {
    public typealias Trash = @Sendable (URL) throws -> Void

    public static let settleSeconds: TimeInterval = 5
    private static let inProgressExtensions: Set<String> = ["crdownload", "download", "part", "tmp"]

    private let pendingRoot: URL
    private let naming: SnapshotNaming
    private let trash: Trash

    public init(
        pendingRoot: URL,
        naming: SnapshotNaming,
        trash: @escaping Trash = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    ) {
        self.pendingRoot = pendingRoot
        self.naming = naming
        self.trash = trash
    }

    public func scan(watchPath: String, filePattern: String, since: Date, now: Date) -> InboxScan {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey]
        let items = (try? FileManager.default.contentsOfDirectory(
            at: Paths.url(watchPath),
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )) ?? []
        let pattern = GlobPattern(filePattern)
        var scan = InboxScan.empty
        for url in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            if Self.inProgressExtensions.contains(url.pathExtension.lowercased()) {
                scan.downloadInProgress = true
                continue
            }
            guard pattern.matches(url.lastPathComponent),
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  let size = values.fileSize, size > 0,
                  let modified = values.contentModificationDate else { continue }
            guard max(modified, values.creationDate ?? modified) > since else { continue }
            if now.timeIntervalSince(modified) < Self.settleSeconds {
                scan.downloadInProgress = true
                continue
            }
            scan.files.append(url)
            scan.totalBytes += Int64(size)
        }
        return scan
    }

    public func pickUp(sourceId: UUID, files: [URL], removeOriginal: Bool, at date: Date) throws -> PendingPackage {
        let fileManager = FileManager.default
        try removePackage(for: sourceId, toTrash: removeOriginal)
        let directory = sourceDirectory(sourceId).appendingPathComponent(naming.name(for: date), isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        for file in files {
            let target = directory.appendingPathComponent(file.lastPathComponent)
            if removeOriginal {
                try fileManager.moveItem(at: file, to: target)
            } else {
                try fileManager.copyItem(at: file, to: target)
            }
        }
        return PendingPackage(directory: directory, collectedAt: naming.date(from: directory.lastPathComponent) ?? date)
    }

    public func pendingPackage(for sourceId: UUID) -> PendingPackage? {
        let directory = sourceDirectory(sourceId)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names
            .compactMap { name in
                naming.date(from: name).map {
                    PendingPackage(directory: directory.appendingPathComponent(name, isDirectory: true), collectedAt: $0)
                }
            }
            .max { $0.collectedAt < $1.collectedAt }
    }

    public func removePackage(for sourceId: UUID, toTrash: Bool) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sourceDirectory(sourceId).path) else { return }
        if toTrash, let package = pendingPackage(for: sourceId) {
            for file in try fileManager.contentsOfDirectory(at: package.directory, includingPropertiesForKeys: nil) {
                try trash(file)
            }
        }
        try fileManager.removeItem(at: sourceDirectory(sourceId))
    }

    private func sourceDirectory(_ sourceId: UUID) -> URL {
        pendingRoot.appendingPathComponent(sourceId.uuidString, isDirectory: true)
    }
}
```

**`BackupCore/Sources/BackupCore/Providers/ManualExportSource.swift`**

```swift
import Foundation

public struct ManualExportSource: SourceProvider {
    private let sourceId: UUID
    private let removeOriginal: Bool
    private let inbox: ManualExportInbox

    public init(sourceId: UUID, removeOriginal: Bool, inbox: ManualExportInbox) {
        self.sourceId = sourceId
        self.removeOriginal = removeOriginal
        self.inbox = inbox
    }

    public func collect(at date: Date) async throws -> Payload {
        guard let package = inbox.pendingPackage(for: sourceId) else {
            throw SourceError.nothingToCollect
        }
        return Payload(root: package.directory, collectedAt: package.collectedAt)
    }

    public func finish(_ payload: Payload, deliveredEverywhere: Bool) {
        guard deliveredEverywhere else { return }
        try? inbox.removePackage(for: sourceId, toTrash: removeOriginal)
    }
}
```

- [ ] **Step 4: Убедиться, что тесты проходят**

Run: `swift test --package-path BackupCore --filter ManualExportInboxTests`
Expected: PASS, 9 тестов.

- [ ] **Step 5: Commit**

```bash
git add BackupCore
git commit -m "Add manual export inbox and source"
```

---

### Task 9: Движок прогона

**Files:**
- Create: `BackupCore/Sources/BackupCore/Engine/{Factories,BackupEngine}.swift`
- Test: `BackupCore/Tests/BackupCoreTests/Support/EngineFakes.swift`, `BackupCore/Tests/BackupCoreTests/BackupEngineTests.swift`

**Interfaces:**
- Consumes: всё из Task 1–8.
- Produces: `protocol SourceProviderFactory { func provider(for source: Source) -> any SourceProvider }`; `protocol DestinationStoreFactory { func store(for destination: Destination) -> any DestinationStore }`; `DefaultSourceProviderFactory(runner:stagingRoot:inbox:)`; `DefaultDestinationStoreFactory(runner:rclone:naming:)`; `BackupEngine(providers:stores:retention:naming:time:)` с `run(source:destinations:trigger:) async -> RunRecord`.

Порядок прогона:
1. Проверить доступность каждого назначения. Если недоступны все — вернуть запись со всеми `.unavailable`, данные не собирать.
2. Собрать данные. Ошибка сбора или ноль файлов — `collectError`, доставок нет.
3. Для каждого доступного назначения: `removeIncomplete` → если снапшота с таким именем ещё нет, `write` → `listSnapshots` → удалить то, что велит `RetentionPolicy`. Ошибка записи — `.failed`, чистка не выполняется. Ошибка чистки — `.delivered` с `warning`.
4. `provider.finish(payload, deliveredEverywhere:)` — `true`, только если все переданные назначения получили снапшот.

Движок не читает и не пишет состояние: запись прогона — его единственный результат.

- [ ] **Step 1: Написать подделки и падающие тесты**

**`BackupCore/Tests/BackupCoreTests/Support/EngineFakes.swift`**

```swift
import Foundation
@testable import BackupCore

final class FakeSourceProvider: SourceProvider, @unchecked Sendable {
    var result: Result<Payload, Error>
    private(set) var collectCount = 0
    private(set) var finished: [Bool] = []

    init(result: Result<Payload, Error>) {
        self.result = result
    }

    func collect(at date: Date) async throws -> Payload {
        collectCount += 1
        return try result.get()
    }

    func finish(_ payload: Payload, deliveredEverywhere: Bool) {
        finished.append(deliveredEverywhere)
    }
}

final class FakeDestinationStore: DestinationStore, @unchecked Sendable {
    var available = true
    var snapshots: [Snapshot] = []
    var writeError: Error?
    var deleteError: Error?
    private(set) var log: [String] = []

    func isAvailable() async -> Bool { available }

    func listSnapshots(sourceSlug: String) async throws -> [Snapshot] { snapshots }

    func removeIncomplete(sourceSlug: String) async throws {
        log.append("removeIncomplete")
    }

    func write(_ payload: Payload, manifest: SnapshotManifest, sourceSlug: String, snapshotName: String) async throws {
        if let writeError { throw writeError }
        log.append("write:\(snapshotName)")
        snapshots.append(Snapshot(name: snapshotName, date: manifest.collectedAt))
    }

    func delete(_ snapshot: Snapshot, sourceSlug: String) async throws {
        if let deleteError { throw deleteError }
        log.append("delete:\(snapshot.name)")
        snapshots.removeAll { $0 == snapshot }
    }
}

struct FakeFactories: SourceProviderFactory, DestinationStoreFactory {
    let sourceProvider: FakeSourceProvider
    let destinationStores: [UUID: FakeDestinationStore]

    func provider(for source: Source) -> any SourceProvider { sourceProvider }

    func store(for destination: Destination) -> any DestinationStore { destinationStores[destination.id]! }
}
```

**`BackupCore/Tests/BackupCoreTests/BackupEngineTests.swift`**

```swift
import Foundation
import Testing
@testable import BackupCore

struct BackupEngineTests {
    private struct Boom: Error, LocalizedError {
        var errorDescription: String? { "диск отвалился" }
    }

    private let temp: TempDirectory
    private let now = Fixtures.date("2026-09-28 14:30:00")
    private let name = "2026-09-28_143000"
    private let disk = Destination(name: "HDD", kind: .localFolder(path: "/unused/hdd"))
    private let cloud = Destination(name: "Cloud", kind: .localFolder(path: "/unused/cloud"))
    private let diskStore = FakeDestinationStore()
    private let cloudStore = FakeDestinationStore()
    private let provider: FakeSourceProvider
    private let source: Source

    init() throws {
        temp = try TempDirectory()
        try temp.file("vault/a.md", "alpha")
        provider = FakeSourceProvider(result: .success(Payload(root: temp.path("vault"), collectedAt: now, details: "log tail")))
        source = Fixtures.source(retention: RetentionRules(daily: 2, weekly: 0, monthly: 0, yearly: 0), destinations: [disk, cloud])
    }

    private func run(_ trigger: RunTrigger = .scheduled) async -> RunRecord {
        let factories = FakeFactories(sourceProvider: provider, destinationStores: [disk.id: diskStore, cloud.id: cloudStore])
        let engine = BackupEngine(
            providers: factories,
            stores: factories,
            retention: RetentionPolicy(timeZone: Fixtures.utc),
            naming: Fixtures.naming,
            time: FakeTimeSource(now)
        )
        return await engine.run(source: source, destinations: [disk, cloud], trigger: trigger)
    }

    @Test func deliversSnapshotToEveryDestination() async {
        defer { temp.remove() }
        let record = await run()
        #expect(record.snapshotName == name)
        #expect(record.fileCount == 1)
        #expect(record.totalBytes == 5)
        #expect(record.details == "log tail")
        #expect(record.collectError == nil)
        #expect(record.deliveries.map(\.outcome) == [.delivered(pruned: 0, warning: nil), .delivered(pruned: 0, warning: nil)])
        #expect(diskStore.log == ["removeIncomplete", "write:\(name)"])
        #expect(provider.finished == [true])
    }

    @Test func unavailableDestinationDoesNotBlockOthers() async {
        defer { temp.remove() }
        diskStore.available = false
        let record = await run()
        #expect(record.deliveries.map(\.outcome) == [.unavailable, .delivered(pruned: 0, warning: nil)])
        #expect(diskStore.log.isEmpty)
        #expect(provider.finished == [false])
    }

    @Test func nothingIsCollectedWhenNoDestinationIsReachable() async {
        defer { temp.remove() }
        diskStore.available = false
        cloudStore.available = false
        let record = await run()
        #expect(record.deliveries.map(\.outcome) == [.unavailable, .unavailable])
        #expect(record.isDeferredOnly)
        #expect(provider.collectCount == 0)
    }

    @Test func collectFailureWritesNothing() async {
        defer { temp.remove() }
        provider.result = .failure(SourceError.commandFailed(exitCode: 1, output: "auth required"))
        let record = await run()
        #expect(record.collectError == "Команда завершилась с кодом 1. auth required")
        #expect(record.deliveries.isEmpty)
        #expect(cloudStore.log.isEmpty)
    }

    @Test func emptySourceNeverProducesSnapshotOrPrunesOldOnes() async throws {
        defer { temp.remove() }
        try temp.directory("emptied")
        provider.result = .success(Payload(root: temp.path("emptied"), collectedAt: now))
        cloudStore.snapshots = ["2026-09-25 10:00:00", "2026-09-26 10:00:00", "2026-09-27 10:00:00"].map(Fixtures.snapshot)
        let record = await run()
        #expect(record.collectError == SourceError.emptyResult.localizedDescription)
        #expect(cloudStore.snapshots.count == 3)
        #expect(cloudStore.log.isEmpty)
        #expect(provider.finished == [false])
    }

    @Test func writeFailureIsIsolatedAndSkipsPruning() async {
        defer { temp.remove() }
        diskStore.writeError = Boom()
        diskStore.snapshots = ["2026-09-25 10:00:00", "2026-09-26 10:00:00", "2026-09-27 10:00:00"].map(Fixtures.snapshot)
        let record = await run()
        #expect(record.deliveries.map(\.outcome) == [.failed(message: "диск отвалился"), .delivered(pruned: 0, warning: nil)])
        #expect(record.firstFailure == "диск отвалился")
        #expect(diskStore.snapshots.count == 3)
        #expect(provider.finished == [false])
    }

    @Test func prunesByRetentionOnlyAfterSuccessfulWrite() async {
        defer { temp.remove() }
        cloudStore.snapshots = ["2026-09-25 10:00:00", "2026-09-26 10:00:00", "2026-09-27 10:00:00"].map(Fixtures.snapshot)
        let record = await run()
        #expect(record.deliveries[1].outcome == .delivered(pruned: 2, warning: nil))
        #expect(cloudStore.log == ["removeIncomplete", "write:\(name)", "delete:2026-09-25_100000", "delete:2026-09-26_100000"])
        #expect(cloudStore.snapshots.map(\.name) == ["2026-09-27_100000", name])
    }

    @Test func pruneFailureKeepsDeliveryButWarns() async {
        defer { temp.remove() }
        cloudStore.snapshots = ["2026-09-25 10:00:00", "2026-09-26 10:00:00"].map(Fixtures.snapshot)
        cloudStore.deleteError = Boom()
        let record = await run()
        #expect(record.deliveries[1].outcome == .delivered(pruned: 0, warning: "Не удалось очистить старые копии: диск отвалился"))
        #expect(record.firstFailure == nil)
    }

    @Test func alreadyDeliveredSnapshotIsNotWrittenTwice() async {
        defer { temp.remove() }
        cloudStore.snapshots = [Snapshot(name: name, date: now)]
        let record = await run(.catchUp)
        #expect(record.deliveries[1].outcome == .delivered(pruned: 0, warning: nil))
        #expect(cloudStore.log == ["removeIncomplete"])
    }
}
```

- [ ] **Step 2: Убедиться, что тесты не собираются**

Run: `swift test --package-path BackupCore --filter BackupEngineTests`
Expected: ошибка сборки `cannot find type 'SourceProviderFactory' in scope`.

- [ ] **Step 3: Реализовать**

**`BackupCore/Sources/BackupCore/Engine/Factories.swift`**

```swift
import Foundation

public protocol SourceProviderFactory: Sendable {
    func provider(for source: Source) -> any SourceProvider
}

public protocol DestinationStoreFactory: Sendable {
    func store(for destination: Destination) -> any DestinationStore
}

public struct DefaultSourceProviderFactory: SourceProviderFactory {
    private let runner: any ProcessRunner
    private let stagingRoot: URL
    private let inbox: ManualExportInbox

    public init(runner: any ProcessRunner, stagingRoot: URL, inbox: ManualExportInbox) {
        self.runner = runner
        self.stagingRoot = stagingRoot
        self.inbox = inbox
    }

    public func provider(for source: Source) -> any SourceProvider {
        switch source.kind {
        case let .folder(path, excludes):
            FolderSource(path: path, excludes: excludes)
        case let .command(command, timeoutSeconds):
            CommandSource(command: command, timeoutSeconds: timeoutSeconds, stagingRoot: stagingRoot, runner: runner)
        case let .manualExport(_, _, _, removeOriginal):
            ManualExportSource(sourceId: source.id, removeOriginal: removeOriginal, inbox: inbox)
        }
    }
}

public struct DefaultDestinationStoreFactory: DestinationStoreFactory {
    private let runner: any ProcessRunner
    private let rclone: RcloneLocator
    private let naming: SnapshotNaming

    public init(runner: any ProcessRunner, rclone: RcloneLocator, naming: SnapshotNaming) {
        self.runner = runner
        self.rclone = rclone
        self.naming = naming
    }

    public func store(for destination: Destination) -> any DestinationStore {
        switch destination.kind {
        case let .localFolder(path):
            LocalFolderDestination(root: Paths.url(path), naming: naming)
        case let .rclone(remote, path):
            RcloneDestination(executable: rclone.find(), remote: remote, path: path, runner: runner, naming: naming)
        }
    }
}
```

**`BackupCore/Sources/BackupCore/Engine/BackupEngine.swift`**

```swift
import Foundation

public struct BackupEngine: Sendable {
    private let providers: any SourceProviderFactory
    private let stores: any DestinationStoreFactory
    private let retention: RetentionPolicy
    private let naming: SnapshotNaming
    private let time: any TimeSource
    private let walker = PayloadWalker()

    public init(
        providers: any SourceProviderFactory,
        stores: any DestinationStoreFactory,
        retention: RetentionPolicy,
        naming: SnapshotNaming,
        time: any TimeSource
    ) {
        self.providers = providers
        self.stores = stores
        self.retention = retention
        self.naming = naming
        self.time = time
    }

    public func run(source: Source, destinations: [Destination], trigger: RunTrigger) async -> RunRecord {
        var record = RunRecord(
            sourceId: source.id,
            sourceName: source.name,
            trigger: trigger,
            startedAt: time.now,
            finishedAt: time.now
        )
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
        let stats: PayloadStats
        do {
            payload = try await provider.collect(at: record.startedAt)
            stats = walker.stats(of: try walker.entries(of: payload))
            guard stats.fileCount > 0 else {
                provider.finish(payload, deliveredEverywhere: false)
                throw SourceError.emptyResult
            }
        } catch {
            record.collectError = error.localizedDescription
            record.finishedAt = time.now
            return record
        }

        let snapshotName = naming.name(for: payload.collectedAt)
        let manifest = SnapshotManifest(
            sourceId: source.id,
            sourceName: source.name,
            collectedAt: payload.collectedAt,
            fileCount: stats.fileCount,
            totalBytes: stats.totalBytes
        )
        record.snapshotName = snapshotName
        record.fileCount = stats.fileCount
        record.totalBytes = stats.totalBytes
        record.details = payload.details

        for destination in destinations {
            let outcome: DeliveryOutcome
            if let store = reachable[destination.id] {
                outcome = await deliver(payload, manifest: manifest, snapshotName: snapshotName, source: source, to: store)
            } else {
                outcome = .unavailable
            }
            record.deliveries.append(Delivery(destinationId: destination.id, destinationName: destination.name, outcome: outcome))
        }
        provider.finish(payload, deliveredEverywhere: record.deliveries.allSatisfy(\.outcome.isDelivered))
        record.finishedAt = time.now
        return record
    }

    private func deliver(
        _ payload: Payload,
        manifest: SnapshotManifest,
        snapshotName: String,
        source: Source,
        to store: any DestinationStore
    ) async -> DeliveryOutcome {
        do {
            try await store.removeIncomplete(sourceSlug: source.slug)
            let existing = try await store.listSnapshots(sourceSlug: source.slug)
            if !existing.contains(where: { $0.name == snapshotName }) {
                try await store.write(payload, manifest: manifest, sourceSlug: source.slug, snapshotName: snapshotName)
            }
        } catch {
            return .failed(message: error.localizedDescription)
        }
        do {
            let snapshots = try await store.listSnapshots(sourceSlug: source.slug)
            let doomed = retention.snapshotsToDelete(snapshots, rules: source.retention)
            for snapshot in doomed {
                try await store.delete(snapshot, sourceSlug: source.slug)
            }
            return .delivered(pruned: doomed.count, warning: nil)
        } catch {
            return .delivered(pruned: 0, warning: "Не удалось очистить старые копии: \(error.localizedDescription)")
        }
    }
}
```

- [ ] **Step 4: Убедиться, что тесты проходят**

Run: `swift test --package-path BackupCore --filter BackupEngineTests`
Expected: PASS, 9 тестов.

- [ ] **Step 5: Commit**

```bash
git add BackupCore
git commit -m "Add backup engine"
```

---

### Task 10: Состояние и расписание

**Files:**
- Create: `BackupCore/Sources/BackupCore/Scheduling/{StateReducer,SchedulePlanner}.swift`
- Test: `BackupCore/Tests/BackupCoreTests/{StateReducerTests,SchedulePlannerTests}.swift`

**Interfaces:**
- Consumes: `AppState`, `Config`, `RunRecord`, `Source`, `Destination`, `Schedule`.
- Produces: `StateReducer().apply(_:to:)`, `dropOrphans(config:state:)`; `SchedulePlanner(calendar:)` с `retryInterval == 3600` и методами:

```swift
func dueDate(for source: Source, state: SourceState) -> Date?
func isDue(_ source: Source, state: SourceState, now: Date) -> Bool
func isSeverelyOverdue(_ source: Source, state: SourceState, now: Date) -> Bool
func dueAutomaticSources(config: Config, state: AppState, now: Date) -> [Source]
func retryableDebts(state: AppState, now: Date) -> [Debt]
func connectDeadline(for destination: Destination, state: AppState) -> Date?
func nextWake(config: Config, state: AppState, now: Date, needsAttention: Bool) -> Date?
```

Правила `StateReducer.apply`:
- ошибка сбора: `lastError`, `retryAfter = finishedAt + 1 ч`; `lastRun` и долги не меняются;
- `.delivered` снимает долг; `.unavailable` создаёт долг без `lastAttempt`; `.failed` создаёт или обновляет долг с `lastAttempt = finishedAt`; дата `since` существующего долга сохраняется;
- `lastError` = первая ошибка доставки или `nil`; `retryAfter = nil`;
- `lastRun = startedAt` для любого триггера, кроме `.catchUp`;
- назначению без оставшихся долгов ставится `lastCaughtUp = finishedAt`.

Правила `SchedulePlanner`:
- срок источника: `createdAt`, если он не запускался, иначе `lastRun + интервал`; у выключенных и у `schedule == .manual` срока нет;
- «сильно просрочен»: `now > срок + 2 интервала`;
- автоматически запускаются источники не типа «ручной экспорт», с назначениями, с наступившим сроком и истёкшим `retryAfter`;
- долг повторяется, если `lastAttempt` пуст или старше часа;
- срок подключения диска: `(lastCaughtUp ?? дата самого раннего долга) + N дней`; без долгов срока нет;
- `nextWake` — ближайшее будущее событие из: сроков источников (с учётом `retryAfter`), сроков подключения, `now + 1 ч` при `needsAttention`.

- [ ] **Step 1: Написать падающие тесты**

**`BackupCore/Tests/BackupCoreTests/StateReducerTests.swift`**

```swift
import Foundation
import Testing
@testable import BackupCore

struct StateReducerTests {
    private let reducer = StateReducer()
    private let sourceId = UUID()
    private let disk = UUID()
    private let cloud = UUID()
    private let started = Fixtures.date("2026-09-28 10:00:00")
    private let finished = Fixtures.date("2026-09-28 10:05:00")

    private func record(_ outcomes: [(UUID, DeliveryOutcome)], trigger: RunTrigger = .scheduled, collectError: String? = nil) -> RunRecord {
        RunRecord(
            sourceId: sourceId,
            sourceName: "Obsidian",
            trigger: trigger,
            startedAt: started,
            finishedAt: finished,
            collectError: collectError,
            deliveries: outcomes.map { Delivery(destinationId: $0.0, destinationName: "d", outcome: $0.1) }
        )
    }

    @Test func successAdvancesScheduleAndMarksDestinationsCaughtUp() {
        var state = AppState()
        reducer.apply(record([(disk, .delivered(pruned: 0, warning: nil)), (cloud, .delivered(pruned: 1, warning: nil))]), to: &state)
        #expect(state.sourceState(sourceId) == SourceState(lastRun: started))
        #expect(state.debts.isEmpty)
        #expect(state.destinationState(disk).lastCaughtUp == finished)
    }

    @Test func unavailableAndFailedDestinationsBecomeDebts() {
        var state = AppState()
        reducer.apply(record([(disk, .unavailable), (cloud, .failed(message: "quota"))]), to: &state)
        #expect(state.debts == [
            Debt(sourceId: sourceId, destinationId: disk, since: started),
            Debt(sourceId: sourceId, destinationId: cloud, since: started, lastAttempt: finished),
        ])
        #expect(state.sourceState(sourceId).lastRun == started)
        #expect(state.sourceState(sourceId).lastError == "quota")
        #expect(state.destinationState(disk).lastCaughtUp == nil)
    }

    @Test func repeatedMissKeepsOriginalDebtDate() {
        var state = AppState()
        let earlier = Fixtures.date("2026-09-20 10:00:00")
        state.debts = [Debt(sourceId: sourceId, destinationId: disk, since: earlier)]
        reducer.apply(record([(disk, .unavailable)]), to: &state)
        #expect(state.debts == [Debt(sourceId: sourceId, destinationId: disk, since: earlier)])
    }

    @Test func catchUpClearsDebtAndErrorWithoutMovingSchedule() {
        var state = AppState()
        let lastRun = Fixtures.date("2026-09-27 10:00:00")
        state.updateSource(sourceId) { $0.lastRun = lastRun; $0.lastError = "quota" }
        state.debts = [Debt(sourceId: sourceId, destinationId: disk, since: lastRun)]
        reducer.apply(record([(disk, .delivered(pruned: 0, warning: nil))], trigger: .catchUp), to: &state)
        #expect(state.debts.isEmpty)
        #expect(state.sourceState(sourceId) == SourceState(lastRun: lastRun))
        #expect(state.destinationState(disk).lastCaughtUp == finished)
    }

    @Test func destinationIsNotCaughtUpWhileOtherSourcesAreOwed() {
        var state = AppState()
        state.debts = [Debt(sourceId: UUID(), destinationId: disk, since: started)]
        reducer.apply(record([(disk, .delivered(pruned: 0, warning: nil))]), to: &state)
        #expect(state.destinationState(disk).lastCaughtUp == nil)
    }

    @Test func collectFailureSchedulesRetryAndKeepsSchedule() {
        var state = AppState()
        reducer.apply(record([], collectError: "auth required"), to: &state)
        #expect(state.sourceState(sourceId) == SourceState(lastError: "auth required", retryAfter: finished.addingTimeInterval(3600)))
    }

    @Test func dropsStateOfRemovedSourcesAndDestinations() {
        let keptDestination = Destination(name: "Cloud", kind: .localFolder(path: "/c"))
        let removedFromSource = Destination(name: "HDD", kind: .localFolder(path: "/h"))
        let source = Fixtures.source(destinations: [keptDestination])
        let config = Config(sources: [source], destinations: [keptDestination, removedFromSource])
        var state = AppState()
        state.debts = [
            Debt(sourceId: source.id, destinationId: keptDestination.id, since: started),
            Debt(sourceId: source.id, destinationId: removedFromSource.id, since: started),
            Debt(sourceId: UUID(), destinationId: keptDestination.id, since: started),
            Debt(sourceId: source.id, destinationId: UUID(), since: started),
        ]
        state.updateSource(UUID()) { $0.lastRun = started }
        state.updateSource(source.id) { $0.lastRun = started }

        reducer.dropOrphans(config: config, state: &state)
        #expect(state.debts == [Debt(sourceId: source.id, destinationId: keptDestination.id, since: started)])
        #expect(Array(state.sources.keys) == [source.id.uuidString])
    }
}
```

**`BackupCore/Tests/BackupCoreTests/SchedulePlannerTests.swift`**

```swift
import Foundation
import Testing
@testable import BackupCore

struct SchedulePlannerTests {
    private let planner = SchedulePlanner(calendar: Fixtures.calendar)
    private let cloud = Destination(name: "Cloud", kind: .localFolder(path: "/c"))
    private let disk = Destination(name: "HDD", kind: .localFolder(path: "/h"), expectedEvery: .days(30))
    private let created = Fixtures.date("2026-09-01 00:00:00")
    private let now = Fixtures.date("2026-09-28 10:00:00")

    @Test func neverRunSourceIsDueSinceCreation() {
        let source = Fixtures.source(destinations: [cloud], createdAt: created)
        #expect(planner.dueDate(for: source, state: SourceState()) == created)
        #expect(planner.isDue(source, state: SourceState(), now: now))
    }

    @Test func sourceIsDueOneIntervalAfterLastRun() {
        let source = Fixtures.source(schedule: .weekly, destinations: [cloud])
        let state = SourceState(lastRun: Fixtures.date("2026-09-22 10:00:00"))
        #expect(!planner.isDue(source, state: state, now: Fixtures.date("2026-09-29 09:59:59")))
        #expect(planner.isDue(source, state: state, now: Fixtures.date("2026-09-29 10:00:00")))
    }

    @Test func retryDelayPostponesDueSource() {
        let source = Fixtures.source(destinations: [cloud])
        let state = SourceState(retryAfter: now.addingTimeInterval(600))
        #expect(!planner.isDue(source, state: state, now: now))
        #expect(planner.isDue(source, state: state, now: now.addingTimeInterval(600)))
    }

    @Test func manualScheduleAndDisabledSourcesAreNeverDue() {
        var disabled = Fixtures.source(destinations: [cloud])
        disabled.enabled = false
        #expect(planner.dueDate(for: disabled, state: SourceState()) == nil)
        #expect(planner.dueDate(for: Fixtures.source(schedule: .manual, destinations: [cloud]), state: SourceState()) == nil)
    }

    @Test func automaticRunsSkipManualExportsAndSourcesWithoutDestinations() {
        let folder = Fixtures.source(name: "Obsidian", destinations: [cloud])
        let orphan = Fixtures.source(name: "Orphan")
        let manual = Fixtures.source(
            name: "Photos",
            kind: .manualExport(watchPath: "/d", filePattern: "*.zip", fileMode: .multiple, removeOriginal: true),
            destinations: [cloud]
        )
        let config = Config(sources: [folder, orphan, manual], destinations: [cloud])
        #expect(planner.dueAutomaticSources(config: config, state: AppState(), now: now).map(\.name) == ["Obsidian"])
    }

    @Test func severeOverdueStartsAfterTwoMissedIntervals() {
        let source = Fixtures.source(schedule: .daily, destinations: [cloud])
        let state = SourceState(lastRun: Fixtures.date("2026-09-25 10:00:00"))
        #expect(!planner.isSeverelyOverdue(source, state: state, now: Fixtures.date("2026-09-28 10:00:00")))
        #expect(planner.isSeverelyOverdue(source, state: state, now: Fixtures.date("2026-09-28 10:00:01")))
    }

    @Test func failedDebtsWaitAnHourBeforeRetry() {
        var state = AppState()
        let fresh = Debt(sourceId: UUID(), destinationId: cloud.id, since: now)
        let recentFailure = Debt(sourceId: UUID(), destinationId: cloud.id, since: now, lastAttempt: now.addingTimeInterval(-600))
        let oldFailure = Debt(sourceId: UUID(), destinationId: cloud.id, since: now, lastAttempt: now.addingTimeInterval(-3600))
        state.debts = [fresh, recentFailure, oldFailure]
        #expect(planner.retryableDebts(state: state, now: now) == [fresh, oldFailure])
    }

    @Test func connectDeadlineCountsFromLastCatchUpOrFirstDebt() {
        var state = AppState()
        #expect(planner.connectDeadline(for: disk, state: state) == nil)

        state.debts = [Debt(sourceId: UUID(), destinationId: disk.id, since: Fixtures.date("2026-09-10 10:00:00"))]
        #expect(planner.connectDeadline(for: disk, state: state) == Fixtures.date("2026-10-10 10:00:00"))

        state.updateDestination(disk.id) { $0.lastCaughtUp = Fixtures.date("2026-09-05 10:00:00") }
        #expect(planner.connectDeadline(for: disk, state: state) == Fixtures.date("2026-10-05 10:00:00"))
        #expect(planner.connectDeadline(for: cloud, state: state) == nil)
    }

    @Test func nextWakeIsEarliestFutureEvent() {
        let daily = Fixtures.source(name: "Daily", schedule: .daily, destinations: [cloud, disk])
        let weekly = Fixtures.source(name: "Weekly", schedule: .weekly, destinations: [cloud])
        let config = Config(sources: [daily, weekly], destinations: [cloud, disk])
        var state = AppState()
        state.updateSource(daily.id) { $0.lastRun = Fixtures.date("2026-09-28 08:00:00") }
        state.updateSource(weekly.id) { $0.lastRun = Fixtures.date("2026-09-27 08:00:00") }

        #expect(planner.nextWake(config: config, state: state, now: now, needsAttention: false) == Fixtures.date("2026-09-29 08:00:00"))
        #expect(planner.nextWake(config: config, state: state, now: now, needsAttention: true) == now.addingTimeInterval(3600))

        state.updateDestination(disk.id) { $0.lastCaughtUp = Fixtures.date("2026-08-29 20:00:00") }
        state.debts = [Debt(sourceId: daily.id, destinationId: disk.id, since: now)]
        #expect(planner.nextWake(config: config, state: state, now: now, needsAttention: false) == Fixtures.date("2026-09-28 20:00:00"))
    }

    @Test func nothingScheduledMeansNoWake() {
        let config = Config(sources: [Fixtures.source(schedule: .manual, destinations: [cloud])], destinations: [cloud])
        #expect(planner.nextWake(config: config, state: AppState(), now: now, needsAttention: false) == nil)
    }
}
```

- [ ] **Step 2: Убедиться, что тесты не собираются**

Run: `swift test --package-path BackupCore --filter "StateReducerTests|SchedulePlannerTests"`
Expected: ошибка сборки `cannot find 'StateReducer' in scope`.

- [ ] **Step 3: Реализовать**

**`BackupCore/Sources/BackupCore/Scheduling/StateReducer.swift`**

```swift
import Foundation

public struct StateReducer: Sendable {
    public init() {}

    public func apply(_ record: RunRecord, to state: inout AppState) {
        if let collectError = record.collectError {
            state.updateSource(record.sourceId) {
                $0.lastError = collectError
                $0.retryAfter = record.finishedAt.addingTimeInterval(SchedulePlanner.retryInterval)
            }
            return
        }
        for delivery in record.deliveries {
            switch delivery.outcome {
            case .delivered:
                state.debts.removeAll { $0.sourceId == record.sourceId && $0.destinationId == delivery.destinationId }
            case .unavailable:
                upsertDebt(record, delivery, attemptedAt: nil, in: &state)
            case .failed:
                upsertDebt(record, delivery, attemptedAt: record.finishedAt, in: &state)
            }
        }
        for delivery in record.deliveries where delivery.outcome.isDelivered {
            if state.debts(forDestination: delivery.destinationId).isEmpty {
                state.updateDestination(delivery.destinationId) { $0.lastCaughtUp = record.finishedAt }
            }
        }
        state.updateSource(record.sourceId) {
            $0.lastError = record.firstFailure
            $0.retryAfter = nil
            if record.trigger != .catchUp { $0.lastRun = record.startedAt }
        }
    }

    public func dropOrphans(config: Config, state: inout AppState) {
        state.debts.removeAll { debt in
            guard let source = config.source(debt.sourceId) else { return true }
            return config.destination(debt.destinationId) == nil || !source.destinationIds.contains(debt.destinationId)
        }
        let sourceKeys = Set(config.sources.map(\.id.uuidString))
        let destinationKeys = Set(config.destinations.map(\.id.uuidString))
        state.sources = state.sources.filter { sourceKeys.contains($0.key) }
        state.destinations = state.destinations.filter { destinationKeys.contains($0.key) }
    }

    private func upsertDebt(_ record: RunRecord, _ delivery: Delivery, attemptedAt: Date?, in state: inout AppState) {
        if let index = state.debts.firstIndex(where: { $0.sourceId == record.sourceId && $0.destinationId == delivery.destinationId }) {
            if let attemptedAt { state.debts[index].lastAttempt = attemptedAt }
        } else {
            state.debts.append(Debt(
                sourceId: record.sourceId,
                destinationId: delivery.destinationId,
                since: record.startedAt,
                lastAttempt: attemptedAt
            ))
        }
    }
}
```

**`BackupCore/Sources/BackupCore/Scheduling/SchedulePlanner.swift`**

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
        if let retryAfter = state.retryAfter, retryAfter > now { return false }
        return true
    }

    public func isSeverelyOverdue(_ source: Source, state: SourceState, now: Date) -> Bool {
        guard let due = dueDate(for: source, state: state),
              let first = source.schedule.nextDue(after: due, calendar: calendar),
              let second = source.schedule.nextDue(after: first, calendar: calendar) else { return false }
        return now > second
    }

    public func dueAutomaticSources(config: Config, state: AppState, now: Date) -> [Source] {
        config.sources.filter { source in
            !source.isManualExport
                && !source.destinationIds.isEmpty
                && isDue(source, state: state.sourceState(source.id), now: now)
        }
    }

    public func retryableDebts(state: AppState, now: Date) -> [Debt] {
        state.debts.filter { debt in
            guard let lastAttempt = debt.lastAttempt else { return true }
            return lastAttempt.addingTimeInterval(Self.retryInterval) <= now
        }
    }

    public func connectDeadline(for destination: Destination, state: AppState) -> Date? {
        guard case let .days(days) = destination.expectedEvery,
              let earliestDebt = state.debts(forDestination: destination.id).map(\.since).min() else { return nil }
        let reference = state.destinationState(destination.id).lastCaughtUp ?? earliestDebt
        return calendar.date(byAdding: .day, value: days, to: reference)
    }

    public func nextWake(config: Config, state: AppState, now: Date, needsAttention: Bool) -> Date? {
        var candidates: [Date] = []
        for source in config.sources {
            let sourceState = state.sourceState(source.id)
            guard let due = dueDate(for: source, state: sourceState) else { continue }
            candidates.append(max(due, sourceState.retryAfter ?? due))
        }
        candidates.append(contentsOf: config.destinations.compactMap { connectDeadline(for: $0, state: state) })
        if needsAttention {
            candidates.append(now.addingTimeInterval(Self.retryInterval))
        }
        return candidates.filter { $0 > now }.min()
    }
}
```

- [ ] **Step 4: Убедиться, что тесты проходят**

Run: `swift test --package-path BackupCore --filter "StateReducerTests|SchedulePlannerTests"`
Expected: PASS, 17 тестов.

- [ ] **Step 5: Commit**

```bash
git add BackupCore
git commit -m "Add state reducer and schedule planner"
```

---

### Task 11: Статус и напоминания

**Files:**
- Create: `BackupCore/Sources/BackupCore/Status/{StatusReporter,ReminderPlanner,Notice}.swift`
- Test: `BackupCore/Tests/BackupCoreTests/{StatusReporterTests,ReminderPlannerTests}.swift`

**Interfaces:**
- Consumes: `SchedulePlanner`, `Config`, `AppState`, `InboxScan`, `RunRecord`.
- Produces: `OverallStatus` (`.ok < .attention < .error`); `AttentionItem` (`runFailed`, `severelyOverdue`, `manualExportDue`, `filesAwaitingPickup`, `noDestinations`, `destinationUnavailable`, `connectDestination`) с `severity`; `StatusReport(items:)` с `overall`; `StatusReporter(planner:).report(config:state:now:unavailableDestinations:inboxScans:)`; `ReminderPlanner().dueReminders(in:state:now:)`, `record(_:report:state:now:)`; `Notice` (`manualExportDue`, `connectDestination`, `runFailed`, `destinationCaughtUp`); `TickResult(runs:notices:)`.

Соответствие спеке (раздел 5.5):

| Пункт | Условие | Цвет |
|---|---|---|
| `runFailed` | у источника есть `lastError` | красный |
| `severelyOverdue` | срок пропущен больше чем на два интервала | красный |
| `manualExportDue` | ручной экспорт, срок наступил, подходящих файлов нет | жёлтый |
| `filesAwaitingPickup` | ручной экспорт, найдены подходящие файлы | жёлтый |
| `noDestinations` | у включённого источника нет назначений | жёлтый |
| `destinationUnavailable` | назначение `always` недоступно и имеет долг | жёлтый |
| `connectDestination` | назначение с интервалом недоступно, имеет долг, срок подключения вышел | жёлтый |

Напоминают только `manualExportDue` и `connectDestination`, не чаще раза в сутки на каждый источник или диск. Когда повод исчез, отметка о напоминании стирается, и при следующем появлении повода напоминание придёт сразу.

- [ ] **Step 1: Написать падающие тесты**

**`BackupCore/Tests/BackupCoreTests/StatusReporterTests.swift`**

```swift
import Foundation
import Testing
@testable import BackupCore

struct StatusReporterTests {
    private let reporter = StatusReporter(planner: SchedulePlanner(calendar: Fixtures.calendar))
    private let cloud = Destination(name: "Cloud", kind: .localFolder(path: "/c"))
    private let disk = Destination(name: "HDD", kind: .localFolder(path: "/h"), expectedEvery: .days(30))
    private let now = Fixtures.date("2026-09-28 10:00:00")

    private func report(
        _ sources: [Source],
        _ state: AppState,
        unavailable: Set<UUID> = [],
        scans: [UUID: InboxScan] = [:]
    ) -> StatusReport {
        reporter.report(
            config: Config(sources: sources, destinations: [cloud, disk]),
            state: state,
            now: now,
            unavailableDestinations: unavailable,
            inboxScans: scans
        )
    }

    private func fresh(_ source: Source) -> AppState {
        var state = AppState()
        state.updateSource(source.id) { $0.lastRun = now.addingTimeInterval(-3600) }
        return state
    }

    private func photos(_ schedule: Schedule = .monthly) -> Source {
        Fixtures.source(
            name: "Photos",
            kind: .manualExport(watchPath: "/d", filePattern: "takeout-*.zip", fileMode: .multiple, removeOriginal: true),
            schedule: schedule,
            destinations: [cloud]
        )
    }

    @Test func freshSourcesAreOk() {
        let source = Fixtures.source(destinations: [cloud, disk])
        let result = report([source], fresh(source))
        #expect(result.items.isEmpty)
        #expect(result.overall == .ok)
    }

    @Test func failedRunIsError() {
        let source = Fixtures.source(destinations: [cloud])
        var state = fresh(source)
        state.updateSource(source.id) { $0.lastError = "quota" }
        let result = report([source], state)
        #expect(result.items == [.runFailed(sourceId: source.id, message: "quota")])
        #expect(result.overall == .error)
    }

    @Test func longOverdueSourceIsError() {
        let source = Fixtures.source(destinations: [cloud])
        var state = AppState()
        state.updateSource(source.id) { $0.lastRun = Fixtures.date("2026-09-20 10:00:00") }
        #expect(report([source], state).items == [.severelyOverdue(sourceId: source.id)])
    }

    @Test func sourceWithoutDestinationsNeedsAttention() {
        let source = Fixtures.source()
        let result = report([source], AppState())
        #expect(result.items == [.noDestinations(sourceId: source.id)])
        #expect(result.overall == .attention)
    }

    @Test func disabledSourceIsIgnored() {
        var source = Fixtures.source()
        source.enabled = false
        #expect(report([source], AppState()).overall == .ok)
    }

    @Test func dueManualExportAsksForExport() {
        let source = photos()
        var state = AppState()
        state.updateSource(source.id) { $0.lastRun = Fixtures.date("2026-08-20 10:00:00") }
        #expect(report([source], state).items == [.manualExportDue(sourceId: source.id)])
    }

    @Test func foundFilesReplaceTheReminder() {
        let source = photos()
        var state = AppState()
        state.updateSource(source.id) { $0.lastRun = Fixtures.date("2026-08-20 10:00:00") }
        let scan = InboxScan(files: [URL(fileURLWithPath: "/d/takeout-1.zip")], totalBytes: 12, downloadInProgress: true)
        #expect(report([source], state, scans: [source.id: scan]).items == [
            .filesAwaitingPickup(sourceId: source.id, fileCount: 1, totalBytes: 12, downloadInProgress: true),
        ])
    }

    @Test func unfinishedDownloadWithoutMatchingFilesIsNotReported() {
        let source = photos()
        let scan = InboxScan(files: [], totalBytes: 0, downloadInProgress: true)
        #expect(report([source], fresh(source), scans: [source.id: scan]).items.isEmpty)
    }

    @Test func alwaysOnDestinationWithDebtIsReportedWhenUnreachable() {
        let source = Fixtures.source(destinations: [cloud])
        var state = fresh(source)
        state.debts = [Debt(sourceId: source.id, destinationId: cloud.id, since: now)]
        #expect(report([source], state, unavailable: [cloud.id]).items == [.destinationUnavailable(destinationId: cloud.id)])
        #expect(report([source], state).items.isEmpty)
    }

    @Test func periodicDiskIsQuietUntilItsDeadline() {
        let source = Fixtures.source(destinations: [disk])
        var state = fresh(source)
        state.debts = [Debt(sourceId: source.id, destinationId: disk.id, since: Fixtures.date("2026-09-10 10:00:00"))]
        state.updateDestination(disk.id) { $0.lastCaughtUp = Fixtures.date("2026-09-09 10:00:00") }
        #expect(report([source], state, unavailable: [disk.id]).overall == .ok)

        state.updateDestination(disk.id) { $0.lastCaughtUp = Fixtures.date("2026-08-29 10:00:00") }
        #expect(report([source], state, unavailable: [disk.id]).items == [.connectDestination(destinationId: disk.id)])
    }
}
```

**`BackupCore/Tests/BackupCoreTests/ReminderPlannerTests.swift`**

```swift
import Foundation
import Testing
@testable import BackupCore

struct ReminderPlannerTests {
    private let planner = ReminderPlanner()
    private let now = Fixtures.date("2026-09-28 10:00:00")
    private let sourceId = UUID()
    private let diskId = UUID()

    @Test func remindsOnceADayOnlyAboutActionableItems() {
        let report = StatusReport(items: [
            .manualExportDue(sourceId: sourceId),
            .connectDestination(destinationId: diskId),
            .runFailed(sourceId: sourceId, message: "quota"),
            .destinationUnavailable(destinationId: diskId),
        ])
        var state = AppState()
        let first = planner.dueReminders(in: report, state: state, now: now)
        #expect(first == [.manualExportDue(sourceId: sourceId), .connectDestination(destinationId: diskId)])

        planner.record(first, report: report, state: &state, now: now)
        #expect(planner.dueReminders(in: report, state: state, now: now.addingTimeInterval(3600)).isEmpty)
        #expect(planner.dueReminders(in: report, state: state, now: now.addingTimeInterval(86_400)) == first)
    }

    @Test func resolvedReminderIsForgottenSoItFiresImmediatelyNextTime() {
        let due = StatusReport(items: [.manualExportDue(sourceId: sourceId)])
        var state = AppState()
        planner.record(due.items, report: due, state: &state, now: now)

        planner.record([], report: StatusReport(items: []), state: &state, now: now.addingTimeInterval(60))
        #expect(state.lastReminders.isEmpty)
        #expect(planner.dueReminders(in: due, state: state, now: now.addingTimeInterval(120)) == due.items)
    }
}
```

- [ ] **Step 2: Убедиться, что тесты не собираются**

Run: `swift test --package-path BackupCore --filter "StatusReporterTests|ReminderPlannerTests"`
Expected: ошибка сборки `cannot find 'StatusReporter' in scope`.

- [ ] **Step 3: Реализовать**

**`BackupCore/Sources/BackupCore/Status/StatusReporter.swift`**

```swift
import Foundation

public enum OverallStatus: Int, Sendable, Comparable {
    case ok
    case attention
    case error

    public static func < (lhs: OverallStatus, rhs: OverallStatus) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum AttentionItem: Sendable, Equatable {
    case runFailed(sourceId: UUID, message: String)
    case severelyOverdue(sourceId: UUID)
    case manualExportDue(sourceId: UUID)
    case filesAwaitingPickup(sourceId: UUID, fileCount: Int, totalBytes: Int64, downloadInProgress: Bool)
    case noDestinations(sourceId: UUID)
    case destinationUnavailable(destinationId: UUID)
    case connectDestination(destinationId: UUID)

    public var severity: OverallStatus {
        switch self {
        case .runFailed, .severelyOverdue: .error
        default: .attention
        }
    }
}

public struct StatusReport: Sendable, Equatable {
    public let items: [AttentionItem]

    public init(items: [AttentionItem]) {
        self.items = items
    }

    public var overall: OverallStatus {
        items.map(\.severity).max() ?? .ok
    }
}

public struct StatusReporter: Sendable {
    private let planner: SchedulePlanner

    public init(planner: SchedulePlanner) {
        self.planner = planner
    }

    public func report(
        config: Config,
        state: AppState,
        now: Date,
        unavailableDestinations: Set<UUID>,
        inboxScans: [UUID: InboxScan]
    ) -> StatusReport {
        var items: [AttentionItem] = []
        for source in config.sources where source.enabled {
            let sourceState = state.sourceState(source.id)
            if source.destinationIds.isEmpty {
                items.append(.noDestinations(sourceId: source.id))
                continue
            }
            if let message = sourceState.lastError {
                items.append(.runFailed(sourceId: source.id, message: message))
            }
            if planner.isSeverelyOverdue(source, state: sourceState, now: now) {
                items.append(.severelyOverdue(sourceId: source.id))
            }
            guard source.isManualExport else { continue }
            if let scan = inboxScans[source.id], !scan.files.isEmpty {
                items.append(.filesAwaitingPickup(
                    sourceId: source.id,
                    fileCount: scan.files.count,
                    totalBytes: scan.totalBytes,
                    downloadInProgress: scan.downloadInProgress
                ))
            } else if planner.isDue(source, state: sourceState, now: now) {
                items.append(.manualExportDue(sourceId: source.id))
            }
        }
        for destination in config.destinations where unavailableDestinations.contains(destination.id) {
            guard !state.debts(forDestination: destination.id).isEmpty else { continue }
            switch destination.expectedEvery {
            case .always:
                items.append(.destinationUnavailable(destinationId: destination.id))
            case .days:
                if let deadline = planner.connectDeadline(for: destination, state: state), deadline <= now {
                    items.append(.connectDestination(destinationId: destination.id))
                }
            }
        }
        return StatusReport(items: items)
    }
}
```

**`BackupCore/Sources/BackupCore/Status/ReminderPlanner.swift`**

```swift
import Foundation

public struct ReminderPlanner: Sendable {
    public static let repeatInterval: TimeInterval = 86_400

    public init() {}

    public func dueReminders(in report: StatusReport, state: AppState, now: Date) -> [AttentionItem] {
        report.items.filter { item in
            guard let key = key(for: item) else { return false }
            guard let last = state.lastReminders[key] else { return true }
            return last.addingTimeInterval(Self.repeatInterval) <= now
        }
    }

    public func record(_ reminded: [AttentionItem], report: StatusReport, state: inout AppState, now: Date) {
        let active = Set(report.items.compactMap(key))
        state.lastReminders = state.lastReminders.filter { active.contains($0.key) }
        for key in reminded.compactMap(key) {
            state.lastReminders[key] = now
        }
    }

    private func key(for item: AttentionItem) -> String? {
        switch item {
        case let .manualExportDue(sourceId): "manual:\(sourceId.uuidString)"
        case let .connectDestination(destinationId): "connect:\(destinationId.uuidString)"
        default: nil
        }
    }
}
```

**`BackupCore/Sources/BackupCore/Status/Notice.swift`**

```swift
import Foundation

public enum Notice: Sendable, Equatable {
    case manualExportDue(sourceId: UUID, sourceName: String)
    case connectDestination(destinationId: UUID, destinationName: String)
    case runFailed(sourceId: UUID, sourceName: String, message: String)
    case destinationCaughtUp(destinationId: UUID, destinationName: String)
}

public struct TickResult: Sendable, Equatable {
    public var runs: [RunRecord]
    public var notices: [Notice]

    public init(runs: [RunRecord] = [], notices: [Notice] = []) {
        self.runs = runs
        self.notices = notices
    }
}
```

- [ ] **Step 4: Убедиться, что тесты проходят**

Run: `swift test --package-path BackupCore --filter "StatusReporterTests|ReminderPlannerTests"`
Expected: PASS, 12 тестов.

- [ ] **Step 5: Commit**

```bash
git add BackupCore
git commit -m "Add status reporter and reminder planner"
```

---

### Task 12: Координатор, первый запуск, сборка ядра

**Files:**
- Create: `BackupCore/Sources/BackupCore/Application/{BackupCoordinator,Bootstrap,CoreAssembly}.swift`
- Test: `BackupCore/Tests/BackupCoreTests/{BackupCoordinatorTests,BootstrapTests}.swift`

**Interfaces:**
- Consumes: всё из Task 1–11.
- Produces — API, которым пользуется приложение (второй план):

```swift
public actor BackupCoordinator {
    public init(store: Store, engine: BackupEngine, inbox: ManualExportInbox,
                stores: any DestinationStoreFactory, time: any TimeSource, calendar: Calendar)
    public func tick() async throws -> TickResult
    public func runNow(sourceId: UUID) async throws -> TickResult
    public func runAllNow() async throws -> TickResult
    public func confirmPickup(sourceId: UUID) async throws -> TickResult
    public func statusReport() async throws -> StatusReport
    public func nextWake() async throws -> Date?
}
```

- `Bootstrap(store:workDirectory:).prepare(now:)`, `Bootstrap.selfSourceName`; `CoreAssembly.makeCoordinator(dataDirectory:workDirectory:timeZone:runner:time:rclone:)`, `CoreAssembly.stagingDirectory(in:)`, `CoreAssembly.pendingDirectory(in:)`.

Порядок `tick()`:
1. Прочитать настройки и состояние, убрать долги и состояние удалённых источников и назначений.
2. Догон: для каждого включённого источника с повторяемым долгом, у которого не наступил плановый срок, запустить прогон `.catchUp` во все назначения-должники этого источника. У ручного экспорта без ожидающего пакета долги снимаются.
3. Подхват: для ручных источников в режиме `single` — если `scan.isReady`, забрать файлы и запустить прогон `.pickup`.
4. Плановые прогоны `.scheduled` для автоматических источников с наступившим сроком.
5. Собрать уведомления: ошибки прогонов, «диск догнал» для назначений с интервалом, у которых были долги и не осталось, напоминания.

Все публичные операции, меняющие состояние, выстраиваются в очередь внутри актора, поэтому одновременные вызовы выполняются по одному. Прогон, в котором все назначения недоступны, в историю не пишется (кроме запущенного вручную). `runNow` для ручного экспорта равен `confirmPickup`. Источник без назначений не подхватывает файлы.

`Bootstrap.prepare`: создаёт папки, очищает `staging`, ставит встроенные шаблоны, при отсутствии `config.json` создаёт источник «Настройки Backup Everything» типа «Папка» на папку данных, без назначений, раз в день.

- [ ] **Step 1: Написать падающие тесты**

**`BackupCore/Tests/BackupCoreTests/BackupCoordinatorTests.swift`**

```swift
import Foundation
import Testing
@testable import BackupCore

struct BackupCoordinatorTests {
    private let temp: TempDirectory
    private let time: FakeTimeSource
    private let store: Store
    private let coordinator: BackupCoordinator
    private let cloud: Destination
    private let disk: Destination
    private let start = Fixtures.date("2026-09-28 10:00:00")
    private let created = Fixtures.date("2026-09-27 00:00:00")

    init() throws {
        let temp = try TempDirectory()
        self.temp = temp
        time = FakeTimeSource(start)
        store = Store(dataDirectory: temp.path("data"))
        try temp.directory("cloud")
        try temp.directory("Downloads")
        try temp.directory("trash")
        try temp.file("vault/a.md", "alpha")
        cloud = Fixtures.localDestination("Cloud", at: temp.path("cloud"))
        disk = Fixtures.localDestination("HDD", at: temp.path("hdd"), expectedEvery: .days(30))

        let inbox = ManualExportInbox(pendingRoot: temp.path("work/pending"), naming: Fixtures.naming) { url in
            try FileManager.default.moveItem(at: url, to: temp.path("trash/\(url.lastPathComponent)"))
        }
        let runner = SystemProcessRunner()
        let stores = DefaultDestinationStoreFactory(runner: runner, rclone: RcloneLocator(candidates: []), naming: Fixtures.naming)
        let engine = BackupEngine(
            providers: DefaultSourceProviderFactory(runner: runner, stagingRoot: temp.path("work/staging"), inbox: inbox),
            stores: stores,
            retention: RetentionPolicy(timeZone: Fixtures.utc),
            naming: Fixtures.naming,
            time: time
        )
        coordinator = BackupCoordinator(store: store, engine: engine, inbox: inbox, stores: stores, time: time, calendar: Fixtures.calendar)
    }

    private func vault(_ destinations: [Destination]) -> Source {
        Fixtures.source(kind: .folder(path: temp.path("vault").path, excludes: []), destinations: destinations, createdAt: created)
    }

    private func photos(_ mode: FileMode, _ destinations: [Destination]) -> Source {
        Fixtures.source(
            name: "Photos",
            kind: .manualExport(watchPath: temp.path("Downloads").path, filePattern: "takeout-*.zip", fileMode: mode, removeOriginal: true),
            schedule: .monthly,
            destinations: destinations,
            createdAt: created
        )
    }

    @Test func dueSourceIsBackedUpOncePerInterval() async throws {
        defer { temp.remove() }
        try store.saveConfig(Config(sources: [vault([cloud])], destinations: [cloud]))

        let first = try await coordinator.tick()
        #expect(first.runs.map(\.trigger) == [.scheduled])
        #expect(first.notices.isEmpty)
        #expect(temp.names(in: "cloud/obsidian") == ["2026-09-28_100000"])
        #expect(store.loadRuns().count == 1)
        #expect(try await coordinator.statusReport().overall == .ok)
        #expect(try await coordinator.nextWake() == Fixtures.date("2026-09-29 10:00:00"))

        time.advance(3600)
        #expect(try await coordinator.tick() == TickResult())

        time.advance(23 * 3600)
        #expect(try await coordinator.tick().runs.count == 1)
        #expect(temp.names(in: "cloud/obsidian") == ["2026-09-28_100000", "2026-09-29_100000"])
    }

    @Test func overlappingTicksRunTheSourceOnlyOnce() async throws {
        defer { temp.remove() }
        try store.saveConfig(Config(sources: [vault([cloud])], destinations: [cloud]))
        async let wake = coordinator.tick()
        async let mount = coordinator.tick()
        let results = try await [wake, mount]
        #expect(results.flatMap(\.runs).count == 1)
        #expect(temp.names(in: "cloud/obsidian").count == 1)
    }

    @Test func unpluggedDiskIsCaughtUpWithOneSnapshotWhenItReturns() async throws {
        defer { temp.remove() }
        try store.saveConfig(Config(sources: [vault([cloud, disk])], destinations: [cloud, disk]))

        for _ in 0..<3 {
            _ = try await coordinator.tick()
            time.advance(86_400)
        }
        #expect(temp.names(in: "cloud/obsidian").count == 3)
        #expect(!temp.exists("hdd"))
        #expect(try store.loadState().debts.count == 1)
        #expect(try await coordinator.statusReport().overall == .ok)

        time.advance(-3600)
        try temp.directory("hdd")
        let result = try await coordinator.tick()
        #expect(result.runs.map(\.trigger) == [.catchUp])
        #expect(result.notices == [.destinationCaughtUp(destinationId: disk.id, destinationName: "HDD")])
        #expect(temp.names(in: "hdd/obsidian").count == 1)
        #expect(try store.loadState().debts.isEmpty)
    }

    @Test func overdueDiskTriggersDailyConnectReminder() async throws {
        defer { temp.remove() }
        try store.saveConfig(Config(sources: [vault([disk])], destinations: [disk]))

        #expect(try await coordinator.tick() == TickResult())
        #expect(store.loadRuns().isEmpty)

        time.advance(30 * 86_400)
        let reminder = Notice.connectDestination(destinationId: disk.id, destinationName: "HDD")
        #expect(try await coordinator.tick().notices == [reminder])
        #expect(try await coordinator.statusReport().items == [.connectDestination(destinationId: disk.id)])

        time.advance(3600)
        #expect(try await coordinator.tick().notices.isEmpty)
        time.advance(23 * 3600)
        #expect(try await coordinator.tick().notices == [reminder])
    }

    @Test func failedRunIsReportedAndRetriedAfterAnHour() async throws {
        defer { temp.remove() }
        let source = Fixtures.source(kind: .folder(path: temp.path("moved").path, excludes: []), destinations: [cloud], createdAt: created)
        try store.saveConfig(Config(sources: [source], destinations: [cloud]))

        let failed = try await coordinator.tick()
        let message = SourceError.pathMissing(temp.path("moved").path).localizedDescription
        #expect(failed.notices == [.runFailed(sourceId: source.id, sourceName: "Obsidian", message: message)])
        #expect(try await coordinator.statusReport().overall == .error)
        #expect(try await coordinator.nextWake() == start.addingTimeInterval(3600))

        time.advance(600)
        #expect(try await coordinator.tick().runs.isEmpty)

        try temp.file("moved/a.md")
        time.advance(3000)
        let retried = try await coordinator.tick()
        #expect(retried.runs.count == 1)
        #expect(retried.notices.isEmpty)
        #expect(try await coordinator.statusReport().overall == .ok)
    }

    @Test func singleFileExportIsPickedUpAutomatically() async throws {
        defer { temp.remove() }
        let source = photos(.single, [cloud])
        try store.saveConfig(Config(sources: [source], destinations: [cloud]))
        #expect(try await coordinator.tick().notices == [.manualExportDue(sourceId: source.id, sourceName: "Photos")])

        try temp.file("Downloads/takeout-1.zip", "zip", modified: start.addingTimeInterval(-60))
        let result = try await coordinator.tick()
        #expect(result.runs.map(\.trigger) == [.pickup])
        #expect(temp.names(in: "cloud/photos/2026-09-28_100000") == ["_snapshot.json", "takeout-1.zip"])
        #expect(temp.names(in: "Downloads").isEmpty)
        #expect(temp.names(in: "trash") == ["takeout-1.zip"])
        #expect(try await coordinator.statusReport().overall == .ok)
    }

    @Test func multiFileExportWaitsForConfirmation() async throws {
        defer { temp.remove() }
        let source = photos(.multiple, [cloud])
        try store.saveConfig(Config(sources: [source], destinations: [cloud]))
        try temp.file("Downloads/takeout-1.zip", "one", modified: start.addingTimeInterval(-600))
        try temp.file("Downloads/takeout-2.zip", "two", modified: start.addingTimeInterval(-300))

        #expect(try await coordinator.tick().runs.isEmpty)
        #expect(try await coordinator.statusReport().items == [
            .filesAwaitingPickup(sourceId: source.id, fileCount: 2, totalBytes: 6, downloadInProgress: false),
        ])

        let result = try await coordinator.confirmPickup(sourceId: source.id)
        #expect(result.runs.map(\.trigger) == [.pickup])
        #expect(temp.names(in: "cloud/photos/2026-09-28_100000") == ["_snapshot.json", "takeout-1.zip", "takeout-2.zip"])
        #expect(try await coordinator.statusReport().overall == .ok)
    }

    @Test func confirmationIsIgnoredWhileDownloadIsUnfinished() async throws {
        defer { temp.remove() }
        let source = photos(.multiple, [cloud])
        try store.saveConfig(Config(sources: [source], destinations: [cloud]))
        try temp.file("Downloads/takeout-1.zip", "one", modified: start.addingTimeInterval(-600))
        try temp.file("Downloads/takeout-2.zip.crdownload", "tw", modified: start)

        #expect(try await coordinator.confirmPickup(sourceId: source.id).runs.isEmpty)
        #expect(temp.exists("Downloads/takeout-1.zip"))
    }

    @Test func manualExportWaitsInPendingUntilDiskReturns() async throws {
        defer { temp.remove() }
        let source = photos(.single, [cloud, disk])
        try store.saveConfig(Config(sources: [source], destinations: [cloud, disk]))
        try temp.file("Downloads/takeout-1.zip", "zip", modified: start.addingTimeInterval(-60))

        _ = try await coordinator.tick()
        #expect(temp.names(in: "cloud/photos") == ["2026-09-28_100000"])
        #expect(temp.names(in: "trash").isEmpty)
        #expect(temp.names(in: "work/pending/\(source.id.uuidString)") == ["2026-09-28_100000"])

        time.advance(5 * 86_400)
        try temp.directory("hdd")
        _ = try await coordinator.tick()
        #expect(temp.names(in: "hdd/photos") == ["2026-09-28_100000"])
        #expect(temp.names(in: "trash") == ["takeout-1.zip"])
        #expect(!temp.exists("work/pending/\(source.id.uuidString)"))
    }

    @Test func runNowIgnoresScheduleAndSameDayCopiesCollapseToNewest() async throws {
        defer { temp.remove() }
        let source = vault([cloud])
        try store.saveConfig(Config(sources: [source], destinations: [cloud]))
        _ = try await coordinator.tick()
        time.advance(60)
        #expect(try await coordinator.runNow(sourceId: source.id).runs.map(\.trigger) == [.manual])
        time.advance(60)
        #expect(try await coordinator.runAllNow().runs.count == 1)
        #expect(temp.names(in: "cloud/obsidian") == ["2026-09-28_100200"])
        #expect(store.loadRuns().count == 3)
    }

    @Test func corruptedConfigStopsTheTick() async throws {
        defer { temp.remove() }
        try temp.file("data/config.json", "{ broken")
        await #expect(throws: StoreError.corrupted(file: "config.json")) { try await coordinator.tick() }
    }
}
```

**`BackupCore/Tests/BackupCoreTests/BootstrapTests.swift`**

```swift
import Foundation
import Testing
@testable import BackupCore

struct BootstrapTests {
    @Test func firstLaunchCreatesSelfBackupSourceAndTemplates() async throws {
        let temp = try TempDirectory()
        defer { temp.remove() }
        let store = Store(dataDirectory: temp.path("data"))
        let bootstrap = Bootstrap(store: store, workDirectory: temp.path("work"))
        let now = Fixtures.date("2026-09-28 10:00:00")
        try temp.file("work/staging/leftover/output/file.txt")

        try bootstrap.prepare(now: now)

        let config = try store.loadConfig()
        #expect(config.sources.map(\.name) == [Bootstrap.selfSourceName])
        #expect(config.sources[0].kind == .folder(path: temp.path("data").path, excludes: []))
        #expect(config.sources[0].slug == "настройки-backup-everything")
        #expect(store.loadTemplates().count == 7)
        #expect(!temp.exists("work/staging"))
    }

    @Test func laterLaunchesKeepUserConfig() throws {
        let temp = try TempDirectory()
        defer { temp.remove() }
        let store = Store(dataDirectory: temp.path("data"))
        let bootstrap = Bootstrap(store: store, workDirectory: temp.path("work"))
        try bootstrap.prepare(now: Fixtures.date("2026-09-28 10:00:00"))
        try store.saveConfig(Config())

        try bootstrap.prepare(now: Fixtures.date("2026-09-29 10:00:00"))
        #expect(try store.loadConfig().sources.isEmpty)
    }

    @Test func assembledCoordinatorBacksUpItsOwnSettings() async throws {
        let temp = try TempDirectory()
        defer { temp.remove() }
        let store = Store(dataDirectory: temp.path("data"))
        let time = FakeTimeSource(Fixtures.date("2026-09-28 10:00:00"))
        try Bootstrap(store: store, workDirectory: temp.path("work")).prepare(now: time.now)
        try temp.directory("backups")
        let destination = Fixtures.localDestination("Disk", at: temp.path("backups"))
        var config = try store.loadConfig()
        config.destinations = [destination]
        config.sources[0].destinationIds = [destination.id]
        try store.saveConfig(config)

        let coordinator = CoreAssembly.makeCoordinator(
            dataDirectory: temp.path("data"),
            workDirectory: temp.path("work"),
            timeZone: Fixtures.utc,
            time: time
        )
        let result = try await coordinator.tick()

        #expect(result.runs.count == 1)
        #expect(temp.exists("backups/настройки-backup-everything/2026-09-28_100000/config.json"))
        #expect(temp.exists("backups/настройки-backup-everything/2026-09-28_100000/templates/github.json"))
    }
}
```

- [ ] **Step 2: Убедиться, что тесты не собираются**

Run: `swift test --package-path BackupCore --filter "BackupCoordinatorTests|BootstrapTests"`
Expected: ошибка сборки `cannot find type 'BackupCoordinator' in scope`.

- [ ] **Step 3: Реализовать**

**`BackupCore/Sources/BackupCore/Application/BackupCoordinator.swift`**

```swift
import Foundation

public actor BackupCoordinator {
    private let store: Store
    private let engine: BackupEngine
    private let inbox: ManualExportInbox
    private let stores: any DestinationStoreFactory
    private let time: any TimeSource
    private let planner: SchedulePlanner
    private let reporter: StatusReporter
    private let reminders = ReminderPlanner()
    private let reducer = StateReducer()
    private var queueTail: Task<Void, Never>?

    public init(
        store: Store,
        engine: BackupEngine,
        inbox: ManualExportInbox,
        stores: any DestinationStoreFactory,
        time: any TimeSource,
        calendar: Calendar
    ) {
        self.store = store
        self.engine = engine
        self.inbox = inbox
        self.stores = stores
        self.time = time
        self.planner = SchedulePlanner(calendar: calendar)
        self.reporter = StatusReporter(planner: planner)
    }

    public func tick() async throws -> TickResult {
        try await enqueue { try await self.performTick() }
    }

    public func runNow(sourceId: UUID) async throws -> TickResult {
        try await enqueue { try await self.performRunNow(sourceId: sourceId) }
    }

    public func runAllNow() async throws -> TickResult {
        try await enqueue { try await self.performRunAllNow() }
    }

    public func confirmPickup(sourceId: UUID) async throws -> TickResult {
        try await enqueue { try await self.performConfirmPickup(sourceId: sourceId) }
    }

    public func statusReport() async throws -> StatusReport {
        let config = try store.loadConfig()
        let state = try store.loadState()
        return await report(config: config, state: state, now: time.now)
    }

    public func nextWake() async throws -> Date? {
        let config = try store.loadConfig()
        let state = try store.loadState()
        let now = time.now
        let report = await report(config: config, state: state, now: now)
        return planner.nextWake(config: config, state: state, now: now, needsAttention: report.overall != .ok)
    }

    private func enqueue<Value: Sendable>(_ operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        let previous = queueTail
        let task = Task<Value, Error> {
            await previous?.value
            return try await operation()
        }
        queueTail = Task { _ = try? await task.value }
        return try await task.value
    }

    private func performTick() async throws -> TickResult {
        let config = try store.loadConfig()
        var state = try store.loadState()
        reducer.dropOrphans(config: config, state: &state)
        let now = time.now
        let debtorsBefore = Set(state.debts.map(\.destinationId))
        var runs: [RunRecord] = []

        let due = planner.dueAutomaticSources(config: config, state: state, now: now)
        let dueIds = Set(due.map(\.id))
        let retryableSourceIds = Set(planner.retryableDebts(state: state, now: now).map(\.sourceId))
        for source in config.sources where source.enabled && !dueIds.contains(source.id) {
            guard retryableSourceIds.contains(source.id) else { continue }
            if source.isManualExport, inbox.pendingPackage(for: source.id) == nil {
                state.debts.removeAll { $0.sourceId == source.id }
                continue
            }
            let debtors = state.debts.filter { $0.sourceId == source.id }.compactMap { config.destination($0.destinationId) }
            try await execute(source, debtors, .catchUp, state: &state, runs: &runs)
        }
        for source in config.sources where source.enabled {
            guard case let .manualExport(_, _, fileMode, _) = source.kind, fileMode == .single else { continue }
            try await pickUp(source, config: config, state: &state, runs: &runs)
        }
        for source in due {
            try await execute(source, config.destinations(of: source), .scheduled, state: &state, runs: &runs)
        }

        let notices = await closingNotices(config: config, state: &state, runs: runs, debtorsBefore: debtorsBefore)
        try store.saveState(state)
        return TickResult(runs: runs, notices: notices)
    }

    private func performRunNow(sourceId: UUID) async throws -> TickResult {
        let config = try store.loadConfig()
        var state = try store.loadState()
        var runs: [RunRecord] = []
        guard let source = config.source(sourceId) else { return TickResult() }
        if source.isManualExport {
            try await pickUp(source, config: config, state: &state, runs: &runs)
        } else {
            try await execute(source, config.destinations(of: source), .manual, state: &state, runs: &runs)
        }
        return TickResult(runs: runs, notices: failureNotices(runs))
    }

    private func performRunAllNow() async throws -> TickResult {
        let config = try store.loadConfig()
        var state = try store.loadState()
        var runs: [RunRecord] = []
        for source in config.sources where source.enabled && !source.isManualExport && !source.destinationIds.isEmpty {
            try await execute(source, config.destinations(of: source), .manual, state: &state, runs: &runs)
        }
        return TickResult(runs: runs, notices: failureNotices(runs))
    }

    private func performConfirmPickup(sourceId: UUID) async throws -> TickResult {
        let config = try store.loadConfig()
        var state = try store.loadState()
        var runs: [RunRecord] = []
        guard let source = config.source(sourceId) else { return TickResult() }
        try await pickUp(source, config: config, state: &state, runs: &runs)
        return TickResult(runs: runs, notices: failureNotices(runs))
    }

    private func pickUp(_ source: Source, config: Config, state: inout AppState, runs: inout [RunRecord]) async throws {
        guard case let .manualExport(watchPath, filePattern, _, removeOriginal) = source.kind,
              !source.destinationIds.isEmpty else { return }
        let now = time.now
        let since = state.sourceState(source.id).lastPickup ?? source.createdAt
        let scan = inbox.scan(watchPath: watchPath, filePattern: filePattern, since: since, now: now)
        guard scan.isReady else { return }
        _ = try inbox.pickUp(sourceId: source.id, files: scan.files, removeOriginal: removeOriginal, at: now)
        state.updateSource(source.id) { $0.lastPickup = now }
        try store.saveState(state)
        try await execute(source, config.destinations(of: source), .pickup, state: &state, runs: &runs)
    }

    private func execute(
        _ source: Source,
        _ destinations: [Destination],
        _ trigger: RunTrigger,
        state: inout AppState,
        runs: inout [RunRecord]
    ) async throws {
        let record = await engine.run(source: source, destinations: destinations, trigger: trigger)
        reducer.apply(record, to: &state)
        try store.saveState(state)
        if record.isDeferredOnly && trigger != .manual { return }
        try store.appendRun(record)
        runs.append(record)
    }

    private func closingNotices(
        config: Config,
        state: inout AppState,
        runs: [RunRecord],
        debtorsBefore: Set<UUID>
    ) async -> [Notice] {
        var notices = failureNotices(runs)
        for destination in config.destinations where debtorsBefore.contains(destination.id) {
            guard case .days = destination.expectedEvery, state.debts(forDestination: destination.id).isEmpty else { continue }
            notices.append(.destinationCaughtUp(destinationId: destination.id, destinationName: destination.name))
        }
        let now = time.now
        let report = await report(config: config, state: state, now: now)
        let reminded = reminders.dueReminders(in: report, state: state, now: now)
        reminders.record(reminded, report: report, state: &state, now: now)
        for item in reminded {
            switch item {
            case let .manualExportDue(sourceId):
                if let source = config.source(sourceId) {
                    notices.append(.manualExportDue(sourceId: sourceId, sourceName: source.name))
                }
            case let .connectDestination(destinationId):
                if let destination = config.destination(destinationId) {
                    notices.append(.connectDestination(destinationId: destinationId, destinationName: destination.name))
                }
            default:
                break
            }
        }
        return notices
    }

    private func failureNotices(_ runs: [RunRecord]) -> [Notice] {
        runs.compactMap { run in
            run.firstFailure.map { .runFailed(sourceId: run.sourceId, sourceName: run.sourceName, message: $0) }
        }
    }

    private func report(config: Config, state: AppState, now: Date) async -> StatusReport {
        var unavailable: Set<UUID> = []
        for destination in config.destinations where !state.debts(forDestination: destination.id).isEmpty {
            if !(await stores.store(for: destination).isAvailable()) {
                unavailable.insert(destination.id)
            }
        }
        var scans: [UUID: InboxScan] = [:]
        for source in config.sources where source.enabled {
            guard case let .manualExport(watchPath, filePattern, _, _) = source.kind else { continue }
            let since = state.sourceState(source.id).lastPickup ?? source.createdAt
            scans[source.id] = inbox.scan(watchPath: watchPath, filePattern: filePattern, since: since, now: now)
        }
        return reporter.report(config: config, state: state, now: now, unavailableDestinations: unavailable, inboxScans: scans)
    }
}
```

**`BackupCore/Sources/BackupCore/Application/Bootstrap.swift`**

```swift
import Foundation

public struct Bootstrap: Sendable {
    public static let selfSourceName = "Настройки Backup Everything"

    private let store: Store
    private let workDirectory: URL

    public init(store: Store, workDirectory: URL) {
        self.store = store
        self.workDirectory = workDirectory
    }

    public func prepare(now: Date) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: store.dataDirectory, withIntermediateDirectories: true)
        try? fileManager.removeItem(at: CoreAssembly.stagingDirectory(in: workDirectory))
        try fileManager.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        try store.installBundledTemplates()
        guard !store.hasConfig else { return }
        let selfSource = Source(
            name: Self.selfSourceName,
            slug: Slug.make(from: Self.selfSourceName, existing: []),
            kind: .folder(path: store.dataDirectory.path, excludes: []),
            schedule: .daily,
            instructions: "Настройки, история и шаблоны приложения. Выберите назначения, чтобы их можно было восстановить.",
            createdAt: now
        )
        try store.saveConfig(Config(sources: [selfSource]))
    }
}
```

**`BackupCore/Sources/BackupCore/Application/CoreAssembly.swift`**

```swift
import Foundation

public enum CoreAssembly {
    public static func stagingDirectory(in workDirectory: URL) -> URL {
        workDirectory.appendingPathComponent("staging", isDirectory: true)
    }

    public static func pendingDirectory(in workDirectory: URL) -> URL {
        workDirectory.appendingPathComponent("pending", isDirectory: true)
    }

    public static func makeCoordinator(
        dataDirectory: URL,
        workDirectory: URL,
        timeZone: TimeZone = .current,
        runner: any ProcessRunner = SystemProcessRunner(),
        time: any TimeSource = SystemTimeSource(),
        rclone: RcloneLocator = RcloneLocator()
    ) -> BackupCoordinator {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = timeZone
        let naming = SnapshotNaming(timeZone: timeZone)
        let inbox = ManualExportInbox(pendingRoot: pendingDirectory(in: workDirectory), naming: naming)
        let stores = DefaultDestinationStoreFactory(runner: runner, rclone: rclone, naming: naming)
        let engine = BackupEngine(
            providers: DefaultSourceProviderFactory(runner: runner, stagingRoot: stagingDirectory(in: workDirectory), inbox: inbox),
            stores: stores,
            retention: RetentionPolicy(timeZone: timeZone),
            naming: naming,
            time: time
        )
        return BackupCoordinator(
            store: Store(dataDirectory: dataDirectory),
            engine: engine,
            inbox: inbox,
            stores: stores,
            time: time,
            calendar: calendar
        )
    }
}
```

- [ ] **Step 4: Убедиться, что тесты проходят**

Run: `swift test --package-path BackupCore --filter "BackupCoordinatorTests|BootstrapTests"`
Expected: PASS, 14 тестов.

- [ ] **Step 5: Прогнать всё и проверить отсутствие предупреждений**

Run: `swift build --package-path BackupCore --build-tests 2>&1 | grep -ci warning`
Expected: `0`

Run: `swift test --package-path BackupCore`
Expected: `Test run with 113 tests passed`. Прогнать трижды подряд: тесты с таймаутом процесса и одновременными `tick()` не должны мигать.

- [ ] **Step 6: Commit**

```bash
git add BackupCore
git commit -m "Add backup coordinator, bootstrap and core assembly"
```

---

## После этого плана

Ядро готово и проверено тестами, но приложения ещё нет. Следующий шаг — отдельный brainstorming и план для приложения: экраны, таймер и системные события, уведомления. Он опирается на API из Task 12 и на `Store` для редактирования настроек.
