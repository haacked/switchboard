import AppKit
import SwitchboardCore
import Testing

@testable import SwitchboardApp

@MainActor
@Suite struct BoardModelSlashCommandsTests {
  static let rows = [
    SlashCommand(name: "commit", description: "Commit the changes", source: .listing),
    SlashCommand(name: "probe-user-only", description: nil, source: .scan),
    SlashCommand(name: "clear", description: "Start a new conversation with empty context", source: .builtIn),
  ]

  static func answer(_ rows: [SlashCommand]) throws -> JSON {
    .object(["commands": try JSON(encoding: rows), "listing": true])
  }

  @Test func loadSlashCommandsAsksSbdForTheSessionsCommands() async {
    let sent = await firstRequest { $0.loadSlashCommands("s1") }

    #expect(sent.op == "slash-commands")
    #expect(sent.args == ["session": "s1"])
  }

  @Test func loadSlashCommandsStoresTheAnswerUnderTheSession() async throws {
    let model = offlineModel()
    let answer = try Self.answer(Self.rows)
    model.send = { op, _ in op == "slash-commands" ? answer : .null }

    model.loadSlashCommands("s1")
    await settle { model.slashCommands["s1"] != nil }

    #expect(model.slashCommands["s1"] == Self.rows)
  }

  @Test func loadSlashCommandsLeavesOtherSessionsAlone() async throws {
    let model = offlineModel()
    let other = [SlashCommand(name: "go", description: nil, source: .listing)]
    model.slashCommands["s2"] = other
    let answer = try Self.answer(Self.rows)
    model.send = { op, _ in op == "slash-commands" ? answer : .null }

    model.loadSlashCommands("s1")
    await settle { model.slashCommands["s1"] != nil }

    #expect(model.slashCommands["s2"] == other)
  }

  @Test func aNewerAnswerReplacesTheStoredRows() async throws {
    let model = offlineModel()
    model.slashCommands["s1"] = [SlashCommand(name: "stale", description: nil, source: .listing)]
    let answer = try Self.answer(Self.rows)
    model.send = { op, _ in op == "slash-commands" ? answer : .null }

    model.loadSlashCommands("s1")
    await settle { model.slashCommands["s1"] == Self.rows }

    #expect(model.slashCommands["s1"] == Self.rows)
  }

  /// The field shows the stored rows while sbd answers, so a failed request must not empty the list.
  @Test func aFailedRequestKeepsTheStoredRows() async {
    let model = offlineModel()
    let kept = [SlashCommand(name: "go", description: nil, source: .listing)]
    model.slashCommands["s1"] = kept
    let sent = Counter()
    model.send = { _, _ in
      sent.increment()
      throw Boom()
    }

    model.loadSlashCommands("s1")
    await settle { sent.value > 0 }
    try? await Task.sleep(nanoseconds: 200_000_000)

    #expect(model.slashCommands["s1"] == kept)
  }
}
