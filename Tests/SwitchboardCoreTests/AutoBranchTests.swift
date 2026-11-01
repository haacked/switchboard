import Testing

@testable import SwitchboardCore

struct AutoBranchTests {
  @Test func slugsTheNameAndAddsTheSuffix() {
    #expect(NewSession.autoBranch(name: "Fix the Flaky Test!", suffix: "ab12") == "fix-the-flaky-test-ab12")
  }

  @Test func fallsBackToSessionWithoutAUsableName() {
    #expect(NewSession.autoBranch(name: nil, suffix: "ab12") == "session-ab12")
    #expect(NewSession.autoBranch(name: "  ✨ ", suffix: "ab12") == "session-ab12")
  }

  @Test func capsTheSlugLength() {
    let branch = NewSession.autoBranch(name: String(repeating: "word ", count: 30), suffix: "ab12")
    #expect(branch.hasSuffix("-ab12"))
    #expect(!branch.contains("--"))
    #expect(branch.count <= 45)
  }

  @Test func defaultSuffixIsFourHexCharacters() {
    let branch = NewSession.autoBranch(name: "x")
    #expect(branch.range(of: #"^x-[0-9a-f]{4}$"#, options: .regularExpression) != nil)
  }

  @Test func skipsABranchThatExists() {
    var suffixes = ["aaaa", "bbbb"].makeIterator()
    let branch = NewSession.freeAutoBranch(
      prefix: "p/", name: "x", exists: { $0 == "p/x-aaaa" }, suffix: { suffixes.next()! })
    #expect(branch == "p/x-bbbb")
  }
}
