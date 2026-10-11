import Foundation

public enum CoreAssembly {
    public static func stagingDirectory(in workDirectory: URL) -> URL {
        workDirectory.appendingPathComponent("staging", isDirectory: true)
    }

    public static func pendingDirectory(in workDirectory: URL) -> URL {
        workDirectory.appendingPathComponent("pending", isDirectory: true)
    }

    public static func chainsDirectory(in workDirectory: URL) -> URL {
        workDirectory.appendingPathComponent("chains", isDirectory: true)
    }

    public static func scratchDirectory(in workDirectory: URL) -> URL {
        workDirectory.appendingPathComponent("scratch", isDirectory: true)
    }

    public static func makeCoordinator(
        dataDirectory: URL,
        workDirectory: URL,
        timeZone: TimeZone = .current,
        runner: any ProcessRunner = SystemProcessRunner(),
        time: any TimeSource = SystemTimeSource(),
        rsync: URL = RsyncTransfer.homebrewRsync,
        receiver: ReceiverCommand? = .standard,
        access: any DestinationAccess = SystemDestinationAccess(),
        quit: any QuitSignal = ProcessGroups.shared,
        trash: @escaping ManualExportInbox.Trash = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) },
        progress: @escaping ProgressHandler = { _ in }
    ) -> BackupCoordinator {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = timeZone
        let naming = SnapshotNaming(timeZone: timeZone)
        let inbox = ManualExportInbox(pendingRoot: pendingDirectory(in: workDirectory), naming: naming, trash: trash)
        let chains = StepChainRunner(
            chainsRoot: chainsDirectory(in: workDirectory),
            inbox: inbox,
            runner: runner,
            time: time,
            trash: trash,
            progress: progress
        )
        let transfer = RsyncTransfer(rsync: rsync, receiver: receiver, runner: runner, scratch: scratchDirectory(in: workDirectory))
        let stores = DefaultDestinationStoreFactory(naming: naming, access: access, transfer: transfer)
        let engine = BackupEngine(
            providers: DefaultSourceProviderFactory(
                runner: runner,
                stagingRoot: stagingDirectory(in: workDirectory),
                inbox: inbox,
                quit: quit,
                trash: trash,
                progress: progress
            ),
            stores: stores,
            naming: naming,
            time: time,
            progress: progress
        )
        return BackupCoordinator(
            store: Store(dataDirectory: dataDirectory),
            engine: engine,
            inbox: inbox,
            chains: chains,
            stores: stores,
            time: time,
            calendar: calendar,
            quit: quit,
            progress: progress
        )
    }
}
