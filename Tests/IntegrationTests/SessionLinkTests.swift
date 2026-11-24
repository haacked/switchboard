import Foundation
import SwitchboardCore
import Testing

/// Example Slack links. The workspace, channels, and ts values are made up.
enum SlackExample {
  static let channel = "C0EXAMPLE01"
  static let dmChannel = "D0EXAMPLE01"
  static let rootTs = "1794965000.000100"
  static let rootP = "p1794965000000100"
  static let replyTs = "1794965246.462679"
  static let replyP = "p1794965246462679"

  static let root = "https://example.slack.com/archives/\(channel)/\(rootP)"
  /// A reply in the root's thread, in the form Slack's "Copy link" gives.
  static let reply = "https://example.slack.com/archives/\(channel)/\(replyP)?thread_ts=\(rootTs)&cid=\(channel)"
  /// The message of the Evidence sample of a `slack_send_message` result.
  static let dm = "https://example.slack.com/archives/\(dmChannel)/\(replyP)"

  static let sendTool = "mcp__claude_ai_Slack__slack_send_message"
  static let sendInput: JSON = ["channel_id": "U0EXAMPLE01", "message": "Hey, a heads-up about the flag cache"]
}

extension Instance {
  /// The `tool_response` of `slack_send_message`: an MCP content array whose one text block holds the result as
  /// JSON text, as the Evidence sample in sb.db has it.
  static func slackSendResponse(link: String, channel: String, ts: String) -> JSON {
    let result: JSON = [
      "message_link": .string(link), "message_context": ["message_ts": .string(ts), "channel_id": .string(channel)],
    ]
    return [["type": "text", "text": .string(result.text)]]
  }

  /// Sends a hook of the Slack connector's send tool for the session, as `sb hook` does for a local claude, and
  /// returns the time that sbd recorded for it. sbd folds the hook before it answers.
  @discardableResult
  func postSlackSendHook(
    _ id: String, kind: String = "PostToolUse", toolName: String = SlackExample.sendTool,
    input: JSON = SlackExample.sendInput, response: JSON?, agent: String? = nil
  ) throws -> Int64 {
    let claudeSessionId = try get(id).claudeSessionId
    let toolUseId = "toolu_\(UUID().uuidString)"
    var payload: [String: JSON] = [
      "hook_event_name": .string(kind), "session_id": .string(claudeSessionId), "tool_name": .string(toolName),
      "tool_use_id": .string(toolUseId), "tool_input": input, "permission_mode": "default", "cwd": "/tmp",
      "duration_ms": 640,
    ]
    if let response { payload["tool_response"] = response }
    if let agent { payload["agent_id"] = .string(agent) }
    _ = try client.call("hook", ["session": .string(id), "payload": .object(payload)])
    let event = try #require(try events(id).last { $0.data["tool_use_id"]?.string == toolUseId })
    return event.t
  }

  /// Sends a send hook whose result names the message at `link`, and returns the time that sbd recorded for it.
  @discardableResult
  func postSlackSend(_ id: String, link: String, channel: String, ts: String) throws -> Int64 {
    try postSlackSendHook(id, response: Instance.slackSendResponse(link: link, channel: channel, ts: ts))
  }

  /// Sends a UserPromptSubmit hook with the prompt for the session, and returns the time that sbd recorded for it.
  @discardableResult
  func postPromptHook(_ id: String, prompt: String) throws -> Int64 {
    let claudeSessionId = try get(id).claudeSessionId
    let payload: JSON = [
      "hook_event_name": "UserPromptSubmit", "session_id": .string(claudeSessionId), "prompt": .string(prompt),
      "permission_mode": "default", "cwd": "/tmp", "prompt_id": .string(UUID().uuidString),
    ]
    _ = try client.call("hook", ["session": .string(id), "payload": payload])
    let event = try #require(
      try events(id).last { $0.kind == "UserPromptSubmit" && $0.data["prompt"]?.string == prompt })
    return event.t
  }

  /// The `links` of `sb get --json`, or nil when the key is missing.
  func sessionLinks(_ id: String) throws -> [JSON]? { try summaryJSON(id)["links"]?.array }
}

/// sbd finds the Slack, Linear, Notion, Google, and Grafana links in a session's prompts and the link of each
/// Slack message that the session sends, lists them in `sb get` and `sb ls`, and keeps them across a restart.
@Suite(.blocking(timeLimit: .seconds(120))) struct SessionLinkTests {
  @Test func aSessionWithoutLinksHasNoLinksKey() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "flags-cache")

    #expect(try sbd.sessionLinks(s.id) == nil)
  }

  /// The launch prompt runs through the claude stub's real UserPromptSubmit.
  @Test func aPromptWithASlackThreadLinkListsItInSbGetJson() throws {
    let sbd = try Instance()
    let url = SlackExample.reply

    let s = try sbd.new(prompt: "Review \(url)", name: "flags-cache")

    let links = try sbd.waitFor("the prompt's link", fetch: { try sbd.sessionLinks(s.id) }) { !$0.isEmpty }
    let prompt = try #require(try sbd.events(s.id).first { $0.kind == "UserPromptSubmit" })
    let link = try #require(links.first)
    #expect(links.count == 1)
    #expect(link["kind"]?.string == "slack")
    #expect(link["url"]?.string == url)
    #expect(link["channel"]?.string == SlackExample.channel)
    #expect(link["thread"]?.string == SlackExample.rootTs)
    #expect(link["by"]?.string == "found")
    #expect(link["t"]?.int.map(Int64.init) == prompt.t)
    #expect(link["id"]?.string?.hasPrefix("f") == true)
    #expect(link["title"]?.string == "Slack thread in \(SlackExample.channel)")
  }

  @Test func aMessageSentThroughTheSlackConnectorListsItsLink() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "flags-cache")

    let t = try sbd.postSlackSend(
      s.id, link: SlackExample.dm, channel: SlackExample.dmChannel, ts: SlackExample.replyTs)

    let links = try #require(try sbd.sessionLinks(s.id))
    let link = try #require(links.first)
    #expect(links.count == 1)
    #expect(link["url"]?.string == SlackExample.dm)
    #expect(link["kind"]?.string == "slack")
    #expect(link["channel"]?.string == SlackExample.dmChannel)
    #expect(link["thread"]?.string == SlackExample.replyTs)
    #expect(link["by"]?.string == "found")
    #expect(link["t"]?.int.map(Int64.init) == t)
  }

  /// The last valid send proves that sbd folded the hooks before it, instead of skipping them.
  @Test func aDraftAFailureAndAnErrorTextAddNoLink() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "flags-cache")
    let draft: JSON = [
      [
        "type": "text",
        "text": #"{"channel_link":"https:\/\/example.slack.com\/archives\/D0EXAMPLE01","draft_id":"Dr0EXAMPLE01"}"#,
      ]
    ]
    let sent = Instance.slackSendResponse(
      link: SlackExample.dm, channel: SlackExample.dmChannel, ts: SlackExample.replyTs)

    try sbd.postSlackSendHook(s.id, toolName: "\(SlackExample.sendTool)_draft", response: draft)
    try sbd.postSlackSendHook(s.id, kind: "PostToolUseFailure", response: sent)
    try sbd.postSlackSendHook(s.id, response: [["type": "text", "text": "Error: channel_not_found"]])
    let noneYet = try sbd.sessionLinks(s.id)
    try sbd.postSlackSend(s.id, link: SlackExample.root, channel: SlackExample.channel, ts: SlackExample.rootTs)

    #expect(noneYet == nil)
    #expect(try sbd.sessionLinks(s.id)?.compactMap { $0["url"]?.string } == [SlackExample.root])
  }

  @Test func aGitHubLinkAndAnOtherURLInAPromptAddNoLink() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "flags-cache")

    try sbd.postPromptHook(s.id, prompt: "See https://github.com/example/widgets/pull/42 and https://example.com/doc")
    let noneYet = try sbd.sessionLinks(s.id)
    try sbd.postPromptHook(s.id, prompt: "And \(SlackExample.root)")

    #expect(noneYet == nil)
    #expect(try sbd.sessionLinks(s.id)?.compactMap { $0["url"]?.string } == [SlackExample.root])
  }

  @Test func aPromptAndASendToOneThreadListOneLink() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "flags-cache")
    let first = try sbd.postPromptHook(s.id, prompt: "Reply in \(SlackExample.root)")
    try sbd.advanceClock(60_000)

    let second = try sbd.postSlackSend(
      s.id, link: SlackExample.reply, channel: SlackExample.channel, ts: SlackExample.replyTs)

    let links = try #require(try sbd.sessionLinks(s.id))
    #expect(second > first)
    #expect(links.count == 1)
    #expect(links.first?["url"]?.string == SlackExample.root)
    #expect(links.first?["t"]?.int.map(Int64.init) == first)
  }

  @Test func oneOfEachKnownTypeListsWithItsKind() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "flags-cache")
    let linear = "https://linear.app/example/issue/ENG-123/fix-the-flag-cache"
    let notion = "https://www.notion.so/example/Q4-Plan-0123456789abcdef0123456789abcdef"
    let google = "https://docs.google.com/document/d/1AbCdEfGhIjKlMnOpQrStUvWxYz_-0123456789/edit?usp=sharing"
    let grafana = "https://grafana.example.com/d/abc123/api-latency?orgId=1&from=now-6h&to=now"

    try sbd.postPromptHook(
      s.id, prompt: "Issue \(linear), plan <\(notion)|plan>, doc [doc](\(google)), and \(grafana).")

    let links = try #require(try sbd.sessionLinks(s.id))
    #expect(links.compactMap { $0["url"]?.string } == [linear, notion, google, grafana])
    #expect(links.compactMap { $0["kind"]?.string } == ["linear", "notion", "google", "grafana"])
    #expect(links.allSatisfy { $0["channel"] == nil && $0["thread"] == nil })
  }

  @Test func linksSurviveARestartWithTheSameIds() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "flags-cache")
    try sbd.postPromptHook(s.id, prompt: "Review \(SlackExample.root) and https://linear.app/example/issue/ENG-123")
    try sbd.postSlackSend(s.id, link: SlackExample.dm, channel: SlackExample.dmChannel, ts: SlackExample.replyTs)
    let before = try #require(try sbd.sessionLinks(s.id))

    sbd.stopSbd()
    try sbd.startSbd()

    #expect(before.count == 3)
    #expect(try sbd.sessionLinks(s.id) == before)
  }

  @Test func sbGetPrintsALinePerLink() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "flags-cache")
    try sbd.postPromptHook(s.id, prompt: "Review \(SlackExample.root)")
    let id = try #require(try sbd.sessionLinks(s.id)?.first?["id"]?.string)
    try sbd.advanceClock(60_000)
    let linear = "https://linear.app/example/issue/ENG-123"
    try sbd.postPromptHook(s.id, prompt: "Also \(linear)")

    let text = try sbd.sb("get", s.id)

    let lines = text.split(separator: "\n").map(String.init).filter { $0.hasPrefix("  link: ") }
    #expect(lines.count == 2, "\(lines)")
    #expect(lines.first?.contains(linear) == true, "\(lines)")
    let line = try #require(lines.last)
    #expect(
      line.hasPrefix("  link: \(id)  Slack thread in \(SlackExample.channel)  \(SlackExample.root)  (found "),
      "\(line)")
    #expect(line.hasSuffix(" ago)"), "\(line)")
  }

  @Test func sbLsJsonCarriesLinks() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "flags-cache")
    let other = try sbd.new(name: "other")

    try sbd.postPromptHook(s.id, prompt: "Review \(SlackExample.root)")

    let rows = try #require(JSON.parse(try sbd.sb("ls", "--json"))?.array)
    let mine = try #require(rows.first { $0["id"]?.string == s.id })
    let theirs = try #require(rows.first { $0["id"]?.string == other.id })
    #expect(mine["links"]?.array?.compactMap { $0["url"]?.string } == [SlackExample.root])
    #expect(mine["links"]?.array?.first?["kind"]?.string == "slack")
    #expect(theirs["links"] == nil)
  }
}
