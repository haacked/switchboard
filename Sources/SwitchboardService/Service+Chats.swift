import Foundation
import SwitchboardCore

/// Group chats. `plans/group-chats.md` in the notes repo describes them.
extension Service {
  /// The `chat` request. With `new`, it starts another conversation in the group chat, with `text` as its first
  /// prompt, named `name`, else the first line of `text`, else `Manager.untitled`. With `session`, it sends
  /// `text` to that chat of the group, or without text opens it. With neither, it does the same for the group's
  /// most recent chat, and starts one named `Chat.name(group:)` when the group has none. The answer is the chat's
  /// summary, with `delivery` when it took text.
  func chatRequest(_ args: JSON) -> Response {
    do {
      let group = try queue.sync {
        let group = try lookupGroup(args)
        try ensureChatFolder(group, description: groups[group]?.description)
        return group
      }
      let text = args["text"]?.string.flatMap { $0.isEmpty ? nil : $0 }
      let isNew = args["new"]?.bool == true
      let ref = args["session"]?.string.flatMap { $0.isEmpty ? nil : $0 }
      if isNew, ref != nil { throw APIError("pass session or new, not both") }
      if !isNew {
        let found = try queue.sync { () -> String? in
          if let ref { return try groupChat(ref, of: group) }
          return mostRecentChat(of: group)
        }
        if let id = found { return try openOrSend(id, text) }
      }
      awaitMCPServers()
      // Another request can create the chat or remove the group while this one
      // waits off the queue, so the checks run again on it.
      let (id, created, queued) = try queue.sync { () -> (String, SessionSummary?, Bool) in
        if !isNew, let id = mostRecentChat(of: group) { return (id, nil, false) }
        guard let groupName = groups[group]?.name else { throw APIError("group \(group) was removed") }
        let name = isNew ? args["name"]?.string.flatMap { $0.isEmpty ? nil : $0 } : Chat.name(group: groupName)
        let chat = try createConversation(chat: group, name: name, prompt: text, mcp: nil)
        return (chat.id, chat, entries[chat.id]?.queuedSince != nil)
      }
      guard let created else { return try openOrSend(id, text) }
      return try createdAnswer(created, text: text, queued: queued)
    } catch {
      return .failure("\(error)")
    }
  }

  /// Sends `text` to the chat, or without text opens it. `sender` holds the `from` and `insideClaude` of the
  /// request that carried the text, which say who wrote it.
  func openOrSend(_ id: String, _ text: String?, sender: JSON = [:]) throws -> Response {
    var request: [String: JSON] = ["session": .string(id)]
    request["text"] = text.map(JSON.string)
    request["from"] = sender["from"]
    request["insideClaude"] = sender["insideClaude"]
    let response = handle(Request(op: text == nil ? "open" : "send", args: .object(request)))
    guard text != nil, let delivery = response.result?["delivery"] else { return response }
    return .success(try queue.sync { try withDelivery(summary(id), delivery) })
  }

  /// The answer for a session that a request just created, with `text` as
  /// its first prompt when there was one.
  func createdAnswer(_ created: SessionSummary, text: String?, queued: Bool) throws -> Response {
    guard text != nil else { return .success(try JSON(encoding: created)) }
    return .success(try withDelivery(created, .string((queued ? Delivery.queued : .resumed).rawValue)))
  }

  private func withDelivery(_ summary: SessionSummary, _ delivery: JSON) throws -> JSON {
    var object = try JSON(encoding: summary).object ?? [:]
    object["delivery"] = delivery
    return .object(object)
  }

  /// The `chat-log` request: the last messages of the group's chat, or of
  /// the session that `session` names, oldest first. With `manager`, the
  /// session is a Manager conversation, and the most recent one without
  /// `session`. With `operator`, it is the operator, which the read does not
  /// create. It refuses a session that is not a Manager conversation or a
  /// group chat, unless `role` is `assistant`. That read returns only
  /// Claude's messages, which the session's terminal already shows, so it
  /// serves any session. It reads the transcript off the state queue.
  /// With `sent`, the id of a `sent` event of the session, the answer marks that message's prompt and reaches
  /// back to it, as `Transcript.messages` with a mark does. An id that names no `sent` event of the session marks
  /// nothing. `role: assistant` leaves the prompts out, so it ignores `sent`.
  func chatLog(_ args: JSON) throws -> JSON {
    let assistantOnly = args["role"]?.string == ChatMessage.Role.assistant.rawValue
    let sent: Int64?
    if assistantOnly || args["sent"] == nil {
      sent = nil
    } else if let id = args["sent"]?.int {
      sent = Int64(id)
    } else {
      throw APIError("sent is the id of a sent event")
    }
    let (findTranscript, machine, mark) = try queue.sync { () -> (() -> String?, any Machine, SentMark?) in
      let id = try chatTarget(args, op: "chat-log", anyKind: assistantOnly)
      return (transcriptFinder(id), try site(of: id).machine, try sent.flatMap { try sentMark($0, of: id) })
    }
    let limit = args["limit"]?.int ?? 50
    var messages: [ChatMessage] = []
    if let path = findTranscript() {
      // A `/clear` or a reset starts another conversation, so a mark from an earlier one names another file.
      let usable = mark.flatMap { Transcript.isFile(path, of: $0.conversation) ? $0 : nil }
      messages = Transcript.messages(path, limit: limit, mark: usable, on: machine)
    }
    return try JSON(encoding: assistantOnly ? messages.filter { $0.role == .assistant } : messages)
  }

  /// The mark of the message whose `sent` event has the id `sent`, or nil when that event is not a `sent` event
  /// of the session `id`. It runs on the state queue.
  private func sentMark(_ sent: Int64, of id: String) throws -> SentMark? {
    guard let event = try store.event(id: sent), event.session == id, event.kind == "sent",
      let text = event.data["text"]?.string
    else { return nil }
    let later = try store.events(since: sent, session: id, kinds: ["pasting", "sent"])
    return SentMark.of(sent: event, later: later, text: pastedText(text, id))
  }

  /// The session that `manager`, `session`, or `group` names, as `chat-log`
  /// and `chat-read` read them. A group that has no chat is an error, and
  /// nothing creates one. Unless `anyKind`, a session that is not a Manager
  /// conversation or a group chat is an error that names `op`.
  func chatTarget(_ args: JSON, op: String, anyKind: Bool = false) throws -> String {
    let id: String
    if args["operator"]?.bool == true {
      guard let found = operatorID() else { throw APIError("there is no operator. Start it with: sb operator") }
      id = found
    } else if args["manager"]?.bool == true {
      id = try managerConversation(args["session"]?.string)
    } else if let ref = args["session"]?.string, args["group"] != nil {
      id = try groupChat(ref, of: try lookupGroup(args))
    } else if args["session"] != nil {
      id = try lookup(args)
    } else {
      let group = try lookupGroup(args)
      guard let chat = mostRecentChat(of: group) else {
        throw APIError("group \(groups[group]!.name) has no chat. Start it with: sb chat \(group)")
      }
      id = chat
    }
    let session = entries[id]!.session
    guard anyKind || session.kind.isConversation else {
      throw APIError("\(session.name) is not a Manager conversation or a group chat. \(op) reads only those")
    }
    return id
  }

  /// The ids of the group's chats in `Chat.Order`, read from the entries without building summaries.
  func chats(of group: String) -> [String] {
    entries.values.filter { $0.session.chat == group }.sorted { chatOrder($0) < chatOrder($1) }.map(\.session.id)
  }

  /// The group's newest chat that is not done, or its newest done chat when every chat is done.
  func mostRecentChat(of group: String) -> String? {
    entries.values.lazy.filter { $0.session.chat == group }.min { chatOrder($0) < chatOrder($1) }?.session.id
  }

  private func chatOrder(_ e: Entry) -> Chat.Order {
    Chat.Order(done: e.session.done, lastActivity: e.facts.lastActivity, created: e.session.created, id: e.session.id)
  }

  /// The `chat-ls` request: the group's chats in the order of `chats(of:)`.
  func chatList(_ args: JSON) throws -> [SessionSummary] { try chats(of: lookupGroup(args)).map { summary($0) } }

  /// The chat of the group that `ref` names by id, unique id prefix, or unique name. A session that is not a chat
  /// of the group is an error.
  func groupChat(_ ref: String, of group: String) throws -> String {
    try resolveSession(ref, noun: "chat of group \(groups[group]?.name ?? group)") { $0.chat == group }
  }

  func ensureChatFolder(_ group: String, description: String?) throws {
    let folder = home.chatFolder(group)
    try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    try writeGuide(Chat.guide(description: description), in: folder)
  }

  /// Rewrites CLAUDE.md in each chat folder that exists. A folder is named
  /// for its group's id.
  func refreshChatGuides() throws {
    for name in (try? FileManager.default.contentsOfDirectory(atPath: home.chatsFolder)) ?? [] {
      try refreshChatGuide(name)
    }
  }

  /// Writes the group chat's CLAUDE.md with the group's description, when the chat's folder exists.
  private func refreshChatGuide(_ group: String) throws {
    let folder = home.chatFolder(group)
    if isDirectory(folder) { try writeGuide(Chat.guide(description: groups[group]?.description), in: folder) }
  }

  /// Rewrites the group's chat guide, and tells each chat of the group that is not done and whose claude runs. A
  /// chat whose claude is not live reads the new guide when it starts. The pane reads `starting` while a stopped
  /// claude exits, so the check reads `live` and not the pane. A failed send is logged, so the other chats still
  /// get the notice.
  func groupDescribed(_ group: String) throws {
    try refreshChatGuide(group)
    for id in chats(of: group) {
      guard let e = entries[id], !e.session.done, e.facts.live else { continue }
      do {
        _ = try send(id, Chat.describedNotice(groups[group]?.description), by: .sbd, trigger: .chat)
      } catch {
        logLine("groups: can't tell \(id) about the description of \(group): \(error)")
      }
    }
  }

  /// Marks each chat of the group done, because their tools can no longer find the group.
  func retireChats(of group: String) throws {
    for id in chats(of: group) where entries[id]?.session.done == false {
      try update(id) { $0.done = true }
      record(id, "done")
    }
  }
}
