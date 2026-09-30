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
