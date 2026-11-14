import Foundation
import SwitchboardCore

/// The read state of group chats and Manager conversations.
/// `plans/conversations-list-chat-state.md` in the notes repo describes it.
extension Service {
  /// The `chat-read` request, which marks the replies of the chat that
  /// `group` or `session` names read, up to `replies`, or all of them without
  /// it. Only the user marks a chat read, so it refuses any request from a
  /// session: a session could otherwise hide a chat's replies from the user.
  /// It records nothing when no new reply would be read.
  func chatReadRequest(_ args: JSON) throws -> JSON {
    if let caller = args["caller"]?.string {
      let name = entries[caller]?.session.name ?? caller
      throw APIError("\(name) can't mark a chat read. Only the user reads a chat's replies")
    }
    let id = try chatTarget(args)
    let e = entries[id]!
    guard e.session.kind.showsAsChat else {
      throw APIError("\(e.session.name) is not a Manager conversation or a group chat. chat-read reads only those")
    }
    let read = min(args["replies"]?.int ?? e.facts.replies, e.facts.replies)
    if read > (e.facts.repliesRead ?? 0) { recordRead(id, read) }
    return try JSON(encoding: summary(id))
  }

  /// The session that `manager`, `session`, or `group` names, as `chat-log`
  /// and `chat-read` read them. A group that has no chat is an error, and
  /// nothing creates one.
  func chatTarget(_ args: JSON) throws -> String {
    if args["manager"]?.bool == true { return try managerConversation(args["session"]?.string) }
    if args["session"] != nil { return try lookup(args) }
    let group = try lookupGroup(args)
    guard let chat = chatID(group) else {
      throw APIError("group \(groups[group]!.name) has no chat. Start it with: sb chat \(group)")
    }
    return chat
  }

  /// Marks every reply of each chat and conversation read that has no read
  /// state, which only one from before read state can lack. `create` records a
  /// read of 0 for each new one, so a restart keeps a new chat's unread replies.
  func migrateReadState() {
    for (id, e) in entries where e.session.kind.showsAsChat && e.facts.repliesRead == nil {
      recordRead(id, e.facts.replies)
    }
  }

  /// The `manager-pin` request, which pins the Manager conversation that
  /// `session` names to the top of the sidebar, or with `pinned` false unpins
  /// it. A pin is not activity, so it doesn't reorder the list.
  func managerPin(_ args: JSON) throws -> JSON {
    let id = try lookup(args)
    let session = entries[id]!.session
    guard session.kind == .manager else {
      throw APIError("\(session.name) is not a Manager conversation. Only a conversation can be pinned")
    }
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
