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
}
