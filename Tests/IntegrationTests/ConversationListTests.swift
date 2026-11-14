import Foundation
import SwitchboardCore
import Testing

/// Pinned Manager conversations, and the archive that a conversation enters once it is unpinned, idle, and quiet
/// for `Conversations.archiveAfterMs`. sbd stores the pin and derives the archive from its own clock.
@Suite(.blocking(timeLimit: .seconds(120))) struct ConversationListTests {
  func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T { try JSONCoding.decode(type, from: text) }

  func newConversation(_ sbd: Instance, name: String? = nil) throws -> SessionSummary {
    var args = ["manager", "new", "--json"]
    if let name { args += ["--name", name] }
    return try decode(SessionSummary.self, sbd.sb(args))
  }

  @discardableResult
  func turn(_ sbd: Instance, _ id: String, _ text: String) throws -> SessionSummary {
    try sbd.sb("send", id, text)
    return try sbd.waitFor(id, "the reply to \(text)", timeout: 30) { $0.lastReply == "Done: \(text)" }
  }

  /// A conversation whose first turn, for `text`, has ended.
  func idleConversation(_ sbd: Instance, name: String? = nil, _ text: String = "hello") throws -> SessionSummary {
    let c = try newConversation(sbd, name: name)
    try sbd.waitFor(c.id, "the stub") { $0.live }
    return try turn(sbd, c.id, text)
  }

  /// An idle conversation whose replies the user read.
  func readConversation(_ sbd: Instance, name: String) throws -> SessionSummary {
    let c = try idleConversation(sbd, name: name)
    return try decode(SessionSummary.self, sbd.sb("manager", c.id, "--read", "--json"))
  }

  func conversations(_ sbd: Instance) throws -> [SessionSummary] {
    try decode([SessionSummary].self, sbd.sb("manager", "ls", "--json"))
  }

  func listed(_ sbd: Instance, _ id: String) throws -> SessionSummary {
    try #require(try conversations(sbd).first { $0.id == id }, "\(id) is not listed")
  }

  /// The line of `sb manager ls` that names the conversation.
  func lsLine(_ sbd: Instance, _ id: String) throws -> String {
    try #require(try sbd.sb("manager", "ls").split(separator: "\n").map(String.init).first { $0.contains(id) })
  }

  func pin(_ sbd: Instance, _ id: String) throws -> SessionSummary {
    try decode(SessionSummary.self, sbd.sb("manager", "pin", id, "--json"))
  }

  func unpin(_ sbd: Instance, _ id: String) throws -> SessionSummary {
    try decode(SessionSummary.self, sbd.sb("manager", "unpin", id, "--json"))
  }

  /// Stops the session's claude and waits for its SessionEnd. That hook moves `lastActivity`, so a test that
  /// moves the clock past the archive wait stops each conversation first.
  func stopAndSettle(_ sbd: Instance, _ id: String) throws {
    let mark = try sbd.lastEventId(id)
    try sbd.sb("stop", id)
    try sbd.waitFor("the SessionEnd after the stop of \(id)", timeout: 15) {
      try sbd.events(id, after: mark).contains { $0.kind == "SessionEnd" }
    }
  }

  /// Moves sbd's clock to `offset` ms past the latest `lastActivity` of the conversations.
  func advance(_ sbd: Instance, pastActivityOf ids: [String], by offset: Int64) throws {
    let latest = try ids.map { try listed(sbd, $0).lastActivity }.max() ?? 0
    let step = latest + offset - (try sbd.now())
    try #require(step > 0, "the clock is already past the target")
    try sbd.advanceClock(step)
  }

  // MARK: Pin

  @Test func pinMarksTheConversationPinnedInTheList() throws {
    let sbd = try Instance()
    let c = try idleConversation(sbd)

    let pinned = try pin(sbd, c.id)

    #expect(pinned.pinned == true)
    #expect(try listed(sbd, c.id).pinned == true)
  }

  @Test func aPinSurvivesAnSbdRestart() throws {
    let sbd = try Instance()
    let c = try idleConversation(sbd)
    _ = try pin(sbd, c.id)

    sbd.stopSbd()
    try sbd.startSbd()

    #expect(try listed(sbd, c.id).pinned == true)
  }

  @Test func unpinClearsThePin() throws {
    let sbd = try Instance()
    let c = try idleConversation(sbd)
    _ = try pin(sbd, c.id)

    let unpinned = try unpin(sbd, c.id)

    #expect(unpinned.pinned != true)
    #expect(try listed(sbd, c.id).pinned != true)
  }

  @Test func pinAndUnpinRecordTheirEvents() throws {
    let sbd = try Instance()
    let c = try idleConversation(sbd)

    _ = try pin(sbd, c.id)
    _ = try unpin(sbd, c.id)

    let kinds = try sbd.events(c.id).map(\.kind).filter { $0 == "pinned" || $0 == "unpinned" }
    #expect(kinds == ["pinned", "unpinned"])
  }

  @Test func managerPinOnAWorkSessionFails() throws {
    let sbd = try Instance()
    let work = try sbd.new(name: "work")

    let error = failure(sbd, "manager-pin", ["session": .string(work.id), "pinned": true])
    let command = try sbd.run("manager", "pin", work.id, "--json")

    #expect(error != "no error")
    #expect(command.status != 0)
    #expect(try sbd.get(work.id).pinned != true)
  }

  @Test func managerPinOnAGroupChatFails() throws {
    let sbd = try Instance()
    _ = try decode(GroupSummary.self, sbd.sb("group", "add", "--json", "Flags"))
    let c = try decode(SessionSummary.self, sbd.sb("chat", "Flags", "--json"))

    let error = failure(sbd, "manager-pin", ["session": .string(c.id), "pinned": true])

    #expect(error != "no error")
    #expect(try sbd.get(c.id).pinned != true)
  }

  @Test func pinningTheOlderConversationLeavesTheOrderAndItsLastActivity() throws {
    let sbd = try Instance()
    let older = try idleConversation(sbd, name: "older")
    _ = try idleConversation(sbd, name: "newer")
    let before = try conversations(sbd)
    try #require(before.map(\.name) == ["newer", "older"])
    let olderBefore = try #require(before.first { $0.id == older.id })

    _ = try pin(sbd, older.id)

    let after = try conversations(sbd)
    let olderAfter = try #require(after.first { $0.id == older.id })
    #expect(after.map(\.id) == before.map(\.id))
    #expect(olderAfter.lastActivity == olderBefore.lastActivity)
    #expect(olderAfter.state == olderBefore.state)
    #expect(olderAfter.since == olderBefore.since)
  }

  @Test func managerLsTextNamesAPinnedConversation() throws {
    let sbd = try Instance()
    let c = try idleConversation(sbd)
    _ = try pin(sbd, c.id)

    #expect(try lsLine(sbd, c.id).contains("pinned"))
  }

  // MARK: Archive

  /// The archive reads the conversation's mark. A pinned one, an unread one, and one with a send card stay out.
  /// A send card expires after an hour, so the card opens after the clock moves, and the test checks that the
  /// conversation was archived before it.
  @Test func anIdleReadConversationIsArchivedAfterTheArchiveWaitAndTheOthersAreNot() throws {
    let sbd = try Instance()
    let member = try sbd.new(name: "member")
    let flags = try decode(GroupSummary.self, sbd.sb("group", "add", "--json", "Flags", member.id))
    let idle = try readConversation(sbd, name: "idle")
    let pinned = try readConversation(sbd, name: "pinned")
    _ = try pin(sbd, pinned.id)
    let unread = try idleConversation(sbd, name: "unread")
    let carded = try readConversation(sbd, name: "carded")
    let ids = [idle.id, pinned.id, unread.id, carded.id]
    for id in ids { try stopAndSettle(sbd, id) }
    try #require(try listed(sbd, unread.id).activity?.unread == 1)

    try advance(sbd, pastActivityOf: ids, by: Conversations.archiveAfterMs + 1)

    #expect(try listed(sbd, idle.id).activity?.archived == true)
    #expect(try listed(sbd, pinned.id).activity?.archived != true)
    #expect(try listed(sbd, unread.id).activity?.archived != true)
    try #require(try listed(sbd, carded.id).activity?.archived == true)

    _ = try sbd.client.call(
      "send-group",
      ["group": .string(flags.id), "text": "rebase on main", "from": .string(carded.id), "confirmed": true])

    let withCard = try listed(sbd, carded.id)
    #expect(withCard.cards.map(\.kind) == [.send])
    #expect(withCard.activity?.archived != true)
  }

  @Test func managerLsTextNamesAnArchivedConversation() throws {
    let sbd = try Instance()
    let c = try readConversation(sbd, name: "idle")
    try stopAndSettle(sbd, c.id)

    try advance(sbd, pastActivityOf: [c.id], by: Conversations.archiveAfterMs + 1)

    #expect(try lsLine(sbd, c.id).contains("archived"))
  }

  @Test func anIdleReadConversationIsNotArchivedOneMinuteBeforeTheArchiveWait() throws {
    let sbd = try Instance()
    let c = try readConversation(sbd, name: "idle")
    try stopAndSettle(sbd, c.id)

    try advance(sbd, pastActivityOf: [c.id], by: Conversations.archiveAfterMs - 60_000)

    #expect(try listed(sbd, c.id).activity?.archived != true)
  }

  @Test func aMessageToAnArchivedConversationTakesItOutOfTheArchive() throws {
    let sbd = try Instance()
    let c = try readConversation(sbd, name: "idle")
    try stopAndSettle(sbd, c.id)
    try advance(sbd, pastActivityOf: [c.id], by: Conversations.archiveAfterMs + 1)
    try #require(try listed(sbd, c.id).activity?.archived == true)

    try turn(sbd, c.id, "again")
    let unread = try listed(sbd, c.id)
    let read = try decode(SessionSummary.self, sbd.sb("manager", c.id, "--read", "--json"))

    #expect(unread.activity?.archived != true)
    #expect(read.activity?.unread == 0)
    #expect(read.activity?.archived != true)
    #expect(try listed(sbd, c.id).activity?.archived != true)
  }

  /// Pinning is not activity, so it does not move the archive clock either. Unpinning an old conversation
  /// archives it at once.
  @Test func unpinningAnOldConversationArchivesItAtOnce() throws {
    let sbd = try Instance()
    let c = try readConversation(sbd, name: "idle")
    _ = try pin(sbd, c.id)
    try stopAndSettle(sbd, c.id)
    try advance(sbd, pastActivityOf: [c.id], by: Conversations.archiveAfterMs + 1)
    try #require(try listed(sbd, c.id).activity?.archived != true)

    _ = try unpin(sbd, c.id)

    #expect(try listed(sbd, c.id).activity?.archived == true)
  }

  @Test func aGroupChatIsNeverArchived() throws {
    let sbd = try Instance()
    _ = try decode(GroupSummary.self, sbd.sb("group", "add", "--json", "Flags"))
    let id = try #require(try decode(JSON.self, sbd.sb("chat", "Flags", "--send", "hello", "--json"))["id"]?.string)
    try sbd.waitFor(id, "the reply") { $0.lastReply == "Done: hello" }
    _ = try sbd.sb("chat", "Flags", "--read")
    try stopAndSettle(sbd, id)
    let lastActivity = try sbd.get(id).lastActivity
    try sbd.advanceClock(lastActivity + Conversations.archiveAfterMs + 1 - (try sbd.now()))

    #expect(try sbd.get(id).activity?.archived != true)
  }
}
