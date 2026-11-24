import Foundation
import Testing

@testable import SwitchboardCore

// MARK: Fixtures

/// A PR #42 whose Depot run failed on its head commit outside Trunk's queue.
private func depotPR() -> PullRequest {
  withDepot(samplePR(checks: "PENDING"), sampleDepot(["Django Tests Pass on Depot", "Lint"]))
}

/// A session whose turn ended with `reply`, after which the poller read the failed Depot run.
private func depotFacts(_ reply: String) throws -> SessionFacts {
  try prFacts(depotPR(), reply: reply)
}

private func depotVerdict(_ f: SessionFacts, session s: Session = session()) throws -> Verdict {
  let v = Attention.evaluate(s, f, now: 10)
  try #require(v.reason.hasPrefix("fix Depot CI on #42"), "the fixture gave \(v.state): \(v.reason)")
  return v
}

/// The Depot CI rule item that sbd builds for a work session whose last reply is `reply`.
private func depotItem(_ reply: String) throws -> (item: TriageItem, verdict: Verdict) {
  let f = try depotFacts(reply)
  let v = try depotVerdict(f)
  let built = try #require(Triage.item(f, v, kind: .work))
  try #require(built.source == .rule)
  return (built, v)
}

/// The question or offer that `Attention.classify` finds in the reply.
private func classified(_ reply: String) -> String? {
  switch Attention.classify(reply) {
  case .question(let q): q
  case .offer(let o): o
  case .other: nil
  }
}

private let askPrefix = "The session asked: "

private func isAsk(_ callout: Callout) -> Bool { callout.title.hasPrefix(askPrefix) }

private func hasAsk(_ item: TriageItem) -> Bool { item.callouts.contains(where: isAsk) }

private let yes = TriageOption(label: "Yes", action: .send, message: "Yes", recommended: true)
private let no = TriageOption(label: "No", action: .send, message: "No")

private func demoted(_ options: [TriageOption]) -> [TriageOption] {
  options.map { option in
    var option = option
    option.recommended = false
    return option
  }
}

private let yesNoOffer = "I pushed the fix.\n\nWant me to push the tag too?"
private let choiceOffer = "I fixed it.\n\nShould I push now or wait for CI?"
private let nextStep = "Done. Tests pass.\n\nNext, I'll update the docs."
private let yesNoLikeQuestion = "I checked.\n\nIs the staging deploy done?"
private let asksNothing = "I fixed the test. It passes."

/// A reply of exactly `count` characters whose last paragraph is `tail`.
private func sizedReply(characters count: Int, ending tail: String) -> String {
  let end = "\n\n" + tail
  return String(repeating: "a", count: count - end.count) + end
}

/// A reply of exactly `count` lines, none blank, whose last line is `last`.
private func sizedReply(lines count: Int, ending last: String) -> String {
  ((1..<count).map { "Line \($0)." } + [last]).joined(separator: "\n")
}

private func sourced(_ source: TriageSource, decisions: [PendingDecision] = []) -> TriageItem {
  TriageItem(title: "Pick a database", kind: .info, summary: "It did the work.", decisions: decisions, source: source)
}

/// A rule item that carries the question callout that `addReplyAsk` adds for `reply`.
private func ruleAsking(_ reply: String) -> TriageItem {
  var item = sourced(.rule)
  item.callouts = [Callout(kind: .decision, title: askPrefix + (classified(reply) ?? ""))]
  return item
}

private let decision = PendingDecision(
  number: 1, header: "Name", question: "Hub or Switchboard?",
  options: [PendingDecision.Option(label: "Hub"), PendingDecision.Option(label: "Switchboard", recommended: true)])

// MARK: Short reply limits

@Suite struct TriageReplyLimits {
  @Test func aShortReplyHasAtMostTwelveHundredCharactersAndTwentyLines() {
    #expect(Triage.wholeReplyCharacters == 1_200)
    #expect(Triage.wholeReplyLines == 20)
  }
}

// MARK: Triage.replyPresentation

@Suite struct TriageReplyPresentation {
  static let modelSources: [TriageSource] = [.summary, .fallback]

  @Test(arguments: modelSources)
  func aShortReplyReplacesTheSummary(_ source: TriageSource) {
    let p = Triage.replyPresentation(item: sourced(source), reply: asksNothing, listOpen: false)

    #expect(p == .replacesSummary)
  }

  @Test(arguments: modelSources)
  func aShortReplyThatAsksStillReplacesTheSummary(_ source: TriageSource) {
    let p = Triage.replyPresentation(item: sourced(source), reply: yesNoOffer, listOpen: false)

    #expect(p == .replacesSummary)
  }

  @Test(arguments: modelSources)
  func aReplyOfExactlyTheCharacterLimitReplacesTheSummary(_ source: TriageSource) throws {
    let text = sizedReply(characters: Triage.wholeReplyCharacters, ending: "Done.")
    try #require(text.count == 1_200)

    let p = Triage.replyPresentation(item: sourced(source), reply: text, listOpen: false)

    #expect(p == .replacesSummary)
  }

  @Test(arguments: modelSources)
  func aReplyOneCharacterOverTheLimitIsCollapsed(_ source: TriageSource) throws {
    let text = sizedReply(characters: Triage.wholeReplyCharacters + 1, ending: "Done.")
    try #require(text.count == 1_201)

    let p = Triage.replyPresentation(item: sourced(source), reply: text, listOpen: false)

    #expect(p == .collapsed)
  }

  @Test(arguments: modelSources)
  func aReplyOfExactlyTheLineLimitReplacesTheSummary(_ source: TriageSource) throws {
    let text = sizedReply(lines: Triage.wholeReplyLines, ending: "Done.")
    try #require(text.components(separatedBy: "\n").count == 20)

    let p = Triage.replyPresentation(item: sourced(source), reply: text, listOpen: false)

    #expect(p == .replacesSummary)
  }

  @Test(arguments: modelSources)
  func aReplyOneLineOverTheLimitIsCollapsed(_ source: TriageSource) throws {
    let text = sizedReply(lines: Triage.wholeReplyLines + 1, ending: "Done.")
    try #require(text.components(separatedBy: "\n").count == 21)
    try #require(text.count < Triage.wholeReplyCharacters)

    let p = Triage.replyPresentation(item: sourced(source), reply: text, listOpen: false)

    #expect(p == .collapsed)
  }

  /// The limits apply after trimming, so whitespace around a reply at the limit doesn't make it long.
  @Test func aReplyAtTheCharacterLimitWithSurroundingWhitespaceIsShort() {
    let text = "  \n" + sizedReply(characters: Triage.wholeReplyCharacters, ending: "Done.") + "\n\n  \n"

    let p = Triage.replyPresentation(item: sourced(.summary), reply: text, listOpen: false)

    #expect(p == .replacesSummary)
  }

  @Test func aReplyAtTheLineLimitWithTrailingBlankLinesIsShort() {
    let text = "\n" + sizedReply(lines: Triage.wholeReplyLines, ending: "Done.") + "\n\n\n"

    let p = Triage.replyPresentation(item: sourced(.summary), reply: text, listOpen: false)

    #expect(p == .replacesSummary)
  }

  @Test(
    arguments: [TriageSource.summary, .fallback, .session, .rule, .card, .report], ["", "   ", "  \n\t\n "])
  func anEmptyOrBlankReplyShowsNothing(_ source: TriageSource, _ text: String) {
    let p = Triage.replyPresentation(item: sourced(source), reply: text, listOpen: false)

    #expect(p == .none)
  }

  @Test(arguments: modelSources)
  func aShortReplyWhileADecisionListIsOpenIsCollapsed(_ source: TriageSource) {
    let p = Triage.replyPresentation(item: sourced(source), reply: asksNothing, listOpen: true)

    #expect(p == .collapsed)
  }

  @Test(arguments: modelSources)
  func aShortReplyOnAnItemWithDecisionsIsCollapsed(_ source: TriageSource) {
    let p = Triage.replyPresentation(item: sourced(source, decisions: [decision]), reply: asksNothing, listOpen: false)

    #expect(p == .collapsed)
  }

  /// A card that the session wrote on purpose keeps its summary, whatever the reply's length.
  @Test(arguments: [asksNothing, yesNoOffer, sizedReply(characters: 1_201, ending: "Done.")])
  func aSessionCardCollapsesTheReply(_ text: String) {
    let p = Triage.replyPresentation(item: sourced(.session), reply: text, listOpen: false)

    #expect(p == .collapsed)
  }

  @Test(arguments: [yesNoOffer, proseQuestion, choiceOffer])
  func aRuleItemWhoseShortReplyAsksIsExpanded(_ text: String) {
    let p = Triage.replyPresentation(item: ruleAsking(text), reply: text, listOpen: false)

    #expect(p == .expanded)
  }

  @Test func aRuleItemWhoseAskingReplyIsExactlyTheCharacterLimitIsExpanded() throws {
    let text = sizedReply(characters: Triage.wholeReplyCharacters, ending: "Want me to push?")
    try #require(text.count == 1_200)

    let p = Triage.replyPresentation(item: ruleAsking(text), reply: text, listOpen: false)

    #expect(p == .expanded)
  }

  @Test func aRuleItemWhoseAskingReplyIsOneCharacterOverTheLimitIsCollapsed() throws {
    let text = sizedReply(characters: Triage.wholeReplyCharacters + 1, ending: "Want me to push?")
    try #require(text.count == 1_201)

    let p = Triage.replyPresentation(item: ruleAsking(text), reply: text, listOpen: false)

    #expect(p == .collapsed)
  }

  @Test func aRuleItemWhoseAskingReplyIsExactlyTheLineLimitIsExpanded() {
    let text = sizedReply(lines: Triage.wholeReplyLines, ending: "Want me to push?")

    let p = Triage.replyPresentation(item: ruleAsking(text), reply: text, listOpen: false)

    #expect(p == .expanded)
  }

  @Test func aRuleItemWhoseAskingReplyIsOneLineOverTheLimitIsCollapsed() {
    let text = sizedReply(lines: Triage.wholeReplyLines + 1, ending: "Want me to push?")

    let p = Triage.replyPresentation(item: ruleAsking(text), reply: text, listOpen: false)

    #expect(p == .collapsed)
  }

  /// A rule item whose reply asks nothing leaves the reply in Details, however long it is.
  @Test(arguments: [
    asksNothing, sizedReply(characters: 1_201, ending: "Done."), sizedReply(lines: 21, ending: "Done."),
  ])
  func aRuleItemWhoseReplyAsksNothingShowsNothing(_ text: String) {
    let p = Triage.replyPresentation(item: sourced(.rule), reply: text, listOpen: false)

    #expect(p == .none)
  }

  @Test(
    arguments: [TriageSource.card, .report],
    [asksNothing, yesNoOffer, proseQuestion, sizedReply(characters: 1_201, ending: "Done.")])
  func cardsAndReportsShowNoReply(_ source: TriageSource, _ text: String) {
    let p = Triage.replyPresentation(item: sourced(source), reply: text, listOpen: false)

    #expect(p == .none)
  }

  /// The issue comment's case: the Depot CI item shows the reply that asks to queue the PR.
  @Test func theDepotItemWithTheFixtureReplyIsExpanded() throws {
    let text = try replyFixture("rule-hides-question")
    let (built, _) = try depotItem(text)

    let p = Triage.replyPresentation(item: built, reply: text, listOpen: false)

    #expect(p == .expanded)
  }
}

// MARK: Triage.replyAsk

@Suite struct TriageReplyAsk {
  @Test func aQuestionReplyGivesItsQuestion() {
    #expect(Triage.replyAsk(proseQuestion) == "Which database should I use, Postgres or SQLite?")
  }

  @Test func anOfferReplyGivesItsOffer() throws {
    #expect(Triage.replyAsk(try replyFixture("offer-delete-branch")) == "Do you want me to delete it?")
  }

  @Test func theRuleHidesQuestionFixtureGivesItsLastQuestion() throws {
    let ask = try #require(Triage.replyAsk(try replyFixture("rule-hides-question")))

    #expect(ask.hasPrefix("Do you want me to watch CI and queue it with"))
    #expect(ask.hasSuffix("once it's green?"))
  }

  @Test(arguments: ["", "   ", "\n\n", asksNothing, "Pushed."])
  func aReplyThatAsksNothingGivesNil(_ text: String) {
    #expect(Triage.replyAsk(text) == nil)
  }

  @Test(arguments: TriageReplyParity.replies)
  func replyAskIsWhatClassifyFinds(_ text: String) {
    #expect(Triage.replyAsk(text) == classified(text))
  }
}

// MARK: The question on a rule item

@Suite struct TriageReplyRuleQuestion {
  @Test func theDepotItemLeadsWithTheFixturesQuestion() throws {
    let text = try replyFixture("rule-hides-question")
    let ask = try #require(classified(text))

    let (built, _) = try depotItem(text)

    #expect(built.callouts.first == Callout(kind: .decision, title: askPrefix + ask))
  }

  @Test func theQuestionCalloutNamesTheTrunkQueue() throws {
    let (built, _) = try depotItem(try replyFixture("rule-hides-question"))

    let first = try #require(built.callouts.first)
    #expect(first.title.hasPrefix("The session asked: Do you want me to watch CI and queue it with"))
    #expect(first.title.hasSuffix("once it's green?"))
  }

  @Test func theRulesOwnCalloutsFollowTheQuestion() throws {
    let (built, v) = try depotItem(try replyFixture("rule-hides-question"))

    #expect(Array(built.callouts.dropFirst()) == v.callouts)
  }

  @Test func theItemKeepsTheRulesTitleAndKind() throws {
    let (built, v) = try depotItem(try replyFixture("rule-hides-question"))

    #expect(built.title == Triage.ruleTitle(v.reason))
    #expect(built.kind == v.kind)
  }

  @Test func aYesNoOfferPutsYesAndNoBeforeTheRulesDemotedOptions() throws {
    let (built, v) = try depotItem(try replyFixture("rule-hides-question"))

    #expect(built.options == [yes, no] + demoted(v.options))
  }

  @Test func aYesNoOfferMakesYesTheMainOption() throws {
    let (built, _) = try depotItem(try replyFixture("rule-hides-question"))

    #expect(built.primary == yes)
    #expect(built.primaryIndex == 0)
  }

  @Test func aYesNoOfferLeavesTheRulesOptionSecondToYesAndNo() throws {
    let (built, v) = try depotItem(yesNoOffer)
    let rule = try #require(v.options.first)
    try #require(rule.recommended, "the Depot rule's option is recommended before the ask")

    #expect(built.options.map(\.label) == ["Yes", "No", rule.label])
    #expect(built.options.filter(\.recommended).map(\.label) == ["Yes"])
  }

  @Test(arguments: [proseQuestion, choiceOffer, nextStep, yesNoLikeQuestion])
  func aNonYesNoAskAddsTheCalloutFirst(_ text: String) throws {
    let ask = try #require(classified(text))

    let (built, _) = try depotItem(text)

    #expect(built.callouts.first == Callout(kind: .decision, title: askPrefix + ask))
  }

  /// Only an offer that a yes or no answers gets buttons. A question, even one that reads as yes or no, gets none.
  @Test(arguments: [proseQuestion, choiceOffer, nextStep, yesNoLikeQuestion])
  func aNonYesNoAskAddsNoButtons(_ text: String) throws {
    let (built, v) = try depotItem(text)

    #expect(built.options.map(\.label) == v.options.map(\.label))
  }

  @Test(arguments: [proseQuestion, choiceOffer, nextStep, yesNoLikeQuestion])
  func aNonYesNoAskDemotesEveryRuleOption(_ text: String) throws {
    let (built, v) = try depotItem(text)

    #expect(built.options == demoted(v.options))
  }

  /// Decision 20: rule options lose `recommended`, so a rule with several options has no main button.
  @Test(arguments: [proseQuestion, choiceOffer, nextStep, yesNoLikeQuestion])
  func aNonYesNoAskLeavesNoMainButton(_ text: String) throws {
    let f = try depotFacts(text)
    let options = [
      TriageOption(
        label: "Fix the checks", action: .send, message: "Fix the failing Depot CI on #42.", recommended: true),
      TriageOption(label: "Done", action: .done),
    ]
    let v = Verdict(state: .needsYou, reason: "fix Depot CI on #42: tests", options: options)

    let built = try #require(Triage.item(f, v, kind: .work))

    try #require(built.source == .rule)
    #expect(built.options == demoted(options))
    #expect(built.primary == nil)
  }

  /// Decision 20: a lone rule option stays the main button through `TriageItem.primary`'s only-option rule.
  @Test(arguments: [proseQuestion, choiceOffer, nextStep, yesNoLikeQuestion])
  func aNonYesNoAskKeepsALoneRuleOptionAsTheMainButton(_ text: String) throws {
    let (built, v) = try depotItem(text)
    try #require(v.options.count == 1)

    #expect(built.primary == demoted(v.options).first)
  }

  @Test func aLongQuestionCutsTheCalloutTitleAtAHundredAndTwentyCharacters() throws {
    let offer = "Do you want me to " + String(repeating: "update the flag cache ", count: 8) + "now?"
    let (built, _) = try depotItem("Done.\n\n" + offer)

    let first = try #require(built.callouts.first)
    #expect(first.kind == .decision)
    #expect(first.title.count == 120)
    #expect(first.title.hasPrefix("The session asked: Do you want me to update"))
    #expect(first.title.hasSuffix("…"))
  }

  /// A wait's `notify` outcome is a rule item too, and its reply's question leads.
  @Test func aWaitOutcomeItemLeadsWithTheQuestion() throws {
    let text = try replyFixture("rule-hides-question")
    var f = facts([event("UserPromptSubmit", 0, ["prompt": "go"]), stop(2, 1, text)])
    f.waitOutcome = "CI passed on #4"

    let built = try #require(item(f))

    try #require(built.source == .rule)
    #expect(built.callouts.first == Callout(kind: .decision, title: askPrefix + (classified(text) ?? "")))
  }
}

// MARK: Where the question is not added

@Suite struct TriageReplyRuleGuards {
  @Test(arguments: [asksNothing, "Pushed."])
  func aReplyThatAsksNothingLeavesTheRuleItemAsItIs(_ text: String) throws {
    let (built, v) = try depotItem(text)

    #expect(built.callouts == v.callouts)
    #expect(built.options == v.options)
  }

  @Test(arguments: ["", "   ", "\n\n \n"])
  func anEmptyReplyLeavesTheRuleItemAsItIs(_ text: String) throws {
    let (built, v) = try depotItem(text)

    #expect(built.callouts == v.callouts)
    #expect(built.options == v.options)
  }

  /// A prompt starts a turn, so the reply's question is no longer open.
  @Test func whileATurnRunsTheRuleItemGetsNoQuestion() throws {
    let text = try replyFixture("rule-hides-question")
    var f = try depotFacts(text)
    let v = try depotVerdict(f)
    f.apply(event("UserPromptSubmit", 3, ["prompt": "watch CI"]))
    try #require(f.turnRunning)
    try #require(f.lastReply == text, "the prompt kept the reply that asks")

    let built = try #require(Triage.item(f, v, kind: .work))

    try #require(built.source == .rule)
    #expect(!hasAsk(built))
    #expect(built.options == v.options)
  }

  /// A turn that ends without a Stop keeps the reply that the prompt answered.
  @Test(arguments: [
    event("StopFailure", 4, ["error": "rate_limit"]), event("idle", 4), event("exited", 4), event("stopped", 4),
  ])
  func aTurnThatEndsWithoutAStopLeavesTheAnsweredQuestionOff(_ end: Event) throws {
    let text = try replyFixture("rule-hides-question")
    var f = try depotFacts(text)
    let v = try depotVerdict(f)
    f.apply(event("UserPromptSubmit", 3, ["prompt": "Yes"]))
    f.apply(end)
    try #require(!f.turnRunning)
    try #require(f.lastReply == text, "the turn's end kept the reply that asks")

    let built = try #require(Triage.item(f, v, kind: .work))

    try #require(built.source == .rule)
    #expect(!hasAsk(built))
    #expect(built.options == v.options)
  }

  @Test func aStopAfterThePromptOpensTheNewReplysQuestion() throws {
    var f = try depotFacts(asksNothing)
    let v = try depotVerdict(f)
    f.apply(event("UserPromptSubmit", 3, ["prompt": "go on"]))
    f.apply(event("Stop", 4, ["last_assistant_message": .string(yesNoOffer)]))

    let built = try #require(Triage.item(f, v, kind: .work))

    #expect(hasAsk(built))
  }

  @Test func anImportedReplysQuestionIsOpen() throws {
    var f = try depotFacts(asksNothing)
    let v = try depotVerdict(f)
    f.apply(event("UserPromptSubmit", 3, ["prompt": "go on"]))
    f.apply(event("idle", 4))
    f.apply(event("imported", 5, ["lastReply": .string(yesNoOffer), "hasReplies": .bool(true)]))
    try #require(!f.turnRunning)

    let built = try #require(Triage.item(f, v, kind: .work))

    #expect(hasAsk(built))
  }

  /// A Stop that sbd never saw leaves the transcript's reply for `reconciled` to recover.
  @Test func aReconciledReplysQuestionIsOpen() throws {
    var f = try depotFacts(asksNothing)
    let v = try depotVerdict(f)
    f.apply(event("UserPromptSubmit", 3, ["prompt": "go on"]))
    f.apply(event("idle", 4))
    f.apply(event("reconciled", 5, ["lastReply": .string(yesNoOffer)]))
    try #require(!f.turnRunning)

    let built = try #require(Triage.item(f, v, kind: .work))

    #expect(hasAsk(built))
  }

  @Test func aReconciledCopyOfTheAnsweredReplyKeepsItAnswered() throws {
    var f = try depotFacts(yesNoOffer)
    let v = try depotVerdict(f)
    f.apply(event("UserPromptSubmit", 3, ["prompt": "Yes"]))
    f.apply(event("reconciled", 4, ["lastReply": .string(yesNoOffer)]))
    f.apply(event("idle", 5))
    try #require(!f.turnRunning)

    let built = try #require(Triage.item(f, v, kind: .work))

    #expect(!hasAsk(built))
  }

  @Test func aCardItemGetsNoQuestion() throws {
    var f = try depotFacts(try replyFixture("rule-hides-question"))
    let v = try depotVerdict(f)
    f.cards = facts(permissionTurn()).cards
    try #require(!f.cards.isEmpty)
    try #require(!f.turnRunning)

    let built = try #require(Triage.item(f, v, kind: .work))

    try #require(built.source == .card)
    #expect(!hasAsk(built))
    #expect(built.options.map(\.label) == ["Allow", "Deny"])
  }

  @Test func aSessionCardGetsNoQuestion() throws {
    let f = facts([
      event("UserPromptSubmit", 0, ["prompt": "go"]), try summaryEvent(2, 1, sessionCard),
      stop(3, 2, try replyFixture("rule-hides-question")), try prEvent(4, depotPR()),
    ])
    let v = try depotVerdict(f)

    let built = try #require(Triage.item(f, v, kind: .work))

    try #require(built.source == .session)
    #expect(!hasAsk(built))
    #expect(!built.options.contains { $0.action == .send && ($0.message == "Yes" || $0.message == "No") })
  }

  @Test func theOperatorsReportItemGetsNoQuestion() throws {
    let f = opRouted(
      operatorSession(),
      facts([
        opPrompt(1, "hello"), stop(2, 2, try replyFixture("rule-hides-question")),
        opReport(3, "Should I pause the rollout?"),
      ]))
    let v = opVerdict(operatorSession(), f)

    let built = try #require(Triage.item(f, v, kind: .operator))

    try #require(built.source == .report)
    #expect(!hasAsk(built))
    #expect(built.options.map(\.action) == [.reply])
  }

  /// An overdue wait that sbd could not route gives the operator a held item, which takes no reply question.
  @Test func theOperatorsHeldWaitItemGetsNoQuestion() throws {
    let s = operatorSession(waits: [overdueWait])
    let f = opRouted(s, facts([opPrompt(1, "hello"), stop(2, 2, try replyFixture("rule-hides-question"))]))
    let v = opVerdict(s, f)
    try #require(v.fromOperator, "\(v.state) \(v.reason)")

    let built = try #require(Triage.item(f, v, kind: .operator))

    try #require(built.source == .report)
    #expect(!hasAsk(built))
    #expect(built.options.isEmpty)
  }

  @Test func aFailedRemovalGetsNoQuestion() throws {
    var s = session()
    var removal = Removal(requested: 0, notBefore: 0, worktree: true, branch: true, remoteBranch: false, resolve: [])
    removal.state = .failed
    removal.error = "git worktree remove failed"
    s.removal = removal
    let f = try depotFacts(try replyFixture("rule-hides-question"))
    let v = Attention.evaluate(s, f, now: 10)
    try #require(v.reason.hasPrefix("Delete failed"), "\(v.state) \(v.reason)")

    let built = try #require(Triage.item(f, v, kind: .work))

    try #require(built.source == .rule)
    #expect(!hasAsk(built))
    #expect(built.options == v.options)
  }
}

// MARK: Options that the rule already has

@Suite struct TriageReplyExistingOptions {
  static let fix = TriageOption(
    label: "Fix the checks", action: .send, message: "Fix the failing Depot CI on #42.", recommended: true)

  func built(_ options: [TriageOption]) throws -> TriageItem {
    let f = try depotFacts(try replyFixture("rule-hides-question"))
    let v = Verdict(state: .needsYou, reason: "fix Depot CI on #42: tests", options: options)
    let built = try #require(Triage.item(f, v, kind: .work))
    try #require(built.source == .rule)
    return built
  }

  /// The guard matches the action and the message, not the label.
  @Test func aRuleSendOptionWithYesAsItsMessageGetsNoSecondYes() throws {
    let item = try built([Self.fix, TriageOption(label: "Go ahead", action: .send, message: "Yes")])

    #expect(item.options.filter { $0.action == .send && $0.message == "Yes" }.count == 1)
  }

  @Test func aRuleSendOptionWithYesAsItsMessageBecomesTheMainOption() throws {
    let item = try built([Self.fix, TriageOption(label: "Go ahead", action: .send, message: "Yes")])

    #expect(item.primary?.label == "Go ahead")
    #expect(item.options.filter(\.recommended).map(\.label) == ["Go ahead"])
  }

  @Test func aRuleSendOptionWithYesAsItsMessageStillGetsNo() throws {
    let item = try built([Self.fix, TriageOption(label: "Go ahead", action: .send, message: "Yes")])

    #expect(item.options.filter { $0.action == .send && $0.message == "No" }.count == 1)
  }

  @Test func aRuleSendOptionWithNoAsItsMessageGetsNoSecondNo() throws {
    let item = try built([Self.fix, TriageOption(label: "Not now", action: .send, message: "No")])

    #expect(item.options.filter { $0.action == .send && $0.message == "No" }.count == 1)
    #expect(item.primary == yes)
  }

  /// An option labeled Yes that doesn't send "Yes" is another option, so the reply's Yes still joins.
  @Test func aYesLabelOnAnotherActionStillGetsTheRepliesYes() throws {
    let item = try built([Self.fix, TriageOption(label: "Yes", action: .done)])

    #expect(item.options.contains(yes))
    #expect(item.primary == yes)
  }
}

// MARK: sbd's callout and the app's reply display agree

@Suite struct TriageReplyParity {
  static let replies = [
    proseQuestion, yesNoOffer, choiceOffer, nextStep, yesNoLikeQuestion, asksNothing, "Pushed.", "", "   ",
    "  \n\t\n ",
  ]

  /// Replies past the character or line limit, one that asks and one that asks nothing of each.
  static let longReplies = [
    sizedReply(characters: 1_201, ending: "Want me to push?"), sizedReply(lines: 21, ending: "Want me to push?"),
    sizedReply(characters: 1_201, ending: "Done."), sizedReply(lines: 21, ending: "Done."),
  ]

  @Test(arguments: replies)
  func theCalloutAppearsExactlyWhenTheShortReplyIsExpanded(_ text: String) throws {
    let f = try depotFacts(text)
    let built = try #require(Triage.item(f, try depotVerdict(f), kind: .work))
    try #require(built.source == .rule)

    let p = Triage.replyPresentation(item: built, reply: f.lastReply ?? "", listOpen: false)

    #expect(hasAsk(built) == (p == .expanded), "\(p)")
  }

  @Test(arguments: longReplies)
  func theCalloutAppearsExactlyWhenALongReplyShowsAtAll(_ text: String) throws {
    let f = try depotFacts(text)
    let built = try #require(Triage.item(f, try depotVerdict(f), kind: .work))
    try #require(built.source == .rule)

    let p = Triage.replyPresentation(item: built, reply: f.lastReply ?? "", listOpen: false)

    #expect(hasAsk(built) == (p == .collapsed), "\(p)")
  }

  /// A rule item built while a turn runs, such as an open prompt's, keeps the earlier turn's reply in `lastReply`.
  @Test func aRuleItemBuiltWhileATurnRunsShowsNoEarlierQuestion() throws {
    let text = try replyFixture("rule-hides-question")
    var f = try depotFacts(text)
    let v = try depotVerdict(f)
    f.apply(event("UserPromptSubmit", 3, ["prompt": "watch CI"]))
    try #require(f.turnRunning)
    try #require(Triage.replyAsk(f.lastReply ?? "") != nil, "the earlier reply still asks")

    let built = try #require(Triage.item(f, v, kind: .work))
    let p = Triage.replyPresentation(item: built, reply: f.lastReply ?? "", listOpen: false)

    try #require(built.source == .rule)
    #expect(!hasAsk(built))
    #expect(p == .none)
  }

  @Test(arguments: replies + longReplies)
  func theCalloutAppearsExactlyWhenReplyAskFindsAnAsk(_ text: String) throws {
    let (built, _) = try depotItem(text)

    #expect(hasAsk(built) == (Triage.replyAsk(text) != nil))
  }

  @Test(arguments: replies + longReplies)
  func yesAndNoAppearExactlyForAYesNoOffer(_ text: String) throws {
    let (built, _) = try depotItem(text)
    let isYesNoOffer: Bool
    if case .offer(let o) = Attention.classify(text) {
      isYesNoOffer = OfferText.isYesNo(o)
    } else {
      isYesNoOffer = false
    }

    #expect(built.options.contains(yes) == isYesNoOffer)
    #expect(built.options.contains(no) == isYesNoOffer)
  }
}
