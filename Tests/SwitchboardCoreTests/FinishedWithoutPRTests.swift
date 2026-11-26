import Foundation
import Testing

@testable import SwitchboardCore

private let now: Int64 = 10
private let doneWithoutPR = Verdict(state: .done, reason: "finished without a PR; nothing to commit or push")
private let readTheLastReply = Verdict(state: .needsYou, reason: "read its last reply and decide what's next")

/// A `worktree` event. A nil `onDefault` leaves the key out, as an sbd from before the field wrote it.
private func folderCount(_ t: Int64, dirty: Int? = 0, gone: Bool = false, onDefault: Bool? = true) -> Event {
  var fields: [String: JSON] = ["dirty": dirty.map { .number(Double($0)) } ?? .null, "gone": .bool(gone)]
  if let onDefault { fields["onDefault"] = .bool(onDefault) }
  return event("worktree", t, fields)
}

/// An `ack` event of `verdict`, whose data is the JSON encoding of the acknowledgment.
private func ackOf(_ t: Int64, _ verdict: Verdict, head: String? = nil) throws -> Event {
  let data = try JSON(encoding: Acknowledgment(state: verdict.state, reason: verdict.reason, head: head))
  return event("ack", t, data.object ?? [:])
}

/// The facts of a work session whose turn ended with `reply`, whose last reply the user acknowledged, and
/// whose folder the poller counted. The poller counts only after the acknowledgment, so the count comes last
/// unless `countFirst` puts it before the ack. A nil `reply` is a Stop that carries no message. `before` holds
/// events that come before the prompt, and `then` holds events from time 5 on.
private func noPRFacts(
  reply: String? = "Done.", prompted: Bool = true, acknowledged: Bool = true, counted: Bool = true, dirty: Int? = 0,
  gone: Bool = false, onDefault: Bool? = true, countFirst: Bool = false, before: [Event] = [], then: [Event] = []
) throws -> SessionFacts {
  var events = before
  if prompted { events.append(event("UserPromptSubmit", 1, ["prompt": "go"])) }
  events.append(event("Stop", 2, reply.map { ["last_assistant_message": .string($0)] } ?? [:]))
  let ack = acknowledged ? [try ackOf(countFirst ? 4 : 3, Attention.replyVerdict(reply ?? ""))] : []
  let count = counted ? [folderCount(countFirst ? 3 : 4, dirty: dirty, gone: gone, onDefault: onDefault)] : []
  events += countFirst ? count + ack : ack + count
  return facts(events + then)
}

private func verdict(_ f: SessionFacts, _ s: Session = session(), at t: Int64 = now) -> Verdict {
  Attention.evaluate(s, f, now: t)
}

/// One way that a session breaks a condition of the rule other than the folder's state. Each case keeps every
/// other condition, so the session would be Done without it.
enum NoPRExclusion: String, CaseIterable, Sendable, CustomTestStringConvertible {
  case snoozed, ackedQuestion, ackedOffer, unacknowledged, noPrompt, onceHadAPR, turnRunning, runningJob
  case runningSubagent
  case manager, chat

  var testDescription: String { rawValue }

  static let question = "Which branch should I use?"
  static let offer = "Want me to push?"

  var session: Session {
    var s = SwitchboardCoreTests.session()
    switch self {
    case .manager: s.manager = true
    case .chat: s.chat = "g"
    default: break
    }
    return s
  }

  func facts() throws -> SessionFacts {
    switch self {
    case .snoozed: try noPRFacts(then: [event("snooze", 5, ["until": .number(1_000_000)])])
    case .ackedQuestion: try noPRFacts(reply: Self.question)
    case .ackedOffer: try noPRFacts(reply: Self.offer)
    case .unacknowledged: try noPRFacts(acknowledged: false)
    // A reply with no prompt before it gets past the first-prompt rule, which needs both to be missing.
    case .noPrompt: try noPRFacts(prompted: false)
    case .onceHadAPR: try noPRFacts(before: [try prEvent(0, samplePR()), event("pr", 0, ["pr": .null])])
    // A turn that starts also clears the acknowledgment, so this case breaks two conditions.
    case .turnRunning: try noPRFacts(then: [event("PreToolUse", 5, tool("Bash", ["command": "ls"], id: "t1"))])
    case .runningJob: try noPRFacts(then: [event("job", 5, ["count": 1])])
    case .runningSubagent: try noPRFacts(then: [event("SubagentStart", 5, ["agent_id": "a1"])])
    case .manager, .chat: try noPRFacts()
    }
  }
}

/// The suites nest under one name, so `--filter FinishedWithoutPRTests` runs them all.
@Suite struct FinishedWithoutPRTests {}

extension FinishedWithoutPRTests {
  @Suite struct Facts {
    @Test func headOnDefaultStartsFalse() {
      #expect(SessionFacts().headOnDefault == false)
    }

    @Test func worktreeEventWithOnDefaultSetsHeadOnDefault() {
      let f = facts([folderCount(1, onDefault: true)])

      #expect(f.headOnDefault == true)
    }

    @Test func worktreeEventWithOnDefaultFalseClearsHeadOnDefault() {
      let f = facts([folderCount(1, onDefault: true), folderCount(2, onDefault: false)])

      #expect(f.headOnDefault == false)
    }

    /// An sbd from before the field recorded no `onDefault`, so an old log gives no Done.
    @Test func worktreeEventWithoutOnDefaultReadsFalse() {
      let f = facts([folderCount(1, onDefault: true), folderCount(2, onDefault: nil)])

      #expect(f.headOnDefault == false)
    }

    @Test func worktreeEventWithOnDefaultStillSetsTheDirtyCount() {
      let f = facts([folderCount(1, dirty: 3, onDefault: true)])

      #expect(f.dirty == 3)
    }
  }
}

extension FinishedWithoutPRTests {
  @Suite struct Rule {
    @Test(arguments: [false, true])
    func acknowledgedPlainReplyInACleanFolderOnTheDefaultBranchIsDone(_ countFirst: Bool) throws {
      let f = try noPRFacts(countFirst: countFirst)

      #expect(verdict(f) == doneWithoutPR)
    }

    @Test(arguments: ["Done.", "", "Fixed the typo.\n\nThe change is already on main.", nil] as [String?])
    func everyReplyThatAsksNothingIsDone(_ reply: String?) throws {
      let f = try noPRFacts(reply: reply)

      #expect(verdict(f) == doneWithoutPR)
    }

    /// The rule runs before the Stale rule.
    @Test func doneHoldsAfterTwoIdleDays() throws {
      let f = try noPRFacts()

      #expect(verdict(f, at: 3 * Attention.dayMs) == doneWithoutPR)
    }

    /// The acknowledgment's recheck time moves only an Inbox verdict, so Done does not return to the Inbox.
    @Test func shownKeepsDoneAfterTheAcknowledgmentExpires() throws {
      let f = try noPRFacts()
      let acknowledgedMs = RecheckSettings().acknowledgedMs
      let later = 4 + acknowledgedMs + 1

      let shown = Attention.shown(verdict(f, at: later), f, now: later, acknowledgedMs: acknowledgedMs)

      #expect(shown == doneWithoutPR)
    }
  }
}

extension FinishedWithoutPRTests {
  @Suite struct Exclusions {
    @Test(arguments: NoPRExclusion.allCases)
    func everyExclusionIsNotDone(_ exclusion: NoPRExclusion) throws {
      let f = try exclusion.facts()

      #expect(verdict(f, exclusion.session).state != .done)
    }

    @Test func snoozedSessionNeedsYou() throws {
      #expect(verdict(try NoPRExclusion.snoozed.facts()) == readTheLastReply)
    }

    /// The ack covers the question's own verdict, so only the reply's kind refuses it.
    @Test(arguments: [NoPRExclusion.question, "Should it be renamed?"])
    func acknowledgedQuestionIsNotDone(_ reply: String) throws {
      let f = try noPRFacts(reply: reply)

      #expect(verdict(f) == Attention.replyVerdict(reply))
    }

    /// The ack covers the offer's own verdict, so only the reply's kind refuses it.
    @Test(arguments: [NoPRExclusion.offer, "Next, I'll open a PR."])
    func acknowledgedOfferIsNotDone(_ reply: String) throws {
      let f = try noPRFacts(reply: reply)

      #expect(verdict(f) == Attention.replyVerdict(reply))
    }

    @Test func unacknowledgedReplyNeedsYou() throws {
      #expect(verdict(try NoPRExclusion.unacknowledged.facts()) == readTheLastReply)
    }

    @Test(arguments: [
      Verdict(state: .needsYou, reason: "answer: \(NoPRExclusion.question)"),
      Verdict(state: .waiting, reason: readTheLastReply.reason),
      Verdict(state: .canContinue, reason: "offered: \(NoPRExclusion.offer)"),
    ])
    func ackOfAnotherVerdictIsNotDone(_ acked: Verdict) throws {
      let f = try noPRFacts(acknowledged: false, then: [try ackOf(5, acked)])

      #expect(verdict(f) == readTheLastReply)
    }

    /// Without a PR the acknowledgment must carry no head commit to cover the reply.
    @Test func ackWithAHeadCommitIsNotDone() throws {
      let f = try noPRFacts(acknowledged: false, then: [try ackOf(5, readTheLastReply, head: samplePRHead)])

      #expect(verdict(f) == readTheLastReply)
    }

    @Test func unackAfterTheAckIsNotDone() throws {
      let f = try noPRFacts(then: [event("unack", 5)])

      #expect(verdict(f) == readTheLastReply)
    }

    @Test func openWaitWinsOverDone() throws {
      let f = try noPRFacts()

      #expect(verdict(f, session(wait: "the deploy")) == Verdict(state: .waiting, reason: "the deploy"))
    }

    @Test func waitOutcomeWinsOverDone() throws {
      let wait = waitOn(.deploy, pr: pr1204, environment: "prod", then: .notify)
      let f = try noPRFacts(then: [try resolved(wait, "it deployed", 5)])

      #expect(verdict(f) == Verdict(state: .needsYou, reason: "#1204 to reach prod: it deployed"))
    }

    @Test func runningBackgroundJobWaits() throws {
      let f = try NoPRExclusion.runningJob.facts()

      #expect(verdict(f) == Verdict(state: .waiting, reason: "waiting on 1 background job"))
    }

    @Test func runningSubagentWaits() throws {
      let f = try NoPRExclusion.runningSubagent.facts()

      #expect(verdict(f) == Verdict(state: .waiting, reason: "waiting on 1 subagent"))
    }

    /// A fresh worktree is clean and on the default branch too. The ack of either verdict a fresh session can
    /// show must not finish it.
    @Test(arguments: [
      readTheLastReply, Verdict(state: .needsYou, reason: "give it a first prompt"),
    ])
    func freshSessionNeedsAFirstPrompt(_ acked: Verdict) throws {
      let f = facts([event("SessionStart", 1), try ackOf(2, acked), folderCount(3)])

      #expect(verdict(f) == Verdict(state: .needsYou, reason: "give it a first prompt"))
    }

    @Test func replyWithoutAPromptIsNotDone() throws {
      let f = try NoPRExclusion.noPrompt.facts()

      #expect(f.prompts == 0)
      #expect(verdict(f).state != .done)
    }

    @Test func sessionThatOnceHadAPRIsNotDone() throws {
      let f = try NoPRExclusion.onceHadAPR.facts()

      #expect(f.pr == nil)
      #expect(!f.prNumbers.isEmpty)
      #expect(verdict(f).state != .done)
    }

    @Test(arguments: [samplePR(), samplePR(state: .merged), samplePR(state: .closed)])
    func sessionWithAPRGetsNoDoneWithoutAPR(_ pr: PullRequest) throws {
      let f = try noPRFacts(before: [try prEvent(0, pr)])

      #expect(verdict(f) != doneWithoutPR)
    }

    @Test(
      arguments: [
        (dirty: 2, gone: false, onDefault: true),
        (dirty: nil, gone: false, onDefault: true),
        (dirty: nil, gone: true, onDefault: true),
        (dirty: 0, gone: false, onDefault: false),
        (dirty: 0, gone: false, onDefault: nil),
      ] as [(dirty: Int?, gone: Bool, onDefault: Bool?)])
    func folderThatIsNotKnownToBeLosslessIsNotDone(_ folder: (dirty: Int?, gone: Bool, onDefault: Bool?)) throws {
      let f = try noPRFacts(dirty: folder.dirty, gone: folder.gone, onDefault: folder.onDefault)

      #expect(verdict(f) == readTheLastReply)
    }

    @Test func uncountedFolderIsNotDone() throws {
      let f = try noPRFacts(counted: false)

      #expect(verdict(f) == readTheLastReply)
    }

    @Test func operatorIsNotDone() throws {
      var s = session()
      s.manager = true
      s.isOperator = true

      #expect(verdict(try noPRFacts(), s).state != .done)
    }
  }
}

extension FinishedWithoutPRTests {
  @Suite struct Leaving {
    @Test func newPromptLeavesDone() throws {
      let f = try noPRFacts(then: [event("UserPromptSubmit", 5, ["prompt": "one more thing"])])

      #expect(verdict(f).state == .working)
    }

    /// The prompt cleared the acknowledgment, so a turn that ends with the same words needs a new one.
    @Test func turnThatEndsWithTheSameReplyNeedsYouAgain() throws {
      let f = try noPRFacts(then: [
        event("UserPromptSubmit", 5, ["prompt": "one more thing"]),
        event("Stop", 6, ["last_assistant_message": "Done."]),
      ])

      #expect(verdict(f) == readTheLastReply)
    }

    /// The earlier count stays in `dirty` and `folderGone`, so only the reset of `headOnDefault` holds Done back.
    @Test func acknowledgmentAfterTheNextTurnWaitsForANewCount() throws {
      let f = try noPRFacts(then: [
        event("UserPromptSubmit", 5, ["prompt": "one more thing"]),
        event("Stop", 6, ["last_assistant_message": "Done."]),
        try ackOf(7, readTheLastReply),
      ])

      #expect(f.headOnDefault == false)
      #expect(verdict(f) == readTheLastReply)
    }

    @Test func newAcknowledgmentAfterTheNextTurnIsDoneAgain() throws {
      let f = try noPRFacts(then: [
        event("UserPromptSubmit", 5, ["prompt": "one more thing"]),
        event("Stop", 6, ["last_assistant_message": "Done."]),
        try ackOf(7, readTheLastReply),
        folderCount(8),
      ])

      #expect(verdict(f) == doneWithoutPR)
    }

    @Test func laterDirtyCountLeavesDone() throws {
      let f = try noPRFacts(then: [folderCount(5, dirty: 1)])

      #expect(verdict(f) == readTheLastReply)
    }

    @Test func laterCountOffTheDefaultBranchLeavesDone() throws {
      let f = try noPRFacts(then: [folderCount(5, onDefault: false)])

      #expect(verdict(f) == readTheLastReply)
    }

    @Test func laterCountThatFindsTheFolderGoneLeavesDone() throws {
      let f = try noPRFacts(then: [folderCount(5, dirty: nil, gone: true)])

      #expect(verdict(f).state != .done)
    }
  }
}

extension FinishedWithoutPRTests {
  @Suite struct Parent {
    @Test func parentHearsTheChildIsDone() throws {
      let f = try noPRFacts()
      let v = verdict(f)

      let line = ParentDigest.line(
        name: "fix", id: "s1", heard: ChildMark(state: .needsYou, pr: nil),
        now: ChildMark(state: v.state, pr: f.pr?.number), reason: v.reason, prURL: nil)

      #expect(line == "fix (s1): done")
    }
  }
}

/// `awaitsFolderCheck` decides which sessions the poller counts, so it must hold for every session the rule would
/// finish, whatever the folder's state was at the last count.
extension FinishedWithoutPRTests {
  @Suite struct FolderCheck {
    @Test(
      arguments: [
        (counted: false, dirty: 0, onDefault: true),
        (counted: true, dirty: 0, onDefault: true),
        (counted: true, dirty: 2, onDefault: true),
        (counted: true, dirty: 0, onDefault: false),
        (counted: true, dirty: 0, onDefault: nil),
      ] as [(counted: Bool, dirty: Int?, onDefault: Bool?)])
    func candidateAwaitsACountWhateverTheLastCountFound(_ folder: (counted: Bool, dirty: Int?, onDefault: Bool?))
      throws
    {
      let f = try noPRFacts(counted: folder.counted, dirty: folder.dirty, onDefault: folder.onDefault)

      #expect(Attention.awaitsFolderCheck(kind: .work, f, now: now))
    }

    @Test(arguments: NoPRExclusion.allCases)
    func everyExclusionAwaitsNoCount(_ exclusion: NoPRExclusion) throws {
      let f = try exclusion.facts()

      #expect(!Attention.awaitsFolderCheck(kind: exclusion.session.kind, f, now: now))
    }
  }
}

/// The poller passes `git for-each-ref --format=%(symref) --contains HEAD 'refs/remotes/*/HEAD'` output. Only a
/// remote's symbolic `HEAD` ref names a default branch. A branch whose name ends in `/HEAD` prints a blank line.
extension FinishedWithoutPRTests {
  @Suite struct RemoteHead {
    @Test(arguments: [
      "refs/remotes/origin/main\n",
      "\nrefs/remotes/upstream/main",
    ])
    func refsThatNameARemoteHeadAreOnTheDefaultBranch(_ refs: String) {
      #expect(GitHub.namesRemoteHead(refs))
    }

    @Test(arguments: [
      "",
      "\n",
      "\n\n",
    ])
    func refsWithoutARemoteHeadAreNotOnTheDefaultBranch(_ refs: String) {
      #expect(!GitHub.namesRemoteHead(refs))
    }
  }
}
