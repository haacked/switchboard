import Foundation
import SwitchboardCore

extension Service {
  /// `link-add` adds a link to a session by hand, and `link-rm` deletes an added link or hides a found one. Claude
  /// acts only on its own session. `Session.addLink` and `removeLink` refuse to let Claude remove a link the user
  /// added, hide a found link, or add back a page the user hid.
  func sessionLinkRequest(_ op: String, _ args: JSON, origin: RequestOrigin) throws -> JSON {
    let id = try lookup(args)
    let by = try Author(parsing: args["by"]?.string)
    try requireOwnSession(id, args, "add or remove links")
    let found = entries[id]?.facts.links ?? []
    var event: (kind: String, data: JSON) = ("", [:])
    try update(id) { session in
      switch op {
      case "link-add":
        switch try session.addLink(
          url: args["url"]?.string, title: args["title"]?.string, by: by, found: found, now: nowMs())
        {
        case .added(let link): event = ("link-added", ["link": try JSON(encoding: link)])
        case .unhid(let link): event = ("link-unhidden", ["link": .string(link.id)])
        }
      case "link-rm":
        switch try session.removeLink(id: args["link"]?.string ?? "", by: by, found: found) {
        case .deleted(let link): event = ("link-removed", ["link": .string(link.id)])
        case .hid(let link): event = ("link-hidden", ["link": .string(link.id), "url": .string(link.url)])
        }
      default:
        throw APIError("unknown request \(op)")
      }
    }
    record(id, event.kind, event.data)
    return try JSON(encoding: summary(id, for: origin))
  }

  /// `link-open` records that the user opened one of the session's links from Switchboard. A Slack link's new-reply
  /// mark then stays off until a newer reply. Only the user acts, so a session can't hide its own marks.
  func linkOpenRequest(_ args: JSON, origin: RequestOrigin) throws -> JSON {
    let id = try lookup(args)
    try requireUser(args, "Only you can open a link.")
    let e = entries[id]!
    let linkId = args["link"]?.string ?? ""
    guard let link = e.session.links(found: e.facts.links).first(where: { $0.id == linkId }) else {
      throw APIError("\(e.session.name) has no link \(linkId)")
    }
    record(id, "link-opened", ["link": .string(link.id), "key": .string(ExternalLink.pageKey(link.url))])
    return try JSON(encoding: summary(id, for: origin))
  }
}
