import Foundation
import Testing

@testable import SwitchboardCore
@testable import SwitchboardService

private let hosts: [String: JSON] = [
  "mini": ["kind": "ssh", "destination": .string(LinkBench.destination)],
  "other": ["kind": "ssh", "destination": "haacked@other.local"],
]

private func session(_ id: String, host: String?, group: String?) -> Session {
  var s = Session(id: id, name: "name-\(id)", cwd: "/srv/repo", claudeSessionId: "u-\(id)", created: 5)
  s.host = host
  s.group = group
  s.started = true
  return s
}

private func group(_ id: String, _ name: String, secret: String) -> SessionGroup {
  SessionGroup(
    id: id, name: name, description: "about \(secret)", notes: [Note(id: "n1", text: secret, by: .you, t: 1)],
    created: 1)
}

/// Each group's note and description hold its secret, so an answer or an error that carries another group's data
/// shows it.
private let groups = [
  group("gflag2", "Flags", secret: "flags-secret"),
  group("gbill3", "Billing", secret: "billing-secret"),
  group("gdocs4", "Docs", secret: "docs-secret"),
  group("gops5x", "Ops", secret: "ops-secret"),
]

/// mini's `m1` is in Flags, which also holds the local `l2`. mini's `m2` is in Billing, so Billing has a session on
/// mini that is not the caller. mini's `m3` is in no group. The local `l1` is in Docs, and other's `o1` is in Ops.
private func withGroups(_ body: (Service) throws -> Void) throws {
  let config: [String: JSON] = ["claude": "/usr/bin/true", "tmux": "/usr/bin/true"]
  try withHostService(hosts: hosts, config: config) { service, _ in
    service.queue.sync {
      for g in groups { service.groups[g.id] = g }
      for s in [
        session("m1", host: "mini", group: "gflag2"), session("l2", host: nil, group: "gflag2"),
        session("m2", host: "mini", group: "gbill3"), session("m3", host: "mini", group: nil),
        session("l1", host: nil, group: "gdocs4"), session("o1", host: "other", group: "gops5x"),
      ] {
        service.entries[s.id] = Service.Entry(session: s)
      }
    }
    try body(service)
  }
}

private func show(_ service: Service, _ args: [String: JSON], from origin: RequestOrigin = .remote("mini"))
  -> Response
{
  service.handle(Request(op: "group-show", args: .object(args)), origin: origin)
}

private func summary(_ response: Response) throws -> GroupSummary {
  try JSONCoding.convert(try #require(response.result), to: GroupSummary.self)
}

/// The secrets of every group but Flags, which is `m1`'s own.
private let otherSecrets = ["billing-secret", "docs-secret", "ops-secret"]

/// `group-show` from a host answers only the group of the calling session, which the request names in `session`.
/// A request that names any other group, that names no session, or whose session is in no group is refused.
@Suite struct GroupShowHostScopeTests {
  // MARK: The caller's own group

  @Test(
    .timeLimit(.minutes(1)),
    arguments: [
      ["session": "m1"], ["session": "m1", "group": "gflag2"], ["session": "m1", "group": "Flags"],
      ["session": "m1", "group": "gfl"], ["session": "name-m1"],
    ] as [[String: JSON]])
  func aHostSessionSeesItsOwnGroup(args: [String: JSON]) throws {
    try withGroups { service in
      let answer = show(service, args)

      #expect(answer.ok, "\(answer.error ?? "")")
      let shown = try summary(answer)
      #expect(shown.id == "gflag2")
      #expect(shown.notes.map(\.text) == ["flags-secret"])
    }
  }

  /// The host's answer for its own group is the one that this Mac gets for the same group.
  @Test(.timeLimit(.minutes(1)))
  func aHostSeesItsOwnGroupAsThisMacDoes() throws {
    try withGroups { service in
      let fromHost = try summary(show(service, ["session": "m1"]))
      let fromMac = try summary(show(service, ["group": "gflag2"], from: .mac))

      #expect(fromHost == fromMac)
    }
  }

  // MARK: Every other group

  /// Billing has mini's `m2`, Docs has only a local session, and Ops has only other's session. Each is named by its
  /// id, by a prefix of its id, and by its name.
  @Test(
    .timeLimit(.minutes(1)),
    arguments: ["gbill3", "gbi", "Billing", "gdocs4", "gdo", "Docs", "gops5x", "gop", "Ops"])
  func aHostSessionCantSeeAnotherGroup(named: String) throws {
    try withGroups { service in
      let answer = show(service, ["session": "m1", "group": .string(named)])

      #expect(!answer.ok, "answered \(answer.result?.text ?? "")")
      let error = answer.error ?? ""
      #expect(!otherSecrets.contains { error.contains($0) }, "\(error)")
    }
  }

  /// Without a session, the host names no caller, so even the group of one of its own sessions is refused.
  @Test(.timeLimit(.minutes(1)), arguments: ["gflag2", "Flags", "gbill3", "Billing", "gdocs4"])
  func aRequestWithoutASessionIsRefused(named: String) throws {
    try withGroups { service in
      let answer = show(service, ["group": .string(named)])

      #expect(!answer.ok, "answered \(answer.result?.text ?? "")")
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func aRequestWithNothingIsRefused() throws {
    try withGroups { service in
      #expect(!show(service, [:]).ok)
    }
  }

  @Test(.timeLimit(.minutes(1)), arguments: [nil, "gflag2", "Flags", "gbill3"] as [String?])
  func aHostSessionInNoGroupSeesNoGroup(named: String?) throws {
    try withGroups { service in
      var args: [String: JSON] = ["session": "m3"]
      if let named { args["group"] = .string(named) }

      let answer = show(service, args)

      #expect(!answer.ok, "answered \(answer.result?.text ?? "")")
    }
  }

  /// A session off mini can't be the caller, even for its own group or for the group of a session on mini.
  @Test(
    .timeLimit(.minutes(1)),
    arguments: [
      ["session": "l1"], ["session": "l2"], ["session": "o1"], ["session": "l2", "group": "gflag2"],
      ["session": "l1", "group": "Docs"], ["session": "o1", "group": "Ops"], ["session": "name-l1"],
      ["session": "nope"], ["session": ""],
    ] as [[String: JSON]])
  func aCallerThatIsNotASessionOfTheHostIsRefused(args: [String: JSON]) throws {
    try withGroups { service in
      let answer = show(service, args)

      #expect(!answer.ok, "answered \(answer.result?.text ?? "")")
      let error = answer.error ?? ""
      #expect(!otherSecrets.contains { error.contains($0) }, "\(error)")
    }
  }

  /// A `group` that is not a string must not reach another group. Whatever sbd does with it, an answer is the
  /// caller's own group.
  @Test(
    .timeLimit(.minutes(1)),
    arguments: [
      JSON.number(7), .bool(true), .null, .array(["gbill3"]), .object(["group": "gbill3"]), .array([]),
    ])
  func aGroupOfTheWrongTypeNeverAnswersAnotherGroup(value: JSON) throws {
    try withGroups { service in
      let answer = show(service, ["session": "m1", "group": value])

      if answer.ok {
        let shown = try summary(answer)
        #expect(shown.id == "gflag2")
      }
      let text = (answer.result?.text ?? "") + (answer.error ?? "")
      #expect(!otherSecrets.contains { text.contains($0) }, "\(text)")
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func aKeyThatGroupShowDoesNotReadIsRefusedFromAHost() throws {
    try withGroups { service in
      let answer = show(service, ["session": "m1", "host": "other"])

      #expect(!answer.ok)
      #expect(answer.error?.contains("host") == true, "\(answer.error ?? "")")
    }
  }

  // MARK: This Mac

  /// The limit is a host's. On this Mac any group can be shown, with or without a session.
  @Test(
    .timeLimit(.minutes(1)),
    arguments: [
      (["group": "Billing"], "gbill3"), (["session": "m1", "group": "Billing"], "gbill3"),
      (["session": "l1"], "gdocs4"),
      (["session": "o1"], "gops5x"),
    ] as [([String: JSON], String)])
  func thisMacSeesAnyGroup(args: [String: JSON], expected: String) throws {
    try withGroups { service in
      let answer = show(service, args, from: .mac)

      #expect(answer.ok, "\(answer.error ?? "")")
      let shown = try summary(answer)
      #expect(shown.id == expected)
    }
  }
}

/// What sbd records when it can't tell who wrote a group's context or which context a session last heard.
@Suite struct GroupContextServiceTests {
  /// sbd can't show that a client whose pid it can't read runs outside every session.
  @Test(.timeLimit(.minutes(1)))
  func aDescriptionFromAClientWithoutAPidIsClaudes() throws {
    try withGroups { service in
      let answer = service.handle(
        Request(op: "group-describe", args: ["group": "gflag2", "text": "From nowhere."]), caller: .client(pid: nil))

      #expect(answer.ok, "\(answer.error ?? "")")
      let after = service.queue.sync { service.groups["gflag2"] }
      #expect(after?.description == "From nowhere.")
      #expect(after?.descriptionBy == .claude)
    }
  }

  /// A session that an older sbd launched has no context on record.
  @Test(.timeLimit(.minutes(1)))
  func aSessionThatNeverHeardAContextHearsTheCurrentOneWithoutANotice() throws {
    try withGroups { service in
      let notice = service.queue.sync { service.groupContextNotice("l2") }

      #expect(notice == nil)
      let heard = service.queue.sync { service.entries["l2"]?.facts.groupContextHeard }
      #expect(heard == GroupContext.fingerprint(groups[0]))
    }
  }
}
