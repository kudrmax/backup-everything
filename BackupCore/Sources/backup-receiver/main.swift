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
