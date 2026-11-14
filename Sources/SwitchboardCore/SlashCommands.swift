import Foundation

/// A command that the user can type after `/` in a session's claude.
public struct SlashCommand: Codable, Equatable, Sendable {
  public enum Source: String, Codable, Sendable {
    /// The transcript's latest skill listing, which lists what the model may call.
    case listing
    /// A skill or command file in the account's or the cwd's folders.
    case scan
    case builtIn
  }

  public let name: String
  public let description: String?
  public let source: Source

  public init(name: String, description: String?, source: Source) {
    self.name = name
    self.description = description
    self.source = source
  }

  /// Claude Code's own commands that the listing never carries. The bundled
  /// skills, such as `init` and `code-review`, are in the listing.
  public static let builtIns: [SlashCommand] = [
    ("add-dir", "Add a working folder to the session"),
    ("agents", "Create or manage subagents"),
    ("clear", "Start a new conversation with empty context"),
    ("compact", "Summarize the conversation to free up context"),
    ("config", "Open Claude Code's settings"),
    ("context", "Show how much of the context window is in use"),
    ("doctor", "Check the Claude Code installation and settings"),
    ("export", "Export the conversation as plain text"),
    ("help", "Show help and the available commands"),
    ("hooks", "Show the hook configuration"),
    ("mcp", "Manage the MCP server connections"),
    ("memory", "Edit CLAUDE.md files and auto memory"),
    ("model", "Switch the model"),
    ("permissions", "Manage the tool permission rules"),
    ("resume", "Resume another conversation"),
    ("rewind", "Rewind the conversation or the code to an earlier point"),
    ("status", "Show the version, model, account, and connectivity"),
    ("usage", "Show the plan's usage limits and the session's cost"),
  ].map { SlashCommand(name: $0.0, description: $0.1, source: .builtIn) }
}

/// Reads the `skill_listing` attachments that claude writes to its
/// transcript: an initial listing at each launch, then deltas that add skills
/// or change their descriptions.
public enum SkillListing {
  /// The folded listing of one transcript, and the byte just past the last
  /// line that the fold read.
  public struct State: Equatable, Sendable {
    /// Nil when the transcript holds no listing.
    public var commands: [SlashCommand]?
    public var offset: UInt64 = 0

    public init() {}
  }

  private static let marker = Data(#""skill_listing""#.utf8)
  private static let newline = UInt8(ascii: "\n")

  /// The listing's items, one per entry of `names`, in that order. A name's
  /// item is the first line that is `- <name>` followed by the end of the
  /// line, ":", ": ", or " (". So the item of a plugin skill such as
  /// `a:b` is not taken for the item of `a`. An item's description is the
  /// text after the name, its optional plugin in parentheses, and ": ", on
  /// the item's first line only.
  public static func items(_ attachment: JSON) -> [SlashCommand] {
    let lines = (attachment["content"]?.string ?? "").components(separatedBy: "\n")
    return (attachment["names"]?.array ?? []).compactMap(\.string).map { name in
      let head = "- \(name)"
      let line = lines.first { line in
        guard line.hasPrefix(head) else { return false }
        let rest = line.dropFirst(head.count)
        return rest.isEmpty || rest == ":" || rest.hasPrefix(": ") || rest.hasPrefix(" (")
      }
      return SlashCommand(
        name: name, description: line.flatMap { description($0.dropFirst(head.count)) }, source: .listing)
    }
  }

  private static func description(_ afterName: Substring) -> String? {
    var rest = afterName
    if rest.hasPrefix(" ("), let close = rest.firstIndex(of: ")") { rest = rest[rest.index(after: close)...] }
    guard rest.hasPrefix(": ") else { return nil }
    let text = rest.dropFirst(2).trimmingCharacters(in: .whitespaces)
    return text.isEmpty ? nil : text
  }

  /// Folds the transcript's listings into `state`. Without `offset`, it starts
  /// over and reads back from the end to the last initial listing. With
  /// `offset`, it folds the lines after it into `state`, and starts over when
  /// the file is shorter than `offset`. It folds only lines that end in a new
  /// line, because claude can be writing the last one.
  ///
  /// It returns false when a read of the machine failed. A failed read of
  /// the lines after `offset` leaves `state` as it was. A failed size, or a
  /// failed read back from the end, leaves no listing at offset 0. The caller
  /// must not keep the state of a failed read for a later read from its offset.
  public static func read(
    _ path: String, from offset: UInt64? = nil, into state: inout State, on machine: any Machine
  ) -> Bool {
    guard let size = machine.size(path) else {
      state = State()
      return false
    }
    if let offset, offset <= size {
      return readForward(path, from: offset, to: size, into: &state, on: machine)
    }
    guard let read = readFromEnd(path, size: size, on: machine) else {
      state = State()
      return false
    }
    state = read
    return true
  }

  /// Nil when a read of the machine failed.
  private static func readFromEnd(_ path: String, size: UInt64, on machine: any Machine) -> State? {
    var state = State()
    guard size > 0 else { return state }
    guard let last = machine.read(path, from: size - 1, count: 1) else { return nil }
    var partial = last.first != newline
    var end = size
    var found: [JSON] = []
    let complete = Transcript.eachLineFromEnd(path, before: size, on: machine) { line in
      if partial {
        partial = false
        end = size - UInt64(line.count)
        return false
      }
      guard let attachment = listing(line) else { return false }
      found.append(attachment)
      return isInitial(attachment)
    }
    guard complete else { return nil }
    for attachment in found.reversed() { apply(attachment, to: &state.commands) }
    state.offset = end
    return state
  }

  /// False when the read of the machine failed.
  private static func readForward(
    _ path: String, from offset: UInt64, to size: UInt64, into state: inout State, on machine: any Machine
  ) -> Bool {
    guard size > offset else { return true }
    guard let data = machine.read(path, from: offset, count: Int(size - offset)) else { return false }
    guard let last = data.lastIndex(of: newline) else { return true }
    for line in data[..<last].split(separator: newline) {
      if let attachment = listing(Data(line)) { apply(attachment, to: &state.commands) }
    }
    state.offset = offset + UInt64(data.distance(from: data.startIndex, to: last) + 1)
    return true
  }

  /// The attachment of a listing line of the main conversation. Subagents
  /// write sidechain lines.
  private static func listing(_ line: Data) -> JSON? {
    guard line.range(of: marker) != nil, let object = try? JSONCoding.decoder.decode(JSON.self, from: line),
      object["type"]?.string == "attachment", object["isSidechain"]?.bool != true,
      let attachment = object["attachment"], attachment["type"]?.string == "skill_listing"
    else { return nil }
    return attachment
  }

  private static func isInitial(_ attachment: JSON) -> Bool { attachment["isInitial"]?.bool == true }

  /// An initial listing replaces the set. A delta upserts its items by name.
  private static func apply(_ attachment: JSON, to commands: inout [SlashCommand]?) {
    var current = isInitial(attachment) ? [] : commands ?? []
    for item in items(attachment) {
      if let i = current.firstIndex(where: { $0.name == item.name }) {
        current[i] = item
      } else {
        current.append(item)
      }
    }
    commands = current
  }
}

/// A skill or a legacy command file, read from its frontmatter.
public struct ScannedSkill: Equatable, Sendable {
  public let name: String
  public let description: String?
  /// False when the frontmatter says `user-invocable: false`.
  public let userInvocable: Bool
  /// False when the frontmatter says `disable-model-invocation: true`.
  public let modelInvocable: Bool
}

/// Reads the skill and command folders that Claude Code loads for a session.
public enum SkillFolders {
  /// The skills in `<folder>/skills/*/SKILL.md` and the commands in
  /// `<folder>/commands/*.md` of the account and of `<cwd>/.claude`, in the
  /// order in which Claude Code picks among entries of one name: a skill
  /// before a command, and the account's before the cwd's. A nil account
  /// scans only the cwd.
  public static func scan(account: String?, cwd: String, on machine: any Machine) -> [ScannedSkill] {
    let folders = [account, "\(cwd)/.claude"].compactMap { $0 }
    let skills = folders.flatMap { folder in
      machine.list("\(folder)/skills").sorted().compactMap { name in
        head("\(folder)/skills/\(name)/SKILL.md", on: machine).map { skill($0, named: name) }
      }
    }
    let commands = folders.flatMap { folder in
      machine.list("\(folder)/commands").filter { $0.hasSuffix(".md") }.sorted().compactMap { file in
        head("\(folder)/commands/\(file)", on: machine).map {
          skill($0, named: String(file.dropLast(3)), isCommand: true)
        }
      }
    }
    return (skills + commands).filter { !$0.name.isEmpty }
  }

  /// The frontmatter and the first body line fit well inside this many bytes.
  private static let maxFileBytes = 64 << 10

  /// The start of the file. A repo can commit a skill as a symlink to a
  /// device such as /dev/zero, which never reaches its end.
  private static func head(_ path: String, on machine: any Machine) -> String? {
    machine.read(path, from: 0, count: maxFileBytes).map { String(decoding: $0, as: UTF8.self) }
  }

  /// The `skillOverrides` of the account's settings.json, from skill name to
  /// a state such as "off". A nil account has none.
  public static func overrides(account: String?, on machine: any Machine) -> [String: String] {
    guard let account, let text = machine.text("\(account)/settings.json"),
      let overrides = JSON.parse(text)?["skillOverrides"]?.object
    else { return [:] }
    return overrides.compactMapValues(\.string)
  }

  /// A file has frontmatter only when its first line is `---`. The
  /// frontmatter ends at the next `---` line. Its `name` replaces `fallback`
  /// for a skill. A command is always named after its file, as in Claude Code.
  static func skill(_ text: String, named fallback: String, isCommand: Bool = false) -> ScannedSkill {
    let lines = text.replacingOccurrences(of: "\r\n", with: "\n").trimmingPrefix("\u{FEFF}")
      .components(separatedBy: "\n")
    var scalars: [String: String] = [:]
    var body = lines[...]
    if lines.first == "---", let close = lines.dropFirst().firstIndex(of: "---") {
      scalars = YAMLScalars.read(lines[1..<close].joined(separator: "\n"))
      body = lines[(close + 1)...]
    }
    func trimmed(_ text: Substring?) -> String? {
      text.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
    }
    let name = isCommand ? nil : trimmed(scalars["name"]?[...])
    let described = trimmed(scalars["description"]?.split(separator: "\n").first)
    return ScannedSkill(
      name: name ?? fallback,
      description: described ?? body.lazy.compactMap { trimmed($0[...]) }.first,
      userInvocable: scalars["user-invocable"]?.lowercased() != "false",
      modelInvocable: scalars["disable-model-invocation"]?.lowercased() != "true")
  }
}

public enum SlashCommands {
  /// The rows that the user can type. With a listing: its items, less those
  /// whose file says `user-invocable: false`, plus the scanned entries that
  /// the listing leaves out because the model can't call them. Without one:
  /// every scanned entry that the user can call. Then the built-ins whose
  /// names are still free. A name that `skillOverrides` turns off is left
  /// out. Among scanned entries of one name, the first one in scan order
  /// decides.
  public static func merge(
    listing: [SlashCommand]?, scanned: [ScannedSkill], overrides: [String: String]
  ) -> [SlashCommand] {
    var files: [String: ScannedSkill] = [:]
    var winners: [ScannedSkill] = []
    for skill in scanned where files[skill.name] == nil {
      files[skill.name] = skill
      winners.append(skill)
    }
    let typeable = winners.filter(\.userInvocable)

    var rows: [SlashCommand] = []
    var taken: Set<String> = []
    func add(_ command: SlashCommand) {
      guard overrides[command.name] != "off", taken.insert(command.name).inserted else { return }
      rows.append(command)
    }
    func row(_ skill: ScannedSkill) -> SlashCommand {
      SlashCommand(name: skill.name, description: skill.description, source: .scan)
    }

    if let listing {
      for item in listing where files[item.name]?.userInvocable != false {
        add(
          SlashCommand(
            name: item.name, description: item.description ?? files[item.name]?.description, source: .listing))
      }
      // The override "user-invocable-only" hides a skill from the listing and keeps it in the `/` menu.
      for skill in typeable where !skill.modelInvocable || overrides[skill.name] == "user-invocable-only" {
        add(row(skill))
      }
    } else {
      typeable.forEach { add(row($0)) }
    }
    SlashCommand.builtIns.forEach(add)
    return rows
  }

  private static let separators: Set<Character> = [":", "-", "_"]

  /// The commands whose names hold `query`, ignoring case: first the names
  /// that start with it, then those where a part after ":", "-", or "_"
  /// starts with it, then the rest. Each group sorts by name.
  public static func rank(_ commands: [SlashCommand], query: String) -> [SlashCommand] {
    let query = query.lowercased()
    func tier(_ name: String) -> Int? {
      let name = name.lowercased()
      if name.hasPrefix(query) { return 0 }
      if name.indices.contains(where: {
        separators.contains(name[$0]) && name[name.index(after: $0)...].hasPrefix(query)
      }) {
        return 1
      }
      return name.contains(query) ? 2 : nil
    }
    return commands.compactMap { c in tier(c.name).map { (c, $0) } }
      .sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0.name < $1.0.name }
      .map(\.0)
  }
}
