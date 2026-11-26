import Foundation
import Testing

@testable import SwitchboardCore

/// How sbd reads the events of one PR's Event Streams subscription.
@Suite struct GitHubEventStreamTests {
  private static let pr = PRRef(repo: "PostHog/posthog", number: 141619)
  private static let checkSuiteType = "com.github.pull_request.check_suite.status.changed.v1"

  /// The check suite event recorded from PostHog/posthog#141619, unedited.
  private static let recordedCheckSuite = #"""
    {"specversion":"1.0","id":"eda99af6-1b29-5b9f-bd76-8c18b74e3ad1","source":"https://api.github.com/repositories/235901813","type":"com.github.pull_request.check_suite.status.changed.v1","subject":"pulls/141619","datacontenttype":"application/json","dataschema":"https://api.github.com/schemas/events/pull-request-check-suite-status-changed/1.0.0/schema.json","time":"2026-11-24T22:52:19.563896417Z","data":{"api_url":"https://api.github.com/repositories/235901813/check-suites/123127561561","conclusion":"success"}}
    """#

  /// The review event recorded from PostHog/posthog#141619, unedited.
  private static let recordedReview = #"""
    {"specversion":"1.0","id":"686135e8-fa2c-4cc8-b6c4-9d65942a0ae2","source":"https://api.github.com/repositories/235901813","type":"com.github.pull_request.review.submitted.v1","subject":"pulls/141619","datacontenttype":"application/json","dataschema":"https://api.github.com/schemas/events/thin-resource-change/1.0.0/schema.json","time":"2026-11-24T22:55:56.151528596Z","data":{"api_url":"https://api.github.com/repositories/235901813/pulls/141619/reviews/6048691856"}}
    """#

  /// An event as the stream sends it: the SSE id and event lines name the CloudEvent's id and type.
  private static func event(
    _ type: String, id: String = "e1", conclusion: String? = nil, time: String = "2026-11-24T22:52:19Z"
  ) -> SSEEvent {
    let data =
      conclusion.map { #"{"api_url":"https://api.github.com/x","conclusion":"\#($0)"}"# }
      ?? #"{"api_url":"https://api.github.com/x"}"#
    return SSEEvent(
      id: id, event: type,
      data: #"{"specversion":"1.0","id":"\#(id)","type":"\#(type)","time":"\#(time)","data":\#(data)}"#)
  }

  private static func signal(_ message: GitHubEventStream.Message) -> PRSignal? {
    guard case .signal(let s) = message else { return nil }
    return s
  }

  @Test func theProviderIsGitHubEvents() {
    #expect(GitHubEventStream.provider == "github-events")
  }

  @Test func theEventTypesAreTheFivePRTypesSorted() {
    #expect(
      GitHubEventStream.eventTypes == [
        "com.github.pull_request.check_suite.status.changed.v1",
        "com.github.pull_request.head.changed.v1",
        "com.github.pull_request.merge_conflict.v1",
        "com.github.pull_request.review.submitted.v1",
        "com.github.pull_request.state.changed.v1",
      ])
  }

  /// 2026-11-24T22:52:19Z is 20781 days and 82339 s after the epoch. The nanoseconds are cut to ms, not rounded.
  @Test func theRecordedCheckSuiteEventIsAChecksSignal() {
    let sse = SSEEvent(
      id: "eda99af6-1b29-5b9f-bd76-8c18b74e3ad1", event: Self.checkSuiteType, data: Self.recordedCheckSuite)

    #expect(
      GitHubEventStream.decode(sse, pr: Self.pr)
        == .signal(
          PRSignal(
            provider: "github-events", id: "eda99af6-1b29-5b9f-bd76-8c18b74e3ad1", target: .pr(Self.pr), kind: .checks,
            at: 1_795_560_739_563, failed: false)))
  }

  @Test func theRecordedReviewEventIsAReviewSignal() {
    let sse = SSEEvent(
      id: "686135e8-fa2c-4cc8-b6c4-9d65942a0ae2", event: "com.github.pull_request.review.submitted.v1",
      data: Self.recordedReview)

    #expect(
      GitHubEventStream.decode(sse, pr: Self.pr)
        == .signal(
          PRSignal(
            provider: "github-events", id: "686135e8-fa2c-4cc8-b6c4-9d65942a0ae2", target: .pr(Self.pr), kind: .review,
            at: 1_795_560_956_151, failed: false)))
  }

  @Test(
    arguments: zip(
      [
        "com.github.pull_request.check_suite.status.changed.v1", "com.github.pull_request.review.submitted.v1",
        "com.github.pull_request.state.changed.v1", "com.github.pull_request.head.changed.v1",
        "com.github.pull_request.merge_conflict.v1", "com.github.pull_request.labeled.v1",
      ],
      [.checks, .review, .state, .head, .conflict, .other] as [PRSignal.Kind]))
  func eachTypeGivesItsKind(_ type: String, _ kind: PRSignal.Kind) {
    #expect(Self.signal(GitHubEventStream.decode(Self.event(type), pr: Self.pr))?.kind == kind)
  }

  @Test(arguments: ["failure", "timed_out", "cancelled", "action_required", "startup_failure"])
  func aCheckSuiteWithAFailedConclusionIsFailed(_ conclusion: String) {
    let s = Self.signal(GitHubEventStream.decode(Self.event(Self.checkSuiteType, conclusion: conclusion), pr: Self.pr))

    #expect(s?.kind == .checks)
    #expect(s?.failed == true)
  }

  @Test(arguments: ["success", "skipped", "neutral"])
  func aCheckSuiteWithAnotherConclusionIsNotFailed(_ conclusion: String) {
    let s = Self.signal(GitHubEventStream.decode(Self.event(Self.checkSuiteType, conclusion: conclusion), pr: Self.pr))

    #expect(s?.kind == .checks)
    #expect(s?.failed == false)
  }

  /// The types whose payloads the recorded runs didn't include decode like the recorded ones.
  @Test(
    arguments: zip(
      [
        "com.github.pull_request.head.changed.v1", "com.github.pull_request.state.changed.v1",
        "com.github.pull_request.merge_conflict.v1",
      ],
      [.head, .state, .conflict] as [PRSignal.Kind]))
  func aPREventIsASignalForTheSubscriptionsPR(_ type: String, _ kind: PRSignal.Kind) {
    #expect(
      GitHubEventStream.decode(Self.event(type, id: "u1"), pr: Self.pr)
        == .signal(
          PRSignal(
            provider: "github-events", id: "u1", target: .pr(Self.pr), kind: kind, at: 1_795_560_739_000,
            failed: false)))
  }

  @Test func theCloudEventIdWinsOverTheSSEId() {
    var sse = Self.event(Self.checkSuiteType, id: "cloud")
    sse.id = "wire"

    #expect(Self.signal(GitHubEventStream.decode(sse, pr: Self.pr))?.id == "cloud")
  }

  @Test func withoutACloudEventIdTheSSEIdNamesTheSignal() {
    let sse = SSEEvent(
      id: "wire", event: Self.checkSuiteType,
      data: #"{"type":"\#(Self.checkSuiteType)","time":"2026-11-24T22:52:19Z","data":{"conclusion":"success"}}"#)

    #expect(Self.signal(GitHubEventStream.decode(sse, pr: Self.pr))?.id == "wire")
  }

  @Test func anUnknownTypeIsAnOtherSignalThatIsNotFailed() {
    let s = Self.signal(
      GitHubEventStream.decode(Self.event("com.github.pull_request.renamed.v2", conclusion: "failure"), pr: Self.pr))

    #expect(s?.kind == .other)
    #expect(s?.failed == false)
  }

  @Test func aStreamEndForADeletedSubscriptionGivesItsOutcomeAndReason() {
    let sse = SSEEvent(event: "github.stream.end", data: #"{"outcome":"subscription_ended","reason":"deleted"}"#)

    #expect(GitHubEventStream.decode(sse, pr: Self.pr) == .end(outcome: "subscription_ended", reason: "deleted"))
  }

  @Test func aStreamEndThatAsksForAReconnectHasNoReason() {
    let sse = SSEEvent(event: "github.stream.end", data: #"{"outcome":"reconnect"}"#)

    #expect(GitHubEventStream.decode(sse, pr: Self.pr) == .end(outcome: "reconnect", reason: nil))
  }

  @Test(arguments: ["not json", "", "{", "[1,2]", "42", #""text""#])
  func dataThatIsNotAJSONObjectIsIgnored(_ data: String) {
    let sse = SSEEvent(id: "x", event: Self.checkSuiteType, data: data)

    #expect(GitHubEventStream.decode(sse, pr: Self.pr) == .ignored)
  }

  @Test func aStreamEndWhoseDataIsNotJSONIsIgnored() {
    #expect(GitHubEventStream.decode(SSEEvent(event: "github.stream.end", data: "bye"), pr: Self.pr) == .ignored)
  }
}
