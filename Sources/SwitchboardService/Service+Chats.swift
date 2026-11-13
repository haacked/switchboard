import Foundation
import SwitchboardCore

/// Group chats. `plans/group-chats.md` in the notes repo describes them.
extension Service {
  /// The `chat` request: creates the group's chat the first time, with `text`
  /// as its first prompt. After that it sends `text` to the chat, or without
  /// text opens it (resumes a stopped claude). The answer is the chat's
  /// summary, with `delivery` when it took text.
  func chatRequest(_ args: JSON) -> Response {
    do {
      let group = try queue.sync {
        let group = try lookupGroup(args)
        try ensureChatFolder(group, description: groups[group]?.description)
        return group
      }
      let text = args["text"]?.string.flatMap { $0.isEmpty ? nil : $0 }
      if let id = queue.sync(execute: { chatID(group) }) { return try openOrSend(id, text) }
      awaitMCPServers()
      // Another request can create the chat or remove the group while this one
      // waits off the queue, so the checks run again on it.
      let (id, created, queued) = try queue.sync { () -> (String, SessionSummary?, Bool) in
        if let id = chatID(group) { return (id, nil, false) }
        guard let name = groups[group]?.name else { throw APIError("group \(group) was removed") }
        let folder = home.chatFolder(group)
        let new = NewSession(path: folder, name: Chat.name(group: name), prompt: text)
        let chat = try create(new, (folder, nil, nil)) { $0.chat = group }
        return (chat.id, chat, entries[chat.id]?.queued != nil)
      }
      guard let created else { return try openOrSend(id, text) }
      return try createdAnswer(created, text: text, queued: queued)
    } catch {
      return .failure("\(error)")
    }
  }

  /// Sends `text` to the chat, or without text opens it.
  func openOrSend(_ id: String, _ text: String?) throws -> Response {
    var request: [String: JSON] = ["session": .string(id)]
    request["text"] = text.map(JSON.string)
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
  /// `session`. It reads the transcript off the state queue.
  func chatLog(_ args: JSON) throws -> JSON {
    let (findTranscript, machine) = try queue.sync { () -> (() -> String?, any Machine) in
      let manager = args["manager"]?.bool == true
      if manager || args["session"] != nil {
        let id = manager ? try managerConversation(args["session"]?.string) : try lookup(args)
        return (transcriptFinder(id), try site(of: id).machine)
      }
      let group = try lookupGroup(args)
      guard let id = chatID(group) else {
        throw APIError("group \(groups[group]!.name) has no chat. Start it with: sb chat \(group)")
      }
      return (transcriptFinder(id), try site(of: id).machine)
    }
    let limit = args["limit"]?.int ?? 50
    return try JSON(encoding: findTranscript().map { Transcript.messages($0, limit: limit, on: machine) } ?? [])
  }

  func chatID(_ group: String) -> String? {
    entries.values.first { $0.session.chat == group }?.session.id
  }

  private func ensureChatFolder(_ group: String, description: String?) throws {
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

  /// Rewrites the group's chat guide, and tells the chat when its claude
  /// runs. A chat whose claude is not live reads the new guide when it
  /// starts. The pane reads `starting` while a stopped claude exits, so the
  /// check reads `live` and not the pane.
  func groupDescribed(_ group: String) throws {
    try refreshChatGuide(group)
    guard let id = chatID(group), let e = entries[id], !e.session.done, e.facts.live else { return }
    _ = try send(id, Chat.describedNotice(groups[group]?.description), byUser: false, trigger: .chat)
  }

  /// Marks the group's chat done, because its tools can no longer find the group.
  func retireChat(of group: String) throws {
    guard let id = chatID(group), entries[id]?.session.done == false else { return }
    try update(id) { $0.done = true }
    record(id, "done")
  }
}
