import Foundation

/// The board's columns. Their order is the order the board shows them.
public enum AttentionState: String, Codable, CaseIterable, Comparable, Sendable {
  case needsYou = "needs_you"
  /// An idle session whose PR can merge now.
  case readyToMerge = "ready_to_merge"
  case canContinue = "can_continue"
  /// A session that the other rules put in Waiting and whose PR is open and not a draft.
  case readyForReview = "ready_for_review"
  case waiting
  case working
  case done
  case stale
  /// A follow-up that hasn't started.
  case notStarted = "not_started"

  public var title: String {
    switch self {
    case .needsYou: "Needs you"
    case .readyToMerge: "Ready to merge"
    case .canContinue: "Claude can continue"
    case .readyForReview: "Ready for review"
    case .waiting: "Waiting"
    case .working: "Working"
    case .done: "Done"
    case .stale: "Stale"
    case .notStarted: "Not started"
    }
  }

  /// Whether the session waits for the user: Needs you, or Ready to merge,
  /// which waits for the user's click on Merge.
  public var needsUser: Bool { self == .needsYou || self == .readyToMerge }

  /// The states whose sessions the Inbox lists, in its order.
  public static let inbox: [AttentionState] = [.needsYou, .readyToMerge, .canContinue]

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
  /// True once sbd has started claude for the session, or imported it. Until
  /// then the conversation has no transcript. A transcript may still not
  /// exist after that, because claude writes none before the first prompt.
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
  /// True for a Manager conversation. Several can exist.
  public var manager: Bool?
  /// Set on a follow-up. Until it starts, `cwd` is empty and claude never runs.
  public var followup: Followup?
  /// The Claude account that the session's claude runs under. Every session
  /// that sbd creates or imports has one. It is nil in a session that an
  /// older sbd stored, which uses the account of sbd and config.env.
  public var claudeConfigDir: String?
  /// The id of the session's group, or nil for Ungrouped.
  public var group: String?
  /// True once the user chose the session's group, or chose Ungrouped. A
  /// session that took its parent's group has it false.
  public var placedByHand: Bool?
  /// Set on a docket row, which tracks one docket review. Its `cwd` is empty
  /// and claude never runs.
  public var docket: DocketSession?
  /// The id of the group whose chat this session is. A chat belongs to no group.
  public var chat: String?
  /// True when every launch starts claude in auto mode, so a resumed session
  /// keeps it. Otherwise sbd passes no permission mode, and Claude's settings
  /// choose one. Nil in a session that an older sbd stored.
  public var autoMode: Bool?
  /// True when the session started in plan mode. `PermissionMode.forLaunch`
  /// reads it on every launch. It stays set after the plan is approved.
  public var planMode: Bool?
  /// True after the shell pane's shell exited or the user closed the pane.
  /// sbd then starts no shell for the session until the user opens one.
  public var shellClosed: Bool?
  /// Set by `sb issue`. It replaces the issues that sbd finds in the PR body
  /// and the branch name.
  public var issue: IssueRef?
  /// The name of the remote host that the session runs on, as config.json lists it. Nil means this Mac.
  public var host: String?
  /// The MCP servers that a Manager conversation loads besides switchboard,
  /// by name. Nil launches claude with the full setup, as for every other
  /// session. An empty list loads only switchboard.
  public var mcp: [String]?
  /// True once sbd gave a Manager conversation its first `mcp` list. A
  /// conversation that the user later set to the full setup keeps nil.
  public var mcpScoped: Bool?

  public var kind: SessionKind { SessionKind(manager: manager, chat: chat) }

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

/// What a session is for. Only a work session belongs to a group, gets a
/// triage item, or has a worktree and a PR.
public enum SessionKind: String, Codable, Sendable {
  case work
  case manager
  case chat

  public init(manager: Bool?, chat: String?) {
    self = manager == true ? .manager : chat != nil ? .chat : .work
  }

  /// Whether the app shows a session of this kind as a chat. `chat-log`
  /// reads only these kinds, because a work session's transcript can hold
  /// what its user never meant to show in the chat pane.
  public var showsAsChat: Bool {
    switch self {
    case .work: false
    case .manager, .chat: true
    }
  }

  /// How a message names a session of this kind, or nil for a work session.
  public var label: String? {
    switch self {
    case .work: nil
    case .manager: "the Manager"
    case .chat: "a group chat"
    }
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

  /// The number of events that the `events` request lists when it names no `limit`.
  public static let defaultLimit = 200

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
  /// The folder that `new` made the worktree from. Only a session with one
  /// can remove its worktree.
  public var repo: String?
  /// The main checkout of the git repo that holds `cwd`, with symlinks
  /// resolved, or nil when `cwd` is in no git repo. Unlike `repo`, it does
  /// not mean that sbd made the worktree.
  public var checkout: String?
  /// The owner/name that the `origin` remote of `checkout` names on GitHub,
  /// or nil when that remote is missing or isn't on GitHub. An sbd that
  /// predates it sends nil.
  public var repository: String?
  /// True once sbd has read `checkout` and its origin remote. While it is
  /// nil, a nil `repository` means sbd hasn't looked yet, not that the
  /// folder has no GitHub remote.
  public var repositoryRead: Bool?
  /// The folder that names the session's repo. An sbd that predates
  /// `checkout` sends only `repo`.
  public var repoFolder: String? { checkout ?? repo }
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
  /// True for a Manager conversation.
  public var manager: Bool?
  /// A Manager conversation's MCP servers besides switchboard, or nil for the full setup.
  public var mcp: [String]?
  /// The field to read for what the session is. `manager` and `chat` stay
  /// in the JSON for the tools that read them.
  public var kind: SessionKind = .work
  /// The id of the group whose chat this session is.
  public var chat: String?
  public var followup: Followup?
  /// When the session was added, in ms since the epoch. An imported
  /// follow-up was added on the date of its line.
  public var created: Int64?
  public var pr: PRSummary?
  /// True when `sb done` or the app marked the session done. A merged or
  /// closed PR can put a session in Done without it.
  public var markedDone: Bool
  /// What the session needs from the user, or nil when it needs nothing.
  public var triage: TriageItem?
  /// The decisions that the user started to answer, or nil when no list is open.
  public var decisions: DecisionList?
  /// True when sbd sent the answers to the item's decisions and the item
  /// waits for the session's next prompt to replace it.
  public var decisionsSent: Bool?
  /// Whether the last decisions submit reached the session, or nil before any submit.
  public var decisionsDelivery: DecisionsDelivery?
  /// The Claude account's folder, or nil when the session never recorded one.
  public var account: String?
  /// Whether `sb cleanup` can remove the worktree of a finished PR, or did.
  public var cleanup: CleanupStatus?
  /// The id of the session's group, or nil for Ungrouped.
  public var group: String?
  /// The name and description of the session's group.
  public var groupName: String?
  public var groupDescription: String?
  /// The PRs that the session's open PR waits on, or nil when it waits on none.
  public var dependencies: [Dependency]?
  /// The plans attached to the session and to its group, or nil when there are none.
  public var plans: [PlanSummary]?
  /// The review that a docket row tracks, or nil for any other session.
  public var docket: DocketSummary?
  /// gh's error from the last failed merge of the PR's head commit.
  public var mergeError: String?
  /// True when the user acknowledged the session's Inbox item, which moves
  /// it to Waiting until its reason changes or a new turn starts.
  public var acknowledged: Bool?
  /// True while the session's start of claude waits behind the live cap.
  public var queued: Bool?
  /// Claude Code's permission mode, such as `default` or `auto`, or nil when
  /// no hook has reported it since claude started.
  public var permissionMode: String?
  /// True when the session has no shell pane, because its shell exited or
  /// the user closed it.
  public var shellClosed: Bool?
  /// The session's place on the board. Nil for the Manager, a group chat,
  /// and a docket row.
  public var board: BoardPlacement?
  /// The GitHub issues that the session works on, first the one the tile
  /// shows. nil when no source names one, for every session that has no
  /// `board`, and for a follow-up that hasn't started.
  public var issues: [SessionIssue]?
  /// The remote host that the session runs on, or nil for this Mac.
  public var host: String?
  /// The state of the host's link, or nil for a session on this Mac and for a host that has no link.
  public var link: LinkState?

  public init(
    id: String, name: String, cwd: String, repo: String?, branch: String?, claudeSessionId: String,
    state: AttentionState, reason: String, since: Int64, lastActivity: Int64, live: Bool,
    claudePid: Int?, attached: Bool, lastReply: String?, waits: [Wait], notes: [Note], cards: [Card] = [],
    openPrompt: Bool = false, pr: PRSummary? = nil, markedDone: Bool = false
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
    self.pr = pr
    self.markedDone = markedDone
  }
}

/// The tmux targets of a session's two terminals.
public struct Terminals: Codable, Equatable, Sendable {
  public var tmux: String
  public var socket: String
  public var claude: String
  public var shell: String
  /// The remote host that holds the tmux server and its socket. Nil means this Mac.
  public var host: String?

  public init(tmux: String, socket: String, claude: String, shell: String, host: String? = nil) {
    self.tmux = tmux
    self.socket = socket
    self.claude = claude
    self.shell = shell
    self.host = host
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

/// The parts joined as an English list: "a", "a and b", or "a, b, and c".
public func englishList(_ parts: [String]) -> String {
  switch parts.count {
  case 0, 1: parts.joined()
  case 2: parts.joined(separator: " and ")
  default: parts.dropLast().joined(separator: ", ") + ", and " + parts.last!
  }
}

private let timestamp = ISO8601DateFormatter()

/// Writes a timestamped line to stderr, which launchd sends to sbd.log.
public func logLine(_ message: String) {
  FileHandle.standardError.write(Data("\(timestamp.string(from: Date())) \(message)\n".utf8))
}

public enum Version {
  public static let text = "0.1.0"
}
