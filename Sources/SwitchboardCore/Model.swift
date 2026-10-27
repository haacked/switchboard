import Foundation

/// The board's columns. Their order is the order the board shows them.
public enum AttentionState: String, Codable, CaseIterable, Comparable, Sendable {
  case needsYou = "needs_you"
  case canContinue = "can_continue"
  case waiting
  case working
  case done
  case stale
  /// A follow-up that hasn't started.
  case notStarted = "not_started"

  public var title: String {
    switch self {
    case .needsYou: "Needs you"
    case .canContinue: "Claude can continue"
    case .waiting: "Waiting"
    case .working: "Working"
    case .done: "Done"
    case .stale: "Stale"
    case .notStarted: "Not started"
    }
  }

  public static func < (a: AttentionState, b: AttentionState) -> Bool {
    allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
  }
}

/// A session as sbd stores it. The attention state comes from its events.
/// A field added later needs a default or an optional type, because sbd
/// decodes the sessions that an older sbd stored.
public struct Session: Codable, Equatable, Sendable {
  public var id: String
  public var name: String
  public var cwd: String
  /// The folder that `new` made the worktree from, or nil when the session
  /// runs in a folder that sbd didn't create.
  public var repo: String?
  public var branch: String?
  /// The conversation that a resume opens. It follows `/clear` and `/resume`
  /// in the pane, because each SessionStart reports the current one.
  public var claudeSessionId: String
  public var model: String?
  /// Milliseconds since the epoch.
  public var created: Int64
  /// True once claude has run, so a transcript exists to resume.
  public var started: Bool
  public var done: Bool
  /// v0.1's free-text wait. `Service.load` turns it into a manual wait.
  public var waitNote: String?
  /// The open waits, oldest first. Nil in a session that an older sbd stored.
  public var waits: [Wait]?
  /// Nil in a session that an older sbd stored.
  public var notes: [Note]?
  /// The session that added this one, such as the session that captured a follow-up.
  public var parent: String?
  /// Set on a follow-up. Until it starts, `cwd` is empty and claude never runs.
  public var followup: Followup?

  public init(
    id: String, name: String, cwd: String, repo: String? = nil, branch: String? = nil,
    claudeSessionId: String, model: String? = nil, created: Int64
  ) {
    self.id = id
    self.name = name
    self.cwd = cwd
    self.repo = repo
    self.branch = branch
    self.claudeSessionId = claudeSessionId
    self.model = model
    self.created = created
    self.started = false
    self.done = false
    self.waitNote = nil
  }
}

/// One entry in the event log: a hook payload, or something sbd did.
public struct Event: Codable, Equatable, Sendable {
  public var id: Int64
  public var session: String
  /// Milliseconds since the epoch.
  public var t: Int64
  public var kind: String
  public var data: JSON

  public init(id: Int64 = 0, session: String, t: Int64, kind: String, data: JSON = [:]) {
    self.id = id
    self.session = session
    self.t = t
    self.kind = kind
    self.data = data
  }

  /// Hooks fire for a subagent's tool calls too, with its agent_id.
  public var fromSubagent: Bool { data["agent_id"]?.string != nil }
}

/// What `sb ls` and the GUI show for a session.
public struct SessionSummary: Codable, Equatable, Sendable, Identifiable {
  public var id: String
  public var name: String
  public var cwd: String
  public var repo: String?
  public var branch: String?
  public var claudeSessionId: String
  public var state: AttentionState
  public var reason: String
  /// When the session entered its state, in ms since the epoch.
  public var since: Int64
  public var lastActivity: Int64
  /// True from claude's SessionStart until claude ends or exits.
  public var live: Bool
  public var claudePid: Int?
  /// True while a terminal shows the session's Claude pane.
  public var attached: Bool
  public var lastReply: String?
  public var waits: [Wait]
  public var notes: [Note]
  /// Open and deferred permission prompts and questions, oldest first.
  public var cards: [Card]
  /// True while Claude Code shows a permission or question dialog, with or
  /// without a card. Without a card, only the terminal can answer it.
  public var openPrompt: Bool
  public var parent: String?
  public var followup: Followup?
  /// When the session was added, in ms since the epoch. An imported
  /// follow-up was added on the date of its line.
  public var created: Int64?

  public init(
    id: String, name: String, cwd: String, repo: String?, branch: String?, claudeSessionId: String,
    state: AttentionState, reason: String, since: Int64, lastActivity: Int64, live: Bool,
    claudePid: Int?, attached: Bool, lastReply: String?, waits: [Wait], notes: [Note], cards: [Card] = [],
    openPrompt: Bool = false
  ) {
    self.id = id
    self.name = name
    self.cwd = cwd
    self.repo = repo
    self.branch = branch
    self.claudeSessionId = claudeSessionId
    self.state = state
    self.reason = reason
    self.since = since
    self.lastActivity = lastActivity
    self.live = live
    self.claudePid = claudePid
    self.attached = attached
    self.lastReply = lastReply
    self.waits = waits
    self.notes = notes
    self.cards = cards
    self.openPrompt = openPrompt
  }
}

/// The tmux targets of a session's two terminals.
public struct Terminals: Codable, Equatable, Sendable {
  public var tmux: String
  public var socket: String
  public var claude: String
  public var shell: String

  public init(tmux: String, socket: String, claude: String, shell: String) {
    self.tmux = tmux
    self.socket = socket
    self.claude = claude
    self.shell = shell
  }

  /// The command that attaches a terminal to one of the two panes.
  public func attachCommand(_ pane: Pane) -> [String] {
    [tmux, "-S", socket, "attach-session", "-t", "=\(pane == .claude ? claude : shell)"]
  }
}

public enum Pane: String, Sendable {
  case claude
  case shell
}

public func nowMs() -> Int64 {
  Clock.now()
}

/// The text on one line, cut to `max` characters with an ellipsis.
public func oneLine(_ text: String, max: Int = 70) -> String {
  let line = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
    .filter { !$0.isEmpty }.joined(separator: " ")
  return line.count <= max ? line : String(line.prefix(max - 1)) + "…"
}

private let timestamp = ISO8601DateFormatter()

/// Writes a timestamped line to stderr, which launchd sends to sbd.log.
public func logLine(_ message: String) {
  FileHandle.standardError.write(Data("\(timestamp.string(from: Date())) \(message)\n".utf8))
}

public enum Version {
  public static let text = "0.1.0"
}
