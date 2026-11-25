import Foundation
import SwitchboardCore
import Testing

@testable import SwitchboardService

/// A `Service` in a temporary home. config.json runs claude as /bin/sh, so a call's arguments carry a shell script.
/// The service never loads, so it starts no tmux server.
private func withShellClaude(_ body: (Service, String) throws -> Void) throws {
  let home = Home(path: try makeShortTempFolder())
  defer { try? FileManager.default.removeItem(atPath: home.path) }
  try JSON.object(["claude": "/bin/sh"]).text.write(toFile: home.config, atomically: true, encoding: .utf8)
  try body(try Service(home: home, sbPath: "/usr/bin/true"), home.path)
}

/// A result envelope on one line, as the last line of stream-json output prints it.
private let envelopeLine = """
  {"type":"result","subtype":"success","is_error":false,"result":"ok","usage":{"input_tokens":2,\
  "output_tokens":124,"cache_read_input_tokens":0,"cache_creation_input_tokens":1126},"modelUsage":\
  {"claude-haiku-5-5":{"inputTokens":2,"outputTokens":124,"cacheReadInputTokens":0,"cacheCreationInputTokens":1126}}}
  """

/// The script prints the envelope and then keeps running, so only a refusal ends it before the timeout.
private let envelopeThenSleep = "printf '%s\\n' '\(envelopeLine)'; exec sleep 30"

private func refuseTheEnvelope(_ line: String) -> String? {
  line.hasPrefix(#"{"type":"result""#) ? "wrong tools" : nil
}

extension Service {
  /// Runs the script through `headlessCall` as a `triage` call that returns what claude printed.
  fileprivate func shellCall(
    _ script: String, folder: String, onLine: ((String) -> String?)?
  ) -> HeadlessOutcome<String> {
    headlessCall(
      .triage, session: nil, arguments: ["-c", script], input: "", env: ProcessInfo.processInfo.environment,
      folder: folder, timeout: 30, onLine: onLine, parse: { $0 })
  }

  /// The stored calls. `headlessCall` stores its row on the serial state queue, so this read runs after it.
  fileprivate func storedCalls() throws -> [HeadlessCall] {
    try queue.sync { try store.headlessCalls(since: 0) }
  }
}

/// `Service.headlessCall` with a line handler: a refusal still stores a `headless_calls` row.
@Suite(.timeLimit(.minutes(1))) struct HeadlessCallRefusalTests {
  @Test func aRefusedCallFailsWithTheRefusal() throws {
    try withShellClaude { service, folder in
      let outcome = service.shellCall("echo first; exec sleep 30", folder: folder, onLine: { _ in "wrong tools" })

      #expect(outcome.error is Headless.Refused, "\(String(describing: outcome.error))")
    }
  }

  /// A runner that let `Refused` fall through to the generic catch stores this row too. The two tests after it are
  /// the ones that check that the reply comes from `Refused.output`.
  @Test func aRefusedCallStoresOneRowWithTheRefusalAsItsError() throws {
    try withShellClaude { service, folder in
      _ = service.shellCall("echo first; exec sleep 30", folder: folder, onLine: { _ in "wrong tools" })

      let calls = try service.storedCalls()

      #expect(calls.count == 1)
      #expect(calls.first?.error?.contains("wrong tools") == true, "\(calls)")
    }
  }

  @Test func aRefusedCallStoresTheTokensAndModelOfWhatClaudePrinted() throws {
    try withShellClaude { service, folder in
      _ = service.shellCall(envelopeThenSleep, folder: folder, onLine: refuseTheEnvelope)

      let call = try #require(try service.storedCalls().first)

      #expect(call.usage == HeadlessUsage(input: 2, output: 124, cacheRead: 0, cacheWrite: 1126))
      #expect(call.model == "claude-haiku-5-5")
    }
  }

  @Test func aRefusedCallsReplyHoldsWhatClaudePrintedBeforeTheRefusal() throws {
    try withShellClaude { service, folder in
      let outcome = service.shellCall(
        "echo first; echo second; exec sleep 30", folder: folder, onLine: { $0 == "second" ? "second line" : nil })

      #expect(outcome.reply?.output.hasPrefix("first\nsecond") == true, "\(String(describing: outcome.reply))")
    }
  }

  @Test func aCallWhoseHandlerRefusesNothingParsesTheOutput() throws {
    try withShellClaude { service, folder in
      let outcome = service.shellCall("printf '%s\\n' '\(envelopeLine)'", folder: folder, onLine: { _ in nil })

      let output = try outcome.result.get()

      #expect(output == envelopeLine + "\n")
    }
  }

  @Test func aCallWhoseHandlerRefusesNothingStoresNoError() throws {
    try withShellClaude { service, folder in
      _ = service.shellCall("printf '%s\\n' '\(envelopeLine)'", folder: folder, onLine: { _ in nil })

      let call = try #require(try service.storedCalls().first)

      #expect(call.error == nil)
    }
  }
}
