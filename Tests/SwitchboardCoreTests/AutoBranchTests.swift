import Testing

@testable import SwitchboardCore

struct AutoBranchTests {
  private func branch(_ name: String?, prefix: String = "", taken: Set<String> = [], suffixes: [String] = ["ab12"])
    -> String
  {
    var next = suffixes.makeIterator()
    return NewSession.freeAutoBranch(
      prefix: prefix, name: name, exists: { taken.contains($0) }, suffix: { next.next()! })
  }

  @Test func slugsTheNameWithoutASuffix() {
    #expect(branch("Fix the Flaky Test!") == "fix-the-flaky-test")
    #expect(branch("x", prefix: "p/") == "p/x")
  }

  @Test func fallsBackToSessionWithoutAUsableName() {
    #expect(branch(nil) == "session")
    #expect(branch("  ✨ ") == "session")
  }

  @Test func capsTheSlugLength() {
    let name = branch(String(repeating: "word ", count: 30))
    #expect(!name.hasSuffix("-"))
    #expect(name.count <= 40)
  }

  @Test func addsASuffixOnlyWhenTheNameExists() {
    #expect(branch("x", prefix: "p/", taken: ["p/x"]) == "p/x-ab12")
    #expect(branch("x", prefix: "p/", taken: ["p/x", "p/x-aaaa"], suffixes: ["aaaa", "bbbb"]) == "p/x-bbbb")
  }

  @Test func defaultSuffixIsFourHexCharacters() {
    let name = NewSession.freeAutoBranch(prefix: "", name: "x", exists: { $0 == "x" })
    #expect(name.range(of: #"^x-[0-9a-f]{4}$"#, options: .regularExpression) != nil)
  }
}
