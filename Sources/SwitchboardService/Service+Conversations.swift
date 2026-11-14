import Foundation
import SwitchboardCore

/// The read state of group chats and Manager conversations.
/// `plans/conversations-list-chat-state.md` in the notes repo describes it.
extension Service {
  /// The `chat-read` request, which marks the replies of the chat that
  /// `group` or `session` names read, up to `replies`, or all of them without
  /// it. It refuses a request that names a `caller`, because a session could
  /// otherwise hide a chat's replies from the user. `sb` sends `caller` from
  /// `SB_SESSION_ID`, so a session that unsets it is not refused, as with
  /// `ack`. It records nothing when no new reply would be read.
  func chatReadRequest(_ args: JSON) throws -> JSON {
    if let caller = args["caller"]?.string {
      let name = entries[caller]?.session.name ?? caller
      throw APIError("\(name) can't mark a chat read. Only the user reads a chat's replies")
    }
    let id = try chatTarget(args, op: ChatActivity.readEvent)
    let e = entries[id]!
    var asked = e.facts.replies
    if let replies = args["replies"] {
      guard let n = replies.int, n >= 0 else { throw APIError("chat-read needs replies as a count of 0 or more") }
      asked = n
    }
    let read = min(asked, e.facts.replies)
    if read > (e.facts.repliesRead ?? 0) { recordRead(id, read) }
    return try JSON(encoding: summary(id))
  }

  /// Marks every reply read for each chat and conversation that has no read
  /// state. Only one from before read state lacks it. `create` records a read
  /// of 0 for each new one, so a restart keeps a new chat's unread replies.
  func migrateReadState() {
    for (id, e) in entries where e.session.kind.showsAsChat && e.facts.repliesRead == nil {
      recordRead(id, e.facts.replies)
    }
  }

  /// The `manager-pin` request, which pins the Manager conversation that
  /// `session` names to the top of the sidebar, or with `pinned` false unpins
  /// it. A pin is not activity, so it doesn't reorder the list.
  func managerPin(_ args: JSON) throws -> JSON {
    guard let ref = args["session"]?.string, !ref.isEmpty else { throw APIError("name a Manager conversation") }
    let id = try managerConversation(ref)
    let session = entries[id]!.session
    let pinned = args["pinned"]?.bool ?? true
    if (session.pinned == true) != pinned {
      try update(id) { $0.pinned = pinned ? true : nil }
      record(id, pinned ? "pinned" : "unpinned")
    }
    return try JSON(encoding: summary(id))
  }

  func recordRead(_ id: String, _ replies: Int) {
    record(id, ChatActivity.readEvent, ["replies": .number(Double(replies))])
  }
}
