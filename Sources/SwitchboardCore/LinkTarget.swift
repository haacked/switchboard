import Foundation

/// The type of page that a link names.
public enum LinkKind: String, Codable, Sendable, CaseIterable {
  case slack
  case linear
  case notion
  case google
  case grafana
  /// Any other page.
  case web
}

/// The page that a link of a known kind names, parsed from its URL.
public struct LinkTarget: Equatable, Sendable {
  public var kind: LinkKind
  /// The text that two links to the same page share, such as a reply's link and its thread's link.
  public var key: String
  /// A short title built only from the parsed parts of the URL.
  public var title: String
  /// A Slack link's channel id.
  public var channel: String?
  /// A Slack link's thread: the ts of the thread's first message.
  public var thread: String?
  /// A Slack link's message ts.
  public var messageTs: String?

  /// The target of a link of a known kind, or nil for any other link. The URL can come from pasted text or from a
  /// tool that the model drives, so each kind checks the scheme, the host, and the whole path, and refuses what
  /// it does not recognize.
  public static func parse(_ url: String) -> LinkTarget? {
    guard url.count <= ExternalLink.urlLimit, let parts = URLComponents(string: url),
      parts.scheme?.lowercased() == "https", parts.user == nil, parts.password == nil,
      let host = parts.host?.lowercased(), host.allSatisfy(\.isASCII), !parts.percentEncodedPath.contains("%")
    else { return nil }
    let path = parts.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    // A path is "/" followed by non-empty segments, so a trailing slash or "//" refuses the link.
    guard path.count >= 2, path[0].isEmpty, !path.dropFirst().contains(where: \.isEmpty) else { return nil }
    let segments = Array(path.dropFirst())
    // A Slack workspace or Notion site can have "grafana" in its host name. A host that fails the Grafana parse goes
    // on to the other kinds.
    if host.contains("grafana"), let target = grafana(host: host, port: parts.port, segments) { return target }
    guard parts.port == nil else { return nil }
    switch host {
    case "linear.app": return linear(segments)
    case "docs.google.com": return google(segments)
    case "notion.so", "www.notion.so": return notion(segments)
    default:
      if isLabel(host, before: ".notion.site") { return notion(segments) }
      guard isLabel(host, before: ".slack.com") else { return nil }
      return slack(workspace: String(host.dropLast(".slack.com".count)), segments, query: parts.queryItems ?? [])
    }
  }

  /// Whether the host is one label of `[a-z0-9-]` followed by `suffix`. Every https URL in a prompt reaches this
  /// check, so it uses no regex.
  private static func isLabel(_ host: String, before suffix: String) -> Bool {
    guard host.hasSuffix(suffix) else { return false }
    let label = host.dropLast(suffix.count)
    return !label.isEmpty && label.allSatisfy { $0 == "-" || ("a"..."z").contains($0) || ("0"..."9").contains($0) }
  }

  private static func isSlug(_ text: String) -> Bool { text.wholeMatch(of: #/[A-Za-z0-9-]+/#) != nil }

  /// A slug's words: `Q4-Plan` gives `Q4 Plan`.
  private static func words(_ slug: some StringProtocol) -> String {
    slug.split(separator: "-").joined(separator: " ")
  }

  private init(
    _ kind: LinkKind, key: String, title: String, channel: String? = nil, thread: String? = nil,
    messageTs: String? = nil
  ) {
    self.kind = kind
    self.key = key
    self.title = oneLine(title, max: ExternalLink.titleLimit)
    self.channel = channel
    self.thread = thread
    self.messageTs = messageTs
  }

  /// `/archives/<channel>/p<16 digits>`, with an optional `thread_ts` that names the thread of a reply.
  private static func slack(workspace: String, _ segments: [String], query: [URLQueryItem]) -> LinkTarget? {
    guard segments.count == 3, segments[0] == "archives", segments[1].wholeMatch(of: #/[A-Z0-9]+/#) != nil,
      let digits = segments[2].wholeMatch(of: #/p([0-9]{16})/#)?.1
    else { return nil }
    let threads = query.filter { $0.name == "thread_ts" }
    guard threads.count <= 1 else { return nil }
    let messageTs = "\(digits.prefix(10)).\(digits.suffix(6))"
    var thread = messageTs
    if let given = threads.first {
      guard let value = given.value, value.wholeMatch(of: #/[0-9]{10}\.[0-9]{6}/#) != nil else { return nil }
      thread = value
    }
    let channel = segments[1]
    return LinkTarget(
      .slack, key: "slack:\(workspace)/\(channel)/\(thread)", title: "Slack thread in \(channel)", channel: channel,
      thread: thread, messageTs: messageTs)
  }

  /// `/<workspace>/issue/<KEY>`, with an optional slug after the key.
  private static func linear(_ segments: [String]) -> LinkTarget? {
    guard segments.count == 3 || (segments.count == 4 && isSlug(segments[3])), isSlug(segments[0]),
      segments[1] == "issue",
      segments[2].wholeMatch(of: #/[A-Za-z][A-Za-z0-9]*-[0-9]+/#) != nil
    else { return nil }
    let issue = segments[2].uppercased()
    return LinkTarget(.linear, key: "linear:\(segments[0].lowercased())/\(issue)", title: "Linear \(issue)")
  }

  /// `/<page>` or `/<workspace>/<page>`, where the page segment ends in the page's 32 hex digit id.
  private static func notion(_ segments: [String]) -> LinkTarget? {
    guard segments.count == 1 || (segments.count == 2 && isSlug(segments[0])),
      let page = segments.last!.wholeMatch(of: #/(?:([A-Za-z0-9-]+)-)?([0-9a-fA-F]{32})/#)
    else { return nil }
    return LinkTarget(
      .notion, key: "notion:\(page.2.lowercased())", title: page.1.map { "Notion: \(words($0))" } ?? "Notion page")
  }

  private static let googleTitles = [
    "document": "Google Doc", "spreadsheets": "Google Sheet", "presentation": "Google Slides",
  ]

  /// `/<type>/d/<id>`, with an optional `/u/<n>` account before `d` and an optional action such as `edit` after
  /// the id.
  private static func google(_ segments: [String]) -> LinkTarget? {
    guard let type = segments.first, let title = googleTitles[type] else { return nil }
    var rest = segments.dropFirst()
    if rest.first == "u" {
      guard rest.count >= 2, rest.dropFirst().first!.wholeMatch(of: #/[0-9]+/#) != nil else { return nil }
      rest = rest.dropFirst(2)
    }
    let tail = Array(rest)
    guard tail.count == 2 || (tail.count == 3 && tail[2].wholeMatch(of: #/[a-z]+/#) != nil), tail[0] == "d",
      tail[1].wholeMatch(of: #/[A-Za-z0-9_-]{10,}/#) != nil
    else { return nil }
    return LinkTarget(.google, key: "google:\(type)/\(tail[1])", title: title)
  }

  /// `/d/<uid>`, with an optional slug after the uid, on a host whose name contains `grafana`.
  private static func grafana(host: String, port: Int?, _ segments: [String]) -> LinkTarget? {
    guard segments.count == 2 || (segments.count == 3 && isSlug(segments[2])), segments[0] == "d",
      segments[1].wholeMatch(of: #/[A-Za-z0-9_-]{1,40}/#) != nil
    else { return nil }
    let uid = segments[1]
    return LinkTarget(
      .grafana, key: "grafana:\(host)\(port.map { ":\($0)" } ?? "")/\(uid)",
      title: segments.count == 3 ? "Grafana: \(words(segments[2]))" : "Grafana dashboard \(uid)")
  }
}

/// Finds the https links in free text, such as a prompt.
public enum LinkScan {
  private static let terminators = Set("<>\"'`|()[]{}\\^")
  private static let trailing = Set(".,;:!?*~")

  /// Each `https://` link in the text, in order and with repeats. A link ends at whitespace, at a control
  /// character, at a character that wraps links in Slack or Markdown text, or at the next `https://`. Trailing
  /// sentence punctuation and Markdown `*` and `~` emphasis are not part of it. A trailing `_` stays unless a `_`
  /// comes right before the link, because an id such as a Grafana uid can end in `_`. `withoutTrailingUnderscores`
  /// gives the link without it.
  public static func urls(in text: String) -> [String] {
    guard text.contains("://") else { return [] }
    var found: [String] = []
    var from = text.startIndex
    while let start = text.range(of: "https://", options: .caseInsensitive, range: from..<text.endIndex) {
      var end = start.upperBound
      while end < text.endIndex {
        let c = text[end]
        if c.isWhitespace || c.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
          || terminators.contains(c)
          || ((c == "h" || c == "H") && text[end...].prefix(8).lowercased() == "https://")
        {
          break
        }
        end = text.index(after: end)
      }
      let opener = start.lowerBound > text.startIndex ? text[text.index(before: start.lowerBound)] : nil
      var link = text[start.lowerBound..<end]
      while let last = link.last, trailing.contains(last) || (last == "_" && opener == "_") {
        link = link.dropLast()
      }
      if link.count > "https://".count { found.append(String(link)) }
      from = end
    }
    return found
  }

  /// The link without its trailing `_` and the punctuation and emphasis around them, for a link that `_` emphasis
  /// closes, such as `_see https://…_`.
  public static func withoutTrailingUnderscores(_ link: String) -> String {
    var bare = Substring(link)
    while let last = bare.last, last == "_" || trailing.contains(last) { bare = bare.dropLast() }
    return String(bare)
  }
}
