import Foundation

/// A Claude account is a Claude config folder. The account picks the
/// subscription, the settings, and the MCP servers. Claude's default account
/// is ~/.claude. It runs with CLAUDE_CONFIG_DIR unset. With
/// CLAUDE_CONFIG_DIR=~/.claude, claude reads ~/.claude/.claude.json instead of
/// ~/.claude.json, so that is a different account.
public enum ClaudeAccount {
  public static var defaultFolder: String { normalize("~/.claude") }

  public static func normalize(_ folder: String) -> String {
    (folder.expandingTilde as NSString).standardizingPath
  }

  public static func isDefault(_ folder: String) -> Bool { normalize(folder) == defaultFolder }

  /// Whether a Claude account lives in the folder. The default account keeps
  /// its .claude.json in the home folder. Every other account keeps it in its
  /// own folder.
  public static func holdsAccount(_ folder: String) -> Bool {
    isDefault(folder) || FileManager.default.fileExists(atPath: configFile(folder))
  }

  /// The account's .claude.json, which holds its login. The default account
  /// keeps it in the home folder.
  public static func configFile(_ folder: String) -> String {
    isDefault(folder) ? "~/.claude.json".expandingTilde : "\(normalize(folder))/.claude.json"
  }

  /// Sets CLAUDE_CONFIG_DIR to the folder, or removes it for the default account.
  public static func apply(_ folder: String, to env: inout [String: String]) {
    env["CLAUDE_CONFIG_DIR"] = isDefault(folder) ? nil : normalize(folder)
  }

  /// A command line that runs `command` under the account, for the user to copy.
  public static func command(_ command: String, in folder: String) -> String {
    isDefault(folder) ? command : "CLAUDE_CONFIG_DIR=\(shellQuote(normalize(folder))) \(command)"
  }

  /// A short name for the account: "default" for ~/.claude, else the folder
  /// name without its ".claude-" prefix.
  public static func name(_ folder: String) -> String {
    let last = (normalize(folder) as NSString).lastPathComponent
    if isDefault(folder) { return "default" }
    return last.hasPrefix(".claude-") ? String(last.dropFirst(".claude-".count)) : last
  }

  /// The account folder that `ref` names: a short name from `name`, or a
  /// folder. Throws when no known account matches, or when the folder holds no
  /// account.
  public static func resolve(_ ref: String, among known: [String]) throws -> String {
    if let match = known.first(where: { name($0) == ref }) { return normalize(match) }
    let folder = normalize(ref)
    guard holdsAccount(folder) else {
      let names = known.map(name).joined(separator: ", ")
      throw APIError("\(ref) is no Claude account (no .claude.json in \(folder)). Known accounts: \(names)")
    }
    return folder
  }

  /// The default account, then each ~/.claude-* folder that holds a .claude.json, by name.
  public static func discover(home: String = NSHomeDirectory()) -> [String] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: home)) ?? []
    let others = names.filter { $0.hasPrefix(".claude-") }.sorted().map { "\(home)/\($0)" }.filter(holdsAccount)
    return (["\(home)/.claude"] + others).map(normalize)
  }
}

/// A Claude session that runs outside Switchboard, from `claude agents --json`.
/// Switchboard can import it.
public struct ClaudeSession: Codable, Equatable, Sendable, Identifiable {
  /// Claude's session id, which names the conversation's transcript.
  public var id: String
  public var name: String?
  public var cwd: String
  /// The account's Claude config folder.
  public var account: String
  /// idle, busy, or waiting, while a claude runs the session.
  public var status: String?
  /// A background session's job id, for `claude stop` and `claude attach`.
  public var job: String?
  /// The claude that runs the session, or nil when none does.
  public var pid: Int?
  /// When `claude agents` last listed the session, in ms since the epoch.
  public var seen: Int64
  /// The folder name of the repo's main checkout, or nil outside git. sbd sets
  /// `repo`, `branch`, and `worktree` with git after `claude agents` lists the
  /// session. They are nil and false until then.
  public var repo: String?
  public var branch: String?
  /// True when the folder is a linked worktree of its repo.
  public var worktree: Bool
  /// The pids of the claudes that other accounts list for the session. Nil
  /// when no other account lists one.
  public var otherPids: [Int]?

  public init(
    id: String, name: String? = nil, cwd: String, account: String, status: String? = nil, job: String? = nil,
    pid: Int? = nil, seen: Int64 = 0, repo: String? = nil, branch: String? = nil, worktree: Bool = false,
    otherPids: [Int]? = nil
  ) {
    self.id = id
    self.name = name
    self.cwd = cwd
    self.account = account
    self.status = status
    self.job = job
    self.pid = pid
    self.seen = seen
    self.repo = repo
    self.branch = branch
    self.worktree = worktree
    self.otherPids = otherPids
  }

  public var running: Bool { pid != nil }

  /// The pid of every claude that runs the session.
  public var livePids: [Int] { (pid.map { [$0] } ?? []) + (otherPids ?? []) }

  /// True when the rows of two accounts list the session with different pids.
  public var runsInSeveralClaudes: Bool { otherPids != nil }

  /// True when one interactive claude runs the session and waits at its
  /// prompt. Exiting that claude loses no turn, unless one starts after the
  /// listing that read this status. A session that several claudes run is not
  /// stoppable, because import would have to exit each of them, and one can
  /// outlast the signal.
  public var stoppable: Bool { pid != nil && job == nil && status == "idle" && !runsInSeveralClaudes }

  /// Which of two rows for one session to keep: 2 for a claude that runs and
  /// can't be stopped, 1 for one that can be, 0 when none runs.
  public var keepRank: Int { running ? (stoppable ? 1 : 2) : 0 }

  /// The lowest pid of a claude that runs both sessions, or nil when none does.
  public func sharedPid(with other: ClaudeSession) -> Int? { Set(livePids).intersection(other.livePids).min() }

  /// True when no claude runs the session, or when `import --stop` can exit it.
  public var importable: Bool { !running || stoppable }

  /// The name that the session gets on import: its branch in a worktree, else
  /// Claude's name, else its folder's name.
  public var title: String { (worktree ? branch : nil) ?? name ?? (cwd as NSString).lastPathComponent }

  /// The id's first 8 characters, which tell apart two sessions with one title.
  public var idPrefix: String { String(id.prefix(8)) }

  /// Claude's name for the session, else its id's first 8 characters.
  public var label: String { name ?? idPrefix }

  /// Whether a claude runs the session, and where, in a few words.
  public var summary: String {
    switch (running, job) {
    case (true, let job?): "background job \(job), \(status ?? "running")"
    case (true, nil): runsInSeveralClaudes ? "in several claudes" : "\(status ?? "running") in another terminal"
    case (false, let job?): "background job \(job), stopped"
    case (false, nil): "exited"
    }
  }

  /// A sentence that starts with `label` and says where a claude runs the
  /// session and how to end that claude before an import. It is nil when no
  /// claude runs the session.
  public func whereItRuns(_ label: String) -> String? {
    guard let pid else { return nil }
    guard let job else {
      if runsInSeveralClaudes {
        let pids = livePids.map(String.init).joined(separator: ", ")
        return "\(label) runs in several claudes, in \(cwd) (pids \(pids)). Exit claude in each, then import it."
      }
      let stop = stoppable ? " Or import it with --stop to exit that claude." : ""
      return "\(label) runs in another terminal, in \(cwd) (pid \(pid)). Exit claude there, then import it.\(stop)"
    }
    let stop = ClaudeAccount.command("claude stop \(job)", in: account)
    return "\(label) runs as background job \(job). Stop it with `\(stop)`, then import it."
  }

  /// Marks the session as one that no claude runs.
  public mutating func clearProcess() {
    pid = nil
    status = nil
    otherPids = nil
  }

  /// The rows of `claude agents --json` for one account.
  public static func list(fromAgents text: String, account: String, seen: Int64) throws -> [ClaudeSession] {
    guard let rows = JSON.parse(text)?.array else {
      throw APIError("claude agents printed no list of sessions for \(account): \(oneLine(text, max: 200))")
    }
    return rows.compactMap { row in
      guard let id = row["sessionId"]?.string, let cwd = row["cwd"]?.string else { return nil }
      var session = ClaudeSession(
        id: id, name: row["name"]?.string, cwd: cwd, account: account, status: row["status"]?.string,
        job: row["id"]?.string, pid: row["pid"]?.int, seen: seen)
      // A pid that can't name a process means no claude runs the session.
      if let pid = session.pid, !Processes.isValidPid(pid) { session.clearProcess() }
      return session
    }
  }

  /// The order of the import list: by repo, with folders outside git last,
  /// then by branch or name.
  public static func importOrder(_ a: ClaudeSession, _ b: ClaudeSession) -> Bool {
    func key(_ s: ClaudeSession) -> [String] {
      [s.repo == nil ? "1" : "0", s.repo ?? "", s.branch ?? s.name ?? s.cwd, s.id].map { $0.lowercased() }
    }
    return key(a).lexicographicallyPrecedes(key(b))
  }
}

/// What the end of a Claude transcript says about the conversation.
public struct TranscriptTail: Equatable, Sendable {
  /// The text of the main conversation's last assistant message that has text.
  public var lastReply: String?
  /// The timestamp of the last line that has one, in ms since the epoch.
  public var lastActivity: Int64?
  /// True when the main conversation has an assistant message.
  public var hasReplies: Bool

  public init(lastReply: String? = nil, lastActivity: Int64? = nil, hasReplies: Bool = false) {
    self.lastReply = lastReply
    self.lastActivity = lastActivity
    self.hasReplies = hasReplies
  }
}

/// The names of the folders in <account>/projects. Claude doesn't document
/// the rule. This copy comes from claude 2.1.322. Its tests use folder names
/// that claude created.
public enum ClaudeFolder {
  private static let maxLength = 200

  /// The folder that Claude names after `path`. Claude counts UTF-16 units,
  /// because it runs in JavaScript. It replaces each unit other than an ASCII
  /// letter or digit with "-". It cuts a longer name to 200 units and appends
  /// "-" and a hash of the whole path.
  public static func name(_ path: String) -> String {
    let units = Array(path.utf16)
    let dash = UInt16(UInt8(ascii: "-"))
    let name = String(decoding: units.map { isLetterOrDigit($0) ? $0 : dash }.prefix(maxLength), as: UTF16.self)
    guard units.count > maxLength else { return name }
    return "\(name)-\(String(javaHash(units).magnitude, radix: 36))"
  }

  private static func isLetterOrDigit(_ unit: UInt16) -> Bool {
    (0x30...0x39).contains(unit) || (0x41...0x5A).contains(unit) || (0x61...0x7A).contains(unit)
  }

  /// Java's String.hashCode, with 32-bit wrapping.
  private static func javaHash(_ units: [UInt16]) -> Int32 {
    units.reduce(Int32(0)) { $0 &* 31 &+ Int32($1) }
  }
}

public enum Transcript {
  /// The transcript of a session: <account>/projects/<folder>/<id>.jsonl.
  /// Claude names the folder after the session's cwd, as `ClaudeFolder.name`
  /// does. A symlink can change the cwd. So when that folder lacks the
  /// transcript, this looks in every folder in <account>/projects.
  /// The account, the cwd, and the transcript are on `machine`.
  public static func find(
    _ sessionId: String, account: String, cwd: String, on machine: any Machine
  ) -> String? {
    find(sessionId, account: account, cwd: cwd, on: machine, folders: machine.list)
  }

  /// As `find` above, but when the cwd's folder lacks the transcript, this
  /// looks in the folders that `folders` names. `folders` gets the path of
  /// <account>/projects and returns folder names, not paths. It runs only
  /// when the cwd's folder lacks the transcript.
  public static func find(
    _ sessionId: String, account: String, cwd: String, on machine: any Machine,
    folders: (String) -> [String]
  ) -> String? {
    let projects = "\(account)/projects"
    let named = "\(projects)/\(ClaudeFolder.name(cwd))/\(sessionId).jsonl"
    if machine.exists(named) { return named }
    return folders(projects).map { "\(projects)/\($0)/\(sessionId).jsonl" }.first(
      where: machine.exists)
  }

  /// Reads the transcript from the end, because transcripts reach 24 MB.
  public static func tail(_ path: String, on machine: any Machine) -> TranscriptTail {
    var tail = TranscriptTail()
    eachLineFromEnd(path, on: machine) { fold($0, into: &tail) }
    return tail
  }

  /// The main conversation's last `limit` messages that have text, oldest first.
  public static func messages(_ path: String, limit: Int, on machine: any Machine) -> [ChatMessage] {
    var messages: [ChatMessage] = []
    eachLineFromEnd(path, on: machine) { line in
      if let message = message(line) { messages.append(message) }
      return messages.count >= limit
    }
    return messages.reversed()
  }

  /// Whether a user message of the main conversation that holds `text` starts
  /// at byte `offset` or later. It is false when the file is shorter than
  /// `offset`, because then it is not the file that `offset` measured.
  public static func hasUserMessage(
    _ path: String, holding text: String, from offset: UInt64, on machine: any Machine
  ) -> Bool {
    guard let data = machine.read(path, from: offset, count: nil) else { return false }
    let wanted = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return data.split(separator: UInt8(ascii: "\n")).contains {
      guard let m = message(Data($0)), m.role == .user else { return false }
      return m.text.contains(wanted)
    }
  }

  /// Calls `body` with each non-empty line, last line first, until it returns
  /// true. Each read is twice the size of the one before, up to 4 MB, so a
  /// long line costs few reads.
  static func eachLineFromEnd(_ path: String, on machine: any Machine, _ body: (Data) -> Bool) {
    guard var offset = machine.size(path) else { return }
    var size: UInt64 = 1 << 16
    // The start of the chunk after the current one, up to its first newline.
    // It ends a line that starts in the current chunk. It is empty when that
    // chunk starts with a newline, which ends the current chunk's last line.
    var rest = Data()
    while offset > 0 {
      let count = min(size, offset)
      offset -= count
      size = min(size * 2, 1 << 22)
      guard let chunk = machine.read(path, from: offset, count: Int(count)) else { return }
      var lines = (chunk + rest).split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
      rest = offset > 0 ? Data(lines.removeFirst()) : Data()
      for line in lines.reversed() where !line.isEmpty {
        if body(Data(line)) { return }
      }
    }
  }

  /// Folds one line into the tail, and returns true at the last reply. The
  /// main conversation's replies are the assistant lines that are not
  /// sidechains, which hold subagents. An api-request-blob line also carries
  /// an assistant message, and its type leaves it out.
  static func fold(_ line: Data, into tail: inout TranscriptTail) -> Bool {
    guard let object = try? JSONCoding.decoder.decode(JSON.self, from: line) else { return false }
    if tail.lastActivity == nil, let t = object["timestamp"]?.string.flatMap(milliseconds) { tail.lastActivity = t }
    guard object["type"]?.string == "assistant", object["isSidechain"]?.bool != true else { return false }
    tail.hasReplies = true
    let text = text(of: object)
    guard !text.isEmpty else { return false }
    tail.lastReply = text
    return true
  }

  /// A user or assistant line of the main conversation that has text. A
  /// user line that holds only tool results has none. A meta line is one
  /// that claude adds, such as a command's output. Claude Code writes the
  /// summary of a compacted conversation as a user line that only its
  /// transcript view shows.
  static func message(_ line: Data) -> ChatMessage? {
    guard let object = try? JSONCoding.decoder.decode(JSON.self, from: line),
      let role = object["type"]?.string.flatMap(ChatMessage.Role.init(rawValue:)),
      object["isSidechain"]?.bool != true, object["isMeta"]?.bool != true,
      object["isCompactSummary"]?.bool != true, object["isVisibleInTranscriptOnly"]?.bool != true
    else { return nil }
    let text = text(of: object)
    guard !text.isEmpty else { return nil }
    return ChatMessage(role: role, text: text, t: object["timestamp"]?.string.flatMap(milliseconds))
  }

  /// The text of a line's message: its string content, or its text blocks.
  private static func text(of object: JSON) -> String {
    let content = object["message"]?["content"]
    let texts =
      content?.string.map { [$0] }
      ?? (content?.array ?? []).filter { $0["type"]?.string == "text" }.compactMap { $0["text"]?.string }
    return texts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static let fractional: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
  }()
  private static let whole = ISO8601DateFormatter()

  /// The time in ms of an ISO 8601 timestamp, with or without fractional seconds.
  public static func milliseconds(_ timestamp: String) -> Int64? {
    (fractional.date(from: timestamp) ?? whole.date(from: timestamp)).map {
      Int64(($0.timeIntervalSince1970 * 1000).rounded())
    }
  }
}
