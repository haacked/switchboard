import Foundation

/// A named set of sessions. Each session names its group. The group record
/// holds no member list.
public struct SessionGroup: Codable, Equatable, Sendable, Identifiable {
  public var id: String
  public var name: String
  public var notes: [Note]
  /// Milliseconds since the epoch.
  public var created: Int64

  public init(id: String, name: String, notes: [Note] = [], created: Int64) {
    self.id = id
    self.name = name
    self.notes = notes
    self.created = created
  }

  /// This group with `other`'s notes added, oldest first. A note of `other`
  /// whose id this group already uses gets a new id.
  public func absorbing(_ other: SessionGroup) -> SessionGroup {
    var kept = self
    for var note in other.notes {
      if kept.notes.contains(where: { $0.id == note.id }) { note.id = shortId("n", taken: kept.notes.map(\.id)) }
      kept.notes.append(note)
    }
    kept.notes.sort { $0.t < $1.t }
    return kept
  }
}

/// A group and the ids of its sessions, follow-ups included.
public struct GroupSummary: Codable, Equatable, Sendable, Identifiable {
  public var id: String
  public var name: String
  public var notes: [Note]
  public var created: Int64
  public var sessions: [String]

  public init(_ group: SessionGroup, sessions: [String]) {
    id = group.id
    name = group.name
    notes = group.notes
    created = group.created
    self.sessions = sessions
  }
}

/// The answer to `group-ls`: the groups sorted by name, and the sessions in no group.
public struct GroupList: Codable, Equatable, Sendable {
  public var groups: [GroupSummary]
  public var ungrouped: [String]

  public init(groups: [GroupSummary], ungrouped: [String]) {
    self.groups = groups
    self.ungrouped = ungrouped
  }
}

/// A group that sbd proposes: a new one, more sessions for an existing one,
/// or a merge of two groups.
public struct GroupSuggestion: Codable, Equatable, Sendable, Identifiable {
  /// The group that a merge empties into `group`.
  public struct Merge: Codable, Equatable, Sendable {
    public var group: String
    public var name: String

    public init(group: String, name: String) {
      self.group = group
      self.name = name
    }
  }

  /// Stays the same while the key and the group stay, so `--accept` can name it.
  public var id: String
  public var name: String
  /// The group to join, or nil for a new group.
  public var group: String?
  /// The sessions that accepting moves.
  public var sessions: [String]
  public var reason: String
  public var merge: Merge?
  /// The sessions of the merged group that the user placed by hand. Accepting
  /// leaves them where they are.
  public var stays: [String]?

  public init(
    id: String, name: String, group: String?, sessions: [String], reason: String, merge: Merge? = nil,
    stays: [String]? = nil
  ) {
    self.id = id
    self.name = name
    self.group = group
    self.sessions = sessions
    self.reason = reason
    self.merge = merge
    self.stays = stays
  }

  /// What accepting does, such as `join Flags`.
  public var action: String {
    if let merge { return "merge \(merge.name) into \(name)" }
    return group == nil ? "new group \(name)" : "join \(name)"
  }

  /// Such as `s1, s2 stay, placed by hand`, with each session's id passed
  /// through `name`. Nil when no session stays.
  public func staying(_ name: (String) -> String = { $0 }) -> String? {
    guard let stays, !stays.isEmpty else { return nil }
    return "\(stays.map(name).joined(separator: ", ")) \(stays.count == 1 ? "stays" : "stay"), placed by hand"
  }
}

/// The answer to `send-group`.
public struct GroupSend: Codable, Equatable, Sendable {
  public struct Target: Codable, Equatable, Sendable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
      self.id = id
      self.name = name
    }
  }

  public struct Result: Codable, Equatable, Sendable {
    public var session: String
    public var delivery: Delivery?
    public var error: String?

    public init(session: String, delivery: Delivery? = nil, error: String? = nil) {
      self.session = session
      self.delivery = delivery
      self.error = error
    }
  }

  public var group: String
  public var targets: [Target]
  /// False when the request was not confirmed, so nothing was sent.
  public var sent: Bool
  public var deliveries: [Result]?

  public init(group: String, targets: [Target], sent: Bool, deliveries: [Result]? = nil) {
    self.group = group
    self.targets = targets
    self.sent = sent
    self.deliveries = deliveries
  }
}

/// Proposes groups from dependencies between sessions, branch names, and PR titles.
public enum GroupSuggestions {
  public struct Candidate: Sendable {
    public var id: String
    public var branch: String?
    public var prTitle: String?
    public var group: String?
    /// True once the user chose the session's group, or chose no group.
    public var placedByHand: Bool
    /// The repo of the session's PR.
    public var repo: String?
    /// The number of the session's PR.
    public var pr: Int?
    public var dependencies: [Dependency]

    public init(
      id: String, branch: String?, prTitle: String?, group: String?, placedByHand: Bool, repo: String? = nil,
      pr: Int? = nil, dependencies: [Dependency] = []
    ) {
      self.id = id
      self.branch = branch
      self.prTitle = prTitle
      self.group = group
      self.placedByHand = placedByHand
      self.repo = repo
      self.pr = pr
      self.dependencies = dependencies
    }

    /// In no group, and not placed there by hand.
    var open: Bool { group == nil && !placedByHand }
  }

  /// Ranked from the strongest signal to the weakest.
  enum Kind: Comparable {
    case prefix
    case scope
    case word
  }

  struct Key: Hashable {
    var kind: Kind
    var text: String
  }

  static let stopWords: Set<String> = [
    "about", "adds", "after", "also", "back", "before", "bump", "change", "changes", "chore", "clean", "cleanup",
    "does", "draft", "feat", "feature", "first", "from", "handle", "into", "just", "make", "more", "move", "only",
    "other", "over", "refactor", "remove", "rename", "revert", "some", "support", "than", "that", "then", "this",
    "update", "updates", "when", "with", "without", "work",
  ]

  static func words(_ text: String) -> [String] {
    text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
  }

  /// The words of `text`, lowercased and joined with dashes.
  static func slug(_ text: String) -> String { words(text).joined(separator: "-") }

  static func significant(_ word: String) -> Bool {
    word.count >= 4 && !stopWords.contains(word) && !word.allSatisfy(\.isNumber)
  }

  /// The branch without its first segment, such as the owner in
  /// `haacked/flag-cache`, split into words. A branch without a `/` is split
  /// whole.
  static func branchWords(_ branch: String) -> [String] {
    words(branch.split(separator: "/", maxSplits: 1).last.map(String.init) ?? branch)
  }

  /// The scope of a conventional title such as `feat(flags): …`.
  static func scope(_ title: String) -> String? {
    guard let open = title.firstIndex(of: "("), let close = title[open...].firstIndex(of: ")"),
      title[close...].dropFirst().hasPrefix(":") || title[close...].dropFirst().hasPrefix("!:")
    else { return nil }
    let scope = title[title.index(after: open)..<close].lowercased().trimmingCharacters(in: .whitespaces)
    return scope.isEmpty ? nil : scope
  }

  static func keys(branch: String?, prTitle: String?) -> Set<Key> {
    var keys: Set<Key> = []
    if let branch {
      let w = branchWords(branch)
      for n in stride(from: 1, to: w.count, by: 1) where w.prefix(n).contains(where: significant) {
        keys.insert(Key(kind: .prefix, text: w.prefix(n).joined(separator: "-")))
      }
      for word in w where significant(word) { keys.insert(Key(kind: .word, text: word)) }
    }
    if let prTitle {
      if let scope = scope(prTitle) { keys.insert(Key(kind: .scope, text: scope)) }
      for word in words(prTitle) where significant(word) { keys.insert(Key(kind: .word, text: word)) }
    }
    return keys
  }

  static func reason(_ key: Key) -> String {
    switch key.kind {
    case .prefix: "branches start with \(key.text)"
    case .scope: "PR titles have the scope \(key.text)"
    case .word: "branches or PR titles share the word \(key.text)"
    }
  }

  /// The suggestions, strongest first: merges of groups that a dependency
  /// links, then joins from a dependency, then joins and new groups from
  /// keys. A session in no group that the user didn't place there by hand
  /// appears in at most one join or new group. A suggestion whose id is in
  /// `declined` is left out.
  public static func make(candidates: [Candidate], groups: [SessionGroup], declined: Set<String> = [])
    -> [GroupSuggestion]
  {
    let links = Links(candidates: candidates, groups: groups)
    let joins = links.joins(declined: declined)
    let taken = Set(joins.flatMap(\.sessions))
    let open = candidates.filter { $0.open && !taken.contains($0.id) }
    return links.merges(declined: declined) + joins + keyed(open, candidates, groups, declined: declined)
  }

  static func keyed(_ open: [Candidate], _ candidates: [Candidate], _ groups: [SessionGroup], declined: Set<String>)
    -> [GroupSuggestion]
  {
    var openByKey: [Key: [String]] = [:]
    for c in open {
      for key in keys(branch: c.branch, prTitle: c.prTitle) { openByKey[key, default: []].append(c.id) }
    }
    // How many members of each group have each key.
    var groupsByKey: [Key: [String: Int]] = [:]
    let names = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0.name) })
    for c in candidates {
      guard let group = c.group, names[group] != nil else { continue }
      for key in keys(branch: c.branch, prTitle: c.prTitle) { groupsByKey[key, default: [:]][group, default: 0] += 1 }
    }
    // A group whose name has the key's text counts it once, whatever the key's
    // kind, so a suggestion never makes a second group with that name.
    var named: [String: [String]] = [:]
    for g in groups { named[slug(g.name), default: []].append(g.id) }

    struct Option {
      var key: Key
      var group: String?
      var members: Int
      var sessions: [String]
    }
    var options: [Option] = []
    for (key, sessions) in openByKey {
      var joins = groupsByKey[key] ?? [:]
      for id in named[slug(key.text)] ?? [] { joins[id, default: 0] += 1 }
      // Ties go to the group whose name sorts first.
      let best = joins.max { a, b in (a.value, names[b.key] ?? "") < (b.value, names[a.key] ?? "") }
      options.append(Option(key: key, group: best?.key, members: best?.value ?? 0, sessions: sessions))
    }
    options.sort { a, b in
      let (sizeA, sizeB) = (a.sessions.count + a.members, b.sessions.count + b.members)
      if sizeA != sizeB { return sizeA > sizeB }
      if a.key.kind != b.key.kind { return a.key.kind < b.key.kind }
      if a.key.text.count != b.key.text.count { return a.key.text.count > b.key.text.count }
      return (a.key.text, a.group ?? "") < (b.key.text, b.group ?? "")
    }

    var taken: Set<String> = []
    var out: [GroupSuggestion] = []
    for option in options {
      let id = "\(option.key.kind):\(option.key.text)" + (option.group.map { ":\($0)" } ?? "")
      let sessions = option.sessions.filter { !taken.contains($0) }.sorted()
      guard sessions.count >= (option.group == nil ? 2 : 1), !declined.contains(id) else { continue }
      taken.formUnion(sessions)
      out.append(
        GroupSuggestion(
          id: id, name: option.group.flatMap { names[$0] } ?? option.key.text, group: option.group,
          sessions: sessions, reason: reason(option.key)))
    }
    return out
  }
}

/// The board's rows: one per group, then Ungrouped.
public enum BoardRows {
  public struct Row: Equatable, Sendable, Identifiable {
    public var title: String
    /// Nil for the Ungrouped row.
    public var group: String?
    public var sessions: [SessionSummary]
    public var id: String { group ?? "" }
  }

  public static let ungroupedTitle = "Ungrouped"

  /// Every group in the order of `groups`, with its sessions in the order of
  /// `sessions`. A session whose group is not in `groups` counts as
  /// ungrouped. The Ungrouped row comes last, and only when it has sessions.
  public static func make(sessions: [SessionSummary], groups: [GroupSummary]) -> [Row] {
    let known = Set(groups.map(\.id))
    var rows = groups.map { g in Row(title: g.name, group: g.id, sessions: sessions.filter { $0.group == g.id }) }
    let ungrouped = sessions.filter { $0.group.map { !known.contains($0) } ?? true }
    if !ungrouped.isEmpty { rows.append(Row(title: ungroupedTitle, group: nil, sessions: ungrouped)) }
    return rows
  }
}
