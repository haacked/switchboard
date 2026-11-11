import Foundation
import Testing

@testable import SwitchboardCore

@Suite struct ProcessTests {
  /// Swift Testing runs tests on the cooperative pool, which has one thread
  /// per CPU, and integration tests call runCommand from there in parallel.
  @Test(
    .timeLimit(.minutes(1))) func runsMoreCommandsAtOnceThanThereAreCPUs() async
  {
    let count = 2 * ProcessInfo.processInfo.activeProcessorCount
    let statuses = await withTaskGroup(of: Int32.self) { group in
      for _ in 0..<count {
        group.addTask { (try? runCommand("/bin/sleep", ["0.2"]))?.status ?? -1 }
      }
      return await group.reduce(into: [Int32]()) { $0.append($1) }
    }
    #expect(statuses == Array(repeating: 0, count: count))
  }

  @Test(.timeLimit(.minutes(1))) func endsACommandThatOutlastsItsTimeout() throws {
    let start = Date()
    let r = try runCommand("/bin/sleep", ["30"], timeout: 0.3)
    #expect(r.status != 0)
    #expect(Date().timeIntervalSince(start) < 10)
  }

  @Test func leavesACommandThatFinishesInTimeAlone() throws {
    #expect(try runCommand("/bin/echo", ["hi"], timeout: 30).stdout == "hi\n")
  }
}

@Suite struct ShellQuoteTests {
  @Test(arguments: [
    ("", "''"), ("a b", "'a b'"), ("'", #"''\'''"#), ("it's", #"'it'\''s'"#), ("''", #"''\'''\'''"#),
    ("$HOME `id` \"x\"", "'$HOME `id` \"x\"'"), ("line\nbreak", "'line\nbreak'"), ("héllo ✓ 日本", "'héllo ✓ 日本'"),
    ("e\u{301}", "'e\u{301}'"), ("a\\b", "'a\\b'"),
  ])
  func putsTheTextInSingleQuotes(text: String, quoted: String) {
    #expect(Array(shellQuote(text).utf8) == Array(quoted.utf8))
  }

  /// A `'` and the combining character after it are one character.
  @Test(arguments: ["'\u{301}; touch /tmp/sb-injected; '\u{301}", "'\u{FE0F}x", "a'\u{200D}b", "e\u{301}'"])
  func escapesAQuoteBeforeACombiningCharacter(text: String) {
    let quoted = shellQuote(text)

    #expect(
      !quoted.dropFirst().dropLast().replacingOccurrences(of: "'\\''", with: "", options: .literal).unicodeScalars
        .contains("'"))
  }

  /// The shell reads the command from stdin, because `Process` decomposes the characters of an
  /// argument.
  @Test(
    .timeLimit(.minutes(1)),
    arguments: [
      "'\u{301}; echo INJECTED; '\u{301}", "'\u{FE0F}x", "a'\u{200D}b", "e\u{301}'", "'", "it's", "'\\''", "",
      "$(echo INJECTED)", "`echo INJECTED`", "a; echo INJECTED", "line\nbreak", "héllo ✓ 日本", "\\", "%s", "-n",
    ])
  func aShellReadsTheQuotedTextAsTheSameBytes(text: String) throws {
    let r = try runCommand("/bin/sh", [], input: Data("printf %s \(shellQuote(text))\n".utf8), timeout: 30)

    #expect(r.status == 0)
    #expect(Array(r.stdout.utf8) == Array(text.utf8))
    #expect(r.stderr.isEmpty)
  }
}
