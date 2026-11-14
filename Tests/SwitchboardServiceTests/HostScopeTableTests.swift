import Foundation
import Testing

@testable import SwitchboardCore
@testable import SwitchboardService

/// The scope table of the plan, written out by hand so that a test never loops over `HostScope.rules` itself. A
/// table that lost a row would then give a loop nothing to check.
enum PlannedScope {
  struct Row {
    /// Every key that the op may carry.
    var keys: Set<String>
    /// The keys whose string names one session.
    var refs: [String] = []
    /// The keys whose list names sessions.
    var refLists: [String] = []
    /// `target` names a session when `kind` is `session`.
    var waitTarget = false
  }

  private static let sessionOnly = Row(keys: ["session"], refs: ["session"])
  private static let noteKeys: Set<String> = ["session", "text", "by", "kind", "note"]
  private static let waitKeys: Set<String> = [
    "session", "kind", "target", "who", "environment", "service", "state", "until", "note", "then", "by", "wait",
    "outcome",
  ]

  /// The op table of "The scope design". `answer` also takes `always`, which it reads through `AllowExtra` as it
  /// reads `autoMode`, and which the plan's row left out.
  static let rows: [String: Row] = [
    "ping": Row(keys: []),
    "ls": Row(keys: []),
    "get": sessionOnly, "reply": sessionOnly, "terminals": sessionOnly, "stop": sessionOnly,
    "screen": Row(keys: ["session", "pane", "colors"], refs: ["session"]),
    "shell": Row(keys: ["session", "open"], refs: ["session"]),
    "open": Row(keys: ["session", "terminals"], refs: ["session"]),
    "resume": Row(keys: ["session", "prompt"], refs: ["session"]),
    "done": Row(keys: ["session", "done"], refs: ["session"]),
    "rename": Row(keys: ["session", "name"], refs: ["session"]),
    "issue": Row(keys: ["session", "issue", "clear"], refs: ["session"]),
    "note": Row(keys: noteKeys, refs: ["session"]),
    "remove-note": Row(keys: noteKeys, refs: ["session"]),
    "resolve-note": Row(keys: noteKeys, refs: ["session"]),
    "wait": Row(keys: waitKeys, refs: ["session"], waitTarget: true),
    "clear-wait": Row(keys: waitKeys, refs: ["session"]),
    "resolve-wait": Row(keys: waitKeys, refs: ["session"]),
    "events": Row(keys: ["session", "sessions", "since", "limit"], refs: ["session"], refLists: ["sessions"]),
    "send": Row(keys: ["session", "text", "from"], refs: ["session", "from"]),
    "answer": Row(
      keys: ["session", "card", "behavior", "autoMode", "always", "message", "answers"], refs: ["session"]),
    "summary-set": Row(keys: ["session", "card"], refs: ["session"]),
    "new": Row(
      keys: [
        "path", "branch", "base", "name", "worktree", "prompt", "model", "parent", "autoMode", "planMode", "manualMode",
        "host", "issue",
      ],
      refs: ["parent"]),
    "spawn": Row(
      keys: [
        "repository", "branch", "prompt", "base", "wait", "parent", "name", "model", "autoMode", "planMode", "host",
      ],
      refs: ["parent"]),
  ]

  /// Every op of `handle` and `dispatch` that the plan refuses from a host. `accounts` is here although the plan
  /// names only `account-*`, because it lists this Mac's accounts. The `activity`, `draft`, `issues`, and
  /// `live-next` ops came from main after the plan, and the table denies every op it doesn't name.
  static let refused: [String] = [
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

  /// The ops that `handleHostRequest` sends on their own path before the table: `hook` to `handleHostHook`, and
  /// `cli` to its refusal until stage 4.
  static let ownPaths: Set<String> = ["hook", "cli"]

  /// A request of `op` that the table admits, with every session it names on mini.
  static func baseArgs(_ op: String) -> [String: JSON] {
    switch op {
    case "ping", "ls", "events": [:]
    case "new": ["path": "/srv/new"]
    case "spawn": ["repository": "o/n", "branch": "b1", "prompt": "hello"]
    case "send": ["session": "m1", "text": "hello"]
    default: ["session": "m1"]
    }
  }

  /// A value of the right type for each key of the row, with every session on mini.
  static func everyKey(_ op: String) -> [String: JSON] {
    let row = rows[op]!
    var args: [String: JSON] = [:]
    for key in row.keys {
      args[key] =
        switch key {
        case _ where row.refs.contains(key): "m1"
        case _ where row.refLists.contains(key): ["m1"]
        case "host": "mini"
        case "kind" where row.waitTarget: "session"
        case "target" where row.waitTarget: "mq7x"
        case "card" where op == "summary-set": ["summary": "a turn"]
        case "since", "limit", "card": 3
        case "answers": ["yes"]
        case "colors", "open", "terminals", "done", "clear", "worktree", "autoMode", "always", "planMode",
          "manualMode":
          true
        default: .string("\(key) value")
        }
    }
    return args
  }
}

/// One key of one op that names sessions.
struct RefSlot: Sendable, CustomTestStringConvertible {
  enum Shape: Sendable { case one, list, waitTarget }

  var op: String
  var key: String
  var shape: Shape

  var testDescription: String { "\(op).\(key)" }

  /// Puts `value` where the slot names a session. A list holds mini's `m1` before it, so a refusal comes from
  /// `value` alone.
  func args(with value: JSON) -> [String: JSON] {
    var args = PlannedScope.baseArgs(op)
    switch shape {
    case .one: args[key] = value
    case .list: args[key] = .array(["m1", value])
    case .waitTarget:
      args["kind"] = "session"
      args["state"] = "idle"
      args["target"] = value
    }
    return args
  }

  /// The value at the slot of a request that `authorize` returned.
  func value(in args: JSON) -> JSON? {
    switch shape {
    case .one: args[key]
    case .list: args[key]?.array?.last
    case .waitTarget: args["target"]
    }
  }

  static let all: [RefSlot] = PlannedScope.rows.keys.sorted().flatMap { op -> [RefSlot] in
    let row = PlannedScope.rows[op]!
    return row.refs.map { RefSlot(op: op, key: $0, shape: .one) }
      + row.refLists.map { RefSlot(op: op, key: $0, shape: .list) }
      + (row.waitTarget ? [RefSlot(op: op, key: "target", shape: .waitTarget)] : [])
  }
}

private func session(_ id: String, host: String?, name: String) -> Session {
  var s = Session(id: id, name: name, cwd: "/srv/repo", claudeSessionId: "u-\(id)", created: 5)
  s.host = host
  s.started = true
  return s
}

/// A local session, two sessions on mini, and one on other. `m1`'s name is the local session's id, and `o1`'s name
/// is `m1`'s id, so a name never stands in for an id. `mq7x`'s id and name collide with nothing.
private let sessions = [
  session("l1", host: nil, name: "local"),
  session("m1", host: "mini", name: "l1"),
  session("o1", host: "other", name: "m1"),
  session("mq7x", host: "mini", name: "box"),
]

private func authorize(_ op: String, _ args: [String: JSON]) throws -> Request {
  try HostScope.authorize(Request(op: op, args: .object(args)), host: "mini", sessions: sessions)
}

/// Whether `body` throws an error whose text holds `text`, or any error when `text` is nil.
private func refuses(_ text: String?, _ body: () throws -> Request) -> (Bool, String) {
  do {
    let request = try body()
    return (false, "authorized: \(request.op) \(request.args.text)")
  } catch {
    return (text.map { "\(error)".contains($0) } ?? true, "\(error)")
  }
}

/// `HostScope.authorize` over a fixed list of sessions. It runs no service.
@Suite struct HostScopeTableTests {
  // MARK: The ops

  @Test func theTableAdmitsExactlyTheOpsOfThePlan() {
    #expect(Set(HostScope.rules.keys) == Set(PlannedScope.rows.keys))
  }

  @Test(arguments: PlannedScope.refused)
  func everyOpThatThePlanRefusesIsRefusedWithItsName(op: String) {
    let (refused, why) = refuses("\(op) can't run from mini") { try authorize(op, ["session": "m1"]) }

    #expect(HostScope.refused[op] != nil)
    #expect(refused, "\(why)")
  }

  @Test(arguments: [
    "no-such-op", "", "Get", "get ", " ls", "PING", "ls\0", "send\n", "hook", "Hook", "spawn-group", "events-follow",
  ])
  func anOpThatNoTableNamesIsRefused(op: String) {
    let (refused, why) = refuses("\(op) can't run from mini") { try authorize(op, ["session": "m1"]) }

    #expect(refused, "\(why)")
  }

  @Test func noOpIsBothAdmittedAndRefused() {
    #expect(Set(HostScope.rules.keys).isDisjoint(with: HostScope.refused.keys))
  }

  // MARK: The keys

  /// A request that names only mini's sessions by their ids passes unchanged, with every key of its row.
  @Test(arguments: PlannedScope.rows.keys.sorted())
  func aRequestWithEveryKeyOfItsRowPassesUnchanged(op: String) throws {
    let args = PlannedScope.everyKey(op)

    let authorized = try authorize(op, args)

    #expect(authorized.op == op)
    #expect(authorized.args == .object(args))
  }

  @Test(arguments: PlannedScope.rows.keys.sorted())
  func aKeyOutsideTheRowIsRefused(op: String) {
    var args = PlannedScope.baseArgs(op)
    args["pwned"] = "x"

    let (refused, why) = refuses("pwned") { try authorize(op, args) }

    #expect(refused, "\(why)")
  }

  /// The keys that Risk 1 names, and keys that differ from a row's key only in their spelling.
  @Test(arguments: [
    ("send", "images"), ("new", "account"), ("new", "group"), ("get", "host"), ("spawn", "account"),
    ("spawn", "group"), ("spawn", "followup"), ("spawn", "after"), ("ping", "session"), ("ls", "session"),
    ("wait", "on"), ("get", "Session"), ("send", "session "), ("events", "follow"), ("answer", "always "),
  ])
  func aKeyThatTheOpDoesNotReadIsRefused(op: String, key: String) {
    var args = PlannedScope.baseArgs(op)
    args[key] = key == "images" ? [["name": "a.png", "data": "AA=="]] : "m1"

    let (refused, why) = refuses(key.trimmingCharacters(in: .whitespaces)) { try authorize(op, args) }

    #expect(refused, "\(why)")
  }

  // MARK: The session references

  /// `l1` is the local session's id and also `m1`'s name. An exact id of a session off mini is refused before any
  /// name among mini's sessions is read.
  @Test(arguments: RefSlot.all, ["l1", "o1", "local", "l", "o", "nope"])
  func aRefToASessionOffTheHostIsRefused(slot: RefSlot, ref: String) {
    let (refused, why) = refuses("that session is not on mini") {
      try authorize(slot.op, slot.args(with: .string(ref)))
    }

    #expect(refused, "\(why)")
  }

  /// An empty ref, a prefix that two of mini's sessions share, and other spellings of mini's ids.
  @Test(arguments: RefSlot.all, ["", "m", "M1", " m1", "m1 ", "m1\n", "m1\0", "MQ7X", "Box"])
  func aRefThatNamesNoSingleSessionOfTheHostIsRefused(slot: RefSlot, ref: String) {
    let (refused, why) = refuses(nil) { try authorize(slot.op, slot.args(with: .string(ref))) }

    #expect(refused, "\(why)")
  }

  @Test(
    arguments: RefSlot.all,
    [JSON.number(7), .bool(true), .null, .array(["m1"]), .object(["session": "m1"]), .array([])])
  func aRefOfTheWrongJSONTypeIsRefused(slot: RefSlot, value: JSON) {
    let (refused, why) = refuses(nil) { try authorize(slot.op, slot.args(with: value)) }

    #expect(refused, "\(why)")
  }

  @Test(arguments: [JSON.string("m1"), .number(7), .null, .bool(true), .object(["0": "m1"]), .array([["m1"]])])
  func aListOfSessionsThatIsNotAListOfStringsIsRefused(value: JSON) {
    let (refused, why) = refuses(nil) { try authorize("events", ["sessions": value]) }

    #expect(refused, "\(why)")
  }

  /// The op's own `lookup` runs over every session, so the rewrite must leave it an exact id of mini.
  @Test(
    arguments: RefSlot.all, [("m1", "m1"), ("mq7x", "mq7x"), ("mq", "mq7x"), ("box", "mq7x")] as [(String, String)])
  func theRewriteGivesTheExactIdOfTheHostsSession(slot: RefSlot, ref: (String, String)) throws {
    let (given, exact) = ref

    let authorized = try authorize(slot.op, slot.args(with: .string(given)))

    #expect(slot.value(in: authorized.args) == .string(exact))
  }

  @Test func theRewriteChangesNoKeyButTheRefs() throws {
    let args: [String: JSON] = ["session": "box", "text": "box", "from": "mq"]

    let authorized = try authorize("send", args)

    #expect(authorized.args == ["session": "mq7x", "text": "box", "from": "mq7x"])
  }

  /// A PR kind's target is a PR, so it is not a session and keeps its text.
  @Test(arguments: ["ci", "review", "bot-review", "approval", "queue", "merge", "deploy"])
  func theTargetOfAWaitOfAnotherKindIsNotASession(kind: String) throws {
    let authorized = try authorize("wait", ["session": "m1", "kind": .string(kind), "target": "local"])

    #expect(authorized.args["target"] == "local")
  }

  @Test(arguments: ["review", "ci", "merge", "deploy"], ["7", "#7", "pr:7"])
  func aPRWaitByNumberInTheSessionsRepoIsTaken(kind: String, target: String) throws {
    let authorized = try authorize("wait", ["session": "m1", "kind": .string(kind), "target": .string(target)])

    #expect(authorized.args["target"] == .string(target))
  }

  @Test(
    arguments: ["review", "ci", "merge", "deploy"],
    ["acme/private#7", "pr:acme/private#7", "https://github.com/acme/private/pull/7"])
  func aPRWaitThatNamesARepoIsRefused(kind: String, target: String) {
    let (refused, why) = refuses("names a PR by its number in the session's repo") {
      try authorize("wait", ["session": "m1", "kind": .string(kind), "target": .string(target)])
    }

    #expect(refused, "\(why)")
  }

  // MARK: The host of a new session

  @Test(arguments: ["new", "spawn"], [JSON?.none, .string("mini")])
  func aNewSessionFromTheHostRunsOnTheHost(op: String, host: JSON?) throws {
    var args = PlannedScope.baseArgs(op)
    args["host"] = host

    let authorized = try authorize(op, args)

    #expect(authorized.args["host"] == "mini")
  }

  @Test(arguments: ["new", "spawn"], ["local", "other"])
  func aNewSessionFromTheHostOnAnotherMachineIsRefused(op: String, host: String) {
    var args = PlannedScope.baseArgs(op)
    args["host"] = .string(host)

    let (refused, why) = refuses("can start sessions only on mini") { try authorize(op, args) }

    #expect(refused, "\(why)")
  }

  @Test(arguments: ["new", "spawn"], [JSON.string(""), "LOCAL", "Mini", "mini ", " mini", "nope", 7, .null, ["mini"]])
  func aNewSessionFromTheHostWithAnyOtherHostIsRefused(op: String, host: JSON) {
    var args = PlannedScope.baseArgs(op)
    args["host"] = host

    let (refused, why) = refuses(nil) { try authorize(op, args) }

    #expect(refused, "\(why)")
  }

  // MARK: The classifier

  @Test func everyOpIsClassified() throws {
    let labels = try OpLabels.scanSources()

    let unclassified = OpLabels.unclassified(labels)

    #expect(unclassified.isEmpty, "\(unclassified.map(\.description).joined(separator: "\n"))")
  }

  /// A name in the table that no router has would hide a typo, such as `group-*` for the group ops.
  @Test func everyClassifiedOpIsAnOpOfTheRouter() throws {
    let ops = Set(try OpLabels.scanSources().map(\.op))

    let stale = Set(HostScope.rules.keys).union(HostScope.refused.keys).subtracting(ops).subtracting(
      PlannedScope.ownPaths)

    #expect(stale.isEmpty, "\(stale.sorted())")
  }

  @Test func theClassifierFailsForALabelAddedToDispatch() throws {
    let file = "SwitchboardService/Service.swift"
    let text = try #require(try SourceAudit.sourceFiles().first { $0.file == file }?.text)
    let ping = "    case \"ping\":\n"
    try #require(text.components(separatedBy: ping).count == 2)
    let added = """
          case "x-added":
            return .null
          case "x-first",
            "x-continued":
            return .null

      """
    let edited = text.replacingOccurrences(of: ping, with: added + ping)

    let before = Set(OpLabels.unclassified(OpLabels.scan(text, file: file)).map(\.op))
    let after = Set(OpLabels.unclassified(OpLabels.scan(edited, file: file)).map(\.op))

    #expect(after == before.union(["x-added", "x-first", "x-continued"]))
  }

  /// The scan finds the routers of every file, labels on continuation lines, and no string of a `where` clause or
  /// of a switch on another value.
  @Test func theScanReadsEveryRouterOfTheService() throws {
    let labels = try OpLabels.scanSources()
    let ops = Set(labels.map(\.op))
    let files = Set(labels.map(\.file))

    #expect(
      ops.isSuperset(of: [
        "hook", "ping", "group-suggest", "send-group", "send-pending", "plan-artifact-report", "decision-discard",
        "summary-set", "followup-import", "resolve-note", "clear-wait", "plan-reject", "plan-auto",
      ]))
    #expect(ops.isDisjoint(with: ["images", "read", "proposal", "check", "published", "allow", "deny"]))
    #expect(
      files.isSuperset(of: [
        "SwitchboardService/Service.swift", "SwitchboardService/Service+Followups.swift",
        "SwitchboardService/Service+Decisions.swift", "SwitchboardService/Service+Groups.swift",
        "SwitchboardService/Service+Triage.swift", "SwitchboardService/Service+PlanArtifacts.swift",
        "SwitchboardService/Service+PlanUpdates.swift", "SwitchboardService/Service+Plans.swift",
        "SwitchboardService/Service+Waits.swift", "SwitchboardService/Service+Issues.swift",
        "SwitchboardService/Service+DraftReplies.swift",
      ]))
  }

  @Test func theScanReadsLabelsAcrossLinesAndDropsAWhereClause() {
    let text = """
        func handle(_ request: Request) -> Response {
          switch request.op {
          case "a", "b":
            return x
          case "c",
            "d",
            "e":
            return y
          case "send" where request.args["images"] != nil:
            return z
          default:
            break
          }
        }

      """

    let ops = OpLabels.scan(text, file: "f.swift").map(\.op)

    #expect(ops == ["a", "b", "c", "d", "e", "send"])
  }

  @Test func theScanSkipsASwitchOnAnotherValueInsideARouter() {
    let text = """
        func route(_ op: String, _ args: JSON) throws -> JSON {
          switch op {
          case "report":
            switch kind {
            case "read":
              break
            default:
              break
            }
          case "reject":
            break
          default:
            break
          }
          switch kind {
          case "proposal":
            break
          }
        }

      """

    let ops = OpLabels.scan(text, file: "f.swift").map(\.op)

    #expect(ops == ["report", "reject"])
  }

  @Test func aLabelNamesItsFileAndLine() {
    let text = "func f() {\n  switch op {\n  case \"one\",\n    \"two\":\n    break\n  }\n}\n"

    let labels = OpLabels.scan(text, file: "SwitchboardService/X.swift")

    #expect(labels.map(\.description) == ["SwitchboardService/X.swift:3: one", "SwitchboardService/X.swift:4: two"])
  }
}

/// The ops that the service's routers take: the string labels of every `switch op` and `switch request.op` in
/// `Sources/SwitchboardService`. `handle` and `dispatch` route every request, and each `<group>Request(op, args)`
/// that they call switches on the same op. The scan reads the source as `bin/fmt` lays it out: a switch's cases
/// sit at the switch's own indent, and its closing brace is alone on a line at that indent.
enum OpLabels {
  struct Label: Equatable, CustomStringConvertible {
    var op: String
    var file: String
    var line: Int
    var description: String { "\(file):\(line): \(op)" }
  }

  private static let router = try! NSRegularExpression(pattern: #"^(\s*)switch (?:request\.)?op \{$"#)

  static func scan(_ text: String, file: String) -> [Label] {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var labels: [Label] = []
    for (index, line) in lines.enumerated() {
      let range = NSRange(line.startIndex..., in: line)
      guard let match = router.firstMatch(in: line, range: range), let indent = Range(match.range(at: 1), in: line)
      else { continue }
      let pad = String(line[indent])
      var at = index + 1
      while at < lines.count, lines[at] != "\(pad)}" {
        if lines[at].hasPrefix("\(pad)case ") {
          labels += caseLabels(lines, from: at, after: pad.count + 5, file: file)
        }
        at += 1
      }
    }
    return labels
  }

  /// The string literals of one `case` label, which runs to its `:` or its `where` and may span lines.
  private static func caseLabels(_ lines: [String], from start: Int, after column: Int, file: String) -> [Label] {
    var labels: [Label] = []
    var row = start
    var chars = Array(lines[row].dropFirst(column))
    var i = 0
    while true {
      while i < chars.count, chars[i] == " " { i += 1 }
      if i == chars.count {
        row += 1
        guard row < lines.count else { return labels }
        chars = Array(lines[row])
        i = 0
        continue
      }
      guard chars[i] == "\"" else { return labels }
      i += 1
      var literal = ""
      while i < chars.count, chars[i] != "\"" {
        if chars[i] == "\\", i + 1 < chars.count { i += 1 }
        literal.append(chars[i])
        i += 1
      }
      i += 1
      labels.append(Label(op: literal, file: file, line: row + 1))
      while i < chars.count, chars[i] == " " { i += 1 }
      guard i < chars.count, chars[i] == "," else { return labels }
      i += 1
    }
  }

  /// Every label of the service's Swift files.
  static func scanSources() throws -> [Label] {
    try SourceAudit.sourceFiles().filter { $0.file.hasPrefix(SourceAudit.service) }.flatMap {
      scan($0.text, file: $0.file)
    }
  }

  /// The labels that neither the table nor the list of refused ops names, and that take no path of their own.
  static func unclassified(_ labels: [Label]) -> [Label] {
    labels.filter {
      HostScope.rules[$0.op] == nil && HostScope.refused[$0.op] == nil && !PlannedScope.ownPaths.contains($0.op)
    }
  }
}
