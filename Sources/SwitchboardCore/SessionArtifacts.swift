import Foundation

/// A claude.ai artifact that the session published with Claude Code's Artifact tool.
public struct SessionArtifact: Codable, Equatable, Sendable {
  /// The link that `ArtifactLink.normalized(_:)` returned for the publish's `tool_response.url`.
  public var url: String
  /// The publish's `tool_response.artifact_id`. A create from an Artifact type has none.
  public var artifactId: String?
  /// Untrusted text from the tool result, on one line.
  public var title: String
  /// When the first publish ran, in ms since the epoch.
  public var published: Int64
  /// When the last publish ran.
  public var updated: Int64
  /// When a delete removed the page, or nil while it exists.
  public var removed: Int64?

  public init(url: String, artifactId: String?, title: String, published: Int64, updated: Int64, removed: Int64?) {
    self.url = url
    self.artifactId = artifactId
    self.title = title
    self.published = published
    self.updated = updated
    self.removed = removed
  }
}

/// A row of a group's artifact list: a member's artifact, one that a removed session kept on the group, or one
/// that a group link names. The fields are flat, so `jq '.groups[].artifacts[].url'` reads each URL.
public struct GroupArtifact: Codable, Equatable, Sendable {
  /// The link that `ArtifactLink.normalized(_:)` returned, so rows of one artifact have the same `url`.
  public var url: String
  public var artifactId: String?
  public var title: String
  public var published: Int64
  public var updated: Int64
  public var removed: Int64?
  /// The id of the session that published it, or nil on a row that only a group link gives.
  public var session: String?
  /// The session's name when sbd built or kept the row, or nil on a row that only a group link gives.
  public var sessionName: String?
  /// The id of the group link that names the artifact, or nil when no link names it.
  public var link: String?

  public init(
    url: String, artifactId: String?, title: String, published: Int64, updated: Int64, removed: Int64?,
    session: String?, sessionName: String?, link: String? = nil
  ) {
    self.url = url
    self.artifactId = artifactId
    self.title = title
    self.published = published
    self.updated = updated
    self.removed = removed
    self.session = session
    self.sessionName = sessionName
    self.link = link
  }

  public init(_ artifact: SessionArtifact, session: String, sessionName: String) {
    self.init(
      url: artifact.url, artifactId: artifact.artifactId, title: artifact.title, published: artifact.published,
      updated: artifact.updated, removed: artifact.removed, session: session, sessionName: sessionName)
  }

  /// The row of a group link to a claude.ai artifact, or nil for a link that `ArtifactLink.normalized(_:)` refuses.
  /// Its `published` and `updated` are when the link was added.
  public init?(link: ExternalLink) {
    guard let url = ArtifactLink.normalized(link.url) else { return nil }
    self.init(
      url: url, artifactId: ArtifactLink.artifactId(of: url), title: link.title, published: link.t, updated: link.t,
      removed: nil, session: nil, sessionName: nil, link: link.id)
  }
}

/// The fields that identify an artifact row, order it, and caption it.
public protocol ArtifactRecord {
  var url: String { get }
  var artifactId: String? { get }
  var updated: Int64 { get }
  var removed: Int64? { get }
  /// The word before the time of `updated` in `caption(now:)`.
  var updatedVerb: String { get }
}

extension SessionArtifact: ArtifactRecord {}
extension GroupArtifact: ArtifactRecord {
  /// `added` on a row that only a group link gives, because its `updated` is when the link was added.
  public var updatedVerb: String { session == nil ? "added" : "updated" }
}

extension ArtifactRecord {
  /// Whether `link` names this artifact: the link's normalized form is `url`, or its id is `artifactId`. A
  /// `/code/artifact/<uuid>` link names the uuid that `artifact_id` holds.
  public func names(_ link: String) -> Bool {
    guard let normalized = ArtifactLink.normalized(link) else { return false }
    return normalized == url || (artifactId != nil && ArtifactLink.id(of: normalized) == artifactId)
  }

  public var updatedVerb: String { "updated" }

  /// When a delete removed the artifact, else when its last publish ran, such as `updated 5m ago`.
  public func caption(now: Int64 = nowMs()) -> String {
    removed.map { "removed \(ago($0, now: now)) ago" } ?? "\(updatedVerb) \(ago(updated, now: now)) ago"
  }
}

extension Array where Element: ArtifactRecord {
  /// The last update first, then by URL.
  public var newestFirst: [Element] { sorted { ($1.updated, $0.url) < ($0.updated, $1.url) } }
}

/// What one Artifact tool call did to an artifact's page, as its hook says.
public enum ArtifactCall: Equatable, Sendable {
  /// The call created or redeployed the page at `url`.
  case publish(url: String, artifactId: String?, title: String?)
  /// The call deleted the page that `url` names.
  case delete(url: String)

  private static let titleLimit = 200

  /// The publish or the delete that the event records, or nil for any other event. The tool's input and
  /// result come from the model, so each condition refuses what it does not recognize.
  public static func parse(_ event: Event) -> ArtifactCall? {
    guard event.kind == "PostToolUse", event.data["tool_name"]?.string == "Artifact",
      let input = event.data["tool_input"]?.object
    else { return nil }
    switch input["action"] {
    case nil, .string("publish"):
      return publish(input, event.data["tool_response"])
    case .string("delete"):
      // A delete with `path` removes one uploaded asset and leaves the page.
      guard input["path"] == nil, let link = input["url"]?.string, let url = ArtifactLink.normalized(link) else {
        return nil
      }
      return .delete(url: url)
    default:
      return nil
    }
  }

  /// The URL comes from the response alone. A redeploy by `file_path` has no input `url`, and a create from a
  /// type holds the type's link in its input.
  private static func publish(_ input: [String: JSON], _ response: JSON?) -> ArtifactCall? {
    // These calls upload or copy assets into an artifact and leave its page as it was.
    guard input["asset"] == nil || input["asset"] == .bool(false), input["from_url"] == nil,
      input["asset_ids"] == nil, case .object(let result)? = response, let link = result["url"]?.string,
      let url = ArtifactLink.normalized(link)
    else { return nil }
    let titles = [result["title"]?.string, input["title"]?.string].compactMap {
      $0.map { oneLine($0, max: titleLimit) }
    }
    return .publish(
      url: url, artifactId: result["artifact_id"]?.string.flatMap { $0.isEmpty ? nil : $0 },
      title: titles.first { !$0.isEmpty })
  }
}

extension SessionFacts {
  /// Records a publish or a delete of the Artifact tool. A subagent's call counts for the session.
  mutating func applyArtifact(_ event: Event) {
    switch ArtifactCall.parse(event) {
    case .publish(let url, let artifactId, let title):
      // The short link and the `/code/artifact/<uuid>` link name one page, so either one updates its entry.
      if let i = artifacts.firstIndex(where: { $0.url == url || (artifactId != nil && $0.artifactId == artifactId) }) {
        artifacts[i].updated = event.t
        if let title { artifacts[i].title = title }
        if artifacts[i].artifactId == nil { artifacts[i].artifactId = artifactId }
        artifacts[i].removed = nil
      } else {
        artifacts.append(
          SessionArtifact(
            url: url, artifactId: artifactId, title: title ?? ArtifactLink.id(of: url) ?? url, published: event.t,
            updated: event.t, removed: nil))
      }
    case .delete(let url):
      for i in artifacts.indices where artifacts[i].names(url) { artifacts[i].removed = event.t }
    case nil:
      break
    }
  }
}

/// A group's artifact list.
public enum GroupArtifacts {
  /// The rows of the live members, the group's chat, the group's kept rows, and the group's links, one per
  /// artifact, newest `updated` first and then by URL. Rows that name the same artifact merge. When any row in the
  /// set came from a session, the session rows give every field but `link`: the row with the latest `updated`
  /// gives the URL, title, and session, `published` is the earliest, and the merged row is removed when its latest
  /// removal is at or after its latest update. When every row came from a link, the merged row is the earliest
  /// link's row. `link` is the id of the set's earliest link. The result does not depend on the order of the rows.
  public static func list(_ rows: [GroupArtifact]) -> [GroupArtifact] {
    components(rows).map(merge).newestFirst
  }

  /// The rows grouped by the same-artifact rule. The rule is not transitive, so each group holds every row that
  /// a chain of matches reaches.
  private static func components(_ rows: [GroupArtifact]) -> [[GroupArtifact]] {
    var parent = Array(rows.indices)
    func root(_ i: Int) -> Int {
      var i = i
      while parent[i] != i { i = parent[i] }
      return i
    }
    var byURL: [String: Int] = [:]
    var byId: [String: Int] = [:]
    for (i, row) in rows.enumerated() {
      if let j = byURL[row.url] { parent[root(i)] = root(j) } else { byURL[row.url] = i }
      if let id = row.artifactId {
        if let j = byId[id] { parent[root(i)] = root(j) } else { byId[id] = i }
      }
    }
    return Dictionary(grouping: rows.indices, by: root).values.map { $0.map { rows[$0] } }
  }

  private static func merge(_ rows: [GroupArtifact]) -> GroupArtifact {
    let links = rows.filter { $0.session == nil }.sorted { ($0.updated, $0.link ?? "") < ($1.updated, $1.link ?? "") }
    let recorded = rows.filter { $0.session != nil }
    guard !recorded.isEmpty else { return links[0] }
    // Ties on `updated` go to the row that sorts first by its other fields, never by input position.
    let ordered = recorded.sorted { latest($0, over: $1) }
    var merged = ordered[0]
    merged.published = recorded.map(\.published).min()!
    merged.artifactId = merged.artifactId ?? ordered.first { $0.artifactId != nil }?.artifactId
    let removed = recorded.compactMap(\.removed).max()
    merged.removed = removed.flatMap { $0 >= merged.updated ? $0 : nil }
    merged.link = links.first?.link
    return merged
  }

  /// Whether `a` wins over `b` as the merged row: a later `updated`, then the first by session, URL, title, and
  /// the remaining fields.
  private static func latest(_ a: GroupArtifact, over b: GroupArtifact) -> Bool {
    if a.updated != b.updated { return a.updated > b.updated }
    let keyA = [a.session ?? "", a.url, a.title, a.sessionName ?? "", a.artifactId ?? ""]
    let keyB = [b.session ?? "", b.url, b.title, b.sessionName ?? "", b.artifactId ?? ""]
    if keyA != keyB { return keyA.lexicographicallyPrecedes(keyB) }
    return (a.published, a.removed ?? -1) < (b.published, b.removed ?? -1)
  }
}
