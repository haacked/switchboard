import Foundation
import Testing

@testable import SwitchboardCore

/// The envelope that `claude -p --output-format json --model haiku` printed on 2026-11-18, without its session id.
private let withModelUsage = """
  {"type":"result","subtype":"success","is_error":false,"duration_api_ms":2047,"result":"{\\"a\\":\\"ok\\"}",\
  "structured_output":{"a":"ok"},"usage":{"input_tokens":2,"cache_creation_input_tokens":1126,\
  "cache_read_input_tokens":0,"output_tokens":124},"modelUsage":{"claude-haiku-5-5":{"inputTokens":2,\
  "outputTokens":124,"cacheReadInputTokens":0,"cacheCreationInputTokens":1126,"costUSD":0.0002874}}}

  """

/// The captured envelope without its `modelUsage`, so only the top-level `usage` reports the tokens.
private let withOnlyUsage = """
  {"type":"result","subtype":"success","is_error":false,"result":"{\\"a\\":\\"ok\\"}",\
  "structured_output":{"a":"ok"},"usage":{"input_tokens":2,"cache_creation_input_tokens":1126,\
  "cache_read_input_tokens":0,"output_tokens":124}}

  """

/// An error envelope. claude still reports the tokens that the failed call spent.
private let isError = """
  {"type":"result","subtype":"success","is_error":true,"result":"Credit balance is too low",\
  "usage":{"input_tokens":3,"cache_creation_input_tokens":0,"cache_read_input_tokens":50,"output_tokens":0}}

  """

/// An envelope whose answer is fenced JSON with an escaped quote, a newline, and a non-ASCII character.
private let withEscapedText =
  JSON.object([
    "type": "result", "subtype": "success", "is_error": false,
    "result": .string("```json\n{\"a\": \"caf\u{e9} \\\"quoted\\\"\\nnext\"}\n```"),
    "usage": ["input_tokens": 4, "output_tokens": 5, "cache_read_input_tokens": 6, "cache_creation_input_tokens": 7],
  ]).text + "\n"

private let notJSON = "Error: not logged in\n"

/// The init line of a stream-json run. It is a JSON object, so a parse that accepts the first value of the output
/// and ignores the rest returns it instead of the envelope.
private let initLine = """
  {"type":"system","subtype":"init","cwd":"/tmp","session_id":"s","tools":["StructuredOutput"],\
  "mcp_servers":[],"model":"claude-haiku-5-5"}
  """

/// An assistant line whose message reports other token counts than any envelope here.
private let assistantLine = """
  {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"reading"}],\
  "usage":{"input_tokens":999,"output_tokens":999}}}
  """

/// The output of the same call with `--output-format stream-json --verbose`: an init line, an assistant line, and
/// the envelope as the last line.
private func stream(_ envelope: String) -> String { "\(initLine)\n\(assistantLine)\n\(envelope)" }

/// The line breaks that JSON leaves raw inside a string.
private let lineBreaks = "\u{2028}\u{2029}\u{85}"

/// A tool_result line whose text holds the raw line breaks.
private let lineBreakLine = """
  {"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"a\(lineBreaks)b"}]}}
  """

/// An envelope whose answer holds the raw line breaks.
private let lineBreakEnvelope = """
  {"type":"result","subtype":"success","is_error":false,"result":"{\\"a\\":\\"x\(lineBreaks)y\\"}",\
  "structured_output":{"a":"x\(lineBreaks)y"},"usage":{"input_tokens":2,"output_tokens":3}}
  """

/// Every envelope shape that the existing callers read.
private let envelopes = [withModelUsage, withOnlyUsage, isError, withEscapedText]

/// The envelope shapes, and output that holds no JSON.
private let outputs = envelopes + [notJSON]

/// `Headless.envelope`: the result envelope of single-JSON output and of stream-json output.
@Suite struct HeadlessEnvelopeTests {
  // MARK: Single JSON

  @Test(arguments: envelopes)
  func singleJSONOutputGivesTheWholeObject(_ text: String) throws {
    let parsed = try #require(JSON.parse(text)?.object)

    #expect(Headless.envelope(text) == parsed)
  }

  /// Only the line path requires `type: result`.
  @Test func singleJSONOutputWithoutATypeGivesTheWholeObject() throws {
    let text = #"{"structured_output":{"a":"ok"}}"#
    let parsed = try #require(JSON.parse(text)?.object)

    #expect(Headless.envelope(text) == parsed)
  }

  /// Indented JSON spans many lines, and none of them alone is the envelope.
  @Test func indentedSingleJSONOutputGivesTheWholeObject() throws {
    let parsed = try #require(JSON.parse(withModelUsage)?.object)

    #expect(Headless.envelope(JSON.object(parsed).prettyText) == parsed)
  }

  // MARK: Stream JSON

  @Test(arguments: envelopes)
  func streamOutputGivesTheEnvelopeOnItsLastLine(_ text: String) throws {
    let parsed = try #require(JSON.parse(text)?.object)

    #expect(Headless.envelope(stream(text)) == parsed)
  }

  @Test func blankLinesAfterTheEnvelopeAreSkipped() throws {
    let parsed = try #require(JSON.parse(withModelUsage)?.object)

    #expect(Headless.envelope(stream(withModelUsage) + "\n\n") == parsed)
  }

  @Test func aLineThatIsNotJSONBeforeTheEnvelopeIsSkipped() throws {
    let parsed = try #require(JSON.parse(withModelUsage)?.object)
    let text = "\(initLine)\nwarning: a slow MCP server\n\(withModelUsage)"

    #expect(Headless.envelope(text) == parsed)
  }

  @Test func theLastOfTwoResultLinesIsTheEnvelope() throws {
    let parsed = try #require(JSON.parse(isError)?.object)

    #expect(Headless.envelope(stream(withModelUsage) + isError) == parsed)
  }

  /// A split at every Unicode line break would cut both the tool_result line and the envelope.
  @Test func anEnvelopeHoldingUnicodeLineBreaksAfterALineHoldingThemIsTheEnvelope() throws {
    let parsed = try #require(JSON.parse(lineBreakEnvelope)?.object)
    let text = "\(initLine)\n\(lineBreakLine)\n\(lineBreakEnvelope)\n"

    #expect(Headless.envelope(text) == parsed)
    #expect(try Headless.answer(text)["a"] == .string("x\(lineBreaks)y"))
  }

  @Test func aStreamWithCarriageReturnsGivesTheEnvelope() throws {
    let parsed = try #require(JSON.parse(withModelUsage)?.object)
    let text = "\(initLine)\r\n\(assistantLine)\r\n\(withModelUsage)\r\n"

    #expect(Headless.envelope(text) == parsed)
  }

  @Test func aStreamWhoseLastLineIsNotAResultGivesNil() {
    let text = "\(initLine)\n\(assistantLine)\n"

    #expect(Headless.envelope(text) == nil)
  }

  /// A result line followed by another line is not the last line.
  @Test func aResultLineFollowedByAnAssistantLineGivesNil() {
    let text = "\(initLine)\n\(withModelUsage)\(assistantLine)\n"

    #expect(Headless.envelope(text) == nil)
  }

  @Test func aStreamWhoseLastLineHasNoTypeGivesNil() {
    let text = "\(initLine)\n" + #"{"structured_output":{"a":"ok"}}"# + "\n"

    #expect(Headless.envelope(text) == nil)
  }

  @Test(arguments: [
    "", "claude crashed {", notJSON, "{\"usage\":", "[1,2]", "\"text\"", "\(initLine)\nclaude crashed\n",
  ])
  func outputWithNoEnvelopeGivesNil(_ text: String) {
    #expect(Headless.envelope(text) == nil)
  }

  // MARK: Parity of the two paths

  @Test(arguments: envelopes)
  func singleAndStreamOutputGiveTheSameEnvelope(_ text: String) throws {
    let single = try #require(Headless.envelope(text))

    #expect(Headless.envelope(stream(text)) == single)
  }

  @Test(arguments: outputs)
  func singleAndStreamOutputGiveTheSameTokens(_ text: String) {
    #expect(Headless.reply(stream(text)).usage == Headless.reply(text).usage)
  }

  @Test(arguments: outputs)
  func singleAndStreamOutputGiveTheSameModel(_ text: String) {
    #expect(Headless.reply(stream(text)).model == Headless.reply(text).model)
  }

  /// The parity checks above pass vacuously when both paths give no tokens, so this one pins a value.
  @Test func streamOutputGivesTheTokensOfTheEnvelopeNotOfTheAssistantLine() {
    let reply = Headless.reply(stream(withModelUsage))

    #expect(reply.usage == HeadlessUsage(input: 2, output: 124, cacheRead: 0, cacheWrite: 1126))
  }

  @Test(arguments: outputs)
  func theReplyKeepsTheStreamOutputVerbatim(_ text: String) {
    let output = stream(text)

    #expect(Headless.reply(output).output == output)
  }

  @Test(arguments: [withModelUsage, withOnlyUsage, withEscapedText])
  func singleAndStreamOutputGiveTheSameAnswer(_ text: String) throws {
    let single = try Headless.answer(text)

    #expect(try Headless.answer(stream(text)) == single)
  }

  @Test func theEscapedAnswerReadsTheSameThroughTheStream() throws {
    let answer = try Headless.answer(stream(withEscapedText))

    #expect(answer["a"] == .string("caf\u{e9} \"quoted\"\nnext"))
  }

  /// `answer` falls back to the whole output when an error envelope has no `result`, so only this shape gives the
  /// same message on both paths.
  @Test func singleAndStreamErrorEnvelopesThrowTheSameMessage() {
    let single = #expect(throws: APIError.self) { try Headless.answer(isError) }
    let streamed = #expect(throws: APIError.self) { try Headless.answer(stream(isError)) }

    #expect(streamed?.description == single?.description)
  }

  @Test func anErrorEnvelopeInAStreamThrowsWithItsResultText() {
    let error = #expect(throws: APIError.self) { try Headless.answer(stream(isError)) }

    #expect(error?.description.contains("Credit balance is too low") == true, "\(String(describing: error))")
  }

  @Test(arguments: [notJSON, stream(notJSON), "\(initLine)\n\(assistantLine)\n"])
  func outputWithNoEnvelopeThrowsFromAnswer(_ text: String) {
    #expect(throws: APIError.self) { try Headless.answer(text) }
  }

  // MARK: The exit error

  /// The description shows the start of what claude printed, which for stream output is the init line.
  @Test func anExitErrorOnStreamOutputShowsTheStartOfTheOutput() {
    let error = Headless.ExitError(status: 1, output: stream(isError))

    #expect(error.description.contains(#"{"type":"system","subtype":"init""#), "\(error)")
  }

  @Test func anExitErrorOnStreamOutputShowsTheStatus() {
    let error = Headless.ExitError(status: 1, output: stream(isError))

    #expect(error.description.contains("status 1"), "\(error)")
  }
}
