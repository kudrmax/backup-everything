import Darwin
import Foundation
import Testing
@testable import BackupCore

/// A command may put into its output a hard link to a person's file (`ln`, `cp -al`): the link is another name of the same
/// file, so unlocking it would unlock the person's original.
struct FolderRemovalTests {
    private let temp: TempDirectory

    init() throws {
        temp = try TempDirectory()
    }

    private func linked(_ personal: URL) throws -> URL {
        let staging = try temp.directory("staging/output")
        let link = staging.appendingPathComponent(personal.lastPathComponent)
        #expect(Darwin.link(personal.path, link.path) == 0)
        return link
    }

    private func permissions(_ url: URL) throws -> Int? {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
    }

    private func isLocked(_ url: URL) throws -> Bool {
        try FileManager.default.attributesOfItem(atPath: url.path)[.immutable] as? Bool == true
    }

    @Test func removingAWorkFolderLeavesALinkedFileAsItIs() throws {
        defer { Permissions.removeTree(temp.url) }
        let personal = try temp.file("Documents/contract.pdf", "signed")
        #expect(chmod(personal.path, 0o400) == 0)
        _ = try linked(personal)
        #expect(chmod(temp.path("staging/output").path, 0o555) == 0)

        try FolderRemoval().remove(temp.path("staging").path)

        #expect(!temp.exists("staging"))
        #expect(try String(contentsOf: personal, encoding: .utf8) == "signed")
        #expect(try permissions(personal) == 0o400)
    }

    @Test func linkedFileProtectedByAnAccessListIsNotUnprotected() throws {
        let personal = try temp.file("Documents/contract.pdf", "signed")
        defer {
            try? Permissions.dropAccessList(personal)
            temp.remove()
        }
        try Permissions.denyDeleting(personal)
        let before = try #require(Permissions.accessList(of: personal))
        let link = try linked(personal)

        #expect(throws: FolderRemovalError.protectedLinkedFile(link.path)) {
            try FolderRemoval().remove(temp.path("staging").path)
        }
        #expect(Permissions.accessList(of: personal) == before)
        #expect(temp.exists("staging/output/contract.pdf"))
    }

    @Test func lockedLinkedFileIsNotUnlocked() throws {
        defer {
            Permissions.unlockTree(temp.url)
            temp.remove()
        }
        let personal = try temp.file("Documents/contract.pdf", "signed")
        let link = try linked(personal)
        try Permissions.lock(personal)

        #expect(throws: FolderRemovalError.protectedLinkedFile(link.path)) {
            try FolderRemoval().remove(temp.path("staging").path)
        }
        #expect(try isLocked(personal))
        #expect(temp.exists("staging/output/contract.pdf"))
        #expect(FolderRemovalError.protectedLinkedFile(link.path).localizedDescription.hasPrefix("“\(link.path)” is another name (a hard link)"))
    }

    @Test func lockedLinkedFileIsNotUnlockedToBeTrashed() throws {
        defer {
            Permissions.unlockTree(temp.url)
            temp.remove()
        }
        let personal = try temp.file("Documents/contract.pdf", "signed")
        let link = try linked(personal)
        try Permissions.lock(personal)

        #expect(throws: FolderRemovalError.protectedLinkedFile(link.path)) {
            try FolderRemoval().trash(temp.path("staging"), using: { _ in throw POSIXError(.EPERM) })
        }
        #expect(try isLocked(personal))
    }

    @Test func lockedFileWithASingleNameIsUnlockedAndRemoved() throws {
        defer { temp.remove() }
        let file = try temp.file("staging/output/a.md")
        try Permissions.denyDeleting(file)
        try Permissions.lock(file)

        try FolderRemoval().remove(temp.path("staging").path)

        #expect(!temp.exists("staging"))
    }
}
