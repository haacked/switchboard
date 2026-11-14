import Foundation
import SwitchboardCore

/// What a request that arrived on host h's socket may do. It denies by default: an op that `rules` doesn't name
/// fails, and so does a key that the op's rule doesn't list. Each key that names a session resolves among h's
/// sessions only, and `authorize` replaces it with that session's exact id, so the op's own `lookup` over every
/// session finds the same one.
///
/// `authorize` runs on the state queue before the op. The op checks again in the state queue block that runs it,
/// through `Service.requireOnHost`, that each session the request names is still on h. `create` checks a new
/// session's parent itself, and `answer` checks a `send` card's targets.
enum HostScope {
  struct Rule {
    /// Every key that the op reads.
    var keys: Set<String>
    /// The keys whose string names one session.
    var refs: [String] = []
    /// The keys whose list of strings names sessions.
    var refLists: [String] = []
    /// `target` names a session when `kind` is `session`.
    var waitTarget = false
    /// The op starts a session, so its `host` is absent or h, and `authorize` sets it to h.
    var creates = false
  }

  private static let session = Rule(keys: ["session"], refs: ["session"])
  /// The keys that `noteRequest`, `makeNote`, and `resolveNote` read.
  private static let noteKeys: Set<String> = ["session", "text", "by", "kind", "note"]
  /// The fields of `WaitRequest`, and the keys that `waitRequest` reads for `clear-wait` and `resolve-wait`.
  private static let waitKeys: Set<String> = [
    "session", "kind", "target", "who", "environment", "service", "state", "until", "note", "then", "by", "wait",
    "outcome",
  ]

  /// The ops that a host may send, with the keys that each one reads.
  static let rules: [String: Rule] = [
    "ping": Rule(keys: []),
    "ls": Rule(keys: []),
    "get": session, "reply": session, "terminals": session, "stop": session,
    "screen": Rule(keys: ["session", "pane", "colors"], refs: ["session"]),
    "shell": Rule(keys: ["session", "open"], refs: ["session"]),
    "open": Rule(keys: ["session", "terminals"], refs: ["session"]),
    "resume": Rule(keys: ["session", "prompt"], refs: ["session"]),
    "done": Rule(keys: ["session", "done"], refs: ["session"]),
    "rename": Rule(keys: ["session", "name"], refs: ["session"]),
    "issue": Rule(keys: ["session", "issue", "clear"], refs: ["session"]),
    "note": Rule(keys: noteKeys, refs: ["session"]),
    "remove-note": Rule(keys: noteKeys, refs: ["session"]),
    "resolve-note": Rule(keys: noteKeys, refs: ["session"]),
    "wait": Rule(keys: waitKeys, refs: ["session"], waitTarget: true),
    "clear-wait": Rule(keys: waitKeys, refs: ["session"]),
    "resolve-wait": Rule(keys: waitKeys, refs: ["session"]),
    "events": Rule(keys: ["session", "sessions", "since", "limit"], refs: ["session"], refLists: ["sessions"]),
    // No `images`, so the path that reads image files never runs.
    "send": Rule(keys: ["session", "text", "from"], refs: ["session", "from"]),
    "answer": Rule(
      keys: ["session", "card", "behavior", "autoMode", "always", "message", "answers"], refs: ["session"]),
    "summary-set": Rule(keys: ["session", "card"], refs: ["session"]),
    // No `account` or `group`.
    "new": Rule(
      keys: [
        "path", "branch", "base", "name", "worktree", "prompt", "model", "parent", "autoMode", "planMode", "manualMode",
        "host", "issue",
      ],
      refs: ["parent"], creates: true),
    // No `account`, `group`, `followup`, or `after`.
    "spawn": Rule(
      keys: [
        "repository", "branch", "prompt", "base", "wait", "parent", "name", "model", "autoMode", "planMode", "host",
      ],
      refs: ["parent"], creates: true),
  ]

  private static let stops =
    "sbd can't tell whether a client on a host runs inside the session that this would stop. Run it on this Mac"
  private static let reaches = "it reaches sessions on this Mac"
  private static let actsHere = "it acts on this Mac, on GitHub with this Mac's login, or on every session"

  /// Every other op of the service's routers, with the reason a host can't send it. `hook` and `cli` take their
  /// own paths in `handleHostRequest`.
  static let refused: [String: String] = {
    var refused: [String: String] = [:]
    for op in ["rm", "cleanup", "rm-done"] { refused[op] = stops }
    for op in [
      "send-group", "send-pending", "group-ls", "group-add", "group-rm", "group-move", "group-note", "group-describe",
      "group-account", "group-suggest", "manager", "manager-ls", "manager-mcp", "chat", "chat-log",
    ] {
      refused[op] = reaches
    }
    for op in [
      "import", "importable", "accounts", "account-use", "account-move", "usage", "mcp", "hosts", "host-connect",
      "host-disconnect", "live", "live-next", "autocontinue", "snapshots", "poll", "repos", "repo-add", "clock",
      "triage", "choose", "decisions", "decision-answer", "decision-submit", "decision-resend", "decision-discard",
      "plan-attach", "plan-update", "plan-propose", "plan-apply", "plan-artifact-read", "plan-artifact-rewrite",
      "plan-artifact-apply", "plan-artifact-reject", "plan-artifact-report", "plan-followup", "plan-ls", "plan-get",
      "plan-detach", "plan-auto", "plan-proposals", "plan-reject", "followup-add", "followup-ls", "followup-start",
      "followup-rm", "followup-import", "pr-merged", "docket-start", "merge", "review", "ack", "resolved-todos",
      "dependency-resolved", "activity", "activity-report", "activity-clear", "draft-post", "draft-check", "issues",
      "issues-refresh", "issues-start", "issues-clone", "issues-source-add", "issues-source-rm", "issues-settings",
      "issues-dismiss",
    ] {
      refused[op] = actsHere
    }
    return refused
  }()

  static func notOnHost(_ host: String) -> APIError { APIError("that session is not on \(host)") }

  /// The request with each session reference replaced by the exact id of a session on `host`, and the `host` of
  /// `new` and `spawn` set to `host`. It throws for an op that `rules` doesn't name, for arguments that aren't an
  /// object, for a key outside the op's rule, and for a reference that names no single session on `host`.
  /// `sessions` is every session that sbd holds. It runs on the state queue.
  static func authorize(_ request: Request, host: String, sessions: [Session]) throws -> Request {
    let op = request.op
    guard let rule = rules[op] else {
      throw APIError("\(op) can't run from \(host)\(refused[op].map { ": \($0)" } ?? "")")
    }
    guard var args = request.args.object else { throw APIError("\(op) from \(host) takes an object of arguments") }
    let unread = Set(args.keys).subtracting(rule.keys)
    guard unread.isEmpty else {
      throw APIError("\(op) from \(host) doesn't take \(unread.sorted().joined(separator: ", "))")
    }
    func resolved(_ value: JSON, _ key: String) throws -> JSON {
      guard let ref = value.string else { throw APIError("\(key) names a session by its id or name") }
      return .string(try resolve(ref, host: host, sessions: sessions))
    }
    for key in rule.refs { if let value = args[key] { args[key] = try resolved(value, key) } }
    for key in rule.refLists {
      guard let value = args[key] else { continue }
      guard let items = value.array else { throw APIError("\(key) is a list of sessions") }
      args[key] = .array(try items.map { try resolved($0, key) })
    }
    if rule.waitTarget, let target = args["target"] {
      if args["kind"] == .string(Wait.Kind.session.rawValue) {
        args["target"] = try resolved(target, "target")
      } else if let text = target.string, Wait.PullRequest(parsing: text)?.repository != nil {
        // This Mac's GitHub login polls the PR, so a host may name only a PR of its session's own repo.
        throw APIError("a wait from \(host) names a PR by its number in the session's repo")
      }
    }
    if rule.creates {
      var named: String?
      if let value = args["host"] {
        guard let name = value.string else { throw APIError("host is a host name") }
        named = name
      }
      args["host"] = try SessionHost.choose(named: named, parent: nil, origin: .remote(host)).map(JSON.string)
    }
    return Request(op: op, args: .object(args))
  }

  /// The exact id of the session on `host` that `ref` names: its id, a unique prefix of an id, or a unique name,
  /// among `host`'s sessions only. An exact id of a session elsewhere fails before any name is read.
  private static func resolve(_ ref: String, host: String, sessions: [Session]) throws -> String {
    guard !ref.isEmpty else { throw APIError("name a session") }
    if let exact = sessions.first(where: { $0.id == ref }), exact.host != host { throw notOnHost(host) }
    let onHost = sessions.filter { $0.host == host }.map { (id: $0.id, name: $0.name) }
    guard onHost.contains(where: { $0.id.hasPrefix(ref) || $0.name == ref }) else { throw notOnHost(host) }
    return try resolveRef(ref, "session", onHost)
  }

  /// The ids of the sessions that a request which `authorize` returned names.
  static func sessionIds(of request: Request) -> [String] {
    guard let rule = rules[request.op] else { return [] }
    var ids = rule.refs.compactMap { request.args[$0]?.string }
    for key in rule.refLists { ids += request.args[key]?.array?.compactMap(\.string) ?? [] }
    if rule.waitTarget, request.args["kind"] == .string(Wait.Kind.session.rawValue),
      let target = request.args["target"]?.string
    {
      ids.append(target)
    }
    return ids
  }
}

extension RequestOrigin {
  /// Whether a request from this origin may read a session on `host`, nil for this Mac. A request from this Mac
  /// reads every session, and a request from a host reads only that host's sessions.
  func reaches(_ host: String?) -> Bool {
    guard case .remote(let origin) = self else { return true }
    return host == origin
  }
}
