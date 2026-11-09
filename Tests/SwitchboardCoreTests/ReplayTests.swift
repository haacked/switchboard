import Foundation
import Testing

@testable import SwitchboardCore

/// A `sent` event for a message that sbd accepted, as this sbd records it.
private func sent(_ text: String, _ delivery: Delivery, _ t: Int64) -> Event {
  var data: [String: JSON] = ["text": .string(text), "delivery": .string(delivery.rawValue)]
  if delivery == .pasted { data[Delivery.awaitsDeliveredKey] = true }
  return event("sent", t, data)
}

/// A `sent` event for a direct paste, as an sbd from before `delivered`
/// followed direct pastes recorded it.
private func oldSent(_ text: String, _ t: Int64) -> Event {
  event("sent", t, ["text": .string(text), "delivery": .string(Delivery.pasted.rawValue)])
}

/// One of the events that follow a message after sbd accepted it.
private func after(_ kind: String, _ text: String, _ t: Int64) -> Event {
  event(kind, t, ["text": .string(text)])
}

private func replay(_ events: [Event]) -> SessionReplay {
  .replaying(events, session: session())
}

/// The deliveries whose message goes through the paste queue.
private let pasteDeliveries: [Delivery] = [.pasted, .queued]

/// What a restart of sbd rebuilds for the messages on their way: `pending`
/// holds the ones that sbd pastes again, and `uncertain` holds the ones whose
/// paste started and may or may not have reached claude.
@Suite struct ReplayDeliveryTests {
  @Test(arguments: pasteDeliveries)
  func anAcceptedMessageStaysPendingUntilDelivered(_ delivery: Delivery) {
    let r = replay([sent("fix it", delivery, 1)])

    #expect(r.pending == ["fix it"])
  }

  @Test(arguments: pasteDeliveries)
  func deliveredTakesTheMessageOutOfPending(_ delivery: Delivery) {
    let r = replay([sent("fix it", delivery, 1), after("pasting", "fix it", 2), after("delivered", "fix it", 3)])

    #expect(r.pending.isEmpty)
    #expect(r.uncertain.isEmpty)
  }

  @Test(arguments: pasteDeliveries)
  func pastingWithoutDeliveredMakesTheMessageUncertainRatherThanPending(_ delivery: Delivery) {
    let r = replay([sent("fix it", delivery, 1), after("pasting", "fix it", 2)])

    #expect(r.pending.isEmpty)
    #expect(r.uncertain == ["fix it"])
  }

  @Test func deliveryUnknownDropsTheUncertainMessage() {
    let r = replay([
      sent("fix it", .pasted, 1), after("pasting", "fix it", 2), after("delivery_unknown", "fix it", 3),
    ])

    #expect(r.pending.isEmpty)
    #expect(r.uncertain.isEmpty)
  }

  /// A failed paste is known not to have arrived, so the message waits to be
  /// pasted again, once, whether sbd pasted it at once or from its queue.
  @Test(arguments: pasteDeliveries, [false, true])
  func aFailedPasteKeepsTheMessagePendingOnce(_ delivery: Delivery, _ started: Bool) {
    let r = replay(
      [sent("fix it", delivery, 1)] + (started ? [after("pasting", "fix it", 2)] : [])
        + [after("requeued", "fix it", 3)])

    #expect(r.pending == ["fix it"])
    #expect(r.uncertain.isEmpty)
  }

  /// A log from before `pasting` existed has `requeued` after a failed direct
  /// paste whose `sent` added nothing to `pending`.
  @Test func anOldFailedDirectPasteIsPendingOnce() {
    let r = replay([oldSent("fix it", 1), after("requeued", "fix it", 2)])

    #expect(r.pending == ["fix it"])
    #expect(r.uncertain.isEmpty)
  }

  /// A failed paste goes back to the front of the queue, ahead of the
  /// messages that came after it, as sbd puts it back.
  @Test func aFailedPasteGoesBackAheadOfLaterMessages() {
    let r = replay([
      sent("one", .queued, 1), sent("two", .queued, 2), after("pasting", "one", 3), after("requeued", "one", 4),
    ])

    #expect(r.pending == ["one", "two"])
    #expect(r.uncertain.isEmpty)
  }

  /// claude got the message as the prompt of its launch, so no paste follows.
  @Test func aMessageThatStartedClaudeIsNotPending() {
    let r = replay([sent("fix it", .resumed, 1)])

    #expect(r.pending.isEmpty)
    #expect(r.uncertain.isEmpty)
  }

  /// A resend after an unknown delivery is a new send that waits for its own `delivered`.
  @Test func aResendAfterAnUnknownDeliveryIsPendingUntilDelivered() {
    let r = replay([
      sent("fix it", .pasted, 1), after("pasting", "fix it", 2), after("delivery_unknown", "fix it", 3),
      sent("fix it", .pasted, 4),
    ])

    #expect(r.pending == ["fix it"])
    #expect(r.uncertain.isEmpty)
  }

  @Test func anUncertainMessageLeavesTheOthersPendingInOrder() {
    let r = replay([
      sent("one", .queued, 1), sent("two", .queued, 2), sent("three", .queued, 3), after("pasting", "one", 4),
    ])

    #expect(r.pending == ["two", "three"])
    #expect(r.uncertain == ["one"])
  }

  /// A log from an sbd that wrote no `awaitsDeliveredKey` holds a `sent` with
  /// delivery `pasted` and no `delivered` for every direct paste. A new build
  /// replays every log in full. sbd pastes restored messages on load. Only a
  /// `sent` that carries `awaitsDeliveredKey` waits for its `delivered`, so
  /// none of those old messages reaches its session again.
  @Test func anOldDirectPasteWhosePromptLandedIsNotPending() {
    let r = replay([
      oldSent("fix it", 1), event("UserPromptSubmit", 2, ["prompt": "fix it"]),
      event("Stop", 3, ["last_assistant_message": "Done."]),
    ])

    #expect(r.pending.isEmpty)
    #expect(r.uncertain.isEmpty)
  }

  /// Nothing after the old `sent` shows that the paste arrived, and it still isn't pending.
  @Test func anOldDirectPasteWithoutAPromptIsNotPending() {
    let r = replay([oldSent("fix it", 1), oldSent("and this", 2)])

    #expect(r.pending.isEmpty)
    #expect(r.uncertain.isEmpty)
  }

  /// The field must say true. Another value is not one that sbd writes.
  @Test func aDirectPasteWhoseFieldIsNotTrueIsNotPending() {
    let r = replay([
      event(
        "sent", 1,
        ["text": "fix it", "delivery": .string(Delivery.pasted.rawValue), Delivery.awaitsDeliveredKey: "yes"])
    ])

    #expect(r.pending.isEmpty)
  }

  /// A UserPromptSubmit doesn't settle a paste that sbd started. Only
  /// `delivered` or `delivery_unknown` does, and the check on load records
  /// one of them.
  @Test func aStartedPasteWhosePromptLandedStaysUncertain() {
    let r = replay([
      sent("fix it", .queued, 1), after("pasting", "fix it", 2), event("UserPromptSubmit", 3, ["prompt": "fix it"]),
    ])

    #expect(r.pending.isEmpty)
    #expect(r.uncertain == ["fix it"])
  }

  /// The replay is what a snapshot stores, so `uncertain` survives a snapshot.
  @Test func theUncertainMessagesSurviveEncoding() throws {
    let r = replay([sent("fix it", .pasted, 1), after("pasting", "fix it", 2)])

    let decoded = try JSONCoding.decode(SessionReplay.self, from: try JSONCoding.encode(r))

    #expect(decoded.uncertain == ["fix it"])
  }
}
