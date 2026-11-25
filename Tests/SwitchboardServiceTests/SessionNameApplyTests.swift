import Foundation
import SwitchboardCore
import Testing

@testable import SwitchboardService

/// The name that `sb new --worktree` gives a session it names after its auto branch.
private let fallback = "haacked/session-750e"

/// A `Service` in a temporary home. The service never loads, so it starts no tmux server and no claude. config.json
/// points claude at /usr/bin/false, so a naming job that a bug lets through never reaches a real claude.
private func withNamingService(config extra: [String: JSON] = [:], _ body: (Service) throws -> Void) throws {
  let home = Home(path: try makeShortTempFolder())
  defer { try? FileManager.default.removeItem(atPath: home.path) }
  let config = JSON.object(["claude": "/usr/bin/false"].merging(extra) { $1 })
  try config.text.write(toFile: home.config, atomically: true, encoding: .utf8)
  try body(try Service(home: home, sbPath: "/usr/bin/true"))
}

/// A quota that every account has spent.
private struct NoBudget: QuotaBudget {
  func hasBudget(account: String) -> Bool { false }
  func loginWorks(account: String, since: Int64) -> Bool { false }
}

private let namingReply = HeadlessReply(
  output: "{}", usage: HeadlessUsage(input: 100, output: 20, cacheRead: 300, cacheWrite: 40), model: "claude-haiku-5-5")

extension Service {
  /// Adds a live session named `name` whose naming call is pending, as `create` leaves it.
  fileprivate func addPendingName(_ id: String, name: String = fallback) throws {
    try addLive(id, name: name)
    queue.sync { entries[id]?.pendingName = name }
  }

  /// Hands the session a naming answer on the state queue, as the job does once claude answers.
  fileprivate func answerName(_ id: String, _ result: Result<String, Error>, reply: HeadlessReply? = namingReply) {
    queue.sync { finishSessionName(id, HeadlessOutcome(reply: reply, result: result)) }
  }

  fileprivate func answerName(_ id: String, _ name: String) { answerName(id, .success(name)) }

  fileprivate func nameEvents(_ id: String) throws -> [Event] {
    try queue.sync { try store.events(session: id, kinds: ["session-name"]) }
  }

  fileprivate func liveName(_ id: String) -> String? { queue.sync { entries[id]?.session.name } }

  fileprivate func hasPendingName(_ id: String) -> Bool { queue.sync { entries[id]?.pendingName != nil } }

  /// The session that `sb get <key>` resolves.
  fileprivate func resolved(_ key: String) throws -> String {
    try queue.sync { try lookup(["session": .string(key)]) }
  }

  /// Renames the session through the `rename` request, as `sb rename` does from the Mac.
  fileprivate func renameRequest(_ id: String, to name: String) throws {
    let response = handle(Request(op: "rename", args: ["session": .string(id), "name": .string(name)]))
    if !response.ok { throw APIError(response.error ?? "rename failed") }
  }

  fileprivate func remove(_ id: String) throws {
    try queue.sync { try forgetSession(id, resolving: []) }
  }
}

@Suite struct SessionNameApplyTests {}

// MARK: - Applied

extension SessionNameApplyTests {
  @Suite struct Applied {
    @Test(.timeLimit(.minutes(1)))
    func anAnswerForAnUntouchedSessionRenamesIt() throws {
      try withNamingService { service in
        try service.addPendingName("s1")

        service.answerName("s1", "fix-login-redirect")

        #expect(service.liveName("s1") == "fix-login-redirect")
      }
    }

    @Test(.timeLimit(.minutes(1)))
    func theNewNameIsSavedInTheStore() throws {
      try withNamingService { service in
        try service.addPendingName("s1")

        service.answerName("s1", "fix-login-redirect")

        let saved = try service.queue.sync { try service.store.sessions() }.first { $0.id == "s1" }
        #expect(saved?.name == "fix-login-redirect")
      }
    }

    @Test(.timeLimit(.minutes(1)))
    func theNewNameResolvesToTheSession() throws {
      try withNamingService { service in
        try service.addPendingName("s1")

        service.answerName("s1", "fix-login-redirect")

        #expect(try service.resolved("fix-login-redirect") == "s1")
      }
    }

    @Test(.timeLimit(.minutes(1)))
    func anAppliedNameRecordsOneEventWithTheNameAndTheFallback() throws {
      try withNamingService { service in
        try service.addPendingName("s1")

        service.answerName("s1", "fix-login-redirect")

        let events = try service.nameEvents("s1")
        #expect(events.count == 1)
        #expect(events.first?.data["name"]?.string == "fix-login-redirect")
        #expect(events.first?.data["from"]?.string == fallback)
      }
    }

    @Test(.timeLimit(.minutes(1)))
    func theEventCarriesTheReplysModelAndUsage() throws {
      try withNamingService { service in
        try service.addPendingName("s1")

        service.answerName("s1", "fix-login-redirect")

        let event = try #require(try service.nameEvents("s1").first)
        for (key, value) in namingReply.eventFields { #expect(event.data[key] == value, "\(key)") }
      }
    }

    /// The prompt goes to Haiku, and the event log is no place for it.
    @Test(.timeLimit(.minutes(1)))
    func theEventHoldsNoPrompt() throws {
      try withNamingService { service in
        try service.addPendingName("s1")

        service.answerName("s1", "fix-login-redirect")

        let event = try #require(try service.nameEvents("s1").first)
        #expect(event.data["prompt"] == nil)
        #expect(event.data["input"] == nil)
      }
    }

    @Test(.timeLimit(.minutes(1)))
    func anAppliedNameClearsThePendingMarker() throws {
      try withNamingService { service in
        try service.addPendingName("s1")

        service.answerName("s1", "fix-login-redirect")

        #expect(!service.hasPendingName("s1"))
      }
    }

    /// The first answer clears the marker, so a second answer for the same session changes nothing.
    @Test(.timeLimit(.minutes(1)))
    func aSecondAnswerForTheSameSessionIsDropped() throws {
      try withNamingService { service in
        try service.addPendingName("s1")
        service.answerName("s1", "fix-login-redirect")

        service.answerName("s1", "add-oauth-support")

        #expect(service.liveName("s1") == "fix-login-redirect")
      }
    }
  }
}

// MARK: - Renamed before the answer (Risk 1)

extension SessionNameApplyTests {
  @Suite struct Renamed {
    @Test(.timeLimit(.minutes(1)))
    func aRenameBeforeTheAnswerIsKept() throws {
      try withNamingService { service in
        try service.addPendingName("s1")
        try service.renameRequest("s1", to: "mine")

        service.answerName("s1", "fix-login-redirect")

        #expect(service.liveName("s1") == "mine")
      }
    }

    /// A name set through `update`, not `renameSession`, is no longer the fallback, so the answer leaves it.
    @Test(.timeLimit(.minutes(1)))
    func aNameSetWithoutARenameRequestIsKept() throws {
      try withNamingService { service in
        try service.addPendingName("s1")
        try service.queue.sync { try service.update("s1") { $0.name = "mine" } }

        service.answerName("s1", "fix-login-redirect")

        #expect(service.liveName("s1") == "mine")
        #expect(try service.nameEvents("s1").first?.data["skipped"]?.string == "renamed")
      }
    }

    @Test(.timeLimit(.minutes(1)))
    func aRenameBeforeTheAnswerRecordsSkippedRenamed() throws {
      try withNamingService { service in
        try service.addPendingName("s1")
        try service.renameRequest("s1", to: "mine")

        service.answerName("s1", "fix-login-redirect")

        let events = try service.nameEvents("s1")
        #expect(events.count == 1)
        #expect(events.first?.data["skipped"]?.string == "renamed")
        #expect(events.first?.data["name"] == nil)
      }
    }

    /// The name equals the fallback again, but a rename touched the session, so the user's choice stands.
    @Test(.timeLimit(.minutes(1)))
    func aRenameToSomethingElseAndBackToTheFallbackIsKept() throws {
      try withNamingService { service in
        try service.addPendingName("s1")
        try service.renameRequest("s1", to: "mine")
        try service.renameRequest("s1", to: fallback)

        service.answerName("s1", "fix-login-redirect")

        #expect(service.liveName("s1") == fallback)
        #expect(try service.nameEvents("s1").first?.data["skipped"]?.string == "renamed")
      }
    }

    /// A rename to the name that the session already has still counts as a rename.
    @Test(.timeLimit(.minutes(1)))
    func aRenameToTheFallbackItselfIsKept() throws {
      try withNamingService { service in
        try service.addPendingName("s1")
        try service.renameRequest("s1", to: fallback)

        service.answerName("s1", "fix-login-redirect")

        #expect(service.liveName("s1") == fallback)
      }
    }

    @Test(.timeLimit(.minutes(1)))
    func everyRenameRequestClearsThePendingMarker() throws {
      try withNamingService { service in
        try service.addPendingName("s1")

        try service.renameRequest("s1", to: "mine")

        #expect(!service.hasPendingName("s1"))
      }
    }

    @Test(.timeLimit(.minutes(1)))
    func renameSessionClearsThePendingMarker() throws {
      try withNamingService { service in
        try service.addPendingName("s1")

        try service.queue.sync { try service.renameSession("s1", to: "mine") }

        #expect(!service.hasPendingName("s1"))
      }
    }

    /// After a restart, no marker exists, so a late answer can't apply.
    @Test(.timeLimit(.minutes(1)))
    func anAnswerWithoutAPendingMarkerChangesNothing() throws {
      try withNamingService { service in
        try service.addLive("s1", name: fallback)

        service.answerName("s1", "fix-login-redirect")

        #expect(service.liveName("s1") == fallback)
      }
    }

    @Test(.timeLimit(.minutes(1)))
    func aRenameOfOneSessionLeavesAnotherSessionsMarker() throws {
      try withNamingService { service in
        try service.addPendingName("s1")
        try service.addPendingName("s2", name: "widgets")
        try service.renameRequest("s1", to: "mine")

        service.answerName("s2", "add-oauth-support")

        #expect(service.liveName("s2") == "add-oauth-support")
      }
    }
  }
}

// MARK: - Removed before the answer

extension SessionNameApplyTests {
  @Suite struct Removed {
    @Test(.timeLimit(.minutes(1)))
    func anAnswerForARemovedSessionDoesNotThrowOrRecreateIt() throws {
      try withNamingService { service in
        try service.addPendingName("s1")
        try service.remove("s1")

        service.answerName("s1", "fix-login-redirect")

        #expect(service.liveName("s1") == nil)
        #expect(throws: (any Error).self) { try service.resolved("s1") }
      }
    }

    @Test(.timeLimit(.minutes(1)))
    func anAnswerForARemovedSessionRecordsNoEvent() throws {
      try withNamingService { service in
        try service.addPendingName("s1")
        try service.remove("s1")

        service.answerName("s1", "fix-login-redirect")

        #expect(try service.nameEvents("s1").isEmpty)
      }
    }

    @Test(.timeLimit(.minutes(1)))
    func aRemovedSessionKeepsTheNameItHadWhenItWasRemoved() throws {
      try withNamingService { service in
        try service.addPendingName("s1")
        try service.remove("s1")

        service.answerName("s1", "fix-login-redirect")

        #expect(service.queue.sync { service.removedNames["s1"] } == fallback)
        #expect(service.queue.sync { service.mention("s1") } == sessionMention(name: fallback, id: "s1"))
      }
    }

    @Test(.timeLimit(.minutes(1)))
    func removingASessionClearsItsPendingMarker() throws {
      try withNamingService { service in
        try service.addPendingName("s1")

        try service.remove("s1")

        #expect(!service.hasPendingName("s1"))
      }
    }
  }
}

// MARK: - Unique names (Risk 2)

extension SessionNameApplyTests {
  @Suite struct Unique {
    @Test(.timeLimit(.minutes(1)))
    func aNameThatAnotherLiveSessionHasGetsTwo() throws {
      try withNamingService { service in
        try service.addLive("other", name: "fix-login")
        try service.addPendingName("s1")

        service.answerName("s1", "fix-login")

        #expect(service.liveName("s1") == "fix-login-2")
      }
    }

    /// `sb get` must keep resolving both sessions: the guard's check and `lookup` agree.
    @Test(.timeLimit(.minutes(1)))
    func bothSessionsStillResolveAfterADuplicateAnswer() throws {
      try withNamingService { service in
        try service.addLive("other", name: "fix-login")
        try service.addPendingName("s1")

        service.answerName("s1", "fix-login")

        #expect(try service.resolved("fix-login") == "other")
        #expect(try service.resolved("fix-login-2") == "s1")
      }
    }

    /// A name that is a prefix of another session's id makes `sb get <name>` ambiguous, though no session has
    /// that name.
    @Test(.timeLimit(.minutes(1)))
    func aNameThatPrefixesAnotherSessionsIdGetsTwo() throws {
      try withNamingService { service in
        try service.addLive("fix-login-x1", name: "other")
        try service.addPendingName("s1")

        service.answerName("s1", "fix-login")

        #expect(service.liveName("s1") == "fix-login-2")
        #expect(try service.resolved("fix-login-2") == "s1")
      }
    }

    @Test(.timeLimit(.minutes(1)))
    func aNameAndItsTwoTakenGetsThree() throws {
      try withNamingService { service in
        try service.addLive("a", name: "fix-login")
        try service.addLive("b", name: "fix-login-2")
        try service.addPendingName("s1")

        service.answerName("s1", "fix-login")

        #expect(service.liveName("s1") == "fix-login-3")
      }
    }

    /// Two answers for different sessions apply one after the other on the state queue.
    @Test(.timeLimit(.minutes(1)))
    func twoSessionsWithTheSameAnswerGetTheNameAndTwo() throws {
      try withNamingService { service in
        try service.addPendingName("s1")
        try service.addPendingName("s2")

        service.answerName("s1", "fix-login")
        service.answerName("s2", "fix-login")

        #expect(service.liveName("s1") == "fix-login")
        #expect(service.liveName("s2") == "fix-login-2")
        #expect(try service.resolved("fix-login") == "s1")
        #expect(try service.resolved("fix-login-2") == "s2")
      }
    }

    @Test(.timeLimit(.minutes(1)))
    func theEventOfASuffixedNameRecordsTheSuffixedName() throws {
      try withNamingService { service in
        try service.addLive("other", name: "fix-login")
        try service.addPendingName("s1")

        service.answerName("s1", "fix-login")

        #expect(try service.nameEvents("s1").first?.data["name"]?.string == "fix-login-2")
      }
    }

    /// `lookup` resolves only live sessions, so a removed session's name is free.
    @Test(.timeLimit(.minutes(1)))
    func aRemovedSessionsNameIsFree() throws {
      try withNamingService { service in
        try service.addLive("old", name: "fix-login")
        try service.remove("old")
        try service.addPendingName("s1")

        service.answerName("s1", "fix-login")

        #expect(service.liveName("s1") == "fix-login")
      }
    }

    @Test(.timeLimit(.minutes(1)))
    func allNinetyNineNamesTakenKeepsTheFallback() throws {
      try withNamingService { service in
        try service.addLive("t1", name: "fix-login")
        for n in 2...99 { try service.addLive("t\(n)", name: "fix-login-\(n)") }
        try service.addPendingName("s1")

        service.answerName("s1", "fix-login")

        #expect(service.liveName("s1") == fallback)
      }
    }

    @Test(.timeLimit(.minutes(1)))
    func allNinetyNineNamesTakenRecordsSkippedNoFreeName() throws {
      try withNamingService { service in
        try service.addLive("t1", name: "fix-login")
        for n in 2...99 { try service.addLive("t\(n)", name: "fix-login-\(n)") }
        try service.addPendingName("s1")

        service.answerName("s1", "fix-login")

        let events = try service.nameEvents("s1")
        #expect(events.count == 1)
        #expect(events.first?.data["skipped"]?.string == "no free name")
        #expect(!service.hasPendingName("s1"))
      }
    }
  }
}

// MARK: - Failures

extension SessionNameApplyTests {
  @Suite struct Failures {
    @Test(.timeLimit(.minutes(1)))
    func aFailedCallKeepsTheFallback() throws {
      try withNamingService { service in
        try service.addPendingName("s1")

        service.answerName("s1", .failure(APIError("claude's answer holds no valid name")))

        #expect(service.liveName("s1") == fallback)
      }
    }

    @Test(.timeLimit(.minutes(1)))
    func aFailedCallRecordsOneErrorEventWithTheReplysFields() throws {
      try withNamingService { service in
        try service.addPendingName("s1")

        service.answerName("s1", .failure(APIError("claude's answer holds no valid name")))

        let events = try service.nameEvents("s1")
        #expect(events.count == 1)
        let event = try #require(events.first)
        #expect(event.data["error"]?.string?.contains("no valid name") == true, "\(event.data)")
        #expect(event.data["name"] == nil)
        for (key, value) in namingReply.eventFields { #expect(event.data[key] == value, "\(key)") }
      }
    }

    /// claude that did not start or did not exit by itself leaves no reply, and the error still gets an event.
    @Test(.timeLimit(.minutes(1)))
    func aCallWithoutAReplyRecordsAnErrorEvent() throws {
      try withNamingService { service in
        try service.addPendingName("s1")

        service.answerName("s1", .failure(APIError("timed out after 30 s")), reply: nil)

        #expect(try service.nameEvents("s1").first?.data["error"]?.string?.contains("timed out") == true)
      }
    }

    @Test(.timeLimit(.minutes(1)))
    func aFailedCallClearsThePendingMarker() throws {
      try withNamingService { service in
        try service.addPendingName("s1")

        service.answerName("s1", .failure(APIError("boom")))

        #expect(!service.hasPendingName("s1"))
      }
    }
  }
}

// MARK: - Quota

extension SessionNameApplyTests {
  @Suite struct Quota {
    @Test(.timeLimit(.minutes(1)))
    func aSpentQuotaRecordsSkippedForTheSessionsAccount() throws {
      try withNamingService { service in
        try service.addLive("s1", name: fallback)
        service.queue.sync { service.quota = NoBudget() }

        service.queue.sync { service.queueSessionName("s1", prompt: "Fix the login redirect", worktree: false) }
        service.nameJobs.waitUntilAllOperationsAreFinished()

        let account = service.queue.sync { service.claudeAccount(of: "s1").key }
        let events = try service.nameEvents("s1")
        #expect(events.count == 1)
        #expect(events.first?.data["skipped"]?.string == "no quota left for \(account)")
      }
    }

    @Test(.timeLimit(.minutes(1)))
    func aSpentQuotaRunsNoCallAndKeepsTheFallback() throws {
      try withNamingService { service in
        try service.addLive("s1", name: fallback)
        service.queue.sync { service.quota = NoBudget() }

        service.queue.sync { service.queueSessionName("s1", prompt: "Fix the login redirect", worktree: false) }
        service.nameJobs.waitUntilAllOperationsAreFinished()
        // A job that ran would hop back to the state queue to record its outcome.
        service.queue.sync {}

        #expect(try service.queue.sync { try service.store.headlessCalls(since: 0) }.isEmpty)
        #expect(service.liveName("s1") == fallback)
        #expect(try service.nameEvents("s1").allSatisfy { $0.data["error"] == nil })
      }
    }

    @Test(.timeLimit(.minutes(1)))
    func aSpentQuotaLeavesNoPendingMarker() throws {
      try withNamingService { service in
        try service.addLive("s1", name: fallback)
        service.queue.sync { service.quota = NoBudget() }

        service.queue.sync { service.queueSessionName("s1", prompt: "Fix the login redirect", worktree: false) }

        #expect(!service.hasPendingName("s1"))
      }
    }
  }
}

// MARK: - No call

extension SessionNameApplyTests {
  @Suite struct NoCall {
    @Test(.timeLimit(.minutes(1)))
    func aDisabledConfigQueuesNoCall() throws {
      try withNamingService(config: ["sessionNames": ["enabled": false]]) { service in
        try service.addLive("s1", name: fallback)

        service.queue.sync { service.queueSessionName("s1", prompt: "Fix the login redirect", worktree: false) }

        #expect(service.nameJobs.operationCount == 0)
        #expect(!service.hasPendingName("s1"))
        #expect(try service.nameEvents("s1").isEmpty)
      }
    }

    @Test(.timeLimit(.minutes(1)))
    func aSessionWithoutANamingPromptQueuesNoCall() throws {
      try withNamingService { service in
        try service.addLive("s1", name: fallback)

        service.queue.sync { service.queueSessionName("s1", prompt: nil, worktree: false) }

        #expect(service.nameJobs.operationCount == 0)
        #expect(!service.hasPendingName("s1"))
      }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [SessionKind.manager, .chat, .operator])
    func aSessionThatIsNotWorkQueuesNoCall(_ kind: SessionKind) throws {
      try withNamingService { service in
        try service.addLive("s1", name: fallback)
        service.queue.sync {
          switch kind {
          case .manager: service.entries["s1"]?.session.manager = true
          case .chat: service.entries["s1"]?.session.chat = "g1"
          case .operator: service.entries["s1"]?.session.isOperator = true
          case .work: break
          }
        }

        service.queue.sync { service.queueSessionName("s1", prompt: "Fix the login redirect", worktree: false) }

        #expect(service.nameJobs.operationCount == 0)
        #expect(!service.hasPendingName("s1"))
        #expect(try service.nameEvents("s1").isEmpty)
      }
    }
  }
}

// MARK: - Account of the call

extension SessionNameApplyTests {
  @Suite struct Account {
    /// sbd may run with CLAUDE_CONFIG_DIR set to another account. A session on the default account keeps its turn on
    /// the default account, which the quota check also reads.
    @Test(.timeLimit(.minutes(1)))
    func aDefaultAccountSessionDropsSbdsConfigDir() throws {
      try withNamingService { service in
        try service.addLive("s1", name: fallback)
        service.queue.sync { service.entries["s1"]?.session.claudeConfigDir = ClaudeAccount.defaultFolder }

        let env = service.queue.sync {
          service.headlessEnv(session: "s1", account: nil, base: ["CLAUDE_CONFIG_DIR": "/tmp/sbd-account"])
        }

        #expect(env["CLAUDE_CONFIG_DIR"] == nil)
      }
    }

    @Test(.timeLimit(.minutes(1)))
    func anotherAccountSessionKeepsItsOwnConfigDir() throws {
      try withNamingService { service in
        try service.addLive("s1", name: fallback)
        service.queue.sync { service.entries["s1"]?.session.claudeConfigDir = "/tmp/session-account" }

        let env = service.queue.sync {
          service.headlessEnv(session: "s1", account: nil, base: ["CLAUDE_CONFIG_DIR": "/tmp/sbd-account"])
        }

        #expect(env["CLAUDE_CONFIG_DIR"] == ClaudeAccount(folder: "/tmp/session-account").folder)
      }
    }
  }
}
