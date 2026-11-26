import Foundation
import SwitchboardCore
import Testing

@testable import SwitchboardService

private let manager = "c1"
private let otherManager = "c2"
private let work = "w1"
private let chat = "g1"
private let theOperator = "o1"
private let created: Int64 = 1_800_000_000_000

/// A pid that is in no ancestry of the test process. No test signals it.
private let unrelatedPane = 4242

private func session(_ id: String, _ kind: SessionKind) -> Session {
  var s = makeSession(id, name: "\(kind.rawValue) \(id)")
  switch kind {
  case .manager: s.manager = true
  case .operator:
    s.manager = true
    s.isOperator = true
  case .chat: s.chat = "Flags"
  case .work: break
  }
  return s
}

/// A script schedule of the session, stored in `jobs` as sbd stores one.
private func script(_ id: String) throws -> Schedule {
  try ScheduleRequest(every: "30m", prompt: "git fetch", by: nil, runner: "script").makeSchedule(id: id, now: created)
}

/// A service whose entries hold one session of each kind. It never loads, so it starts no tmux server and no claude.
private func withSessions(_ body: (Service) throws -> Void) throws {
  try withService { service, _ in
    service.queue.sync {
      for (id, kind) in [
        (manager, SessionKind.manager), (otherManager, .manager), (work, .work), (chat, .chat),
        (theOperator, .operator),
      ] {
        service.entries[id] = Service.Entry(session: session(id, kind))
      }
      // `scriptAuthority` reads the installed snapshot, so it stays as the test sets it.
      service.mac.snapshot.taken = .max
    }
    try body(service)
  }
}

private var myPid: Int { Int(getpid()) }
private var me: Caller { .client(pid: myPid) }

/// The test process's start time, as `ProcessTable` reads it.
private func myStart() throws -> Int64 {
  try #require(ProcessTable.readLocal().row(myPid)?.startTime)
}

/// Puts the test process in the session's Claude pane, or in its shell pane.
private func placeMe(_ service: Service, in id: String, pane: Pane = .claude) {
  service.queue.sync {
    let other: Pane = pane == .claude ? .shell : .claude
    service.mac.snapshot.panes[service.paneName(id, pane)] = PaneRow(pid: myPid, dead: false, clients: 0)
    service.mac.snapshot.panes[service.paneName(id, other)] = PaneRow(pid: unrelatedPane, dead: false, clients: 0)
  }
}

/// The request's arguments: `caller` as sb sends it from SB_SESSION_ID, and `group` as a scoped MCP server sends it.
private func args(caller: String? = nil, group: String? = nil) -> JSON {
  var a: [String: JSON] = ["session": .string(work), "every": "30m", "prompt": "git fetch", "runner": "script"]
  if let caller { a["caller"] = .string(caller) }
  if let group { a["group"] = .string(group) }
  return .object(a)
}

/// What `scriptAuthority` returned, or the text of its refusal.
private enum Outcome: Equatable, CustomStringConvertible {
  case authority(String)
  case refused(String)

  var description: String {
    switch self {
    case .authority(let a): "authority \(a)"
    case .refused(let r): "refused: \(r)"
    }
  }

  var refused: Bool { if case .refused = self { true } else { false } }

}

private func classify(
  _ service: Service, _ args: JSON, origin: RequestOrigin = .mac, caller: Caller
) -> Outcome {
  service.queue.sync {
    do {
      return .authority("\(try service.scriptAuthority(args, origin: origin, caller: caller))")
    } catch {
      return .refused("\(error)")
    }
  }
}

/// Decision 3 of the plan: who may store a script schedule or change a script's command or timeout. Each shape here
/// needs no live pane, because the test writes the pane rows of the installed snapshot. The pane shapes that need a
/// real Claude pane are in IntegrationTests/ScheduleScriptTests.
@Suite struct ScheduleScriptCallerTests {
  // MARK: The three callers that store

  @Test func anInProcessCallerIsSbd() throws {
    try withSessions { service in
      let result = service.queue.sync { try? service.scriptAuthority(args(), origin: .mac, caller: .inProcess) }

      #expect(result == .sbd)
    }
  }

  /// A terminal outside Switchboard: no claimed caller, no group, and no pane in the ancestry.
  @Test func aClientOutsideEveryPaneWithNoCallerIsTheUser() throws {
    try withSessions { service in
      let result = service.queue.sync { try? service.scriptAuthority(args(), origin: .mac, caller: me) }

      #expect(result == .user)
    }
  }

  @Test(arguments: [Pane.claude, .shell])
  func aManagerConversationsPaneThatClaimsItIsThatConversation(_ pane: Pane) throws {
    try withSessions { service in
      placeMe(service, in: manager, pane: pane)

      let result = service.queue.sync {
        try? service.scriptAuthority(args(caller: manager), origin: .mac, caller: me)
      }

      #expect(result == .manager(manager))
    }
  }

  /// sb in a pane always claims SB_SESSION_ID, but the claim is optional in (M).
  @Test func aManagerConversationsPaneWithNoClaimIsThatConversation() throws {
    try withSessions { service in
      placeMe(service, in: manager)

      let result = service.queue.sync { try? service.scriptAuthority(args(), origin: .mac, caller: me) }

      #expect(result == .manager(manager))
    }
  }

  // MARK: Shapes that propose (refused until the card ships)

  @Test(arguments: [Pane.claude, .shell])
  func aWorkSessionsPaneProposesOnThatSession(_ pane: Pane) throws {
    try withSessions { service in
      placeMe(service, in: work, pane: pane)

      let result = service.queue.sync { try? service.scriptAuthority(args(caller: work), origin: .mac, caller: me) }

      #expect(result == .propose(work))
    }
  }

  /// A group chat's scoped MCP server sends `group` and the chat as its caller.
  @Test func aGroupChatInItsPaneProposesOnTheChat() throws {
    try withSessions { service in
      placeMe(service, in: chat)

      let result = service.queue.sync {
        try? service.scriptAuthority(args(caller: chat, group: "Flags"), origin: .mac, caller: me)
      }

      #expect(result == .propose(chat))
    }
  }

  // MARK: Shapes that never store

  /// (U) needs no group scope and (M) needs no group scope, so a scoped request never stores, wherever it runs.
  @Test(arguments: [nil, manager] as [String?])
  func aRequestWithAGroupScopeNeverStores(_ inside: String?) throws {
    try withSessions { service in
      if let inside { placeMe(service, in: inside) }

      let result = service.queue.sync {
        try? service.scriptAuthority(args(caller: inside, group: "Flags"), origin: .mac, caller: me)
      }

      #expect(result != .user && result != .sbd, "\(String(describing: result))")
      #expect(result != .manager(manager) && result != .manager(otherManager), "\(String(describing: result))")
    }
  }

  /// The Operator may not add a script or propose one, whether it claims itself, runs in its own pane, or both.
  @Test(arguments: [(true, true), (true, false), (false, true)])
  func theOperatorIsRefused(_ claims: Bool, _ inPane: Bool) throws {
    try withSessions { service in
      if inPane { placeMe(service, in: theOperator) }

      let outcome = classify(service, args(caller: claims ? theOperator : nil), caller: me)

      #expect(outcome.refused, "\(outcome)")
    }
  }

  /// A request that claims a caller is never the user. Outside every pane, the ancestry doesn't place it in the
  /// claimed session either.
  @Test(arguments: [manager, work, chat, "zzzzz"])
  func aClaimedCallerFromOutsideEveryPaneIsRefused(_ claimed: String) throws {
    try withSessions { service in
      let outcome = classify(service, args(caller: claimed), caller: me)

      #expect(outcome.refused, "\(outcome)")
    }
  }

  /// A work session that sets SB_SESSION_ID to a Manager conversation's id.
  @Test func aClaimedManagerFromInsideAWorkPaneIsRefused() throws {
    try withSessions { service in
      placeMe(service, in: work)

      let outcome = classify(service, args(caller: manager), caller: me)

      #expect(outcome.refused, "\(outcome)")
    }
  }

  /// (M) needs the client inside that conversation and inside no other session.
  @Test func aClientInsideAManagerAndAWorkSessionIsNotTheManager() throws {
    try withSessions { service in
      service.queue.sync {
        service.mac.snapshot.panes[service.paneName(manager, .claude)] = PaneRow(pid: myPid, dead: false, clients: 0)
        service.mac.snapshot.panes[service.paneName(work, .shell)] = PaneRow(
          pid: Int(getppid()), dead: false, clients: 0)
      }

      let result = service.queue.sync {
        try? service.scriptAuthority(args(caller: manager), origin: .mac, caller: me)
      }

      #expect(result != .user && result != .sbd, "\(String(describing: result))")
      #expect(result != .manager(manager) && result != .manager(otherManager), "\(String(describing: result))")
    }
  }

  @Test func aRemoteHostsSocketIsRefused() throws {
    try withSessions { service in
      for caller in [Caller.inProcess, me] {
        let outcome = classify(service, args(), origin: .remote("mini"), caller: caller)

        #expect(outcome.refused, "\(caller): \(outcome)")
      }
    }
  }

  /// `Int32.max` passes `Processes.isValidPid` and names no process.
  @Test(arguments: [nil, 0, Int(Int32.max)] as [Int?])
  func aClientWhosePidCantBeReadIsRefused(_ pid: Int?) throws {
    try withSessions { service in
      let outcome = classify(service, args(), caller: .client(pid: pid))

      #expect(outcome.refused, "\(outcome)")
    }
  }

  /// A program that a session starts with `tmux new-window` runs below sbd's tmux server and in no pane. The server
  /// is this process's parent here.
  @Test func aClientBelowTheTmuxServerInNoPaneIsRefused() throws {
    try withSessions { service in
      service.queue.sync {
        service.mac.snapshot.panes["opened-by-a-session"] = PaneRow(
          pid: unrelatedPane, dead: false, clients: 0, server: Int(getppid()))
      }

      let outcome = classify(service, args(), caller: me)

      #expect(outcome.refused, "\(outcome)")
    }
  }

  /// tmux keeps a dead pane's last pid, which no longer names its program, so the client is outside every pane.
  @Test func aDeadPaneDoesNotPlaceTheClientInItsSession() throws {
    try withSessions { service in
      service.queue.sync {
        service.mac.snapshot.panes[service.paneName(theOperator, .claude)] = PaneRow(
          pid: myPid, dead: true, clients: 0)
      }

      let result = service.queue.sync { try? service.scriptAuthority(args(), origin: .mac, caller: me) }

      #expect(result == .user)
    }
  }

  // MARK: Ancestry that stops before pid 1

  /// sbd can read a pid's parents only while they run. A parent that exits between two reads ends the walk early,
  /// and the client could then be below a pane that the walk never reached.
  @Test func anAncestryThatStopsBeforeLaunchdIsRefused() throws {
    try withSessions { service in
      let cut: Set<Int> = [myPid, Int(getppid())]
      try #require(!cut.contains(1))

      let outcome = service.queue.sync { () -> Outcome in
        do {
          return .authority("\(try service.scriptAuthority(args(), origin: .mac, ancestry: cut))")
        } catch {
          return .refused("\(error)")
        }
      }

      #expect(outcome.refused, "\(outcome)")
    }
  }

  /// The control for the test above: the same entry point with the whole ancestry is the user.
  @Test func aWholeAncestryThroughTheSameEntryPointIsTheUser() throws {
    try withSessions { service in
      let whole = try #require(Processes.ancestors(of: myPid))
      try #require(whole.contains(1))

      let result = service.queue.sync { try? service.scriptAuthority(args(), origin: .mac, ancestry: whole) }

      #expect(result == .user)
    }
  }

  // MARK: Below a running detached run (Risk 2)

  /// Gives the session a script schedule whose run is in flight, with the test process as the run's pid.
  private func runInFlight(_ service: Service, of id: String, start: Int64) throws {
    let made = try script("r1")
    service.queue.sync {
      var s = made
      s.running = created
      service.entries[id]?.session.addSchedule(s)
      service.runsInFlight[s.id] = RunInFlight(session: id, pid: myPid, start: start)
    }
  }

  /// No pane holds the client, and `sb` in the run has SB_SESSION_ID unset, so only the run's pid places it.
  @Test func aClientBelowAWorkSessionsRunProposesOnThatSession() throws {
    try withSessions { service in
      try runInFlight(service, of: work, start: try myStart())

      let result = service.queue.sync { try? service.scriptAuthority(args(), origin: .mac, caller: me) }

      #expect(result == .propose(work))
    }
  }

  @Test func aClientBelowAWorkSessionsRunThatClaimsTheSessionProposesOnIt() throws {
    try withSessions { service in
      try runInFlight(service, of: work, start: try myStart())

      let result = service.queue.sync { try? service.scriptAuthority(args(caller: work), origin: .mac, caller: me) }

      #expect(result == .propose(work))
    }
  }

  @Test(arguments: [nil, manager] as [String?])
  func aClientBelowAManagerConversationsRunIsThatConversation(_ claimed: String?) throws {
    try withSessions { service in
      try runInFlight(service, of: manager, start: try myStart())

      let result = service.queue.sync {
        try? service.scriptAuthority(args(caller: claimed), origin: .mac, caller: me)
      }

      #expect(result == .manager(manager))
    }
  }

  /// A run's pid that exited and was reused names another process, whose start time differs from the run's.
  @Test func aReusedRunPidDoesNotPlaceTheClientInTheRunsSession() throws {
    try withSessions { service in
      try runInFlight(service, of: theOperator, start: try myStart() - 1_000_000)

      let result = service.queue.sync { try? service.scriptAuthority(args(), origin: .mac, caller: me) }

      #expect(result == .user)
    }
  }

  /// A run whose start time sbd couldn't read still places a client below its pid, so the check fails closed.
  @Test func aRunWithNoStartTimePlacesTheClientInItsSession() throws {
    try withSessions { service in
      try runInFlight(service, of: work, start: 0)

      let result = service.queue.sync { try? service.scriptAuthority(args(), origin: .mac, caller: me) }

      #expect(result == .propose(work))
    }
  }

  @Test func aClientBelowTheOperatorsRunIsRefused() throws {
    try withSessions { service in
      try runInFlight(service, of: theOperator, start: try myStart())

      let outcome = classify(service, args(), caller: me)

      #expect(outcome.refused, "\(outcome)")
    }
  }
}

// MARK: - Stage 5: who approves a script card

/// The `schedule` request that the app's loop editor sends for a new script, as `BoardModel.addSchedule` builds it:
/// no `caller` and no `group`, with the user as the author.
private func appScriptArgs() -> JSON {
  ["session": .string(work), "every": "1h", "prompt": "git fetch", "by": "you", "runner": "script", "timeout": "5m"]
}

/// The data of a `script_proposed` event: `work` proposes to run `command` every hour in its own folder.
private func proposalData(_ command: String = "git fetch", target: String = work) -> JSON {
  [
    "target": .string(target), "targetName": .string("work \(target)"), "folder": "/tmp", "every": 3_600_000,
    "command": .string(command), "timeout": 300_000, "reason": "Keep the branch fresh.",
    "expires": .number(Double(nowMs() + ScriptProposal.expirySeconds * 1000)),
  ]
}

extension ScheduleScriptCallerTests {
  /// Decision 29 and Risk 1: only the user, from outside every session, approves a `script` card. `answer` runs the
  /// same `scriptAuthority` as an add and requires `.user`. The pane rows of the installed snapshot place the test
  /// process, so no shape needs a live pane. IntegrationTests/ScriptProposalTests runs the shapes with real panes.
  @Suite struct Approval {
    /// A service whose entries and store hold one session of each kind, with a second work session `w2`.
    private func withStoredSessions(_ body: (Service) throws -> Void) throws {
      try withService { service, _ in
        for (id, kind) in [
          (manager, SessionKind.manager), (otherManager, .manager), (work, .work), ("w2", .work), (chat, .chat),
          (theOperator, .operator),
        ] {
          let s = session(id, kind)
          try service.store.save(s)
          service.queue.sync { service.entries[id] = Service.Entry(session: s) }
        }
        service.queue.sync { service.mac.snapshot.taken = .max }
        try body(service)
      }
    }

    /// Opens a `script` card on `work` and returns its id.
    private func openCard(_ service: Service, _ command: String = "git fetch", target: String = work) -> Int64 {
      service.queue.sync { service.record(work, "script_proposed", proposalData(command, target: target)).id }
    }

    private func answerArgs(_ card: Int64, allow: Bool = true, caller claimed: String? = nil, group: String? = nil)
      -> JSON
    {
      var a: [String: JSON] = [
        "session": .string(work), "card": .number(Double(card)), "behavior": .string(allow ? "allow" : "deny"),
      ]
      if let claimed { a["caller"] = .string(claimed) }
      if let group { a["group"] = .string(group) }
      return .object(a)
    }

    /// The answer's result, or the text of its refusal.
    private func answer(_ service: Service, _ args: JSON, origin: RequestOrigin = .mac, caller: Caller) -> Outcome {
      service.queue.sync {
        do {
          return .authority((try service.answer(args, origin: origin, caller: caller)).text)
        } catch {
          return .refused("\(error)")
        }
      }
    }

    private func scripts(_ service: Service, _ id: String = work) -> [Schedule] {
      service.queue.sync { service.entries[id]?.session.allSchedules.filter { $0.runner == .script } ?? [] }
    }

    private func openCards(_ service: Service) -> [Int64] {
      service.queue.sync { service.entries[work]?.facts.cards.filter { $0.kind == .script }.map(\.id) ?? [] }
    }

    private func decisions(_ service: Service) throws -> [String] {
      try service.store.events(session: work, kinds: ["script_decided"]).compactMap { $0.data["decision"]?.string }
    }

    /// Expects a refused allow: the card stays open, no script is stored, and no decision is recorded.
    private func expectRefused(
      _ outcome: Outcome, _ service: Service, card: Int64, sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
      #expect(outcome.refused, "\(outcome)", sourceLocation: sourceLocation)
      #expect(openCards(service) == [card], sourceLocation: sourceLocation)
      #expect(scripts(service).isEmpty, sourceLocation: sourceLocation)
      #expect(try decisions(service).isEmpty, sourceLocation: sourceLocation)
    }

    // MARK: The app's requests are the user's

    /// The app runs outside every session and sends no caller, so its add of a script stores directly.
    @Test func theAppsScheduleRequestForAScriptIsTheUser() throws {
      try withStoredSessions { service in
        let result = service.queue.sync { try? service.scriptAuthority(appScriptArgs(), origin: .mac, caller: me) }

        #expect(result == .user)
      }
    }

    @Test func theAppsAnswerToAScriptCardIsTheUser() throws {
      try withStoredSessions { service in
        let result = service.queue.sync { try? service.scriptAuthority(answerArgs(13), origin: .mac, caller: me) }

        #expect(result == .user)
      }
    }

    // MARK: Allow

    @Test func anAllowFromOutsideEverySessionStoresTheCardsValues() throws {
      try withStoredSessions { service in
        let card = openCard(service, "git fetch --prune")

        let outcome = answer(service, answerArgs(card), caller: me)

        #expect(!outcome.refused, "\(outcome)")
        let stored = scripts(service)
        try #require(stored.count == 1, "\(stored)")
        #expect(stored[0].prompt == "git fetch --prune")
        #expect(stored[0].every == 3_600_000)
        #expect(stored[0].timeout == 300_000)
        #expect(stored[0].by == .claude)
        #expect(openCards(service).isEmpty)
        #expect(try decisions(service) == ["approved"])
      }
    }

    /// The guard's parity: an approval stores what the user's add stores for the same values, except the author.
    @Test func anApprovedScheduleEqualsTheUsersAddOfTheSameValues() throws {
      try withStoredSessions { service in
        let card = openCard(service)
        _ = answer(service, answerArgs(card), caller: me)
        var userArgs = appScriptArgs().object ?? [:]
        userArgs["session"] = "w2"

        let added = try service.queue.sync {
          try service.scheduleRequest("schedule", .object(userArgs), origin: .mac, caller: me)
        }

        var approved = try #require(scripts(service).first)
        var fromUser = try JSONCoding.convert(try #require(added["schedule"]), to: Schedule.self)
        approved.id = ""
        fromUser.id = ""
        approved.created = 0
        fromUser.created = 0
        approved.next = 0
        fromUser.next = 0
        #expect(approved.by == .claude)
        approved.by = fromUser.by
        #expect(approved == fromUser)
      }
    }

    // MARK: Allows that never store

    /// A request that claims a caller is never the user, wherever it runs.
    @Test(arguments: [work, manager, "zzzzz"])
    func anAllowThatClaimsACallerIsRefused(_ claimed: String) throws {
      try withStoredSessions { service in
        let card = openCard(service)

        try expectRefused(answer(service, answerArgs(card, caller: claimed), caller: me), service, card: card)
      }
    }

    /// The session unset CLAUDECODE and SB_SESSION_ID, so only its pane places the client.
    @Test(arguments: [Pane.claude, .shell])
    func anAllowFromTheProposersPaneIsRefused(_ pane: Pane) throws {
      try withStoredSessions { service in
        let card = openCard(service)
        placeMe(service, in: work, pane: pane)

        try expectRefused(answer(service, answerArgs(card), caller: me), service, card: card)
      }
    }

    /// Decision 29: a Manager conversation may add a script itself, but only the user approves a card.
    @Test(arguments: [nil, manager] as [String?])
    func anAllowFromAManagerConversationsPaneIsRefused(_ claimed: String?) throws {
      try withStoredSessions { service in
        let card = openCard(service)
        placeMe(service, in: manager)

        try expectRefused(answer(service, answerArgs(card, caller: claimed), caller: me), service, card: card)
      }
    }

    @Test func anAllowFromAnotherSessionsPaneIsRefused() throws {
      try withStoredSessions { service in
        let card = openCard(service)
        placeMe(service, in: theOperator)

        try expectRefused(answer(service, answerArgs(card), caller: me), service, card: card)
      }
    }

    @Test func anAllowWithAGroupScopeIsRefused() throws {
      try withStoredSessions { service in
        let card = openCard(service)

        try expectRefused(answer(service, answerArgs(card, group: "Flags"), caller: me), service, card: card)
      }
    }

    @Test(arguments: [Caller.inProcess, .client(pid: Int(getpid()))])
    func anAllowFromARemoteHostsSocketIsRefused(_ caller: Caller) throws {
      try withStoredSessions { service in
        let card = openCard(service)

        try expectRefused(
          answer(service, answerArgs(card), origin: .remote("mini"), caller: caller), service, card: card)
      }
    }

    /// Decision 29 reads "only the user" strictly: sbd's own code never approves a card for the user.
    @Test func anInProcessAllowIsRefused() throws {
      try withStoredSessions { service in
        let card = openCard(service)

        try expectRefused(answer(service, answerArgs(card), caller: .inProcess), service, card: card)
      }
    }

    @Test(arguments: [nil, 0, Int(Int32.max)] as [Int?])
    func anAllowFromAClientWhosePidCantBeReadIsRefused(_ pid: Int?) throws {
      try withStoredSessions { service in
        let card = openCard(service)

        try expectRefused(answer(service, answerArgs(card), caller: .client(pid: pid)), service, card: card)
      }
    }

    @Test func anAllowFromBelowTheTmuxServerInNoPaneIsRefused() throws {
      try withStoredSessions { service in
        let card = openCard(service)
        service.queue.sync {
          service.mac.snapshot.panes["opened-by-a-session"] = PaneRow(
            pid: unrelatedPane, dead: false, clients: 0, server: Int(getppid()))
        }

        try expectRefused(answer(service, answerArgs(card), caller: me), service, card: card)
      }
    }

    @Test func anAllowFromBelowARunningRunOfTheProposerIsRefused() throws {
      try withStoredSessions { service in
        let card = openCard(service)
        let made = try script("r1")
        let start = try myStart()
        service.queue.sync {
          var s = made
          s.running = created
          service.entries[work]?.session.addSchedule(s)
          service.runsInFlight[s.id] = RunInFlight(session: work, pid: myPid, start: start)
        }

        let outcome = answer(service, answerArgs(card), caller: me)

        #expect(outcome.refused, "\(outcome)")
        #expect(openCards(service) == [card])
        #expect(scripts(service).map(\.id) == [made.id])
      }
    }

    /// A removed script's id can come back on a schedule that sends its prompt, so an edit's card that names the id
    /// closes as stale and leaves that schedule as it is.
    @Test func anAllowOfAnEditWhoseScheduleNoLongerRunsAScriptIsStale() throws {
      try withStoredSessions { service throws in
        let prompt = try ScheduleRequest(every: "1h", prompt: "git fetch", by: nil, runner: nil)
          .makeSchedule(id: "r1", now: created)
        var data = proposalData("git pull").object ?? [:]
        data["schedule"] = "r1"
        data["before"] = ["command": "git fetch"]
        let card = service.queue.sync { () -> Int64 in
          service.entries[work]?.session.addSchedule(prompt)
          return service.record(work, "script_proposed", .object(data)).id
        }

        let outcome = answer(service, answerArgs(card), caller: me)

        #expect(outcome.refused, "\(outcome)")
        #expect(service.queue.sync { service.entries[work]?.session.schedule("r1") } == prompt)
        #expect(try decisions(service) == ["stale"])
      }
    }

    // MARK: Deny

    /// A deny stores nothing, so it keeps the rules of the other cards, which check no caller in sbd.
    @Test func aDenyFromTheProposersPaneClosesTheCardAndStoresNothing() throws {
      try withStoredSessions { service throws in
        let card = openCard(service)
        placeMe(service, in: work)

        let outcome = answer(service, answerArgs(card, allow: false), caller: me)

        #expect(!outcome.refused, "\(outcome)")
        #expect(openCards(service).isEmpty)
        #expect(scripts(service).isEmpty)
        #expect(try decisions(service) == ["denied"])
      }
    }
  }
}
