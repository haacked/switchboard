import Foundation

/// The GitHub orgs whose sessions the app shows. It only decides what the
/// app shows. sbd runs every session whatever the filter says.
public struct OrgFilter: Equatable, Sendable {
  /// The key of sessions with no GitHub remote. GitHub logins can't contain
  /// parentheses, so it never matches an org.
  public static let localKey = "(local)"
  public static let localTitle = "Local"

  /// Lowercased org keys. An empty set shows every org.
  public private(set) var keys: Set<String>

  public init(keys: some Sequence<String> = [String]()) {
    self.keys = Set(keys.map { $0.lowercased() })
  }

  /// Reads a comma-separated list of keys, such as `posthog, haacked`.
  public init(list: String) {
    self.init(keys: list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
  }

  public var isAll: Bool { keys.isEmpty }

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

  public mutating func insert(_ key: String) {
    keys.insert(key.lowercased())
  }

  public mutating func toggle(_ key: String) {
    if keys.remove(key.lowercased()) == nil { insert(key) }
  }

  /// One row of the filter's menu.
  public struct Entry: Equatable, Sendable, Identifiable {
    public var key: String
    public var title: String
    public var count: Int
    public var needsYou: Int
    public var id: String { key }
  }

  /// The orgs of `sessions`, plus every selected key, by title with Local
  /// last. Sessions with no key aren't counted.
  public func entries(_ sessions: [SessionSummary]) -> [Entry] {
    var byKey: [String: Entry] = [:]
    for s in sessions {
      guard let seen = Self.owner(of: s) else { continue }
      let key = seen.lowercased()
      var entry = byKey[key] ?? Entry(key: key, title: Self.title(key, seen: seen), count: 0, needsYou: 0)
      entry.count += 1
      if Triage.needsYou(s) { entry.needsYou += 1 }
      byKey[key] = entry
    }
    for key in keys where byKey[key] == nil {
      byKey[key] = Entry(key: key, title: Self.title(key, seen: key), count: 0, needsYou: 0)
    }
    return byKey.values.sorted { a, b in
      if (a.key == Self.localKey) != (b.key == Self.localKey) { return b.key == Self.localKey }
      return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
    }
  }

  /// What the toolbar says: "All Orgs", "PostHog", "PostHog, Local", or
  /// "PostHog +2". `entries` supplies the titles.
  public func label(_ entries: [Entry]) -> String {
    let titles = entries.filter { keys.contains($0.key) }.map(\.title)
    switch titles.count {
    case 0: return "All Orgs"
    case 1, 2: return titles.joined(separator: ", ")
    default: return "\(titles[0]) +\(titles.count - 1)"
    }
  }
}
