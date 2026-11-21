import CryptoKit
import Foundation

/// What a skill does to a Manager conversation that loads it. A `work` skill belongs in a session of its own.
public enum SkillLabel: String, Codable, Sendable {
  case work
  case safe
}

/// The `managerSkills` settings in config.json.
public struct ManagerSkillSettings: Codable, Equatable, Sendable {
  /// The model that labels each skill.
  public var model = "haiku"
  /// How long one labeling run may take before sbd ends it. It is at most `maxTimeout`.
  public var timeoutSeconds = 30.0
  /// Names that are always `work`, whatever the classifier says.
  public var work: [String] = []
  /// Names that are always `safe`, whatever the classifier says.
  public var safe: [String] = []

  static let maxTimeout = 120.0

  public init() {}

  public init(from decoder: Decoder) throws {
    self.init(parsing: try JSON(from: decoder))
  }

  /// Reads the section and never fails. It logs a bad value and keeps that
  /// value's default. So a typo can't make sbd ignore all of config.json.
  public init(parsing json: JSON?) {
    guard let json, json != .null else { return }
    guard let fields = json.object else {
      logLine("skipping managerSkills: its value must be an object")
      return
    }
    if let value = fields["model"] {
      if let model = value.string, !model.isEmpty {
        self.model = model
      } else {
        logLine("skipping managerSkills.model: its value must be a model name")
      }
    }
    if let value = fields["timeoutSeconds"] {
      if let seconds = value.double, seconds > 0 {
        timeoutSeconds = min(seconds, Self.maxTimeout)
      } else {
        logLine("skipping managerSkills.timeoutSeconds: its value must be a number of seconds above 0")
      }
    }
    let work = Self.names(fields["work"], list: "work")
    let safe = Self.names(fields["safe"], list: "safe")
    let both = Set(work).intersection(safe)
    for name in both.sorted() {
      logLine("skipping \(name) in managerSkills: it is in both work and safe, so the classifier decides")
    }
    self.work = work.filter { !both.contains($0) }
    self.safe = safe.filter { !both.contains($0) }
  }

  /// The list's names without a leading `/`. It logs and skips a bad entry.
  private static func names(_ value: JSON?, list: String) -> [String] {
    guard let value, value != .null else { return [] }
    guard let entries = value.array else {
      logLine("skipping managerSkills.\(list): its value must be a list of skill names")
      return []
    }
    return entries.compactMap { entry in
      let name = entry.string.map { String($0.trimmingPrefix("/")) }
      guard let name, !name.isEmpty else {
        logLine("skipping \(entry.text) in managerSkills.\(list): an entry must be a skill name")
        return nil
      }
      return name
    }
  }

  /// The label that config.json forces on the name, or nil when it leaves the name to the classifier.
  public func override(_ name: String) -> SkillLabel? {
    if work.contains(name) { return .work }
    if safe.contains(name) { return .safe }
    return nil
  }
}

/// A skill or command that a Manager conversation can load, as discovery found it.
public struct CatalogEntry: Equatable, Sendable {
  public let name: String
  public let origin: ManagerSkillRow.Origin
  /// The file, or nil for a name that only the transcript's listing holds.
  public let path: String?
  public let description: String?
  /// The `SkillHash` of what discovery read. It is nil when nothing could be read, so nothing can be labeled.
  public let hash: String?

  /// The key of the entry's label in `SkillLabelCache`.
  public func key(model: String) -> String? { hash.map { SkillLabelCache.key(hash: $0, model: model) } }
}

/// Finds the skills and commands that Claude Code loads for an account and a cwd.
public enum SkillCatalog {
  /// The entries by name, in Claude Code's precedence: the account's and
  /// the cwd's skill and command files, then the skills and commands of
  /// each enabled plugin, then the listing's names that no file holds. The
  /// first entry of a name wins. A name that `skillOverrides` turns off is
  /// left out.
  public static func discover(account: String, cwd: String, listing: [SlashCommand]?, machine: any Machine)
    -> [String: CatalogEntry]
  {
    let overrides = SkillFolders.overrides(account: account, on: machine)
    var entries: [String: CatalogEntry] = [:]
    func add(_ entry: CatalogEntry) {
      guard overrides[entry.name] != "off", entries[entry.name] == nil else { return }
      entries[entry.name] = entry
    }
    func file(_ skill: ScannedSkill, origin: ManagerSkillRow.Origin) -> CatalogEntry {
      CatalogEntry(
        name: skill.name, origin: origin, path: skill.path, description: skill.description,
        hash: SkillHash.read(skill.path, on: machine)?.hash)
    }
    for skill in SkillFolders.scan(account: account, cwd: cwd, on: machine) {
      add(file(skill, origin: origin(skill.origin)))
    }
    for skill in pluginSkills(account: account, cwd: cwd, listing: listing, machine: machine) {
      add(file(skill, origin: .plugin))
    }
    for item in listing ?? [] {
      add(
        CatalogEntry(
          name: item.name, origin: .listing, path: nil, description: item.description,
          hash: item.description.map { SkillHash.listing(name: item.name, description: $0) }))
    }
    return entries
  }

  private static func origin(_ origin: ScannedSkill.Origin) -> ManagerSkillRow.Origin {
    switch origin {
    case .accountSkill: .user
    case .cwdSkill: .project
    case .accountCommand, .cwdCommand: .command
    }
  }

  /// The skills and then the commands of each enabled plugin that applies to the cwd, named `<plugin>:<name>`, in
  /// the order of `pluginFolders`.
  public static func pluginSkills(account: String, cwd: String, listing: [SlashCommand]?, machine: any Machine)
    -> [ScannedSkill]
  {
    pluginFolders(account: account, cwd: cwd, listing: listing, machine: machine).flatMap { plugin, folder in
      let found =
        SkillFolders.skills(in: folder, origin: .accountSkill, on: machine)
        + SkillFolders.commands(in: folder, origin: .accountCommand, on: machine)
      return found.map {
        ScannedSkill(
          name: "\(plugin):\($0.name)", description: $0.description, userInvocable: $0.userInvocable,
          modelInvocable: $0.modelInvocable, path: $0.path, origin: $0.origin)
      }
    }
  }

  /// The install folder of each enabled plugin that applies to the cwd, with
  /// the plugin's name, sorted by `<plugin>@<marketplace>`. It reads only version
  /// 2 of installed_plugins.json. A plugin is enabled when the account's
  /// settings.json says so, or when the listing names one of its skills.
  private static func pluginFolders(account: String, cwd: String, listing: [SlashCommand]?, machine: any Machine)
    -> [(plugin: String, folder: String)]
  {
    guard let text = machine.text("\(account)/plugins/installed_plugins.json") else { return [] }
    guard let file = JSON.parse(text) else {
      logLine("skipping the plugins of \(account): installed_plugins.json holds no JSON")
      return []
    }
    guard file["version"] == 2, let plugins = file["plugins"]?.object else {
      logLine(
        "skipping the plugins of \(account): installed_plugins.json has version \(file["version"]?.text ?? "none"), "
          + "and sbd reads only version 2")
      return []
    }
    let settings = machine.text("\(account)/settings.json").flatMap(JSON.parse)
    let enabled = Set((settings?["enabledPlugins"]?.object ?? [:]).filter { $0.value == .bool(true) }.keys)
    let listed = Set((listing ?? []).compactMap { $0.name.firstIndex(of: ":").map($0.name.prefix(upTo:)) })
    var folders: [(plugin: String, folder: String)] = []
    for (id, installs) in plugins.sorted(by: { $0.key < $1.key }) {
      let plugin = String(id.prefix { $0 != "@" })
      guard enabled.contains(id) || listed.contains(plugin[...]) else { continue }
      for install in installs.array ?? [] {
        guard let path = install["installPath"]?.string, path.hasPrefix("/"),
          install["scope"]?.string == "user" || install["projectPath"]?.string == cwd
        else { continue }
        folders.append((plugin, path))
      }
    }
    return folders
  }
}

/// The hash that a skill's label is cached under. It covers what discovery read, so an edit gives the skill a new
/// label.
public enum SkillHash {
  /// The SHA-256 of the file's first 64 KiB followed by its size in decimal. A file that grows past the head still
  /// changes the hash through its size.
  public static func file(head: Data, size: UInt64) -> String {
    hex(head + Data(String(size).utf8))
  }

  /// The head of the file at `path` and its hash, or nil when it can't be read.
  public static func read(_ path: String, on machine: any Machine) -> (head: Data, hash: String)? {
    guard let head = SkillFolders.head(path, on: machine), let size = machine.size(path) else { return nil }
    return (head, file(head: head, size: size))
  }

  /// The hash of a name that only the listing holds, from its description.
  public static func listing(name: String, description: String) -> String {
    hex(Data("listing\n\(name)\n\(description)".utf8))
  }

  private static func hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

/// The `claude -p` turn that labels one skill `work` or `safe` from its file.
public enum SkillClassifier {
  /// Part of every cache key. A change to the prompt or the schema needs a new version, which relabels every skill.
  public static let version = 1
  /// The most characters of a skill file that the turn reads.
  public static let maxInput = 16_000
  static let reasonLength = 160

  public static var system: String { Prompts.text(.skillClassifier) }

  public static let schema: JSON = [
    "type": "object",
    "properties": [
      "label": ["type": "string", "enum": ["work", "safe"]],
      "reason": ["type": "string"],
    ],
    "required": ["label", "reason"],
  ]

  /// The arguments of the `claude` command, after the program.
  public static func arguments(model: String) -> [String] {
    Headless.arguments(model: model, schema: schema, system: system)
  }

  /// The turn's input: the name, then the first `maxInput` characters of the
  /// text, each between tags. A listing-only skill's text is its
  /// `description: …` line. A `<skill-…` tag inside the name or the text is
  /// escaped, so the text can't close its tags.
  public static func input(name: String, text: String) -> String {
    let name = UntrustedText.untagged(name, tags: "skill-")
    let file = UntrustedText.untagged(String(text.prefix(maxInput)), tags: "skill-")
    return "<skill-name>\(name)</skill-name>\n<skill-file>\n\(file)\n</skill-file>"
  }

  public struct Answer: Equatable, Sendable {
    public var label: SkillLabel
    /// One line of at most 160 characters.
    public var reason: String
  }

  /// The answer in the output of `claude -p --output-format json`. It throws
  /// unless the answer is an object whose `label` is exactly `work` or `safe`
  /// and whose `reason` is a string.
  public static func parse(_ output: String) throws -> Answer {
    let object = try Headless.answer(output)
    guard let raw = object["label"]?.string, let label = SkillLabel(rawValue: raw) else {
      throw APIError("claude's answer holds no label of work or safe")
    }
    guard let reason = object["reason"]?.string else { throw APIError("claude's answer holds no reason") }
    return Answer(label: label, reason: oneLine(reason, max: reasonLength))
  }
}

/// The classifier's labels by cache key, as `~/.sb/skill-labels.json` holds them. Only successes are kept.
public struct SkillLabelCache: Equatable, Sendable {
  public struct Label: Codable, Equatable, Sendable {
    public var label: SkillLabel
    public var reason: String
    public var model: String
    /// When the classifier answered, in ms since the epoch.
    public var t: Int64

    public init(label: SkillLabel, reason: String, model: String, t: Int64) {
      self.label = label
      self.reason = reason
      self.model = model
      self.t = t
    }
  }

  public var labels: [String: Label] = [:]

  public init() {}

  /// The key of a hash's label. The same file in two accounts shares one key.
  public static func key(hash: String, model: String) -> String { "\(SkillClassifier.version)/\(model)/\(hash)" }

  /// The cache in the file. A missing or unreadable file reads as empty. It skips an entry that doesn't decode. It
  /// logs each case.
  public static func load(_ path: String) -> SkillLabelCache {
    var cache = SkillLabelCache()
    guard let data = FileManager.default.contents(atPath: path) else {
      logLine("no skill labels at \(path), so every Manager skill gets labeled again")
      return cache
    }
    guard let entries = JSON.parse(data)?.object else {
      logLine("skipping \(path): it holds no JSON object")
      return cache
    }
    for (key, value) in entries {
      do {
        cache.labels[key] = try JSONCoding.convert(value, to: Label.self)
      } catch {
        logLine("skipping the skill label \(key) in \(path): \(error)")
      }
    }
    return cache
  }

  /// Replaces the file with a rename, so a reader sees the old file or the new one, never part of one.
  public func save(_ path: String) throws {
    try JSONCoding.encoder.encode(labels).write(to: URL(fileURLWithPath: path), options: .atomic)
  }
}

/// Why the classifier gave a cache key no label. It lives only in sbd's memory.
public struct SkillFailure: Error, Equatable, Sendable {
  public enum Category: String, Sendable {
    case signedOut, noQuota, timeout, failed, badAnswer
  }

  public var category: Category
  public var message: String
  /// When the run failed, in ms since the epoch.
  public var t: Int64

  public init(category: Category, message: String, t: Int64) {
    self.category = category
    self.message = message
    self.t = t
  }
}

/// One row of the `manager-skills` answer.
public struct ManagerSkillRow: Codable, Equatable, Sendable {
  public enum Origin: String, Codable, Sendable {
    /// A skill in the account's `skills` folder.
    case user
    /// A skill in the cwd's `.claude/skills` folder.
    case project
    /// A command file of the account or the cwd.
    case command
    case plugin
    /// A name that only the transcript's listing holds, such as a bundled skill.
    case listing
    /// A name that only config.json's `managerSkills` holds.
    case config
  }

  public enum By: String, Codable, Sendable {
    case haiku
    case config
  }

  public var name: String
  public var origin: Origin
  public var path: String?
  public var label: SkillLabel?
  public var by: By?
  public var reason: String?
  /// Why the last run gave no label.
  public var error: String?
  /// True while the skill waits for a run or runs.
  public var pending: Bool

  public init(
    name: String, origin: Origin, path: String? = nil, label: SkillLabel? = nil, by: By? = nil, reason: String? = nil,
    error: String? = nil, pending: Bool = false
  ) {
    self.name = name
    self.origin = origin
    self.path = path
    self.label = label
    self.by = by
    self.reason = reason
    self.error = error
    self.pending = pending
  }

  /// The label of a name: config.json's override first, then the cached label of the key. Nil means unlabeled.
  public static func label(
    of name: String, key: String?, settings: ManagerSkillSettings, labels: SkillLabelCache
  ) -> (label: SkillLabel, by: By, reason: String?)? {
    if let forced = settings.override(name) { return (forced, .config, nil) }
    guard let key, let cached = labels.labels[key] else { return nil }
    return (cached.label, .haiku, cached.reason)
  }

  /// The rows of one account's entries, plus a row for each config.json name that discovery didn't find, sorted
  /// by name.
  public static func rows(
    _ entries: [String: CatalogEntry], settings: ManagerSkillSettings, labels: SkillLabelCache,
    failures: [String: SkillFailure], queued: Set<String>
  ) -> [ManagerSkillRow] {
    func row(_ name: String, origin: Origin, path: String?, key: String?) -> ManagerSkillRow {
      var row = ManagerSkillRow(
        name: name, origin: origin, path: path, pending: key.map(queued.contains) ?? false)
      if let found = label(of: name, key: key, settings: settings, labels: labels) {
        (row.label, row.by, row.reason) = (found.label, found.by, found.reason)
      } else {
        row.error = key.flatMap { failures[$0]?.message }
      }
      return row
    }
    let found = entries.values.map {
      row($0.name, origin: $0.origin, path: $0.path, key: $0.key(model: settings.model))
    }
    let configOnly = Set(settings.work + settings.safe).filter { entries[$0] == nil }.map {
      row($0, origin: .config, path: nil, key: nil)
    }
    return (found + configOnly).sorted { $0.name < $1.name }
  }

  /// The row as `sb manager skills` prints it: the label or `-`, the name, the origin, and why.
  public var line: String {
    let why: String =
      switch (by, error) {
      case (.haiku?, _): "haiku: \(reason ?? "")"
      case (.config?, _): "config"
      case (nil, _) where pending: "queued"
      case (nil, let error?): "unlabeled: \(error)"
      case (nil, nil): "unlabeled"
      }
    return [label?.rawValue ?? "-", name, origin.rawValue, why].joined(separator: "  ")
  }
}

/// The skill that a prompt or a tool call loads.
public enum SkillCommand {
  /// The tools whose call loads a skill.
  public static let tools: Set<String> = ["Skill", "SlashCommand"]

  /// The command that the prompt's first line starts with, after leading whitespace: a `/` and a name of
  /// `[A-Za-z0-9_.:-]` that ends at whitespace or the end of the line. Matching is case-sensitive, as in Claude Code.
  public static func name(inPrompt prompt: String) -> String? {
    let line = prompt.prefix { !$0.isNewline }.drop { $0.isWhitespace }
    guard line.first == "/" else { return nil }
    let rest = line.dropFirst()
    let name = rest.prefix { $0.isASCII && ($0.isLetter || $0.isNumber || "_.:-".contains($0)) }
    guard !name.isEmpty, name.endIndex == rest.endIndex || rest[name.endIndex].isWhitespace else { return nil }
    return String(name)
  }

  /// The name among `names` that Claude Code loads for a typed name: the name itself when `names` holds it. Claude
  /// Code also loads a plugin's skill or command by its bare name when no other skill or command has that name. So
  /// a name without a `:` that `names` lacks resolves to the one `<plugin>:<name>` in `names`. It is nil when
  /// `names` holds no match or several.
  public static func resolve(_ name: String, among names: some Collection<String>) -> String? {
    if names.contains(name) { return name }
    guard !name.contains(":") else { return nil }
    let plugins = names.filter { full in full.drop { $0 != ":" }.dropFirst() == name }
    return plugins.count == 1 ? plugins.first : nil
  }

  /// The skill that a call of the Skill tool or of the older SlashCommand tool loads. Every other tool loads none.
  public static func name(inToolCall tool: String, input: JSON?) -> String? {
    switch tool {
    case "Skill":
      guard let skill = input?["skill"]?.string?.trimmingCharacters(in: .whitespaces) else { return nil }
      let name = String(skill.trimmingPrefix("/"))
      return name.isEmpty ? nil : name
    case "SlashCommand":
      return input?["command"]?.string.flatMap { name(inPrompt: $0) }
    default:
      return nil
    }
  }
}

/// A user's "Run here anyway" for one message in a Manager conversation. It lives only in sbd's memory.
public enum SkillBypass: Equatable, Sendable {
  /// The message with this skill's command is on its way to claude. The next UserPromptSubmit clears it, and so
  /// does the next start of claude. That prompt gets past the gate only when its command is this skill.
  case armed(String)
  /// The message's skill runs. Every Skill call of its turn is let through until the turn ends.
  case turn
}

/// Whether a manager-kind session may load a skill. The hook, the `slash-commands` label, and `manager-skills`
/// read the same decision.
public enum ManagerSkillGate {
  public enum Decision: Equatable, Sendable {
    /// No skill, or one of Claude Code's built-in commands.
    case ignored
    case bypassed
    case allowed(by: ManagerSkillRow.By)
    case blocked(by: ManagerSkillRow.By)
    /// Allowed without a label. The failure is the one stored for the entry's current key, or nil when none is.
    case unchecked(SkillFailure?)

    /// The label that a `slash-commands` row carries: `work` for a block, `safe` for a labeled allow, and nil
    /// otherwise.
    public var label: SkillLabel? {
      switch self {
      case .blocked: .work
      case .allowed: .safe
      case .ignored, .bypassed, .unchecked: nil
      }
    }
  }

  public static func decide(
    name: String?, catalog: [String: CatalogEntry], labels: SkillLabelCache, failures: [String: SkillFailure],
    settings: ManagerSkillSettings, bypass: SkillBypass?
  ) -> Decision {
    guard let name, !SlashCommand.builtIns.contains(where: { $0.name == name }) else { return .ignored }
    switch bypass {
    case .turn?: return .bypassed
    case .armed(let armed)? where armed == name: return .bypassed
    default: break
    }
    let resolved = resolve(name, catalog: catalog, settings: settings)
    let key = catalog[resolved]?.key(model: settings.model)
    guard let found = ManagerSkillRow.label(of: resolved, key: key, settings: settings, labels: labels) else {
      return .unchecked(key.flatMap { failures[$0] })
    }
    return found.label == .work ? .blocked(by: found.by) : .allowed(by: found.by)
  }

  /// The name that the gate decides for a typed name. A config.json name decides before a plugin skill of the same
  /// bare name.
  public static func resolve(_ name: String, catalog: [String: CatalogEntry], settings: ManagerSkillSettings)
    -> String
  {
    guard settings.override(name) == nil else { return name }
    return SkillCommand.resolve(name, among: catalog.keys) ?? name
  }

  /// The reason of a UserPromptSubmit block, which Claude Code shows to the user. It holds only the skill's name,
  /// so neither the skill's file nor the classifier's reason reaches it. `session` is the conversation's id, which
  /// a shell reads as one word, unlike a name that can hold spaces.
  public static func promptReason(skill: String, session: String) -> String {
    "Switchboard blocked /\(skill) in this Manager conversation. /\(skill) is a work skill, and a Manager rereads "
      + "everything it loads on every later turn. Start a session for it instead: send it again from the "
      + "conversation's Message Claude field in Switchboard (⇧⌘E) and pick Spawn a session with this, or run "
      + "sb spawn --repo <owner/name> --branch <branch> --prompt \"/\(skill) …\". To run it here once, pick "
      + "Run here anyway, or run sb send \(session) --run-here \"/\(skill) …\" in a terminal. "
      + "sb manager skills lists the labels."
  }

  /// The reason of a PreToolUse deny, which the model reads. It holds only the skill's name.
  public static func toolReason(skill: String) -> String {
    "Switchboard denied the \(skill) skill. It is a work skill, and this Manager conversation rereads everything "
      + "it loads on every later turn. Start a session for the work instead, with the spawn tool or sb new <repo> "
      + "--branch <branch> --prompt \"/\(skill) <args>\", and follow it with a wait. Don't load the skill's text "
      + "another way, such as by reading its SKILL.md."
  }
}
