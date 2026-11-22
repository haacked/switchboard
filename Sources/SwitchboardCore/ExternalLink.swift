import Foundation

/// A web page attached to a group or a session, such as an RFC, a design doc, or a Slack thread. On a group, the
/// user adds any link, and a Claude Code session adds only a link to a claude.ai artifact. A group link to a
/// claude.ai artifact also lists among the group's artifacts.
public struct ExternalLink: Codable, Equatable, Sendable, Identifiable {
  public var id: String
  public var title: String
  public var url: String
  public var by: LinkAuthor
  /// Milliseconds since the epoch.
  public var t: Int64
  /// What sbd read of a Slack link's thread. Only a session summary sets it, so stored links never carry it.
  public var status: SlackThreadStatus?

  /// The longest title, in characters.
  public static let titleLimit = 200
  /// The longest URL, in characters.
  public static let urlLimit = 2000

  public init(id: String, title: String, url: String, by: LinkAuthor, t: Int64) {
    self.id = id
    self.title = title
    self.url = url
    self.by = by
    self.t = t
  }

  /// The page that the URL names, or nil for a link of no known kind.
  public var linkTarget: LinkTarget? { LinkTarget.parse(url) }
  /// The kind of page that the URL names: the kind that `LinkTarget.parse(_:)` finds, else `web`.
  public var kind: LinkKind { linkTarget?.kind ?? .web }

  private enum CodingKeys: String, CodingKey { case id, title, url, by, t, status }
  private enum DerivedKeys: String, CodingKey { case kind, channel, thread }

  /// Writes the stored fields and the fields that the URL gives. Decoding reads only the stored fields, so the URL
  /// stays the one source of the derived ones.
  public func encode(to encoder: any Encoder) throws {
    var stored = encoder.container(keyedBy: CodingKeys.self)
    try stored.encode(id, forKey: .id)
    try stored.encode(title, forKey: .title)
    try stored.encode(url, forKey: .url)
    try stored.encode(by, forKey: .by)
    try stored.encode(t, forKey: .t)
    try stored.encodeIfPresent(status, forKey: .status)
    let target = linkTarget
    var derived = encoder.container(keyedBy: DerivedKeys.self)
    try derived.encode(target?.kind ?? .web, forKey: .kind)
    try derived.encodeIfPresent(target?.channel, forKey: .channel)
    try derived.encodeIfPresent(target?.thread, forKey: .thread)
  }

  /// Who put the link there and how long ago, such as "found 3 min ago" or "added by Claude 2 h ago".
  public func caption(now: Int64 = nowMs()) -> String { "\(by.phrase) \(ago(t, now: now)) ago" }

  /// The URL that two links to the same page share: the normalized form of a claude.ai artifact link, else the URL.
  var target: String { Self.target(url) }

  static func target(_ url: String) -> String { ArtifactLink.normalized(url) ?? url }

  /// The URL without surrounding whitespace, and a claude.ai artifact link in its normalized form. It refuses a URL
  /// that is not http or https, that has no host, or that holds whitespace, because sessions will read it as one
  /// token. It refuses a URL with a user name or password, because such a URL shows one host and opens another.
  public static func cleanURL(_ text: String?) throws -> String {
    let url = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !url.isEmpty else { throw APIError("a link needs a URL") }
    guard url.count <= urlLimit else {
      throw APIError("a link URL has at most \(urlLimit) characters, and this one has \(url.count)")
    }
    guard !url.contains(where: \.isWhitespace), let parsed = URL(string: url),
      let scheme = parsed.scheme?.lowercased(), ["http", "https"].contains(scheme), parsed.host?.isEmpty == false
    else { throw APIError("a link needs an http or https URL with a host, not \(url)") }
    guard parsed.user == nil, parsed.password == nil else {
      throw APIError("a link URL can't hold a user name or password, and \(url) does")
    }
    return ArtifactLink.normalized(url) ?? url
  }

  /// The key that two URLs of one page share: the `LinkTarget` key of a known kind, else `target`'s form. Hiding a
  /// found link matches on it, so a reply's link and its thread's link hide together.
  public static func pageKey(_ url: String) -> String { LinkTarget.parse(url)?.key ?? target(url) }

  /// The title on one line. Without a title, it is the URL, cut to `titleLimit` characters with an ellipsis when it
  /// is longer. It refuses a given title over `titleLimit`.
  public static func cleanTitle(_ text: String?, url: String) throws -> String {
    if let title = try SessionGroup.cleanLine(text, limit: titleLimit, noun: "a link title") { return title }
    return url.count <= titleLimit ? url : String(url.prefix(titleLimit - 1)) + "…"
  }
}

/// Who put a link on a session or a group.
public enum LinkAuthor: String, Codable, Sendable {
  /// sbd found the link in the session's events.
  case found
  case you
  case claude

  public init(_ author: Author) {
    switch author {
    case .you: self = .you
    case .claude: self = .claude
    }
  }

  /// "found", "added by you", or "added by Claude".
  public var phrase: String {
    switch self {
    case .found: "found"
    case .you: "added by you"
    case .claude: "added by Claude"
    }
  }
}
