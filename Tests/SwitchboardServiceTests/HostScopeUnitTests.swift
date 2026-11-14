import Foundation
import Testing

@testable import SwitchboardCore
@testable import SwitchboardService

private func session(_ id: String, host: String?, name: String? = nil) -> Session {
  var s = Session(id: id, name: name ?? id, cwd: "/srv/repo", claudeSessionId: "u-\(id)", created: 5)
  s.host = host
  s.started = true
  return s
}

private func eventId(_ ns: UInt64 = UInt64(Date().timeIntervalSince1970 * 1_000_000_000), suffix: String = "a1b2")
  -> String
{
  let digits = String(ns)
  return "\(String(repeating: "0", count: 20 - digits.count))\(digits)-77-\(suffix)"
}

private func payload(_ marker: String, kind: String = "Notification") -> JSON {
  [
    "hook_event_name": .string(kind), "session_id": "hijacked", "notification_type": "sb_test",
    "probe": .string(marker),
  ]
}

private func hook(session: JSON?, _ payload: JSON? = payload("p"), id: String? = eventId(), extra: [String: JSON] = [:])
  -> Request
{
  var args = extra
  if let session { args["session"] = session }
  if let payload { args["payload"] = payload }
  if let id { args["id"] = .string(id) }
  return Request(op: "hook", args: .object(args))
}

private let twoHosts: [String: JSON] = [
  "mini": ["kind": "ssh", "destination": .string(LinkBench.destination)],
  "other": ["kind": "ssh", "destination": "haacked@other.local"],
]

/// A service that holds a local session `l1`, mini's `m1`, and other's `o1`. Its order window is `windowMs`. No
/// link connects unless a request waits for its host. `sbPath` is the `sb` that a `cli` request runs.
private func withSessions(
  windowMs: Int64 = 20, sbPath: String = "/usr/bin/true", hosts: [String: JSON] = twoHosts,
  _ body: (Service) throws -> Void
) throws {
  // A request that a missing guard lets through runs no claude or tmux on this Mac.
  let config: [String: JSON] = ["claude": "/usr/bin/true", "tmux": "/usr/bin/true"]
  try withHostService(hosts: hosts, config: config, sbPath: sbPath) { service, _ in
    service.queue.sync {
      service.hostEventWindowMs = windowMs
      service.entries["l1"] = Service.Entry(session: session("l1", host: nil, name: "local"))
      service.entries["m1"] = Service.Entry(session: session("m1", host: "mini", name: "l1"))
      service.entries["o1"] = Service.Entry(session: session("o1", host: "other", name: "m1"))
    }
    try body(service)
  }
}

/// What a request can change: the log, each session's record, cards, and queued messages.
private struct ScopeState: Equatable {
  var events: [Event]
  var sessions: [String: JSON]
  var cards: [String: [Card]]
  var pending: [String: Int]
}

extension Service {
  /// Every event in the log.
  fileprivate func logged() throws -> [Event] { try queue.sync { try store.events() } }

  fileprivate func scopeState() throws -> ScopeState {
    try queue.sync {
      ScopeState(
        events: try store.events(), sessions: try entries.mapValues { try JSON(encoding: $0.session) },
        cards: entries.mapValues(\.facts.cards), pending: entries.mapValues(\.pending.count))
    }
  }
}

/// Waits until every event that the service took has left the order window, so the event is in the log.
private func settle(_ service: Service) {
  let left = waitUntil(seconds: 10) {
    service.queue.sync { service.hostEvents.values.allSatisfy { $0.payloads.isEmpty } }
  }
  #expect(left, "an event stayed in the order window")
}

/// The scope of a request whose origin is a host: a hook must name a session that sbd holds on that host, and any
/// other op must be one of the table's ops with only the keys of its row. The origin is the socket's, and nothing in
/// the request can change it.
@Suite struct HostScopeRequestTests {
  @Test(.timeLimit(.minutes(1)))
  func aHookForTheHostsOwnSessionIsRecordedOnce() throws {
    try withSessions { service in
      let id = eventId()

      let first = service.handle(hook(session: "m1", payload("own"), id: id), origin: .remote("mini"))
      let second = service.handle(hook(session: "m1", payload("changed"), id: id), origin: .remote("mini"))
      settle(service)
      let third = service.handle(hook(session: "m1", payload("again"), id: id), origin: .remote("mini"))
      settle(service)

      #expect(first.ok && second.ok && third.ok)
      let recorded = try service.logged()
      #expect(recorded.map(\.session) == ["m1"])
      #expect(recorded.first?.data["probe"] == "own")
      #expect(try service.queue.sync { try service.store.hasHostEvent(#require(HostEventID(id))) })
    }
  }

  @Test(
    .timeLimit(.minutes(1)),
    arguments: [
      ("mini", JSON.string("l1")), ("mini", "o1"), ("other", "m1"), ("other", "l1"), ("mini", "nope"), ("mini", ""),
      ("mini", "local"), ("mini", "m"), ("mini", "M1"), ("mini", "m1 "), ("mini", " m1"), ("mini", "m1\0"),
      ("mini", "m1\n"), ("mini", .null), ("mini", 1), ("mini", ["m1"]), ("mini", ["id": "m1"]), ("mini", true),
      // The socket's host is compared as the exact name on the session's record.
      ("Mini", "m1"), ("mini ", "m1"), ("", "l1"), ("", "m1"), ("mini/../other", "o1"), ("local", "l1"),
    ] as [(String, JSON)])
  func aHookThatNamesNoSessionOfTheSocketsHostIsRefusedAndRecordsNothing(host: String, named: JSON) throws {
    try withSessions { service in
      for kind in ["Notification", "SessionStart", "PermissionRequest", "PreToolUse", "Stop"] {
        let answer = service.handle(
          hook(
            session: named, payload("scope", kind: kind), id: eventId(suffix: "00aa"),
            extra: ["host": .string(host), "origin": "mac"]),
          origin: .remote(host))

        #expect(!answer.ok, "\(kind)")
        #expect(answer.error?.contains("that session is not on \(host)") == true, "\(answer.error ?? "")")
      }
      settle(service)

      let recorded = try service.logged()
      #expect(recorded.isEmpty)
      #expect(service.queue.sync { service.held.isEmpty && service.hostEvents.isEmpty })
      #expect(
        service.queue.sync { service.entries.values.map(\.session.claudeSessionId).sorted() } == [
          "u-l1", "u-m1", "u-o1",
        ])
    }
  }

  /// m1 is the name of other's session and l1 is the name of mini's. A name never stands in for an id.
  @Test(.timeLimit(.minutes(1)))
  func aSessionIsFoundByItsIdAndNeverByAName() throws {
    try withSessions { service in
      let onOther = service.handle(hook(session: "m1", payload("by-name")), origin: .remote("other"))
      let onMini = service.handle(hook(session: "l1", payload("by-name")), origin: .remote("mini"))
      settle(service)

      #expect(!onOther.ok && !onMini.ok)
      #expect(service.queue.sync { service.held.isEmpty && service.hostEvents.isEmpty })
      let recorded = try service.logged()
      #expect(recorded.isEmpty)
    }
  }

  /// An op that the table refuses fails with its name. An op that the table admits fails here too, because these
  /// arguments hold keys that it does not read, and the refusal names one of them.
  @Test(
    .timeLimit(.minutes(1)),
    arguments: Array(
      Set(
        [
          "send", "new", "rm", "rm-done", "cleanup", "stop", "resume", "open", "done", "answer", "rename", "note",
          "wait", "ls", "get", "events", "screen", "terminals", "shell", "ping", "clock", "hosts", "host-connect",
          "host-disconnect", "live", "accounts", "account-use", "account-move", "group-account", "usage", "mcp", "poll",
          "import", "importable", "triage", "manager", "chat", "spawn", "followup-add", "plan-ls", "docket-start",
          "Hook", "hook ", " hook", "hooks", "", "HOOK", "hook\0", "no-such-op",
        ] + PlannedScope.refused)
    ).sorted())
  func everyRefusedOpAndEveryKeyAnOpDoesNotReadIsRefusedForAHostAndChangesNothing(op: String) throws {
    try withSessions { service in
      let args: [String: JSON] = [
        "session": "m1", "text": "pwned", "name": "pwned", "path": "/tmp", "host": "mini", "advance": 3_600_000,
        "set": 1, "payload": payload("op"), "id": .string(eventId()), "images": ["a.png"], "account": "x",
        "behavior": "allow",
      ]
      let clock = nowMs()

      let answer = service.handle(Request(op: op, args: .object(args)), origin: .remote("mini"))
      settle(service)

      #expect(!answer.ok)
      if let row = PlannedScope.rows[op] {
        // A short key such as `id` is a part of ordinary words, so only the longer keys show which key was named.
        let unread = Set(args.keys).subtracting(row.keys).filter { $0.count >= 4 }
        let error = answer.error ?? ""
        #expect(unread.contains { error.contains($0) }, "\(error)")
        #expect(!error.contains("can't run from mini") && !error.contains("that session is not on mini"), "\(error)")
      } else {
        #expect(answer.error?.contains("\(op) can't run from mini") == true, "\(answer.error ?? "")")
      }
      #expect(service.queue.sync { service.held.isEmpty && service.hostEvents.isEmpty })
      let recorded = try service.logged()
      #expect(recorded.isEmpty)
      #expect(service.queue.sync { service.entries.keys.sorted() } == ["l1", "m1", "o1"])
      #expect(service.queue.sync { service.entries["m1"]?.session.name } == "l1")
      #expect(nowMs() - clock < 600_000)
      #expect(service.hostLinks.values.allSatisfy { $0.status.state == .disconnected })
    }
  }

  @Test(
    .timeLimit(.minutes(1)),
    arguments: [
      (JSON?.none, String?.some(eventId())), (.string("text"), eventId()), (.array([payload("p")]), eventId()),
      (JSON.null, eventId()), (1, eventId()), (payload("p"), nil), (payload("p"), ""), (payload("p"), "not-an-id"),
      (payload("p"), "1-2-abcd"), (payload("p"), eventId() + " "), (payload("p"), "../" + eventId()),
    ] as [(JSON?, String?)])
  func aHookOfTheHostsOwnSessionWithNoPayloadObjectOrNoEventIdIsRefusedAndRecordsNothing(
    sent: JSON?, id: String?
  ) throws {
    try withSessions { service in
      let answer = service.handle(hook(session: "m1", sent, id: id), origin: .remote("mini"))
      settle(service)

      #expect(!answer.ok)
      #expect(service.queue.sync { service.held.isEmpty && service.hostEvents.isEmpty })
      let recorded = try service.logged()
      #expect(recorded.isEmpty)
    }
  }

  /// The kinds that only sbd records, a missing kind, kinds that are not strings, and other spellings of a hook.
  private static let kindsNoClaudeHookProduces: [JSON?] = [
    "send_pending", "send_decided", "sent", "delivered", "answered", "card_closed", "dialog_closed", "stopped",
    "exited", "running", "idle", "job", "pr", "branch", "worktree", "cleanup", "triage", "merge", "docket", "done",
    "created", "started", "resumed", "wait", "note", "ack", "link_down", "link_up", "reconciled", "unknown", "",
    nil, JSON.null, 7, true, ["Stop"], ["name": "Stop"], "stop", "STOP", "Stop ", " Stop", "Stop\n", "Stop\0",
    "Stop,SessionEnd", "PreCompact",
  ]

  private static func forged(_ kind: JSON?) -> JSON {
    var forged: [String: JSON] = [
      "probe": "forged", "group": "g", "groupName": "harmless", "text": "FORGED",
      "targets": [["id": "l1", "name": "m1"]], "expires": .number(Double(nowMs() + 3_600_000)),
    ]
    if let kind { forged["hook_event_name"] = kind }
    return .object(forged)
  }

  @Test(.timeLimit(.minutes(1)), arguments: kindsNoClaudeHookProduces)
  func aHookOfTheHostsOwnSessionWhoseKindIsNotAClaudeHookIsRefusedAndRecordsNothing(kind: JSON?) throws {
    try withSessions { service in
      let id = eventId()

      let answer = service.handle(hook(session: "m1", Self.forged(kind), id: id), origin: .remote("mini"))
      settle(service)

      #expect(!answer.ok)
      #expect(answer.error?.contains("needs the name of a claude hook") == true, "\(answer.error ?? "")")
      let recorded = try service.logged()
      #expect(recorded.isEmpty)
      #expect(service.queue.sync { service.held.isEmpty && service.hostEvents.isEmpty })
      #expect(service.queue.sync { service.entries.values.allSatisfy { $0.facts.cards.isEmpty } })
      #expect(try service.queue.sync { try !service.store.hasHostEvent(#require(HostEventID(id))) })
    }
  }

  /// The check runs again where an event is applied, which is the path that a spool line takes.
  @Test(.timeLimit(.minutes(1)), arguments: kindsNoClaudeHookProduces)
  func anEventWhoseKindIsNotAClaudeHookIsNotAppliedAndItsIdIsNotRecorded(kind: JSON?) throws {
    try withSessions { service in
      let id = try #require(HostEventID(eventId()))

      #expect(throws: APIError.self) {
        try service.queue.sync { _ = try service.applyHostEvent("m1", id, Self.forged(kind)) }
      }

      let recorded = try service.logged()
      #expect(recorded.isEmpty)
      #expect(service.queue.sync { service.entries.values.allSatisfy { $0.facts.cards.isEmpty } })
      #expect(try service.queue.sync { try !service.store.hasHostEvent(id) })
    }
  }

  @Test(.timeLimit(.minutes(1)), arguments: SessionFacts.hookKinds)
  func anEventOfEachClaudeHookIsApplied(kind: String) throws {
    try withSessions { service in
      let id = try #require(HostEventID(eventId()))

      let applied = try service.queue.sync { try service.applyHostEvent("m1", id, payload("each", kind: kind)) }

      #expect(applied?.event.kind == kind)
      let recorded = try service.logged()
      #expect(recorded.filter { $0.data["probe"] == "each" }.map(\.kind) == [kind])
    }
  }

  /// An id that another host recorded is still one event, so a second host can't record it again.
  @Test(.timeLimit(.minutes(1)))
  func anIdThatOneHostRecordedIsNotRecordedAgainForAnotherHost() throws {
    try withSessions { service in
      let id = eventId()
      _ = service.handle(hook(session: "m1", payload("first"), id: id), origin: .remote("mini"))
      settle(service)

      let answer = service.handle(hook(session: "o1", payload("second"), id: id), origin: .remote("other"))
      settle(service)

      #expect(answer.ok)
      let recorded = try service.logged()
      #expect(recorded.map(\.session) == ["m1"])
    }
  }

  /// The same request is a hook that sbd's own socket takes for any session.
  @Test(.timeLimit(.minutes(1)))
  func theOriginOfSbdsOwnSocketTakesAHookForALocalSession() throws {
    try withSessions { service in
      let onHost = service.handle(hook(session: "l1", payload("mac"), id: nil), origin: .remote("mini"))
      let onMac = service.handle(hook(session: "l1", payload("mac"), id: nil))

      #expect(!onHost.ok)
      #expect(onMac.ok)
      let recorded = try service.logged()
      #expect(recorded.map(\.session) == ["l1"])
    }
  }

  /// A session that sbd forgets while its event waits in the order window gets no event.
  @Test(.timeLimit(.minutes(1)))
  func anEventOfASessionThatWasRemovedInTheOrderWindowIsNotRecorded() throws {
    // The removal must land inside the window, so the test keeps the window of sbd.
    try withSessions(windowMs: HostEventOrder.windowMs) { service in
      let answer = service.handle(hook(session: "m1", payload("gone")), origin: .remote("mini"))
      service.queue.sync { service.entries["m1"] = nil }
      settle(service)

      #expect(answer.ok)
      let recorded = try service.logged()
      #expect(recorded.isEmpty)
    }
  }

  @Test(.timeLimit(.minutes(1)), arguments: [-86_400, 86_400])
  func theTimeOfAHostsEventIsNeverAfterNowOrBeforeTheSessionsLastEvent(secondsOff: Int) throws {
    try withSessions { service in
      let before = service.queue.sync { service.record("m1", "note", ["text": "earlier"]) }
      let ns = UInt64(Int64(Date().timeIntervalSince1970 * 1_000_000_000) + Int64(secondsOff) * 1_000_000_000)

      _ = service.handle(hook(session: "m1", payload("time"), id: eventId(ns)), origin: .remote("mini"))
      _ = service.handle(
        hook(session: "m1", payload("max"), id: eventId(UInt64.max, suffix: "ffff")), origin: .remote("mini"))
      settle(service)

      let recorded = try service.logged().filter { $0.kind == "Notification" }
      #expect(recorded.count == 2)
      for event in recorded {
        #expect(event.t >= before.t)
        #expect(event.t <= nowMs())
      }
    }
  }
}

// MARK: The ops that a host may send

/// A checkout on branch main with one commit, whose origin is github.com/o/n, as a host's `repos` needs.
private func makeCheckout(_ path: String) throws {
  try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
  let p = Process()
  p.executableURL = URL(fileURLWithPath: "/bin/sh")
  p.arguments = [
    "-c",
    "git init -q -b main . && git commit -q --allow-empty -m first && git remote add origin https://github.com/o/n.git",
  ]
  p.currentDirectoryURL = URL(fileURLWithPath: path)
  p.environment = [
    "PATH": "/usr/bin:/bin", "HOME": path, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null",
    "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.com", "GIT_COMMITTER_NAME": "t",
    "GIT_COMMITTER_EMAIL": "t@example.com",
  ]
  p.standardOutput = FileHandle.nullDevice
  p.standardError = FileHandle.nullDevice
  try p.run()
  p.waitUntilExit()
  guard p.terminationStatus == 0 else { throw APIError("git init in \(path) exited with \(p.terminationStatus)") }
}

/// A service whose host mini is ready, with `o/n` in mini's `repos`. It holds the local `l1` (named `local`) and
/// `l2` (named `twin`), and mini's `m1` (named `l1`), `m2`, and `mq7x` (named `twin`), each on mini in a folder on
/// the box. `roots` holds the folders whose paths differ from one bench to the next.
private func withReadySessions(_ body: (Service, BoxFacts, _ roots: [String]) throws -> Void) throws {
  let root = try makeShortTempFolder()
  defer { try? FileManager.default.removeItem(atPath: root) }
  try makeCheckout("\(root)/n")
  let config: [String: JSON] = ["claude": "/usr/bin/true", "tmux": "/usr/bin/true"]
  try withReadyService(host: ["repos": ["o/n": .string("\(root)/n")]], config: config) { bench, service, facts in
    let cwd = "\(facts.home)/work"
    try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
    func onMini(_ id: String, _ name: String) -> Service.Entry {
      var s = session(id, host: "mini", name: name)
      s.cwd = cwd
      return Service.Entry(session: s)
    }
    service.queue.sync {
      service.hostEventWindowMs = 20
      service.entries["l1"] = Service.Entry(session: session("l1", host: nil, name: "local"))
      service.entries["l2"] = Service.Entry(session: session("l2", host: nil, name: "twin"))
      service.entries["m1"] = onMini("m1", "l1")
      service.entries["m2"] = onMini("m2", "m2")
      service.entries["mq7x"] = onMini("mq7x", "twin")
    }
    let roots = [bench.home, service.home.path, facts.home, root].flatMap { [real($0), $0] }
    try body(service, facts, roots.sorted { $0.count > $1.count })
  }
}

/// The answer with every number set to 0 and every root replaced, so two benches can be compared.
private func comparable(_ json: JSON?, _ roots: [String]) -> JSON? {
  switch json {
  case .number: .number(0)
  case .string(let text): .string(roots.reduce(text) { $0.replacingOccurrences(of: $1, with: "<root>") })
  case .array(let items): .array(items.map { comparable($0, roots) ?? .null })
  case .object(let fields): .object(fields.mapValues { comparable($0, roots) ?? .null })
  default: json
  }
}

private func comparable(_ answer: Response, _ roots: [String]) -> JSON? {
  comparable(
    ["ok": .bool(answer.ok), "error": answer.error.map(JSON.string) ?? .null, "result": answer.result ?? .null], roots)
}

extension Service {
  /// The kinds of the events of each session, and each session's record, for two benches to compare.
  fileprivate func comparableState(_ roots: [String]) throws -> JSON? {
    let state = try scopeState()
    return comparable(
      [
        "events": .array(state.events.map { .string("\($0.session) \($0.kind)") }),
        "sessions": .object(state.sessions), "pending": .object(state.pending.mapValues { .number(Double($0)) }),
      ], roots)
  }

  /// The home's paths and the random ids of every note and wait, which differ from one bench to the next.
  fileprivate func benchRoots() -> [String] {
    let generated = queue.sync {
      entries.values.flatMap { ($0.session.notes ?? []).map(\.id) + ($0.session.waits ?? []).map(\.id) }
    }
    return [home.path, real(home.path)] + generated
  }
}

/// A request of the table for `m1` whose effect the op would make if it ran.
private let ownRequests: [(op: String, args: [String: JSON])] = [
  ("ping", [:]), ("get", ["session": "m1"]), ("reply", ["session": "m1"]), ("events", ["session": "m1"]),
  ("done", ["session": "m1", "done": true]), ("rename", ["session": "m1", "name": "renamed"]),
  ("issue", ["session": "m1", "issue": "12"]), ("note", ["session": "m1", "text": "a note", "by": "you"]),
  ("remove-note", ["session": "m1", "note": "n1"]), ("resolve-note", ["session": "m1", "note": "n1", "by": "you"]),
  ("wait", ["session": "m1", "note": "later", "by": "claude"]), ("clear-wait", ["session": "m1"]),
  ("resolve-wait", ["session": "m1", "outcome": "it happened"]),
  ("summary-set", ["session": "m1", "card": ["summary": "a turn"]]),
]

/// The requests of the table that wait for the session's host first.
private let ownHostRequests: [(op: String, args: [String: JSON])] = [
  ("send", ["session": "m1", "text": "hello"]), ("answer", ["session": "m1", "behavior": "allow"]),
  ("stop", ["session": "m1"]), ("screen", ["session": "m1", "pane": "claude"]), ("terminals", ["session": "m1"]),
  ("shell", ["session": "m1", "open": false]), ("open", ["session": "m1"]),
  ("resume", ["session": "m1", "prompt": "go on"]),
]

private func expectLinksDisconnected(_ service: Service) {
  #expect(service.hostLinks.values.allSatisfy { $0.status.state == .disconnected }, "a refusal touched a host")
}

private func ids(_ answer: Response) -> [String] {
  (answer.result?.array ?? []).compactMap { $0["id"]?.string }.sorted()
}

/// The ops of the scope table on a host's socket: each one reads and acts only on that host's sessions.
@Suite struct HostScopeOpTests {
  // MARK: Refs off the host

  /// `l1` is the local session's id and also `m1`'s name. `local` is the local session's name. `l` and `o` are
  /// prefixes of the ids of sessions off mini.
  @Test(.timeLimit(.minutes(1)), arguments: RefSlot.all, ["l1", "o1", "local", "l", "o"])
  func everyRefToASessionOffTheHostFailsAndChangesNothing(slot: RefSlot, ref: String) throws {
    try withSessions { service in
      let before = try service.scopeState()

      let answer = service.handle(
        Request(op: slot.op, args: .object(slot.args(with: .string(ref)))), origin: .remote("mini"))
      settle(service)

      #expect(!answer.ok)
      #expect(answer.error?.contains("that session is not on mini") == true, "\(answer.error ?? "")")
      #expect(try service.scopeState() == before)
      expectLinksDisconnected(service)
    }
  }

  // MARK: The same answer as on sbd's own socket

  /// Two benches run the same request, one from this Mac and one from mini, and end in the same state.
  @Test(.timeLimit(.minutes(1)), arguments: ownRequests)
  func anOpForTheHostsOwnSessionAnswersAsOnSbdsOwnSocket(op: String, args: [String: JSON]) throws {
    try withSessions { onMac in
      try withSessions { onMini in
        let request = Request(op: op, args: .object(args))

        let fromMac = onMac.handle(request)
        let fromMini = onMini.handle(request, origin: .remote("mini"))
        settle(onMac)
        settle(onMini)

        let macRoots = onMac.benchRoots()
        let miniRoots = onMini.benchRoots()
        #expect(comparable(fromMini, miniRoots) == comparable(fromMac, macRoots))
        let macState = try onMac.comparableState(macRoots)
        let miniState = try onMini.comparableState(miniRoots)
        #expect(miniState == macState)
      }
    }
  }

  @Test(.timeLimit(.minutes(3)), arguments: ownHostRequests)
  func anOpThatWaitsForTheHostAnswersForTheHostsOwnSessionAsOnSbdsOwnSocket(op: String, args: [String: JSON]) throws {
    try withReadySessions { onMac, _, macRoots in
      try withReadySessions { onMini, _, miniRoots in
        let request = Request(op: op, args: .object(args))

        let fromMac = onMac.handle(request)
        let fromMini = onMini.handle(request, origin: .remote("mini"))
        settle(onMac)
        settle(onMini)

        #expect(comparable(fromMini, miniRoots) == comparable(fromMac, macRoots))
        let macState = try onMac.comparableState(macRoots)
        let miniState = try onMini.comparableState(miniRoots)
        #expect(miniState == macState)
      }
    }
  }

  // MARK: Lists

  @Test(.timeLimit(.minutes(1)))
  func lsOnAHostsSocketListsOnlyTheHostsSessions() throws {
    try withSessions { service in
      let onMini = service.handle(Request(op: "ls"), origin: .remote("mini"))
      let onOther = service.handle(Request(op: "ls"), origin: .remote("other"))
      let onMac = service.handle(Request(op: "ls"))

      #expect(onMini.ok && onOther.ok && onMac.ok)
      #expect(ids(onMini) == ["m1"])
      #expect(ids(onOther) == ["o1"])
      #expect(ids(onMac) == ["l1", "m1", "o1"])
    }
  }

  @Test(
    .timeLimit(.minutes(1)),
    arguments: [[:], ["since": 0], ["limit": 1000], ["since": 0, "limit": 1000]] as [[String: JSON]])
  func eventsWithNoSessionOnAHostsSocketReturnOnlyTheHostsEvents(args: [String: JSON]) throws {
    try withSessions { service in
      service.queue.sync {
        for id in ["l1", "m1", "o1"] { _ = service.record(id, "note", ["text": .string("by \(id)")]) }
      }

      let answer = service.handle(Request(op: "events", args: .object(args)), origin: .remote("mini"))

      #expect(answer.ok, "\(answer.error ?? "")")
      let sessions = (answer.result?.array ?? []).compactMap { $0["session"]?.string }
      #expect(!sessions.isEmpty)
      #expect(Set(sessions) == ["m1"])
    }
  }

  // MARK: A send card

  private static func sendCard(_ targets: [(id: String, name: String)]) -> JSON {
    [
      "group": "g", "groupName": "Flags", "text": "Rebase on main.",
      "targets": .array(targets.map { ["id": .string($0.id), "name": .string($0.name)] }),
      "expires": .number(Double(nowMs() + 3_600_000)),
    ]
  }

  /// A `send` card's targets are sessions that the answer reaches, so each one must be on the host.
  @Test(.timeLimit(.minutes(2)), arguments: ["allow", "deny"])
  func anAnswerToASendCardWithATargetOffTheHostFailsAndSendsNothing(behavior: String) throws {
    try withReadySessions { service, _, _ in
      let card = service.queue.sync {
        service.record("m1", "send_pending", Self.sendCard([("m2", "m2"), ("l1", "local")]))
      }
      let before = try service.scopeState()

      let answer = service.handle(
        Request(
          op: "answer", args: ["session": "m1", "card": .number(Double(card.id)), "behavior": .string(behavior)]),
        origin: .remote("mini"))
      settle(service)

      #expect(!answer.ok)
      #expect(answer.error?.contains("not on mini") == true, "\(answer.error ?? "")")
      #expect(try service.scopeState() == before)
    }
  }

  @Test(.timeLimit(.minutes(2)))
  func anAnswerToASendCardWhoseTargetsAreAllOnTheHostIsTaken() throws {
    try withReadySessions { service, _, _ in
      let card = service.queue.sync { service.record("m1", "send_pending", Self.sendCard([("m2", "m2")])) }

      let answer = service.handle(
        Request(op: "answer", args: ["session": "m1", "card": .number(Double(card.id)), "behavior": "deny"]),
        origin: .remote("mini"))
      settle(service)

      #expect(answer.ok, "\(answer.error ?? "")")
      let recorded = try service.logged()
      #expect(recorded.contains { $0.session == "m1" && $0.kind == "send_decided" })
    }
  }

  // MARK: New sessions

  @Test(.timeLimit(.minutes(2)), arguments: [JSON?.none, .string("mini")])
  func aNewSessionFromTheHostStartsOnTheHost(host: JSON?) throws {
    try withReadySessions { service, facts, _ in
      var args: [String: JSON] = ["path": .string("\(facts.home)/work"), "prompt": "hello"]
      args["host"] = host

      let answer = service.handle(Request(op: "new", args: .object(args)), origin: .remote("mini"))

      #expect(answer.ok, "\(answer.error ?? "")")
      let id = try #require(answer.result?["id"]?.string)
      #expect(answer.result?["host"] == "mini")
      #expect(service.queue.sync { service.entries[id]?.session.host } == "mini")
    }
  }

  @Test(.timeLimit(.minutes(2)), arguments: [JSON?.none, .string("mini")])
  func aSpawnFromTheHostStartsOnTheHost(host: JSON?) throws {
    try withReadySessions { service, _, _ in
      var args: [String: JSON] = ["repository": "o/n", "branch": "b1", "prompt": "hello"]
      args["host"] = host

      let answer = service.handle(Request(op: "spawn", args: .object(args)), origin: .remote("mini"))

      #expect(answer.ok, "\(answer.error ?? "")")
      let id = try #require(answer.result?["id"]?.string)
      #expect(answer.result?["host"] == "mini")
      #expect(service.queue.sync { service.entries[id]?.session.host } == "mini")
    }
  }

  /// `twin` names both the local `l2` and mini's `mq7x`, so only the rewrite to mini's exact id lets the op's own
  /// lookup over every session find the parent.
  @Test(.timeLimit(.minutes(2)), arguments: ["new", "spawn"])
  func aNewSessionFromTheHostTakesItsParentAmongTheHostsSessions(op: String) throws {
    try withReadySessions { service, facts, _ in
      let args: [String: JSON] =
        op == "new"
        ? ["path": .string("\(facts.home)/work"), "prompt": "hello", "parent": "twin"]
        : ["repository": "o/n", "branch": "b2", "prompt": "hello", "parent": "twin"]

      let answer = service.handle(Request(op: op, args: .object(args)), origin: .remote("mini"))

      #expect(answer.ok, "\(answer.error ?? "")")
      let id = try #require(answer.result?["id"]?.string)
      #expect(service.queue.sync { service.entries[id]?.session.parent } == "mq7x")
      #expect(service.queue.sync { service.entries[id]?.session.host } == "mini")
    }
  }

  @Test(.timeLimit(.minutes(1)), arguments: ["new", "spawn"], ["local", "other"])
  func aNewSessionFromTheHostOnAnotherMachineFailsAndChangesNothing(op: String, host: String) throws {
    try withSessions { service in
      var args = PlannedScope.baseArgs(op)
      args["host"] = .string(host)
      let before = try service.scopeState()

      let answer = service.handle(Request(op: op, args: .object(args)), origin: .remote("mini"))

      #expect(!answer.ok)
      #expect(answer.error?.contains("can start sessions only on mini") == true, "\(answer.error ?? "")")
      #expect(try service.scopeState() == before)
      expectLinksDisconnected(service)
    }
  }

  /// `create` checks the parent's host itself, in the block that saves the record, so a caller that skipped the
  /// scope still can't give a session on mini a local parent.
  @Test(.timeLimit(.minutes(2)), arguments: ["new", "spawn"])
  func aSessionFromTheHostWithAParentOffTheHostIsNotCreated(op: String) throws {
    try withReadySessions { service, facts, _ in
      let before = try service.scopeState()

      do {
        if op == "new" {
          _ = try service.newSession(
            NewSession(path: "\(facts.home)/work", prompt: "hello", parent: "l1"), origin: .remote("mini"))
        } else {
          _ = try service.spawn(
            ["repository": "o/n", "branch": "b3", "prompt": "hello", "parent": "l1"], origin: .remote("mini"))
        }
        Issue.record("\(op) from mini created a session with the local parent l1")
      } catch {
        #expect("\(error)".contains("not on mini"), "\(error)")
      }

      #expect(try service.scopeState() == before)
    }
  }

  // MARK: The recheck

  /// mini's `m1` leaves and a local session takes its id after `authorize` checked it. The op must not act on the
  /// local session. `afterHostAuthorize` runs off the state queue, between `authorize` and the op.
  @Test(
    .timeLimit(.minutes(1)),
    arguments: (ownRequests + ownHostRequests).filter { $0.args["session"] == "m1" })
  func anOpWhoseSessionLeftTheHostAfterTheCheckFailsAndChangesNothing(op: String, args: [String: JSON]) throws {
    try withSessions { service in
      let taken = session("m1", host: nil, name: "taken")
      service.afterHostAuthorize = {
        service.queue.sync { service.entries["m1"] = Service.Entry(session: taken) }
      }

      let answer = service.handle(Request(op: op, args: .object(args)), origin: .remote("mini"))
      settle(service)

      #expect(!answer.ok)
      #expect(answer.error?.contains("that session is not on mini") == true, "\(answer.error ?? "")")
      #expect(try service.logged().isEmpty)
      let after = try service.queue.sync { try JSON(encoding: service.entries["m1"]!.session) }
      #expect(try after == JSON(encoding: taken))
      #expect(
        service.queue.sync { service.entries["m1"]!.pending.isEmpty && service.entries["m1"]!.facts.cards.isEmpty })
      expectLinksDisconnected(service)
    }
  }

  /// The recheck covers every session that the request names, not only `session`. mini's `m2` leaves and a local
  /// session takes its id after `authorize` checked it.
  @Test(
    .timeLimit(.minutes(2)),
    arguments: [
      ("send", ["session": "m1", "text": "hello", "from": "m2"]), ("events", ["sessions": ["m1", "m2"]]),
      ("wait", ["session": "m1", "kind": "session", "target": "m2", "state": "idle"]),
    ] as [(String, [String: JSON])])
  func anOpWhoseOtherSessionLeftTheHostAfterTheCheckFailsAndChangesNothing(op: String, args: [String: JSON]) throws {
    try withReadySessions { service, _, _ in
      let taken = session("m2", host: nil, name: "taken")
      service.afterHostAuthorize = {
        service.queue.sync { service.entries["m2"] = Service.Entry(session: taken) }
      }
      let before = try service.logged()

      let answer = service.handle(Request(op: op, args: .object(args)), origin: .remote("mini"))
      settle(service)

      #expect(!answer.ok)
      #expect(answer.error?.contains("that session is not on mini") == true, "\(answer.error ?? "")")
      #expect(try service.logged() == before)
      #expect(service.queue.sync { service.entries["m1"]!.session.waits ?? [] }.isEmpty)
    }
  }

  // MARK: cli

  /// The request's own fields can't set the subprocess's environment.
  @Test(.timeLimit(.minutes(1)))
  func aCliRequestWithAKeyOutsideItsFieldsFailsAndChangesNothing() throws {
    try withSessions(sbPath: builtSb) { service in
      let before = try service.scopeState()

      let answer = service.handle(
        Request(op: "cli", args: ["argv": ["ls", "--json"], "cwd": "/srv/repo", "env": ["SB_HOME": "/"]]),
        origin: .remote("mini"))

      #expect(!answer.ok)
      #expect(try service.scopeState() == before)
    }
  }
}

/// mini's `repos` name `Secret/Listed`. A PR in `secret/vault`, which they don't name, was read with this Mac's
/// GitHub login, so no copy of it may reach mini.
private let listedHosts: [String: JSON] = [
  "mini": ["kind": "ssh", "destination": .string(LinkBench.destination), "repos": ["Secret/Listed": "~/listed"]],
  "other": ["kind": "ssh", "destination": "haacked@other.local"],
]

/// The text that only the unlisted PR carries.
private let unlistedMarks = ["secret/vault", "Vault sentinel title", "#4242", "pull/4242"]

private func pullRequest(listed: Bool) throws -> JSON {
  let (repo, number, title) =
    listed ? ("secret/listed", 77, "Listed title") : ("secret/vault", 4242, "Vault sentinel title")
  return try JSON(
    encoding: PullRequest(
      id: "PR_\(number)", number: number, url: "https://github.com/\(repo)/pull/\(number)", repo: repo, title: title,
      reviewDecision: .approved, checks: "pass"))
}

extension Service {
  /// Records a `pr` event for the session, as the poller does. It sets the session's PR and logs the event.
  fileprivate func givePR(_ id: String, listed: Bool) throws {
    let pr = try pullRequest(listed: listed)
    queue.sync {
      entries[id]?.facts.prompts = 1
      _ = record(id, "pr", ["pr": pr, "comments": []])
    }
  }
}

private func text(_ answer: Response) -> String {
  (answer.result?.text ?? "") + (answer.error ?? "")
}

/// Every answer that mini gets leaves out what this Mac's GitHub login read for a session whose repo mini's
/// `repos` don't name. sbd still polls that PR and shows it on this Mac.
@Suite struct HostGitHubScopeTests {
  // MARK: Summaries

  @Test(.timeLimit(.minutes(1)), arguments: ownRequests)
  func noAnswerToTheHostCarriesAnUnlistedPR(op: String, args: [String: JSON]) throws {
    try withSessions(hosts: listedHosts) { service in
      try service.givePR("m1", listed: false)

      let answer = service.handle(Request(op: op, args: .object(args)), origin: .remote("mini"))

      for mark in unlistedMarks { #expect(!text(answer).contains(mark), "\(op) answered \(mark)") }
    }
  }

  @Test(.timeLimit(.minutes(3)), arguments: ownHostRequests)
  func noAnswerThatWaitsForTheHostCarriesAnUnlistedPR(op: String, args: [String: JSON]) throws {
    try withReadySessions { service, _, _ in
      try service.givePR("m1", listed: false)

      let answer = service.handle(Request(op: op, args: .object(args)), origin: .remote("mini"))

      for mark in unlistedMarks { #expect(!text(answer).contains(mark), "\(op) answered \(mark)") }
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func lsOnTheHostLeavesOutAnUnlistedPRAndKeepsAListedOne() throws {
    try withSessions(hosts: listedHosts) { service in
      service.queue.sync { service.entries["m2"] = Service.Entry(session: session("m2", host: "mini")) }
      try service.givePR("m1", listed: false)
      try service.givePR("m2", listed: true)

      let answer = service.handle(Request(op: "ls"), origin: .remote("mini"))

      let rows = answer.result?.array ?? []
      #expect(rows.first { $0["id"] == "m1" }?["pr"] == nil)
      #expect(rows.first { $0["id"] == "m2" }?["pr"]?["title"] == "Listed title")
      for mark in unlistedMarks { #expect(!text(answer).contains(mark), "ls answered \(mark)") }
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func thisMacStillSeesTheUnlistedPR() throws {
    try withSessions(hosts: listedHosts) { service in
      try service.givePR("m1", listed: false)

      let get = service.handle(Request(op: "get", args: ["session": "m1"]))
      let ls = service.handle(Request(op: "ls"))

      #expect(get.result?["pr"]?["title"] == "Vault sentinel title")
      #expect(ls.result?.array?.first { $0["id"] == "m1" }?["pr"]?["repo"] == "secret/vault")
    }
  }

  // MARK: Events

  @Test(.timeLimit(.minutes(1)))
  func eventsToTheHostLoseTheDataOfAnUnlistedPRAndKeepAListedOne() throws {
    try withSessions(hosts: listedHosts) { service in
      try service.givePR("m1", listed: false)
      let unlisted = service.handle(Request(op: "events", args: ["session": "m1"]), origin: .remote("mini"))
      try service.givePR("m1", listed: true)
      let listed = service.handle(Request(op: "events", args: ["session": "m1"]), origin: .remote("mini"))

      let first = unlisted.result?.array?.first { $0["kind"] == "pr" }
      #expect(first?["data"] == .object([:]))
      for mark in unlistedMarks { #expect(!text(unlisted).contains(mark), "events answered \(mark)") }
      let shown = listed.result?.array?.filter { $0["kind"] == "pr" }.map { $0["data"]?["pr"]?["title"] }
      #expect(shown == [nil, "Listed title"])
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func aGitHubWaitsOutcomeLeavesTheHostsEventsUnlessTheRepoIsListed() throws {
    try withSessions(hosts: listedHosts) { service in
      try service.givePR("m1", listed: false)
      func resolved(_ kind: Wait.Kind, _ outcome: String) throws {
        let wait = try JSON(encoding: Wait(id: "w-\(kind.rawValue)", kind: kind, by: .you, created: 1, then: .notify))
        service.queue.sync { _ = service.record("m1", "wait-resolved", ["wait": wait, "outcome": .string(outcome)]) }
      }
      try resolved(.ci, "Vault sentinel title checks passed")
      try resolved(.date, "the date came")

      let answer = service.handle(Request(op: "events", args: ["session": "m1"]), origin: .remote("mini"))
      let get = service.handle(Request(op: "get", args: ["session": "m1"]), origin: .remote("mini"))

      let resolutions = (answer.result?.array ?? []).filter { $0["kind"] == "wait-resolved" }
      #expect(resolutions.map { $0["data"]?["wait"]?["id"] } == ["w-ci", "w-date"])
      #expect(resolutions.map { $0["data"]?["outcome"] } == [nil, "the date came"])
      for mark in unlistedMarks {
        #expect(!text(answer).contains(mark), "events answered \(mark)")
        #expect(!text(get).contains(mark), "get answered \(mark)")
      }
    }
  }

  // MARK: Waits

  @Test(.timeLimit(.minutes(1)), arguments: ["ci", "review", "approval", "merge", "queue"])
  func aGitHubWaitFromTheHostOnAnUnlistedRepoIsRefused(kind: String) throws {
    try withSessions(hosts: listedHosts) { service in
      try service.givePR("m1", listed: false)
      let before = try service.scopeState()
      var args: [String: JSON] = ["session": "m1", "kind": .string(kind), "target": "4242"]
      if ["review", "approval"].contains(kind) { args["who"] = "bob" }

      let answer = service.handle(Request(op: "wait", args: .object(args)), origin: .remote("mini"))

      #expect(!answer.ok)
      #expect(answer.error?.contains("repos of mini") == true, "\(answer.error ?? "")")
      #expect(try service.scopeState() == before)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func aGitHubWaitFromTheHostOnASessionWithNoKnownRepoIsRefused() throws {
    try withSessions(hosts: listedHosts) { service in
      let answer = service.handle(
        Request(op: "wait", args: ["session": "m1", "kind": "ci", "target": "12"]), origin: .remote("mini"))

      #expect(!answer.ok)
      #expect(answer.error?.contains("repos of mini") == true, "\(answer.error ?? "")")
    }
  }

  /// Before a PR exists, the poller takes the repo from the branch's tracking remote, which the box chooses.
  @Test(.timeLimit(.minutes(1)))
  func aGitHubWaitFromTheHostWhoseOriginIsListedButThatHasNoPRIsRefused() throws {
    try withSessions(hosts: listedHosts) { service in
      let originCounts = service.queue.sync {
        let session = service.entries["m1"]!.session
        let site = service.site(for: session)
        let checkout = service.checkout(session) ?? session.cwd
        if session.repo == nil { service.checkouts[SitePath(session.cwd, at: site)] = (checkout, nowMs()) }
        service.repositories[SitePath(checkout, at: site)] = ("Secret/Listed", nowMs())
        return service.showsGitHub("m1", to: .remote("mini"))
      }
      #expect(originCounts, "the origin remote should name the listed repo")
      let before = try service.scopeState()

      let answer = service.handle(
        Request(op: "wait", args: ["session": "m1", "kind": "ci", "target": "12"]), origin: .remote("mini"))

      #expect(!answer.ok)
      #expect(answer.error?.contains("PR open") == true, "\(answer.error ?? "")")
      #expect(try service.scopeState() == before)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func aGitHubWaitFromTheHostOnAListedRepoIsSet() throws {
    try withSessions(hosts: listedHosts) { service in
      try service.givePR("m1", listed: true)

      let answer = service.handle(
        Request(op: "wait", args: ["session": "m1", "kind": "ci", "target": "77"]), origin: .remote("mini"))

      #expect(answer.ok, "\(answer.error ?? "")")
      #expect(service.queue.sync { service.entries["m1"]?.session.waits?.map(\.kind) } == [.ci])
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func aGitHubWaitFromThisMacOnAnUnlistedRepoIsSet() throws {
    try withSessions(hosts: listedHosts) { service in
      try service.givePR("m1", listed: false)

      let answer = service.handle(Request(op: "wait", args: ["session": "m1", "kind": "ci", "target": "4242"]))

      #expect(answer.ok, "\(answer.error ?? "")")
    }
  }

  // MARK: Notices to a parent on the host

  /// mini's `m1` started `m2`, whose PR is in an unlisted repo, and `m3`, whose PR is in a listed one.
  @Test(.timeLimit(.minutes(1)))
  func aParentOnTheHostHearsOnlyOfItsChildrensListedPRs() throws {
    try withSessions(hosts: listedHosts) { service in
      service.queue.sync {
        for id in ["m2", "m3"] {
          var child = session(id, host: "mini")
          child.parent = "m1"
          service.entries[id] = Service.Entry(session: child)
        }
      }
      try service.givePR("m2", listed: false)
      try service.givePR("m3", listed: true)

      let unsent = service.queue.sync { () -> [String] in
        service.notifyParents(now: nowMs())
        return service.parentNotices.unsent["m1"] ?? []
      }
      let sent = try service.logged().filter { $0.session == "m1" && $0.kind == "sent" }.compactMap {
        $0.data["text"]?.string
      }
      let heard = (sent + unsent).joined(separator: "\n")

      #expect(heard.contains("m3 (m3) opened PR #77"), "\(heard)")
      for mark in unlistedMarks { #expect(!heard.contains(mark), "\(heard)") }
    }
  }

  // MARK: Messages to the host's session

  @Test(.timeLimit(.minutes(1)))
  func aDependencyMessageReachesTheHostsSessionOnlyForAListedRepo() throws {
    try withSessions(hosts: listedHosts) { service in
      service.queue.sync { service.entries["m2"] = Service.Entry(session: session("m2", host: "mini")) }
      try service.givePR("m1", listed: false)
      try service.givePR("m2", listed: true)
      let args: (String) -> JSON = {
        ["session": .string($0), "message": "secret/vault#4242 merged", "dependencies": []]
      }

      let unlisted = try service.queue.sync { try service.dependencyResolved(args("m1")) }
      let listed = Result { try service.queue.sync { try service.dependencyResolved(args("m2")) } }

      #expect(unlisted["id"] == "m1")
      let sent = try service.logged().filter { $0.kind == "sent" }.map(\.session)
      #expect(!sent.contains("m1"))
      // A send to mini's session with no link either records the message or fails trying.
      if case .success = listed { #expect(sent.contains("m2")) }
    }
  }
}

/// A `cli` request from mini that runs the built `sb` with the argv.
private func cliRequest(_ argv: [String], session: String? = "m1") -> Request {
  var args: [String: JSON] = ["argv": .array(argv.map(JSON.string)), "cwd": "/srv/repo"]
  if let session { args["session"] = .string(session) }
  return Request(op: "cli", args: .object(args))
}

/// The exit status and the two streams of a `cli` answer.
private func cliOutput(_ answer: Response) throws -> (status: Int?, stdout: Data, stderr: Data) {
  try #require(answer.ok, "the cli request failed: \(answer.error ?? "")")
  let result = try #require(answer.result)
  let stdout = try #require(Data(base64Encoded: result["stdout"]?.string ?? "-"), "stdout is not base64")
  let stderr = try #require(Data(base64Encoded: result["stderr"]?.string ?? "-"), "stderr is not base64")
  return (result["status"]?.int, stdout, stderr)
}

/// The `cli` request through the real `sb` under the real profile. The subprocess's requests come back on mini's
/// socket, which the test's listener serves.
@Suite struct HostScopeCLITests {
  /// `l1` is the local session's id and also `m1`'s name, and `local` is the local session's name.
  @Test(
    .timeLimit(.minutes(1)),
    arguments: [
      (["send", "l1", "hi"], "send", ["session": "l1", "text": "hi"]),
      (["send", "local", "hi"], "send", ["session": "local", "text": "hi"]),
      (["get", "l1", "--json"], "get", ["session": "l1"]),
      (["get", "o1", "--json"], "get", ["session": "o1"]),
    ] as [([String], String, [String: JSON])])
  func aCliRequestGetsTheRefusalOfTheSameRawRequestAndChangesNothing(
    argv: [String], op: String, args: [String: JSON]
  ) throws {
    try withSessions(sbPath: builtSb) { service in
      try HostServer.listen(service: service, host: "mini").run()
      let before = try service.scopeState()

      let raw = service.handle(Request(op: op, args: .object(args)), origin: .remote("mini"))
      let cli = try cliOutput(service.handle(cliRequest(argv), origin: .remote("mini")))
      settle(service)

      let refusal = try #require(raw.error, "the raw request was not refused")
      #expect(refusal.contains("that session is not on mini"), "\(refusal)")
      #expect(cli.status == 1)
      #expect(cli.stdout.isEmpty, "\(String(decoding: cli.stdout, as: UTF8.self))")
      #expect(String(decoding: cli.stderr, as: UTF8.self) == "sb: \(refusal)\n")
      #expect(try service.scopeState() == before)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func getForTheHostsOwnSessionThroughCliPrintsTheAnswerOfTheRawRequest() throws {
    try withSessions(sbPath: builtSb) { service in
      try HostServer.listen(service: service, host: "mini").run()

      let raw = service.handle(Request(op: "get", args: ["session": "m1"]), origin: .remote("mini"))
      let cli = try cliOutput(service.handle(cliRequest(["get", "m1", "--json"]), origin: .remote("mini")))

      let roots = service.benchRoots()
      #expect(cli.status == 0, "\(String(decoding: cli.stderr, as: UTF8.self))")
      let printed = JSON.parse(String(decoding: cli.stdout, as: UTF8.self))
      #expect(comparable(printed, roots) == comparable(raw.result, roots))
    }
  }

  /// Claude on a host mostly runs the commands without `--json`, whose text formats dates and names under the
  /// sandbox.
  @Test(.timeLimit(.minutes(1)), arguments: [["get", "m1"], ["ls"]])
  func aCommandWithoutJSONPrintsTheHostsSessionThroughCli(argv: [String]) throws {
    try withSessions(sbPath: builtSb) { service in
      try HostServer.listen(service: service, host: "mini").run()

      let cli = try cliOutput(service.handle(cliRequest(argv), origin: .remote("mini")))

      let printed = String(decoding: cli.stdout, as: UTF8.self)
      #expect(cli.status == 0, "\(String(decoding: cli.stderr, as: UTF8.self))")
      #expect(printed.contains("m1"), "\(printed)")
      #expect(!printed.contains("o1"), "\(printed)")
    }
  }

  /// A client on mini sends `cli` requests whose answers are far larger than a socket's buffer and never reads
  /// them. Each unread answer keeps its run's slot until its write ends, so a ninth request is refused instead
  /// of piling up another answer. The write gives up after the send timeout, which closes the connection and
  /// frees the slot.
  @Test(.timeLimit(.minutes(1)))
  func cliAnswersThatAClientNeverReadsHoldTheirSlotsUntilTheWriteTimesOut() throws {
    try withSessions(sbPath: builtSb) { service in
      service.hostCLIRunner = HostCLIRunner(program: "/usr/bin/head")
      service.hostSendTimeoutSeconds = 4
      try HostServer.listen(service: service, host: "mini").run()
      let socket = service.home.hostSocket("mini")
      let line = Data(
        (#"{"op":"cli","args":{"argv":["-c","4000000","/dev/zero"],"cwd":"/srv/repo"}}"# + "\n").utf8)
      /// Sends one request and reads its whole answer.
      func ask() throws -> Response {
        let fd = try UnixSocket.connect(path: socket, timeout: 30)
        defer { close(fd) }
        try UnixSocket.write(fd, line)
        var reader = UnixSocket.LineReader(fd: fd)
        let answer = try #require(try reader.next(), "sbd closed the connection")
        return try JSONCoding.decoder.decode(Response.self, from: answer)
      }

      let silent = try (0..<8).map { _ in
        let fd = try UnixSocket.connect(path: socket, timeout: 30)
        try UnixSocket.write(fd, line)
        return fd
      }
      defer { silent.forEach { close($0) } }
      // sbd is still writing an answer that has begun to arrive. Its run holds its slot until the write ends.
      let writing = waitUntil(seconds: 6) {
        var ready = silent.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
        return poll(&ready, nfds_t(ready.count), 0) == silent.count
      }
      try #require(writing, "the eight answers did not all begin")
      let refused = try ask()

      #expect(refused.error == "too many sb commands from mini are running", "\(refused)")
      // A read would let a write go on, so the test reads nothing until every write has had twice its 4 s.
      // The write that stalls first returns its partial count. The next write times out.
      // The reads below then show whether sbd hung up.
      _ = waitUntil(seconds: 12) {
        var ends = silent.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
        _ = poll(&ends, nfds_t(ends.count), 0)
        return ends.allSatisfy { $0.revents & Int16(POLLHUP) != 0 }
      }
      for fd in silent {
        var received = 0
        var buffer = [UInt8](repeating: 0, count: 65_536)
        var n = 0
        repeat {
          n = recv(fd, &buffer, buffer.count, 0)
          received += max(n, 0)
        } while n > 0
        #expect(n == 0, "sbd did not close the connection: \(UnixSocket.errnoText())")
        #expect(received < 4_000_000, "the client got the whole answer of \(received) bytes")
      }
      let freed = try ask()
      #expect(freed.ok, "\(freed.error ?? "")")
    }
  }

  /// The subprocess's own request needs the state queue. A `cli` request that held the queue would keep that
  /// request waiting past the one-second deadline, and the runner would end `sb` with status 1.
  @Test(.timeLimit(.minutes(1)))
  func sbGetThroughCliAnswersWithinAOneSecondDeadlineBecauseCliNeverHoldsTheStateQueue() throws {
    try withSessions(sbPath: builtSb) { service in
      try HostServer.listen(service: service, host: "mini").run()
      service.hostCLIRunner = HostCLIRunner(program: service.sbPath, deadline: 1)

      let cli = try cliOutput(service.handle(cliRequest(["get", "m1", "--json"]), origin: .remote("mini")))

      #expect(cli.status == 0, "\(String(decoding: cli.stderr, as: UTF8.self))")
      #expect(JSON.parse(String(decoding: cli.stdout, as: UTF8.self))?["id"] == "m1")
    }
  }
}

/// The listener of a host's socket on this Mac.
@Suite struct HostScopeListenerTests {
  @Test func aSocketPathOver103BytesIsRefusedWithItsLengthAndTheLimit() throws {
    let long = Home(path: "/tmp/" + String(repeating: "x", count: 79))
    let path = long.hostSocket("mini")
    try #require(path.utf8.count == 104)

    #expect {
      try HostServer.socketPath(for: "mini", in: long)
    } throws: { error in
      let text = "\(error)"
      return text.contains(path) && text.contains("104 bytes") && text.contains("at most 103")
    }
  }

  @Test func aSocketPathOf103BytesIsTaken() throws {
    let home = Home(path: "/tmp/" + String(repeating: "x", count: 78))

    let path = try HostServer.socketPath(for: "mini", in: home)

    #expect(path.utf8.count == 103)
    #expect(path == "\(home.path)/hosts/mini/sbd.sock")
  }

  @Test(.timeLimit(.minutes(1)))
  func theListenerMakesTheHostsFolderForThisUserOnly() throws {
    try withHostService { service, home in
      try FileManager.default.createDirectory(
        atPath: "\(home.path)/hosts/mini", withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])

      _ = try HostServer.listen(service: service, host: "mini")

      for folder in [home.hostsFolder, "\(home.hostsFolder)/mini"] {
        let mode = try #require(
          try FileManager.default.attributesOfItem(atPath: folder)[.posixPermissions] as? NSNumber)
        #expect(mode.intValue == 0o700, "\(folder)")
      }
      var info = stat()
      #expect(lstat(home.hostSocket("mini"), &info) == 0 && info.st_mode & S_IFMT == S_IFSOCK)
    }
  }

  /// A link in place of the folder would put the socket where another user may reach it.
  @Test(.timeLimit(.minutes(1)), arguments: ["hosts", "hosts/mini"])
  func theListenerRefusesALinkInPlaceOfItsFolder(linked: String) throws {
    try withHostService { service, home in
      let elsewhere = "\(home.path)/elsewhere"
      try FileManager.default.createDirectory(atPath: elsewhere, withIntermediateDirectories: true)
      if linked == "hosts/mini" {
        try FileManager.default.createDirectory(atPath: home.hostsFolder, withIntermediateDirectories: true)
      }
      try FileManager.default.createSymbolicLink(atPath: "\(home.path)/\(linked)", withDestinationPath: elsewhere)

      #expect(throws: (any Error).self) { try HostServer.listen(service: service, host: "mini") }

      #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere).isEmpty)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func aHostWhoseSocketCantListenFailsItsSetupWithTheReason() throws {
    try withHostService { service, home in
      try "not a folder".write(toFile: home.hostsFolder, atomically: true, encoding: .utf8)

      HostServer.start(service: service)

      let problem = try #require(service.remoteSites["mini"]?.listenerProblem)
      #expect(problem.contains(home.hostsFolder))
    }
  }
}
