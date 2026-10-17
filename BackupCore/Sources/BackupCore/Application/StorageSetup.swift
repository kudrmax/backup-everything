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
    /// The command that protects one destination folder; the account, the gate and the sudo rule come with it.
    public static func command(script: String, folder: String) -> String {
        "sudo \(ShellQuoting.quoted(script)) \(ShellQuoting.quoted(folder))"
    }
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
