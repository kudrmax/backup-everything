import Foundation
import Testing
@testable import BackupCore

struct GlobPatternTests {
    @Test(arguments: [
        ("*.vcf", "Work*"),
        ("Passwords*.csv", "*-export.csv"),
        ("*", ""),
        ("a*b*c", "*c"),
        ("data-?.json", "data-[0-9].json"),
        ("[!a]*", "b*"),
        ("[!a]x", "[!b]x"),
        ("[a-c]x", "[!ab]x"),
        ("REPORT.CSV", "report.csv"),
        ("\\*.txt", "[*].txt"),
        ("[]]", "]"),
        ("[a-]", "-"),
        ("[", "["),
        ("a\\", "a\\"),
        ("[\\]]", "]"),
        ("[a\\-z]", "-"),
        ("[a-\\z]", "m"),
    ])
    func patternsThatMatchACommonNameOverlap(first: String, second: String) {
        #expect(GlobPattern(first).overlaps(GlobPattern(second)))
        #expect(GlobPattern(second).overlaps(GlobPattern(first)))
    }

    @Test(arguments: [
        ("*.vcf", "*.csv"),
        ("Work*", "Home*"),
        ("data-?.json", "data-??.json"),
        ("[a-c]x", "[d-f]x"),
        ("[a-c]x", "[!a-c]x"),
        ("[!a]", "a"),
        ("[a-cx-z]1", "[d-w]1"),
        ("\\*.txt", "a.txt"),
        ("[z-a]", "z"),
        ("a", ""),
        ("a*", ""),
        ("[a\\-z]", "m"),
    ])
    func patternsWithoutACommonNameDoNotOverlap(first: String, second: String) {
        #expect(!GlobPattern(first).overlaps(GlobPattern(second)))
        #expect(!GlobPattern(second).overlaps(GlobPattern(first)))
    }

    @Test func everyNameMatchedByTwoPatternsMakesThemOverlap() {
        let patterns = ["*", "*.csv", "Passwords*", "*-export.csv", "?????", "[a-m]*", "[!p]*.csv", "*x*", "data-[0-9]*", "*.[cj]s*", "\\[*"]
        let names = ["Passwords.csv", "passwords-export.csv", "a.csv", "x", "hello", "data-1.json", "data-x.js", "[draft].csv", "zz-export.csv", "", "mix.css"]
        for first in patterns {
            for second in patterns {
                let common = names.contains { GlobPattern(first).matches($0) && GlobPattern(second).matches($0) }
                if common {
                    #expect(GlobPattern(first).overlaps(GlobPattern(second)), "\(first) and \(second)")
                }
            }
        }
    }

    @Test func longPatternsAreComparedQuickly() {
        let many = String(repeating: "*a", count: 200)
        #expect(!GlobPattern(many + "b").overlaps(GlobPattern(many + "c")))
    }
}
