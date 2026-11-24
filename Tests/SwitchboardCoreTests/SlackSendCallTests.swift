import Foundation
import Testing

@testable import SwitchboardCore

let slackSendTool = "mcp__claude_ai_Slack__slack_send_message"

/// The `tool_response` of `slack_send_message`: an MCP content array whose one text block holds the result as
/// JSON text, as the Evidence sample in sb.db has it. A nil `channel` or `ts` leaves `message_context` out.
func slackSendResponse(link: String, channel: String? = LinkFixtures.dmChannel, ts: String? = LinkFixtures.replyTs)
  -> JSON
{
  var result: [String: JSON] = ["message_link": .string(link)]
  if let channel, let ts { result["message_context"] = ["message_ts": .string(ts), "channel_id": .string(channel)] }
  return [["type": "text", "text": .string(JSON.object(result).text)]]
}

/// A hook of the Slack connector's send tool, as sbd stores its payload.
func slackSendHook(
  _ t: Int64, kind: String = "PostToolUse", tool: String = slackSendTool,
  input: [String: JSON] = ["channel_id": "U0EXAMPLE01", "message": "Hey, a heads-up about the flag cache"],
  response: JSON? = slackSendResponse(link: LinkFixtures.slackDM), agent: String? = nil
) -> Event {
  artifactHook(t, kind: kind, tool: tool, input: input, response: response, agent: agent)
}

/// The Evidence sample's text block, verbatim, with the `\/` escapes that the connector writes.
private let sampleText =
  #"{"message_link":"https:\/\/example.slack.com\/archives\/D0EXAMPLE01\/p1794965246462679","message_context":{"message_ts":"1794965246.462679","channel_id":"D0EXAMPLE01"}}"#

private let sampleResponse: JSON = [["type": "text", "text": .string(sampleText)]]

/// The `_draft` tool's result shape from sb.db. It sent nothing.
private let draftResponse: JSON = [
  [
    "type": "text",
    "text": .string(
      #"{"channel_link":"https:\/\/example.slack.com\/archives\/D0EXAMPLE01","draft_id":"Dr0EXAMPLE01"}"#),
  ]
]

private let threadReply =
  "https://example.slack.com/archives/\(LinkFixtures.channel)/\(LinkFixtures.replyP)?thread_ts=\(LinkFixtures.rootTs)"

/// One hook that the send guard sees, and the link and thread it gives, or nil when it gives nothing.
struct SendCase: Sendable, CustomTestStringConvertible {
  var name: String
  var kind = "PostToolUse"
  var tool = slackSendTool
  var input: [String: JSON] = ["channel_id": "U0EXAMPLE01", "message": "Hey"]
  var response: JSON?
  var url: String? = nil
  var channel: String? = nil
  var thread: String? = nil

  var testDescription: String { name }

  func hook(agent: String? = nil) -> Event {
    slackSendHook(1000, kind: kind, tool: tool, input: input, response: response, agent: agent)
  }
}

private let accepted: [SendCase] = [
  SendCase(
    name: "the sb.db sample", response: sampleResponse, url: LinkFixtures.slackDM, channel: LinkFixtures.dmChannel,
    thread: LinkFixtures.replyTs),
  SendCase(
    name: "the result as a JSON object",
    response: [
      "message_link": .string(LinkFixtures.slackDM),
      "message_context": ["message_ts": .string(LinkFixtures.replyTs), "channel_id": .string(LinkFixtures.dmChannel)],
    ],
    url: LinkFixtures.slackDM, channel: LinkFixtures.dmChannel, thread: LinkFixtures.replyTs),
  SendCase(
    name: "an image block before the text block",
    response: .array([["type": "image", "data": "aGVsbG8=", "mimeType": "image/png"]] + sampleResponse.array!),
    url: LinkFixtures.slackDM, channel: LinkFixtures.dmChannel, thread: LinkFixtures.replyTs),
  SendCase(
    name: "no message_context", response: slackSendResponse(link: LinkFixtures.slackDM, channel: nil, ts: nil),
    url: LinkFixtures.slackDM, channel: LinkFixtures.dmChannel, thread: LinkFixtures.replyTs),
  /// The context names the message, not its thread, so `message_ts` is the reply's own ts.
  SendCase(
    name: "a reply whose link has thread_ts",
    response: slackSendResponse(link: threadReply, channel: LinkFixtures.channel, ts: LinkFixtures.replyTs),
    url: threadReply, channel: LinkFixtures.channel, thread: LinkFixtures.rootTs),
  /// `tool_input` is never read. A link without `thread_ts` is its own thread, whatever the input says.
  SendCase(
    name: "an input thread_ts is ignored",
    input: ["channel_id": .string(LinkFixtures.channel), "message": "Done", "thread_ts": .string(LinkFixtures.rootTs)],
    response: slackSendResponse(
      link: "https://example.slack.com/archives/\(LinkFixtures.channel)/\(LinkFixtures.replyP)",
      channel: LinkFixtures.channel, ts: LinkFixtures.replyTs),
    url: "https://example.slack.com/archives/\(LinkFixtures.channel)/\(LinkFixtures.replyP)",
    channel: LinkFixtures.channel, thread: LinkFixtures.replyTs),
  SendCase(
    name: "extra keys in the result",
    response: [
      [
        "type": "text",
        "text": .string(
          JSON.object([
            "ok": true, "message_link": .string(LinkFixtures.slackDM),
            "message_context": [
              "message_ts": .string(LinkFixtures.replyTs), "channel_id": .string(LinkFixtures.dmChannel),
              "team_id": "T0EXAMPLE01",
            ],
          ]).text),
      ]
    ],
    url: LinkFixtures.slackDM, channel: LinkFixtures.dmChannel, thread: LinkFixtures.replyTs),
]

private let refused: [SendCase] = [
  // 1. The event kind.
  SendCase(name: "PostToolUseFailure", kind: "PostToolUseFailure", response: sampleResponse),
  SendCase(name: "PreToolUse", kind: "PreToolUse", response: sampleResponse),
  SendCase(name: "PermissionRequest", kind: "PermissionRequest", response: sampleResponse),
  SendCase(name: "UserPromptSubmit", kind: "UserPromptSubmit", response: sampleResponse),
  // 2. The tool name, by string equality.
  SendCase(name: "the draft tool with its real result", tool: "\(slackSendTool)_draft", response: draftResponse),
  SendCase(name: "the draft tool with a send's result", tool: "\(slackSendTool)_draft", response: sampleResponse),
  SendCase(name: "the read-thread tool", tool: "mcp__claude_ai_Slack__slack_read_thread", response: sampleResponse),
  SendCase(name: "the search tool", tool: "mcp__claude_ai_Slack__slack_search_public", response: sampleResponse),
  SendCase(name: "another server's send tool", tool: "mcp__other_Slack__slack_send_message", response: sampleResponse),
  SendCase(
    name: "the tool name in lowercase", tool: "mcp__claude_ai_slack__slack_send_message", response: sampleResponse),
  SendCase(name: "the bare tool name", tool: "slack_send_message", response: sampleResponse),
  SendCase(name: "the tool name with a space", tool: "\(slackSendTool) ", response: sampleResponse),
  // 3. The shape of tool_response.
  SendCase(name: "tool_response missing", response: nil),
  SendCase(name: "tool_response null", response: .null),
  SendCase(name: "tool_response an error string", response: "Error: channel_not_found"),
  SendCase(name: "tool_response a string of the result's JSON", response: .string(sampleText)),
  SendCase(name: "tool_response a number", response: 42),
  SendCase(name: "tool_response an empty array", response: []),
  SendCase(name: "an image block only", response: [["type": "image", "data": "aGVsbG8=", "mimeType": "image/png"]]),
  SendCase(name: "a block without a type", response: [["text": .string(sampleText)]]),
  SendCase(name: "a text block whose text is not JSON", response: [["type": "text", "text": "Error: not_in_channel"]]),
  SendCase(
    name: "a text block whose JSON is an array", response: [["type": "text", "text": .string("[\(sampleText)]")]]),
  SendCase(
    name: "a text block whose JSON is a string", response: [["type": "text", "text": "\"https://example.slack.com\""]]),
  SendCase(name: "a text block whose text is not a string", response: [["type": "text", "text": 7]]),
  SendCase(
    name: "the first text block is not JSON and a later one is",
    response: [["type": "text", "text": "Sent!"], ["type": "text", "text": .string(sampleText)]]),
  // 4. message_link.
  SendCase(
    name: "message_link missing",
    response: [["type": "text", "text": #"{"message_context":{"channel_id":"D0EXAMPLE01"}}"#]]),
  SendCase(name: "message_link a number", response: [["type": "text", "text": #"{"message_link":1794965246}"#]]),
  SendCase(name: "message_link null", response: [["type": "text", "text": #"{"message_link":null}"#]]),
  SendCase(
    name: "message_link not Slack",
    response: slackSendResponse(link: "https://example.com/archives/D0EXAMPLE01/p1794965246462679")),
  // A link of another known kind parses. Without message_context, only the kind check refuses it.
  SendCase(
    name: "message_link of another known kind without message_context",
    response: slackSendResponse(link: LinkFixtures.linear, channel: nil, ts: nil)),
  SendCase(
    name: "message_link on a look-alike host",
    response: slackSendResponse(link: "https://example.slack.com.evil.example/archives/D0EXAMPLE01/p1794965246462679")),
  SendCase(
    name: "message_link with userinfo",
    response: slackSendResponse(link: "https://example.slack.com@evil.example/archives/D0EXAMPLE01/p1794965246462679")),
  SendCase(
    name: "message_link of a channel",
    response: slackSendResponse(link: "https://example.slack.com/archives/D0EXAMPLE01")),
  SendCase(
    name: "message_link over http",
    response: slackSendResponse(link: "http://example.slack.com/archives/D0EXAMPLE01/p1794965246462679")),
  SendCase(
    name: "message_link with a malformed thread_ts",
    response: slackSendResponse(link: "\(LinkFixtures.slackDM)?thread_ts=1794965000.0001")),
  // 5. message_context must name the link's message.
  SendCase(
    name: "message_context channel mismatch",
    response: slackSendResponse(link: LinkFixtures.slackDM, channel: "D0EXAMPLE02", ts: LinkFixtures.replyTs)),
  SendCase(
    name: "message_context channel is the input's user id",
    response: slackSendResponse(link: LinkFixtures.slackDM, channel: "U0EXAMPLE01", ts: LinkFixtures.replyTs)),
  SendCase(
    name: "message_context ts mismatch",
    response: slackSendResponse(link: LinkFixtures.slackDM, channel: LinkFixtures.dmChannel, ts: "1794965246.462680")),
  SendCase(
    name: "message_context ts is the thread's, not the reply's",
    response: slackSendResponse(link: threadReply, channel: LinkFixtures.channel, ts: LinkFixtures.rootTs)),
  SendCase(
    name: "message_context ts without the dot",
    response: slackSendResponse(link: LinkFixtures.slackDM, channel: LinkFixtures.dmChannel, ts: "1794965246462679")),
  /// A present context that cannot show the link names the message refuses the send.
  SendCase(
    name: "message_context without channel_id",
    response: [
      [
        "type": "text",
        "text": .string(
          JSON.object([
            "message_link": .string(LinkFixtures.slackDM),
            "message_context": ["message_ts": .string(LinkFixtures.replyTs)],
          ]).text),
      ]
    ]),
  SendCase(
    name: "message_context without message_ts",
    response: [
      [
        "type": "text",
        "text": .string(
          JSON.object([
            "message_link": .string(LinkFixtures.slackDM),
            "message_context": ["channel_id": .string(LinkFixtures.dmChannel)],
          ]).text),
      ]
    ]),
  SendCase(
    name: "message_context ts as a number",
    response: [
      [
        "type": "text",
        "text": .string(
          JSON.object([
            "message_link": .string(LinkFixtures.slackDM),
            "message_context": ["channel_id": .string(LinkFixtures.dmChannel), "message_ts": 1_794_965_246.462679],
          ]).text),
      ]
    ]),
  SendCase(
    name: "message_context a string",
    response: [
      [
        "type": "text",
        "text": .string(
          JSON.object(["message_link": .string(LinkFixtures.slackDM), "message_context": "D0EXAMPLE01"]).text),
      ]
    ]),
]

/// `SlackSendCall.parse` gives a link only when the session sent a Slack message and the link names that
/// message. Each row breaks one condition of D16 or holds every one.
@Suite struct SlackSendCallTests {
  @Test(arguments: accepted) func aSendGivesTheResultsLink(_ row: SendCase) throws {
    let sent = try #require(SlackSendCall.parse(row.hook()))

    #expect(sent.url == row.url)
  }

  @Test(arguments: accepted) func aSendsTargetIsASlackTargetOfTheLink(_ row: SendCase) throws {
    let sent = try #require(SlackSendCall.parse(row.hook()))

    #expect(sent.target.kind == .slack)
    #expect(sent.target.channel == row.channel)
  }

  /// The thread comes from the link alone, so the target is what `LinkTarget.parse` gives for the link.
  @Test(arguments: accepted) func aSendsThreadComesFromItsLinkAlone(_ row: SendCase) throws {
    let sent = try #require(SlackSendCall.parse(row.hook()))

    #expect(sent.target.thread == row.thread)
    #expect(sent.target == LinkTarget.parse(sent.url))
  }

  /// A subagent's send counts for the session.
  @Test(arguments: accepted) func aSubagentsSendCounts(_ row: SendCase) throws {
    let sent = try #require(SlackSendCall.parse(row.hook(agent: "a1b2c3d4e5")))

    #expect(sent.url == row.url)
  }

  @Test(arguments: refused) func aHookThatIsNotASendGivesNothing(_ row: SendCase) {
    #expect(SlackSendCall.parse(row.hook()) == nil)
  }

  @Test(arguments: refused) func aSubagentsHookThatIsNotASendGivesNothing(_ row: SendCase) {
    #expect(SlackSendCall.parse(row.hook(agent: "a1b2c3d4e5")) == nil)
  }

  /// A hook of another tool whose result holds a Slack link gives nothing, such as a Bash run that printed one.
  @Test func anotherToolsResultWithASlackLinkGivesNothing() {
    let e = artifactHook(
      1000, tool: "Bash", input: ["command": "echo"],
      response: ["stdout": .string(LinkFixtures.slackDM), "stderr": "", "interrupted": false])

    #expect(SlackSendCall.parse(e) == nil)
  }
}
