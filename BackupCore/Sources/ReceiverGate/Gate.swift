import Foundation

public struct GateError: Error, Equatable {
    public let message: String

    public init(message: String) {
        self.message = message
    }
}

/// What the gate creates itself before rsync starts: a target that already exists is refused at that moment.
public enum Claim: Equatable, Sendable {
    case folder(String)
    case marker(String)
}

public struct GatePlan: Equatable, Sendable {
    public let argv: [String]
    public let claim: Claim
}

/// What rsync may ask the receiver to do: copy into a new copy folder owned by the backup account, or write the
/// completion marker into a copy folder without one. Nothing else.
public enum Gate {
    public static let completionMarker = ".complete"
    private static let allowedLongOptions: Set<String> = ["--server", "--inplace", "--mkpath"]
    private static let linkDest = "--link-dest"
    /// The letters rsync 3 sends to the receiver for our data transfer and for the completion marker: options without a
    /// value, then `e` whose value (the rest of the cluster) lists the protocol capabilities of the client. Letters that
    /// keep modes, owners, groups, ACLs or hard links (`p o g A H`) are not among them: the gate's umask sets the modes.
    /// `s` would make rsync read a second set of arguments from the protocol, past the gate.
    private static let allowedOptionLetters = Set("lDtrX")
    private static let allowedCapabilityLetters = Set("logDtpAXreHiLsfxCIvu.")

    public static func plan(arguments: [String], environment: any GateEnvironment) -> Result<GatePlan, GateError> {
        var rest = arguments.dropFirst()
        if rest.first == "rsync" { rest = rest.dropFirst() }
        guard rest.first == "--server" else { return .failure(GateError(message: "only rsync --server is accepted")) }
        var argv: [String] = []
        var paths: [String] = []
        var linkDests: [String] = []
        var expectingLinkDest = false
        for argument in rest {
            if expectingLinkDest {
                let value = unescape(argument)
                linkDests.append(value)
                argv.append(value)
                expectingLinkDest = false
            } else if allowedLongOptions.contains(argument) || isAllowedShortCluster(argument) || argument == "." {
                argv.append(argument)
            } else if argument == linkDest {
                argv.append(argument)
                expectingLinkDest = true
            } else if argument.hasPrefix("-") {
                return .failure(GateError(message: "refused option \(argument)"))
            } else {
                let path = unescape(argument)
                paths.append(path)
                argv.append(path)
            }
        }
        guard paths.count == 1, let target = paths.first else {
            return .failure(GateError(message: "exactly one destination path is accepted"))
        }
        return claim(for: target, environment: environment).flatMap { claim in
            if let refused = linkDests.first(where: { !isAcceptable(linkDest: $0, claim: claim, environment: environment) }) {
                return .failure(GateError(message: "refused link-dest \(refused)"))
            }
            return .success(GatePlan(argv: argv, claim: claim))
        }
    }

    /// rsync escapes the paths it sends for a remote shell to remove; `sudo` starts the gate without a shell.
    public static func unescape(_ escaped: String) -> String {
        var plain = ""
        var characters = escaped.makeIterator()
        while let character = characters.next() {
            if character == "\\", let next = characters.next() {
                plain.append(next)
            } else {
                plain.append(character)
            }
        }
        return plain
    }

    private static func isAllowedShortCluster(_ argument: String) -> Bool {
        guard argument.count > 1, argument.hasPrefix("-"), !argument.hasPrefix("--") else { return false }
        let letters = argument.dropFirst()
        let options = letters.prefix { $0 != "e" }
        let capabilities = letters.dropFirst(options.count).dropFirst()
        return options.allSatisfy(allowedOptionLetters.contains) && capabilities.allSatisfy(allowedCapabilityLetters.contains)
    }

    /// The target must sit under a folder of the backup account, on a volume that honours owners, without symlinks on
    /// the way, and must not be (or lie in) a finished copy.
    private static func claim(for target: String, environment: any GateEnvironment) -> Result<Claim, GateError> {
        guard isAbsoluteWithoutClimbing(target) else { return .failure(GateError(message: "path must be absolute without “..”")) }
        let folder = target.hasSuffix("/") ? String(target.dropLast()) : target
        var level = folder
        while !level.isEmpty, level != "/" {
            if environment.fileExists(atPath: level + "/" + completionMarker) {
                return .failure(GateError(message: "\(level) is a finished copy"))
            }
            level = (level as NSString).deletingLastPathComponent
        }
        let claim: Claim
        if target.hasSuffix("/") {
            claim = .folder(folder)
        } else if (target as NSString).lastPathComponent == completionMarker {
            claim = .marker(target)
        } else {
            return .failure(GateError(message: "the destination must be a new copy folder or its completion marker"))
        }
        guard let existing = nearestExisting(folder, environment: environment),
              environment.ownerUID(ofPath: existing) == environment.currentUID else {
            return .failure(GateError(message: "\(folder) is not inside a folder of the backup account"))
        }
        guard environment.realPath(ofPath: existing) == existing else {
            return .failure(GateError(message: "\(folder) goes through a symlink"))
        }
        guard environment.volumeHonoursOwners(atPath: existing) else {
            return .failure(GateError(message: "the volume of \(folder) ignores file owners"))
        }
        return .success(claim)
    }

    /// rsync reads unchanged files from a link-dest as the backup account: only from its own folders.
    private static func isAcceptable(linkDest: String, claim: Claim, environment: any GateEnvironment) -> Bool {
        guard isAbsoluteWithoutClimbing(linkDest) else { return false }
        let path = linkDest.hasSuffix("/") ? String(linkDest.dropLast()) : linkDest
        guard case let .folder(folder) = claim, path != folder else { return false }
        guard let existing = nearestExisting(path, environment: environment) else { return false }
        return environment.ownerUID(ofPath: existing) == environment.currentUID
            && environment.realPath(ofPath: existing) == existing
            && environment.volumeHonoursOwners(atPath: existing)
    }

    private static func isAbsoluteWithoutClimbing(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.split(separator: "/").contains("..")
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
