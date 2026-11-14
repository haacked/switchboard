import Foundation
import SwitchboardCore
import Testing

private let otherDestination = "haacked@other.local"

/// What a request on a host's socket may do. A request that arrives on host `h`'s socket reads and acts only on
/// sessions whose `host` is `h`: a `hook` names one of them, and every other op is one of the scope table's ops with
/// only the keys of its row. Each test sends raw lines to mini's socket, as any program on mini can, and compares
/// the whole event log before and after.
///
/// The ssh stub gives every host the same box, so `mini` and `other` share one `~/.sb` there. The host that set up
/// last owns the box's end of the forward. These tests send to the sockets on this Mac, which stay apart.
@Suite(.blocking(timeLimit: .seconds(240))) struct HostScopeTests {
  private struct Bench {
    var sbd: Instance
    var local: SessionSummary
    var mini: (id: String, claudeSessionId: String, cwd: String, pid: Int)
    var other: (id: String, claudeSessionId: String, cwd: String, pid: Int)
    /// The log once every claude had started and gone quiet.
    var before: [Event]
  }

  /// A local session, a session on mini, and a session on other, each with an idle claude.
  private func bench() throws -> Bench {
    let sbd = try Instance.remote(
      hosts: ["other": Instance.remoteHost(otherDestination)], config: Instance.shortHostWait)
    let local = try sbd.new(name: "local-probe")
    try sbd.waitFor(local.id, "the local SessionStart") { $0.live }
    let mini = try sbd.startOnHost("sb-box-repo", host: "mini")
    let other = try sbd.startOnHost("other-repo", host: "other")
    return Bench(sbd: sbd, local: try sbd.get(local.id), mini: mini, other: other, before: try sbd.settledEvents())
  }

  private func refused(_ answer: JSON?) -> Bool { answer?["ok"] == false }

  /// One way a hook on mini's socket can name a session. `names` marks a session that sbd holds on another site,
  /// which the refusal names.
  private struct Shape {
    var label: String
    var session: JSON?
    var kind: String
    var extra: [String: JSON]
    var names: Bool

    init(
      _ label: String, _ session: JSON?, kind: String = "Notification", extra: [String: JSON] = [:], names: Bool = false
    ) {
      self.label = label
      self.session = session
      self.kind = kind
      self.extra = extra
      self.names = names
    }
  }

  /// The event log differs from `before` by these events.
  private func added(_ b: Bench) throws -> [String] {
    let known = Set(b.before.map(\.id))
    return try b.sbd.settledEvents().filter { !known.contains($0.id) }.map {
      "\($0.session) \($0.kind) \($0.data.text)"
    }
  }

  /// A hook for mini's own session on mini's socket is recorded, which shows that the socket takes hooks at all.
  private func expectMiniTakesItsOwnHook(_ b: Bench, _ when: String) throws {
    let marker = "own-\(UUID().uuidString)"

    let answer = try b.sbd.sendProbe(marker, session: b.mini.id)

    #expect(answer?["ok"] == true, "\(when): \(answer?.text ?? "no answer")")
    try b.sbd.waitFor("the hook of mini's own session \(when)") { try b.sbd.probes(marker).count == 1 }
    #expect(try b.sbd.probes(marker).first?.session == b.mini.id)
  }

  // MARK: The sockets

  @Test func everyHostWithALinkHasASocketInAFolderForTheUserOnlyBeforeAnySessionNeedsIt() throws {
    let sbd = try Instance.remote(hosts: [
      "other": Instance.remoteHost(otherDestination), "typo": ["kind": "hogli"],
      "boxes": ["kind": "hogli", "layout": "perSession"],
    ])

    for host in ["mini", "other"] {
      var info = stat()
      try #require(lstat(sbd.hostSocket(host), &info) == 0, "no socket for \(host)")
      #expect(info.st_mode & S_IFMT == S_IFSOCK)
      let folder = (sbd.hostSocket(host) as NSString).deletingLastPathComponent
      let mode = try #require(try FileManager.default.attributesOfItem(atPath: folder)[.posixPermissions] as? NSNumber)
      #expect(mode.intValue == 0o700, "\(folder) has mode \(String(mode.intValue, radix: 8))")
    }
    for host in ["typo", "boxes", "nope"] {
      #expect(!FileManager.default.fileExists(atPath: sbd.hostSocket(host)), "\(host) has no link and has a socket")
    }
    #expect(sbd.sshStubLog.isEmpty, "sbd connected a host that no session needs")
  }

  // MARK: Hooks

  @Test func aHookOnAHostsSocketForASessionOfThatHostIsRecorded() throws {
    let b = try bench()

    try expectMiniTakesItsOwnHook(b, "on mini's socket")

    let marker = "other-own-\(UUID().uuidString)"
    let answer = try b.sbd.sendProbe(marker, session: b.other.id, host: "other")
    #expect(answer?["ok"] == true, "\(answer?.text ?? "no answer")")
    try b.sbd.waitFor("the hook of other's own session") { try b.sbd.probes(marker).count == 1 }
  }

  /// Every way a hook on mini's socket can name a session that is not mini's.
  @Test func aHookOnAHostsSocketForAnySessionThatIsNotTheHostsFailsAndRecordsNothing() throws {
    let b = try bench()
    let sbd = b.sbd
    let localName = b.local.name
    let otherName = try sbd.get(b.other.id).name
    var shapes: [Shape] = []
    for kind in ["Notification", "SessionStart", "Stop", "PermissionRequest", "PreToolUse"] {
      shapes.append(Shape("a local session, \(kind)", .string(b.local.id), kind: kind, names: true))
      shapes.append(Shape("a session of other, \(kind)", .string(b.other.id), kind: kind, names: true))
      shapes.append(Shape("an unknown session, \(kind)", .string("no-such-session"), kind: kind))
      shapes.append(Shape("no session, \(kind)", nil, kind: kind))
    }
    shapes.append(Shape("a local session by its name", .string(localName)))
    shapes.append(Shape("a session of other by its name", .string(otherName)))
    shapes.append(Shape("a local session by a prefix of its id", .string(String(b.local.id.prefix(3)))))
    shapes.append(Shape("a session of other by a prefix of its id", .string(String(b.other.id.prefix(3)))))
    shapes.append(Shape("mini's session with a space after its id", .string(b.mini.id + " ")))
    shapes.append(Shape("another spelling of mini's id", .string(b.mini.id.uppercased() + "X")))
    shapes.append(Shape("an empty session", .string("")))
    shapes.append(Shape("a null session", JSON.null))
    shapes.append(Shape("a number for the session", .number(7)))
    shapes.append(Shape("a list that holds mini's session", .array([.string(b.mini.id)])))
    shapes.append(Shape("a local session that claims mini", .string(b.local.id), extra: ["host": "mini"], names: true))
    shapes.append(
      Shape("a local session that claims this Mac", .string(b.local.id), extra: ["origin": "mac"], names: true))
    shapes.append(
      Shape(
        "a session of other that claims mini", .string(b.other.id), extra: ["host": "mini", "origin": "mini"],
        names: true))
    var markers: [(label: String, marker: String)] = []

    for shape in shapes {
      let marker = "scope-\(UUID().uuidString)"
      markers.append((shape.label, marker))
      // A SessionStart that sbd took would also move the session to this conversation.
      let payload = Instance.probePayload(marker, kind: shape.kind, claudeSessionId: "hijacked-\(marker)")
      let line = Instance.hookLine(
        session: shape.session, payload: payload, id: Instance.eventId(ns: Instance.clockNs()), extra: shape.extra)

      // sbd holds a PermissionRequest that it took, so a hook that it took gives no answer in time.
      let answer = try? sbd.sendLine(line, to: sbd.hostSocket("mini"))

      #expect(refused(answer), "\(shape.label): \(answer?.text ?? "no answer")")
      if shape.names {
        #expect(
          answer?["error"]?.string?.contains("that session is not on mini") == true,
          "\(shape.label): \(answer?.text ?? "no answer")")
      }
    }

    let new = try added(b)
    #expect(new.isEmpty, "the refused hooks added \(new.count) events, first: \(new.prefix(3))")
    for (label, marker) in markers {
      #expect(try sbd.probes(marker).isEmpty, "sbd recorded the hook of \(label)")
    }
    #expect(try sbd.cards().isEmpty)
    #expect(try sbd.get(b.local.id).claudeSessionId == b.local.claudeSessionId)
    #expect(try sbd.get(b.other.id).claudeSessionId == b.other.claudeSessionId)
    #expect(try sbd.get(b.mini.id).claudeSessionId == b.mini.claudeSessionId)
    try expectMiniTakesItsOwnHook(b, "after the refused hooks")
  }

  @Test func aHookForAMiniSessionOnAnotherHostsSocketFailsAndRecordsNothing() throws {
    let b = try bench()
    let marker = "wrong-socket-\(UUID().uuidString)"

    let answer = try b.sbd.sendProbe(marker, session: b.mini.id, host: "other")

    #expect(refused(answer), "\(answer?.text ?? "no answer")")
    #expect(answer?["error"]?.string?.contains("that session is not on other") == true, "\(answer?.text ?? "")")
    #expect(try added(b).isEmpty)
    #expect(try b.sbd.probes(marker).isEmpty)
  }

  /// The same hook that mini's socket refuses is a hook that sbd's own socket takes, so the refusal comes from the
  /// socket it arrived on and not from the payload.
  @Test func theHookThatAHostsSocketRefusesIsOneThatSbdsOwnSocketTakes() throws {
    let b = try bench()
    let marker = "same-hook-\(UUID().uuidString)"
    let line = Instance.hookLine(
      session: .string(b.local.id), payload: Instance.probePayload(marker, claudeSessionId: b.local.claudeSessionId),
      id: nil)

    let onHost = try b.sbd.sendLine(line, to: b.sbd.hostSocket("mini"))
    let afterHost = try b.sbd.probes(marker).count
    let onMac = try b.sbd.sendLine(line, to: b.sbd.home.socket)

    #expect(refused(onHost), "\(onHost?.text ?? "no answer")")
    #expect(afterHost == 0)
    #expect(onMac?["ok"] == true, "\(onMac?.text ?? "no answer")")
    #expect(try b.sbd.probes(marker).map(\.session) == [b.local.id])
  }

  // MARK: Kinds that only sbd records

  /// The kinds that sbd records itself, which a hook from a host must never be recorded as.
  private static let kindsOfSbd = [
    "send_pending", "send_decided", "sent", "delivered", "delivery_unknown", "answered", "card_closed", "dialog_closed",
    "stopped", "exited", "running", "idle", "job", "pr", "branch", "worktree", "cleanup", "triage", "merge", "docket",
    "dependencies", "created", "imported", "started", "resumed", "followup", "followup-started", "wait", "wait-cleared",
    "note", "done", "undone", "ack", "account-moved", "digest", "link_down", "link_up", "reconciled", "unknown",
  ]

  /// A payload for mini's own session whose `hook_event_name` is `kind`, or is left out when `kind` is nil. It
  /// holds the fields of a group message, so sbd would open a `send` card to the local session if it took the kind
  /// as its own.
  private func forged(_ b: Bench, _ kind: JSON?, _ marker: String) -> JSON {
    var payload: [String: JSON] = [
      "session_id": .string("hijacked-\(marker)"), "probe": .string(marker), "group": "g", "groupName": "harmless",
      "text": .string("FORGED \(marker)"),
      "targets": [["id": .string(b.local.id), "name": .string(b.mini.id)]],
      "expires": .number(Double(Instance.clockNs() / 1_000_000 + 3_600_000)), "count": 3, "behavior": "allow",
      "card": 1, "pr": ["number": 7, "url": "https://example.com/7", "state": "MERGED"], "gone": true,
    ]
    if let kind { payload["hook_event_name"] = kind }
    return .object(payload)
  }

  /// Every way a hook for mini's own session can name a kind that no claude hook produces.
  @Test func aHookWhoseKindIsNotAClaudeHookFailsAndRecordsNothing() throws {
    let b = try bench()
    let sbd = b.sbd
    var kinds: [(label: String, kind: JSON?)] = Self.kindsOfSbd.map { ($0, .string($0)) }
    kinds += [
      ("no kind", nil), ("a null kind", JSON.null), ("a number", 7), ("true", true), ("an empty kind", ""),
      ("a list that holds a hook", ["Stop"]), ("an object", ["name": "Stop"]),
      ("a hook in small letters", "stop"), ("a hook in capitals", "STOP"), ("a hook with a space after", "Stop "),
      ("a hook with a space before", " SessionEnd"), ("a hook with a newline", "Stop\n"),
      ("a hook with a NUL", "Stop\0"), ("two hooks", "Stop,SessionEnd"),
      ("a hook that claude has and sbd does not", "PreCompact"),
    ]
    var markers: [(label: String, marker: String)] = []

    for (label, kind) in kinds {
      let marker = "kind-\(UUID().uuidString)"
      markers.append((label, marker))
      let line = Instance.hookLine(
        session: .string(b.mini.id), payload: forged(b, kind, marker), id: Instance.eventId(ns: Instance.clockNs()))

      let answer = try? sbd.sendLine(line, to: sbd.hostSocket("mini"))

      #expect(refused(answer), "\(label): \(answer?.text ?? "no answer")")
    }

    let new = try added(b)
    #expect(new.isEmpty, "the refused kinds added \(new.count) events, first: \(new.prefix(3))")
    for (label, marker) in markers {
      #expect(try sbd.probes(marker).isEmpty, "sbd recorded the hook of \(label)")
    }
    #expect(try sbd.cards().isEmpty)
    let mini = try sbd.get(b.mini.id)
    #expect(mini.live && mini.claudePid == b.mini.pid)
    #expect(mini.claudeSessionId == b.mini.claudeSessionId)
    #expect(sbd.runs(b.mini.pid))
    try expectMiniTakesItsOwnHook(b, "after the refused kinds")
  }

  /// A `send_pending` event is how sbd records a group message that waits for the user. A host that could record
  /// one on its own session would get a card whose approval pastes the host's text into a local session.
  @Test func aHostCantOpenASendCardThatPastesIntoALocalSession() throws {
    let b = try bench()
    let sbd = b.sbd
    let marker = "FORGED-TEXT-FROM-HOST-\(UUID().uuidString)"
    let payload: JSON = [
      "hook_event_name": "send_pending", "group": "g", "groupName": "harmless", "text": .string(marker),
      "targets": [["id": .string(b.local.id), "name": .string(b.mini.id)]],
      "expires": .number(Double(try sbd.now() + 3_600_000)),
    ]

    let answer = try sbd.sendLine(
      Instance.hookLine(session: .string(b.mini.id), payload: payload, id: Instance.eventId(ns: Instance.clockNs())),
      to: sbd.hostSocket("mini"))

    #expect(refused(answer), "\(answer?.text ?? "no answer")")
    #expect(try added(b).isEmpty)
    #expect(try sbd.cards().isEmpty)
    #expect(try sbd.get(b.mini.id).cards.isEmpty)
    #expect(throws: TestError.self) { try sbd.sb("allow", "--json", b.mini.id) }
    #expect(throws: TestError.self) { try sbd.sb("allow", "--json", b.local.id) }
    #expect(try added(b).isEmpty)
    #expect(!sbd.stubInput().contains { $0.contains(marker) }, "the host's text reached the local pane")
    #expect(!sbd.boxStubInput().contains { $0.contains(marker) }, "the host's text reached a pane on the box")
    #expect(try sbd.events(b.local.id).allSatisfy { !$0.data.text.contains(marker) })
  }

  // MARK: Fields of a claude hook

  /// A SessionStart names the session's conversation, as after `/clear`. A host can name the id of a conversation
  /// on this Mac that Switchboard does not hold. Import still lists that conversation and still imports it.
  @Test func aHostThatNamesAConversationOfThisMacDoesNotTakeItFromImport() throws {
    let sbd = try Instance.remote()
    let account = "\(sbd.home.path)/A"
    try FileManager.default.createDirectory(atPath: account, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: "\(account)/.claude.json", contents: Data("{}".utf8))
    try sbd.restart(setting: "claudeConfigDirs", to: [.string(account)])
    let mini = try sbd.startOnHost()
    let outside = UUID().uuidString.lowercased()
    try sbd.writeAgents(
      "A",
      [
        [
          "sessionId": .string(outside), "cwd": .string(sbd.work), "kind": "interactive", "name": "outside",
          "startedAt": .number(Double(nowMs())),
        ]
      ])
    try #require(try sbd.client.importable(all: true).sessions.map(\.id) == [outside])

    let answer = try sbd.sendLine(
      Instance.hookLine(
        session: .string(mini.id),
        payload: Instance.probePayload("claim", kind: "SessionStart", claudeSessionId: outside),
        id: Instance.eventId(ns: Instance.clockNs())),
      to: sbd.hostSocket("mini"))
    #expect(answer?["ok"] == true, "\(answer?.text ?? "no answer")")
    try sbd.waitFor(mini.id, "the conversation that mini's hook named") { $0.claudeSessionId == outside }

    #expect(try sbd.client.importable(all: true).sessions.map(\.id) == [outside])
    let result = try sbd.client.importSessions([outside])
    #expect(result.refused.isEmpty, "\(result.refused)")
    let local = try sbd.client.sessions().filter { $0.host == nil }
    #expect(local.map(\.claudeSessionId) == [outside])
  }

  /// A claude hook that also carries the fields of the events that sbd records itself. sbd records it under the
  /// hook's kind on mini's session, and reads none of those fields as its own.
  @Test func aClaudeHookThatCarriesTheFieldsOfSbdsOwnEventsChangesOnlyItsOwnSession() throws {
    let b = try bench()
    let sbd = b.sbd
    let marker = "FIELDS-\(UUID().uuidString)"
    let kinds = SessionFacts.hookKinds.filter { $0 != "PermissionRequest" }

    for kind in kinds {
      var payload = Instance.probePayload(marker, kind: kind, claudeSessionId: b.mini.claudeSessionId).object ?? [:]
      payload.merge([
        "session": .string(b.local.id), "host": JSON.null, "origin": "mac", "kind": "send_pending", "group": "g",
        "groupName": "harmless", "text": .string(marker), "by": "sbd", "delivery": "queued",
        "targets": [["id": .string(b.local.id), "name": .string(b.mini.id)]],
        "expires": .number(Double(try sbd.now() + 3_600_000)), "card": 1, "behavior": "allow", "decision": "sent",
        "count": 3, "gone": true, "pr": ["number": 7, "url": "https://example.com/7", "state": "MERGED"],
        "from": "a", "to": .string(sbd.home.path),
      ]) { $1 }
      let answer = try sbd.sendLine(
        Instance.hookLine(
          session: .string(b.mini.id), payload: .object(payload), id: Instance.eventId(ns: Instance.clockNs())),
        to: sbd.hostSocket("mini"))

      #expect(answer?["ok"] == true, "\(kind): \(answer?.text ?? "no answer")")
    }

    try sbd.waitFor("the hooks") { try sbd.probes(marker).count == kinds.count }
    let known = Set(b.before.map(\.id))
    let new = try sbd.settledEvents().filter { !known.contains($0.id) }
    #expect(new.allSatisfy { $0.session == b.mini.id }, "\(new.filter { $0.session != b.mini.id }.map(\.kind))")
    #expect(Set(try sbd.probes(marker).map(\.kind)) == Set(kinds))
    let own = Set(new.map(\.kind)).subtracting(kinds)
    #expect(own.isSubset(of: ["job", "digest"]), "sbd recorded \(own.sorted()) for the hooks")
    #expect(try sbd.cards().isEmpty)
    #expect(try sbd.get(b.mini.id).pr == nil)
    #expect(try sbd.get(b.local.id).claudeSessionId == b.local.claudeSessionId)
    #expect(try sbd.get(b.other.id).claudeSessionId == b.other.claudeSessionId)
    #expect(!sbd.stubInput().contains { $0.contains(marker) }, "the hook's text reached the local pane")
    #expect(!sbd.boxStubInput().contains { $0.contains(marker) }, "the hook's text reached a pane on the box")
  }

  // MARK: Every other op

  /// The ops that mini's socket refuses, whatever they name.
  private static let refusedOps = [
    "rm", "cleanup", "rm-done", "send-group", "send-pending", "group-ls", "group-add", "group-rm", "group-move",
    "group-note", "group-describe", "group-account", "group-suggest", "manager", "manager-ls", "manager-mcp", "chat",
    "chat-log", "import", "importable", "accounts", "account-use", "account-move", "usage", "mcp", "hosts",
    "host-connect", "host-disconnect", "live", "autocontinue", "snapshots", "poll", "repos", "repo-add", "clock",
    "triage", "choose", "decisions", "decision-answer", "decision-submit", "decision-resend", "decision-discard",
    "plan-attach", "plan-update", "plan-propose", "plan-apply", "plan-artifact-read", "plan-artifact-rewrite",
    "plan-artifact-apply", "plan-artifact-reject", "plan-artifact-report", "plan-followup", "plan-ls", "plan-get",
    "plan-detach", "plan-auto", "plan-proposals", "plan-reject", "followup-add", "followup-ls", "followup-start",
    "followup-rm", "followup-import", "pr-merged", "docket-start", "merge", "review", "ack", "resolved-todos",
    "dependency-resolved", "activity", "activity-report", "activity-clear", "live-next", "draft-post", "draft-check",
    "issues", "issues-refresh", "issues-start", "issues-clone", "issues-source-add", "issues-source-rm",
    "issues-settings", "issues-dismiss",
  ]

  /// The keys that the requests below carry and their ops do not read.
  private static let unreadKeys: Set<String> = ["images", "account", "path", "on", "host"]

  /// Every op that the stage 3 test sent, each in a form that mini's socket refuses: a refused op, a session that
  /// is not mini's, a key that the op does not read, or a host other than mini. The ops that only read, sent for
  /// mini's own session, are taken and change nothing.
  @Test func everyRefusedOpFailsOnAHostsSocketAndChangesNothing() throws {
    let b = try bench()
    let sbd = b.sbd
    let (l, s, o): (JSON, JSON, JSON) = (.string(b.local.id), .string(b.mini.id), .string(b.other.id))
    let marker = "op-\(UUID().uuidString)"
    let text = JSON.string(marker)
    let clock = try sbd.now()
    let scope = "that session is not on mini"
    let elsewhere = "can start sessions only on mini"
    /// `refusal` is a text that the error holds, or nil for a request that mini's socket takes.
    var requests: [(op: String, args: [String: JSON], refusal: String?)] = []
    func add(_ op: String, _ args: [String: JSON] = [:], _ refusal: String? = nil) {
      requests.append((op, args, refusal ?? "\(op) can't run from mini"))
    }
    func taken(_ op: String, _ args: [String: JSON] = [:]) { requests.append((op, args, nil)) }
    add("send", ["session": l, "text": text], scope)
    add("send", ["session": o, "text": text], scope)
    add("send", ["session": s, "text": text, "from": l], scope)
    add("send", ["session": s, "text": text, "images": [["name": "a.png", "data": "AA=="]]], "images")
    add("send-group", ["group": "g", "text": text])
    add("new", ["path": .string(sbd.work), "name": text, "host": "local"], elsewhere)
    add("new", ["path": "~/sb-box-repo", "host": "other", "name": text], elsewhere)
    add("new", ["path": "~/sb-box-repo", "name": text, "parent": l], scope)
    add("new", ["path": "~/sb-box-repo", "name": text, "account": "x"], "account")
    add("spawn", ["path": .string(sbd.work), "name": text, "prompt": text], "path")
    add("spawn", ["repository": "o/n", "branch": text, "prompt": text, "host": "local"], elsewhere)
    add("spawn", ["repository": "o/n", "branch": text, "prompt": text, "parent": o], scope)
    add("rm", ["session": s])
    add("rm", ["session": l])
    add("rm-done")
    add("cleanup", ["session": s])
    add("stop", ["session": l], scope)
    add("stop", ["session": o], scope)
    add("resume", ["session": l], scope)
    add("open", ["session": o], scope)
    add("done", ["session": l], scope)
    add("done", ["session": .string(b.local.name)], scope)
    add("ack", ["session": s])
    add("answer", ["session": l, "behavior": "allow"], scope)
    add("rename", ["session": l, "name": text], scope)
    add("rename", ["session": o, "name": text], scope)
    add("note", ["session": l, "text": text], scope)
    add("wait", ["session": s, "on": text], "on")
    add("wait", ["session": s, "kind": "session", "target": l, "state": "idle"], scope)
    add("issue", ["session": l, "issue": "1"], scope)
    taken("ls")
    add("ls", ["host": "other"], "host")
    taken("get", ["session": s])
    add("get", ["session": l], scope)
    add("get", ["session": .string(String(b.local.id.dropLast()))], scope)
    taken("events")
    taken("events", ["session": s])
    add("events", ["sessions": [s, l]], scope)
    taken("screen", ["session": s])
    add("screen", ["session": l], scope)
    add("terminals", ["session": l], scope)
    add("shell", ["session": o, "open": true], scope)
    taken("ping")
    add("clock")
    add("clock", ["advance": 3_600_000])
    add("hosts")
    add("host-connect", ["name": "mini"])
    add("host-disconnect", ["name": "mini"])
    add("host-disconnect", ["name": "other"])
    add("live")
    add("live", ["set": 1])
    add("accounts")
    add("account-use", ["account": text])
    add("account-move", ["account": text])
    add("usage")
    add("mcp")
    add("snapshots")
    add("autocontinue", ["on": true])
    add("poll")
    add("importable")
    add("import", ["refs": [text]])
    add("triage")
    add("summary-set", ["session": l, "card": ["summary": text]], scope)
    add("decisions", ["session": s])
    add("manager")
    add("chat", ["group": text])
    add("merge", ["session": s])
    add("review", ["session": s])
    add("group-ls")
    add("group-add", ["name": text, "sessions": [s]])
    add("plan-ls")
    add("followup-ls")
    add("followup-add", ["text": text])
    add("docket-start")
    add("resolved-todos")
    add("dependency-resolved", ["session": s])
    add("no-such-op")
    let sent = Set(requests.map(\.op))
    for op in Self.refusedOps where !sent.contains(op) { add(op, ["session": s]) }

    for request in requests {
      let answer = try? sbd.sendLine(Instance.requestLine(request.op, request.args), to: sbd.hostSocket("mini"))

      let label = "\(request.op) \(JSON.object(request.args).text): \(answer?.text ?? "no answer")"
      if let refusal = request.refusal {
        let error = answer?["error"]?.string ?? ""
        #expect(refused(answer), "\(label)")
        #expect(error.contains(refusal), "\(label)")
        // A key's name such as `on` is a part of other refusals, so a key refusal must be neither of them.
        if Self.unreadKeys.contains(refusal) {
          #expect(!error.contains("can't run from mini") && !error.contains(scope), "\(label)")
        }
      } else {
        #expect(answer?["ok"] == true, "\(label)")
      }
    }

    let new = try added(b)
    #expect(new.isEmpty, "the requests added \(new.count) events, first: \(new.prefix(3))")
    #expect(try Set(sbd.client.sessions().map(\.id)) == [b.local.id, b.mini.id, b.other.id])
    #expect(try sbd.client.sessions().map(\.name).contains(marker) == false)
    #expect(try sbd.get(b.local.id).claudePid == b.local.claudePid)
    #expect(try sbd.get(b.mini.id).claudePid == b.mini.pid)
    #expect(try sbd.get(b.other.id).claudePid == b.other.pid)
    #expect(sbd.runs(b.mini.pid))
    #expect(try sbd.now() - clock < 600_000, "a clock request on mini's socket moved sbd's clock")
    #expect(try sbd.hosts().first { $0.name == "mini" }?.link == .connected)
    #expect(try sbd.hosts().first { $0.name == "other" }?.link == .connected)
    #expect(!sbd.boxStubInput().contains { $0.contains(marker) }, "a send on mini's socket reached a pane")
    #expect(!sbd.stubInput().contains { $0.contains(marker) }, "a send on mini's socket reached a local pane")
    try expectMiniTakesItsOwnHook(b, "after the refused requests")
  }

  /// A connection that sent a hook that sbd took gets no more rights from it.
  @Test func aConnectionThatSentAGoodHookStillCantSendToALocalSession() throws {
    let b = try bench()
    let (first, second, third) = ("conn-1-\(UUID())", "conn-2-\(UUID())", "conn-3-\(UUID())")
    let lines = [
      Instance.hookLine(
        session: .string(b.mini.id), payload: Instance.probePayload(first), id: Instance.eventId(ns: Instance.clockNs())
      ),
      Instance.requestLine("send", ["session": .string(b.local.id), "text": .string(second)]),
      Instance.hookLine(
        session: .string(b.local.id), payload: Instance.probePayload(third),
        id: Instance.eventId(ns: Instance.clockNs())),
    ]

    let answers = try b.sbd.sendLines(lines.map { Data($0.utf8) }, to: b.sbd.hostSocket("mini"))

    #expect(answers[0]?["ok"] == true, "\(answers[0]?.text ?? "no answer")")
    #expect(refused(answers[1]), "\(answers[1]?.text ?? "no answer")")
    #expect(
      answers[1]?["error"]?.string?.contains("that session is not on mini") == true,
      "\(answers[1]?.text ?? "no answer")")
    #expect(refused(answers[2]), "\(answers[2]?.text ?? "no answer")")
    try b.sbd.waitFor("the good hook") { try b.sbd.probes(first).count == 1 }
    let new = try added(b)
    #expect(new.count == 1, "\(new)")
    #expect(try b.sbd.probes(third).isEmpty)
    #expect(!b.sbd.stubInput().contains { $0.contains(second) }, "the send reached the local pane")
    #expect(!b.sbd.boxStubInput().contains { $0.contains(second) })
  }

  /// A program on mini reaches mini's own session through the box's end of the forward. The bench's box forward
  /// belongs to the host that set up last, so this test runs a sbd with mini alone.
  @Test func aSessionsOwnOpsWorkOnItsHostsSocket() throws {
    let sbd = try Instance.remote(config: Instance.shortHostWait)
    let mini = try sbd.startOnHost()
    let marker = "own-op-\(UUID().uuidString)"
    let session = JSON.string(mini.id)

    let got = try sbd.sendLine(Instance.requestLine("get", ["session": session]), to: sbd.boxSocket)
    let sent = try sbd.sendLine(
      Instance.requestLine("send", ["session": session, "text": .string(marker)]), to: sbd.boxSocket, timeout: 30)
    let waited = try sbd.sendLine(
      Instance.requestLine("wait", ["session": session, "note": .string(marker), "by": "claude"]), to: sbd.boxSocket)

    #expect(got?["ok"] == true, "\(got?.text ?? "no answer")")
    #expect(got?["result"]?["id"] == session)
    #expect(got?["result"]?["host"] == "mini")
    #expect(sent?["ok"] == true, "\(sent?.text ?? "no answer")")
    try sbd.waitFor("the message in mini's pane") { sbd.boxStubInput().contains { $0.contains(marker) } }
    #expect(waited?["ok"] == true, "\(waited?.text ?? "no answer")")
    #expect(try sbd.get(mini.id).waits.contains { $0.note == marker })
    #expect(!sbd.stubInput().contains { $0.contains(marker) }, "the send reached a local pane")
  }

  // MARK: Lines that are not requests

  @Test func aMalformedLineOnAHostsSocketFailsAndRecordsNothing() throws {
    let b = try bench()
    let sbd = b.sbd
    let marker = "malformed-\(UUID().uuidString)"
    let args = JSON.object([
      "session": .string(b.mini.id), "payload": Instance.probePayload(marker),
      "id": .string(Instance.eventId(ns: Instance.clockNs())),
    ]).text
    let lines: [(label: String, line: Data)] = [
      ("text that is not JSON", Data("not json \(marker)".utf8)),
      ("half an object", Data("{\"op\":\"hook\",\"args\":\(args)".utf8)),
      ("a list", Data("[\"hook\",\(args)]".utf8)),
      ("a string", Data("\"hook\"".utf8)),
      ("a number for the op", Data("{\"op\":5,\"args\":\(args)}".utf8)),
      ("no op", Data("{\"args\":\(args)}".utf8)),
      ("an empty op", Data("{\"op\":\"\",\"args\":\(args)}".utf8)),
      ("Hook in capitals", Data("{\"op\":\"Hook\",\"args\":\(args)}".utf8)),
      ("a space before hook", Data("{\"op\":\" hook\",\"args\":\(args)}".utf8)),
      ("a space after hook", Data("{\"op\":\"hook \",\"args\":\(args)}".utf8)),
      ("hook with no args", Data("{\"op\":\"hook\"}".utf8)),
      ("hook with a list for args", Data("{\"op\":\"hook\",\"args\":[\(args)]}".utf8)),
      ("hook with the session id for args", Data("{\"op\":\"hook\",\"args\":\"\(b.mini.id)\"}".utf8)),
      ("NUL bytes", Data([0, 0, 0])),
      ("bytes that are not UTF-8", Data([0xff, 0xfe, 0x7b, 0x7d])),
    ]

    for (label, line) in lines {
      let answer = try? sbd.sendLines([line], to: sbd.hostSocket("mini"))[0]

      #expect(answer?["ok"] != true, "\(label): \(answer?.text ?? "")")
    }

    let new = try added(b)
    #expect(new.isEmpty, "the malformed lines added \(new.count) events, first: \(new.prefix(3))")
    #expect(try sbd.probes(marker).isEmpty)
    try expectMiniTakesItsOwnHook(b, "after the malformed lines")
  }

  /// A hook with no payload has nothing to record, whatever sbd answers.
  @Test func aHookWithNoPayloadRecordsNothing() throws {
    let b = try bench()

    _ = try? b.sbd.sendLine(
      Instance.hookLine(session: .string(b.mini.id), payload: nil, id: Instance.eventId(ns: Instance.clockNs())),
      to: b.sbd.hostSocket("mini"))

    #expect(try added(b).isEmpty)
  }
}
