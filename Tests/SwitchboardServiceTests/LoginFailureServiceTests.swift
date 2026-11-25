import Foundation
import SwitchboardCore
import Testing

@testable import SwitchboardService

private let loginMessage = "Login reached its time limit · Please run /login"

/// sbd records the account that a StopFailure happened on, and the summary shows the failure, not the older reply.
@Suite struct LoginFailureServiceTests {
  /// Runs a turn that ends with a reply and a turn that ends with a StopFailure of `error`, through `hook`, for a
  /// session on the account folder `folder`. `body` runs on the service's queue.
  private func failedTurn<T>(
    error: String, folder: String = "/accounts/.claude-orchid", _ body: (Service) throws -> T
  ) throws -> T {
    let home = Home(path: try makeShortTempFolder())
    defer { try? FileManager.default.removeItem(atPath: home.path) }
    let config: JSON = ["claude": "/usr/bin/false"]
    try config.text.write(toFile: home.config, atomically: true, encoding: .utf8)
    let service = try Service(home: home, sbPath: "/usr/bin/true")
    var session = Session(id: "s1", name: "s1", cwd: "/tmp", claudeSessionId: "u-s1", created: 5)
    session.started = true
    session.claudeConfigDir = folder
    let hooks: [JSON] = [
      ["hook_event_name": "UserPromptSubmit", "prompt": "go"],
      ["hook_event_name": "Stop", "last_assistant_message": "Done: go"],
      ["hook_event_name": "UserPromptSubmit", "prompt": "next"],
      ["hook_event_name": "StopFailure", "error": .string(error), "last_assistant_message": .string(loginMessage)],
    ]
    return try service.queue.sync {
      service.entries["s1"] = Service.Entry(session: session)
      for payload in hooks { _ = try service.hook(["session": "s1", "payload": payload]) }
      return try body(service)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func theFailureRecordsTheSessionsAccount() throws {
    let (recorded, expected) = try failedTurn(error: "authentication_failed") { service in
      (service.entries["s1"]?.facts.turnFailure?.account, service.claudeAccount(of: "s1").key)
    }

    #expect(recorded == expected)
  }

  @Test(.timeLimit(.minutes(1)))
  func theSummaryNeedsYou() throws {
    let state = try failedTurn(error: "authentication_failed") { $0.summary("s1").state }

    #expect(state == .needsYou)
  }

  @Test(.timeLimit(.minutes(1)))
  func theSummaryReasonNamesTheAccountWhoseLoginExpired() throws {
    let reason = try failedTurn(error: "authentication_failed") { $0.summary("s1").reason }

    #expect(reason.contains("orchid"))
    #expect(reason.contains("expired"))
  }

  @Test(.timeLimit(.minutes(1)))
  func theSummaryShowsTheFailureMessageInsteadOfTheOlderReply() throws {
    let reply = try failedTurn(error: "authentication_failed") { $0.summary("s1").lastReply }

    #expect(reply == loginMessage)
  }

  /// Discovery never lists /accounts/.claude-orchid, so only the failure puts it in the usage reader's polls.
  @Test(.timeLimit(.minutes(1)))
  func theUsageReaderPollsTheAccountWhoseLoginFailed() throws {
    let folders = try failedTurn(error: "authentication_failed") { $0.usageAccounts().map(\.folder) }

    #expect(folders.contains("/accounts/.claude-orchid"))
  }

  @Test(.timeLimit(.minutes(1)))
  func aRateLimitFailureAddsNoAccountToThePolls() throws {
    let folders = try failedTurn(error: "rate_limit") { $0.usageAccounts().map(\.folder) }

    #expect(!folders.contains("/accounts/.claude-orchid"))
  }

  /// An ack would leave the item in Needs you, so the request says why instead of doing nothing.
  @Test(.timeLimit(.minutes(1)))
  func anAckOfTheLoginFailureIsRefused() throws {
    let refused = try failedTurn(error: "authentication_failed") { service in
      #expect(throws: APIError.self) { try service.acknowledgeRequest(["session": "s1"]) }
      return service.entries["s1"]?.facts.acknowledgment == nil
    }

    #expect(refused)
  }

  @Test(.timeLimit(.minutes(1)))
  func aRateLimitFailureKeepsTheGenericReason() throws {
    let reason = try failedTurn(error: "rate_limit") { $0.summary("s1").reason }

    #expect(reason == "read its last reply and decide what's next")
  }
}
