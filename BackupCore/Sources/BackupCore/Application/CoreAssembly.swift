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
