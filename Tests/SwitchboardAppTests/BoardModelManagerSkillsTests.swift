import AppKit
import Foundation
import SwitchboardCore
import Testing

@testable import SwitchboardApp

/// The Message Claude field of a Manager conversation or the operator checks a draft that starts with a command
/// before it sends it. It fetches `slash-commands` again, and a row labeled `work` sets an offer in place of the
/// send: Spawn a session with this, Run here anyway, or Cancel. Any other draft, and any draft to another kind of
/// session, sends.
@MainActor
@Suite struct BoardModelManagerSkillsTests {
  static let conversation = needsItem("m", manager: true)
  static let operatorSession = operatorItem()
  static let work = needsItem("w")
  static let chat = chatItem("c", group: "g1")
  static let sessions = [conversation, operatorSession, work, chat]

  /// The rows of a Manager's `slash-commands` answer, with `go` labeled `label`.
  static func rows(go label: SkillLabel?) -> [SlashCommand] {
    [
      SlashCommand(name: "go", description: "Ship it.", source: .scan, label: label),
      SlashCommand(name: "notes", description: "Take notes.", source: .scan, label: .safe),
      SlashCommand(name: "clear", description: "Start a new conversation with empty context", source: .builtIn),
    ]
  }

  /// A model that lists `sessions` and whose `send` records every request. sbd answers `slash-commands` with
  /// `slash`, or refuses it when `slash` is nil, and answers the rest with null. With `hold`, each `slash-commands`
  /// answer waits for a signal of `hold`. With `refuseSend`, sbd refuses every `send`.
  func slashModel(slash: [SlashCommand]?, hold: DispatchSemaphore? = nil, refuseSend: Bool = false) throws
    -> (BoardModel, SentRequests)
  {
    let model = appliedModel(Self.sessions)
    let sent = SentRequests()
    let answer: JSON? = try slash.map { .object(["commands": try JSON(encoding: $0), "listing": true]) }
    model.send = { op, args in
      sent.append(op, args)
      if op == "slash-commands" {
        hold?.wait()
        guard let answer else { throw Boom() }
        return answer
      }
      if op == "send", refuseSend { throw Refusal(description: "the session is gone") }
      return .null
    }
    return (model, sent)
  }

  func draft(_ text: String) -> MessageField.Draft {
    let draft = MessageField.Draft()
    draft.text = text
    return draft
  }

  /// The `send` requests, in the order they were sent.
  func sends(_ sent: SentRequests) -> [[String: JSON]] { sent.value.filter { $0.op == "send" }.map(\.args) }

  /// The texts of the `send` requests, in the order they were sent.
  func texts(_ sent: SentRequests) -> [String] { sends(sent).compactMap { $0["text"]?.string } }

  /// Waits long enough for a send that the model would start after the `slash-commands` answer.
  func pause() async { try? await Task.sleep(nanoseconds: 200_000_000) }

  /// Submits the draft to the session and waits until the model offers a choice for it.
  func submitUntilOffer(_ model: BoardModel, _ session: String, _ draft: MessageField.Draft) async {
    model.submitChecked(session: session, draft: draft)
    await settle { model.workSkillOffers[session] != nil }
  }

  /// Submits the draft to the session and waits until the model sends it.
  func submitUntilSent(_ model: BoardModel, _ sent: SentRequests, _ session: String, _ draft: MessageField.Draft)
    async
  {
    model.submitChecked(session: session, draft: draft)
    await sent.wait(for: "send")
  }

  // MARK: A work label offers a choice

  @Test(arguments: ["m", "op"])
  func aWorkLabelSetsTheOffer(_ session: String) async throws {
    let (model, _) = try slashModel(slash: Self.rows(go: .work))

    await submitUntilOffer(model, session, draft("/go x"))

    let offer = try #require(model.workSkillOffers[session])
    #expect(offer.skill == "go")
    #expect(offer.text == "/go x")
  }

  @Test(arguments: ["m", "op"])
  func aWorkLabelSendsNothing(_ session: String) async throws {
    let (model, sent) = try slashModel(slash: Self.rows(go: .work))

    await submitUntilOffer(model, session, draft("/go x"))
    await pause()

    #expect(sends(sent).isEmpty)
  }

  @Test func aWorkLabelKeepsTheDraft() async throws {
    let (model, _) = try slashModel(slash: Self.rows(go: .work))
    let field = draft("/go x")

    await submitUntilOffer(model, "m", field)
    await pause()

    #expect(field.text == "/go x")
  }

  @Test func aWorkCommandAfterLeadingWhitespaceSetsTheOffer() async throws {
    let (model, _) = try slashModel(slash: Self.rows(go: .work))

    await submitUntilOffer(model, "m", draft("  /go x"))

    #expect(model.workSkillOffers["m"]?.skill == "go")
  }

  @Test func anOfferForOneSessionLeavesTheOtherSessionsAlone() async throws {
    let (model, _) = try slashModel(slash: Self.rows(go: .work))

    await submitUntilOffer(model, "m", draft("/go x"))

    #expect(model.workSkillOffers["op"] == nil)
  }

  // MARK: Anything else sends

  @Test(arguments: [SkillLabel.safe, nil])
  func aCommandThatIsNotLabeledWorkSends(_ label: SkillLabel?) async throws {
    let (model, sent) = try slashModel(slash: Self.rows(go: label))

    await submitUntilSent(model, sent, "m", draft("/go x"))

    #expect(texts(sent) == ["/go x"])
    #expect(model.workSkillOffers["m"] == nil)
  }

  @Test(arguments: ["/notes x", "/clear", "/unknown x"])
  func aSafeABuiltInOrAnUnknownCommandSends(_ text: String) async throws {
    let (model, sent) = try slashModel(slash: Self.rows(go: .work))

    await submitUntilSent(model, sent, "m", draft(text))

    #expect(texts(sent) == [text])
    #expect(model.workSkillOffers["m"] == nil)
  }

  @Test func aPlainSendCarriesNoRunHere() async throws {
    let (model, sent) = try slashModel(slash: Self.rows(go: nil))

    await submitUntilSent(model, sent, "m", draft("/go x"))

    #expect(sends(sent).first?["runHere"] == nil)
  }

  /// D14: a path or a doubled slash is not a command.
  @Test(arguments: ["hello", "/Users/me/notes.md", "//go", "/ go", "hello /go"])
  func aDraftWithoutACommandSendsWithoutAFetch(_ text: String) async throws {
    let (model, sent) = try slashModel(slash: Self.rows(go: .work))

    await submitUntilSent(model, sent, "m", draft(text))

    #expect(sent.ops == ["send"])
    #expect(model.workSkillOffers["m"] == nil)
  }

  @Test(arguments: ["w", "c"])
  func aWorkSessionOrAChatSendsAWorkCommandWithoutACheck(_ session: String) async throws {
    let (model, sent) = try slashModel(slash: Self.rows(go: .work))

    await submitUntilSent(model, sent, session, draft("/go x"))

    #expect(sent.ops == ["send"])
    #expect(model.workSkillOffers[session] == nil)
  }

  // MARK: The submit decides from a fresh answer

  @Test func submitFetchesTheCommandsForTheSession() async throws {
    let (model, sent) = try slashModel(slash: Self.rows(go: .work))

    await submitUntilOffer(model, "m", draft("/go x"))

    let fetch = try #require(sent.value.first { $0.op == "slash-commands" })
    #expect(fetch.args["session"] == "m")
  }

  /// Labels can land after the user typed `/`, so the rows cached then say unlabeled.
  @Test func aFetchedWorkLabelBeatsCachedUnlabeledRows() async throws {
    let (model, sent) = try slashModel(slash: Self.rows(go: .work))
    model.slashCommands["m"] = Self.rows(go: nil)

    await submitUntilOffer(model, "m", draft("/go x"))
    await pause()

    #expect(model.workSkillOffers["m"]?.skill == "go")
    #expect(sends(sent).isEmpty)
  }

  @Test func aFetchedSafeLabelBeatsCachedWorkRows() async throws {
    let (model, sent) = try slashModel(slash: Self.rows(go: .safe))
    model.slashCommands["m"] = Self.rows(go: .work)

    await submitUntilSent(model, sent, "m", draft("/go x"))

    #expect(sent.ops == ["slash-commands", "send"])
    #expect(model.workSkillOffers["m"] == nil)
  }

  @Test func theFetchedRowsReplaceTheCachedOnes() async throws {
    let (model, _) = try slashModel(slash: Self.rows(go: .work))
    model.slashCommands["m"] = Self.rows(go: nil)

    await submitUntilOffer(model, "m", draft("/go x"))
    await settle { model.slashCommands["m"] == Self.rows(go: .work) }

    #expect(model.slashCommands["m"] == Self.rows(go: .work))
  }

  @Test func aFailedFetchFallsBackToCachedWorkRows() async throws {
    let (model, sent) = try slashModel(slash: nil)
    model.slashCommands["m"] = Self.rows(go: .work)

    await submitUntilOffer(model, "m", draft("/go x"))
    await pause()

    #expect(model.workSkillOffers["m"]?.skill == "go")
    #expect(sends(sent).isEmpty)
  }

  @Test func aFailedFetchWithCachedUnlabeledRowsSends() async throws {
    let (model, sent) = try slashModel(slash: nil)
    model.slashCommands["m"] = Self.rows(go: nil)

    await submitUntilSent(model, sent, "m", draft("/go x"))

    #expect(texts(sent) == ["/go x"])
    #expect(model.workSkillOffers["m"] == nil)
  }

  @Test func aFailedFetchWithNoCachedRowsSends() async throws {
    let (model, sent) = try slashModel(slash: nil)

    await submitUntilSent(model, sent, "m", draft("/go x"))

    #expect(texts(sent) == ["/go x"])
    #expect(model.workSkillOffers["m"] == nil)
  }

  /// Claude Code loads a plugin's command by its bare name when no other command has that name.
  @Test func aBareNameOfAPluginWorkCommandSetsTheOffer() async throws {
    let rows =
      Self.rows(go: nil) + [SlashCommand(name: "p:ship", description: "Ship it.", source: .listing, label: .work)]
    let (model, sent) = try slashModel(slash: rows)

    await submitUntilOffer(model, "m", draft("/ship x"))
    await pause()

    #expect(model.workSkillOffers["m"]?.skill == "ship")
    #expect(sends(sent).isEmpty)
  }

  // MARK: Send during the read

  @Test func aDraftChangedDuringTheReadSendsNothingAndOffersNothing() async throws {
    let hold = DispatchSemaphore(value: 0)
    defer { hold.signal() }
    let (model, sent) = try slashModel(slash: Self.rows(go: .work), hold: hold)
    let field = draft("/go x")
    model.submitChecked(session: "m", draft: field)
    await sent.wait(for: "slash-commands")

    field.text = "/go y"
    hold.signal()
    await settle { !model.sending.contains("m") }
    await pause()

    #expect(sent.ops == ["slash-commands"])
    #expect(model.workSkillOffers["m"] == nil)
    #expect(field.text == "/go y")
  }

  @Test func aSecondSendDuringTheReadIsDropped() async throws {
    let hold = DispatchSemaphore(value: 0)
    defer { hold.signal() }
    let (model, sent) = try slashModel(slash: Self.rows(go: nil), hold: hold)
    let field = draft("/go x")
    model.submitChecked(session: "m", draft: field)
    await sent.wait(for: "slash-commands")

    model.submitChecked(session: "m", draft: field)
    hold.signal()
    await sent.wait(for: "send")
    await pause()

    #expect(sent.ops.filter { $0 == "slash-commands" }.count == 1)
    #expect(texts(sent) == ["/go x"])
  }

  // MARK: Run here anyway

  @Test func runHereAnywaySendsTheTextWithRunHere() async throws {
    let (model, sent) = try slashModel(slash: Self.rows(go: .work))
    let field = draft("/go x")
    await submitUntilOffer(model, "m", field)

    model.runHereAnyway("m", draft: field)
    await sent.wait(for: "send")

    let args = try #require(sends(sent).first)
    #expect(args["session"] == "m")
    #expect(args["text"] == "/go x")
    #expect(args["runHere"] == true)
  }

  @Test func runHereAnywayClosesTheOffer() async throws {
    let (model, sent) = try slashModel(slash: Self.rows(go: .work))
    let field = draft("/go x")
    await submitUntilOffer(model, "m", field)

    model.runHereAnyway("m", draft: field)
    await sent.wait(for: "send")
    await settle { model.workSkillOffers["m"] == nil }

    #expect(model.workSkillOffers["m"] == nil)
  }

  @Test func runHereAnywayClearsTheDraftOnceSbdAcceptsIt() async throws {
    let (model, _) = try slashModel(slash: Self.rows(go: .work))
    let field = draft("/go x")
    await submitUntilOffer(model, "m", field)

    model.runHereAnyway("m", draft: field)
    await settle { field.text.isEmpty }

    #expect(field.text.isEmpty)
  }

  @Test func runHereAnywaySendsOnce() async throws {
    let (model, sent) = try slashModel(slash: Self.rows(go: .work))
    let field = draft("/go x")
    await submitUntilOffer(model, "m", field)

    model.runHereAnyway("m", draft: field)
    await sent.wait(for: "send")
    await pause()

    #expect(sends(sent).count == 1)
  }

  @Test func sendWithRunHereCarriesTheFlag() async throws {
    let (model, sent) = recordingModel()

    model.send("m", "/go x", runHere: true)
    await sent.wait(for: "send")

    #expect(sent.value.first?.args["runHere"] == true)
  }

  @Test func sendWithoutRunHereCarriesNoFlag() async throws {
    let (model, sent) = recordingModel()

    model.send("m", "/go x")
    await sent.wait(for: "send")

    #expect(sent.value.first?.args["runHere"] == nil)
  }

  @Test func draftSubmitWithRunHereCarriesTheFlag() async throws {
    let (model, sent) = recordingModel()

    draft("/go x").submit("m", to: model, runHere: true)
    await sent.wait(for: "send")

    #expect(sent.value.first?.args["runHere"] == true)
  }

  // MARK: The caller's completion

  /// Waits until sbd has answered the session's `send` and the model has run what follows the answer.
  func untilAnswered(_ model: BoardModel, _ sent: SentRequests, _ session: String) async {
    await sent.wait(for: "send")
    await settle { !model.sending.contains(session) }
    await pause()
  }

  @Test(arguments: ["m", "op"])
  func aWorkLabelSetsTheOfferAndNeverRunsThen(_ session: String) async throws {
    let (model, _) = try slashModel(slash: Self.rows(go: .work))
    let ran = Counter()

    model.submitChecked(session: session, draft: draft("/go x"), then: { ran.increment() })
    await settle { model.workSkillOffers[session] != nil }
    await pause()

    #expect(model.workSkillOffers[session] != nil)
    #expect(ran.value == 0)
  }

  @Test func aDraftChangedDuringTheReadRunsNoThen() async throws {
    let hold = DispatchSemaphore(value: 0)
    defer { hold.signal() }
    let (model, sent) = try slashModel(slash: Self.rows(go: .safe), hold: hold)
    let field = draft("/go x")
    let ran = Counter()
    model.submitChecked(session: "m", draft: field, then: { ran.increment() })
    await sent.wait(for: "slash-commands")

    field.text = "/go y"
    hold.signal()
    await settle { !model.sending.contains("m") }
    await pause()

    #expect(sends(sent).isEmpty)
    #expect(ran.value == 0)
  }

  @Test func aSecondSubmitDroppedDuringTheReadRunsNoThen() async throws {
    let hold = DispatchSemaphore(value: 0)
    defer { hold.signal() }
    let (model, sent) = try slashModel(slash: Self.rows(go: .safe), hold: hold)
    let field = draft("/go x")
    let first = Counter()
    let second = Counter()
    model.submitChecked(session: "m", draft: field, then: { first.increment() })
    await sent.wait(for: "slash-commands")

    model.submitChecked(session: "m", draft: field, then: { second.increment() })
    hold.signal()
    await untilAnswered(model, sent, "m")

    #expect(first.value == 1)
    #expect(second.value == 0)
  }

  // MARK: Every path that sends runs the completion once (parity)

  /// Each way a draft reaches `draft.submit`: through the gate's read, past the gate before the read, past a failed
  /// read, to a session without a gate, and the field's plain submit.
  enum SendPath: CaseIterable {
    case managerSafeCommand, managerUnlabeledCommand, managerPlainText, operatorPlainText, failedReadWithNoRows
    case chatPlainText, chatWorkCommand, workSessionWorkCommand, plainSubmit

    var session: String {
      switch self {
      case .managerSafeCommand, .managerUnlabeledCommand, .managerPlainText, .failedReadWithNoRows: "m"
      case .operatorPlainText: "op"
      case .chatPlainText, .chatWorkCommand: "c"
      case .workSessionWorkCommand, .plainSubmit: "w"
      }
    }

    var text: String {
      switch self {
      case .managerPlainText, .operatorPlainText, .chatPlainText, .plainSubmit: "hello"
      default: "/go x"
      }
    }
  }

  /// The rows that sbd's `slash-commands` answer holds for the path, or nil when sbd refuses the read.
  func slash(for path: SendPath) -> [SlashCommand]? {
    switch path {
    case .managerSafeCommand: Self.rows(go: .safe)
    case .managerUnlabeledCommand: Self.rows(go: nil)
    case .failedReadWithNoRows: nil
    default: Self.rows(go: .work)
    }
  }

  /// Sends `path`'s text the way `path` reaches `draft.submit`.
  func submit(_ path: SendPath, to model: BoardModel, then: @escaping () -> Void) {
    if path == .plainSubmit {
      draft(path.text).submit(path.session, to: model, then: then)
    } else {
      model.submitChecked(session: path.session, draft: draft(path.text), then: then)
    }
  }

  @Test(arguments: SendPath.allCases)
  func aRefusedSendRunsNoThen(_ path: SendPath) async throws {
    let (model, sent) = try slashModel(slash: slash(for: path), refuseSend: true)
    let ran = Counter()

    submit(path, to: model, then: { ran.increment() })
    await untilAnswered(model, sent, path.session)

    #expect(texts(sent) == [path.text])
    #expect(ran.value == 0)
  }

  @Test(arguments: SendPath.allCases)
  func everyPathThatSendsRunsThenExactlyOnce(_ path: SendPath) async throws {
    let (model, sent) = try slashModel(slash: slash(for: path))
    let ran = Counter()

    submit(path, to: model, then: { ran.increment() })
    await untilAnswered(model, sent, path.session)

    #expect(texts(sent) == [path.text])
    #expect(ran.value == 1)
  }

  // MARK: Run here anyway hides the field

  /// A model whose Manager conversation `m` shows its Message Claude field and offers a choice for `/go x`.
  func offered(refuseSend: Bool = false) async throws -> (BoardModel, SentRequests, MessageField.Draft) {
    let (model, sent) = try slashModel(slash: Self.rows(go: .work), refuseSend: refuseSend)
    model.revealMessageField("m", focus: false)
    let field = model.messageDraft(for: Self.conversation)
    field.text = "/go x"
    await submitUntilOffer(model, "m", field)
    try #require(model.revealedMessageField == "m")
    return (model, sent, field)
  }

  @Test func runHereAnywayHidesTheFieldOnceSbdAcceptsIt() async throws {
    let (model, sent, field) = try await offered()

    model.runHereAnyway("m", draft: field)
    await untilAnswered(model, sent, "m")

    #expect(texts(sent) == ["/go x"])
    #expect(model.revealedMessageField == nil)
  }

  @Test func runHereAnywayKeepsTheFieldRevealedWhenSbdRefusesIt() async throws {
    let (model, sent, field) = try await offered(refuseSend: true)

    model.runHereAnyway("m", draft: field)
    await untilAnswered(model, sent, "m")

    #expect(texts(sent) == ["/go x"])
    #expect(model.revealedMessageField == "m")
  }

  // MARK: Spawn a session with this

  @Test func spawnOpensNewSessionWithThePromptAndTheConversation() async throws {
    let (model, _) = try slashModel(slash: Self.rows(go: .work))
    await submitUntilOffer(model, "m", draft("/go In haacked/switchboard, fix it."))

    model.spawnFromOffer("m")

    let request = try #require(model.newSession)
    #expect(request.prompt == "/go In haacked/switchboard, fix it.")
    #expect(request.parent == "m")
    #expect(request.fromOffer)
  }

  @Test func spawnSendsNothing() async throws {
    let (model, sent) = try slashModel(slash: Self.rows(go: .work))
    let field = draft("/go x")
    await submitUntilOffer(model, "m", field)

    model.spawnFromOffer("m")
    await pause()

    #expect(sends(sent).isEmpty)
    #expect(field.text == "/go x")
  }

  // MARK: Start empties the draft

  /// Spawn opens New Session from the offer. Start creates the session from the sheet's form.
  func startSpawnedSession(_ model: BoardModel, _ sent: SentRequests) async throws {
    model.spawnFromOffer("m")
    let form = NewSessionView.Form(request: try #require(model.newSession))
    form.pick(KnownRepo(path: "/Users/me/dev/switchboard", name: "haacked/switchboard"))
    model.create(try #require(form.request(worktree: false, groups: [])), clearingDraft: form.clearsDraft)
    await sent.wait(for: "new")
  }

  @Test func startOfASpawnedSessionEmptiesTheConversationsDraft() async throws {
    let (model, sent) = try slashModel(slash: Self.rows(go: .work))
    let field = model.messageDraft(for: Self.conversation)
    field.text = "  /go x"
    await submitUntilOffer(model, "m", field)

    try await startSpawnedSession(model, sent)
    await settle { field.text.isEmpty }

    #expect(field.text.isEmpty)
  }

  @Test func startOfASpawnedSessionKeepsADraftThatTheUserChanged() async throws {
    let (model, sent) = try slashModel(slash: Self.rows(go: .work))
    let field = model.messageDraft(for: Self.conversation)
    field.text = "/go x"
    await submitUntilOffer(model, "m", field)
    model.spawnFromOffer("m")
    field.text = "/go y"

    try await startSpawnedSession(model, sent)
    await pause()

    #expect(field.text == "/go y")
  }

  // MARK: Cancel and edits

  @Test func cancelClosesTheOfferAndKeepsTheDraft() async throws {
    let (model, sent) = try slashModel(slash: Self.rows(go: .work))
    let field = draft("/go x")
    await submitUntilOffer(model, "m", field)

    model.dismissOffer("m")
    await pause()

    #expect(model.workSkillOffers["m"] == nil)
    #expect(field.text == "/go x")
    #expect(sends(sent).isEmpty)
  }

  @Test func anEditOfTheDraftClosesTheOffer() async throws {
    let (model, _) = try slashModel(slash: Self.rows(go: .work))
    let field = draft("/go x")
    await submitUntilOffer(model, "m", field)

    field.text = "/go y"
    await settle { model.workSkillOffers["m"] == nil }

    #expect(model.workSkillOffers["m"] == nil)
  }

  @Test func emptyingTheDraftClosesTheOffer() async throws {
    let (model, _) = try slashModel(slash: Self.rows(go: .work))
    let field = draft("/go x")
    await submitUntilOffer(model, "m", field)

    field.text = ""
    await settle { model.workSkillOffers["m"] == nil }

    #expect(model.workSkillOffers["m"] == nil)
  }
}
