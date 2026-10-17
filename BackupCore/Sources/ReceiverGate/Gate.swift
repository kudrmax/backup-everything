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
    private static let allowedLongOptions: Set<String> = ["--server", "--inplace", "--mkpath", "--chmod=ugo=rwX"]
    private static let optionsWithValue: Set<String> = ["--link-dest"]
    /// The letters rsync 3 sends to the receiver for our data transfer and for the completion marker: options without a
    /// value, then `e` whose value (the rest of the cluster) lists the protocol capabilities of the client. Letters that
    /// keep modes, owners, groups, ACLs or hard links (`p o g A H`) are not among them: the gate's umask sets the modes.
    private static let allowedOptionLetters = Set("lDtrXiLsxCIvu.")
    private static let allowedCapabilityLetters = Set("logDtpAXreHiLsfxCIvu.")

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
            if allowedLongOptions.contains(argument) || isAllowedShortCluster(argument) || argument == "." {
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

    private static func isAllowedShortCluster(_ argument: String) -> Bool {
        guard argument.count > 1, argument.hasPrefix("-"), !argument.hasPrefix("--") else { return false }
        let letters = argument.dropFirst()
        let options = letters.prefix { $0 != "e" }
        let capabilities = letters.dropFirst(options.count).dropFirst()
        return options.allSatisfy(allowedOptionLetters.contains) && capabilities.allSatisfy(allowedCapabilityLetters.contains)
    }

    /// The target must sit under a folder of the backup account, on a volume that honours owners, must not be (or lie
    /// in) a finished copy, and must not exist yet: a folder is written once, so an attempt never writes through hard
    /// links into an earlier copy.
    private static func check(target: String, environment: any GateEnvironment) -> GateError? {
        guard target.hasPrefix("/"), !target.split(separator: "/").contains("..") else {
            return GateError(message: "path must be absolute without “..”")
        }
        let folder = target.hasSuffix("/") ? String(target.dropLast()) : target
        var level = folder
        while !level.isEmpty, level != "/" {
            if environment.fileExists(atPath: level + "/" + completionMarker) {
                return GateError(message: "\(level) is a finished copy")
            }
            level = (level as NSString).deletingLastPathComponent
        }
        if environment.fileExists(atPath: folder) {
            return GateError(message: "\(folder) already exists")
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
