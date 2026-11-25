import Foundation

/// One row of a filter's menu.
public struct FilterEntry: Equatable, Sendable, Identifiable {
  public var key: String
  public var title: String
  public var count: Int
  public var needsYou: Int
  public var id: String { key }

  public init(key: String, title: String, count: Int = 0, needsYou: Int = 0) {
    self.key = key
    self.title = title
    self.count = count
    self.needsYou = needsYou
  }

  /// Counts `s` in the row.
  mutating func add(_ s: SessionSummary) {
    count += 1
    if Triage.needsYou(s) { needsYou += 1 }
  }
}

/// The items of a comma-separated list, such as `posthog, haacked`, without spaces or empty items.
public func splitList(_ list: String) -> [String] {
  list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
}

/// A set of lowercased keys that selects which sessions the app shows along
/// one dimension, such as org or group. An empty set shows every session.
public protocol KeyFilter: Equatable, Sendable {
  var keys: Set<String> { get }
  init(keys: some Sequence<String>)
  /// What the toolbar says when the set is empty, such as "All Orgs".
  static var allTitle: String { get }
}

extension KeyFilter {
  /// Reads a comma-separated list of keys, such as `posthog, haacked`.
  public init(list: String) {
    self.init(keys: splitList(list))
  }

  public var isAll: Bool { keys.isEmpty }

  public mutating func insert(_ key: String) {
    self = Self(keys: keys.union([key]))
  }

  public mutating func toggle(_ key: String) {
    let key = key.lowercased()
    self = Self(keys: keys.contains(key) ? keys.subtracting([key]) : keys.union([key]))
  }

  /// The selected titles, in the order of `entries`.
  public func selectedTitles(_ entries: [FilterEntry]) -> [String] {
    entries.filter { keys.contains($0.key) }.map(\.title)
  }

  /// What the toolbar says: `allTitle`, "PostHog", "PostHog, Local", or
  /// "PostHog +2". `entries` supplies the titles.
  public func label(_ entries: [FilterEntry]) -> String {
    let titles = selectedTitles(entries)
    switch titles.count {
    case 0: return Self.allTitle
    case 1, 2: return titles.joined(separator: ", ")
    default: return "\(titles[0]) +\(titles.count - 1)"
    }
  }
}

/// The GitHub orgs and GitLab groups whose sessions the app shows. It only
/// decides what the app shows. sbd runs every session whatever the filter says.
public struct OrgFilter: KeyFilter {
  /// The key of sessions with no GitHub or GitLab remote. GitHub logins can't contain
  /// parentheses, so it never matches an org.
  public static let localKey = "(local)"
  public static let localTitle = "Local"
  public static let allTitle = "All Orgs"

  /// Lowercased org keys. An empty set shows every org.
  public private(set) var keys: Set<String>

  public init(keys: some Sequence<String> = [String]()) {
    self.keys = Set(keys.map { $0.lowercased() })
  }

  /// The org that a session belongs to, or nil when the session belongs to
  /// none (the Manager, a group chat) or sbd hasn't read its folder yet.
  public static func key(of s: SessionSummary) -> String? {
    owner(of: s).map { $0.lowercased() }
  }

  /// The menu title of `key`, whose first session named it `seen`.
  private static func title(_ key: String, seen: String) -> String { key == localKey ? localTitle : seen }

  /// The org with the casing that GitHub uses, such as "PostHog", or `localKey`.
  /// A PR names the org only of a session with no folder, as in `RepoLabels`,
  /// because a session can link a PR from another repo.
  static func owner(of s: SessionSummary) -> String? {
    guard s.kind == .work else { return nil }
    if let docket = s.docket { return DocketRef(docket.pullRequest)?.org ?? localKey }
    if let repo = s.repository ?? (s.repoFolder == nil ? s.pr?.repo : nil) ?? s.followup?.repository {
      let owner = GitHub.ownerAndName(repo).owner
      if !owner.isEmpty { return owner }
    }
    if s.repositoryRead == true || s.waitsToStart { return localKey }
    return nil
  }

  /// A session whose key is nil always shows, because hiding is safe only
  /// when its org is known and not selected.
  public func shows(_ s: SessionSummary) -> Bool {
    guard !isAll, let key = Self.key(of: s) else { return true }
    return keys.contains(key)
  }

  /// Whether the filter shows an issue or PR in `repo`, an owner/name.
  public func shows(repo: String) -> Bool {
    isAll || keys.contains(GitHub.ownerAndName(repo).owner.lowercased())
  }

  /// The orgs of `sessions`, plus every selected key, by title with Local
  /// last. Sessions with no key aren't counted.
  public func entries(_ sessions: [SessionSummary]) -> [FilterEntry] {
    var byKey: [String: FilterEntry] = [:]
    for s in sessions {
      guard let seen = Self.owner(of: s) else { continue }
      let key = seen.lowercased()
      byKey[key, default: FilterEntry(key: key, title: Self.title(key, seen: seen))].add(s)
    }
    for key in keys where byKey[key] == nil {
      byKey[key] = FilterEntry(key: key, title: Self.title(key, seen: key))
    }
    return byKey.values.sorted { a, b in
      if (a.key == Self.localKey) != (b.key == Self.localKey) { return b.key == Self.localKey }
      return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
    }
  }
}
