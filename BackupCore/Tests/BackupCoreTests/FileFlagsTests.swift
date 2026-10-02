import Darwin
import Foundation
import Testing
@testable import BackupCore

/// SMB shares and NAS disks mark files with flags only the system may change (`SF_ARCHIVED`): changing the flags a person
/// sees must leave those as they are, or the file system refuses the whole change.
struct FileFlagsTests {
    /// A file system that refuses to change system flags for a person, and supports only `supported` of the others.
    private final class Disk {
        var flags: UInt32
        let supported: UInt32

        init(_ flags: UInt32, supported: UInt32 = UInt32(UF_SETTABLE)) {
            self.flags = flags
            self.supported = supported
        }

        func change(_ new: UInt32) -> Int32 {
            if (new ^ flags) & UInt32(SF_SETTABLE) != 0 { return EPERM }
            if new & UInt32(UF_SETTABLE) & ~supported != 0 { return EINVAL }
            flags = new
            return 0
        }
    }

    private let archived = UInt32(SF_ARCHIVED)

    @Test func systemFlagsOfTheTargetAreKept() throws {
        let disk = Disk(archived | UInt32(UF_HIDDEN))
        try FileFlags(current: disk.flags, change: disk.change).set(UInt32(UF_IMMUTABLE))
        #expect(disk.flags == archived | UInt32(UF_IMMUTABLE))
    }

    @Test func systemFlagsAreKeptWhenFlagsAreSetOneByOne() throws {
        let disk = Disk(archived, supported: UInt32(UF_HIDDEN | UF_IMMUTABLE))
        try FileFlags(current: disk.flags, change: disk.change).set(UInt32(UF_NODUMP | UF_HIDDEN))
        #expect(disk.flags == archived | UInt32(UF_HIDDEN))
    }

    @Test func nothingIsChangedWhenOnlySystemFlagsDiffer() throws {
        let disk = Disk(archived | UInt32(UF_HIDDEN))
        try FileFlags(current: disk.flags) { _ in EPERM }.set(UInt32(UF_HIDDEN))
        #expect(disk.flags == archived | UInt32(UF_HIDDEN))
    }

    @Test func refusalOfOneFlagIsAnError() {
        #expect(throws: POSIXError(.EPERM)) {
            try FileFlags(current: 0) { $0.nonzeroBitCount > 1 ? EINVAL : EPERM }.set(UInt32(UF_HIDDEN | UF_NODUMP))
        }
    }

    @Test func refusalToChangeWhatAPersonSeesIsAnError() {
        #expect(throws: POSIXError(.EPERM)) {
            try FileFlags(current: 0) { _ in EPERM }.set(UInt32(UF_HIDDEN))
        }
    }
}
