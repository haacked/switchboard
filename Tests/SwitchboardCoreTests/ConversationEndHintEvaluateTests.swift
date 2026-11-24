import Foundation
import Testing

@testable import SwitchboardCore

/// `EndHint.evaluate` decides whether a Manager conversation's header suggests ending it. The done hint shows when
/// the conversation spawned at least one session, each of them is Done or gone, and the conversation has no waits,
/// pause condition, or schedules of its own. The context hint shows when the context reached the threshold, which 0
/// turns off. No hint shows while a turn or a background job runs, while a message is on its way, or while the
/// conversation needs the user. When both rules hold, the done hint shows. A dismissed key hides the hint until the
/// key changes.
@Suite struct ConversationEndHintEvaluateTests {
  static let threshold = 120_000
  static let doneText = "Every session this conversation started is done. End it to start fresh."

  func evaluate(
    spawned: [String: AttentionState?] = [:], hasOwnItems: Bool = false, inTurnOrJob: Bool = false,
    messageOnItsWay: Bool = false, needsMe: Bool = false, contextTokens: Int? = nil, threshold: Int = threshold,
    dismissed: String? = nil
  ) -> EndHint? {
    EndHint.evaluate(
      spawned: spawned, hasOwnItems: hasOwnItems, inTurnOrJob: inTurnOrJob, messageOnItsWay: messageOnItsWay,
      needsMe: needsMe, contextTokens: contextTokens, threshold: threshold, dismissed: dismissed)
  }

  /// The hint's `reason` as its JSON carries it, which is what `sb --json` and the app read.
  func reason(_ hint: EndHint?) throws -> String? {
    guard let hint else { return nil }
    return try JSON(encoding: hint)["reason"]?.string
  }

  // MARK: The done rule (Risk 6)

  @Test func oneDoneChildShowsTheDoneHint() throws {
    let hint = evaluate(spawned: ["k1": .done])

    #expect(try reason(hint) == "done")
    #expect(hint?.key == "done:1")
    #expect(hint?.tokens == nil)
  }

  @Test func theDoneHintSaysEverySessionIsDone() {
    #expect(evaluate(spawned: ["k1": .done])?.text == Self.doneText)
  }

  /// A nil state means the child is gone from sbd. Removal is the user's or the Operator's decision, so a child
  /// removed before it reached Done counts as finished too.
  @Test func aChildThatIsGoneCountsAsFinished() throws {
    let hint = evaluate(spawned: ["k1": nil])

    #expect(try reason(hint) == "done")
    #expect(hint?.key == "done:1")
  }

  /// The key counts every spawned session, gone or not.
  @Test func theKeyCountsDoneAndGoneChildren() throws {
    let hint = evaluate(spawned: ["k1": .done, "k2": nil, "k3": .done])

    #expect(try reason(hint) == "done")
    #expect(hint?.key == "done:3")
  }

  @Test func noChildrenShowsNoHint() {
    #expect(evaluate(spawned: [:]) == nil)
  }

  @Test(arguments: AttentionState.allCases.filter { $0 != .done })
  func aChildThatIsNotDoneBlocksTheDoneHint(_ state: AttentionState) {
    #expect(evaluate(spawned: ["k1": .done, "k2": state]) == nil)
  }

  @Test(arguments: AttentionState.allCases.filter { $0 != .done })
  func anOnlyChildThatIsNotDoneBlocksTheDoneHint(_ state: AttentionState) {
    #expect(evaluate(spawned: ["k1": state]) == nil)
  }

  /// An own wait, pause condition, or schedule.
  @Test func anOwnItemBlocksTheDoneHint() {
    #expect(evaluate(spawned: ["k1": .done], hasOwnItems: true) == nil)
  }

  // MARK: The context rule

  @Test(arguments: [
    (120_000, "context:1"), (239_999, "context:1"), (240_000, "context:2"), (359_999, "context:2"),
    (360_000, "context:3"),
  ])
  func atOrAboveTheThresholdShowsTheContextHintKeyedToTheMultiple(_ tokens: Int, _ key: String) throws {
    let hint = evaluate(contextTokens: tokens)

    #expect(try reason(hint) == "context")
    #expect(hint?.key == key)
    #expect(hint?.tokens == tokens)
  }

  @Test func belowTheThresholdShowsNoHint() {
    #expect(evaluate(contextTokens: 119_999) == nil)
  }

  @Test func noContextValueShowsNoHint() {
    #expect(evaluate(contextTokens: nil) == nil)
  }

  @Test(arguments: [0, 120_000, 10_000_000])
  func aThresholdOfZeroTurnsTheContextHintOff(_ tokens: Int) {
    #expect(evaluate(contextTokens: tokens, threshold: 0) == nil)
  }

  @Test func belowAHigherThresholdShowsNoHint() {
    #expect(evaluate(contextTokens: 250_000, threshold: 300_000) == nil)
  }

  @Test func theKeyDividesByTheGivenThreshold() {
    #expect(evaluate(contextTokens: 650_000, threshold: 300_000)?.key == "context:2")
  }

  @Test func theContextHintSaysTheSizeInThousands() {
    let hint = evaluate(contextTokens: 312_000)

    #expect(
      hint?.text == "This conversation's context is 312k tokens, and each turn re-reads it. End it to start fresh.")
  }

  /// The End flow asks about the conversation's own waits and schedules, so they do not hide the context hint.
  @Test func ownWaitsAndSchedulesLeaveTheContextHint() throws {
    let hint = evaluate(hasOwnItems: true, contextTokens: 250_000)

    #expect(try reason(hint) == "context")
  }

  // MARK: Both rules

  @Test func whenBothRulesHoldTheDoneHintShows() throws {
    let hint = evaluate(spawned: ["k1": .done], contextTokens: 250_000)

    #expect(try reason(hint) == "done")
    #expect(hint?.key == "done:1")
  }

  @Test func anOwnWaitWithAFullContextGivesTheContextHint() throws {
    let hint = evaluate(spawned: ["k1": .done], hasOwnItems: true, contextTokens: 250_000)

    #expect(try reason(hint) == "context")
  }

  // MARK: What hides both

  /// Inputs under which one rule or the other holds.
  enum Eligible: String, CaseIterable, CustomTestStringConvertible {
    case done, context

    var testDescription: String { rawValue }
    var spawned: [String: AttentionState?] { self == .done ? ["k1": .done] : [:] }
    var contextTokens: Int? { self == .context ? 250_000 : nil }
  }

  @Test(arguments: Eligible.allCases)
  func eachEligibleInputShowsItsHint(_ input: Eligible) throws {
    let hint = evaluate(spawned: input.spawned, contextTokens: input.contextTokens)

    #expect(try reason(hint) == input.rawValue)
  }

  @Test(arguments: Eligible.allCases)
  func aRunningTurnOrJobHidesTheHint(_ input: Eligible) {
    #expect(evaluate(spawned: input.spawned, inTurnOrJob: true, contextTokens: input.contextTokens) == nil)
  }

  /// Ending the conversation would refuse while a message is queued for it or claude has not confirmed one.
  @Test(arguments: Eligible.allCases)
  func aMessageOnItsWayHidesTheHint(_ input: Eligible) {
    #expect(evaluate(spawned: input.spawned, messageOnItsWay: true, contextTokens: input.contextTokens) == nil)
  }

  @Test(arguments: Eligible.allCases)
  func aConversationThatNeedsTheUserShowsNoHint(_ input: Eligible) {
    #expect(evaluate(spawned: input.spawned, needsMe: true, contextTokens: input.contextTokens) == nil)
  }

  // MARK: Dismissal

  @Test func aDismissedDoneKeyHidesTheDoneHint() {
    #expect(evaluate(spawned: ["k1": .done], dismissed: "done:1") == nil)
  }

  /// The conversation spawned another session and that one reached Done too.
  @Test func aGrownCountShowsTheDoneHintAgain() {
    let hint = evaluate(spawned: ["k1": .done, "k2": .done], dismissed: "done:1")

    #expect(hint?.key == "done:2")
  }

  @Test func aDismissedContextKeyHidesTheContextHint() {
    #expect(evaluate(contextTokens: 250_000, dismissed: "context:2") == nil)
  }

  @Test func theNextMultipleOfTheThresholdShowsTheContextHintAgain() {
    let hint = evaluate(contextTokens: 360_000, dismissed: "context:2")

    #expect(hint?.key == "context:3")
  }

  /// The key names its reason, so a dismissed context hint whose number matches the done count hides nothing.
  @Test func aDismissedKeyOfTheOtherReasonHidesNothing() throws {
    let hint = evaluate(spawned: ["k1": .done], dismissed: "context:1")

    #expect(try reason(hint) == "done")
  }
}
