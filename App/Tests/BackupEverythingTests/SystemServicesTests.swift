import BackupCore
import Foundation
import ServiceManagement
import Testing
@testable import BackupEverything

@MainActor
private final class RecordingCenter: NotificationPosting {
    private(set) var posted: [(title: String, body: String)] = []
    private(set) var authorizationRequests = 0

    func requestAuthorization() async {
        authorizationRequests += 1
    }

    func post(title: String, body: String) {
        posted.append((title, body))
    }
}

@MainActor
private final class FakeLoginService: LoginService {
    var status: SMAppService.Status
    var failure: Error?
    private(set) var calls: [String] = []

    init(status: SMAppService.Status) {
        self.status = status
    }

    func register() throws {
        calls.append("register")
        if let failure { throw failure }
        status = .enabled
    }

    func unregister() throws {
        calls.append("unregister")
        if let failure { throw failure }
        status = .notRegistered
    }
}

private struct Refusal: LocalizedError {
    var errorDescription: String? { "Operation not permitted" }
}

@MainActor
struct NotifierTests {
    private let source = UUID()
    private let disk = UUID()

    @Test func everyNoticeBecomesANotificationWithItsText() {
        let center = RecordingCenter()
        let notifier = Notifier(isAvailable: true, center: center)
        notifier.post([
            .runFailed(sourceId: source, sourceName: "GitHub", message: "gh: not logged in"),
            .destinationCaughtUp(destinationId: disk, destinationName: "HDD"),
        ])
        #expect(center.posted.map(\.title) == ["Backup failed", "Safe to disconnect the disk"])
        #expect(center.posted.map(\.body) == ["GitHub: gh: not logged in", "“HDD” has received all pending backups."])
    }

    @Test func withoutAnAppBundleNothingIsAskedOrShown() async {
        let center = RecordingCenter()
        let notifier = Notifier(isAvailable: false, center: center)
        notifier.requestAuthorization()
        notifier.post([.deviceDue(sourceId: source, sourceName: "PocketBook")])
        try? await Task.sleep(for: .milliseconds(50))
        #expect(center.authorizationRequests == 0)
        #expect(center.posted.isEmpty)
    }

    @Test func asksForPermissionOnce() async {
        let center = RecordingCenter()
        Notifier(isAvailable: true, center: center).requestAuthorization()
        #expect(await eventually { center.authorizationRequests == 1 })
    }

    @Test func noticeTextsSayWhatToDo() {
        let texts = [
            Notice.deviceDue(sourceId: source, sourceName: "PocketBook"),
            .deviceCanBeUnplugged(sourceId: source, sourceName: "PocketBook"),
            .manualExportDue(sourceId: source, sourceName: "Google"),
            .connectDestination(destinationId: disk, destinationName: "HDD", onlyCopyOf: ["Notes"]),
            .copiesMissing(sourceId: source, sourceName: "Notes", destinationName: "HDD"),
        ].map(NoticeText.of)
        #expect(texts.map(\.title) == ["Time to connect the device", "Safe to disconnect", "Time to export", "Connect “HDD”", "Copy missing"])
        #expect(texts.map(\.body) == [
            "Connect “PocketBook” with a cable and the backup starts on its own.",
            "The backup of “PocketBook” is done, you can disconnect the device.",
            "Google: open Backup Everything for instructions.",
            "The backup of “Notes” exists nowhere else. It will be written as soon as you connect the disk.",
            "The latest copy of “Notes” was not found on “HDD”. Making a new one.",
        ])
    }
}

@MainActor
struct LoginItemTests {
    @Test func turningOnRegistersTheAppAndReportsItEnabled() {
        let service = FakeLoginService(status: .notRegistered)
        let item = LoginItem(service: service)
        #expect(!item.isEnabled)
        let result = item.apply(true)
        #expect(result?.isEnabled == true)
        #expect(result?.problem == nil)
        #expect(service.calls == ["register"])
    }

    @Test func turningOffUnregistersTheApp() {
        let service = FakeLoginService(status: .enabled)
        let result = LoginItem(service: service).apply(false)
        #expect(result?.isEnabled == false)
        #expect(service.calls == ["unregister"])
    }

    @Test func switchThatAlreadyMatchesTheSystemChangesNothing() {
        let service = FakeLoginService(status: .enabled)
        #expect(LoginItem(service: service).apply(true) == nil)
        #expect(service.calls.isEmpty)
    }

    @Test func refusalIsExplainedAndTheSwitchFollowsTheSystem() {
        let service = FakeLoginService(status: .requiresApproval)
        service.failure = Refusal()
        let result = LoginItem(service: service).apply(true)
        #expect(result?.isEnabled == false)
        #expect(result?.problem == "Could not change launch at login: Operation not permitted")
    }
}

struct AppPathsTests {
    private let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
    private let support = URL(fileURLWithPath: "/Users/someone/Library/Application Support", isDirectory: true)

    @Test func settingsLiveInTheHomeFolderAndWorkFilesInApplicationSupport() {
        #expect(AppPaths.dataDirectory(environment: [:], home: home).path == "/Users/someone/BackupEverything")
        #expect(AppPaths.workDirectory(environment: [:], applicationSupport: support).path == "/Users/someone/Library/Application Support/BackupEverything")
    }

    @Test func sandboxKeepsEverythingUnderItsOwnFolder() {
        let environment = ["BACKUP_EVERYTHING_HOME": "/tmp/sandbox"]
        #expect(AppPaths.dataDirectory(environment: environment, home: home).path == "/tmp/sandbox/data")
        #expect(AppPaths.workDirectory(environment: environment, applicationSupport: support).path == "/tmp/sandbox/work")
    }

    @Test func realPathsFollowTheProcessEnvironment() {
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #expect(AppPaths.dataDirectory == AppPaths.dataDirectory(environment: environment, home: home))
        #expect(AppPaths.workDirectory == AppPaths.workDirectory(environment: environment, applicationSupport: support))
    }

    @Test func tildeExpandsToTheHomeFolder() {
        #expect(AppPaths.expand("~/Downloads").path == FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads").path)
        #expect(AppPaths.expand("/Volumes/HDD").path == "/Volumes/HDD")
    }
}

@MainActor
struct FolderWatcherTests {
    @Test func reportsAFileLandingInTheFolder() async throws {
        let temp = try TemporaryFolder()
        var changes = 0
        let watcher = try #require(FolderWatcher(url: temp.url) { changes += 1 })
        try temp.file("takeout-1.zip")
        #expect(await eventually { changes > 0 })
        watcher.stop()
    }

    @Test func staysQuietOnceStopped() async throws {
        let temp = try TemporaryFolder()
        var changes = 0
        let watcher = try #require(FolderWatcher(url: temp.url) { changes += 1 })
        watcher.stop()
        try temp.file("takeout-1.zip")
        try await Task.sleep(for: .milliseconds(200))
        #expect(changes == 0)
    }

    @Test func missingFolderCannotBeWatched() throws {
        let temp = try TemporaryFolder()
        #expect(FolderWatcher(url: temp.url.appendingPathComponent("missing")) {} == nil)
    }
}

@MainActor
private final class RecordingDriver: BackgroundDriving {
    private(set) var starts = 0

    func start() {
        starts += 1
    }
}

@MainActor
private final class RecordingNotifier: Notifying {
    private(set) var authorizationRequests = 0
    private(set) var posted: [Notice] = []

    func requestAuthorization() {
        authorizationRequests += 1
    }

    func post(_ notices: [Notice]) {
        posted += notices
    }
}

@MainActor
struct AppServicesTests {
    private func services(
        secondInstance: Bool,
        temp: TemporaryFolder,
        defaults: TestDefaults,
        handleTermination: @escaping () -> Void = {}
    ) -> (AppServices, RecordingDriver, RecordingNotifier, () -> Int) {
        let model = AppModel(
            dataDirectory: temp.url.appendingPathComponent("data"),
            workDirectory: temp.url.appendingPathComponent("work"),
            rclone: RcloneLocator(candidates: []),
            defaults: defaults.defaults
        )
        let driver = RecordingDriver()
        let notifier = RecordingNotifier()
        var quits = 0
        let services = AppServices(
            model: model,
            driver: driver,
            notifier: notifier,
            isSecondInstance: { secondInstance },
            handleTermination: handleTermination,
            quit: { quits += 1 }
        )
        return (services, driver, notifier, { quits })
    }

    @Test func startsBackgroundWorkAndSendsNoticesToNotifications() throws {
        let temp = try TemporaryFolder()
        let defaults = TestDefaults()
        let (services, driver, notifier, quits) = services(secondInstance: false, temp: temp, defaults: defaults)
        #expect(services.model.config.sources.map(\.name) == [Bootstrap.selfSourceName])
        services.start()
        #expect(driver.starts == 1)
        #expect(notifier.authorizationRequests == 1)
        #expect(quits() == 0)
        let notice = Notice.deviceDue(sourceId: UUID(), sourceName: "PocketBook")
        services.model.onNotices([notice])
        #expect(notifier.posted == [notice])
    }

    /// `kill` and logging out stop the commands of the copy that runs them; a second copy runs none.
    @Test(arguments: [false, true])
    func onlyTheFirstCopyHandlesRequestsToQuit(secondInstance: Bool) throws {
        let temp = try TemporaryFolder()
        let defaults = TestDefaults()
        var installed = 0
        _ = services(secondInstance: secondInstance, temp: temp, defaults: defaults) { installed += 1 }
        #expect(installed == (secondInstance ? 0 : 1))
    }

    @Test func secondCopyQuitsWithoutStartingAnything() throws {
        let temp = try TemporaryFolder()
        let defaults = TestDefaults()
        let (services, driver, notifier, quits) = services(secondInstance: true, temp: temp, defaults: defaults)
        services.start()
        #expect(quits() == 1)
        #expect(driver.starts == 0)
        #expect(notifier.authorizationRequests == 0)
    }

    /// The first copy may be running a backup: its temporary folder, settings and icons stay as they are.
    @Test func secondCopyTouchesNothingOfTheRunningOne() throws {
        let temp = try TemporaryFolder()
        let defaults = TestDefaults()
        let staged = try temp.file("export.txt", in: CoreAssembly.stagingDirectory(in: temp.url.appendingPathComponent("work")))
        let icon = try temp.file("unused.png", in: temp.url.appendingPathComponent("data/icons"))
        let (services, _, _, _) = services(secondInstance: true, temp: temp, defaults: defaults)
        #expect(services.isSecondInstance)
        services.start()
        #expect(FileManager.default.fileExists(atPath: staged.path))
        #expect(FileManager.default.fileExists(atPath: icon.path))
        #expect(!FileManager.default.fileExists(atPath: temp.url.appendingPathComponent("data/config.json").path))
    }

    @Test func secondInstanceIsAnotherRunningAppWithTheSameIdentifier() {
        #expect(!RunningCopies.isSecondInstance(bundleIdentifier: nil, ownProcess: 10) { _ in [10, 20] })
        #expect(!RunningCopies.isSecondInstance(bundleIdentifier: "local.backup-everything", ownProcess: 10) { _ in [10] })
        #expect(RunningCopies.isSecondInstance(bundleIdentifier: "local.backup-everything", ownProcess: 10) { $0 == "local.backup-everything" ? [10, 20] : [] })
    }

    @Test func copyStartedOutsideLaunchServicesStillSeesTheRunningOne() {
        #expect(RunningCopies.isSecondInstance(bundleIdentifier: "local.backup-everything", ownProcess: 30) { _ in [20] })
        #expect(!RunningCopies.isSecondInstance(bundleIdentifier: "local.backup-everything", ownProcess: 30) { _ in [] })
        #expect(!RunningCopies.isSecondInstance(bundleIdentifier: "local.backup-everything.tests.\(UUID().uuidString)"))
    }
}
