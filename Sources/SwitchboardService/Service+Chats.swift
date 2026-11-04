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
      let group = try queue.sync { try lookupGroup(args) }
      let text = args["text"]?.string.flatMap { $0.isEmpty ? nil : $0 }
      try ensureChatFolder(group)
      if let id = queue.sync(execute: { chatID(group) }) { return try openOrSend(id, text) }
      awaitMCPServers()
      // Another request can create the chat or remove the group while this one
      // waits off the queue, so the checks run again on it.
      let (chat, created) = try queue.sync { () -> (SessionSummary, Bool) in
        if let id = chatID(group) { return (summary(id), false) }
        guard let name = groups[group]?.name else { throw APIError("group \(group) was removed") }
        let folder = home.chatFolder(group)
        let new = NewSession(path: folder, name: Chat.name(group: name), prompt: text)
        return (try create(new, (folder, nil, nil)) { $0.chat = group }, true)
      }
      guard let text else { return .success(try JSON(encoding: chat)) }
      guard created else { return try openOrSend(chat.id, text) }
      return .success(try withDelivery(chat, .string(Delivery.resumed.rawValue)))
    } catch {
      return .failure("\(error)")
    }
  }

  /// Sends `text` to the chat, or without text opens it.
  private func openOrSend(_ id: String, _ text: String?) throws -> Response {
    var request: [String: JSON] = ["session": .string(id)]
    request["text"] = text.map(JSON.string)
    let response = handle(Request(op: text == nil ? "open" : "send", args: .object(request)))
    guard text != nil, let delivery = response.result?["delivery"] else { return response }
    return .success(try queue.sync { try withDelivery(summary(id), delivery) })
  }

  private func withDelivery(_ summary: SessionSummary, _ delivery: JSON) throws -> JSON {
    var object = try JSON(encoding: summary).object ?? [:]
    object["delivery"] = delivery
    return .object(object)
  }

  /// The `chat-log` request: the last messages of the group's chat, oldest
  /// first. It reads the transcript off the state queue.
  func chatLog(_ args: JSON) throws -> JSON {
    let findTranscript = try queue.sync { () -> () -> String? in
      let group = try lookupGroup(args)
      guard let id = chatID(group) else {
        throw APIError("group \(groups[group]!.name) has no chat. Start it with: sb chat \(group)")
      }
      return transcriptFinder(id)
    }
    let limit = args["limit"]?.int ?? 50
    return try JSON(encoding: findTranscript().map { Transcript.messages($0, limit: limit) } ?? [])
  }

  func chatID(_ group: String) -> String? {
    entries.values.first { $0.session.chat == group }?.session.id
  }

  private func ensureChatFolder(_ group: String) throws {
    let folder = home.chatFolder(group)
    try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    try writeGuide(Chat.guide, in: folder)
  }

  /// Rewrites CLAUDE.md in each chat folder that exists.
  func refreshChatGuides() throws {
    for name in (try? FileManager.default.contentsOfDirectory(atPath: home.chatsFolder)) ?? [] {
      let folder = home.chatFolder(name)
      if isDirectory(folder) { try writeGuide(Chat.guide, in: folder) }
    }
  }

  /// Marks the group's chat done, because its tools can no longer find the group.
  func retireChat(of group: String) throws {
    guard let id = chatID(group), entries[id]?.session.done == false else { return }
    try update(id) { $0.done = true }
    record(id, "done")
  }
}
