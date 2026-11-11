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

/// A service that holds a local session `l1`, mini's `m1`, and other's `o1`.
private func withSessions(_ body: (Service) throws -> Void) throws {
  try withHostService(hosts: twoHosts) { service, _ in
    service.queue.sync {
      service.entries["l1"] = Service.Entry(session: session("l1", host: nil, name: "local"))
      service.entries["m1"] = Service.Entry(session: session("m1", host: "mini", name: "l1"))
      service.entries["o1"] = Service.Entry(session: session("o1", host: "other", name: "m1"))
    }
    try body(service)
  }
}

extension Service {
  /// Every event in the log.
  fileprivate func logged() throws -> [Event] { try queue.sync { try store.events() } }
}

/// Waits out the order window, so an event that sbd took is in the log.
private func settle() { Thread.sleep(forTimeInterval: Double(HostEventOrder.windowMs) / 1000 + 0.3) }

/// The scope of a request whose origin is a host: it changes nothing unless it is a hook for a session that sbd
/// holds on that host. The origin is the socket's, and nothing in the request can change it.
@Suite struct HostScopeRequestTests {
  @Test(.timeLimit(.minutes(1)))
  func aHookForTheHostsOwnSessionIsRecordedOnce() throws {
    try withSessions { service in
      let id = eventId()

      let first = service.handle(hook(session: "m1", payload("own"), id: id), origin: .remote("mini"))
      let second = service.handle(hook(session: "m1", payload("changed"), id: id), origin: .remote("mini"))
      settle()
      let third = service.handle(hook(session: "m1", payload("again"), id: id), origin: .remote("mini"))
      settle()

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
      settle()

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
      settle()

      #expect(!onOther.ok && !onMini.ok)
      let recorded = try service.logged()
      #expect(recorded.isEmpty)
    }
  }

  @Test(
    .timeLimit(.minutes(1)),
    arguments: [
      "send", "new", "rm", "rm-done", "cleanup", "stop", "resume", "open", "done", "answer", "rename", "note", "wait",
      "ls", "get", "events", "screen", "terminals", "shell", "ping", "clock", "hosts", "host-connect",
      "host-disconnect", "live", "accounts", "account-use", "account-move", "group-account", "usage", "mcp", "poll",
      "import", "importable", "triage", "manager", "chat", "spawn", "followup-add", "plan-ls", "docket-start", "Hook",
      "hook ", " hook", "hooks", "", "HOOK", "hook\0", "no-such-op",
    ])
  func everyOpOtherThanHookIsRefusedForAHostAndChangesNothing(op: String) throws {
    try withSessions { service in
      let args: JSON = [
        "session": "m1", "text": "pwned", "name": "pwned", "path": "/tmp", "host": "mini", "advance": 3_600_000,
        "set": 1, "payload": payload("op"), "id": .string(eventId()), "images": ["a.png"], "account": "x",
        "behavior": "allow",
      ]
      let clock = nowMs()

      let answer = service.handle(Request(op: op, args: args), origin: .remote("mini"))
      settle()

      #expect(!answer.ok)
      #expect(answer.error?.contains("can only be a hook") == true, "\(answer.error ?? "")")
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
      settle()

      #expect(!answer.ok)
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
      settle()

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
      settle()

      let answer = service.handle(hook(session: "o1", payload("second"), id: id), origin: .remote("other"))
      settle()

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
    try withSessions { service in
      let answer = service.handle(hook(session: "m1", payload("gone")), origin: .remote("mini"))
      service.queue.sync { service.entries["m1"] = nil }
      settle()

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
      settle()

      let recorded = try service.logged().filter { $0.kind == "Notification" }
      #expect(recorded.count == 2)
      for event in recorded {
        #expect(event.t >= before.t)
        #expect(event.t <= nowMs())
      }
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
