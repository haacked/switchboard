import Foundation
import SwitchboardCore
import Testing

@testable import SwitchboardService

private let url = "https://github.com/acme/widgets/pull/42#discussion_r5001"

private func postedReply() throws -> JSON {
  let target = ResolvedTarget(
    target: ReplyTarget(repo: "acme/widgets", pr: 42, kind: .reviewComment, id: 1001), root: 1001, author: "ann",
    path: "a.swift", line: 3, excerpt: "Why not use a guard?", url: url)
  let attempt = PostAttempt(
    ref: "summary:2", number: 1, target: target, text: "Good catch, fixed.", draftText: "Good catch, fixed.",
    label: "Reply to ann", outcome: .posting)
  return try attempt.eventData(posted: (url, 5001))
}

/// The UserPromptSubmit hook of a host session gives its posted replies to claude only when the hook is local.
@Suite struct DraftNoticeHostTests {
  private func prompt(stamped: Bool) throws -> (answer: String, heardThrough: Int64) {
    let home = Home(path: try makeShortTempFolder())
    defer { try? FileManager.default.removeItem(atPath: home.path) }
    let config: JSON = ["claude": "/usr/bin/false"]
    try config.text.write(toFile: home.config, atomically: true, encoding: .utf8)
    let service = try Service(home: home, sbPath: "/usr/bin/true")
    var session = Session(id: "s1", name: "s1", cwd: "/srv/repo", claudeSessionId: "u-s1", created: 5)
    session.host = "mini"
    session.started = true
    #expect(session.kind == .work)
    let data = try postedReply()
    let stamp = HostEventStamp(id: try #require(HostEventID("00000001700000000000-4242-0001")), host: "mini", t: 2_000)
    return try service.queue.sync {
      service.entries["s1"] = Service.Entry(session: session)
      _ = service.record("s1", DraftReplies.postedEvent, data)
      let args: JSON = ["session": "s1", "payload": ["hook_event_name": "UserPromptSubmit", "prompt": "next"]]
      let answer = try #require(try service.hook(args, stamp: stamped ? stamp : nil)).answer
      return (answer.text, service.entries["s1"]?.facts.draftReplies.heardThrough ?? -1)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func aHostHookLeavesThePostedReplyUnheard() throws {
    let (answer, heard) = try prompt(stamped: true)
    #expect(!answer.contains(url))
    #expect(heard == 0)
  }

  @Test(.timeLimit(.minutes(1)))
  func aLocalHookGivesThePostedReplyAndRecordsItHeard() throws {
    let (answer, heard) = try prompt(stamped: false)
    #expect(answer.contains(url))
    #expect(heard > 0)
  }
}
