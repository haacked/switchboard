import Foundation
import Testing

@testable import SwitchboardCore

/// `SentMark.of` reads the events that sbd stores: a `sent` event and the `pasting` events after it. Each
/// `pasting` stores `transcript_bytes`, `conversation`, and `sent` as `startPaste` writes them.
@Suite struct SentMarkTests {
  private static let prompt = "Check the deploy queue."
  private static let run: Int64 = 10

  private static func sent(
    _ id: Int64 = SentMarkTests.run, kind: String = "sent", delivery: Delivery = .queued, _ extra: [String: JSON] = [:]
  ) -> Event {
    let data: [String: JSON] = ["text": .string(prompt), "delivery": .string(delivery.rawValue), "by": "sbd"]
    return Event(id: id, session: "s1", t: id, kind: kind, data: .object(data.merging(extra) { $1 }))
  }

  /// A `resumed` `sent` event that measured the transcript before the launch.
  private static func resumed(conversation: String? = "c1", bytes: UInt64? = 300) -> Event {
    var extra: [String: JSON] = [:]
    if let conversation { extra["conversation"] = .string(conversation) }
    if let bytes { extra["transcript_bytes"] = .number(Double(bytes)) }
    return sent(delivery: .resumed, extra)
  }

  private static func pasting(
    _ id: Int64, sent: Int64?, bytes: UInt64?, conversation: String? = "c1", text: String = SentMarkTests.prompt
  ) -> Event {
    var data: [String: JSON] = ["text": .string(text)]
    if let bytes {
      data["transcript"] = "/box/home/.claude/projects/-box-repo/c1.jsonl"
      data["transcript_bytes"] = .number(Double(bytes))
    }
    if let conversation { data["conversation"] = .string(conversation) }
    if let sent { data["sent"] = .number(Double(sent)) }
    return Event(id: id, session: "s1", t: id, kind: "pasting", data: .object(data))
  }

  private static func mark(from: UInt64, before: UInt64? = nil, conversation: String = "c1") -> SentMark {
    SentMark(sent: run, conversation: conversation, from: from, before: before, text: prompt)
  }

  // MARK: Where the mark starts

  @Test func onePastingThatNamesTheRunGivesItsOffsetAndConversation() {
    let pastings = [Self.pasting(11, sent: Self.run, bytes: 500)]

    let mark = SentMark.of(sent: Self.sent(), later: pastings, text: Self.prompt)

    #expect(mark == Self.mark(from: 500))
  }

  @Test func aRequeuedPasteStartsTheMarkAtTheLastPastingAndItDoesNotEndTheMark() {
    let pastings = [Self.pasting(11, sent: Self.run, bytes: 500), Self.pasting(12, sent: Self.run, bytes: 700)]

    let mark = SentMark.of(sent: Self.sent(), later: pastings, text: Self.prompt)

    #expect(mark == Self.mark(from: 700))
  }

  @Test func aRequeuedPasteEndsTheMarkAtTheNextPastingOfAnotherMessage() {
    let pastings = [
      Self.pasting(11, sent: Self.run, bytes: 500),
      Self.pasting(12, sent: Self.run, bytes: 700),
      Self.pasting(13, sent: 99, bytes: 900),
    ]

    let mark = SentMark.of(sent: Self.sent(), later: pastings, text: Self.prompt)

    #expect(mark == Self.mark(from: 700, before: 900))
  }

  /// A message that the user queued ahead of the run pastes first, and it is not the run's message.
  @Test func aPastingOfAnotherMessageBeforeTheRunsPastingDoesNotEndTheMark() {
    let pastings = [
      Self.pasting(11, sent: 99, bytes: 500, text: "Mine."), Self.pasting(12, sent: Self.run, bytes: 700),
    ]

    let mark = SentMark.of(sent: Self.sent(), later: pastings, text: Self.prompt)

    #expect(mark == Self.mark(from: 700))
  }

  @Test func theMarkStartsAtTheLastPastingThatNamesTheRunEvenWithAnotherPastingBetween() {
    let pastings = [
      Self.pasting(11, sent: Self.run, bytes: 500),
      Self.pasting(12, sent: 99, bytes: 600),
      Self.pasting(13, sent: Self.run, bytes: 700),
    ]

    let mark = SentMark.of(sent: Self.sent(), later: pastings, text: Self.prompt)

    #expect(mark == Self.mark(from: 700))
  }

  @Test func aPastingWithNoTranscriptBytesStartsTheMarkAtZero() {
    let pastings = [Self.pasting(11, sent: Self.run, bytes: nil)]

    let mark = SentMark.of(sent: Self.sent(), later: pastings, text: Self.prompt)

    #expect(mark == Self.mark(from: 0))
  }

  @Test(arguments: [Delivery.pasted, .queued, .resumed])
  func aPastingThatNamesTheRunStartsTheMarkWhateverTheDelivery(_ delivery: Delivery) {
    let pastings = [Self.pasting(11, sent: Self.run, bytes: 500)]

    let mark = SentMark.of(sent: Self.sent(delivery: delivery), later: pastings, text: Self.prompt)

    #expect(mark?.from == 500)
  }

  @Test func aResumedRunWithNoPastingTakesItsMarkFromItsSentEvent() {
    let mark = SentMark.of(sent: Self.resumed(), later: [], text: Self.prompt)

    #expect(mark == Self.mark(from: 300))
  }

  @Test func aResumedRunIntoANewTranscriptStartsTheMarkAtZero() {
    let mark = SentMark.of(sent: Self.resumed(bytes: 0), later: [], text: Self.prompt)

    #expect(mark == Self.mark(from: 0))
  }

  /// `closeTrust` requeues a launch prompt without its `sent` id, so its paste names no run.
  @Test func aResumedRunFollowedByAPastingWithNoSentEndsTheMarkThere() {
    let pastings = [Self.pasting(11, sent: nil, bytes: 450)]

    let mark = SentMark.of(sent: Self.resumed(), later: pastings, text: Self.prompt)

    #expect(mark == Self.mark(from: 300, before: 450))
  }

  /// A loop slower than the idle stop launches claude with each run's prompt, so no `pasting` follows the run.
  @Test func theNextResumedRunInTheSameConversationEndsTheMark() {
    let next = Self.sent(
      11, delivery: .resumed, ["conversation": "c1", "transcript_bytes": .number(700)])

    let mark = SentMark.of(sent: Self.resumed(), later: [next], text: Self.prompt)

    #expect(mark == Self.mark(from: 300, before: 700))
  }

  @Test func aPastedRunEndsAtTheNextResumedRun() {
    let later = [
      Self.pasting(11, sent: Self.run, bytes: 500),
      Self.sent(12, delivery: .resumed, ["conversation": "c1", "transcript_bytes": .number(900)]),
    ]

    let mark = SentMark.of(sent: Self.sent(), later: later, text: Self.prompt)

    #expect(mark == Self.mark(from: 500, before: 900))
  }

  /// A launch in another conversation, or one that recorded no start, wrote nothing to this conversation's file
  /// that the mark can bound.
  @Test(arguments: [
    ["conversation": "c2", "transcript_bytes": .number(700)] as [String: JSON],
    ["conversation": "c1"],
    [:],
  ])
  func aResumedRunThatCannotBoundTheMarkLeavesItOpen(_ extra: [String: JSON]) {
    let next = Self.sent(11, delivery: .resumed, extra)

    let mark = SentMark.of(sent: Self.resumed(), later: [next], text: Self.prompt)

    #expect(mark == Self.mark(from: 300))
  }

  /// A queued or pasted message's `sent` event comes before its `pasting`, which ends the mark instead.
  @Test(arguments: [Delivery.queued, .pasted])
  func aSentEventThatDidNotLaunchClaudeLeavesTheMarkOpen(_ delivery: Delivery) {
    let next = Self.sent(11, delivery: delivery, ["conversation": "c1", "transcript_bytes": .number(700)])

    let mark = SentMark.of(sent: Self.resumed(), later: [next], text: Self.prompt)

    #expect(mark == Self.mark(from: 300))
  }

  @Test func aResumedRunThatAPastingAlsoNamesTakesItsMarkFromThePasting() {
    let pastings = [Self.pasting(11, sent: Self.run, bytes: 800, conversation: "c2")]

    let mark = SentMark.of(sent: Self.resumed(), later: pastings, text: Self.prompt)

    #expect(mark == Self.mark(from: 800, conversation: "c2"))
  }

  // MARK: Where the mark ends

  @Test func aLaterPastingInTheSameConversationEndsTheMark() {
    let pastings = [Self.pasting(11, sent: Self.run, bytes: 500), Self.pasting(12, sent: 99, bytes: 900)]

    let mark = SentMark.of(sent: Self.sent(), later: pastings, text: Self.prompt)

    #expect(mark == Self.mark(from: 500, before: 900))
  }

  @Test func aLaterPastingInAnotherConversationDoesNotEndTheMark() {
    let pastings = [
      Self.pasting(11, sent: Self.run, bytes: 500), Self.pasting(12, sent: 99, bytes: 40, conversation: "c2"),
    ]

    let mark = SentMark.of(sent: Self.sent(), later: pastings, text: Self.prompt)

    #expect(mark == Self.mark(from: 500))
  }

  /// The search skips a pasting into another conversation and keeps looking, instead of stopping at it.
  @Test func aPastingInAnotherConversationIsSkippedAndTheNextOneInTheSameConversationEndsTheMark() {
    let pastings = [
      Self.pasting(11, sent: Self.run, bytes: 500),
      Self.pasting(12, sent: 98, bytes: 40, conversation: "c2"),
      Self.pasting(13, sent: 99, bytes: 900),
    ]

    let mark = SentMark.of(sent: Self.sent(), later: pastings, text: Self.prompt)

    #expect(mark == Self.mark(from: 500, before: 900))
  }

  /// An older sbd wrote no `conversation`, and counting it as the same conversation can only shorten the mark.
  @Test func aLaterPastingWithNoConversationEndsTheMark() {
    let pastings = [
      Self.pasting(11, sent: Self.run, bytes: 500), Self.pasting(12, sent: 99, bytes: 900, conversation: nil),
    ]

    let mark = SentMark.of(sent: Self.sent(), later: pastings, text: Self.prompt)

    #expect(mark == Self.mark(from: 500, before: 900))
  }

  @Test func aLaterPastingWithNoSentEndsTheMark() {
    let pastings = [Self.pasting(11, sent: Self.run, bytes: 500), Self.pasting(12, sent: nil, bytes: 900)]

    let mark = SentMark.of(sent: Self.sent(), later: pastings, text: Self.prompt)

    #expect(mark == Self.mark(from: 500, before: 900))
  }

  @Test func onlyTheFirstLaterPastingEndsTheMark() {
    let pastings = [
      Self.pasting(11, sent: Self.run, bytes: 500),
      Self.pasting(12, sent: 98, bytes: 900),
      Self.pasting(13, sent: 99, bytes: 1_200),
    ]

    let mark = SentMark.of(sent: Self.sent(), later: pastings, text: Self.prompt)

    #expect(mark?.before == 900)
  }

  @Test func aLaterPastingWithNoTranscriptBytesEndsTheMarkAtZero() {
    let pastings = [Self.pasting(11, sent: Self.run, bytes: 500), Self.pasting(12, sent: 99, bytes: nil)]

    let mark = SentMark.of(sent: Self.sent(), later: pastings, text: Self.prompt)

    #expect(mark == Self.mark(from: 500, before: 0))
  }

  // MARK: What the mark carries

  /// The caller removes image paths from the text, so the mark keeps the text it gets, not the event's.
  @Test func theMarkCarriesTheTextItIsGivenAndTheSentEventsId() {
    let pastings = [Self.pasting(11, sent: Self.run, bytes: 500)]

    let mark = SentMark.of(sent: Self.sent(), later: pastings, text: "Check the deploy.")

    #expect(mark?.text == "Check the deploy.")
    #expect(mark?.sent == Self.run)
  }

  // MARK: No mark

  @Test(arguments: [Delivery.queued, .pasted])
  func aRunWithNoPastingYetGetsNoMark(_ delivery: Delivery) {
    let mark = SentMark.of(sent: Self.sent(delivery: delivery), later: [], text: Self.prompt)

    #expect(mark == nil)
  }

  /// After an sbd restart the queue holds the message without its `sent` id, so its paste names no run.
  @Test(arguments: [Delivery.queued, .pasted])
  func aRunWhoseOnlyPastingNamesNoSentGetsNoMark(_ delivery: Delivery) {
    let pastings = [Self.pasting(11, sent: nil, bytes: 500)]

    let mark = SentMark.of(sent: Self.sent(delivery: delivery), later: pastings, text: Self.prompt)

    #expect(mark == nil)
  }

  @Test func aRunWhoseOnlyPastingNamesAnotherRunGetsNoMark() {
    let pastings = [Self.pasting(11, sent: 99, bytes: 500)]

    let mark = SentMark.of(sent: Self.sent(), later: pastings, text: Self.prompt)

    #expect(mark == nil)
  }

  /// Only a launch with the prompt writes nothing to paste, so only a `resumed` event is its own start.
  @Test(arguments: [Delivery.queued, .pasted])
  func aSentEventThatIsNotResumedIsNotItsOwnStart(_ delivery: Delivery) {
    let event = Self.sent(delivery: delivery, ["conversation": "c1", "transcript_bytes": 300])

    let mark = SentMark.of(sent: event, later: [], text: Self.prompt)

    #expect(mark == nil)
  }

  /// A work session's resumed run, and a resumed run whose host did not answer the size read, record no mark.
  @Test func aResumedRunWithNoConversationGetsNoMark() {
    let mark = SentMark.of(sent: Self.resumed(conversation: nil), later: [], text: Self.prompt)

    #expect(mark == nil)
  }

  @Test func aResumedRunWithNoTranscriptBytesGetsNoMark() {
    let mark = SentMark.of(sent: Self.resumed(bytes: nil), later: [], text: Self.prompt)

    #expect(mark == nil)
  }

  @Test func aPastingThatNamesTheRunButNoConversationGivesNoMark() {
    let pastings = [Self.pasting(11, sent: Self.run, bytes: 500, conversation: nil)]

    let mark = SentMark.of(sent: Self.sent(), later: pastings, text: Self.prompt)

    #expect(mark == nil)
  }

  @Test(arguments: ["pasting", "delivered", "UserPromptSubmit", "schedule-ran"])
  func anEventOfAnotherKindGetsNoMark(_ kind: String) {
    let pastings = [Self.pasting(11, sent: Self.run, bytes: 500)]

    let mark = SentMark.of(sent: Self.sent(kind: kind), later: pastings, text: Self.prompt)

    #expect(mark == nil)
  }

  /// `ChatMessage.records` accepts every user message for an empty text, so an empty text can't pick one.
  @Test(arguments: ["", " ", "\n\t \n"])
  func anEmptyTextGetsNoMark(_ text: String) {
    let pastings = [Self.pasting(11, sent: Self.run, bytes: 500)]

    let mark = SentMark.of(sent: Self.sent(), later: pastings, text: text)

    #expect(mark == nil)
  }

  @Test func anEmptyTextGetsNoMarkOnAResumedRun() {
    let mark = SentMark.of(sent: Self.resumed(), later: [], text: "")

    #expect(mark == nil)
  }
}
