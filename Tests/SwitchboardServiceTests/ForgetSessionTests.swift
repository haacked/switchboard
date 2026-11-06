import Foundation
import Testing

/// `forgetSession` refuses to delete a session that holds an open to-do. These tests read the service's source.
/// A second caller of `store.delete(session:)` would delete records without that check.
@Suite struct ForgetSessionTests {
  static let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("Sources/SwitchboardService")

  struct DeleteCall: CustomStringConvertible {
    let file: String
    let line: Int
    /// The name of the nearest `func` above the call, or nil when no function precedes it.
    let function: String?

    var description: String { "\(file):\(line) in \(function ?? "no function")" }
  }

  static func swiftFiles() throws -> [URL] {
    let names = try FileManager.default.contentsOfDirectory(atPath: sources.path)
    return names.filter { $0.hasSuffix(".swift") }.sorted().map { sources.appendingPathComponent($0) }
  }

  /// Each call of `delete(session:)` on any receiver in the service's sources, outside comments, with the function
  /// that contains it.
  static func deleteCalls() throws -> [DeleteCall] {
    try swiftFiles().flatMap {
      try deleteCalls(in: String(contentsOf: $0, encoding: .utf8), file: $0.lastPathComponent)
    }
  }

  /// The calls in one file's text. The patterns match against the whole text. A call that wraps after
  /// `delete(` still counts.
  static func deleteCalls(in text: String, file: String) throws -> [DeleteCall] {
    let call = try Regex(#"\.delete\(\s*session\s*:"#)
    let function = try Regex(#"\bfunc\s+([A-Za-z_][A-Za-z0-9_]*)"#)
    let lines = text.components(separatedBy: "\n")
    func lineNumber(_ index: String.Index) -> Int { text[..<index].filter { $0 == "\n" }.count + 1 }
    func isComment(_ line: Int) -> Bool { lines[line - 1].trimmingCharacters(in: .whitespaces).hasPrefix("//") }
    let functions = text.matches(of: function).compactMap { match in
      isComment(lineNumber(match.range.lowerBound))
        ? nil : match.output[1].substring.map { (start: match.range.lowerBound, name: String($0)) }
    }
    return text.matches(of: call).compactMap { match in
      let line = lineNumber(match.range.lowerBound)
      if isComment(line) { return nil }
      let enclosing = functions.last { $0.start < match.range.lowerBound }?.name
      return DeleteCall(file: file, line: line, function: enclosing)
    }
  }

  @Test func deleteCallsFindsACallThatWrapsAfterTheParenthesis() throws {
    let text = "func purge() {\n  try store.delete(\n    session: id, resolving: [])\n}\n"

    let calls = try Self.deleteCalls(in: text, file: "Purge.swift")

    #expect(calls.map(\.description) == ["Purge.swift:2 in purge"])
  }

  @Test func theServiceHasSourceFiles() throws {
    #expect(!(try Self.swiftFiles()).isEmpty)
  }

  @Test func forgetSessionIsDefinedOnce() throws {
    let definition = try Regex(#"\bfunc\s+forgetSession\s*\("#)
    let count = try Self.swiftFiles().map { try String(contentsOf: $0, encoding: .utf8) }
      .map { $0.matches(of: definition).count }.reduce(0, +)

    #expect(count == 1)
  }

  @Test func onlyForgetSessionDeletesASessionRecord() throws {
    let calls = try Self.deleteCalls()

    #expect(!calls.isEmpty)
    let elsewhere = calls.filter { $0.function != "forgetSession" }
    #expect(elsewhere.isEmpty, "store.delete(session:) is called outside forgetSession at \(elsewhere)")
  }
}
