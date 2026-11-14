import Foundation

/// The `livePriority` setting: orgs and repositories in order, such as
/// `["PostHog/posthog", "PostHog"]`. A start from a higher entry gets a live
/// slot first, and the live cap stops idle sessions from the lowest rank first.
public struct LivePriority: Equatable, Sendable {
  /// Each entry is an org or an owner/name, highest first, without duplicates.
  public var entries: [String]

  public init(entries: [String]) {
    var seen = Set<String>()
    self.entries = entries.filter { seen.insert($0.lowercased()).inserted }
  }

  /// The valid entries of a `livePriority` value from config.json, and a
  /// problem for each part that isn't valid. An entry is an org or an
  /// owner/name.
  public static func parse(_ value: JSON?) -> (entries: [String], problems: [String]) {
    guard let value, value != .null else { return ([], []) }
    guard case .array(let items) = value else { return ([], ["livePriority must be a list of orgs and repositories"]) }
    var entries: [String] = []
    var problems: [String] = []
    for item in items {
      guard let text = item.string else {
        problems.append("livePriority entry \(item.text) isn't a string")
        continue
      }
      let org = !text.isEmpty && !text.contains("/") && !text.contains(where: \.isWhitespace)
      guard org || Followup.isRepository(text) else {
        problems.append("livePriority entry \"\(text)\" isn't an org or an owner/name")
        continue
      }
      entries.append(text)
    }
    return (LivePriority(entries: entries).entries, problems)
  }

  /// The entry that ranks `repository`: its exact entry when the list has
  /// one, otherwise its org's entry.
  public func entry(of repository: String?) -> String? {
    guard let repository else { return nil }
    let name = repository.lowercased()
    if let exact = entries.first(where: { $0.lowercased() == name }) { return exact }
    let org = GitHub.ownerAndName(name).owner
    return entries.first { $0.lowercased() == org }
  }

  /// Higher is first. A repository that matches no entry ranks 0.
  public func rank(of repository: String?) -> Int {
    guard let entry = entry(of: repository), let index = entries.firstIndex(of: entry) else { return 0 }
    return entries.count - index
  }
}
