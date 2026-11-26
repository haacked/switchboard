import Foundation
import SwitchboardCore
import Testing

/// Values that the Slack thread poll suites share.
enum SlackFixtures {
  static let config: [String: JSON] = ["slack": ["pollSeconds": 1200]]
  static let other = "U0OTHER"
  /// The stub's default profile id.
  static let selfId = "U0EXAMPLESELF"
  static let secondChannel = "C0EXAMPLE02"
  static let secondTs = "1794965100.000200"
  static let secondThread = "https://example.slack.com/archives/C0EXAMPLE02/p1794965100000200"

  /// A little more than `slack.pollSeconds` of 1200, so a scan is due whether "due" means after or at.
  static let step: Int64 = 20 * 60_000 + 1000

  /// A Slack ts for a time in ms.
  static func ts(_ ms: Int64) -> String { String(format: "%lld.%06lld", ms / 1000, (ms % 1000) * 1000) }
}

/// Checks the condition every 0.2 s for the seconds, and fails at the first check that is false.
func stays(_ what: String, for seconds: Double = 2, _ condition: () throws -> Bool) throws {
  let deadline = Date().addingTimeInterval(seconds)
  while Date() < deadline {
    try #require(try condition(), "\(what)")
    usleep(200_000)
  }
}

/// A reply in a thread fixture of the stub's `<slack-threads>` branch.
struct SlackReply {
  var ts: String
  var user: String
  var name: String
}

/// The files of the stub's `<slack-self>` and `<slack-threads>` branches in SB_HOME. Every assumption about their
/// format lives here.
extension Instance {
  /// The runs that the stub logged in the file, oldest first, each as its arguments. The stub writes each argument
  /// followed by a NUL, so a run starts at each `-p`.
  func slackRuns(_ file: String) -> [[String]] {
    let text = (try? String(contentsOfFile: "\(home.path)/\(file)", encoding: .utf8)) ?? ""
    var runs: [[String]] = []
    // The text after the last NUL is empty, or a record that the stub is writing.
    for record in text.split(separator: "\0", omittingEmptySubsequences: false).dropLast().map(String.init) {
      if record == "-p" {
        runs.append([record])
      } else if !runs.isEmpty {
        runs[runs.count - 1].append(record)
      }
    }
    return runs
  }

  /// The threads that each `<slack-threads>` input asked for, oldest first, as `[{channel_id, message_ts, oldest?}]`.
  func slackAsks() -> [[JSON]] {
    let text = (try? String(contentsOfFile: "\(home.path)/slack-inputs.log", encoding: .utf8)) ?? ""
    return text.components(separatedBy: "<slack-threads>").dropFirst().compactMap { block in
      guard let end = block.range(of: "</slack-threads>") else { return nil }
      return JSON.parse(String(block[..<end.lowerBound]))?.array
    }
  }

  func writeSlackThread(
    channel: String = SlackExample.channel, ts: String = SlackExample.rootTs, _ replies: [SlackReply]
  ) throws {
    let json: JSON = [
      "replies": .array(replies.map { ["ts": .string($0.ts), "user": .string($0.user), "name": .string($0.name)] })
    ]
    try json.text.write(toFile: "\(home.path)/slack-thread-\(channel)-\(ts).json", atomically: true, encoding: .utf8)
  }

  func writeSlackSwitch(_ name: String, _ text: String = "") throws {
    try text.write(toFile: "\(home.path)/\(name)", atomically: true, encoding: .utf8)
  }

  func removeSlackSwitch(_ name: String) {
    try? FileManager.default.removeItem(atPath: "\(home.path)/\(name)")
  }

  func slackFileExists(_ name: String) -> Bool {
    FileManager.default.fileExists(atPath: "\(home.path)/\(name)")
  }

  /// Adds the link by hand and returns it as `sb link add --json` lists it.
  func addLink(_ session: String, _ url: String) throws -> JSON {
    let summary = try #require(JSON.parse(try sb(["link", "add", "--json", session, url])))
    return try #require(summary["links"]?.array?.first { $0["url"]?.string == url }, "no link to \(url)")
  }

  /// The thread's `slack_threads` row as sbd stored it, read with sqlite3 while sbd runs.
  func slackThreadRow(channel: String = SlackExample.channel, thread: String = SlackExample.rootTs) throws -> JSON? {
    let r = try runCommand(
      "/usr/bin/sqlite3", ["-cmd", ".timeout 5000", home.database, "SELECT json FROM slack_threads"])
    try #require(r.status == 0, "\(r.stderr)")
    return r.stdout.split(separator: "\n").compactMap { JSON.parse(String($0)) }.first {
      $0["channel"]?.string == channel && $0["thread"]?.string == thread
    }
  }

  /// Moves the clock so a scan is due, and returns the earliest time that a poll after the move records as `read`.
  func advanceToPoll(by ms: Int64 = SlackFixtures.step) throws -> Int64 {
    let due = try now() + ms
    try advanceClock(ms)
    return due
  }
}
