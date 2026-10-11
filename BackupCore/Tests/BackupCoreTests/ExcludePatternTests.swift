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
}
