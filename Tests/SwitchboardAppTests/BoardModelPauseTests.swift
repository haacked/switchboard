import AppKit
import SwitchboardCore
import Testing

@testable import SwitchboardApp

/// The app's Pause and Resume buttons. sbd refuses a request that names both a session and a group, so a session
/// button sends only `session` and a lane button sends only `group`. A one-click pause sends no reason, condition,
/// or message.
@MainActor
@Suite struct BoardModelPauseTests {
  // MARK: One session

  @Test func pauseSendsPauseForTheSession() async {
    let sent = await firstRequest { $0.pause("s1") }

    #expect(sent.op == "pause")
    #expect(sent.args["session"] == "s1")
  }

  @Test func pauseNamesNoGroup() async {
    let sent = await firstRequest { $0.pause("s1") }

    #expect(sent.args["group"] == nil)
  }

  @Test(arguments: ["reason", "until", "message"])
  func pauseSendsNoReasonConditionOrMessage(_ field: String) async {
    let sent = await firstRequest { $0.pause("s1") }

    #expect(sent.args[field] == nil)
  }

  @Test func pauseUntilSendsTheTimeAsWholeSeconds() async {
    let until = Date(timeIntervalSince1970: 1_800_000_000.7)
    let sent = await firstRequest { $0.pause("s1", until: until) }

    #expect(sent.op == "pause")
    #expect(sent.args["session"] == "s1")
    #expect(sent.args["until"] == "2027-01-15T08:00:00Z")
    #expect(sent.args["group"] == nil)
  }

  @Test func theOpenPausePickerCountsAsASheet() {
    let model = offlineModel()
    #expect(!model.presentingSheet)
    model.pickingPauseTime = "s1"
    #expect(model.presentingSheet)
  }

  @Test func theOpenNotesSheetCountsAsASheet() {
    let model = offlineModel()
    #expect(!model.presentingSheet)
    model.editingNotes = "s1"
    #expect(model.presentingSheet)
  }

  @Test func resumeStillSendsResumeForTheSession() async {
    let sent = await firstRequest { $0.resume("s1") }

    #expect(sent.op == "resume")
    #expect(sent.args["session"] == "s1")
    #expect(sent.args["group"] == nil)
  }

  @Test func aRefusedPauseShowsSbdsErrorInTheBanner() async {
    let model = offlineModel()
    model.send = { _, _ in throw Refusal(description: "s1 is a follow-up that hasn't started") }

    model.pause("s1")
    await settle { model.actionError != nil }

    #expect(model.actionError == "pause: s1 is a follow-up that hasn't started")
  }

  // MARK: A group lane

  @Test func pauseGroupSendsPauseForTheGroup() async {
    let sent = await firstRequest { $0.pauseGroup("g1") }

    #expect(sent.op == "pause")
    #expect(sent.args["group"] == "g1")
  }

  @Test func pauseGroupNamesNoSession() async {
    let sent = await firstRequest { $0.pauseGroup("g1") }

    #expect(sent.args["session"] == nil)
  }

  @Test(arguments: ["reason", "until", "message"])
  func pauseGroupSendsNoReasonConditionOrMessage(_ field: String) async {
    let sent = await firstRequest { $0.pauseGroup("g1") }

    #expect(sent.args[field] == nil)
  }

  @Test func resumeGroupSendsResumeForTheGroup() async {
    let sent = await firstRequest { $0.resumeGroup("g1") }

    #expect(sent.op == "resume")
    #expect(sent.args["group"] == "g1")
  }

  @Test func resumeGroupNamesNoSession() async {
    let sent = await firstRequest { $0.resumeGroup("g1") }

    #expect(sent.args["session"] == nil)
  }

  /// Without a message, sbd resumes each member with the message stored in its own pause.
  @Test(arguments: ["message", "prompt"])
  func resumeGroupSendsNoMessageSoEachMemberGetsItsOwn(_ field: String) async {
    let sent = await firstRequest { $0.resumeGroup("g1") }

    #expect(sent.args[field] == nil)
  }

  @Test func aRefusedGroupResumeShowsSbdsErrorInTheBanner() async {
    let model = offlineModel()
    model.send = { _, _ in throw Refusal(description: "no group named g9") }

    model.resumeGroup("g9")
    await settle { model.actionError != nil }

    #expect(model.actionError == "resume: no group named g9")
  }

  // MARK: A group reply's failed members

  static func report(_ rows: [PauseRow]) throws -> JSON {
    try JSON(encoding: PauseReport(group: "g1", name: "Flags", sessions: rows))
  }

  /// sbd answers a group pause even when every member fails, so the failures come back in its rows.
  @Test func aGroupPauseShowsEachMemberThatFailed() async throws {
    let model = offlineModel()
    let reply = try Self.report([
      PauseRow(session: "s1", name: "cache", result: .paused),
      PauseRow(session: "s2", name: "flags", result: .failed, error: "can't read host h1"),
      PauseRow(session: "s3", name: "docs", result: .skipped),
      PauseRow(session: "s4", name: "api", result: .failed, error: "s4 is a follow-up that hasn't started"),
    ])
    model.send = { _, _ in reply }

    model.pauseGroup("g1")
    await settle { model.actionError != nil }

    #expect(model.actionError == "pause: flags: can't read host h1; api: s4 is a follow-up that hasn't started")
  }

  @Test func aGroupResumeShowsEachMemberThatFailed() async throws {
    let model = offlineModel()
    let reply = try Self.report([PauseRow(session: "s1", name: "cache", result: .failed, error: "worktree is gone")])
    model.send = { _, _ in reply }

    model.resumeGroup("g1")
    await settle { model.actionError != nil }

    #expect(model.actionError == "resume: cache: worktree is gone")
  }

  @Test(arguments: [PauseRow.Result.paused, .alreadyPaused, .skipped, .resumed])
  func aGroupReplyWithoutFailuresClearsTheBanner(_ result: PauseRow.Result) async throws {
    let model = offlineModel()
    let reply = try Self.report([PauseRow(session: "s1", name: "cache", result: result)])
    model.send = { _, _ in reply }
    model.actionError = "an earlier failure"

    model.pauseGroup("g1")
    await settle { model.actionError == nil }

    #expect(model.actionError == nil)
  }
}
