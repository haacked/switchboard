import Foundation
import Testing

@testable import SwitchboardCore

/// The Loops tab's Background Activity list, built from the Operator's own `report`, `wait-resolved`, and `judge`
/// events (#410, Decision 44). The fixtures below build each event in the shape that sbd records it.

// MARK: Builders

/// A `report` event as `recordReport` records it. A follow-through report names the wait whose action made it.
private func activityReport(
  _ id: Int64, _ text: String, needsYou: Bool = false, about: String? = nil, wait: String? = nil
) -> Event {
  var data: [String: JSON] = ["text": .string(text), "needsYou": .bool(needsYou)]
  if let about { data["about"] = .string(about) }
  if let wait { data["wait"] = .string(wait) }
  return Event(id: id, session: "op", t: id * 1000, kind: "report", data: .object(data))
}

/// An Operator wait on session `target`, or a PR merge wait whose action acts on `subject` when `subject` is set.
private func activityWait(_ id: String, watching target: String? = "k1", subject: String? = nil) -> Wait {
  var w: Wait
  if let target {
    w = Wait(
      id: id, kind: .session, session: Wait.SessionTarget(id: target, name: "kid"), state: .readyToMerge, created: 0)
  } else {
    w = Wait(id: id, kind: .merge, pr: Wait.PullRequest(repository: "o/r", number: 7), created: 0)
  }
  w.action = WaitAction(kind: target == nil ? .rmWorktree : .merge)
  w.subject = subject.map { Wait.SessionTarget(id: $0, name: "subj") }
  return w
}

/// A `wait-resolved` event as `finish` records it through `closeWait` when an action is done: the whole wait, the
/// outcome, and the action's kind, result, and detail.
private func actionResolved(_ id: Int64, _ wait: Wait, detail: String) throws -> Event {
  let action: JSON = [
    "kind": .string(wait.action?.kind.rawValue ?? "merge"), "result": "merged", "detail": .string(detail),
  ]
  let data: JSON = ["wait": try JSON(encoding: wait), "outcome": .string(detail), "action": action]
  return Event(id: id, session: "op", t: id * 1000, kind: "wait-resolved", data: data)
}

/// A `wait-resolved` event of a wait without an action, as `resolve` records it.
private func plainResolved(_ id: Int64, _ wait: Wait) throws -> Event {
  let data: JSON = ["wait": try JSON(encoding: wait), "outcome": "k1 reached Ready to merge"]
  return Event(id: id, session: "op", t: id * 1000, kind: "wait-resolved", data: data)
}

/// A `judge` event with the keys of master Stage 2a's Decision 39.
private func judged(_ id: Int64, kind: String = "reply-gate", session: String = "s1", answer: String = "merge") -> Event
{
  let data: JSON = [
    "kind": .string(kind), "session": .string(session), "wait": "w1", "head": "abc123", "model": "sonnet",
    "inputTokens": 1200, "outputTokens": 40, "usage": ["input_tokens": 1200, "output_tokens": 40],
    "answer": .string(answer),
  ]
  return Event(id: id, session: "op", t: id * 1000, kind: "judge", data: data)
}

/// A `judge` event with `data` as given.
private func judgeEvent(_ id: Int64, _ data: JSON) -> Event {
  Event(id: id, session: "op", t: id * 1000, kind: "judge", data: data)
}

private func texts(_ events: [Event]) -> [String] { BackgroundActivity.entries(events).map(\.text) }

@Suite struct BackgroundActivityTests {
  // MARK: Kinds

  @Test func theListReadsReportsResolvedWaitsAndJudgments() {
    #expect(BackgroundActivity.kinds == ["report", "wait-resolved", "judge"])
  }

  @Test func noEventsGiveNoEntries() {
    #expect(BackgroundActivity.entries([]).isEmpty)
  }

  @Test func anEventOfAnotherKindGivesNoEntry() {
    let sent = Event(id: 1, session: "op", t: 1000, kind: "sent", data: ["text": "hi", "by": "you"])

    #expect(BackgroundActivity.entries([sent]).isEmpty)
  }

  // MARK: Ordering

  @Test func entriesAreNewestFirstWhenTheEventsComeOldestFirst() throws {
    let events = [
      activityReport(1, "Merged #1"), try actionResolved(2, activityWait("w2"), detail: "Merged #2"),
      judged(3), activityReport(4, "Merged #4"),
    ]

    #expect(BackgroundActivity.entries(events).map(\.id) == [4, 3, 2, 1])
  }

  @Test func entriesAreNewestFirstWhateverOrderTheEventsComeIn() throws {
    let events = [
      judged(3), activityReport(1, "Merged #1"), activityReport(4, "Merged #4"),
      try actionResolved(2, activityWait("w2"), detail: "Merged #2"),
    ]

    #expect(BackgroundActivity.entries(events).map(\.id) == [4, 3, 2, 1])
  }

  @Test func anEntryKeepsItsEventsIdAndTime() throws {
    let entry = try #require(BackgroundActivity.entries([activityReport(7, "Merged #7")]).first)

    #expect(entry.id == 7)
    #expect(entry.t == 7000)
  }

  // MARK: Reports

  @Test func anInfoReportShowsItsText() {
    #expect(texts([activityReport(1, "Merged #7 into main")]) == ["Merged #7 into main"])
  }

  @Test func aNeedsYouReportShowsAsAQuestionThatTheOperatorAsked() {
    #expect(
      texts([activityReport(1, "Merge #7 with an open thread?", needsYou: true)]) == [
        "Asked: Merge #7 with an open thread?"
      ])
  }

  @Test func aReportsSubjectIsTheSessionItIsAbout() {
    #expect(BackgroundActivity.entries([activityReport(1, "Merged #7", about: "s1")]).map(\.subject) == ["s1"])
  }

  @Test func aReportAboutNoSessionHasNoSubject() {
    #expect(BackgroundActivity.entries([activityReport(1, "Pruned two worktrees")]).map(\.subject) == [nil])
  }

  // MARK: Resolved waits

  @Test func aResolvedWaitWithAnActionShowsTheActionsDetail() throws {
    let event = try actionResolved(1, activityWait("w1"), detail: "Merged PostHog/posthog#7")

    #expect(texts([event]) == ["Merged PostHog/posthog#7"])
  }

  @Test func aResolvedWaitWithoutAnActionGivesNoEntry() throws {
    #expect(BackgroundActivity.entries([try plainResolved(1, activityWait("w1"))]).isEmpty)
  }

  /// The subject is the session that the action acted on: the wait's `subject`, or else the session it watched.
  @Test func aResolvedSessionWaitsSubjectIsTheSessionItWatched() throws {
    let event = try actionResolved(1, activityWait("w1", watching: "k1"), detail: "Merged #7")

    #expect(BackgroundActivity.entries([event]).map(\.subject) == ["k1"])
  }

  @Test func aResolvedPRWaitsSubjectIsTheSessionItsActionActedOn() throws {
    let event = try actionResolved(1, activityWait("w1", watching: nil, subject: "s9"), detail: "Removed fix-cache")

    #expect(BackgroundActivity.entries([event]).map(\.subject) == ["s9"])
  }

  // MARK: A report and its wait

  /// `finish` records `wait-resolved` and then an info report for the same wait. The report names the subject, so
  /// only it shows.
  @Test func aResolvedWaitThatAReportNamesShowsOnlyTheReport() throws {
    let events = [
      try actionResolved(1, activityWait("w1"), detail: "Merged #7"),
      activityReport(2, "Merged #7 into main", about: "k1", wait: "w1"),
    ]

    #expect(BackgroundActivity.entries(events).map(\.id) == [2])
  }

  @Test func aResolvedWaitThatNoReportNamesStays() throws {
    let events = [
      try actionResolved(1, activityWait("w1"), detail: "Merged #7"),
      try actionResolved(2, activityWait("w2"), detail: "Merged #8"),
      activityReport(3, "Merged #7 into main", about: "k1", wait: "w1"),
    ]

    #expect(BackgroundActivity.entries(events).map(\.id) == [3, 2])
  }

  @Test func aReportThatNamesAWaitWithNoResolvedEventStillShows() {
    #expect(texts([activityReport(1, "Merged #7", wait: "w-gone")]) == ["Merged #7"])
  }

  // MARK: Judgments

  @Test(arguments: [("reply-gate", "merge"), ("reply-gate", "ask"), ("ci-failure", "flake")])
  func aJudgmentShowsItsKindAndAnswer(_ kind: String, _ answer: String) {
    #expect(texts([judged(1, kind: kind, answer: answer)]) == ["Judge \(kind): \(answer)"])
  }

  @Test func aJudgmentsSubjectIsTheSessionItJudged() {
    #expect(BackgroundActivity.entries([judged(1, session: "s4")]).map(\.subject) == ["s4"])
  }

  /// A failed judge call records `error` and no `answer`.
  @Test func aFailedJudgmentWithNoAnswerGivesNoEntry() {
    let failed = judgeEvent(
      1, ["kind": "reply-gate", "session": "s1", "wait": "w1", "head": "abc123", "model": "sonnet", "error": "timeout"])

    #expect(BackgroundActivity.entries([failed]).isEmpty)
  }

  @Test func aJudgmentWithNoKindGivesNoEntry() {
    let event = judgeEvent(1, ["session": "s1", "wait": "w1", "answer": "merge"])

    #expect(BackgroundActivity.entries([event]).isEmpty)
  }

  @Test func aJudgmentWithNoDataGivesNoEntry() {
    #expect(BackgroundActivity.entries([judgeEvent(1, [:])]).isEmpty)
  }

  @Test func aJudgmentWithMissingKeysLeavesTheOtherEntries() {
    let events = [activityReport(1, "Merged #7"), judgeEvent(2, ["session": "s1"]), judged(3)]

    #expect(BackgroundActivity.entries(events).map(\.id) == [3, 1])
  }
}
