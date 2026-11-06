import Foundation
import Testing

/// `forgetSession` refuses to delete a session that holds an open to-do. These tests read the service's source,
/// because a second caller of `store.delete(session:)` would delete records without that check.
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

  /// Each call of `delete(session:)` on any receiver, outside comments, with the function that contains it.
  static func deleteCalls() throws -> [DeleteCall] {
    let call = try Regex(#"\.delete\(\s*session\s*:"#)
    let function = try Regex(#"\bfunc\s+([A-Za-z_][A-Za-z0-9_]*)"#)
    var calls: [DeleteCall] = []
    for file in try swiftFiles() {
      var current: String?
      let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
      for (index, line) in lines.enumerated() {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("//") { continue }
        if let match = line.firstMatch(of: function), let name = match.output[1].substring {
          current = String(name)
        }
        if line.contains(call) {
          calls.append(DeleteCall(file: file.lastPathComponent, line: index + 1, function: current))
        }
      }
    }
    return calls
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
