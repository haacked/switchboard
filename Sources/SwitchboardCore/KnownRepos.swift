import Foundation

/// A repository that the New Session sheet offers.
public struct KnownRepo: Codable, Equatable, Sendable, Identifiable {
  /// The real path of the repository's main checkout.
  public var path: String
  /// The `owner/name` of its GitHub remote, or the folder's name without one.
  public var name: String
  /// When a session last started in it or the user added it, in milliseconds. It is nil for a repository
  /// that only config.json names.
  public var used: Int64?

  public var id: String { path }

  public init(path: String, name: String, used: Int64? = nil) {
    self.path = path
    self.name = name
    self.used = used
  }
}

public enum KnownRepos {
  /// One entry per path, with its latest use. The most recently used comes first. Entries without a use
  /// follow, by name without case and then by path.
  public static func merge(_ entries: [KnownRepo]) -> [KnownRepo] {
    let byPath = Dictionary(entries.map { ($0.path, $0) }) { kept, entry in
      (entry.used ?? .min) > (kept.used ?? .min) ? entry : kept
    }
    return byPath.values.sorted { a, b in
      if a.used != b.used { return (a.used ?? .min) > (b.used ?? .min) }
      let (an, bn) = (a.name.lowercased(), b.name.lowercased())
      return an != bn ? an < bn : a.path < b.path
    }
  }

  /// The repository that the New Session sheet selects for `group`: the one whose path is the checkout of the
  /// most work sessions in the group. A tie goes to the one that comes first in `known`. When no session in the
  /// group has a checkout in `known`, or `group` is nil, it is the first of `known`.
  public static func preferred(_ known: [KnownRepo], group: String?, sessions: [SessionSummary]) -> KnownRepo? {
    guard let group else { return known.first }
    var counts: [String: Int] = [:]
    for s in sessions where s.group == group && s.kind == .work {
      if let checkout = s.checkout { counts[checkout, default: 0] += 1 }
    }
    var best: (repo: KnownRepo, count: Int)?
    for repo in known {
      let count = counts[repo.path, default: 0]
      if count > (best?.count ?? 0) { best = (repo, count) }
    }
    return best?.repo ?? known.first
  }
}
