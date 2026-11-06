import Foundation

/// The folder that holds sbd's state, socket, terminals, and settings. It is
/// `path` when given, else $SB_HOME when set and not empty, else ~/.sb. A test
/// runs a private sbd by setting SB_HOME.
public struct Home: Sendable {
  public let path: String

  public init(path: String? = nil) {
    let env = ProcessInfo.processInfo.environment["SB_HOME"]
    self.path = (path ?? env.flatMap { $0.isEmpty ? nil : $0 } ?? "~/.sb").expandingTilde
  }

  public var socket: String { "\(path)/sbd.sock" }
  /// The file that the running sbd holds an exclusive lock on.
  public var lock: String { "\(path)/sbd.lock" }
  public var database: String { "\(path)/sb.db" }
  public var tmuxSocket: String { "\(path)/tmux.sock" }
  public var tmuxConfig: String { "\(path)/tmux.conf" }
  public var claudeSettings: String { "\(path)/claude-settings.json" }
  public var config: String { "\(path)/config.json" }
  /// The folder of the account that `sb account use` chose, or no file.
  public var activeAccount: String { "\(path)/account" }
  public var log: String { "\(path)/sbd.log" }
  /// Where the app saves the message fields' unsent text and images.
  public var drafts: String { "\(path)/drafts" }
  /// Holds `on` while `sb autocontinue on` is in force.
  public var autoContinue: String { "\(path)/auto-continue" }
  /// The --mcp-config file that every session gets, which lists the shared MCP servers.
  public var mcpConfig: String { "\(path)/mcp-config.json" }
  /// Where sbd writes each shared MCP server's launcher script.
  public var mcpFolder: String { "\(path)/mcp" }

  /// The folder that the Manager session runs in.
  public var managerFolder: String { "\(path)/manager" }

  /// Holds a folder per group chat.
  public var chatsFolder: String { "\(path)/chats" }
  /// The folder that a group's chat runs in.
  public func chatFolder(_ group: String) -> String { "\(chatsFolder)/\(group)" }

  /// Where sbd writes a session's launcher script.
  public func sessionFolder(_ id: String) -> String { "\(path)/sessions/\(id)" }
  /// Where sbd keeps copies of the images sent to a session. Removing the
  /// session removes its session folder, and these with it.
  public func attachmentsFolder(_ id: String) -> String { "\(sessionFolder(id))/attachments" }

  public func create() throws {
    try FileManager.default.createDirectory(
      atPath: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  }

  public func loadConfig() -> Config {
    guard let data = FileManager.default.contents(atPath: config) else { return Config() }
    do {
      return try JSONCoding.decoder.decode(Config.self, from: data)
    } catch {
      FileHandle.standardError.write(Data("sbd: ignoring \(config): \(error)\n".utf8))
      return Config()
    }
  }
}

/// Settings from $SB_HOME/config.json. Every field is optional there.
public struct Config: Codable, Equatable, Sendable {
  /// The claude command. A test points it at a stub.
  public var claude: String = "claude"
  /// How long a session sits idle after its turn ends before sbd stops claude.
  public var idleStopSeconds: Int = 900
  /// The most claude processes that may run at once, or nil for no limit.
  /// Further starts are held until a slot frees.
  public var liveCap: Int?
  /// How often sbd checks its processes and stops idle sessions.
  public var tickSeconds: Double = 1
  /// The model for new sessions, or nil for claude's default.
  public var model: String?
  /// Where `sb new --branch` creates worktrees: <root>/<repo>/<branch>.
  public var worktreeRoot: String = "~/dev/worktrees"
  /// The tmux binary, or nil to look on PATH, then in Homebrew's and the
  /// system's bin folders.
  public var tmux: String?
  /// The shell for both panes, or nil for the user's login shell.
  public var shell: String?
  /// Extra arguments for every claude command, such as --strict-mcp-config.
  /// A session in auto mode passes its --permission-mode after these, so it
  /// wins over one here.
  public var claudeArgs: [String] = []
  /// Whether new sessions start claude in auto mode. `sb new --no-auto` opts one out.
  public var autoMode = true
  /// Extra environment for both panes, such as CLAUDE_CONFIG_DIR.
  public var env: [String: String] = [:]
  /// Lets the `clock` request move sbd's clock forward. Only tests set it.
  public var testClock = false
  /// The MCP servers that sbd runs once and shares with every session, by
  /// the name that sessions see.
  public var mcpServers: [String: MCPServer] = [:]
  /// Local checkouts by `owner/name`, for repositories outside `repoRoots`.
  public var repos: [String: String] = [:]
  /// Folders that hold checkouts at <root>/<owner>/<name>.
  public var repoRoots: [String] = ["~/dev"]
  /// Goes before a branch name that `followup start` makes from a title.
  public var branchPrefix = ""
  /// The file that `followup import` reads when the request names none.
  public var followupsFile = "~/dev/haacked/notes/PostHog/Followups.md"
  /// Names of ignored files and folders that `sb cleanup` may delete besides
  /// build output, such as `.env` or `.notes`.
  public var cleanupDeletes: [String] = []
  /// The supacode command, which deletes a worktree that Supacode locked. A test points it at a stub.
  public var supacode = "supacode"
  /// The Claude config folders whose sessions `sb import` lists, or nil for
  /// `ClaudeAccount.discover()`. ~/.claude means Claude's default account.
  public var claudeConfigDirs: [String]?
  public var github = GitHubSettings()
  public var depot = DepotSettings()
  public var trunk = TrunkSettings()
  /// How many new events a session collects before sbd saves a snapshot of its
  /// state. 0 turns snapshots off, and sbd replays every event at start.
  public var snapshotEvery = 500
  public var triage = TriageSettings()
  public var autoContinue = AutoContinueSettings()
  public var usage = UsageSettings()
  public var docket = DocketSettings()
  public var planUpdates = PlanUpdateSettings()

  public init() {}

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let d = Config()
    claude = try c.decodeIfPresent(String.self, forKey: .claude) ?? d.claude
    idleStopSeconds = try c.decodeIfPresent(Int.self, forKey: .idleStopSeconds) ?? d.idleStopSeconds
    tickSeconds = try c.decodeIfPresent(Double.self, forKey: .tickSeconds) ?? d.tickSeconds
    // A value that isn't a whole number of at least 1 means no limit.
    if let n = try? c.decodeIfPresent(Double.self, forKey: .liveCap), n >= 1, n == n.rounded() { liveCap = Int(n) }
    model = try c.decodeIfPresent(String.self, forKey: .model)
    worktreeRoot = try c.decodeIfPresent(String.self, forKey: .worktreeRoot) ?? d.worktreeRoot
    tmux = try c.decodeIfPresent(String.self, forKey: .tmux)
    shell = try c.decodeIfPresent(String.self, forKey: .shell)
    claudeArgs = try c.decodeIfPresent([String].self, forKey: .claudeArgs) ?? d.claudeArgs
    autoMode = try c.decodeIfPresent(Bool.self, forKey: .autoMode) ?? d.autoMode
    env = try c.decodeIfPresent([String: String].self, forKey: .env) ?? d.env
    testClock = try c.decodeIfPresent(Bool.self, forKey: .testClock) ?? d.testClock
    // This skips a server that doesn't decode, such as a stdio one copied from
    // a Claude config. Throwing would make sbd ignore all of config.json.
    for (name, value) in try c.decodeIfPresent([String: JSON].self, forKey: .mcpServers) ?? [:] {
      do {
        mcpServers[name] = try JSONCoding.convert(value, to: MCPServer.self)
      } catch {
        logLine("skipping MCP server \(name): \(error)")
      }
    }
    repos = try c.decodeIfPresent([String: String].self, forKey: .repos) ?? d.repos
    repoRoots = try c.decodeIfPresent([String].self, forKey: .repoRoots) ?? d.repoRoots
    branchPrefix = try c.decodeIfPresent(String.self, forKey: .branchPrefix) ?? d.branchPrefix
    followupsFile = try c.decodeIfPresent(String.self, forKey: .followupsFile) ?? d.followupsFile
    cleanupDeletes = try c.decodeIfPresent([String].self, forKey: .cleanupDeletes) ?? d.cleanupDeletes
    supacode = try c.decodeIfPresent(String.self, forKey: .supacode) ?? d.supacode
    claudeConfigDirs = try c.decodeIfPresent([String].self, forKey: .claudeConfigDirs)
    github = try c.decodeIfPresent(GitHubSettings.self, forKey: .github) ?? d.github
    depot = try c.decodeIfPresent(DepotSettings.self, forKey: .depot) ?? d.depot
    trunk = try c.decodeIfPresent(TrunkSettings.self, forKey: .trunk) ?? d.trunk
    snapshotEvery = try c.decodeIfPresent(Int.self, forKey: .snapshotEvery) ?? d.snapshotEvery
    triage = try c.decodeIfPresent(TriageSettings.self, forKey: .triage) ?? d.triage
    autoContinue = try c.decodeIfPresent(AutoContinueSettings.self, forKey: .autoContinue) ?? d.autoContinue
    usage = try c.decodeIfPresent(UsageSettings.self, forKey: .usage) ?? d.usage
    docket = try c.decodeIfPresent(DocketSettings.self, forKey: .docket) ?? d.docket
    planUpdates = try c.decodeIfPresent(PlanUpdateSettings.self, forKey: .planUpdates) ?? d.planUpdates
  }
}

extension String {
  public var expandingTilde: String { (self as NSString).expandingTildeInPath }

  /// The repository as sbd should get it. sbd runs in another folder, so a
  /// path becomes absolute. An `owner/name` or a bare name stays as it is.
  public var repositoryArgument: String {
    ["/", "~", "."].contains(where: hasPrefix) ? URL(fileURLWithPath: expandingTilde).standardizedFileURL.path : self
  }
}

public func isDirectory(_ path: String) -> Bool {
  var isDir: ObjCBool = false
  return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
}
