import Foundation
import Testing

@testable import SwitchboardCore

/// The spec's example of a card that a session writes with `sb summary set`.
let exampleCard: JSON = [
  "title": "Pick how to land #98",
  "summary": "Opened #98; CI is green.\nTwo review items need a call.",
  "options": [
    [
      "label": "Fix items 3 and 5, then merge", "action": "send", "message": "Fix items 3 and 5, then merge.",
      "recommended": true,
    ],
    ["label": "Merge as is", "action": "merge"],
    ["label": "Wait for CI", "action": "wait", "wait": ["kind": "ci", "target": "98"]],
    ["label": "Skip", "action": "done"],
    ["label": "Something else", "action": "reply", "placeholder": "What should it do?"],
  ],
  "callouts": [["kind": "warning", "title": "Drops events_old", "body": "The migration deletes the table."]],
]

/// A card with the summary and the given options and callouts.
func card(options: [JSON] = [], callouts: [JSON] = [], summary: String = "It did the work.") -> JSON {
  ["summary": .string(summary), "options": .array(options), "callouts": .array(callouts)]
}

/// `item(_:)` under a name that a local `item` doesn't shadow inside `#require`.
func itemOf(_ f: SessionFacts) -> TriageItem? { item(f) }

func cleaned(_ raw: JSON, now: Int64 = 1_000) throws -> TriageCard.Cleaned {
  try TriageCard.clean(raw, now: now)
}

/// The `summary` event that `sb summary set` records with the cleaned card.
func summaryEvent(_ id: Int64, _ t: Int64, _ summary: TriageSummary) throws -> Event {
  Event(id: id, session: "s1", t: t, kind: "summary", data: try JSON(encoding: summary))
}

let sessionCard = TriageSummary(
  title: "Pick how to land #42", kind: .decision, summary: "Opened #42.\nIt needs a call.",
  options: [
    TriageOption(label: "Fix it", action: .send, message: "Fix it.", recommended: true),
    TriageOption(label: "Skip", action: .done),
  ],
  callouts: [Callout(kind: .decision, title: "Kept the old API", body: "Callers still use it.")])

// MARK: Cleaning

@Suite struct TriageCardCleaning {
  @Test func keepsTheSpecExample() throws {
    let result = try cleaned(exampleCard)

    #expect(result.dropped.isEmpty)
    #expect(result.card.title == "Pick how to land #98")
    #expect(result.card.summary == "Opened #98; CI is green.\nTwo review items need a call.")
    #expect(result.card.options.map(\.action) == [.send, .merge, .wait, .done, .reply])
    #expect(
      result.card.callouts == [
        Callout(kind: .warning, title: "Drops events_old", body: "The migration deletes the table.")
      ])
  }

  @Test(arguments: TriageAction.writable)
  func keepsEachWritableAction(_ action: TriageAction) throws {
    var option: [String: JSON] = ["label": "Go", "action": .string(action.rawValue)]
    if action == .wait { option["wait"] = ["kind": "ci", "target": "98"] }

    let result = try cleaned(card(options: [.object(option)]))

    #expect(result.card.options.map(\.action) == [action])
    #expect(result.dropped.isEmpty)
  }

  @Test func theWritableActionsAreTheFiveThatASessionMayName() {
    #expect(Set(TriageAction.writable) == [.send, .reply, .merge, .wait, .done])
  }

  /// sbd alone adds `dismiss`, `allow`, `deny`, and `answer`. A name that is
  /// not an action, or that differs only in case, is not in the set either.
  @Test(arguments: ["dismiss", "allow", "deny", "answer", "rm -rf /", "MERGE", "Send", "", " send"])
  func dropsAnActionOutsideTheWritableSet(_ action: String) throws {
    let raw = card(options: [["label": "Do it", "action": .string(action)], ["label": "Fine", "action": "send"]])

    let result = try cleaned(raw)

    #expect(result.card.options.map(\.label) == ["Fine"])
    #expect(result.dropped.count == 1)
    #expect(result.dropped.first?.contains("Do it") == true)
  }

  @Test(arguments: [JSON.number(1), .bool(true), .array(["merge"]), .object(["name": "merge"])])
  func dropsAnActionThatIsNotText(_ action: JSON) throws {
    let raw = card(options: [["label": "Do it", "action": action]])

    let result = try cleaned(raw)

    #expect(result.card.options.isEmpty)
    #expect(result.dropped.count == 1)
  }

  @Test(arguments: [JSON.null, .string(""), .string("   "), .string("\n\t"), .number(3)])
  func dropsAnOptionWithoutALabel(_ label: JSON) throws {
    var option: [String: JSON] = ["action": "send", "message": "Go."]
    if label != .null { option["label"] = label }

    let result = try cleaned(card(options: [.object(option)]))

    #expect(result.card.options.isEmpty)
    #expect(result.dropped.count == 1)
  }

  /// Each wait here is one that `WaitRequest.makeWait` refuses: an unknown
  /// kind, a date wait with no time, a field that the kind doesn't take, a
  /// target that isn't a PR, a time that has passed, and an unknown `then`.
  @Test(arguments: [
    JSON.object(["kind": "nonsense"]),
    .object(["kind": "date"]),
    .object(["kind": "ci", "who": "alice"]),
    .object(["kind": "ci", "until": "1h"]),
    .object(["kind": "review", "target": "98"]),
    .object(["kind": "ci", "target": "not a pr"]),
    .object(["kind": "date", "until": "1970-01-01T00:00:00Z"]),
    .object(["kind": "manual", "then": "explode"]),
  ])
  func dropsAWaitThatMakeWaitRefuses(_ wait: JSON) throws {
    let raw = card(options: [["label": "Wait", "action": "wait", "wait": wait]])

    let result = try cleaned(raw, now: 1_800_000_000_000)

    #expect(result.card.options.isEmpty)
    #expect(result.dropped.count == 1)
  }

  @Test(arguments: [JSON.null, .string("ci"), .array([]), .number(98)])
  func dropsAWaitOptionWhoseWaitIsNotAnObject(_ wait: JSON) throws {
    var option: [String: JSON] = ["label": "Wait", "action": "wait"]
    if wait != .null { option["wait"] = wait }

    let result = try cleaned(card(options: [.object(option)]))

    #expect(result.card.options.isEmpty)
    #expect(result.dropped.count == 1)
  }

  @Test func keepsTheFieldsOfAWaitThatMakeWaitAccepts() throws {
    let raw = card(options: [
      ["label": "Wait for CI", "action": "wait", "wait": ["kind": "ci", "target": "98", "by": "claude"]]
    ])

    let wait = try #require(try cleaned(raw).card.options.first?.wait)

    #expect(wait.kind == "ci")
    #expect(wait.target == "98")
    #expect(wait.by == nil)
  }

  @Test(arguments: [nil, "", "  \n "] as [String?])
  func aSendWithoutAMessageSendsItsLabel(_ message: String?) throws {
    var option: [String: JSON] = ["label": "Go on", "action": "send"]
    if let message { option["message"] = .string(message) }

    let kept = try #require(try cleaned(card(options: [.object(option)])).card.options.first)

    #expect(kept.message == "Go on")
  }

  @Test func aBlankDetailAndPlaceholderAreLeftOut() throws {
    let raw = card(options: [["label": "Something else", "action": "reply", "detail": "  ", "placeholder": " \n "]])

    let kept = try #require(try cleaned(raw).card.options.first)

    #expect(kept.detail == nil)
    #expect(kept.placeholder == nil)
  }

  @Test func longFieldsAreCutToTheirLimits() throws {
    let long = String(repeating: "x", count: 3_000)
    let raw = card(
      options: [["label": .string(long), "action": "send", "message": .string(long)]],
      callouts: [["kind": "info", "title": "Note", "body": .string(long)]])

    let result = try cleaned(raw).card

    #expect(result.options.first?.label.count == TriageCard.labelLength)
    #expect(result.options.first?.message?.count == TriageCard.messageLength)
    #expect(result.callouts.first?.body.count == TriageCard.bodyLength)
  }

  @Test func reportsEachDroppedPartAndWhy() throws {
    let raw = card(
      options: [
        ["label": "Keep", "action": "send"], ["label": "Dismiss it", "action": "dismiss"],
        ["label": "Allow it", "action": "allow"],
      ],
      callouts: [["kind": "danger", "title": "Odd kind"], ["kind": "info", "title": "Fine"]])

    let result = try cleaned(raw)

    #expect(result.dropped.count == 3)
    #expect(result.dropped.contains { $0.contains("Dismiss it") && $0.contains("dismiss") })
    #expect(result.dropped.contains { $0.contains("Allow it") && $0.contains("allow") })
    #expect(result.dropped.contains { $0.contains("danger") })
  }

  // MARK: Summary and title

  @Test(arguments: [JSON.null, .string(""), .string("  \n \n\t"), .number(1), .array(["a"])])
  func refusesACardWithoutASummary(_ summary: JSON) {
    var raw: [String: JSON] = ["title": "A title", "options": [["label": "Go", "action": "send"]]]
    if summary != .null { raw["summary"] = summary }

    #expect(throws: APIError.self) { try cleaned(.object(raw)) }
  }

  @Test(arguments: [JSON.array([]), .string("summary"), .null, .number(1)])
  func refusesACardThatIsNotAnObject(_ raw: JSON) {
    #expect(throws: APIError.self) { try cleaned(raw) }
  }

  @Test(arguments: ["a\n\nb\nc\n\n\nd\ne\nf", "a\r\nb\r\n\r\nc\r\nd\r\ne", "  a  \n b\n\nc\nd\ne"])
  func keepsTheFirstFourNonEmptyLines(_ summary: String) throws {
    let result = try cleaned(card(summary: summary))

    #expect(result.card.summary == "a\nb\nc\nd")
  }

  @Test func cutsEachLineToTwoHundredCharacters() throws {
    let long = String(repeating: "x", count: 500)

    let lines = try cleaned(card(summary: "\(long)\nshort\n\(long)")).card.summary.components(separatedBy: "\n")

    #expect(lines.count == 3)
    #expect(lines.allSatisfy { $0.count <= TriageCard.lineLength })
    #expect(TriageCard.lineLength == 200)
    #expect(lines[1] == "short")
  }

  @Test func theTitleDefaultsToTheSummarysFirstLine() throws {
    #expect(try cleaned(card(summary: "\n\nOpened #98.\nIt needs a call.")).card.title == "Opened #98.")
  }

  @Test(arguments: [JSON.string(""), .string("   "), .number(5)])
  func aBlankTitleDefaultsToTheSummarysFirstLine(_ title: JSON) throws {
    var raw = card(summary: "Opened #98.\nIt needs a call.").object!
    raw["title"] = title

    #expect(try cleaned(.object(raw)).card.title == "Opened #98.")
  }

  @Test func theDefaultTitleIsAtMostSixtyCharacters() throws {
    let title = try cleaned(card(summary: String(repeating: "word ", count: 30))).card.title

    #expect(title.count <= Triage.titleLength)
    #expect(Triage.titleLength == 60)
    #expect(!title.isEmpty)
  }

  @Test func aGivenTitleIsAtMostSixtyCharacters() throws {
    var raw = card().object!
    raw["title"] = .string(String(repeating: "t", count: 100))

    #expect(try cleaned(.object(raw)).card.title.count <= Triage.titleLength)
  }

  // MARK: Limits

  @Test func keepsTheFirstSixOptions() throws {
    let options = (1...8).map { JSON.object(["label": .string("Option \($0)"), "action": "send"]) }

    let result = try cleaned(card(options: options))

    #expect(result.card.options.map(\.label) == (1...6).map { "Option \($0)" })
    #expect(!result.dropped.isEmpty)
  }

  /// A dropped option does not use up one of the six places.
  @Test func anInvalidOptionLeavesItsPlaceToAValidOne() throws {
    let bad = JSON.object(["label": "Bad", "action": "allow"])
    let good = (1...6).map { JSON.object(["label": .string("Option \($0)"), "action": "send"]) }

    let result = try cleaned(card(options: [bad] + good))

    #expect(result.card.options.count == 6)
    #expect(result.card.options.first?.label == "Option 1")
  }

  @Test func keepsTheFirstFiveCallouts() throws {
    let callouts = (1...7).map { JSON.object(["kind": "info", "title": .string("Note \($0)"), "body": ""]) }

    let result = try cleaned(card(callouts: callouts))

    #expect(result.card.callouts.map(\.title) == (1...5).map { "Note \($0)" })
    #expect(!result.dropped.isEmpty)
  }

  // MARK: Callouts

  @Test(arguments: Callout.Kind.allCases)
  func keepsEachCalloutKind(_ kind: Callout.Kind) throws {
    let raw = card(callouts: [["kind": .string(kind.rawValue), "title": "Read this", "body": "It matters."]])

    #expect(try cleaned(raw).card.callouts == [Callout(kind: kind, title: "Read this", body: "It matters.")])
  }

  @Test func theCalloutKindsAreWarningDecisionAndInfo() {
    #expect(Set(Callout.Kind.allCases) == [.warning, .decision, .info])
  }

  @Test(arguments: [JSON.null, .string(""), .string("error"), .string("WARNING"), .number(0)])
  func dropsACalloutWithAnUnknownKind(_ kind: JSON) throws {
    var callout: [String: JSON] = ["title": "Read this", "body": "It matters."]
    if kind != .null { callout["kind"] = kind }

    let result = try cleaned(card(callouts: [.object(callout)]))

    #expect(result.card.callouts.isEmpty)
    #expect(result.dropped.count == 1)
  }

  @Test(arguments: [JSON.null, .string(""), .string("  \n"), .number(1)])
  func dropsACalloutWithoutATitle(_ title: JSON) throws {
    var callout: [String: JSON] = ["kind": "warning", "body": "It matters."]
    if title != .null { callout["title"] = title }

    let result = try cleaned(card(callouts: [.object(callout)]))

    #expect(result.card.callouts.isEmpty)
    #expect(result.dropped.count == 1)
  }
}

// MARK: Decoding

@Suite struct TriageOptionDecoding {
  @Test func anOptionWithoutAnActionDecodesAsSend() throws {
    let json = #"{"label":"Postgres","detail":"Already in use","message":"Use Postgres.","recommended":true}"#

    let option = try JSONCoding.decode(TriageOption.self, from: json)

    #expect(option.action == .send)
    #expect(option.message == "Use Postgres.")
    #expect(option.recommended)
  }

  @Test func aTriageEventFromBeforeActionsStillGivesItsOptions() {
    let f = facts([
      event("UserPromptSubmit", 0, ["prompt": "go"]), stop(2, 1, proseQuestion), triageEvent(2, options: [postgres]),
    ])

    let options = item(f)?.options

    #expect(options?.map(\.action) == [.send])
    #expect(options?.map(\.message) == ["Use Postgres."])
  }

  @Test func aSummaryWithoutCalloutsDecodesWithNone() throws {
    let json = #"{"title":"Pick","kind":"decision","summary":"It asks.","options":[]}"#

    #expect(try JSONCoding.decode(TriageSummary.self, from: json).callouts.isEmpty)
  }

  @Test func anItemRoundTripsItsOptionsAndCallouts() throws {
    let cleanedCard = try cleaned(exampleCard).card
    let item = TriageItem(
      title: cleanedCard.title, kind: cleanedCard.kind, summary: cleanedCard.summary, options: cleanedCard.options,
      callouts: cleanedCard.callouts, source: .session, ref: "summary:9")

    let decoded = try JSONCoding.decode(TriageItem.self, from: try JSON(encoding: item).text)

    #expect(decoded == item)
  }
}

// MARK: Which card an item shows

@Suite struct TriageCardPrecedence {
  /// A turn that ended in prose, with the session's card recorded during it.
  func carded(_ summary: TriageSummary = sessionCard) throws -> SessionFacts {
    facts([
      event("UserPromptSubmit", 0, ["prompt": "go"]), try summaryEvent(2, 1, summary), stop(3, 2, proseQuestion),
    ])
  }

  @Test func theSessionsCardBecomesTheItem() throws {
    let item = try #require(itemOf(try carded()))

    #expect(item.source == .session)
    #expect(item.title == "Pick how to land #42")
    #expect(item.summary == "Opened #42.\nIt needs a call.")
    #expect(item.options == sessionCard.options)
    #expect(item.callouts == sessionCard.callouts)
  }

  @Test func aCardSetAfterTheStopBelongsToThatTurn() throws {
    let f = facts([
      event("UserPromptSubmit", 0, ["prompt": "go"]), stop(2, 1, proseQuestion), try summaryEvent(3, 2, sessionCard),
    ])

    #expect(f.sessionSummary == sessionCard)
    #expect(item(f)?.source == .session)
  }

  @Test func aNewPromptDropsTheSessionsCard() throws {
    var f = try carded()

    f.apply(event("UserPromptSubmit", 5, ["prompt": "Fix it."]))

    #expect(f.sessionSummary == nil)
  }

  @Test func theTurnAfterANewPromptFallsBackWithoutTheOldCard() throws {
    var f = try carded()
    f.apply(event("UserPromptSubmit", 5, ["prompt": "Fix it."]))

    f.apply(stop(7, 6, proseQuestion))

    #expect(item(f)?.source == .fallback)
  }

  @Test func aSessionThatStillWorksHasNoItemDespiteItsCard() throws {
    let f = facts([event("UserPromptSubmit", 0, ["prompt": "go"]), try summaryEvent(2, 1, sessionCard)])

    #expect(item(f) == nil)
  }

  @Test func aHeldCardWinsOverTheSessionsCard() throws {
    var f = try carded()

    f.apply(Event(id: 9, session: "s1", t: 5, kind: "PermissionRequest", data: .object(touch)))

    #expect(item(f)?.source == .card)
    #expect(item(f)?.options.map(\.action) == [.allow, .deny])
  }

  /// A dialog in the terminal without a card holds the session's next
  /// prompt, so the card's buttons would only queue behind it.
  @Test(arguments: [true, false])
  func anOpenTerminalDialogWinsOverTheSessionsCard(_ question: Bool) throws {
    var f = try carded()
    let call = ToolCall(tool: question ? "AskUserQuestion" : "Bash", summary: "Which fruit?", since: 5)
    if question { f.openQuestion = call } else { f.openPermission = call }

    let item = try #require(itemOf(f))

    #expect(item.source != .session)
  }

  @Test func aHeldQuestionsOptionsAnswer() {
    let one: JSON = [
      "questions": [
        ["question": "Which fruit?", "header": "Fruit", "multiSelect": false, "options": [["label": "apple"]]]
      ]
    ]

    let item = item(facts(promptTurn(ask(one, id: "q1"), ask(one, id: nil))))

    #expect(item?.options.map(\.action) == [.answer])
    #expect(item?.options.map(\.message) == ["apple"])
  }

  @Test func theSessionsCardWinsOverTheModelsSummary() throws {
    var f = try carded()

    f.apply(triageEvent(3, options: [postgres]))

    #expect(item(f)?.source == .session)
  }

  @Test func theSessionsCardWinsOverARuleAndTheRuleLeadsTheCallouts() throws {
    var f = try carded()
    f.pr = samplePR(mergeable: .conflicting)

    let item = try #require(itemOf(f))

    #expect(item.source == .session)
    #expect(item.options.map(\.label) == sessionCard.options.map(\.label) + ["Rebase"])
    #expect(item.primary == sessionCard.options.first)
    let lead = try #require(item.callouts.first)
    #expect(lead.kind == .warning)
    #expect((lead.title + " " + lead.body).contains("#42 conflicts with main"))
    #expect(Array(item.callouts.suffix(sessionCard.callouts.count)) == sessionCard.callouts)
  }

  /// A card written before the PR became ready to merge keeps Merge and
  /// Acknowledge, since the Inbox shows no other merge button for one PR.
  @Test func aReadyPRAfterTheSessionsCardAddsMergeAndAcknowledge() throws {
    var f = try carded()
    f.pr = samplePR(checks: "SUCCESS")
    f.pr?.trunkConfig = false

    let item = try #require(itemOf(f))

    #expect(item.source == .session)
    #expect(item.callouts.first?.kind == .info)
    #expect(item.options.map(\.action) == sessionCard.options.map(\.action) + [.merge, .dismiss])
    #expect(item.primary == sessionCard.options.first)
  }

  /// A card with one option and no recommendation keeps that option as the
  /// main one after the rule's recommended Merge joins it.
  @Test func aRulesRecommendedOptionDoesNotTakeOverTheCardsOnlyOption() throws {
    var only = sessionCard
    only.options = [TriageOption(label: "Go on", action: .send, message: "Go on.")]
    var f = try carded(only)
    f.pr = samplePR(checks: "SUCCESS")
    f.pr?.trunkConfig = false

    let item = try #require(itemOf(f))

    #expect(item.primary?.label == "Go on")
    #expect(item.options.filter(\.recommended).map(\.label) == ["Go on"])
  }

  /// A card that already offers a merge does not get a second Merge button.
  @Test func aCardsOwnMergeOptionIsNotRepeated() throws {
    var merging = sessionCard
    merging.options = [TriageOption(label: "Ship it", action: .merge, recommended: true)]
    var f = try carded(merging)
    f.pr = samplePR(checks: "SUCCESS")
    f.pr?.trunkConfig = false

    let item = try #require(itemOf(f))

    #expect(item.options.map(\.label) == ["Ship it", "Acknowledge"])
  }

  /// A card that has the most callouts still shows the rule's reason first.
  @Test func theRulesCalloutLeadsAFullSetOfCallouts() throws {
    var full = sessionCard
    full.callouts = (1...TriageCard.maxCallouts).map { Callout(kind: .info, title: "Note \($0)", body: "") }
    var f = try carded(full)
    f.pr = samplePR(mergeable: .conflicting)

    let lead = try #require(itemOf(f)?.callouts.first)

    #expect(lead.kind == .warning)
    #expect((lead.title + " " + lead.body).contains("conflicts"))
  }

  @Test func aRuleWinsOverTheModelsSummary() throws {
    var f = facts([
      event("UserPromptSubmit", 0, ["prompt": "go"]), stop(2, 1, proseQuestion), triageEvent(2, options: [postgres]),
    ])
    f.pr = samplePR(mergeable: .conflicting)

    let item = try #require(itemOf(f))

    #expect(item.source == .rule)
    #expect(item.options.map(\.label) == ["Rebase"])
  }

  @Test func theModelsSummaryWinsOverTheFallback() {
    let f = facts([event("UserPromptSubmit", 0, ["prompt": "go"]), stop(2, 1, proseQuestion), triageEvent(2)])

    #expect(item(f)?.source == .summary)
  }

  /// `choose` refuses a stale ref, so a new card in the same turn must not
  /// share the old card's ref.
  @Test func aSecondCardInTheSameTurnHasANewRef() throws {
    var f = try carded()
    let before = try #require(itemOf(f)?.ref)
    var second = sessionCard
    second.title = "A new question"

    f.apply(try summaryEvent(4, 3, second))

    let after = try #require(itemOf(f))
    #expect(after.title == "A new question")
    #expect(after.ref != before)
  }

  @Test func aSessionCardsRefDiffersFromTheModelSummarysRef() throws {
    let modelOnly = facts([
      event("UserPromptSubmit", 0, ["prompt": "go"]), stop(3, 2, proseQuestion), triageEvent(3),
    ])
    var both = modelOnly
    both.apply(try summaryEvent(5, 4, sessionCard))

    #expect(item(both)?.ref != item(modelOnly)?.ref)
  }

  /// A `triage` event that only says sbd skipped the call leaves the reply.
  @Test func aSkippedSummaryLeavesTheFallback() {
    let skipped = Event(
      id: 3, session: "s1", t: 2, kind: "triage", data: ["stop": 2, "skipped": "no quota left"])

    let f = facts([event("UserPromptSubmit", 0, ["prompt": "go"]), stop(2, 1, proseQuestion), skipped])

    #expect(f.triage == nil)
    #expect(item(f)?.source == .fallback)
  }
}

// MARK: PR rules attach options

@Suite struct TriageRuleCards {
  func ended(_ pr: PullRequest, comments: [PRComment] = []) -> SessionFacts {
    var f = facts([event("UserPromptSubmit", 0, ["prompt": "go"]), stop(2, 1, "Pushed.")])
    f.pr = pr
    // The poller found no .trunk folder, so the repo merges without Trunk.
    f.pr?.trunkConfig = false
    f.prComments = comments
    return f
  }

  @Test func readyToMergeOffersMergeAndAcknowledge() throws {
    let f = ended(samplePR(checks: "SUCCESS"))

    let item = try #require(itemOf(f))

    #expect(item.source == .rule)
    #expect(item.options.map(\.label) == ["Merge #42", "Acknowledge"])
    #expect(item.options.map(\.action) == [.merge, .dismiss])
    #expect(item.options.map(\.recommended) == [true, false])
    #expect(item.primary?.action == .merge)
  }

  @Test func aFailedMergeShowsGhsErrorAsAWarning() throws {
    var f = ended(samplePR(checks: "SUCCESS"))
    let error = "the base branch policy prohibits the merge"
    f.apply(event("merge", 3, ["head": .string(samplePRHead), "result": "failed", "error": .string(error)]))

    let item = try #require(itemOf(f))

    #expect(item.options.map(\.action) == [.merge, .dismiss])
    #expect(item.callouts.contains { $0.kind == .warning && ($0.title + " " + $0.body).contains(error) })
  }

  @Test func aMergeThatFailedAtAnOlderHeadShowsNoWarning() throws {
    var f = ended(samplePR(checks: "SUCCESS"))
    f.apply(event("merge", 3, ["head": "older", "result": "failed", "error": "stale error"]))

    let item = try #require(itemOf(f))

    #expect(!item.callouts.contains { ($0.title + " " + $0.body).contains("stale error") })
  }

  @Test func aConflictOffersARebaseAndWarns() throws {
    let f = ended(samplePR(mergeable: .conflicting))

    let item = try #require(itemOf(f))

    #expect(item.source == .rule)
    #expect(item.options.map(\.label) == ["Rebase"])
    #expect(item.options.map(\.action) == [.send])
    #expect(item.options.first?.message == "Rebase onto main, resolve the conflicts, and push.")
    #expect(item.callouts.first?.kind == .warning)
  }

  @Test func aConflictsRebaseNamesThePRsBase() throws {
    let f = ended(samplePR(base: "release-2", mergeable: .conflicting))

    #expect(item(f)?.options.first?.message == "Rebase onto release-2, resolve the conflicts, and push.")
  }

  enum OneStep: String, CaseIterable, CustomTestStringConvertible {
    case retarget, requestedChanges, trunkRemoval, depotFailure, approvedForTrunk

    var testDescription: String { rawValue }

    var pr: PullRequest {
      var pr: PullRequest
      switch self {
      case .retarget: pr = samplePR(mergedBase: 41)
      case .requestedChanges: pr = samplePR(reviewDecision: .changesRequested)
      case .trunkRemoval: pr = samplePR(queue: .removed)
      case .depotFailure:
        pr = samplePR()
        pr.depot = DepotRun(
          id: "run1", headSha: samplePRHead, status: "failed", jobs: 3, failed: [DepotRun.Job(name: "Django tests")])
      case .approvedForTrunk:
        pr = samplePR(reviewDecision: .approved, verdicts: [Review(author: "alice", state: "APPROVED")])
      }
      return pr
    }

    var comments: [PRComment] {
      self == .approvedForTrunk
        ? [PRComment(id: "IC_trunk", author: TrunkComments.author, createdAt: "2026-10-25T00:00:00Z", body: "Trunk")]
        : []
    }
  }

  @Test(arguments: OneStep.allCases)
  func aPRRuleWithOneNextStepOffersOneSend(_ rule: OneStep) throws {
    let f = ended(rule.pr, comments: rule.comments)

    let item = try #require(itemOf(f))

    #expect(item.source == .rule)
    #expect(item.options.count == 1)
    #expect(item.options.first?.action == .send)
    #expect(item.options.first?.message?.isEmpty == false)
    #expect(item.primary == item.options.first)
  }

  @Test func aDepotFailureNamesTheFailedJobInAWarning() throws {
    var pr = samplePR()
    pr.depot = DepotRun(
      id: "run1", headSha: samplePRHead, status: "failed", jobs: 3, failed: [DepotRun.Job(name: "Django tests")])

    let item = try #require(itemOf(ended(pr)))

    #expect(item.callouts.contains { $0.kind == .warning && ($0.title + " " + $0.body).contains("Django tests") })
  }

  @Test func aRuleWithoutAKnownNextStepOffersNothing() throws {
    var f = facts([event("UserPromptSubmit", 0, ["prompt": "go"]), stop(2, 1, "Waiting.")])
    f.waitOutcome = "CI passed on #4"

    let item = try #require(itemOf(f))

    #expect(item.source == .rule)
    #expect(item.options.isEmpty)
  }

  @Test func noRuleOffersAnActionThatOnlyTheSessionMayName() throws {
    for f in [ended(samplePR(checks: "SUCCESS")), ended(samplePR(mergeable: .conflicting))] {
      let actions = item(f)?.options.map(\.action) ?? []
      #expect(!actions.contains(.wait))
      #expect(!actions.contains(.done))
    }
  }
}

// MARK: The primary option

@Suite struct TriagePrimaryOption {
  func item(_ options: [TriageOption]) -> TriageItem {
    TriageItem(title: "t", kind: .decision, summary: "s", options: options, source: .session)
  }

  @Test func theRecommendedOptionIsPrimaryWhereverItIs() {
    let options = [
      TriageOption(label: "A", action: .send, message: "a"),
      TriageOption(label: "B", action: .merge, recommended: true),
    ]

    #expect(item(options).primary?.label == "B")
  }

  @Test func theOnlyOptionIsPrimaryWithoutARecommendation() {
    #expect(item([TriageOption(label: "A", action: .done)]).primary?.label == "A")
  }

  @Test func severalOptionsWithoutARecommendationHaveNoPrimary() {
    let options = [TriageOption(label: "A", action: .done), TriageOption(label: "B", action: .done)]

    #expect(item(options).primary == nil)
  }

  @Test func noOptionsHaveNoPrimary() {
    #expect(item([]).primary == nil)
  }
}

// MARK: Model fallback

@Suite struct TriageSummaryRateLimit {
  func callEvent(_ id: Int64, _ t: Int64, _ data: JSON) -> Event {
    Event(id: id, session: "s1", t: t, kind: "triage", data: data)
  }

  let hourMs: Int64 = 3_600_000

  @Test func aSummaryCallCountsAtItsTime() {
    let f = facts([
      event("UserPromptSubmit", 0, ["prompt": "go"]), stop(2, 1, proseQuestion),
      callEvent(3, 50, ["stop": 2, "title": "t", "kind": "info", "summary": "s", "options": []]),
    ])

    #expect(f.summaryCalls == [50])
  }

  @Test func aFailedSummaryCallStillCounts() {
    let f = facts([
      event("UserPromptSubmit", 0, ["prompt": "go"]), stop(2, 1, proseQuestion),
      callEvent(3, 50, ["stop": 2, "error": "timed out"]),
    ])

    #expect(f.summaryCalls == [50])
  }

  @Test func aSkippedCallDoesNotCount() {
    let f = facts([
      event("UserPromptSubmit", 0, ["prompt": "go"]), stop(2, 1, proseQuestion),
      callEvent(3, 50, ["stop": 2, "skipped": "no quota left"]),
    ])

    #expect(f.summaryCalls.isEmpty)
  }

  @Test func aCallOlderThanAnHourDropsOut() {
    let f = facts([
      callEvent(1, 10, ["stop": 0, "error": "x"]), callEvent(2, 20 + hourMs, ["stop": 0, "error": "x"]),
    ])

    #expect(f.summaryCalls == [20 + hourMs])
  }

  @Test func callsCountAcrossTurns() {
    let f = facts([
      event("UserPromptSubmit", 0, ["prompt": "go"]), stop(2, 1, proseQuestion),
      callEvent(3, 5, ["stop": 2, "error": "x"]),
      event("UserPromptSubmit", 6, ["prompt": "again"]), stop(5, 7, proseQuestion),
      callEvent(6, 8, ["stop": 5, "error": "x"]),
    ])

    #expect(f.summaryCalls == [5, 8])
  }

  @Test func perHourDefaultsToSix() {
    #expect(Config().triage.perHour == 6)
  }

  @Test func readsPerHourAndKeepsTheOtherDefaults() throws {
    let config = try JSONCoding.decode(Config.self, from: #"{"triage":{"perHour":2}}"#)

    #expect(config.triage.perHour == 2)
    #expect(config.triage.model == "haiku")
    #expect(config.triage.enabled)
  }

  @Test func anObjectWithoutPerHourKeepsSix() throws {
    let config = try JSONCoding.decode(Config.self, from: #"{"triage":{"enabled":false}}"#)

    #expect(config.triage.perHour == 6)
  }
}

// MARK: The model's summary

@Suite struct TriageModelCards {
  func envelope(_ payload: JSON) -> String {
    JSON.object(["is_error": false, "result": .string(payload.text), "structured_output": payload]).text
  }

  @Test func theSchemaAsksForActionTypedOptionsAndCallouts() throws {
    let properties = try #require(TriageSummarizer.schema["properties"])
    let action = try #require(properties["options"]?["items"]?["properties"]?["action"])

    #expect(action["enum"] == ["send", "reply"])
    #expect(properties["callouts"]?["items"]?["properties"]?["kind"]?["enum"] == ["warning", "decision", "info"])
  }

  @Test func readsActionsAndCallouts() throws {
    let payload: JSON = [
      "title": "Pick a database", "kind": "decision", "summary": "It compared both.\nIt asks which one.",
      "options": [
        ["label": "Postgres", "action": "send", "message": "Use Postgres.", "recommended": true],
        ["label": "Other", "action": "reply", "placeholder": "Which one?"],
      ],
      "callouts": [["kind": "info", "title": "SQLite is faster here", "body": "For one writer."]],
    ]

    let summary = try TriageSummarizer.parse(envelope(payload))

    #expect(summary.options.map(\.action) == [.send, .reply])
    #expect(summary.options.last?.placeholder == "Which one?")
    #expect(summary.callouts == [Callout(kind: .info, title: "SQLite is faster here", body: "For one writer.")])
    #expect(summary.summary == "It compared both.\nIt asks which one.")
  }

  /// The model reads text that PR comments and other sessions wrote, so it
  /// may offer only `send` and `reply`.
  @Test(arguments: ["merge", "wait", "done", "dismiss", "allow", "deny", "answer"])
  func dropsAModelOptionThatIsNotSendOrReply(_ action: String) throws {
    var option: [String: JSON] = ["label": "Do it", "action": .string(action)]
    if action == "wait" { option["wait"] = ["kind": "ci", "target": "98"] }
    let payload: JSON = [
      "title": "t", "kind": "decision", "summary": "s",
      "options": [.object(option), ["label": "Fine", "action": "send", "message": "Fine."]],
    ]

    let summary = try TriageSummarizer.parse(envelope(payload))

    #expect(summary.options.map(\.label) == ["Fine"])
  }

  /// Values whose JSON form or reading differs: escapes, a label that spells
  /// null, a number in a string, blank text, and lines with CRLF.
  static let edgeOptions: [JSON] = [
    ["label": "Say \"hi\" \u{2014} now\\", "action": "send", "message": "Line one\nLine \"two\""],
    ["label": "null", "action": "send", "message": "null"],
    ["label": "98", "action": "reply", "placeholder": "  "],
    ["label": "  ", "action": "send"],
    ["label": "Blank message", "action": "send", "message": ""],
    ["label": "Tab\tand\u{0007}bell", "action": "send", "detail": ""],
  ]

  @Test(arguments: edgeOptions)
  func theParserCleansAnOptionAsTheSessionsCardDoes(_ option: JSON) throws {
    let payload: JSON = [
      "title": "t", "kind": "decision", "summary": "a\r\nb\n\nc", "options": [option],
      "callouts": [["kind": "info", "title": "null", "body": "x \"y\""], ["kind": "nope", "title": "z"]],
    ]

    let parsed = try TriageSummarizer.parse(envelope(payload))
    let card = try TriageCard.clean(payload, actions: TriageSummarizer.actions).card

    #expect(parsed.options == card.options)
    #expect(parsed.callouts == card.callouts)
    #expect(parsed.summary == card.summary)
  }

  /// claude prints the answer as `structured_output` and as text in
  /// `result`. The two readings agree, escapes and all.
  @Test(arguments: edgeOptions)
  func theResultTextReadsAsTheStructuredOutputDoes(_ option: JSON) throws {
    let payload: JSON = [
      "title": "Pick \"one\"", "kind": "decision", "summary": "It asks.\nWhich one?", "options": [option],
      "callouts": [["kind": "warning", "title": "Read \\this", "body": "Line\nbreak"]],
    ]
    let structured = JSON.object(["is_error": false, "structured_output": payload]).text
    let fenced = JSON.object(["is_error": false, "result": .string("```json\n\(payload.text)\n```")]).text

    #expect(try TriageSummarizer.parse(structured) == TriageSummarizer.parse(fenced))
  }
}
