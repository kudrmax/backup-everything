import Testing
@testable import BackupCore

struct ExcludePatternTests {
    @Test func isCaseSensitive() {
        #expect(!ExcludePattern("Cache").matches("cache", name: "cache"))
        #expect(ExcludePattern("Cache").matches("x/Cache", name: "Cache"))
    }

    @Test func bracketPatternMatchesBothCases() {
        #expect(ExcludePattern("[cC]ache").matches("cache", name: "cache"))
        #expect(ExcludePattern("[cC]ache").matches("Cache", name: "Cache"))
    }

    @Test func patternWithoutSlashMatchesTheNameAtAnyDepth() {
        #expect(ExcludePattern("*.tmp").matches("a/b/x.tmp", name: "x.tmp"))
        #expect(!ExcludePattern("*.tmp").matches("a/b/x.txt", name: "x.txt"))
    }

    @Test func patternWithSlashMatchesTheEndOfThePathOnComponentBoundaries() {
        #expect(ExcludePattern("a/b").matches("a/b", name: "b"))
        #expect(ExcludePattern("a/b").matches("x/a/b", name: "b"))
        #expect(!ExcludePattern("a/b").matches("xa/b", name: "b"))
    }

    @Test func leadingSlashAnchorsAtTheTop() {
        #expect(ExcludePattern("/a/b").matches("a/b", name: "b"))
        #expect(!ExcludePattern("/a/b").matches("x/a/b", name: "b"))
    }

    @Test func trailingSlashIsIgnored() {
        #expect(ExcludePattern("cache/").matches("x/cache", name: "cache"))
    }

    /// As in rsync: `*` stays inside one name, `**` crosses folders.
    @Test func singleStarStaysInOneNameDoubleStarCrossesFolders() {
        #expect(ExcludePattern("build/*.o").matches("build/x.o", name: "x.o"))
        #expect(!ExcludePattern("build/*.o").matches("build/sub/y.o", name: "y.o"))
        #expect(ExcludePattern("build/**.o").matches("build/sub/y.o", name: "y.o"))
        #expect(ExcludePattern("/build/**").matches("build/sub/y.o", name: "y.o"))
        #expect(!ExcludePattern("/a?b").matches("a/b", name: "b"))
    }
}
