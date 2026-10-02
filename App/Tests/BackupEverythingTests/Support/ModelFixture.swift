import AppKit
import BackupCore
import Foundation
import Testing
@testable import BackupEverything

/// Opens a command step until the test lets it finish, so a running backup can be looked at.
actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

/// Stands in for the shell: prints a progress line, waits for the gate, leaves a file in the output folder.
struct GatedCommandRunner: ProcessRunner {
    let gate: Gate
    var progressLine = "3 of 5"
    var exitCode: Int32 = 0

    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval?,
        onOutput: (@Sendable (String) -> Void)?
    ) async throws -> ProcessResult {
        onOutput?(progressLine)
        await gate.wait()
        if let output = environment["BACKUP_OUTPUT_DIR"] {
            try Data("exported".utf8).write(to: URL(fileURLWithPath: output).appendingPathComponent("export.txt"))
        }
        return ProcessResult(exitCode: exitCode, stdout: progressLine, stderr: exitCode == 0 ? "" : "gh: not logged in")
    }
}

@MainActor
final class ModelFixture {
    let temp: TemporaryFolder
    let defaults = TestDefaults()
    let finder = FakeFinder()
    let model: AppModel
    let store: Store
    private(set) var notices: [Notice] = []
    private(set) var changes = 0
    private(set) var edits = 0

    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    init(runner: any ProcessRunner = SystemProcessRunner(), rclone: RcloneLocator = RcloneLocator(candidates: []), prepare: Bool = true) throws {
        temp = try TemporaryFolder()
        store = Store(dataDirectory: temp.url.appendingPathComponent("data", isDirectory: true))
        model = AppModel(
            dataDirectory: store.dataDirectory,
            workDirectory: temp.url.appendingPathComponent("work", isDirectory: true),
            runner: runner,
            rclone: rclone,
            defaults: defaults.defaults,
            finder: finder
        )
        model.onNotices = { [weak self] in self?.notices += $0 }
        model.onChange = { [weak self] in self?.changes += 1 }
        model.onConfigEdited = { [weak self] in self?.edits += 1 }
        if prepare { model.prepare() }
    }

    var workDirectory: URL { temp.url.appendingPathComponent("work", isDirectory: true) }

    func disk(_ name: String = "HDD", connected: Bool = true, every days: Int? = nil) throws -> Destination {
        let path = temp.url.appendingPathComponent("disks/\(name)", isDirectory: true)
        if connected { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true) }
        return Destination(name: name, kind: .localFolder(path: path.path), expectedEvery: days.map { .days($0) } ?? .always)
    }

    func folderSource(_ name: String = "Notes", to destinations: [Destination], schedule: Schedule = .daily) throws -> Source {
        let folder = try temp.folder("originals/\(name)")
        try temp.file("note.md", in: folder, contents: String(repeating: "x", count: 2_000))
        return source(name, steps: [.folder(folder.path)], to: destinations, schedule: schedule)
    }

    func source(_ name: String, steps: [SourceStep], to destinations: [Destination] = [], schedule: Schedule = .daily) -> Source {
        Source(name: name, slug: name.lowercased(), steps: steps, schedule: schedule, destinationIds: destinations.map(\.id), createdAt: now)
    }

    /// Writes the settings as if they were edited elsewhere and shows them in the model.
    func use(_ config: Config, state: AppState = AppState()) async throws {
        try store.saveConfig(config)
        try store.saveState(state)
        await model.refresh()
    }

    /// Progress reaches the model through a stream, a moment after the operation itself returns.
    func settle() async {
        _ = await eventually { model.activity.active.isEmpty }
    }

    func savedConfig() throws -> Config {
        try store.loadConfig()
    }

    func picture(_ name: String = "icon.png") throws -> URL {
        let file = temp.url.appendingPathComponent(name)
        let image = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        try #require(image.representation(using: .png, properties: [:])).write(to: file)
        return file
    }
}
