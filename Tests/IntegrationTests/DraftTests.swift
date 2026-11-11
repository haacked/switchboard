import Foundation
import SwitchboardCore
import Testing

/// A card as a session writes it with `sb summary set`, with one draft.
private let draftCard = #"""
  {"summary": "Drafted a review request.\nPaste it to HogQL.", "drafts": [{"label": "Review request", "text": "Could someone review #1?"}]}
  """#

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

/// The drafts that a session or the model writes reach the item that
/// `sb get --json` prints.
@Suite(.blocking(timeLimit: .seconds(120))) struct DraftTests {
  @Test func summarySetShowsTheDraftOnTheItem() throws {
    let sbd = try Instance()
    let s = try sbd.endedSession()

    let result = try sbd.setSummary(s.id, draftCard)

    #expect(result.stdout.contains("1 draft"), "\(result.stdout)")
    try sbd.waitFor(s.id, "the session's card") { $0.triage?.source == .session }
    let row = try #require(JSON.parse(try sbd.sb("get", s.id, "--json")))
    let drafts = try #require(row["triage"]?["message"]?["summary"]?["drafts"]?.array)
    #expect(drafts.count == 1)
    #expect(drafts.first?["text"]?.string == "Could someone review #1?")
    #expect(drafts.first?["label"]?.string == "Review request")
  }

  /// `sb triage` prints the draft between the Summary and the Action.
  @Test func theTextListingPrintsTheDraftBeforeTheAction() throws {
    let sbd = try Instance()
    let s = try sbd.endedSession()
    try sbd.setSummary(s.id, draftCard)
    try sbd.waitFor(s.id, "the session's card") { $0.triage?.source == .session }

    let text = try sbd.sb("triage")

    #expect(text.contains("> Could someone review #1?"), "\(text)")
    let headings = ["Summary:", "Draft: Review request:", "Action:"].map { text.range(of: $0)?.lowerBound }
    #expect(headings.allSatisfy { $0 != nil }, "\(text)")
    #expect(headings.compactMap { $0 } == headings.compactMap { $0 }.sorted())
  }

  /// The model's answer names a quoted copy and a paraphrase. Only the copy
  /// is in the reply, so only it reaches the item, without its markers.
  @Test func theModelsSummaryKeepsOnlyTheDraftThatIsInTheReply() throws {
    let sbd = try Instance()
    try hogqlReply.write(toFile: "\(sbd.home.path)/hogql.md", atomically: true, encoding: .utf8)
    let quoted = hogqlParagraphs.split(separator: "\n", omittingEmptySubsequences: false)
      .map { $0.isEmpty ? ">" : "> \($0)" }.joined(separator: "\n")
    let answer: JSON = [
      "title": "Send the review request", "kind": "info", "summary": "It drafted a review request for HogQL.",
      "options": [],
      "drafts": [
        ["label": "Quoted", "text": .string(quoted)],
        ["label": "Paraphrase", "text": "Could a HogQL owner review PR 131397?"],
      ],
    ]
    try answer.text.write(toFile: "\(sbd.home.path)/summary-answer.json", atomically: true, encoding: .utf8)

    let s = try sbd.new(prompt: "reply hogql")

    let item = try #require(try sbd.waitFor(s.id, "the summary") { $0.triage?.source == .summary }.triage)
    #expect(item.drafts == [TriageDraft(label: "Quoted", text: hogqlParagraphs)])
  }
}
