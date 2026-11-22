import CryptoKit
import Foundation

/// A Slack message that the session sent through the claude.ai Slack connector, as its hook says.
public enum SlackSendCall {
  static let toolName = "mcp__claude_ai_Slack__slack_send_message"

  /// The link and target of the message that the event records as sent, or nil for any other event. The result
  /// comes from a tool that the model drives, so each condition refuses what it does not recognize. A draft, a
  /// failure, and a result whose link does not name the message it reports add nothing.
  public static func parse(_ event: Event) -> (url: String, target: LinkTarget)? {
    guard event.kind == "PostToolUse", event.data["tool_name"]?.string == toolName,
      let result = resultObject(event.data["tool_response"]), let url = result["message_link"]?.string,
      let target = LinkTarget.parse(url), target.kind == .slack
    else { return nil }
    if let context = result["message_context"] {
      guard context["channel_id"]?.string == target.channel, context["message_ts"]?.string == target.messageTs else {
        return nil
      }
    }
    return (url, target)
  }

  /// The result's JSON object: the object itself, or the JSON text of the first text block of an MCP content array.
  private static func resultObject(_ response: JSON?) -> [String: JSON]? {
    switch response {
    case .object(let object):
      return object
    case .array(let blocks):
      guard let text = blocks.first(where: { $0["type"]?.string == "text" })?["text"]?.string else { return nil }
      return JSON.parse(text)?.object
    default:
      return nil
    }
  }
}

extension ExternalLink {
  /// The id of a link that sbd found, from its target key, so a replay gives the same id. `f` keeps it apart from
  /// the `l` ids of added links. When an id in `taken` has it already, the next try hashes the key with `#1`,
  /// `#2`, and so on.
  public static func foundId(key: String, taken: [String]) -> String {
    let alphabet = Array(ShortId.alphabet)
    var attempt = 0
    while true {
      let digest = Array(SHA256.hash(data: Data((attempt == 0 ? key : "\(key)#\(attempt)").utf8)))
      let id = "f" + String((0..<ShortId.length).map { alphabet[Int(digest[$0]) % alphabet.count] })
      if !taken.contains(id) { return id }
      attempt += 1
    }
  }
}

extension SessionFacts {
  /// Records the links of known kinds in a prompt, the link of a Slack message that the session sent, and an Open
  /// of a link from Switchboard. A link whose page the list already holds changes nothing, so the first sighting's
  /// URL and time stay.
  mutating func applyLinks(_ event: Event) {
    switch event.kind {
    case "UserPromptSubmit":
      // A subagent's result arrives as a prompt but is model output.
      guard !event.fromSubagent, let prompt = event.data["prompt"]?.string, !Attention.isSubagentResult(prompt)
      else { return }
      for found in LinkScan.urls(in: prompt) {
        // The link as found wins, because an id can end in `_`.
        for url in [found, LinkScan.withoutTrailingUnderscores(found)] {
          if let target = LinkTarget.parse(url) {
            addFoundLink(url: url, target: target, t: event.t)
            break
          }
        }
      }
    case "PostToolUse":
      if let sent = SlackSendCall.parse(event) { addFoundLink(url: sent.url, target: sent.target, t: event.t) }
    case "link-opened":
      if let key = event.data["key"]?.string { linkOpened[key] = max(linkOpened[key] ?? 0, event.t) }
    default:
      break
    }
  }

  private mutating func addFoundLink(url: String, target: LinkTarget, t: Int64) {
    guard !links.contains(where: { $0.linkTarget?.key == target.key }) else { return }
    links.append(
      ExternalLink(
        id: ExternalLink.foundId(key: target.key, taken: links.map(\.id)), title: target.title, url: url,
        by: .found, t: t))
  }
}

/// What `Session.addLink` did.
public enum LinkAdd: Equatable, Sendable {
  /// It added the link by hand.
  case added(ExternalLink)
  /// It took a hidden found link off the hidden list, and the found link lists again with its id.
  case unhid(ExternalLink)
}

/// What `Session.removeLink` did.
public enum LinkRemoval: Equatable, Sendable {
  /// It deleted a link that the user or Claude added.
  case deleted(ExternalLink)
  /// It hid a link that sbd found.
  case hid(ExternalLink)
}

extension Session {
  /// The session's links, ordered by time with found links first on a tie: the found links whose page is not
  /// hidden and whose URL no added link has, and the added links.
  public func links(found: [ExternalLink]) -> [ExternalLink] {
    guard addedLinks != nil || hiddenLinks != nil else { return found }
    let added = addedLinks ?? []
    let hidden = Set((hiddenLinks ?? []).map(ExternalLink.pageKey))
    let addedTargets = Set(added.map(\.target))
    let shown = found.filter { !hidden.contains(ExternalLink.pageKey($0.url)) && !addedTargets.contains($0.target) }
    return (shown + added).enumerated()
      .sorted { ($0.element.t, $0.offset) < ($1.element.t, $1.offset) }
      .map(\.element)
  }

  /// Adds a link by hand, or brings back a hidden found link when the user adds its URL. It refuses a URL that a
  /// listed link has. Only the user unhides, so it refuses Claude's link to a hidden page.
  public mutating func addLink(url text: String?, title: String?, by: Author, found: [ExternalLink], now: Int64)
    throws -> LinkAdd
  {
    let url = try ExternalLink.cleanURL(text)
    var link = ExternalLink(
      id: "", title: try ExternalLink.cleanTitle(title, url: url), url: url, by: LinkAuthor(by), t: now)
    if let listed = links(found: found).first(where: { $0.target == link.target }) {
      throw APIError("\(name) already has a link to \(url) (\(listed.id))")
    }
    let page = ExternalLink.pageKey(url)
    let hidden = hiddenLinks ?? []
    if by == .claude, hidden.contains(where: { ExternalLink.pageKey($0) == page }) {
      throw APIError("The user hid a link to this page. Ask the user to run sb link add")
    }
    // The check above finds every listed link, so a found link with this URL is hidden.
    if let back = found.first(where: { $0.target == link.target }) {
      let rest = hidden.filter { ExternalLink.pageKey($0) != page }
      hiddenLinks = rest.isEmpty ? nil : rest
      return .unhid(back)
    }
    let added = addedLinks ?? []
    link.id = shortId("l", taken: (found + added).map(\.id))
    addedLinks = added + [link]
    return .added(link)
  }

  /// Deletes an added link, or hides a listed found link. Claude may delete only a link that Claude added, and
  /// only the user hides. When the user deletes an added link that has a found link's URL, the found link is
  /// hidden too, so the link leaves the list.
  public mutating func removeLink(id: String, by: Author, found: [ExternalLink]) throws -> LinkRemoval {
    let added = addedLinks ?? []
    if let link = added.first(where: { $0.id == id }) {
      guard by == .you || link.by == .claude else {
        throw APIError("Only you can remove a link you added. Ask the user to run sb link rm")
      }
      let rest = added.filter { $0.id != id }
      addedLinks = rest.isEmpty ? nil : rest
      if by == .you, let shadowed = links(found: found).first(where: { $0.by == .found && $0.target == link.target }) {
        hiddenLinks = (hiddenLinks ?? []) + [shadowed.url]
      }
      return .deleted(link)
    }
    guard let link = links(found: found).first(where: { $0.id == id && $0.by == .found }) else {
      throw APIError("\(name) has no link \(id)")
    }
    guard by == .you else { throw APIError("Only you can hide a link that Switchboard found") }
    hiddenLinks = (hiddenLinks ?? []) + [link.url]
    return .hid(link)
  }
}
