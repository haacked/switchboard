import Foundation
import Testing

@testable import SwitchboardCore

/// Builds a long history and times the replay that `Service.load` runs, with and without snapshots. It
/// runs only with SB_BENCH=<sessions>x<events>, and keeps the database in
/// SB_BENCH_HOME when that is set.
@Suite struct ReplayBenchmark {
  static func comment(_ i: Int) -> PRComment {
    PRComment(
      id: "IC_\(i)", author: i % 2 == 0 ? "greptile-apps[bot]" : "reviewer", createdAt: "2026-10-01T10:00:00Z",
      body: String(repeating: "This change reads the flag cache without a lock, which can race. ", count: 14))
  }

  @Test(.enabled(if: ProcessInfo.processInfo.environment["SB_BENCH"] != nil))
  func replayTime() throws {
    let spec = ProcessInfo.processInfo.environment["SB_BENCH"]!.split(separator: "x").compactMap { Int($0) }
    let (sessions, perSession) = (spec[0], spec[1])
    let dir = try ProcessInfo.processInfo.environment["SB_BENCH_HOME"] ?? tempFolder()
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let store = try Store(path: "\(dir)/sb.db")
    let pr = PullRequest(id: "PR_1", number: 7, url: "https://github.com/a/b/pull/7", repo: "a/b", title: "A change")
    let prData: JSON = [
      "pr": try JSON(encoding: pr), "comments": try JSON(encoding: (0..<10).map(Self.comment)),
    ]
    let toolData: JSON = [
      "tool_name": "Bash", "tool_use_id": "t1", "tool_input": ["command": "swift build 2>&1 | tail -20"],
    ]
    let t0 = Date()
    for s in 0..<sessions {
      let session = Session(
        id: "s\(s)", name: "s\(s)", cwd: "/tmp", branch: "main", claudeSessionId: "u\(s)", created: 1)
      try store.save(session)
      for i in 0..<perSession {
        let kind = ["pr", "pr", "PreToolUse", "PostToolUse", "Stop"][i % 5]
        let data: JSON = kind == "pr" ? prData : kind == "Stop" ? ["last_assistant_message": "Done."] : toolData
        try store.append(Event(session: session.id, t: Int64(1000 + i), kind: kind, data: data))
      }
    }
    print("BENCH built in \(Date().timeIntervalSince(t0)) s")

    var start = Date()
    var count = 0
    for session in try store.sessions() {
      let events = try store.events(session: session.id)
      var replay = SessionReplay.replaying(events, session: session)
      count += events.count
      replay.restarted()
    }
    print("BENCH full replay of \(count) events: \(Date().timeIntervalSince(start)) s")

    for pass in ["builds the snapshots", "starts from them"] {
      start = Date()
      for session in try store.sessions() { try Snapshots.refresh(store, session, build: "bench") }
      print("BENCH \(pass): \(Date().timeIntervalSince(start)) s")
    }
  }
}
