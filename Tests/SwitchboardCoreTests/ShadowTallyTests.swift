import Foundation
import Testing

@testable import SwitchboardCore

/// What shadow mode counts for one source of PR changes: signals that a later read showed, signals that no read
/// showed, and reads that showed a change of a live PR without a signal.
@Suite struct ShadowTallyTests {
  static let t0: Int64 = 1_000_000_000_000
  static let base = ShadowTally.Snapshot(
    head: "head1", state: "OPEN", draft: false, reviews: 0, checks: "PENDING", mergeable: "MERGEABLE")

  /// The base snapshot with one field changed, by the field's name.
  static func changed(_ field: String) -> ShadowTally.Snapshot {
    var s = base
    switch field {
    case "head": s.head = "head2"
    case "state": s.state = "MERGED"
    case "draft": s.draft = true
    case "reviews": s.reviews = 1
    case "checks": s.checks = "SUCCESS"
    case "mergeable": s.mergeable = "CONFLICTING"
    default: Issue.record("no field \(field)")
    }
    return s
  }

  /// A read of PR_7 at `polled` whose previous read showed `base` at `previousAt`.
  @discardableResult
  static func read(
    _ tally: inout ShadowTally, _ now: ShadowTally.Snapshot, at polled: Int64,
    previousAt: Int64 = ShadowTallyTests.t0 - 300_000,
    previous: ShadowTally.Snapshot = ShadowTallyTests.base, liveSince: Int64? = nil, pr: String = "PR_7"
  ) -> [String] {
    tally.read(pr, previous: (previous, previousAt), now: now, polled: polled, liveSince: liveSince)
  }

  // MARK: Matching

  @Test(
    arguments: zip(
      ["head", "state", "draft", "reviews", "checks", "mergeable"],
      [.head, .state, .state, .review, .checks, .conflict] as [PRSignal.Kind]))
  func aSignalMatchesAReadThatShowsItsField(_ field: String, _ kind: PRSignal.Kind) {
    var tally = ShadowTally()
    tally.signal("PR_7", kind: kind, at: Self.t0)

    Self.read(&tally, Self.changed(field), at: Self.t0 + 3_000)

    #expect(tally.matched == 1)
  }

  /// A signal stays pending when the read shows a change of another field.
  @Test(
    arguments: zip(
      [.head, .state, .review, .checks, .conflict] as [PRSignal.Kind],
      ["checks", "reviews", "head", "mergeable", "state"]))
  func aSignalDoesNotMatchAChangeOfAnotherField(_ kind: PRSignal.Kind, _ field: String) {
    var tally = ShadowTally()
    tally.signal("PR_7", kind: kind, at: Self.t0)

    Self.read(&tally, Self.changed(field), at: Self.t0 + 3_000)

    #expect(tally.matched == 0)
  }

  @Test(arguments: ["head", "state", "draft", "reviews", "checks", "mergeable"])
  func anOtherSignalMatchesAnyChange(_ field: String) {
    var tally = ShadowTally()
    tally.signal("PR_7", kind: .other, at: Self.t0)

    Self.read(&tally, Self.changed(field), at: Self.t0 + 3_000)

    #expect(tally.matched == 1)
  }

  @Test func aReadWithoutAChangeMatchesNothing() {
    var tally = ShadowTally()
    tally.signal("PR_7", kind: .other, at: Self.t0)

    Self.read(&tally, Self.base, at: Self.t0 + 3_000)

    #expect(tally.matched == 0)
  }

  @Test func aSignalForAnotherPRDoesNotMatch() {
    var tally = ShadowTally()
    tally.signal("PR_8", kind: .head, at: Self.t0)

    Self.read(&tally, Self.changed("head"), at: Self.t0 + 3_000)

    #expect(tally.matched == 0)
  }

  @Test func aSignalAfterTheReadDoesNotMatchIt() {
    var tally = ShadowTally()
    tally.signal("PR_7", kind: .head, at: Self.t0 + 3_001)

    Self.read(&tally, Self.changed("head"), at: Self.t0 + 3_000)

    #expect(tally.matched == 0)
  }

  @Test func aSignalAtTheReadsTimeMatchesIt() {
    var tally = ShadowTally()
    tally.signal("PR_7", kind: .head, at: Self.t0 + 3_000)

    Self.read(&tally, Self.changed("head"), at: Self.t0 + 3_000)

    #expect(tally.matched == 1)
  }

  /// A signal that came after one read matches the next read that shows its change.
  @Test func aSignalAfterOneReadMatchesTheNextRead() {
    var tally = ShadowTally()
    var third = Self.changed("head")
    third.head = "head3"
    tally.signal("PR_7", kind: .head, at: Self.t0 + 5_000)
    Self.read(&tally, Self.changed("head"), at: Self.t0)

    Self.read(&tally, third, at: Self.t0 + 30_000, previousAt: Self.t0, previous: Self.changed("head"))

    #expect(tally.matched == 1)
    #expect(tally.medianLeadMs == 25_000)
  }

  @Test func eachPendingSignalThatTheReadShowsMatches() {
    var tally = ShadowTally()
    tally.signal("PR_7", kind: .head, at: Self.t0)
    tally.signal("PR_7", kind: .head, at: Self.t0 + 1_000)

    Self.read(&tally, Self.changed("head"), at: Self.t0 + 3_000)

    #expect(tally.matched == 2)
  }

  @Test func aMatchedSignalDoesNotMatchALaterRead() {
    var tally = ShadowTally()
    tally.signal("PR_7", kind: .other, at: Self.t0)
    Self.read(&tally, Self.changed("head"), at: Self.t0 + 3_000)

    Self.read(&tally, Self.changed("checks"), at: Self.t0 + 33_000, previousAt: Self.t0 + 3_000)

    #expect(tally.matched == 1)
  }

  // MARK: Lead time

  @Test func theMedianLeadIsNilBeforeAMatch() {
    var tally = ShadowTally()
    tally.signal("PR_7", kind: .head, at: Self.t0)

    #expect(tally.medianLeadMs == nil)
  }

  @Test func theLeadIsTheTimeFromTheSignalToTheRead() {
    var tally = ShadowTally()
    tally.signal("PR_7", kind: .head, at: Self.t0)

    Self.read(&tally, Self.changed("head"), at: Self.t0 + 7_500)

    #expect(tally.medianLeadMs == 7_500)
  }

  @Test func theMedianLeadIsTheMiddleOfTheMatchedLeads() {
    var tally = ShadowTally()
    tally.signal("PR_7", kind: .head, at: Self.t0)
    tally.signal("PR_8", kind: .head, at: Self.t0)
    tally.signal("PR_9", kind: .head, at: Self.t0)

    Self.read(&tally, Self.changed("head"), at: Self.t0 + 30_000, pr: "PR_7")
    Self.read(&tally, Self.changed("head"), at: Self.t0 + 1_000, pr: "PR_8")
    Self.read(&tally, Self.changed("head"), at: Self.t0 + 5_000, pr: "PR_9")

    #expect(tally.medianLeadMs == 5_000)
  }

  // MARK: Pruning

  @Test(arguments: zip([599_999, 600_001] as [Int64], [0, 1]))
  func aSignalThatNoReadShowsForTenMinutesIsUnmatched(_ after: Int64, _ unmatched: Int) {
    var tally = ShadowTally()
    tally.signal("PR_7", kind: .head, at: Self.t0)

    tally.prune(now: Self.t0 + after)

    #expect(tally.unmatched == unmatched)
  }

  @Test func aPrunedSignalNoLongerMatches() {
    var tally = ShadowTally()
    tally.signal("PR_7", kind: .head, at: Self.t0)
    tally.prune(now: Self.t0 + 600_001)

    Self.read(&tally, Self.changed("head"), at: Self.t0 + 600_002)

    #expect(tally.matched == 0)
  }

  @Test func aMatchedSignalIsNeverUnmatched() {
    var tally = ShadowTally()
    tally.signal("PR_7", kind: .head, at: Self.t0)
    Self.read(&tally, Self.changed("head"), at: Self.t0 + 3_000)

    tally.prune(now: Self.t0 + 3_600_000)

    #expect(tally.unmatched == 0)
  }

  @Test func eachSignalCountsAsUnmatchedOnce() {
    var tally = ShadowTally()
    tally.signal("PR_7", kind: .head, at: Self.t0)
    tally.signal("PR_8", kind: .review, at: Self.t0)

    tally.prune(now: Self.t0 + 600_001)
    tally.prune(now: Self.t0 + 1_200_000)

    #expect(tally.unmatched == 2)
  }

  // MARK: Misses

  @Test(arguments: ["head", "state", "draft", "reviews", "checks"])
  func aChangeOfALivePRWithoutASignalIsAMiss(_ field: String) {
    var tally = ShadowTally()

    let fields = Self.read(&tally, Self.changed(field), at: Self.t0, liveSince: Self.t0 - 600_000)

    #expect(tally.misses == 1)
    #expect(!fields.isEmpty)
  }

  @Test func aMissReturnsTheChangedFields() {
    var tally = ShadowTally()
    var now = Self.base
    now.head = "head2"
    now.checks = "SUCCESS"

    let fields = Self.read(&tally, now, at: Self.t0, liveSince: Self.t0 - 600_000)

    #expect(Set(fields) == ["head", "checks"])
  }

  @Test func aMergeableOnlyChangeIsNotAMiss() {
    var tally = ShadowTally()

    let fields = Self.read(&tally, Self.changed("mergeable"), at: Self.t0, liveSince: Self.t0 - 600_000)

    #expect(tally.misses == 0)
    #expect(fields.isEmpty)
  }

  @Test func aReadWithoutAChangeIsNotAMiss() {
    var tally = ShadowTally()

    let fields = Self.read(&tally, Self.base, at: Self.t0, liveSince: Self.t0 - 600_000)

    #expect(tally.misses == 0)
    #expect(fields.isEmpty)
  }

  @Test func theFirstReadIsNeverAMiss() {
    var tally = ShadowTally()

    let fields = tally.read(
      "PR_7", previous: nil, now: Self.changed("head"), polled: Self.t0, liveSince: Self.t0 - 600_000)

    #expect(tally.misses == 0)
    #expect(fields.isEmpty)
  }

  @Test func aReadOfAPRThatIsNotLiveIsNotAMiss() {
    var tally = ShadowTally()

    let fields = Self.read(&tally, Self.changed("head"), at: Self.t0, liveSince: nil)

    #expect(tally.misses == 0)
    #expect(fields.isEmpty)
  }

  /// The source has to be live from the previous read on, or the change may have come before it went live.
  @Test(arguments: zip([-1, 0, 1] as [Int64], [1, 1, 0]))
  func aMissNeedsTheSourceLiveSinceThePreviousRead(_ liveAfterPrevious: Int64, _ misses: Int) {
    var tally = ShadowTally()
    let previousAt = Self.t0 - 300_000

    Self.read(
      &tally, Self.changed("head"), at: Self.t0, previousAt: previousAt, liveSince: previousAt + liveAfterPrevious)

    #expect(tally.misses == misses)
  }

  /// With a previous read 5 minutes back, any signal since that read keeps the read from being a miss. The window
  /// includes both of its ends.
  @Test(arguments: zip([-300_001, -300_000, -200_000, 0, 1] as [Int64], [1, 0, 0, 0, 1]))
  func aSignalSinceAnOldPreviousReadPreventsAMiss(_ signalAgo: Int64, _ misses: Int) {
    var tally = ShadowTally()
    tally.signal("PR_7", kind: .review, at: Self.t0 + signalAgo)

    Self.read(&tally, Self.changed("head"), at: Self.t0, previousAt: Self.t0 - 300_000, liveSince: Self.t0 - 600_000)

    #expect(tally.misses == misses)
  }

  /// With a previous read 10 s back, a signal in the 60 s before the read keeps it from being a miss, even when the
  /// signal came before the previous read.
  @Test(arguments: zip([-60_001, -60_000, -30_000] as [Int64], [1, 0, 0]))
  func aSignalInTheLastMinutePreventsAMiss(_ signalAgo: Int64, _ misses: Int) {
    var tally = ShadowTally()
    tally.signal("PR_7", kind: .review, at: Self.t0 + signalAgo)

    Self.read(&tally, Self.changed("head"), at: Self.t0, previousAt: Self.t0 - 10_000, liveSince: Self.t0 - 600_000)

    #expect(tally.misses == misses)
  }

  /// A signal that the same read matches still arrived in the window.
  @Test func aSignalThatTheReadMatchesPreventsAMiss() {
    var tally = ShadowTally()
    tally.signal("PR_7", kind: .head, at: Self.t0 - 2_000)

    let fields = Self.read(&tally, Self.changed("head"), at: Self.t0, liveSince: Self.t0 - 600_000)

    #expect(tally.matched == 1)
    #expect(tally.misses == 0)
    #expect(fields.isEmpty)
  }

  /// A signal that an earlier read matched still arrived in the window of the next read.
  @Test func aSignalThatAnEarlierReadMatchedPreventsAMiss() {
    var tally = ShadowTally()
    let live = Self.t0 - 600_000
    tally.signal("PR_7", kind: .head, at: Self.t0 - 20_000)
    Self.read(&tally, Self.changed("head"), at: Self.t0 - 15_000, previousAt: Self.t0 - 45_000, liveSince: live)

    Self.read(
      &tally, Self.changed("checks"), at: Self.t0, previousAt: Self.t0 - 15_000, previous: Self.base, liveSince: live)

    #expect(tally.misses == 0)
  }

  @Test func aSignalForAnotherPRDoesNotPreventAMiss() {
    var tally = ShadowTally()
    tally.signal("PR_8", kind: .head, at: Self.t0 - 1_000)

    Self.read(&tally, Self.changed("head"), at: Self.t0, liveSince: Self.t0 - 600_000)

    #expect(tally.misses == 1)
  }

  // MARK: Snapshot

  /// Each field that a signal announces changes the snapshot of a PR.
  @Test(arguments: ["head", "state", "draft", "reviews", "checks", "mergeable"])
  func eachAnnouncedFieldOfAPRChangesItsSnapshot(_ field: String) {
    var pr = samplePR(checks: "PENDING")
    switch field {
    case "head": pr.headSha = "head2"
    case "state": pr.state = .merged
    case "draft": pr.draft = true
    case "reviews": pr.reviews = [sampleVerdict("alice", "COMMENTED")]
    case "checks": pr.checks = "SUCCESS"
    default: pr.mergeable = .conflicting
    }

    #expect(ShadowTally.Snapshot(pr) != ShadowTally.Snapshot(samplePR(checks: "PENDING")))
  }

  /// The status query reads the last 20 reviews, so a new review can leave the count at 20.
  @Test func aNewestReviewAtTheSameCountIsAReviewChange() {
    let old = ShadowTally.Snapshot(
      head: "h", state: "OPEN", draft: false, reviews: 20, checks: nil, mergeable: nil,
      lastReview: "2026-11-25T10:00:00Z")
    var new = old
    new.lastReview = "2026-11-25T11:00:00Z"
    var t = ShadowTally()
    t.signal("PR_7", kind: .review, at: 1_000)

    t.read("PR_7", previous: (old, 500), now: new, polled: 2_000, liveSince: nil)

    #expect(t.matched == 1)
  }

  @Test func fieldsThatNoSignalAnnouncesLeaveTheSnapshotTheSame() {
    var pr = samplePR(checks: "PENDING")
    pr.title = "a new title"
    pr.labels = ["bug"]
    pr.base = "release"

    #expect(ShadowTally.Snapshot(pr) == ShadowTally.Snapshot(samplePR(checks: "PENDING")))
  }

  @Test func aSnapshotOfAPRKeepsItsHeadDraftAndChecks() {
    let s = ShadowTally.Snapshot(samplePR(draft: true, headSha: "abc", checks: "FAILURE"))

    #expect(s.head == "abc")
    #expect(s.draft)
    #expect(s.checks == "FAILURE")
  }
}
