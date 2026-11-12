import Foundation
import Testing

@testable import SwitchboardCore

/// A reply that quotes a review request for the user to paste.
private let hogqlReply = """
  Here's a draft you can paste:

  > Could someone from HogQL review https://github.com/PostHog/posthog/pull/131397? It needs a code-owner approval because it touches `posthog/hogql/flag_called_warnings.py` and `metadata.py`.
  >
  > It narrows the SQL editor's `$feature_flag_called` warnings to queries that will fail once flag calls move to `flag_evaluations`. It doesn't change the swap or the union, and the warning code comes out once every org has moved.
  """

/// The two quoted paragraphs of `hogqlReply` without their markers.
private let hogqlParagraphs = """
  Could someone from HogQL review https://github.com/PostHog/posthog/pull/131397? It needs a code-owner approval because it touches `posthog/hogql/flag_called_warnings.py` and `metadata.py`.

  It narrows the SQL editor's `$feature_flag_called` warnings to queries that will fail once flag calls move to `flag_evaluations`. It doesn't change the swap or the union, and the warning code comes out once every org has moved.
  """

/// The two quoted paragraphs as the reply writes them, with their markers.
private let hogqlQuoted = """
  > Could someone from HogQL review https://github.com/PostHog/posthog/pull/131397? It needs a code-owner approval because it touches `posthog/hogql/flag_called_warnings.py` and `metadata.py`.
  >
  > It narrows the SQL editor's `$feature_flag_called` warnings to queries that will fail once flag calls move to `flag_evaluations`. It doesn't change the swap or the union, and the warning code comes out once every org has moved.
  """

/// A reply with two drafts: one in a fence and one in a blockquote.
private let twoDraftReply = """
  Post this in #team-hogql:

  ```
  Hi team,

  please review #5.
  ```

  And send this to Alice:

  > Thanks for the quick look at #4.
  """

private func modelEnvelope(_ payload: JSON) -> String {
  JSON.object(["is_error": false, "result": .string(payload.text), "structured_output": payload]).text
}

/// The model's answer for a turn, with the given drafts.
private func modelOutput(_ drafts: [JSON]) -> String {
  modelEnvelope([
    "title": "Send the review request", "kind": "info", "summary": "It drafted a review request.",
    "options": [], "drafts": .array(drafts),
  ])
}

/// A session's card with the given drafts.
private func draftCard(_ drafts: [JSON]) -> JSON {
  ["summary": "It drafted a review request.\nPaste it to HogQL.", "drafts": .array(drafts)]
}

private let reviewDraft = TriageDraft(label: "Review request", text: "Could someone review #1?")

// MARK: The verbatim check

@Suite struct TriageDraftVerbatim {
  @Test func keepsTheParagraphsWithoutMarkers() {
    let result = TriageDrafts.verbatim([TriageDraft(label: "HogQL", text: hogqlParagraphs)], in: hogqlReply)

    #expect(result.kept == [TriageDraft(label: "HogQL", text: hogqlParagraphs)])
    #expect(result.dropped.isEmpty)
  }

  @Test func keepsACopyWithMarkersAndRemovesThem() {
    let result = TriageDrafts.verbatim([TriageDraft(text: hogqlQuoted)], in: hogqlReply)

    #expect(result.kept.map(\.text) == [hogqlParagraphs])
  }

  @Test func dropsAParaphraseWithAReason() {
    let paraphrase = TriageDraft(
      text: "Could a HogQL owner review PR 131397? It touches flag_called_warnings.py and metadata.py.")

    let result = TriageDrafts.verbatim([paraphrase], in: hogqlReply)

    #expect(result.kept.isEmpty)
    #expect(result.dropped.count == 1)
    #expect(result.dropped.first?.contains("its text is not in the reply") == true)
  }

  @Test func keepsADraftFromAFencedBlock() {
    let result = TriageDrafts.verbatim([TriageDraft(text: "Hi team,\n\nplease review #5.")], in: twoDraftReply)

    #expect(result.kept.map(\.text) == ["Hi team,\n\nplease review #5."])
  }

  @Test func aFencedDraftKeepsItsOwnQuoteLines() {
    let reply = "Paste this:\n\n```\nAs you said:\n> ship it Friday\nSo I will.\n```"
    let text = "As you said:\n> ship it Friday\nSo I will."
    let result = TriageDrafts.verbatim([TriageDraft(text: text)], in: reply)

    #expect(result.kept.map(\.text) == [text])
  }

  @Test func keepsTwoDraftsInTheirOrder() {
    let drafts = [
      TriageDraft(label: "Alice", text: "> Thanks for the quick look at #4."),
      TriageDraft(label: "Team", text: "Hi team,\n\nplease review #5."),
    ]

    let result = TriageDrafts.verbatim(drafts, in: twoDraftReply)

    #expect(
      result.kept == [
        TriageDraft(label: "Alice", text: "Thanks for the quick look at #4."),
        TriageDraft(label: "Team", text: "Hi team,\n\nplease review #5."),
      ])
  }

  @Test func keepsTheDraftsThatMatchAndDropsTheRest() {
    let drafts = [
      TriageDraft(label: "Copy", text: hogqlParagraphs), TriageDraft(label: "Paraphrase", text: "Please review it."),
    ]

    let result = TriageDrafts.verbatim(drafts, in: hogqlReply)

    #expect(result.kept.map(\.label) == ["Copy"])
    #expect(result.dropped.count == 1)
  }

  @Test(arguments: ["", " ", "\n", "\n  \n", "\r\n\r\n", ">", "> ", ">\n>"])
  func dropsAnEmptyDraft(_ text: String) {
    let result = TriageDrafts.verbatim([TriageDraft(text: text)], in: "Some reply.\n\n> \n")

    #expect(result.kept.isEmpty)
    #expect(result.dropped.count == 1)
  }

  /// Each draft differs from the reply in a way that normalization must not
  /// hide: a second marker, a marker indented four spaces (a code block),
  /// inner whitespace, one character, a line break that the reply lacks, or
  /// a copy that starts or ends in the middle of a line.
  @Test(arguments: [
    ("Could someone from HogQL review", hogqlReply),
    ("It needs a code-owner approval", hogqlReply),
    ("review #1", "Could someone review #12?"),
    ("> > nested quote", "nested quote"),
    ("    > hello world", "hello world"),
    ("Could  someone review #1?", "Could someone review #1?"),
    ("Could someone review #2?", "Could someone review #1?"),
    ("Could someone\nreview #1?", "Could someone review #1?"),
    (" Could someone review #1?", "Could someone review #1?"),
    ("could someone review #1?", "Could someone review #1?"),
    ("Could someone review #1?", "Could someone review\n#1?"),
    ("first\n\nsecond", "first\nsecond"),
  ])
  func dropsADraftThatIsNotInTheReply(_ draft: String, _ reply: String) {
    let result = TriageDrafts.verbatim([TriageDraft(text: draft)], in: reply)

    #expect(result.kept.isEmpty)
    #expect(result.dropped.count == 1)
  }

  /// Each draft is in the reply once both lose their CRLFs, one marker per
  /// line, trailing whitespace, and the draft's outer blank lines.
  @Test(arguments: [
    ("a\r\nb", "x\na\nb\ny", "a\nb"),
    ("a\nb", "x\r\na\r\nb\r\ny", "a\nb"),
    ("line one\nline two", "line one  \nline two", "line one\nline two"),
    ("line one   \nline two\t", "line one\nline two", "line one\nline two"),
    ("\n\n  \nHi\n\n", "Hi", "Hi"),
    ("\r\n\r\nHi\r\n\r\n", "Hi", "Hi"),
    ("   > Hi\n>there", "Hi\nthere", "Hi\nthere"),
    (">Hi", "Hi", "Hi"),
    ("Hi\nthere", "> Hi\n>there", "Hi\nthere"),
    ("Hi\n\nthere", "> Hi\n>\n> there", "Hi\n\nthere"),
    ("Hi\n\nthere", "> Hi\n> \n> there", "Hi\n\nthere"),
    ("> > nested", "> > nested", "> nested"),
    ("a > b", "a > b", "a > b"),
  ])
  func keepsTheNormalizedText(_ draft: String, _ reply: String, _ expected: String) {
    let result = TriageDrafts.verbatim([TriageDraft(text: draft)], in: reply)

    #expect(result.kept.map(\.text) == [expected])
  }

  /// Text that a JSON round trip or a reading as a number or a null would change.
  @Test(arguments: [
    #"say "hi" \ bye"#, "null", "42", "3.0", "true", "tab\there", "emoji 👋🏽 and é", #"{"a": 1}"#, "\\n stays",
  ])
  func keepsTextThatLooksLikeAnotherValue(_ text: String) {
    let result = TriageDrafts.verbatim([TriageDraft(text: text)], in: "Before.\n\n\(text)\n\nAfter.")

    #expect(result.kept.map(\.text) == [text])
  }

  @Test func theKeptTextHasNoCarriageReturns() {
    let result = TriageDrafts.verbatim([TriageDraft(text: "a\r\nb\r\n")], in: "a\r\nb\r\n")

    #expect(result.kept.first?.text.contains("\r") == false)
  }

  @Test func dropsADraftLongerThanTheLimitThatIsInTheReply() {
    let text = String(repeating: "a", count: TriageDrafts.maxLength + 1)

    let result = TriageDrafts.verbatim([TriageDraft(text: text)], in: text)

    #expect(result.kept.isEmpty)
    #expect(result.dropped.count == 1)
  }

  @Test func keepsADraftOfExactlyTheLimit() {
    let text = String(repeating: "a", count: TriageDrafts.maxLength)

    let result = TriageDrafts.verbatim([TriageDraft(text: text)], in: text)

    #expect(result.kept.map(\.text.count) == [TriageDrafts.maxLength])
  }

  /// The limit counts characters, and "é" takes two bytes in UTF-8.
  @Test func theLimitCountsCharactersNotBytes() {
    let text = String(repeating: "\u{E9}", count: TriageDrafts.maxLength)

    let result = TriageDrafts.verbatim([TriageDraft(text: text)], in: text)

    #expect(result.kept.count == 1)
  }

  @Test func theLimitsAreFiveDraftsOfTenThousandCharacters() {
    #expect(TriageDrafts.maxDrafts == 5)
    #expect(TriageDrafts.maxLength == 10_000)
  }
}

// MARK: The model's summary

@Suite struct TriageDraftParsing {
  @Test func keepsADraftThatIsInTheReply() throws {
    let output = modelOutput([["label": "HogQL", "text": .string(hogqlParagraphs)]])

    let summary = try TriageSummarizer.parse(output, reply: hogqlReply)

    #expect(summary.drafts == [TriageDraft(label: "HogQL", text: hogqlParagraphs)])
  }

  @Test func removesTheMarkersFromAQuotedCopy() throws {
    let output = modelOutput([["text": .string(hogqlQuoted)]])

    let summary = try TriageSummarizer.parse(output, reply: hogqlReply)

    #expect(summary.drafts.map(\.text) == [hogqlParagraphs])
  }

  @Test func dropsAParaphrase() throws {
    let output = modelOutput([
      ["label": "Copy", "text": .string(hogqlParagraphs)],
      ["label": "Paraphrase", "text": "Could a HogQL owner review PR 131397?"],
    ])

    let summary = try TriageSummarizer.parse(output, reply: hogqlReply)

    #expect(summary.drafts.map(\.label) == ["Copy"])
  }

  @Test func keepsNoDraftWithoutAReply() throws {
    let summary = try TriageSummarizer.parse(modelOutput([["text": "Could someone review #1?"]]), reply: "")

    #expect(summary.drafts.isEmpty)
  }

  @Test func anAnswerWithoutDraftsHasNone() throws {
    let output = modelEnvelope(["title": "Read the reply", "kind": "info", "summary": "It finished.", "options": []])

    let summary = try TriageSummarizer.parse(output, reply: hogqlReply)

    #expect(summary.drafts.isEmpty)
  }

  @Test func keepsTheFirstFiveDrafts() throws {
    let lines = (1...7).map { "Message \($0)." }
    let output = modelOutput(lines.map { ["text": .string($0)] })

    let summary = try TriageSummarizer.parse(output, reply: lines.joined(separator: "\n\n"))

    #expect(summary.drafts.map(\.text) == Array(lines.prefix(TriageDrafts.maxDrafts)))
  }

  @Test func dropsALongDraftRatherThanCuttingIt() throws {
    let long = String(repeating: "a", count: TriageDrafts.maxLength + 1)
    let output = modelOutput([["text": .string(long)], ["text": "Short one."]])

    let summary = try TriageSummarizer.parse(output, reply: "\(long)\n\nShort one.")

    #expect(summary.drafts.map(\.text) == ["Short one."])
  }

  /// The model sees only the end of a long reply. A draft that starts before
  /// that cut reaches the model without its start.
  @Test func dropsTheTailOfADraftThatStartsBeforeTheCut() throws {
    let draft = "Could someone review #1? \(String(repeating: "a", count: 100))\nThanks."
    let after = "\n\n" + String(repeating: "z", count: TriageSummarizer.replyCharacters - 50)
    let reply = "Here:\n\n\(draft)\(after)"
    let seen = String(reply.suffix(TriageSummarizer.replyCharacters))
    let copy = String(seen.dropLast(after.count))
    try #require(copy != draft && draft.hasSuffix(copy))

    let summary = try TriageSummarizer.parse(modelOutput([["text": .string(copy)]]), reply: reply)

    #expect(summary.drafts.isEmpty)
  }

  /// The cut falls on a line break, so the model sees whole lines of the draft but not its first line.
  @Test func dropsTheTailOfADraftWhenTheCutFallsOnALineBreak() throws {
    let after = "\n\n" + String(repeating: "z", count: TriageSummarizer.replyCharacters - "Second line.".count - 2)
    let reply = "Here:\n\nFirst line of the request.\nSecond line.\(after)"
    try #require(reply.suffix(TriageSummarizer.replyCharacters).hasPrefix("Second line."))

    let summary = try TriageSummarizer.parse(modelOutput([["text": "Second line."]]), reply: reply)

    #expect(summary.drafts.isEmpty)
  }

  /// Swift reads CRLF as one character, so the cut line must end at that character too.
  @Test func keepsADraftAfterTheCutOfALongCRLFReply() throws {
    let reply = String(repeating: "filler line\r\n", count: 2_000) + "Could someone review #1?\r\n"

    let summary = try TriageSummarizer.parse(modelOutput([["text": "Could someone review #1?"]]), reply: reply)

    #expect(summary.drafts.map(\.text) == ["Could someone review #1?"])
  }

  @Test func theSchemaHasDrafts() throws {
    let properties = try #require(TriageSummarizer.schema["properties"])

    #expect(properties["drafts"] != nil)
  }
}

// MARK: The session's card

@Suite struct TriageDraftCard {
  @Test func readsStringsAndObjects() throws {
    let raw = draftCard(["Plain draft.", ["label": "Review request", "text": "Could someone review #1?"]])

    let result = try TriageCard.clean(raw)

    #expect(result.card.drafts == [TriageDraft(text: "Plain draft."), reviewDraft])
    #expect(result.dropped.isEmpty)
  }

  @Test func keepsADraftThatNoReplyHolds() throws {
    let result = try TriageCard.clean(draftCard([["text": "Text that appears nowhere else."]]))

    #expect(result.card.drafts.map(\.text) == ["Text that appears nowhere else."])
  }

  @Test func aCardWithoutDraftsHasNone() throws {
    let result = try TriageCard.clean(["summary": "It finished."])

    #expect(result.card.drafts.isEmpty)
    #expect(result.dropped.isEmpty)
  }

  @Test(arguments: [
    ("\n\nHi\nthere\n\n", "Hi\nthere"),
    ("  \n\t\nHi\n \n", "Hi"),
    ("a\n\nb", "a\n\nb"),
    ("  indented first line", "  indented first line"),
  ])
  func trimsOnlyTheOuterBlankLines(_ text: String, _ expected: String) throws {
    let result = try TriageCard.clean(draftCard([.string(text)]))

    #expect(result.card.drafts.map(\.text) == [expected])
  }

  @Test func keepsTheFirstFiveAndReportsTheRest() throws {
    let texts = (1...7).map { "Draft \($0)." }

    let result = try TriageCard.clean(draftCard(texts.map { .string($0) }))

    #expect(result.card.drafts.map(\.text) == Array(texts.prefix(TriageDrafts.maxDrafts)))
    #expect(result.dropped.count == 1)
  }

  @Test func dropsALongDraftRatherThanCuttingIt() throws {
    let long = String(repeating: "x", count: TriageDrafts.maxLength + 1)

    let result = try TriageCard.clean(draftCard([.string(long), "Short one."]))

    #expect(result.card.drafts.map(\.text) == ["Short one."])
    #expect(result.dropped.count == 1)
  }

  @Test func keepsADraftOfExactlyTheLimit() throws {
    let text = String(repeating: "x", count: TriageDrafts.maxLength)

    let result = try TriageCard.clean(draftCard([.string(text)]))

    #expect(result.card.drafts.map(\.text.count) == [TriageDrafts.maxLength])
  }

  @Test(arguments: [
    JSON.null, .number(5), .bool(true), .array(["text"]), .object(["text": .number(5)]), .object(["label": "x"]),
    .string(""), .string("\n  \n"), .object(["label": "Empty", "text": ""]),
  ])
  func dropsADraftWithoutText(_ draft: JSON) throws {
    let result = try TriageCard.clean(draftCard([draft, "Fine."]))

    #expect(result.card.drafts.map(\.text) == ["Fine."])
    #expect(result.dropped.count == 1)
  }

  @Test(arguments: [
    #"say "hi" \ bye"#, "null", "42", "true", "line\nbreak", "emoji 👋🏽", #"{"a": 1}"#, "**bold** and `code`",
  ])
  func keepsTextThatLooksLikeAnotherValue(_ text: String) throws {
    let raw = try #require(JSON.parse(draftCard([.string(text)]).text))

    let result = try TriageCard.clean(raw)

    #expect(result.card.drafts.map(\.text) == [text])
  }

  @Test func aDraftWithoutALabelHasNone() throws {
    let result = try TriageCard.clean(draftCard([["text": "Hi."]]))

    #expect(result.card.drafts == [TriageDraft(text: "Hi.")])
  }

  @Test func theInstructionsNameDrafts() {
    #expect(TriageCard.instructions.contains("drafts"))
  }
}

// MARK: Card and model agree

@Suite struct TriageDraftParity {
  /// Each text appears verbatim in the reply with no markers, so the card
  /// path and the model path keep the same draft.
  @Test(arguments: [
    hogqlParagraphs, "Could someone review #1?", #"say "hi" \ bye"#, "null", "42", "emoji 👋🏽 and é",
    "**bold** and `code`", "Hi team,\n\nplease review #5.",
  ])
  func theCardAndTheModelKeepTheSameDraft(_ text: String) throws {
    let draft: JSON = ["label": "Message", "text": .string(text)]
    let reply = "Here is the message:\n\n\(text)\n\nPaste it."

    let card = try TriageCard.clean(draftCard([draft])).card.drafts
    let model = try TriageSummarizer.parse(modelOutput([draft]), reply: reply).drafts

    #expect(card == model)
    #expect(card == [TriageDraft(label: "Message", text: text)])
  }
}

// MARK: Coding and the item

@Suite struct TriageDraftCoding {
  @Test func aSummaryWithoutDraftsEncodesAnEmptyList() throws {
    let json = try JSON(encoding: sessionCard)

    #expect(json["drafts"] == .array([]))
  }

  @Test func aSummaryWithDraftsEncodesThem() throws {
    var summary = sessionCard
    summary.drafts = [reviewDraft]

    let json = try JSON(encoding: summary)

    #expect(json["drafts"]?.array?.first?["text"]?.string == "Could someone review #1?")
    #expect(json["drafts"]?.array?.first?["label"]?.string == "Review request")
  }

  @Test func aSummaryRoundTripsItsDrafts() throws {
    var summary = sessionCard
    summary.drafts = [reviewDraft, TriageDraft(text: "No label.")]

    let decoded = try JSONCoding.convert(try JSON(encoding: summary), to: TriageSummary.self)

    #expect(decoded == summary)
  }

  @Test func aSummaryWithoutTheKeyDecodesWithNone() throws {
    let json = #"{"title":"Pick","kind":"decision","summary":"It asks.","options":[]}"#

    #expect(try JSONCoding.decode(TriageSummary.self, from: json).drafts.isEmpty)
  }

  @Test func anItemWithoutTheKeyDecodesWithNone() throws {
    let old: JSON = [
      "title": "t", "kind": "info", "summary": "s", "options": [], "callouts": [], "source": "rule", "ref": "r",
    ]

    let decoded = try JSONCoding.convert(old, to: TriageItem.self)

    #expect(decoded.drafts.isEmpty)
    #expect(decoded.message.summary.drafts.isEmpty)
  }

  @Test func aDraftWithoutALabelDecodesWithNone() throws {
    let decoded = try JSONCoding.decode(TriageDraft.self, from: #"{"text":"Hi."}"#)

    #expect(decoded == TriageDraft(text: "Hi."))
  }

  /// A turn that ended in prose, with a session card that has drafts.
  func drafted(_ drafts: [TriageDraft] = [reviewDraft]) throws -> SessionFacts {
    var summary = sessionCard
    summary.drafts = drafts
    return facts([
      event("UserPromptSubmit", 0, ["prompt": "go"]), try summaryEvent(2, 1, summary), stop(3, 2, proseQuestion),
    ])
  }

  @Test func theSessionsCardGivesTheItemItsDrafts() throws {
    let item = try #require(itemOf(try drafted()))

    #expect(item.drafts == [reviewDraft])
  }

  @Test func theMessageSummaryCarriesTheItemsDrafts() throws {
    let item = try #require(itemOf(try drafted()))

    #expect(item.message.summary.drafts == item.drafts)
  }

  @Test func theItemEncodesItsDraftsOnlyInTheMessage() throws {
    let item = try #require(itemOf(try drafted()))

    let json = try JSON(encoding: item)

    #expect(json["message"]?["summary"]?["drafts"]?.array?.first?["text"]?.string == "Could someone review #1?")
    #expect(json["message"]?["summary"]?["drafts"]?.array?.first?["label"]?.string == "Review request")
    #expect(json["drafts"] == nil)
  }

  @Test func anItemRoundTripsItsDrafts() throws {
    let item = try #require(itemOf(try drafted([reviewDraft, TriageDraft(text: "No label.")])))

    let decoded = try JSONCoding.convert(try JSON(encoding: item), to: TriageItem.self)

    #expect(decoded == item)
    #expect(decoded.drafts.count == 2)
  }

  @Test func anItemWithoutDraftsHasNone() throws {
    let item = try #require(itemOf(try drafted([])))

    #expect(item.drafts.isEmpty)
    #expect(item.message.summary.drafts.isEmpty)
  }

  /// sbd records the model's summary, drafts included, as a `triage` event.
  @Test func theModelsSummaryGivesTheItemItsDrafts() throws {
    let triage = Event(
      id: 3, session: "s1", t: 100, kind: "triage",
      data: [
        "stop": .number(2), "title": "Send the review request", "kind": "info", "summary": "It drafted one.",
        "options": [], "drafts": [["label": "Review request", "text": "Could someone review #1?"]],
      ])
    let f = facts([
      event("UserPromptSubmit", 0, ["prompt": "go"]), stop(2, 1, "Paste this:\n\nCould someone review #1?"), triage,
    ])

    let item = try #require(itemOf(f))

    #expect(item.source == .summary)
    #expect(item.drafts == [reviewDraft])
  }
}
