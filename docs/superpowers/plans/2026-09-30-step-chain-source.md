# Источник «По шагам» — план реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Добавить тип источника «По шагам» (цепочка из ручных шагов и команд) и перевести на него шаблон и источник Claude, экспорт которого теперь отдаёт манифест со ссылками на архивы.

**Architecture:** Новый вариант `SourceKind.steps` хранит список `SourceStep`. Положение цепочки живёт в `SourceState.chain`. `StepChainRunner` делает ровно один переход за вызов (принять файл ручного шага, выполнить команду, собрать результат в пакет `pending`), а `BackupCoordinator` крутит его в цикле, сохраняя `state.json` после каждого перехода. Готовый пакет доставляется существующим механизмом ручного экспорта (`ManualExportSource` + `pending` + долги).

**Tech Stack:** Swift 6, Swift Package Manager, Swift Testing (`@Test`, `#expect`), SwiftUI (macOS 15), zsh для команд источников.

**Spec:** `docs/superpowers/specs/2026-09-30-backup-manager-design.md` — раздел 4.1 «Правила типа „По шагам“» и «Шаблон Claude», а также 5.5, 5.6, 6, 7, 8.

## Global Constraints

- Ядро `BackupCore/` не зависит от UI; `App/` зависит от ядра. macOS 14+ для ядра, 15+ для приложения.
- Перед каждым коммитом обязательны оба прогона и оба должны быть зелёными, код возврата каждой команды проверяется отдельно:
  - `swift test --package-path BackupCore`
  - `swift test --package-path App`
- Каждый упавший тест — блокер, даже если падал раньше. Тесты не скипать и не отключать.
- Интерфейс и тексты ошибок — на русском.
- Комментарии в коде — только там, где без них не обойтись.
- Удаление файлов в командах разработки — только `trash`; `rm`, `unlink` запрещены. В коде приложения пользовательские файлы уходят в Корзину (`FileManager.trashItem`), временные рабочие папки удаляются напрямую.
- Прод не трогать до задачи 10: не запускать `scripts/build-app.sh`, не править `~/BackupEverything/`, не завершать запущенное приложение. Все проверки интерфейса — в песочнице (см. `CLAUDE.md`, раздел «Песочница»).
- В `config.json` и в репозитории нет секретов.
- Работа идёт в ветке `steps-source`. Коммиты заканчиваются строкой `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Тип источника выбирается при добавлении и дальше не меняется.
- Тип «Ручной экспорт» остаётся как есть.

## Review Focus

1. **Шаги источника отредактировали, пока цепочка в середине** (шагов стало меньше, чем `stepIndex`). Ожидание: цепочка сбрасывается к началу, приложение не падает. Тест — задача 4, `chainIsResetWhenStepsWereRemoved`.
2. **Приложение закрыли во время команды.** Файл ручного шага к этому моменту уже забран из «Загрузок»; если положение цепочки не сохранено, манифест потерян. Ожидание: `state.json` записан до запуска команды. Тест — задача 5, `chainPositionIsSavedBeforeTheCommandRuns`.
3. **Firefox создаёт пустой файл с финальным именем и рядом `.part`.** Ожидание: команда Claude не считает такой архив скачанным. Тест — задача 7, `halfDownloadedArchiveIsNotTaken`.
4. **В «Загрузках» лежит одноимённый архив от прошлого экспорта.** Браузер сохранит новый как `имя (1).zip`, и ожидание никогда не закончится. Ожидание: понятная ошибка сразу, ни одна одноразовая ссылка не открыта. Тест — задача 7, `staleArchiveStopsTheStepBeforeAnyLinkIsOpened`.
5. **У источника нет назначений.** Ожидание: цепочка не стартует и не забирает файл из «Загрузок». Тест — задача 5, `chainWithoutDestinationsLeavesTheFileAlone`.

## Карта файлов

Ядро (`BackupCore/Sources/BackupCore/`):

| Файл | Что меняется |
|---|---|
| `Domain/SourceStep.swift` (новый) | `StepKind`, `SourceStep`, `WatchedFile` |
| `Domain/Source.swift` | `SourceKind.steps`, `steps`, `isStepChain`, `deliversFromPending`, `watchedFiles` |
| `Domain/AppState.swift` | `ChainState`, `SourceState.chain` |
| `Infrastructure/ShellCommand.swift` (новый) | запуск команды через `/bin/zsh -lc` с разбором результата; общий для `CommandSource` и шагов |
| `Providers/CommandSource.swift` | переходит на `ShellCommand` |
| `Providers/ManualExportInbox.swift` | `adopt(sourceId:directory:at:)` |
| `Engine/StepChainRunner.swift` (новый) | один переход цепочки, рабочие папки `chains/<sourceId>/` |
| `Engine/RunProgress.swift` | `.step(sourceId:index:count:)` |
| `Engine/Factories.swift` | провайдер для `.steps` |
| `Application/BackupCoordinator.swift` | цикл цепочки, `restartChain`, догон |
| `Application/CoreAssembly.swift` | `chainsDirectory`, сборка `StepChainRunner` |
| `Application/ConfigEditor.swift` | `maskConflicts` через `watchedFiles` |
| `Scheduling/SchedulePlanner.swift` | `dueAutomaticSources` исключает `deliversFromPending` |
| `Status/StatusReporter.swift` | `.stepAwaitingFile`, ошибка цепочки, напоминание первого шага |
| `Storage/BundledTemplates.swift` | шаблон Claude на шагах |

Приложение (`App/Sources/BackupEverything/`):

| Файл | Что меняется |
|---|---|
| `Model/Drafts.swift` | `StepKindChoice`, `StepDraft`, шаги в `SourceDraft` |
| `Views/StepsEditor.swift` (новый) | карточки шагов |
| `Views/SourcesView.swift` | блок шагов, подписи |
| `Presentation/ChainPosition.swift` (новый) | «шаг N из M», общий текст пометки |
| `Presentation/SourceGuide.swift` (новый) | инструкция источника вместе с инструкциями ручных шагов |
| `Presentation/SourceStatus.swift`, `LiveReport.swift`, `MenuLines.swift`, `Texts.swift`, `StatusStyle.swift` | новые случаи |
| `Model/ActivityTracker.swift` | номер выполняемого шага |
| `Model/AppModel.swift` | `restartChain`, `chain(of:)`, `runStep(of:)` |
| `Views/OverviewView.swift`, `Views/MenuBarView.swift` | пометки и действия |
| `System/BackgroundDriver.swift` | слежение за папками ручных шагов |

---

### Task 1: Модель — шаги, положение цепочки, маски

**Files:**
- Create: `BackupCore/Sources/BackupCore/Domain/SourceStep.swift`
- Modify: `BackupCore/Sources/BackupCore/Domain/Source.swift`
- Modify: `BackupCore/Sources/BackupCore/Domain/AppState.swift`
- Modify: `BackupCore/Sources/BackupCore/Engine/Factories.swift`
- Modify: `BackupCore/Sources/BackupCore/Application/ConfigEditor.swift`
- Modify: `BackupCore/Sources/BackupCore/Application/BackupCoordinator.swift`
- Modify: `BackupCore/Sources/BackupCore/Scheduling/SchedulePlanner.swift`
- Modify: `App/Sources/BackupEverything/Model/Drafts.swift`
- Modify: `App/Sources/BackupEverything/Views/SourcesView.swift`
- Modify: `App/Sources/BackupEverything/Presentation/Texts.swift`
- Modify: `App/Sources/BackupEverything/Presentation/StatusStyle.swift`
- Modify: `App/Sources/BackupEverything/System/BackgroundDriver.swift`
- Test: `BackupCore/Tests/BackupCoreTests/DomainTests.swift`, `BackupCore/Tests/BackupCoreTests/ConfigEditorTests.swift`, `App/Tests/BackupEverythingTests/DraftTests.swift`

**Interfaces:**
- Produces:
  - `enum StepKind { case manual(instructions: String, watchPath: String, filePattern: String, includeInCopy: Bool); case command(command: String, timeoutSeconds: Int) }`
  - `struct SourceStep { var id: UUID; var name: String; var kind: StepKind; init(id: UUID = UUID(), name: String, kind: StepKind); var isManual: Bool }`
  - `struct WatchedFile { let watchPath: String; let filePattern: String }`
  - `SourceKind.steps(steps: [SourceStep])`
  - `Source.steps: [SourceStep]`, `Source.isStepChain: Bool`, `Source.deliversFromPending: Bool`, `Source.watchedFiles: [WatchedFile]`
  - `struct ChainState { var stepIndex: Int; var startedAt: Date; var stepEnteredAt: Date; var failure: String? }`, `SourceState.chain: ChainState?`
  - В приложении: `SourceKindChoice.steps`, `SourceDraft.steps: [SourceStep]` (в задаче 8 заменится на `[StepDraft]`)

- [ ] **Step 1: Написать падающие тесты ядра**

В `DomainTests.swift` добавить:

```swift
    @Test func stepChainRoundTripsThroughReadableJSON() throws {
        let steps = [
            SourceStep(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                name: "Запросить экспорт",
                kind: .manual(instructions: "скачай манифест", watchPath: "~/Downloads", filePattern: "manifest-*.json", includeInCopy: false)
            ),
            SourceStep(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                name: "Скачать архивы",
                kind: .command(command: "echo hi", timeoutSeconds: 3600)
            ),
        ]
        let source = Fixtures.source(name: "Claude", kind: .steps(steps: steps), schedule: .monthly)
        let data = try JSONCoding.encoder().encode(source)
        #expect(try JSONCoding.decoder().decode(Source.self, from: data) == source)

        let json = #"{"steps":{"steps":[{"id":"00000000-0000-0000-0000-000000000002","name":"Скачать архивы","kind":{"command":{"command":"echo hi","timeoutSeconds":3600}}}]}}"#
        #expect(try JSONCoding.decoder().decode(SourceKind.self, from: Data(json.utf8)) == .steps(steps: [steps[1]]))
    }

    @Test func sourceKnowsWhichFilesItWaitsFor() {
        let manual = SourceStep(name: "A", kind: .manual(instructions: "", watchPath: "~/Downloads", filePattern: "manifest-*.json", includeInCopy: false))
        let command = SourceStep(name: "B", kind: .command(command: "true", timeoutSeconds: 60))
        let chain = Fixtures.source(kind: .steps(steps: [manual, command]))
        #expect(chain.isStepChain)
        #expect(chain.deliversFromPending)
        #expect(chain.steps.map(\.isManual) == [true, false])
        #expect(chain.watchedFiles == [WatchedFile(watchPath: "~/Downloads", filePattern: "manifest-*.json")])

        let export = Fixtures.source(kind: .manualExport(watchPath: "~/Downloads", filePattern: "takeout-*.zip", fileMode: .multiple, removeOriginal: true))
        #expect(!export.isStepChain)
        #expect(export.deliversFromPending)
        #expect(export.watchedFiles == [WatchedFile(watchPath: "~/Downloads", filePattern: "takeout-*.zip")])

        let folder = Fixtures.source()
        #expect(!folder.deliversFromPending)
        #expect(folder.steps.isEmpty)
        #expect(folder.watchedFiles.isEmpty)
    }

    @Test func stateSavedBeforeChainsStillLoadsAndChainRoundTrips() throws {
        let legacy = Data(#"{"lastRun":"2026-09-28T10:00:00Z"}"#.utf8)
        #expect(try JSONCoding.decoder().decode(SourceState.self, from: legacy).chain == nil)

        let at = Fixtures.date("2026-09-28 10:00:00")
        let state = SourceState(chain: ChainState(stepIndex: 1, startedAt: at, stepEnteredAt: at, failure: "сломалось"))
        #expect(try JSONCoding.decoder().decode(SourceState.self, from: JSONCoding.encoder().encode(state)) == state)
    }
```

В `ConfigEditorTests.swift` добавить (структура тестов там уже есть; если в файле используется общий `editor`, использовать его, иначе `ConfigEditor()`):

```swift
    @Test func manualStepMaskConflictsWithManualExportInTheSameFolder() {
        let step = SourceStep(name: "Манифест", kind: .manual(instructions: "", watchPath: "~/Downloads", filePattern: "*.json", includeInCopy: false))
        let chain = Fixtures.source(name: "Claude", kind: .steps(steps: [step]))
        let export = Fixtures.source(
            name: "Экспорт",
            kind: .manualExport(watchPath: "~/Downloads", filePattern: "data-*.json", fileMode: .single, removeOriginal: true)
        )
        let elsewhere = Fixtures.source(
            name: "Другая папка",
            kind: .manualExport(watchPath: "~/Desktop", filePattern: "*.json", fileMode: .single, removeOriginal: true)
        )
        let config = Config(sources: [chain, export, elsewhere])
        #expect(ConfigEditor().maskConflicts(for: chain, in: config).map(\.name) == ["Экспорт"])
        #expect(ConfigEditor().maskConflicts(for: export, in: config).map(\.name) == ["Claude"])
    }
```

- [ ] **Step 2: Убедиться, что тесты не собираются**

Run: `swift test --package-path BackupCore 2>&1 | tail -20`
Expected: ошибка компиляции — `cannot find 'SourceStep' in scope`.

- [ ] **Step 3: Реализовать модель**

Создать `BackupCore/Sources/BackupCore/Domain/SourceStep.swift`:

```swift
import Foundation

public enum StepKind: Codable, Sendable, Equatable {
    case manual(instructions: String, watchPath: String, filePattern: String, includeInCopy: Bool)
    case command(command: String, timeoutSeconds: Int)
}

public struct SourceStep: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var kind: StepKind

    public init(id: UUID = UUID(), name: String, kind: StepKind) {
        self.id = id
        self.name = name
        self.kind = kind
    }

    public var isManual: Bool {
        if case .manual = kind { return true }
        return false
    }
}

public struct WatchedFile: Sendable, Equatable {
    public let watchPath: String
    public let filePattern: String

    public init(watchPath: String, filePattern: String) {
        self.watchPath = watchPath
        self.filePattern = filePattern
    }
}
```

В `Domain/Source.swift` добавить вариант в `SourceKind`:

```swift
    case steps(steps: [SourceStep])
```

и рядом с `isManualExport` в `Source`:

```swift
    public var steps: [SourceStep] {
        if case let .steps(steps) = kind { return steps }
        return []
    }

    public var isStepChain: Bool {
        if case .steps = kind { return true }
        return false
    }

    public var deliversFromPending: Bool {
        isManualExport || isStepChain
    }

    public var watchedFiles: [WatchedFile] {
        switch kind {
        case .folder, .command:
            []
        case let .manualExport(watchPath, filePattern, _, _):
            [WatchedFile(watchPath: watchPath, filePattern: filePattern)]
        case let .steps(steps):
            steps.compactMap { step in
                guard case let .manual(_, watchPath, filePattern, _) = step.kind else { return nil }
                return WatchedFile(watchPath: watchPath, filePattern: filePattern)
            }
        }
    }
```

В `Domain/AppState.swift` перед `SourceState` добавить:

```swift
public struct ChainState: Codable, Sendable, Equatable {
    public var stepIndex: Int
    public var startedAt: Date
    public var stepEnteredAt: Date
    public var failure: String?

    public init(stepIndex: Int, startedAt: Date, stepEnteredAt: Date, failure: String? = nil) {
        self.stepIndex = stepIndex
        self.startedAt = startedAt
        self.stepEnteredAt = stepEnteredAt
        self.failure = failure
    }
}
```

В `SourceState` добавить поле `public var chain: ChainState?` и параметр `chain: ChainState? = nil` последним в `init` с присваиванием `self.chain = chain`.

В `Engine/Factories.swift` в `provider(for:)` добавить ветку:

```swift
        case .steps:
            ManualExportSource(sourceId: source.id, removeOriginal: true, inbox: inbox)
```

В `Application/ConfigEditor.swift` заменить `maskConflicts` целиком (метод `sample(of:)` остаётся):

```swift
    public func maskConflicts(for source: Source, in config: Config) -> [Source] {
        let own = source.watchedFiles.filter { !$0.filePattern.isEmpty }
        guard !own.isEmpty else { return [] }
        return config.sources.filter { other in
            other.id != source.id && other.watchedFiles.contains { theirs in
                !theirs.filePattern.isEmpty && own.contains { Self.overlap($0, theirs) }
            }
        }
    }

    private static func overlap(_ first: WatchedFile, _ second: WatchedFile) -> Bool {
        guard Paths.url(first.watchPath).standardizedFileURL == Paths.url(second.watchPath).standardizedFileURL else { return false }
        return GlobPattern(first.filePattern).matches(sample(of: second.filePattern))
            || GlobPattern(second.filePattern).matches(sample(of: first.filePattern))
    }
```

В `Scheduling/SchedulePlanner.swift` в `dueAutomaticSources` заменить `!source.isManualExport` на `!source.deliversFromPending`.

В `Application/BackupCoordinator.swift`:
- в `performTick` заменить `if source.isManualExport, inbox.pendingPackage(for: source.id) == nil` на `if source.deliversFromPending, inbox.pendingPackage(for: source.id) == nil`;
- в `performRunNow` заменить `if source.isManualExport {` на `if source.deliversFromPending {` (для цепочки `pickUp` пока ничего не делает; запуск появится в задаче 5);
- в `performRunAllNow` заменить `!$0.isManualExport` на `!$0.deliversFromPending`.

- [ ] **Step 4: Прогнать тесты ядра**

Run: `swift test --package-path BackupCore 2>&1 | tail -5`
Expected: все тесты проходят.

- [ ] **Step 5: Написать падающий тест приложения**

В `App/Tests/BackupEverythingTests/DraftTests.swift` добавить четвёртый аргумент в `sourceDraftRoundTripsEveryKind`:

```swift
        SourceKind.steps(steps: [
            SourceStep(name: "Манифест", kind: .manual(instructions: "скачай", watchPath: "~/Downloads", filePattern: "manifest-*.json", includeInCopy: false)),
            SourceStep(name: "Архивы", kind: .command(command: "echo hi", timeoutSeconds: 3600)),
        ]),
```

и тест:

```swift
    @Test func stepChainWithoutStepsCannotBeSaved() {
        var draft = SourceDraft(source(.steps(steps: [])))
        #expect(draft.problem == "Добавьте хотя бы один шаг.")
        draft.steps = [SourceStep(name: "Архивы", kind: .command(command: "echo hi", timeoutSeconds: 60))]
        #expect(draft.problem == nil)
    }
```

Run: `swift test --package-path App 2>&1 | tail -20`
Expected: ошибка компиляции — `switch must be exhaustive` в `Drafts.swift`, `Texts.swift`, `StatusStyle.swift`, `SourcesView.swift`.

- [ ] **Step 6: Научить приложение новому типу (без редактора шагов)**

`Model/Drafts.swift`:
- в `SourceKindChoice` добавить `case steps` и заголовок `case .steps: "По шагам"`;
- в `SourceDraft` добавить поле `var steps: [SourceStep] = []`;
- в `init` добавить ветку:

```swift
        case let .steps(steps):
            kindChoice = .steps
            self.steps = steps
```

- в `problem` перед `default` добавить `case .steps where steps.isEmpty: return "Добавьте хотя бы один шаг."`;
- в `build()` добавить ветку:

```swift
        case .steps:
            source.kind = .steps(steps: steps)
```

`Presentation/Texts.swift`, `kind(_:)`: добавить `case .steps: "По шагам"`.

`Presentation/StatusStyle.swift`, `symbol(for kind: SourceKind)`: добавить `case .steps: "list.number"`.

`Views/SourcesView.swift`:
- в `symbol` добавить `case .steps: "list.number"`;
- в `kindCard` добавить ветку (временный список только для чтения, редактор появится в задаче 8):

```swift
        case .steps:
            SettingsSection(title: "Что бэкапить · тип «По шагам»: шаги выполняются по очереди") {
                ForEach(Array(draft.steps.enumerated()), id: \.element.id) { index, step in
                    SettingsRow(title: "\(index + 1). \(step.name)") {
                        Text(step.isManual ? "Ручной шаг" : "Команда").foregroundStyle(.secondary)
                    }
                }
            }
```

`System/BackgroundDriver.swift`, `refreshWatchers`: заменить тело первого цикла на

```swift
        for source in model.config.sources where source.enabled {
            for file in source.watchedFiles {
                wanted.insert(AppPaths.expand(file.watchPath).path)
            }
        }
```

- [ ] **Step 7: Прогнать оба набора тестов**

Run: `swift test --package-path BackupCore 2>&1 | tail -5`
Expected: PASS.
Run: `swift test --package-path App 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 8: Коммит**

```bash
git add BackupCore App
git commit -m "Add the step-chain source kind to the model

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: `ShellCommand` — общий запуск команд

**Files:**
- Create: `BackupCore/Sources/BackupCore/Infrastructure/ShellCommand.swift`
- Modify: `BackupCore/Sources/BackupCore/Providers/CommandSource.swift`
- Test: `BackupCore/Tests/BackupCoreTests/SourceProviderTests.swift`

**Interfaces:**
- Produces: `struct ShellCommand: Sendable { init(runner: any ProcessRunner); func run(_ command: String, timeoutSeconds: Int, environment: [String: String], status: @escaping StatusHandler) async throws -> String }` — возвращает хвост вывода (до 4096 символов), бросает `SourceError.commandTimedOut` / `SourceError.commandFailed`.

- [ ] **Step 1: Написать падающий тест**

В `SourceProviderTests.swift` добавить:

```swift
    @Test func shellCommandPassesEnvironmentAndReportsFailures() async throws {
        let runner = FakeProcessRunner(output: ["1 из 2"]) { call in
            call.environment["MODE"] == "fail" ? ProcessResult(exitCode: 3, stdout: "out\n", stderr: "boom\n") : ProcessResult(exitCode: 0, stdout: "готово\n")
        }
        let shell = ShellCommand(runner: runner)
        let lines = LockedBox<[String]>([])

        let tail = try await shell.run("echo hi", timeoutSeconds: 30, environment: ["MODE": "ok"]) { lines.set(lines.get() + [$0]) }
        #expect(tail == "готово")
        #expect(lines.get() == ["1 из 2"])
        #expect(runner.calls.first?.arguments == ["-lc", "echo hi"])
        #expect(runner.calls.first?.executable.path == "/bin/zsh")
        #expect(runner.calls.first?.timeout == 30)

        await #expect(throws: SourceError.commandFailed(exitCode: 3, output: "out\nboom")) {
            try await shell.run("echo hi", timeoutSeconds: 30, environment: ["MODE": "fail"]) { _ in }
        }
    }
```

- [ ] **Step 2: Убедиться, что тест не собирается**

Run: `swift test --package-path BackupCore --filter shellCommandPassesEnvironmentAndReportsFailures 2>&1 | tail -10`
Expected: `cannot find 'ShellCommand' in scope`.

- [ ] **Step 3: Реализовать и перевести `CommandSource`**

Создать `Infrastructure/ShellCommand.swift`:

```swift
import Foundation

public struct ShellCommand: Sendable {
    private static let shell = URL(fileURLWithPath: "/bin/zsh")
    private static let outputTailLength = 4096

    private let runner: any ProcessRunner

    public init(runner: any ProcessRunner) {
        self.runner = runner
    }

    public func run(
        _ command: String,
        timeoutSeconds: Int,
        environment: [String: String],
        status: @escaping StatusHandler
    ) async throws -> String {
        let result = try await runner.run(
            executable: Self.shell,
            arguments: ["-lc", command],
            environment: environment,
            timeout: TimeInterval(timeoutSeconds),
            onOutput: status
        )
        let tail = Self.tail(of: result)
        if result.timedOut {
            throw SourceError.commandTimedOut(seconds: timeoutSeconds, output: tail)
        }
        guard result.exitCode == 0 else {
            throw SourceError.commandFailed(exitCode: result.exitCode, output: tail)
        }
        return tail
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

`Providers/CommandSource.swift` заменить целиком:

```swift
import Foundation

public struct CommandSource: SourceProvider {
    private let command: String
    private let timeoutSeconds: Int
    private let stagingRoot: URL
    private let shell: ShellCommand

    public init(command: String, timeoutSeconds: Int, stagingRoot: URL, runner: any ProcessRunner) {
        self.command = command
        self.timeoutSeconds = timeoutSeconds
        self.stagingRoot = stagingRoot
        self.shell = ShellCommand(runner: runner)
    }

    public func collect(at date: Date, status: @escaping StatusHandler) async throws -> Payload {
        let fileManager = FileManager.default
        let session = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let output = session.appendingPathComponent("output", isDirectory: true)
        let scratch = session.appendingPathComponent("scratch", isDirectory: true)
        try fileManager.createDirectory(at: output, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        do {
            let tail = try await shell.run(
                command,
                timeoutSeconds: timeoutSeconds,
                environment: ["BACKUP_OUTPUT_DIR": output.path, "BACKUP_SCRATCH_DIR": scratch.path],
                status: status
            )
            return Payload(root: output, collectedAt: date, details: tail.isEmpty ? nil : tail)
        } catch {
            try? fileManager.removeItem(at: session)
            throw error
        }
    }

    public func finish(_ payload: Payload, deliveredEverywhere: Bool) {
        try? FileManager.default.removeItem(at: payload.root.deletingLastPathComponent())
    }
}
```

- [ ] **Step 4: Прогнать тесты**

Run: `swift test --package-path BackupCore 2>&1 | tail -5`
Expected: PASS (включая прежние тесты `CommandSource`).
Run: `swift test --package-path App 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 5: Коммит**

```bash
git add BackupCore
git commit -m "Extract shell command running so step chains can reuse it

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: `ManualExportInbox.adopt` — готовая папка становится пакетом

**Files:**
- Modify: `BackupCore/Sources/BackupCore/Providers/ManualExportInbox.swift`
- Test: `BackupCore/Tests/BackupCoreTests/ManualExportInboxTests.swift`

**Interfaces:**
- Produces: `func adopt(sourceId: UUID, directory: URL, at date: Date) throws -> PendingPackage` — перемещает `directory` в `pending/<sourceId>/<имя снапшота>`, прежний недоставленный пакет источника уходит в Корзину.

- [ ] **Step 1: Написать падающий тест**

В `ManualExportInboxTests.swift` добавить (в файле уже есть фикстуры временной папки; если общие свойства называются иначе — использовать `TempDirectory()` локально, как ниже):

```swift
    @Test func adoptedFolderBecomesThePendingPackageAndReplacesTheOldOne() throws {
        let temp = try TempDirectory()
        defer { temp.remove() }
        try temp.directory("trash")
        let inbox = ManualExportInbox(pendingRoot: temp.path("pending"), naming: Fixtures.naming) { url in
            try FileManager.default.moveItem(at: url, to: temp.path("trash/\(url.lastPathComponent)"))
        }
        let sourceId = UUID()
        let first = Fixtures.date("2026-09-28 10:00:00")
        let second = Fixtures.date("2026-09-29 10:00:00")

        try temp.file("chain/output/old.zip", "old")
        let oldPackage = try inbox.adopt(sourceId: sourceId, directory: temp.path("chain/output"), at: first)
        #expect(oldPackage.collectedAt == first)
        #expect(!temp.exists("chain/output"))

        try temp.file("chain/output/new.zip", "new")
        let package = try inbox.adopt(sourceId: sourceId, directory: temp.path("chain/output"), at: second)

        #expect(inbox.pendingPackage(for: sourceId) == package)
        #expect(package.collectedAt == second)
        #expect(temp.names(in: "pending/\(sourceId.uuidString)") == ["2026-09-29_100000"])
        #expect(temp.names(in: "pending/\(sourceId.uuidString)/2026-09-29_100000") == ["new.zip"])
        #expect(temp.names(in: "trash") == ["old.zip"])
    }
```

- [ ] **Step 2: Убедиться, что тест не собирается**

Run: `swift test --package-path BackupCore --filter adoptedFolderBecomesThePendingPackageAndReplacesTheOldOne 2>&1 | tail -10`
Expected: `value of type 'ManualExportInbox' has no member 'adopt'`.

- [ ] **Step 3: Реализовать**

В `ManualExportInbox` после `pickUp` добавить:

```swift
    public func adopt(sourceId: UUID, directory: URL, at date: Date) throws -> PendingPackage {
        let fileManager = FileManager.default
        try removePackage(for: sourceId, toTrash: true)
        try fileManager.createDirectory(at: sourceDirectory(sourceId), withIntermediateDirectories: true)
        let target = sourceDirectory(sourceId).appendingPathComponent(naming.name(for: date), isDirectory: true)
        try fileManager.moveItem(at: directory, to: target)
        return PendingPackage(directory: target, collectedAt: naming.date(from: target.lastPathComponent) ?? date)
    }
```

- [ ] **Step 4: Прогнать тесты**

Run: `swift test --package-path BackupCore 2>&1 | tail -5`
Expected: PASS.
Run: `swift test --package-path App 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 5: Коммит**

```bash
git add BackupCore
git commit -m "Let the inbox adopt a finished folder as a pending package

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: `StepChainRunner` — один переход цепочки

**Files:**
- Create: `BackupCore/Sources/BackupCore/Engine/StepChainRunner.swift`
- Modify: `BackupCore/Sources/BackupCore/Engine/RunProgress.swift`
- Modify: `App/Sources/BackupEverything/Model/ActivityTracker.swift`
- Test: `BackupCore/Tests/BackupCoreTests/StepChainRunnerTests.swift` (новый), `App/Tests/BackupEverythingTests/ActivityTrackerTests.swift`

**Interfaces:**
- Consumes: `ShellCommand` (задача 2), `ManualExportInbox.scan` и `.adopt` (задача 3), `ChainState`, `SourceStep` (задача 1).
- Produces:
  - `RunProgress.step(sourceId: UUID, index: Int, count: Int)` — `index` с нуля
  - `enum ChainTransition: Sendable, Equatable { case stay; case moved(ChainState?); case failed(ChainState); case completed(PendingPackage) }`
  - `struct ChainPermissions: Sendable, Equatable { var mayStart: Bool; var mayRetry: Bool; init(mayStart: Bool, mayRetry: Bool) }`
  - `struct StepChainRunner: Sendable`
    - `init(chainsRoot: URL, inbox: ManualExportInbox, runner: any ProcessRunner, time: any TimeSource, trash: @escaping ManualExportInbox.Trash = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }, progress: @escaping ProgressHandler = { _ in })`
    - `func advance(_ source: Source, chain: ChainState?, lastPickup: Date?, permissions: ChainPermissions) async -> ChainTransition`
    - `func discard(sourceId: UUID) throws`
  - В приложении: `ActivityTracker.step(of: UUID) -> (index: Int, count: Int)?`

Семантика `advance` (ровно один переход за вызов):
- `.stay` — делать нечего: файла нет, старт не разрешён, шаг упал и повтор не разрешён.
- `.moved(state)` — положение изменилось, вызвать ещё раз. `nil` — цепочка сброшена к началу.
- `.failed(state)` — команда (или сборка результата) упала; причина в `state.failure`.
- `.completed(package)` — результат лежит в `pending`.

- [ ] **Step 1: Написать падающие тесты**

Создать `BackupCore/Tests/BackupCoreTests/StepChainRunnerTests.swift`:

```swift
import Foundation
import Testing
@testable import BackupCore

struct StepChainRunnerTests {
    private let temp: TempDirectory
    private let time: FakeTimeSource
    private let inbox: ManualExportInbox
    private let events = LockedBox<[RunProgress]>([])
    private let start = Fixtures.date("2026-09-28 10:00:00")
    private let created = Fixtures.date("2026-09-27 00:00:00")
    private let allowAll = ChainPermissions(mayStart: true, mayRetry: true)
    private let tickOnly = ChainPermissions(mayStart: false, mayRetry: false)

    init() throws {
        let temp = try TempDirectory()
        self.temp = temp
        time = FakeTimeSource(start)
        try temp.directory("Downloads")
        try temp.directory("trash")
        inbox = ManualExportInbox(pendingRoot: temp.path("pending"), naming: Fixtures.naming) { url in
            try FileManager.default.moveItem(at: url, to: temp.path("trash/\(url.lastPathComponent)"))
        }
    }

    private func runner(_ handler: @escaping @Sendable (FakeProcessRunner.Call) throws -> ProcessResult = { _ in ProcessResult(exitCode: 0) }) -> StepChainRunner {
        StepChainRunner(
            chainsRoot: temp.path("chains"),
            inbox: inbox,
            runner: FakeProcessRunner(output: ["скачано 1 из 2"], handler: handler),
            time: time,
            trash: { [temp] url in try FileManager.default.moveItem(at: url, to: temp.path("trash/\(url.lastPathComponent)")) },
            progress: { [events] event in events.set(events.get() + [event]) }
        )
    }

    private func manual(_ pattern: String, includeInCopy: Bool = false) -> SourceStep {
        SourceStep(name: "Файл \(pattern)", kind: .manual(instructions: "", watchPath: temp.path("Downloads").path, filePattern: pattern, includeInCopy: includeInCopy))
    }

    private func command(_ name: String = "Скачать архивы") -> SourceStep {
        SourceStep(name: name, kind: .command(command: "run \(name)", timeoutSeconds: 60))
    }

    private func source(_ steps: [SourceStep]) -> Source {
        Fixtures.source(name: "Claude", kind: .steps(steps: steps), schedule: .monthly, createdAt: created)
    }

    private func writeArchive(_ call: FakeProcessRunner.Call) throws -> ProcessResult {
        let output = URL(fileURLWithPath: call.environment["BACKUP_OUTPUT_DIR"]!)
        try Data("zip".utf8).write(to: output.appendingPathComponent("archive.zip"))
        return ProcessResult(exitCode: 0)
    }

    private func chainFolder(_ source: Source, _ name: String) -> String {
        "chains/\(source.id.uuidString)/\(name)"
    }

    @Test func manualStepWaitsForItsFileAndKeepsItOutOfTheCopy() async throws {
        defer { temp.remove() }
        let source = source([manual("manifest-*.json"), command()])
        let runner = runner()

        #expect(await runner.advance(source, chain: nil, lastPickup: nil, permissions: tickOnly) == .stay)

        try temp.file("Downloads/manifest-a.json", "{}", modified: start.addingTimeInterval(-60))
        let moved = await runner.advance(source, chain: nil, lastPickup: nil, permissions: tickOnly)
        #expect(moved == .moved(ChainState(stepIndex: 1, startedAt: start, stepEnteredAt: start)))
        #expect(temp.names(in: "Downloads").isEmpty)
        #expect(temp.names(in: chainFolder(source, "input")) == ["manifest-a.json"])
        #expect(temp.names(in: chainFolder(source, "output")).isEmpty)
    }

    @Test func manualStepFileCanBePartOfTheCopy() async throws {
        defer { temp.remove() }
        let source = source([manual("export-*.csv", includeInCopy: true)])
        try temp.file("Downloads/export-1.csv", "a;b", modified: start.addingTimeInterval(-60))
        let runner = runner()

        guard case let .moved(chain) = await runner.advance(source, chain: nil, lastPickup: nil, permissions: tickOnly) else {
            Issue.record("шаг не принят")
            return
        }
        #expect(temp.names(in: chainFolder(source, "output")) == ["export-1.csv"])

        guard case let .completed(package) = await runner.advance(source, chain: chain, lastPickup: nil, permissions: tickOnly) else {
            Issue.record("цепочка не завершилась")
            return
        }
        #expect(inbox.pendingPackage(for: source.id) == package)
        #expect(temp.names(in: "pending/\(source.id.uuidString)/2026-09-28_100000") == ["export-1.csv"])
        #expect(!temp.exists("chains/\(source.id.uuidString)"))
    }

    @Test func fileOlderThanTheLastPickupIsIgnored() async throws {
        defer { temp.remove() }
        let source = source([manual("manifest-*.json"), command()])
        try temp.file("Downloads/manifest-a.json", "{}", modified: start.addingTimeInterval(-3600))
        let transition = await runner().advance(source, chain: nil, lastPickup: start.addingTimeInterval(-60), permissions: tickOnly)
        #expect(transition == .stay)
        #expect(temp.names(in: "Downloads") == ["manifest-a.json"])
    }

    @Test func commandSeesEarlierFilesAndItsOutputBecomesThePackage() async throws {
        defer { temp.remove() }
        let source = source([manual("manifest-*.json"), command()])
        try temp.file("Downloads/manifest-a.json", "{}", modified: start.addingTimeInterval(-60))
        let seen = LockedBox<[String]>([])
        let runner = runner { [self] call in
            let input = URL(fileURLWithPath: call.environment["BACKUP_INPUT_DIR"]!)
            seen.set(try FileManager.default.contentsOfDirectory(atPath: input.path))
            #expect(FileManager.default.fileExists(atPath: call.environment["BACKUP_SCRATCH_DIR"]!))
            return try writeArchive(call)
        }

        guard case let .moved(afterFile) = await runner.advance(source, chain: nil, lastPickup: nil, permissions: tickOnly) else {
            Issue.record("файл не принят")
            return
        }
        time.advance(10)
        let afterCommand = await runner.advance(source, chain: afterFile, lastPickup: nil, permissions: tickOnly)
        #expect(afterCommand == .moved(ChainState(stepIndex: 2, startedAt: start, stepEnteredAt: start.addingTimeInterval(10))))
        #expect(seen.get() == ["manifest-a.json"])
        #expect(events.get() == [
            .collecting(sourceId: source.id),
            .step(sourceId: source.id, index: 1, count: 2),
            .status(sourceId: source.id, text: "скачано 1 из 2"),
        ])

        guard case .moved(let done) = afterCommand,
              case let .completed(package) = await runner.advance(source, chain: done, lastPickup: nil, permissions: tickOnly) else {
            Issue.record("цепочка не завершилась")
            return
        }
        #expect(package.collectedAt == start.addingTimeInterval(10))
        #expect(temp.names(in: "pending/\(source.id.uuidString)/2026-09-28_100010") == ["archive.zip"])
        #expect(temp.names(in: "trash") == ["manifest-a.json"])
        #expect(!temp.exists("chains/\(source.id.uuidString)"))
    }

    @Test func failedCommandStaysPutUntilRetryIsAllowed() async throws {
        defer { temp.remove() }
        let source = source([manual("manifest-*.json"), command()])
        try temp.file("Downloads/manifest-a.json", "{}", modified: start.addingTimeInterval(-60))
        let shouldFail = LockedBox(true)
        let runner = runner { [self] call in
            shouldFail.get() ? ProcessResult(exitCode: 1, stderr: "Не скачались архивы: a.zip") : try writeArchive(call)
        }

        guard case let .moved(afterFile) = await runner.advance(source, chain: nil, lastPickup: nil, permissions: tickOnly),
              case let .failed(failed) = await runner.advance(source, chain: afterFile, lastPickup: nil, permissions: tickOnly) else {
            Issue.record("ожидалась ошибка шага")
            return
        }
        #expect(failed.stepIndex == 1)
        #expect(failed.failure == "Команда завершилась с кодом 1. Не скачались архивы: a.zip")
        #expect(temp.names(in: chainFolder(source, "input")) == ["manifest-a.json"])

        time.advance(7200)
        #expect(await runner.advance(source, chain: failed, lastPickup: nil, permissions: tickOnly) == .stay)

        shouldFail.set(false)
        let retried = await runner.advance(source, chain: failed, lastPickup: nil, permissions: allowAll)
        #expect(retried == .moved(ChainState(stepIndex: 2, startedAt: start, stepEnteredAt: start.addingTimeInterval(7200))))
    }

    @Test func freshFirstStepFileRestartsAStuckChain() async throws {
        defer { temp.remove() }
        let source = source([manual("manifest-*.json"), command()])
        let failed = ChainState(stepIndex: 1, startedAt: start, stepEnteredAt: start, failure: "ссылки сгорели")
        try temp.file("chains/\(source.id.uuidString)/input/manifest-a.json", "{}")
        try temp.file("chains/\(source.id.uuidString)/output/partial.zip", "zip")
        let runner = runner()

        time.advance(600)
        try temp.file("Downloads/manifest-b.json", "{}", modified: start.addingTimeInterval(300))
        #expect(await runner.advance(source, chain: failed, lastPickup: nil, permissions: tickOnly) == .moved(nil))
        #expect(temp.names(in: "trash") == ["manifest-a.json", "partial.zip"])
        #expect(!temp.exists("chains/\(source.id.uuidString)"))

        let restarted = await runner.advance(source, chain: nil, lastPickup: nil, permissions: tickOnly)
        #expect(restarted == .moved(ChainState(stepIndex: 1, startedAt: start.addingTimeInterval(600), stepEnteredAt: start.addingTimeInterval(600))))
        #expect(temp.names(in: chainFolder(source, "input")) == ["manifest-b.json"])
    }

    @Test func chainThatOpensWithACommandStartsOnlyWhenAllowed() async throws {
        defer { temp.remove() }
        let source = source([command("Открыть страницу"), manual("export-*.csv", includeInCopy: true)])
        let runner = runner()

        #expect(await runner.advance(source, chain: nil, lastPickup: nil, permissions: tickOnly) == .stay)
        let started = await runner.advance(source, chain: nil, lastPickup: nil, permissions: ChainPermissions(mayStart: true, mayRetry: false))
        #expect(started == .moved(ChainState(stepIndex: 1, startedAt: start, stepEnteredAt: start)))
    }

    @Test func laterManualStepTakesOnlyFilesThatAppearedAfterThePreviousStep() async throws {
        defer { temp.remove() }
        let source = source([command("Открыть страницу"), manual("export-*.csv", includeInCopy: true)])
        let waiting = ChainState(stepIndex: 1, startedAt: start, stepEnteredAt: start)
        let runner = runner()

        time.advance(600)
        try temp.file("Downloads/export-old.csv", "old", modified: start.addingTimeInterval(-60))
        #expect(await runner.advance(source, chain: waiting, lastPickup: nil, permissions: tickOnly) == .stay)

        try temp.file("Downloads/export-new.csv", "new", modified: start.addingTimeInterval(300))
        let moved = await runner.advance(source, chain: waiting, lastPickup: nil, permissions: tickOnly)
        #expect(moved == .moved(ChainState(stepIndex: 2, startedAt: start, stepEnteredAt: start.addingTimeInterval(600))))
        #expect(temp.names(in: "Downloads") == ["export-old.csv"])
        #expect(temp.names(in: chainFolder(source, "output")) == ["export-new.csv"])
    }

    @Test func chainThatProducedNothingFails() async throws {
        defer { temp.remove() }
        let source = source([command()])
        let runner = runner()
        guard case let .moved(done) = await runner.advance(source, chain: nil, lastPickup: nil, permissions: allowAll),
              case let .failed(failed) = await runner.advance(source, chain: done, lastPickup: nil, permissions: tickOnly) else {
            Issue.record("ожидалась ошибка пустого результата")
            return
        }
        #expect(failed.stepIndex == 1)
        #expect(failed.failure == SourceError.emptyResult.localizedDescription)
        #expect(inbox.pendingPackage(for: source.id) == nil)
        #expect(await runner.advance(source, chain: failed, lastPickup: nil, permissions: tickOnly) == .stay)
    }

    @Test func chainIsResetWhenStepsWereRemoved() async throws {
        defer { temp.remove() }
        let source = source([command()])
        let stale = ChainState(stepIndex: 3, startedAt: start, stepEnteredAt: start)
        try temp.file("chains/\(source.id.uuidString)/input/manifest-a.json", "{}")
        #expect(await runner().advance(source, chain: stale, lastPickup: nil, permissions: tickOnly) == .moved(nil))
        #expect(temp.names(in: "trash") == ["manifest-a.json"])
    }

    @Test func sourceWithoutStepsDoesNothing() async throws {
        defer { temp.remove() }
        #expect(await runner().advance(source([]), chain: nil, lastPickup: nil, permissions: allowAll) == .stay)
    }
}
```

В `App/Tests/BackupEverythingTests/ActivityTrackerTests.swift` добавить:

```swift
    @Test func trackerRemembersWhichStepIsRunning() {
        let id = UUID()
        var tracker = ActivityTracker()
        tracker.apply(.collecting(sourceId: id))
        #expect(tracker.step(of: id) == nil)
        tracker.apply(.step(sourceId: id, index: 1, count: 2))
        #expect(tracker.step(of: id)?.index == 1)
        #expect(tracker.step(of: id)?.count == 2)
        tracker.apply(.finished(sourceId: id))
        #expect(tracker.step(of: id) == nil)
    }
```

- [ ] **Step 2: Убедиться, что тесты не собираются**

Run: `swift test --package-path BackupCore --filter StepChainRunnerTests 2>&1 | tail -10`
Expected: `cannot find 'StepChainRunner' in scope`.

- [ ] **Step 3: Реализовать**

`Engine/RunProgress.swift` — добавить случай после `.status`:

```swift
    case step(sourceId: UUID, index: Int, count: Int)
```

Создать `Engine/StepChainRunner.swift`:

```swift
import Foundation

public enum ChainTransition: Sendable, Equatable {
    case stay
    case moved(ChainState?)
    case failed(ChainState)
    case completed(PendingPackage)
}

public struct ChainPermissions: Sendable, Equatable {
    public var mayStart: Bool
    public var mayRetry: Bool

    public init(mayStart: Bool, mayRetry: Bool) {
        self.mayStart = mayStart
        self.mayRetry = mayRetry
    }
}

public struct StepChainRunner: Sendable {
    private struct Folders {
        let root: URL
        var input: URL { root.appendingPathComponent("input", isDirectory: true) }
        var output: URL { root.appendingPathComponent("output", isDirectory: true) }
        var scratch: URL { root.appendingPathComponent("scratch", isDirectory: true) }
        var all: [URL] { [input, output, scratch] }
    }

    private let chainsRoot: URL
    private let inbox: ManualExportInbox
    private let shell: ShellCommand
    private let time: any TimeSource
    private let trash: ManualExportInbox.Trash
    private let progress: ProgressHandler

    public init(
        chainsRoot: URL,
        inbox: ManualExportInbox,
        runner: any ProcessRunner,
        time: any TimeSource,
        trash: @escaping ManualExportInbox.Trash = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) },
        progress: @escaping ProgressHandler = { _ in }
    ) {
        self.chainsRoot = chainsRoot
        self.inbox = inbox
        self.shell = ShellCommand(runner: runner)
        self.time = time
        self.trash = trash
        self.progress = progress
    }

    public func advance(_ source: Source, chain: ChainState?, lastPickup: Date?, permissions: ChainPermissions) async -> ChainTransition {
        let steps = source.steps
        guard !steps.isEmpty else { return .stay }
        let now = time.now
        if let chain, chain.stepIndex > steps.count || hasFreshStart(steps[0], chain: chain, now: now) {
            try? discard(sourceId: source.id)
            return .moved(nil)
        }
        if chain?.failure != nil, !permissions.mayRetry { return .stay }
        guard chain != nil || steps[0].isManual || permissions.mayStart else { return .stay }

        var next = chain ?? ChainState(stepIndex: 0, startedAt: now, stepEnteredAt: now)
        next.failure = nil
        let folders = folders(source.id)
        do {
            if chain == nil { try discard(sourceId: source.id) }
            guard next.stepIndex < steps.count else {
                return .completed(try assemble(source.id, folders: folders, at: now))
            }
            switch steps[next.stepIndex].kind {
            case let .manual(_, watchPath, filePattern, includeInCopy):
                let since = next.stepIndex == 0 ? (lastPickup ?? source.createdAt) : next.stepEnteredAt
                let scan = inbox.scan(watchPath: watchPath, filePattern: filePattern, since: since, now: now)
                guard scan.isReady else { return .stay }
                try prepare(folders)
                try take(scan.files, into: includeInCopy ? folders.output : folders.input)
            case let .command(command, timeoutSeconds):
                try prepare(folders)
                progress(.collecting(sourceId: source.id))
                progress(.step(sourceId: source.id, index: next.stepIndex, count: steps.count))
                _ = try await shell.run(
                    command,
                    timeoutSeconds: timeoutSeconds,
                    environment: [
                        "BACKUP_INPUT_DIR": folders.input.path,
                        "BACKUP_OUTPUT_DIR": folders.output.path,
                        "BACKUP_SCRATCH_DIR": folders.scratch.path,
                    ],
                    status: { [progress] text in progress(.status(sourceId: source.id, text: text)) }
                )
            }
        } catch {
            next.failure = error.localizedDescription
            return .failed(next)
        }
        next.stepIndex += 1
        next.stepEnteredAt = time.now
        return .moved(next)
    }

    public func discard(sourceId: UUID) throws {
        let fileManager = FileManager.default
        let folders = folders(sourceId)
        for directory in [folders.input, folders.output] {
            for item in (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
                try trash(item)
            }
        }
        if fileManager.fileExists(atPath: folders.root.path) {
            try fileManager.removeItem(at: folders.root)
        }
    }

    private func hasFreshStart(_ first: SourceStep, chain: ChainState, now: Date) -> Bool {
        guard chain.stepIndex > 0, case let .manual(_, watchPath, filePattern, _) = first.kind else { return false }
        return inbox.scan(watchPath: watchPath, filePattern: filePattern, since: chain.startedAt, now: now).isReady
    }

    private func assemble(_ sourceId: UUID, folders: Folders, at date: Date) throws -> PendingPackage {
        let produced = (try? FileManager.default.contentsOfDirectory(atPath: folders.output.path)) ?? []
        guard !produced.isEmpty else { throw SourceError.emptyResult }
        let package = try inbox.adopt(sourceId: sourceId, directory: folders.output, at: date)
        try? discard(sourceId: sourceId)
        return package
    }

    private func prepare(_ folders: Folders) throws {
        for directory in folders.all {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    private func take(_ files: [URL], into directory: URL) throws {
        let fileManager = FileManager.default
        var moved: [(original: URL, taken: URL)] = []
        do {
            for file in files {
                let taken = directory.appendingPathComponent(file.lastPathComponent)
                try fileManager.moveItem(at: file, to: taken)
                moved.append((file, taken))
            }
        } catch {
            for item in moved.reversed() {
                try? fileManager.moveItem(at: item.taken, to: item.original)
            }
            throw error
        }
    }

    private func folders(_ sourceId: UUID) -> Folders {
        Folders(root: chainsRoot.appendingPathComponent(sourceId.uuidString, isDirectory: true))
    }
}
```

Пояснение к порядку проверок: упавшая сборка результата оставляет `stepIndex == steps.count` с `failure`; условие сброса — строго `stepIndex > steps.count`, поэтому такая цепочка не сбрасывается, а ждёт повтора.

`App/Sources/BackupEverything/Model/ActivityTracker.swift`:
- добавить поле `private var steps: [UUID: (index: Int, count: Int)] = [:]`;
- добавить метод:

```swift
    func step(of sourceId: UUID) -> (index: Int, count: Int)? {
        steps[sourceId]
    }
```

- в `apply` добавить ветку:

```swift
        case let .step(sourceId, index, count):
            steps[sourceId] = (index, count)
```

- в ветке `.finished` добавить `steps[sourceId] = nil`, в `reset()` — `steps = [:]`.

- [ ] **Step 4: Прогнать тесты**

Run: `swift test --package-path BackupCore 2>&1 | tail -5`
Expected: PASS.
Run: `swift test --package-path App 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 5: Коммит**

```bash
git add BackupCore App
git commit -m "Add the runner that moves a step chain one transition at a time

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Координатор — цикл цепочки, повтор, сброс, догон

**Files:**
- Modify: `BackupCore/Sources/BackupCore/Application/BackupCoordinator.swift`
- Modify: `BackupCore/Sources/BackupCore/Application/CoreAssembly.swift`
- Test: `BackupCore/Tests/BackupCoreTests/BackupCoordinatorTests.swift`

**Interfaces:**
- Consumes: `StepChainRunner.advance`, `.discard`, `ChainTransition`, `ChainPermissions` (задача 4).
- Produces:
  - `BackupCoordinator.init(store:engine:inbox:chains:stores:time:calendar:progress:)` — новый параметр `chains: StepChainRunner` после `inbox`
  - `func restartChain(sourceId: UUID) async throws -> TickResult`
  - `CoreAssembly.chainsDirectory(in workDirectory: URL) -> URL`
  - Запись в истории об упавшем шаге: `RunRecord` с `trigger: .pickup` и `collectError == "Шаг N из M «имя». <причина>"`. В `SourceState.lastError` она не попадает — ошибка цепочки хранится в `chain.failure`.

Поведение по режимам:

| Вызов | Стартует цепочку с командой первым шагом | Повторяет упавший шаг |
|---|---|---|
| `tick()` | только когда подошёл срок | нет |
| `runAllNow()` | да | нет |
| `runNow(sourceId:)` | да | да |

- [ ] **Step 1: Обновить сборку координатора в тестах и написать падающие тесты**

В `BackupCoordinatorTests.init` после создания `inbox` собрать раннер и передать его координатору:

```swift
        let chains = StepChainRunner(
            chainsRoot: temp.path("work/chains"),
            inbox: inbox,
            runner: runner,
            time: time,
            trash: { url in try FileManager.default.moveItem(at: url, to: temp.path("trash/\(url.lastPathComponent)")) },
            progress: { [events] event in events.set(events.get() + [event]) }
        )
```

(объявление `let runner = SystemProcessRunner()` поднять выше этого блока) и в вызове `BackupCoordinator(` добавить `chains: chains,` после `inbox: inbox,`.

Добавить помощник и тесты:

```swift
    private func claude(_ destinations: [Destination], command: String = #"cp "$BACKUP_INPUT_DIR"/manifest-a.json "$BACKUP_OUTPUT_DIR/archive.zip""#) -> Source {
        Fixtures.source(
            name: "Claude",
            kind: .steps(steps: [
                SourceStep(name: "Запросить экспорт", kind: .manual(instructions: "", watchPath: temp.path("Downloads").path, filePattern: "manifest-*.json", includeInCopy: false)),
                SourceStep(name: "Скачать архивы", kind: .command(command: command, timeoutSeconds: 60)),
            ]),
            schedule: .monthly,
            destinations: destinations,
            createdAt: created
        )
    }

    @Test func stepChainDeliversWhatItsCommandProduced() async throws {
        defer { temp.remove() }
        let source = claude([cloud])
        try store.saveConfig(Config(sources: [source], destinations: [cloud]))

        #expect(try await coordinator.tick().runs.isEmpty)

        try temp.file("Downloads/manifest-a.json", "{}", modified: start.addingTimeInterval(-60))
        let result = try await coordinator.tick()

        #expect(result.runs.map(\.trigger) == [.pickup])
        #expect(result.runs.first?.firstFailure == nil)
        #expect(temp.names(in: "cloud/claude/2026-09-28_100000") == ["_snapshot.json", "archive.zip"])
        #expect(temp.names(in: "Downloads").isEmpty)
        #expect(temp.names(in: "trash").sorted() == ["archive.zip", "manifest-a.json"])
        let state = try store.loadState().sourceState(source.id)
        #expect(state.chain == nil)
        #expect(state.lastPickup == start)
        #expect(state.lastRun == start)
        #expect(try await coordinator.statusReport().overall == .ok)
        #expect(events.get().contains(.step(sourceId: source.id, index: 1, count: 2)))
        #expect(events.get().last == .finished(sourceId: source.id))
    }

    @Test func failedStepIsRecordedOnceAndWaitsForTheUser() async throws {
        defer { temp.remove() }
        let source = claude([cloud], command: "echo 'Не скачались архивы: a.zip' >&2; exit 1")
        try store.saveConfig(Config(sources: [source], destinations: [cloud]))
        try temp.file("Downloads/manifest-a.json", "{}", modified: start.addingTimeInterval(-60))

        let failed = try await coordinator.tick()
        let message = try #require(failed.runs.first?.collectError)
        #expect(failed.runs.count == 1)
        #expect(message.hasPrefix("Шаг 2 из 2 «Скачать архивы». Команда завершилась с кодом 1."))
        #expect(message.hasSuffix("Не скачались архивы: a.zip"))
        #expect(failed.notices.contains(.runFailed(sourceId: source.id, sourceName: "Claude", message: message)))
        #expect(store.loadRuns().count == 1)
        let stuck = try store.loadState().sourceState(source.id)
        #expect(stuck.chain?.stepIndex == 1)
        #expect(stuck.chain?.failure?.hasPrefix("Команда завершилась с кодом 1.") == true)
        #expect(stuck.lastError == nil)
        #expect(stuck.retryAfter == nil)
        #expect(events.get().last == .finished(sourceId: source.id))

        time.advance(2 * 3600)
        #expect(try await coordinator.tick().runs.isEmpty)
        #expect(try await coordinator.runAllNow().runs.isEmpty)
        #expect(store.loadRuns().count == 1)

        #expect(try await coordinator.runNow(sourceId: source.id).runs.count == 1)
        #expect(store.loadRuns().count == 2)

        _ = try await coordinator.restartChain(sourceId: source.id)
        #expect(try store.loadState().sourceState(source.id).chain == nil)
        #expect(temp.names(in: "trash") == ["manifest-a.json"])
        #expect(!temp.exists("work/chains/\(source.id.uuidString)"))
    }

    @Test func chainPositionIsSavedBeforeTheCommandRuns() async throws {
        defer { temp.remove() }
        let stateFile = store.stateURL.path
        let source = claude([cloud], command: #"grep -q '"stepIndex" : 1' '\#(stateFile)' && echo saved > "$BACKUP_OUTPUT_DIR/ok.txt""#)
        try store.saveConfig(Config(sources: [source], destinations: [cloud]))
        try temp.file("Downloads/manifest-a.json", "{}", modified: start.addingTimeInterval(-60))

        let result = try await coordinator.tick()
        #expect(result.runs.first?.firstFailure == nil)
        #expect(temp.exists("cloud/claude/2026-09-28_100000/ok.txt"))
    }

    @Test func chainWithoutDestinationsLeavesTheFileAlone() async throws {
        defer { temp.remove() }
        let source = claude([])
        try store.saveConfig(Config(sources: [source], destinations: [cloud]))
        try temp.file("Downloads/manifest-a.json", "{}", modified: start.addingTimeInterval(-60))

        #expect(try await coordinator.tick().runs.isEmpty)
        #expect(temp.names(in: "Downloads") == ["manifest-a.json"])
        #expect(try store.loadState().sourceState(source.id).chain == nil)
    }

    @Test func finishedChainCatchesUpAnUnpluggedDiskFromPending() async throws {
        defer { temp.remove() }
        let source = claude([cloud, disk])
        try store.saveConfig(Config(sources: [source], destinations: [cloud, disk]))
        try temp.file("Downloads/manifest-a.json", "{}", modified: start.addingTimeInterval(-60))

        _ = try await coordinator.tick()
        #expect(temp.names(in: "cloud/claude") == ["2026-09-28_100000"])
        #expect(try store.loadState().debts.map(\.destinationId) == [disk.id])
        #expect(temp.names(in: "work/pending/\(source.id.uuidString)") == ["2026-09-28_100000"])

        time.advance(86_400)
        try temp.directory("hdd")
        let caughtUp = try await coordinator.tick()
        #expect(caughtUp.runs.map(\.trigger) == [.catchUp])
        #expect(temp.names(in: "hdd/claude") == ["2026-09-28_100000"])
        #expect(try store.loadState().debts.isEmpty)
        #expect(!temp.exists("work/pending/\(source.id.uuidString)"))
    }

    @Test func chainThatOpensWithACommandStartsOnSchedule() async throws {
        defer { temp.remove() }
        let source = Fixtures.source(
            name: "Отчёт",
            kind: .steps(steps: [SourceStep(name: "Собрать", kind: .command(command: #"echo data > "$BACKUP_OUTPUT_DIR/report.txt""#, timeoutSeconds: 60))]),
            schedule: .daily,
            destinations: [cloud],
            createdAt: created
        )
        try store.saveConfig(Config(sources: [source], destinations: [cloud]))

        #expect(try await coordinator.tick().runs.map(\.trigger) == [.pickup])
        #expect(temp.names(in: "cloud/отчёт") == ["2026-09-28_100000"])

        time.advance(3600)
        #expect(try await coordinator.tick().runs.isEmpty)
        time.advance(23 * 3600)
        #expect(try await coordinator.tick().runs.count == 1)
    }
```

- [ ] **Step 2: Убедиться, что тесты не собираются**

Run: `swift test --package-path BackupCore --filter BackupCoordinatorTests 2>&1 | tail -10`
Expected: `extra argument 'chains' in call`.

- [ ] **Step 3: Реализовать**

`Application/CoreAssembly.swift`:

```swift
    public static func chainsDirectory(in workDirectory: URL) -> URL {
        workDirectory.appendingPathComponent("chains", isDirectory: true)
    }
```

и в `makeCoordinator` после создания `inbox`:

```swift
        let chains = StepChainRunner(
            chainsRoot: chainsDirectory(in: workDirectory),
            inbox: inbox,
            runner: runner,
            time: time,
            progress: progress
        )
```

передать `chains: chains,` в `BackupCoordinator(` после `inbox: inbox,`.

`Application/BackupCoordinator.swift`:

1. Добавить свойство `private let chains: StepChainRunner`, параметр `chains: StepChainRunner` в `init` после `inbox` и присваивание.

2. Добавить режим и публичный метод:

```swift
    private enum ChainMode {
        case tick
        case runAll
        case runNow
    }

    public func restartChain(sourceId: UUID) async throws -> TickResult {
        try await enqueue { try await self.performRestartChain(sourceId: sourceId) }
    }
```

3. В `performTick` после цикла подхвата `single`-экспортов и перед `for source in due` добавить:

```swift
        for source in config.sources where source.enabled && source.isStepChain {
            try await advanceChain(source, config: config, mode: .tick, state: &state, runs: &runs)
        }
```

4. `performRunNow` — заменить развилку на:

```swift
        if source.isStepChain {
            try await advanceChain(source, config: config, mode: .runNow, state: &state, runs: &runs)
        } else if source.isManualExport {
            try await pickUp(source, config: config, respectRetryDelay: false, state: &state, runs: &runs)
        } else {
            try await execute(source, destinations, .manual, state: &state, runs: &runs)
        }
```

5. `performRunAllNow` — после цикла по обычным источникам добавить:

```swift
        for source in config.sources where source.enabled && source.isStepChain {
            try await advanceChain(source, config: config, mode: .runAll, state: &state, runs: &runs)
        }
```

6. Добавить приватные методы:

```swift
    private func performRestartChain(sourceId: UUID) async throws -> TickResult {
        var state = try store.loadState()
        try chains.discard(sourceId: sourceId)
        state.updateSource(sourceId) { $0.chain = nil }
        try store.saveState(state)
        return TickResult()
    }

    private func advanceChain(
        _ source: Source,
        config: Config,
        mode: ChainMode,
        state: inout AppState,
        runs: inout [RunRecord]
    ) async throws {
        let destinations = config.destinations(of: source)
        guard !destinations.isEmpty else { return }
        var didWork = false
        while true {
            let sourceState = state.sourceState(source.id)
            let startedAt = time.now
            let permissions = ChainPermissions(
                mayStart: mode != .tick || planner.isDue(source, state: sourceState, now: startedAt),
                mayRetry: mode == .runNow && !didWork
            )
            let transition = await chains.advance(source, chain: sourceState.chain, lastPickup: sourceState.lastPickup, permissions: permissions)
            switch transition {
            case .stay:
                if didWork { progress(.finished(sourceId: source.id)) }
                return
            case let .moved(chain):
                didWork = true
                state.updateSource(source.id) { $0.chain = chain }
                try store.saveState(state)
            case let .failed(chain):
                state.updateSource(source.id) { $0.chain = chain }
                try store.saveState(state)
                let failure = RunRecord(
                    sourceId: source.id,
                    sourceName: source.name,
                    trigger: .pickup,
                    startedAt: startedAt,
                    finishedAt: time.now,
                    collectError: Self.stepFailure(chain, in: source)
                )
                try store.appendRun(failure)
                runs.append(failure)
                progress(.finished(sourceId: source.id))
                return
            case .completed:
                state.updateSource(source.id) {
                    $0.chain = nil
                    $0.lastPickup = startedAt
                }
                try store.saveState(state)
                try await execute(source, destinations, .pickup, state: &state, runs: &runs)
                return
            }
        }
    }

    private static func stepFailure(_ chain: ChainState, in source: Source) -> String {
        let steps = source.steps
        let index = min(chain.stepIndex, steps.count - 1)
        return "Шаг \(index + 1) из \(steps.count) «\(steps[index].name)». \(chain.failure ?? "")"
    }
```

`mayRetry` выдаётся только на первый переход вызова: повторённый и снова упавший шаг не должен крутиться в цикле.

- [ ] **Step 4: Прогнать тесты**

Run: `swift test --package-path BackupCore 2>&1 | tail -5`
Expected: PASS.
Run: `swift test --package-path App 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 5: Коммит**

```bash
git add BackupCore
git commit -m "Drive step chains from the coordinator: advance, retry, restart, catch up

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Статус — ожидание шага и ошибка цепочки

**Files:**
- Modify: `BackupCore/Sources/BackupCore/Status/StatusReporter.swift`
- Modify: `App/Sources/BackupEverything/Presentation/SourceStatus.swift`
- Modify: `App/Sources/BackupEverything/Presentation/LiveReport.swift`
- Test: `BackupCore/Tests/BackupCoreTests/StatusReporterTests.swift`, `App/Tests/BackupEverythingTests/OverviewTextsTests.swift`

**Interfaces:**
- Produces:
  - `AttentionItem.stepAwaitingFile(sourceId: UUID)` — жёлтый статус: цепочка ждёт ручного шага в середине
  - для цепочки `.runFailed(sourceId:message:)` несёт `chain.failure` (без префикса «Шаг N из M»), `.manualExportDue` — когда цепочка не начата, первый шаг ручной и подошёл срок
  - `SourceStatus.awaitingFile` с `note == "ждёт файл"`, `text == "Ждёт файл для следующего шага"`, серьёзность `.attention`

- [ ] **Step 1: Написать падающие тесты**

В `StatusReporterTests.swift` добавить:

```swift
    @Test func stepChainReportsWhereItIsStuck() {
        let now = Fixtures.date("2026-09-28 10:00:00")
        let cloud = Fixtures.localDestination("Cloud", at: URL(fileURLWithPath: "/tmp/cloud"))
        let steps = [
            SourceStep(name: "Открыть страницу", kind: .command(command: "true", timeoutSeconds: 60)),
            SourceStep(name: "Файл", kind: .manual(instructions: "", watchPath: "~/Downloads", filePattern: "x-*.csv", includeInCopy: true)),
        ]
        let chain = Fixtures.source(name: "Chain", kind: .steps(steps: steps), schedule: .manual, destinations: [cloud])
        let manualFirst = Fixtures.source(
            name: "Claude",
            kind: .steps(steps: [steps[1], steps[0]]),
            schedule: .monthly,
            destinations: [cloud],
            createdAt: Fixtures.date("2026-09-01 00:00:00")
        )
        let config = Config(sources: [chain, manualFirst], destinations: [cloud])
        let reporter = StatusReporter(planner: SchedulePlanner(calendar: Fixtures.calendar))
        func items(_ state: AppState) -> [AttentionItem] {
            reporter.report(config: config, state: state, now: now, unavailableDestinations: [], inboxScans: [:]).items
        }

        var state = AppState()
        #expect(items(state) == [.manualExportDue(sourceId: manualFirst.id)])

        state.updateSource(chain.id) { $0.chain = ChainState(stepIndex: 1, startedAt: now, stepEnteredAt: now) }
        state.updateSource(manualFirst.id) { $0.chain = ChainState(stepIndex: 1, startedAt: now, stepEnteredAt: now, failure: "Команда завершилась с кодом 1. нет архивов") }
        #expect(items(state) == [
            .stepAwaitingFile(sourceId: chain.id),
            .runFailed(sourceId: manualFirst.id, message: "Команда завершилась с кодом 1. нет архивов"),
        ])
    }
```

В `BackupCoordinatorTests.swift` добавить (помощник `claude(_:command:)` появился в задаче 5):

```swift
    @Test func idleChainRemindsAboutItsFirstManualStep() async throws {
        defer { temp.remove() }
        let source = claude([cloud])
        try store.saveConfig(Config(sources: [source], destinations: [cloud]))

        let idle = try await coordinator.tick()
        #expect(idle.runs.isEmpty)
        #expect(idle.notices == [.manualExportDue(sourceId: source.id, sourceName: "Claude")])
        #expect(try await coordinator.statusReport().items == [.manualExportDue(sourceId: source.id)])

        time.advance(3600)
        #expect(try await coordinator.tick().notices.isEmpty)
    }
```

В `OverviewTextsTests.swift` в `rowNoteIsEmptyWhenNothingNeedsSaying` добавить строку:

```swift
        #expect(SourceStatus.awaitingFile.note == "ждёт файл")
```

и тест:

```swift
    @Test func chainWaitingForAFileNeedsAttention() {
        let cloud = Destination(name: "Cloud", kind: .localFolder(path: "/tmp/cloud"))
        let source = Source(
            name: "Chain",
            slug: "chain",
            kind: .steps(steps: []),
            schedule: .manual,
            destinationIds: [cloud.id],
            createdAt: now
        )
        let report = StatusReport(items: [.stepAwaitingFile(sourceId: source.id)])
        let status = SourceStatus.of(source, report: report, lastRun: now)
        #expect(status == .awaitingFile)
        #expect(status.severity == .attention)
        #expect(LiveReport.of(report, running: [source.id]).items.isEmpty)
    }
```

- [ ] **Step 2: Убедиться, что тесты не собираются**

Run: `swift test --package-path BackupCore --filter stepChainReportsWhereItIsStuck 2>&1 | tail -10`
Expected: `type 'AttentionItem' has no member 'stepAwaitingFile'`.

- [ ] **Step 3: Реализовать**

`Status/StatusReporter.swift`:
- в `AttentionItem` добавить `case stepAwaitingFile(sourceId: UUID)` (серьёзность по умолчанию — `.attention`);
- в `report` заменить блок от `if let message = sourceState.lastError {` до конца тела цикла по источникам на:

```swift
            if let message = sourceState.chain?.failure ?? sourceState.lastError {
                items.append(.runFailed(sourceId: source.id, message: message))
            }
            if planner.isSeverelyOverdue(source, state: sourceState, now: now) {
                items.append(.severelyOverdue(sourceId: source.id))
            }
            if source.isStepChain {
                items.append(contentsOf: chainItems(source, state: sourceState, now: now))
                continue
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
```

- добавить метод:

```swift
    private func chainItems(_ source: Source, state: SourceState, now: Date) -> [AttentionItem] {
        let steps = source.steps
        guard let chain = state.chain else {
            let waitsForHuman = steps.first?.isManual == true && planner.isDue(source, state: state, now: now)
            return waitsForHuman ? [.manualExportDue(sourceId: source.id)] : []
        }
        guard chain.failure == nil, chain.stepIndex < steps.count, steps[chain.stepIndex].isManual else { return [] }
        return [.stepAwaitingFile(sourceId: source.id)]
    }
```

`Presentation/LiveReport.swift`: добавить `let .stepAwaitingFile(sourceId)` в первую ветку `switch` (ту, что возвращает `sourceId`).

`Presentation/SourceStatus.swift`:
- добавить `case awaitingFile` после `filesFound`;
- в `of` добавить `case let .stepAwaitingFile(id) where id == source.id: found.append(.awaitingFile)`;
- `severity`: добавить `.awaitingFile` к списку `.attention`;
- `text`: `case .awaitingFile: "Ждёт файл для следующего шага"`;
- `note`: `case .awaitingFile: "ждёт файл"`;
- `rank`: `.awaitingFile: 4`, `.exportDue: 5`, остальные (`.disabled, .neverRun, .ok`) — `6`.

- [ ] **Step 4: Прогнать тесты**

Run: `swift test --package-path BackupCore 2>&1 | tail -5`
Expected: PASS.
Run: `swift test --package-path App 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 5: Коммит**

```bash
git add BackupCore App
git commit -m "Report step chains that wait for a file or failed on a step

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: Шаблон Claude на шагах

**Files:**
- Modify: `BackupCore/Sources/BackupCore/Storage/BundledTemplates.swift`
- Modify: `docs/superpowers/specs/2026-09-30-backup-manager-design.md`
- Test: `BackupCore/Tests/BackupCoreTests/ClaudeTemplateTests.swift` (новый)

**Interfaces:**
- Consumes: `ShellCommand` (задача 2), `SourceStep` (задача 1).
- Produces: шаблон `claude` типа `.steps` из двух шагов. Команда второго шага понимает три необязательные переменные, которые нужны только тестам: `BACKUP_DOWNLOADS_DIR` (по умолчанию `~/Downloads`), `BACKUP_OPEN_COMMAND` (по умолчанию `open -g`), `BACKUP_WAIT_SECONDS` (по умолчанию `3300`).

Команда проверена вручную на четырёх сценариях (всё скачалось; один архив уже скачан; старый одноимённый файл; ничего не пришло).

- [ ] **Step 1: Написать падающие тесты**

Создать `BackupCore/Tests/BackupCoreTests/ClaudeTemplateTests.swift`:

```swift
import Foundation
import Testing
@testable import BackupCore

struct ClaudeTemplateTests {
    private let temp: TempDirectory
    private let shell = ShellCommand(runner: SystemProcessRunner())

    init() throws {
        temp = try TempDirectory()
        for folder in ["input", "output", "Downloads"] { try temp.directory(folder) }
        try temp.file("opened.txt", "")
    }

    private var steps: [SourceStep] {
        guard let template = BundledTemplates.all.first(where: { $0.id == "claude" }),
              case let .steps(steps) = template.kind else { return [] }
        return steps
    }

    private var command: String {
        guard case let .command(command, _) = steps.last?.kind else { return "" }
        return command
    }

    private func manifest(_ files: [(name: String, link: String)], createdAt: String = "2026-01-15T00:00:00.231593+00:00") throws {
        let entries = files.map { #"{"export_url":"\#($0.link)","filename":"\#($0.name)","category":"x","part":0}"# }
        try temp.file("input/manifest-abc.json", #"{"created_at":"\#(createdAt)","total_files":\#(files.count),"data_files":[\#(entries.joined(separator: ","))],"version":"1.0"}"#)
    }

    /// Подменяет браузер: записывает открытую ссылку и «скачивает» файл с тем именем, которое задано для ссылки.
    private func fakeBrowser(_ downloads: [String: String]) throws -> String {
        let cases = downloads.map { #"  "\#($0.key)") echo data > "\#(temp.path("Downloads").path)/\#($0.value)" ;;"# }.joined(separator: "\n")
        let script = """
        #!/bin/zsh
        echo "$1" >> "\(temp.path("opened.txt").path)"
        case "$1" in
        \(cases)
        esac
        """
        let url = try temp.file("fake-open", script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    private func run(opener: String) async throws -> String {
        try await shell.run(command, timeoutSeconds: 60, environment: [
            "BACKUP_INPUT_DIR": temp.path("input").path,
            "BACKUP_OUTPUT_DIR": temp.path("output").path,
            "BACKUP_DOWNLOADS_DIR": temp.path("Downloads").path,
            "BACKUP_OPEN_COMMAND": opener,
            "BACKUP_WAIT_SECONDS": "3",
        ]) { _ in }
    }

    /// Login-оболочка может дописать в вывод своё, поэтому ошибки сверяются по концу текста.
    private func failure(opener: String) async -> String {
        do {
            _ = try await run(opener: opener)
            Issue.record("ожидалась ошибка шага")
            return ""
        } catch let SourceError.commandFailed(_, output) {
            return output
        } catch {
            Issue.record("неожиданная ошибка: \(error)")
            return ""
        }
    }

    private var opened: [String] {
        ((try? String(contentsOf: temp.path("opened.txt"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    private let two = [(name: "memories-000.zip", link: "https://claude.ai/export/x/download/1"), (name: "projects-000.zip", link: "https://claude.ai/export/x/download/2")]

    @Test func templateIsAManualStepFollowedByACommand() {
        #expect(steps.map(\.name) == ["Запросить экспорт", "Скачать архивы"])
        guard case let .manual(instructions, watchPath, filePattern, includeInCopy) = steps.first?.kind,
              case let .command(_, timeoutSeconds) = steps.last?.kind else {
            Issue.record("неожиданные шаги")
            return
        }
        #expect(watchPath == "~/Downloads")
        #expect(filePattern == "manifest-*.json")
        #expect(!includeInCopy)
        #expect(instructions.contains("claude.ai"))
        #expect(timeoutSeconds == 3600)
    }

    @Test func everyArchiveIsOpenedAndMovedIntoTheCopy() async throws {
        defer { temp.remove() }
        try manifest(two)
        let opener = try fakeBrowser(["https://claude.ai/export/x/download/1": "memories-000.zip", "https://claude.ai/export/x/download/2": "projects-000.zip"])

        let tail = try await run(opener: opener)

        #expect(tail.hasSuffix("скачано 2 из 2"))
        #expect(opened == two.map(\.link))
        #expect(temp.names(in: "output") == ["memories-000.zip", "projects-000.zip"])
        #expect(temp.names(in: "Downloads").isEmpty)
        #expect(temp.names(in: "input") == ["manifest-abc.json"])
    }

    @Test func archiveDownloadedEarlierIsNotOpenedAgain() async throws {
        defer { temp.remove() }
        try manifest(two)
        try temp.file("Downloads/memories-000.zip", "data")
        let opener = try fakeBrowser(["https://claude.ai/export/x/download/2": "projects-000.zip"])

        _ = try await run(opener: opener)

        #expect(opened == ["https://claude.ai/export/x/download/2"])
        #expect(temp.names(in: "output") == ["memories-000.zip", "projects-000.zip"])
    }

    @Test func staleArchiveStopsTheStepBeforeAnyLinkIsOpened() async throws {
        defer { temp.remove() }
        try manifest(two)
        let old = Fixtures.date("2026-01-01 00:00:00")
        try temp.file("Downloads/memories-000.zip", "old", modified: old)
        let opener = try fakeBrowser(["https://claude.ai/export/x/download/2": "projects-000.zip"])

        #expect(await failure(opener: opener).hasSuffix("В папке загрузок лежит старый файл memories-000.zip. Уберите его и повторите шаг."))
        #expect(opened.isEmpty)
        #expect(temp.names(in: "Downloads") == ["memories-000.zip"])
        #expect(temp.names(in: "output").isEmpty)
    }

    @Test func halfDownloadedArchiveIsNotTaken() async throws {
        defer { temp.remove() }
        try manifest([two[0]])
        try temp.file("Downloads/memories-000.zip", "partial")
        try temp.file("Downloads/memories-000.zip.part", "partial")

        #expect(await failure(opener: "/usr/bin/true").hasSuffix("Не скачались архивы: memories-000.zip. Запросите экспорт заново."))
        #expect(opened.isEmpty)
        #expect(temp.names(in: "output").isEmpty)
        #expect(temp.names(in: "Downloads") == ["memories-000.zip", "memories-000.zip.part"])
    }

    @Test func missingArchivesAreNamedInTheError() async throws {
        defer { temp.remove() }
        try manifest(two)
        let opener = try fakeBrowser(["https://claude.ai/export/x/download/1": "memories-000.zip"])

        #expect(await failure(opener: opener).hasSuffix("Не скачались архивы: projects-000.zip. Запросите экспорт заново."))
        #expect(temp.names(in: "Downloads") == ["memories-000.zip"])
        #expect(temp.names(in: "output").isEmpty)
    }

    @Test func archiveNameFromTheManifestCannotEscapeTheFolders() async throws {
        defer { temp.remove() }
        try manifest([(name: "../../evil.zip", link: "https://claude.ai/export/x/download/1")])
        let opener = try fakeBrowser(["https://claude.ai/export/x/download/1": "evil.zip"])

        _ = try await run(opener: opener)

        #expect(temp.names(in: "output") == ["evil.zip"])
        #expect(!temp.exists("evil.zip"))
    }

    @Test func stepFailsWithoutAManifest() async throws {
        defer { temp.remove() }
        #expect(await failure(opener: "/usr/bin/true").hasSuffix("Манифест экспорта не найден."))
    }
}
```

- [ ] **Step 2: Убедиться, что тесты падают**

Run: `swift test --package-path BackupCore --filter ClaudeTemplateTests 2>&1 | tail -15`
Expected: FAIL — `templateIsAManualStepFollowedByACommand` получает пустой список шагов.

- [ ] **Step 3: Заменить шаблон**

В `Storage/BundledTemplates.swift` заменить `private static let claude` целиком:

```swift
    private static let claude = SourceTemplate(
        id: "claude",
        name: "Claude",
        kind: .steps(steps: [
            SourceStep(
                id: UUID(uuidString: "C1A0DE00-0000-4000-8000-000000000001")!,
                name: "Запросить экспорт",
                kind: .manual(
                    instructions: """
                    1. Откройте https://claude.ai → Settings → Privacy → Export data.
                    2. Дождитесь письма и перейдите по ссылке из него.
                    3. Скачайте файл манифеста в «Загрузки», не меняя имя.

                    Архивы приложение скачает само через браузер по умолчанию: в нём должен быть выполнен вход в claude.ai, а переименование загрузок выключено.
                    """,
                    watchPath: downloads,
                    filePattern: "manifest-*.json",
                    includeInCopy: false
                )
            ),
            SourceStep(
                id: UUID(uuidString: "C1A0DE00-0000-4000-8000-000000000002")!,
                name: "Скачать архивы",
                kind: .command(
                    command: #"""
                    set -euo pipefail
                    downloads="${BACKUP_DOWNLOADS_DIR:-$HOME/Downloads}"
                    opener=(${=BACKUP_OPEN_COMMAND:-open -g})
                    wait_seconds="${BACKUP_WAIT_SECONDS:-3300}"

                    manifest=("$BACKUP_INPUT_DIR"/manifest-*.json(N.om[1]))
                    [ ${#manifest} -eq 1 ] || { echo "Манифест экспорта не найден." >&2; exit 1; }
                    created="$(plutil -extract created_at raw -o - "$manifest")"
                    since="$(date -j -u -f '%Y-%m-%dT%H:%M:%S' "${created[1,19]}" +%s)"
                    total="$(plutil -extract data_files raw -o - "$manifest")"

                    names=(); urls=()
                    for ((i = 0; i < total; i++)); do
                      names+=("${$(plutil -extract "data_files.$i.filename" raw -o - "$manifest"):t}")
                      urls+=("$(plutil -extract "data_files.$i.export_url" raw -o - "$manifest")")
                    done

                    # Браузер ставит файлу дату изменения с сервера, поэтому возраст считается и по дате появления на диске
                    age_mark() {
                      local born changed
                      born="$(stat -f %B "$1")"; changed="$(stat -f %m "$1")"
                      echo $(( born > changed ? born : changed ))
                    }
                    downloaded() {
                      [ -s "$downloads/$1" ] && [ ! -e "$downloads/$1.part" ] && [ "$(age_mark "$downloads/$1")" -gt "$since" ]
                    }

                    for ((i = 1; i <= total; i++)); do
                      downloaded "$names[i]" && continue
                      if [ -e "$downloads/$names[i]" ] && [ ! -e "$downloads/$names[i].part" ]; then
                        echo "В папке загрузок лежит старый файл $names[i]. Уберите его и повторите шаг." >&2
                        exit 1
                      fi
                    done
                    for ((i = 1; i <= total; i++)); do
                      downloaded "$names[i]" || [ -e "$downloads/$names[i].part" ] || $opener "$urls[i]"
                    done

                    deadline=$(( $(date +%s) + wait_seconds ))
                    while true; do
                      left=()
                      for name in $names; do downloaded "$name" || left+=("$name"); done
                      echo "скачано $(( total - ${#left} )) из $total"
                      [ ${#left} -eq 0 ] && break
                      if [ "$(date +%s)" -ge "$deadline" ]; then
                        echo "Не скачались архивы: ${(j:, :)left}. Запросите экспорт заново." >&2
                        exit 1
                      fi
                      sleep 2
                    done
                    for name in $names; do mv "$downloads/$name" "$BACKUP_OUTPUT_DIR/$name"; done
                    """#,
                    timeoutSeconds: 3600
                )
            ),
        ]),
        schedule: .monthly,
        retention: RetentionRules(daily: 0, weekly: 0, monthly: 12, yearly: 0),
        description: "Все чаты, проекты и память аккаунта Claude — архивы официального экспорта.",
        instructions: "Экспорт делается в два шага: манифест скачиваете вы, архивы по ссылкам из него приложение скачивает само."
    )
```

Отличие от вручную проверенной версии: файл с соседом `.part` считается идущей загрузкой — он не «старый» и его ссылка повторно не открывается (сценарий Firefox, тест `halfDownloadedArchiveIsNotTaken`).

- [ ] **Step 4: Прогнать тесты**

Run: `swift test --package-path BackupCore 2>&1 | tail -5`
Expected: PASS (включая `bundledTemplatesInstallOnceAndAllDecode` и `everyBundledTemplateSaysWhatItBacksUp`).
Run: `swift test --package-path App 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 5: Уточнить спеку**

В `docs/superpowers/specs/2026-09-30-backup-manager-design.md`, в описании шага 2 шаблона Claude, после предложения «…иначе ссылка `export_url` открывается в браузере по умолчанию в фоне (`open -g`).» добавить:

```
Если в «Загрузках» лежит одноимённый файл старше манифеста, шаг сразу завершается ошибкой с просьбой убрать его и ни одной ссылки не открывает: иначе браузер сохранил бы новый архив под именем «… (1).zip» и шаг ждал бы его до таймаута. Файл, рядом с которым лежит `.part`, считается ещё скачивающимся.
```

В разделе 8 заменить «устаревшие одноимённые файлы не принимаются» на «устаревший одноимённый файл останавливает шаг до открытия ссылок».

- [ ] **Step 6: Коммит**

```bash
git add BackupCore docs
git commit -m "Move the Claude template to steps: manifest by hand, archives by command

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: Редактор шагов в настройках источника

**Files:**
- Modify: `App/Sources/BackupEverything/Model/Drafts.swift`
- Create: `App/Sources/BackupEverything/Views/StepsEditor.swift`
- Modify: `App/Sources/BackupEverything/Views/SourcesView.swift`
- Test: `App/Tests/BackupEverythingTests/DraftTests.swift`

**Interfaces:**
- Consumes: `SourceStep`, `StepKind` (задача 1); компоненты из `Views/SettingsComponents.swift`: `SettingsSection(title:)`, `SettingsRow(title:)`, `SettingsRow(title:tip:)`, `PathField(path:)`, `CodeEditor(text:minHeight:)`.
- Produces:
  - `enum StepKindChoice: String, CaseIterable, Identifiable { case manual, command; var title: String }`
  - `struct StepDraft: Identifiable, Equatable { var id: UUID; var name: String; var kindChoice: StepKindChoice; var instructions, watchPath, filePattern: String; var includeInCopy: Bool; var command: String; var timeoutMinutes: Int; init(_ step: SourceStep); init(new kindChoice: StepKindChoice); func build() -> SourceStep; var problem: String? }`
  - `SourceDraft.steps: [StepDraft]` (заменяет `[SourceStep]` из задачи 1)
  - `SourceDraft.firstStepIsManual: Bool`
  - `struct StepsEditor: View { init(steps: Binding<[StepDraft]>, currentIndex: Int?) }`

- [ ] **Step 1: Написать падающие тесты**

В `DraftTests.swift` заменить тест `stepChainWithoutStepsCannotBeSaved` из задачи 1 на:

```swift
    @Test func stepChainExplainsWhatIsMissing() {
        var draft = SourceDraft(source(.steps(steps: [])))
        #expect(draft.problem == "Добавьте хотя бы один шаг.")

        draft.steps = [StepDraft(new: .manual), StepDraft(new: .command)]
        #expect(draft.steps.map(\.name) == ["Ручной шаг", "Команда"])
        #expect(draft.firstStepIsManual)
        #expect(draft.problem == "Шаг 1: укажите маску файла, например manifest-*.json.")
        draft.steps[0].filePattern = " manifest-*.json "
        #expect(draft.problem == "Шаг 2: укажите команду.")
        draft.steps[1].command = "echo hi"
        draft.steps[1].name = "  "
        #expect(draft.problem == "Шаг 2: укажите название.")
        draft.steps[1].name = " Скачать "
        draft.steps[0].watchPath = ""
        #expect(draft.problem == "Шаг 1: укажите папку, куда попадает файл.")
        draft.steps[0].watchPath = "~/Downloads"
        #expect(draft.problem == nil)

        #expect(draft.build().kind == .steps(steps: [
            SourceStep(id: draft.steps[0].id, name: "Ручной шаг", kind: .manual(instructions: "", watchPath: "~/Downloads", filePattern: "manifest-*.json", includeInCopy: true)),
            SourceStep(id: draft.steps[1].id, name: "Скачать", kind: .command(command: "echo hi", timeoutSeconds: 3600)),
        ]))
    }

    @Test func stepDraftKeepsBothFormsWhileTheKindIsSwitched() {
        var step = StepDraft(SourceStep(name: "Архивы", kind: .command(command: "echo hi", timeoutSeconds: 1800)))
        #expect(step.timeoutMinutes == 30)
        step.kindChoice = .manual
        step.filePattern = "x-*.zip"
        step.kindChoice = .command
        #expect(step.build().kind == .command(command: "echo hi", timeoutSeconds: 1800))
    }
```

- [ ] **Step 2: Убедиться, что тесты не собираются**

Run: `swift test --package-path App --filter DraftTests 2>&1 | tail -10`
Expected: `cannot find 'StepDraft' in scope`.

- [ ] **Step 3: Реализовать черновик шага**

В `Model/Drafts.swift` после `SourceKindChoice` добавить:

```swift
enum StepKindChoice: String, CaseIterable, Identifiable {
    case manual
    case command

    var id: String { rawValue }

    var title: String {
        switch self {
        case .manual: "Ручной шаг"
        case .command: "Команда"
        }
    }
}

struct StepDraft: Identifiable, Equatable {
    var id: UUID
    var name: String
    var kindChoice: StepKindChoice
    var instructions = ""
    var watchPath = "~/Downloads"
    var filePattern = ""
    var includeInCopy = true
    var command = ""
    var timeoutMinutes = 60

    init(new kindChoice: StepKindChoice) {
        id = UUID()
        name = kindChoice.title
        self.kindChoice = kindChoice
    }

    init(_ step: SourceStep) {
        id = step.id
        name = step.name
        switch step.kind {
        case let .manual(instructions, watchPath, filePattern, includeInCopy):
            kindChoice = .manual
            self.instructions = instructions
            self.watchPath = watchPath
            self.filePattern = filePattern
            self.includeInCopy = includeInCopy
        case let .command(command, timeoutSeconds):
            kindChoice = .command
            self.command = command
            timeoutMinutes = max(1, timeoutSeconds / 60)
        }
    }

    var problem: String? {
        if trimmed(name).isEmpty { return "укажите название." }
        switch kindChoice {
        case .manual where trimmed(watchPath).isEmpty: return "укажите папку, куда попадает файл."
        case .manual where trimmed(filePattern).isEmpty: return "укажите маску файла, например manifest-*.json."
        case .command where trimmed(command).isEmpty: return "укажите команду."
        default: return nil
        }
    }

    func build() -> SourceStep {
        let kind: StepKind = switch kindChoice {
        case .manual:
            .manual(instructions: instructions, watchPath: trimmed(watchPath), filePattern: trimmed(filePattern), includeInCopy: includeInCopy)
        case .command:
            .command(command: command, timeoutSeconds: max(1, timeoutMinutes) * 60)
        }
        return SourceStep(id: id, name: trimmed(name), kind: kind)
    }

    private func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
```

В `SourceDraft`:
- поле из задачи 1 заменить на `var steps: [StepDraft] = []`;
- в `init`: `self.steps = steps.map(StepDraft.init)`;
- добавить `var firstStepIsManual: Bool { kindChoice == .steps && steps.first?.kindChoice == .manual }`;
- `problem` заменить целиком на:

```swift
    var problem: String? {
        kindProblem ?? (trimmed(name).isEmpty ? "Укажите название." : nil)
    }

    private var kindProblem: String? {
        switch kindChoice {
        case .folder:
            return trimmed(folderPath).isEmpty ? "Укажите папку или файл источника." : nil
        case .command:
            return trimmed(command).isEmpty ? "Укажите команду." : nil
        case .manualExport:
            if trimmed(watchPath).isEmpty { return "Укажите папку, куда попадает экспорт." }
            return trimmed(filePattern).isEmpty ? "Укажите маску файла, например Passwords*.csv." : nil
        case .steps:
            if steps.isEmpty { return "Добавьте хотя бы один шаг." }
            for (index, step) in steps.enumerated() {
                if let problem = step.problem { return "Шаг \(index + 1): \(problem)" }
            }
            return nil
        }
    }
```
- в `build()`: `source.kind = .steps(steps: steps.map { $0.build() })`.

- [ ] **Step 4: Прогнать тесты черновика**

Run: `swift test --package-path App --filter DraftTests 2>&1 | tail -5`
Expected: ошибка компиляции в `SourcesView.swift` (временный список из задачи 1 обращается к `step.isManual`). Перейти к шагу 5.

- [ ] **Step 5: Сделать редактор шагов**

Создать `Views/StepsEditor.swift`:

```swift
import BackupCore
import SwiftUI

struct StepsEditor: View {
    @Binding var steps: [StepDraft]
    let currentIndex: Int?

    var body: some View {
        SettingsSection(title: "Что бэкапить · тип «По шагам»: шаги выполняются по очереди") {
            ForEach($steps) { $step in
                let index = steps.firstIndex { $0.id == step.id } ?? 0
                StepCard(
                    step: $step,
                    number: index + 1,
                    isCurrent: index == currentIndex,
                    canMoveUp: index > 0,
                    canMoveDown: index < steps.count - 1,
                    move: { steps.swapAt(index, index + $0) },
                    remove: { steps.remove(at: index) }
                )
            }
            HStack {
                Menu("Добавить шаг") {
                    ForEach(StepKindChoice.allCases) { choice in
                        Button(choice.title) { steps.append(StepDraft(new: choice)) }
                    }
                }
                .fixedSize()
                Spacer()
            }
            .padding(10)
        }
    }
}

private struct StepCard: View {
    @Binding var step: StepDraft
    let number: Int
    let isCurrent: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let move: (Int) -> Void
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            switch step.kindChoice {
            case .manual: manualFields
            case .command: commandFields
            }
        }
        .background(isCurrent ? AnyShapeStyle(.tint.opacity(0.08)) : AnyShapeStyle(.clear))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("\(number)")
                .font(.callout.weight(.semibold).monospacedDigit())
                .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 18)
            TextField("", text: $step.name, prompt: Text("Название шага"))
                .textFieldStyle(.plain)
                .font(.body.weight(.medium))
            if isCurrent {
                Text("сейчас здесь").font(.caption).foregroundStyle(.tint)
            }
            Picker("", selection: $step.kindChoice) {
                ForEach(StepKindChoice.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            Button { move(-1) } label: { Image(systemName: "chevron.up") }
                .disabled(!canMoveUp)
                .help("Выше")
            Button { move(1) } label: { Image(systemName: "chevron.down") }
                .disabled(!canMoveDown)
                .help("Ниже")
            Button(role: .destructive, action: remove) { Image(systemName: "trash") }
                .help("Удалить шаг")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var manualFields: some View {
        TextEditor(text: $step.instructions)
            .font(.body)
            .scrollContentBackground(.hidden)
            .padding(6)
            .frame(minHeight: 80)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
            .help("Инструкция: что нужно сделать руками")
        SettingsRow(title: "Куда попадает файл") {
            PathField(path: $step.watchPath)
        }
        SettingsRow(title: "Маска файла") {
            TextField("", text: $step.filePattern, prompt: Text("например, manifest-*.json"))
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .font(.body.monospaced())
        }
        SettingsRow(
            title: "Файл входит в копию",
            tip: "Выключите, если файл нужен только следующим командам — он будет лежать в $BACKUP_INPUT_DIR."
        ) {
            Toggle("", isOn: $step.includeInCopy)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
    }

    @ViewBuilder
    private var commandFields: some View {
        CodeEditor(text: $step.command, minHeight: 130)
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
        SettingsRow(
            title: "Останавливать через",
            tip: "Результат — в $BACKUP_OUTPUT_DIR.\nФайлы ручных шагов, не входящие в копию, — в $BACKUP_INPUT_DIR.\nДля временных файлов есть $BACKUP_SCRATCH_DIR."
        ) {
            Stepper("\(step.timeoutMinutes) мин", value: $step.timeoutMinutes, in: 1...720)
        }
    }
}
```

В `Views/SourcesView.swift`:
- ветку `case .steps` в `kindCard` заменить на:

```swift
        case .steps:
            StepsEditor(steps: $draft.steps, currentIndex: isNew ? nil : model.chain(of: draft.id)?.stepIndex)
```

- заголовок строки расписания: `SettingsRow(title: draft.kindChoice == .manualExport || draft.firstStepIsManual ? "Напоминать об экспорте" : "Как часто")`;
- `conflictWarning`: заменить первую строку `guard draft.kindChoice == .manualExport else { return nil }` на `guard draft.kindChoice == .manualExport || draft.kindChoice == .steps else { return nil }`.

В `Model/AppModel.swift` в разделе `// MARK: Queries` добавить:

```swift
    func chain(of sourceId: UUID) -> ChainState? {
        state.sourceState(sourceId).chain
    }
```

- [ ] **Step 6: Прогнать тесты**

Run: `swift test --package-path BackupCore 2>&1 | tail -5`
Expected: PASS.
Run: `swift test --package-path App 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 7: Коммит**

```bash
git add App
git commit -m "Edit the steps of a step-chain source in its settings

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: Обзор и меню — положение в цепочке и действия

**Files:**
- Create: `App/Sources/BackupEverything/Presentation/ChainPosition.swift`
- Create: `App/Sources/BackupEverything/Presentation/SourceGuide.swift`
- Modify: `App/Sources/BackupEverything/Presentation/MenuLines.swift`
- Modify: `App/Sources/BackupEverything/Model/AppModel.swift`
- Modify: `App/Sources/BackupEverything/Views/OverviewView.swift`
- Modify: `App/Sources/BackupEverything/Views/MenuBarView.swift`
- Test: `App/Tests/BackupEverythingTests/ChainPresentationTests.swift` (новый)

**Interfaces:**
- Consumes: `ActivityTracker.step(of:)` (задача 4), `SourceStatus.awaitingFile` (задача 6), `AppModel.chain(of:)` (задача 8), `BackupCoordinator.restartChain` (задача 5).
- Produces:
  - `enum ChainPosition { static func label(of source: Source, chain: ChainState?) -> String?; static func label(index: Int, count: Int) -> String; static func note(_ note: String?, of source: Source, chain: ChainState?) -> String? }`
  - `enum SourceGuide { static func text(for source: Source) -> String }`
  - `MenuLines.of(config:state:report:unavailable:)` — новый параметр `state: AppState`
  - `AppModel.restartChain(_ source: Source) async`, `AppModel.runStep(of source: Source) -> (index: Int, count: Int)?`

- [ ] **Step 1: Написать падающие тесты**

Создать `App/Tests/BackupEverythingTests/ChainPresentationTests.swift`:

```swift
import BackupCore
import Foundation
import Testing
@testable import BackupEverything

struct ChainPresentationTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let cloud = Destination(name: "Cloud", kind: .localFolder(path: "/tmp/cloud"))

    private var claude: Source {
        Source(
            name: "Claude",
            slug: "claude",
            kind: .steps(steps: [
                SourceStep(name: "Запросить экспорт", kind: .manual(instructions: "Скачайте манифест.", watchPath: "~/Downloads", filePattern: "manifest-*.json", includeInCopy: false)),
                SourceStep(name: "Скачать архивы", kind: .command(command: "true", timeoutSeconds: 60)),
            ]),
            schedule: .monthly,
            destinationIds: [cloud.id],
            instructions: "Экспорт в два шага.",
            createdAt: now
        )
    }

    private var folder: Source {
        Source(name: "Obsidian", slug: "obsidian", kind: .folder(path: "~/Obsidian", excludes: []), schedule: .daily, createdAt: now)
    }

    @Test func positionIsShownOnlyForStepChains() {
        #expect(ChainPosition.label(of: folder, chain: nil) == nil)
        #expect(ChainPosition.label(of: claude, chain: nil) == "шаг 1 из 2")
        #expect(ChainPosition.label(of: claude, chain: ChainState(stepIndex: 1, startedAt: now, stepEnteredAt: now)) == "шаг 2 из 2")
        #expect(ChainPosition.label(of: claude, chain: ChainState(stepIndex: 2, startedAt: now, stepEnteredAt: now)) == "шаг 2 из 2")
        #expect(ChainPosition.label(index: 1, count: 3) == "шаг 2 из 3")
    }

    @Test func noteStartsWithThePosition() {
        let stuck = ChainState(stepIndex: 1, startedAt: now, stepEnteredAt: now, failure: "x")
        #expect(ChainPosition.note("пора сделать экспорт", of: claude, chain: nil) == "шаг 1 из 2 · пора сделать экспорт")
        #expect(ChainPosition.note("Команда завершилась с кодом 1", of: claude, chain: stuck) == "шаг 2 из 2 · Команда завершилась с кодом 1")
        #expect(ChainPosition.note(nil, of: claude, chain: nil) == nil)
        #expect(ChainPosition.note("выключен", of: folder, chain: nil) == "выключен")
    }

    @Test func menuLineCarriesThePosition() {
        let source = claude
        let message = "Команда завершилась с кодом 1. нет архивов"
        let config = Config(sources: [source], destinations: [cloud])
        var state = AppState()
        state.updateSource(source.id) { $0.chain = ChainState(stepIndex: 1, startedAt: now, stepEnteredAt: now, failure: message) }
        let report = StatusReport(items: [.runFailed(sourceId: source.id, message: message)])

        let lines = MenuLines.of(config: config, state: state, report: report, unavailable: [])
        #expect(lines.map(\.text) == ["шаг 2 из 2 · Команда завершилась с кодом 1"])
        #expect(lines.first?.severity == .error)
    }

    @Test func guideJoinsTheSourceInstructionWithItsManualSteps() {
        #expect(SourceGuide.text(for: claude) == """
        Экспорт в два шага.

        **Шаг 1. Запросить экспорт**

        Скачайте манифест.
        """)
        var plain = folder
        plain.instructions = "Укажите путь."
        #expect(SourceGuide.text(for: plain) == "Укажите путь.")
        #expect(SourceGuide.text(for: folder).isEmpty)
    }
}
```

`claude` и `folder` — вычисляемые свойства и при каждом обращении создают источник с новым `id`; там, где `id` должен совпасть с состоянием или отчётом, источник сначала сохраняется в локальную константу.

- [ ] **Step 2: Убедиться, что тесты не собираются**

Run: `swift test --package-path App --filter ChainPresentationTests 2>&1 | tail -10`
Expected: `cannot find 'ChainPosition' in scope`.

- [ ] **Step 3: Реализовать представление**

Создать `Presentation/ChainPosition.swift`:

```swift
import BackupCore
import Foundation

enum ChainPosition {
    static func label(index: Int, count: Int) -> String {
        "шаг \(index + 1) из \(count)"
    }

    static func label(of source: Source, chain: ChainState?) -> String? {
        let count = source.steps.count
        guard count > 0 else { return nil }
        return label(index: min(chain?.stepIndex ?? 0, count - 1), count: count)
    }

    static func note(_ note: String?, of source: Source, chain: ChainState?) -> String? {
        guard let note else { return nil }
        guard let label = label(of: source, chain: chain) else { return note }
        return "\(label) · \(note)"
    }
}
```

Создать `Presentation/SourceGuide.swift`:

```swift
import BackupCore
import Foundation

enum SourceGuide {
    static func text(for source: Source) -> String {
        var parts = source.instructions.isEmpty ? [] : [source.instructions]
        for (index, step) in source.steps.enumerated() {
            guard case let .manual(instructions, _, _, _) = step.kind, !instructions.isEmpty else { continue }
            parts.append("**Шаг \(index + 1). \(step.name)**\n\n\(instructions)")
        }
        return parts.joined(separator: "\n\n")
    }
}
```

`Presentation/MenuLines.swift`: сигнатуру заменить на `static func of(config: Config, state: AppState, report: StatusReport, unavailable: Set<UUID>) -> [MenuLine]`, а создание строки источника — на:

```swift
            let text = ChainPosition.note(note, of: source, chain: state.sourceState(source.id).chain) ?? note
            return MenuLine(subject: .source(source), severity: status.severity, text: text, canPickUp: canPickUp)
```

`Model/AppModel.swift`:
- `menuLines`: `MenuLines.of(config: config, state: state, report: report, unavailable: unavailableDestinations)`;
- рядом с `confirmPickup`:

```swift
    func restartChain(_ source: Source) async {
        await perform { try await self.coordinator.restartChain(sourceId: source.id) }
    }
```

- рядом с `runStatus(of:)`:

```swift
    func runStep(of source: Source) -> (index: Int, count: Int)? {
        activity.step(of: source.id)
    }
```

- [ ] **Step 4: Подключить в обзоре и меню**

`Views/OverviewView.swift` (строка источника):

1. В `note(_:_:)` обе ветки, которые показывают `status.note` (кнопка с ошибкой и обычный текст), должны выводить текст с положением. Добавить в структуру строки:

```swift
    private func positioned(_ note: String) -> String {
        ChainPosition.note(note, of: source, chain: model.chain(of: source.id)) ?? note
    }
```

и заменить `Text(note)` на `Text(positioned(note))` в обеих ветках.

2. `stageText(_:)` заменить на:

```swift
    private func stageText(_ stage: SourceStage) -> String {
        let text = Texts.stage(stage, destinationName: deliveringName(stage))
        let running = model.runStatus(of: source).map { "\(text.trimmingCharacters(in: CharacterSet(charactersIn: "…"))) · \($0)" } ?? text
        guard stage == .collecting, let step = model.runStep(of: source) else { return running }
        let label = ChainPosition.label(index: step.index, count: step.count)
        return "\(label) · \(model.runStatus(of: source) ?? "выполняет команду…")"
    }
```

3. В `hoverActions`:
- кнопку «Запустить» показывать при `!source.isManualExport` (условие не меняется — для цепочки она уже видна и вызывает `runNow`, то есть старт или повтор шага); подсказку сделать зависящей от состояния: `.help(model.chain(of: source.id)?.failure != nil ? "Повторить шаг" : "Запустить")`;
- в `Menu` после пункта «Показать ошибку» добавить:

```swift
                if model.chain(of: source.id)?.failure != nil {
                    Button("Повторить шаг") { Task { await model.runNow(source) } }
                        .disabled(model.isWorking)
                }
                if model.chain(of: source.id) != nil {
                    Button("Начать заново") { Task { await model.restartChain(source) } }
                        .disabled(model.isWorking)
                }
```

- пункт «Инструкция»: условие `!source.instructions.isEmpty` заменить на `!SourceGuide.text(for: source).isEmpty`.

4. Лист инструкции: `InstructionsSheet(title: source.name, text: SourceGuide.text(for: source))`.

5. В `timeDetails`: `let prefix = source.isManualExport || source.steps.first?.isManual == true ? "Экспорт пора делать" : "Следующий"`.

`Views/MenuBarView.swift`, строка 143 (строка выполняющегося источника): перед статусом добавить положение —

```swift
        let step = model.runStep(of: source).map { ChainPosition.label(index: $0.index, count: $0.count) }
        return [step, model.runStatus(of: source), elapsed].compactMap { $0 }.joined(separator: " · ")
```

- [ ] **Step 5: Прогнать тесты**

Run: `swift test --package-path BackupCore 2>&1 | tail -5`
Expected: PASS.
Run: `swift test --package-path App 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 6: Коммит**

```bash
git add App
git commit -m "Show where a step chain stands and let the user retry or restart it

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 10: Проверка в песочнице и выкатка

**Files:**
- Modify: `~/BackupEverything/templates/claude.json` (прод, только после согласия Макса)
- Modify: `~/BackupEverything/config.json` (прод, только после согласия Макса)

**Interfaces:**
- Consumes: всё предыдущее.

Эта задача меняет прод. Шаги 1–3 безопасны. Шаги 4–7 выполняются только после явного согласия Макса и только когда бэкап не идёт.

- [ ] **Step 1: Собрать песочницу**

```bash
swift build -c release --package-path App
```

Expected: `Compiling` … `Build complete!`, код возврата 0.

Собрать отдельный `.app` вне `dist/` (папка в scratchpad сессии, далее `$SANDBOX`):

```bash
mkdir -p "$SANDBOX/BackupEverythingSandbox.app/Contents/MacOS" "$SANDBOX/home"
cp "$(swift build -c release --package-path App --show-bin-path)/BackupEverything" "$SANDBOX/BackupEverythingSandbox.app/Contents/MacOS/BackupEverything"
cp App/Info.plist "$SANDBOX/BackupEverythingSandbox.app/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string local.backup-everything.sandbox "$SANDBOX/BackupEverythingSandbox.app/Contents/Info.plist"
codesign --force --sign - "$SANDBOX/BackupEverythingSandbox.app"
```

- [ ] **Step 2: Проверить поведение в песочнице**

Запустить:

```bash
BACKUP_EVERYTHING_HOME="$SANDBOX/home" "$SANDBOX/BackupEverythingSandbox.app/Contents/MacOS/BackupEverything" --show-window
```

Проверить по списку (снимки экрана — только окна песочницы):

1. «Источники → Добавить → Из шаблона → Claude»: блок «Что бэкапить · тип „По шагам“» показывает две карточки: «1 Запросить экспорт» (инструкция, папка, маска `manifest-*.json`, «Файл входит в копию» выключен) и «2 Скачать архивы» (команда, 60 мин). Строка расписания называется «Напоминать об экспорте».
2. Шаги переставляются стрелками, удаляются, добавляются через «Добавить шаг»; планка сохранения называет недостающее поле («Шаг 3: укажите команду.»).
3. После сохранения с локальным назначением (папка внутри `$SANDBOX`) в «Обзоре» у Claude пометка «шаг 1 из 2 · пора сделать экспорт», значок жёлтый; в «⋯ → Инструкция» виден текст источника и «Шаг 1. Запросить экспорт».
4. Заменить в песочнице команду второго шага на `cp "$BACKUP_INPUT_DIR"/manifest-*.json "$BACKUP_OUTPUT_DIR/archive.zip"` (чтобы не трогать настоящие одноразовые ссылки), положить в `~/Downloads` файл `manifest-sandbox-test.json` с содержимым `{}`. Через ~10 секунд источник сам проходит оба шага, в назначении появляется снапшот с `archive.zip`, файл из «Загрузок» исчезает.
5. Заменить команду на `echo 'Не скачались архивы: a.zip' >&2; exit 1`, снова положить манифест: пометка красная «шаг 2 из 2 · Команда завершилась с кодом 1», в «⋯» есть «Показать ошибку», «Повторить шаг», «Начать заново». «Начать заново» возвращает «шаг 1 из 2», манифест оказывается в Корзине.

Если что-то расходится со спекой — исправить код (с тестом), прогнать оба набора тестов, закоммитить и повторить проверку.

- [ ] **Step 3: Финальный прогон тестов**

Run: `swift test --package-path BackupCore 2>&1 | tail -5`
Expected: PASS.
Run: `swift test --package-path App 2>&1 | tail -5`
Expected: PASS.

Закрыть песочницу, отправить ветку:

```bash
git push
```

- [ ] **Step 4: Спросить согласие Макса на выкатку**

Сообщить Максу: новая версия проверена в песочнице; выкатка заменит `dist/BackupEverything.app`, перепишет шаблон Claude и источник «Claude» в `config.json` (назначения, расписание, хранение, значок, id и slug сохранятся); приложение нужно будет закрыть и открыть заново. Дождаться явного «да». Старая версия приложения не умеет читать новый `config.json`, поэтому порядок шагов 5–7 менять нельзя.

- [ ] **Step 5: Собрать прод-сборку**

```bash
./scripts/build-app.sh
```

Expected: путь к `dist/BackupEverything.app`, код возврата 0. Запущенное приложение продолжает работать на старом бинарнике.

- [ ] **Step 6: Попросить Макса закрыть приложение и перенести данные**

После того как Макс подтвердил, что приложение закрыто («Выйти» в меню) и бэкап не идёт:

```bash
cp ~/BackupEverything/config.json ~/BackupEverything/config.json.before-steps
cp ~/BackupEverything/templates/claude.json ~/BackupEverything/templates/claude.json.before-steps
cp "$SANDBOX/home/data/templates/claude.json" ~/BackupEverything/templates/claude.json
```

Перенести `kind`, `description` и `instructions` из нового шаблона в источник Claude, не трогая остальное:

```bash
python3 - <<'EOF'
import json, os
home = os.path.expanduser("~/BackupEverything")
template = json.load(open(f"{home}/templates/claude.json"))
config = json.load(open(f"{home}/config.json"))
matches = [s for s in config["sources"] if "manualExport" in s["kind"] and s["kind"]["manualExport"]["filePattern"] == "data-*.zip"]
assert len(matches) == 1, f"ожидался один источник Claude, найдено {len(matches)}"
source = matches[0]
source["kind"] = template["kind"]
source["description"] = template["description"]
source["instructions"] = template["instructions"]
tmp = f"{home}/config.json.tmp"
json.dump(config, open(tmp, "w"), ensure_ascii=False, indent=2, sort_keys=True)
os.replace(tmp, f"{home}/config.json")
print("ok:", source["name"], list(source["kind"].keys()))
EOF
```

Expected: `ok: Claude ['steps']`.

Файлы `*.before-steps` из папки `templates/` убрать из-под чтения шаблонов не требуется: `Store.loadTemplates` читает только расширение `.json`. Оба файла `*.before-steps` оставить до подтверждения Макса, что всё работает, затем убрать через `trash`.

- [ ] **Step 7: Отдать команду запуска и проверить на настоящем экспорте**

Отдать Максу команду (самому не запускать):

```bash
open dist/BackupEverything.app
```

Попросить Макса: убедиться, что переименование загрузок в Arc выключено; запросить новый экспорт в claude.ai и скачать манифест в «Загрузки». Ожидаемое: источник сам переходит на «шаг 2 из 2 · скачано N из 5», в браузере открываются вкладки, в назначении появляется снапшот с пятью zip-архивами без манифеста.
