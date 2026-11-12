import Foundation
import SwitchboardCore
import Testing

/// Routes for Fixtures/gh-api-stub, which answers `gh api` from files in
/// `$SB_HOME/gh-api`.
extension Instance {
  /// A private sbd whose poller asks `github`, with Fixtures/gh-api-stub as
  /// its gh. Polls run only when a test asks.
  static func withReplyStub(_ github: FakeGitHub) throws -> Instance {
    try Instance(config: [
      "github": [
        "gh": .string("\(FakeGitHub.fixtures)/gh-api-stub"), "url": .string(github.url), "pollSeconds": 0,
      ],
      "tickSeconds": 1,
    ])
  }

  /// The stub's file base for a `gh api` call. The stub maps the path the
  /// same way: it drops a leading slash and the query, and turns each / into _.
  func ghRouteBase(_ method: String, _ path: String) -> String {
    var path = Substring(path)
    if path.hasPrefix("/") { path = path.dropFirst() }
    if let query = path.firstIndex(of: "?") { path = path[..<query] }
    return "\(home.path)/gh-api/\(method)_\(path.replacingOccurrences(of: "/", with: "_"))"
  }

  private func writeGhRouteFile(_ method: String, _ path: String, _ suffix: String, _ text: String) throws {
    try FileManager.default.createDirectory(atPath: "\(home.path)/gh-api", withIntermediateDirectories: true)
    try text.write(toFile: "\(ghRouteBase(method, path)).\(suffix)", atomically: true, encoding: .utf8)
  }

  /// Makes the stub print `json` for the call. It also removes a failure
  /// that `ghRouteFails` set, so the route answers again.
  func ghRoute(_ method: String, _ path: String, json: JSON) throws {
    try ghRoute(method, path, text: json.text)
  }

  /// Makes the stub print one compact JSON value per line for the call, as
  /// gh prints `--jq '.[] | @json'`.
  func ghRoute(_ method: String, _ path: String, lines: [JSON]) throws {
    try ghRoute(method, path, text: lines.map { $0.text + "\n" }.joined())
  }

  func ghRoute(_ method: String, _ path: String, text: String) throws {
    let base = ghRouteBase(method, path)
    for suffix in ["error", "status"] { try? FileManager.default.removeItem(atPath: "\(base).\(suffix)") }
    try writeGhRouteFile(method, path, "json", text)
  }

  /// Makes the stub print `stderr` and exit with `status` for the call.
  func ghRouteFails(_ method: String, _ path: String, stderr: String, status: Int32 = 1) throws {
    try writeGhRouteFile(method, path, "status", String(status))
    try writeGhRouteFile(method, path, "error", stderr)
  }

  /// Makes the stub hold the call until `openGhGate` writes a line to the
  /// FIFO. It returns the FIFO's path.
  @discardableResult
  func ghGate(_ method: String, _ path: String) throws -> String {
    try FileManager.default.createDirectory(atPath: "\(home.path)/gh-api", withIntermediateDirectories: true)
    let gate = "\(ghRouteBase(method, path)).gate"
    guard mkfifo(gate, 0o600) == 0 else { throw TestError(description: "mkfifo failed") }
    return gate
  }

  /// Lets one held call go on. Opening the FIFO for writing blocks until the
  /// stub opens it for reading, so a test calls this only once `ghCalls`
  /// shows the call.
  func openGhGate(_ gate: String) throws {
    let writer = try #require(FileHandle(forWritingAtPath: gate))
    writer.write(Data("go\n".utf8))
    try writer.close()
  }

  /// Each `-f body=` value that the stub received, oldest first, byte for byte.
  func ghBodies() -> [String] {
    let dir = "\(home.path)/gh-bodies"
    let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
    return names.compactMap(Int.init).sorted().compactMap {
      try? String(contentsOfFile: "\(dir)/\($0)", encoding: .utf8)
    }
  }
}
