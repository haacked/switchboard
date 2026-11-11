import Foundation
import Testing

@testable import SwitchboardCore

func docketRow(done: Bool = false) -> Session {
  var s = Session(id: "s1", name: "o/r#1", cwd: "", claudeSessionId: "uuid", created: 0)
  s.docket = DocketSession(pullRequest: "o/r#1", url: "https://github.com/o/r/pull/1")
  s.done = done
  return s
}

func docketReview(
  _ state: String, error: String? = nil, prState: String? = nil, progress: DocketProgress? = nil
) -> DocketReview {
  var r = DocketReview(pullRequest: "o/r#1", url: "https://github.com/o/r/pull/1", state: state)
  r.error = error
  r.prState = prState
  r.progress = progress
  return r
}

/// A `docket` event that records a review, as sbd stores it.
func reviewEvent(_ review: DocketReview, _ t: Int64 = 1) -> Event {
  event("docket", t, ["review": try! JSON(encoding: review)])
}

func closedEvent(_ t: Int64 = 1) -> Event { event("docket", t, ["closed": true]) }

func problemEvent(_ text: String, _ t: Int64 = 1) -> Event { event("docket", t, ["problem": .string(text)]) }

struct DocketVerdictCase: Sendable, CustomTestStringConvertible {
  let name: String
  let events: [Event]
  let verdict: Verdict

  init(_ name: String, _ events: [Event], _ state: AttentionState, _ reason: String) {
    self.name = name
    self.events = events
    verdict = Verdict(state: state, reason: reason)
  }

  var testDescription: String { name }
}

@Suite struct DocketVerdicts {
  static let cases: [DocketVerdictCase] = [
    .init("no poll yet", [], .working, "starting the review"),
    .init("a failed poll", [problemEvent("docket exited")], .needsYou, "can't read docket: docket exited"),
    .init(
      "a failed poll after a review", [reviewEvent(docketReview("preparing")), problemEvent("timed out", 2)],
      .needsYou, "can't read docket: timed out"),
    .init(
      "a good poll after a failed one", [problemEvent("timed out"), reviewEvent(docketReview("preparing"), 2)],
      .working, "preparing the review"),
    .init(
      "a failed poll with a multi-line error", [problemEvent("docket exited\n  gh: not found\n")], .needsYou,
      "can't read docket: docket exited gh: not found"),
    .init(
      "no longer listed", [reviewEvent(docketReview("reviewing")), closedEvent(2)], .done,
      "docket closed the review"),
    .init(
      "not started", [reviewEvent(docketReview("not_started", error: "gh is not on PATH"))], .needsYou,
      "did not start: gh is not on PATH"),
    .init(
      "preparing with an error", [reviewEvent(docketReview("preparing", error: "clone failed"))], .needsYou,
      "docket: clone failed"),
    .init(
      "preparing with an empty error", [reviewEvent(docketReview("preparing", error: ""))], .working,
      "preparing the review"),
    .init("preparing", [reviewEvent(docketReview("preparing"))], .working, "preparing the review"),
    .init(
      "reviewing and waiting with needs",
      [reviewEvent(docketReview("reviewing", progress: DocketProgress(waiting: true, needs: "approve git push")))],
      .needsYou, "review needs you: approve git push"),
    .init(
      "reviewing and waiting without needs",
      [reviewEvent(docketReview("reviewing", progress: DocketProgress(detail: "reading", waiting: true)))],
      .needsYou, "review needs you: answer it in docket"),
    .init(
      "reviewing and waiting with empty needs",
      [reviewEvent(docketReview("reviewing", progress: DocketProgress(waiting: true, needs: "")))],
      .needsYou, "review needs you: answer it in docket"),
    .init(
      "reviewing with a detail",
      [
        reviewEvent(docketReview("reviewing", progress: DocketProgress(detail: "reading Docket.swift", waiting: false)))
      ],
      .working, "reviewing: reading Docket.swift"),
    .init("reviewing without progress", [reviewEvent(docketReview("reviewing"))], .working, "reviewing"),
    .init(
      "reviewing with an empty detail", [reviewEvent(docketReview("reviewing", progress: DocketProgress(detail: "")))],
      .working, "reviewing"),
    .init("drafted", [reviewEvent(docketReview("drafted"))], .needsYou, "draft ready to submit"),
    .init(
      "drafted on an open PR", [reviewEvent(docketReview("drafted", prState: "OPEN"))], .needsYou,
      "draft ready to submit"),
    .init(
      "drafted on a merged PR", [reviewEvent(docketReview("drafted", prState: "MERGED"))], .needsYou,
      "draft ready to submit (PR merged)"),
    .init(
      "drafted on a closed PR", [reviewEvent(docketReview("drafted", prState: "CLOSED"))], .needsYou,
      "draft ready to submit (PR closed)"),
    .init("unreviewed", [reviewEvent(docketReview("unreviewed"))], .needsYou, "the review ended without a draft"),
    .init("submitted", [reviewEvent(docketReview("submitted"))], .done, "review submitted"),
    .init("reviewed", [reviewEvent(docketReview("reviewed"))], .done, "reviewed"),
    .init("an unknown state", [reviewEvent(docketReview("paused"))], .needsYou, "docket reports paused"),
    .init("archived while listed", [reviewEvent(docketReview("archived"))], .needsYou, "docket reports archived"),
    .init(
      "the latest review", [reviewEvent(docketReview("preparing")), reviewEvent(docketReview("submitted"), 2)], .done,
      "review submitted"),
  ]

  @Test(arguments: cases) func mapsDocketsStateToAnAttentionState(_ c: DocketVerdictCase) {
    let v = Attention.docketVerdict(docketRow(), facts(c.events))

    #expect(v == c.verdict)
  }

  @Test(arguments: [
    "not_started", "preparing", "reviewing", "drafted", "submitted", "archived", "abandoned", "unreviewed", "reviewed",
  ])
  func noDocketStateIsWaiting(_ state: String) {
    let waiting = docketReview(state, progress: DocketProgress(waiting: true))

    let v = Attention.docketVerdict(docketRow(), facts([reviewEvent(waiting)]))

    #expect(v?.state != .waiting)
  }

  @Test func leavesASessionThatIsNotADocketRowToTheOtherRules() {
    let v = Attention.docketVerdict(session(), facts([reviewEvent(docketReview("drafted"))]))

    #expect(v == nil)
  }

  @Test func markedDoneWinsOverDocket() {
    let v = Attention.evaluate(docketRow(done: true), facts([reviewEvent(docketReview("drafted"))]), now: 2)

    #expect(v == Verdict(state: .done, reason: "marked done"))
  }

  @Test func aRowWithoutAPollNeverAsksForAFirstPrompt() {
    let v = Attention.evaluate(docketRow(), facts([]), now: 2)

    #expect(v == Verdict(state: .working, reason: "starting the review"))
  }

  @Test func aRowThatSitsForDaysNeverGoesStale() {
    let v = Attention.evaluate(docketRow(), facts([reviewEvent(docketReview("drafted"))]), now: 10 * Attention.dayMs)

    #expect(v == Verdict(state: .needsYou, reason: "draft ready to submit"))
  }

  @Test func hookEventsDoNotChangeADocketRow() {
    let f = facts([
      reviewEvent(docketReview("reviewing")), event("UserPromptSubmit", 2, ["prompt": "go"]),
      event("PermissionRequest", 3, tool("Bash", ["command": "rm -rf build"])),
    ])

    #expect(Attention.evaluate(docketRow(), f, now: 4) == Verdict(state: .working, reason: "reviewing"))
  }
}

@Suite struct DocketRefs {
  @Test(arguments: [
    ("https://github.com/o/r/pull/12", "o/r#12"),
    ("https://github.com/o/r/pull/12/", "o/r#12"),
    ("https://github.com/o/r/pull/12/files", "o/r#12"),
    ("https://github.com/o/r/pull/12/commits/abc123", "o/r#12"),
    ("https://github.com/PostHog/posthog/pull/41234", "PostHog/posthog#41234"),
    ("https://github.com/o/r/pull/12?notification_referrer_id=x", "o/r#12"),
    ("https://github.com/o/r/pull/12#discussion_r1", "o/r#12"),
    ("https://www.github.com/o/r/pull/12", "o/r#12"),
    ("github.com/o/r/pull/12", "o/r#12"),
    ("o/r#12", "o/r#12"),
    ("o/r/pull/12", "o/r#12"),
    ("o/r.git#12", "o/r#12"),
    ("  o/r#12 ", "o/r#12"),
    ("12", "d/x#12"),
    ("#12", "d/x#12"),
  ])
  func readsWhatDocketReads(_ input: String, _ expected: String) {
    #expect(DocketRef(input, defaultRepo: "d/x")?.text == expected)
  }

  @Test(arguments: [
    "https://github.com/o/r/issues/12",
    "https://github.com/o/r/pull/abc",
    "https://github.com/o/r/pull/",
    "https://github.com/o/r",
    "https://github.com//r/pull/12",
    "https://example.com/o/r/pull/12",
    "o/r#0",
    "-o/r#1",
    "",
  ])
  func refusesWhatDocketRefuses(_ input: String) {
    #expect(DocketRef(input, defaultRepo: "d/x") == nil)
  }

  @Test func needsADefaultRepoForABareNumber() {
    #expect(DocketRef("12") == nil)
    #expect(DocketRef("12", defaultRepo: "no-slash") == nil)
  }

  @Test func matchesWithoutCaseInTheOwnerAndRepository() {
    let ref = DocketRef("PostHog/posthog#1")!
    #expect(ref.names("posthog/PostHog#1"))
    #expect(ref.names("https://github.com/POSTHOG/posthog/pull/1"))
    #expect(!ref.names("PostHog/posthog#2"))
    #expect(!ref.names("PostHog/other#1"))
    #expect(!ref.names("1"))
  }

  @Test(
    arguments: [
      ("default_repo = \"o/r\"\n", "o/r"),
      ("# docket\ndefault_engine = \"claude\"\n  default_repo='o/r'  # mine\n", "o/r"),
      ("[accounts]\ndefault_repo = \"o/r\"\n", nil),
      ("default_engine = \"claude\"\n", nil),
    ] as [(String, String?)])
  func readsTheTopLevelDefaultRepo(_ toml: String, _ expected: String?) throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("docket-home-\(UUID().uuidString)").path
    try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: home) }
    try toml.write(toFile: "\(home)/config.toml", atomically: true, encoding: .utf8)

    #expect(DocketRef.defaultRepo(docketHome: home) == expected)
  }

  @Test func hasNoDefaultRepoWithoutAConfigFile() {
    #expect(DocketRef.defaultRepo(docketHome: "/nonexistent-\(UUID().uuidString)") == nil)
  }
}

@Suite struct DocketExecutable {
  /// A home with an executable `docket` in `go/bin`.
  func goHome() throws -> String {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("docket-go-\(UUID().uuidString)").path
    try FileManager.default.createDirectory(atPath: "\(home)/go/bin", withIntermediateDirectories: true)
    FileManager.default.createFile(
      atPath: "\(home)/go/bin/docket-sb-test", contents: Data("#!/bin/sh\n".utf8),
      attributes: [.posixPermissions: 0o755])
    return home
  }

  @Test func findsDocketInGoBin() throws {
    let home = try goHome()
    defer { try? FileManager.default.removeItem(atPath: home) }
    var settings = DocketSettings()
    settings.path = "docket-sb-test"

    #expect(settings.executable(home: home, environment: [:]) == "\(home)/go/bin/docket-sb-test")
  }

  @Test func findsDocketInGOBIN() throws {
    let home = try goHome()
    defer { try? FileManager.default.removeItem(atPath: home) }
    var settings = DocketSettings()
    settings.path = "docket-sb-test"

    #expect(
      settings.executable(home: "/nonexistent", environment: ["GOBIN": "\(home)/go/bin"])
        == "\(home)/go/bin/docket-sb-test")
  }

  @Test func looksNoFurtherForAPathWithASlash() throws {
    let home = try goHome()
    defer { try? FileManager.default.removeItem(atPath: home) }
    var settings = DocketSettings()
    settings.path = "bin/docket-sb-test"

    #expect(settings.executable(home: home, environment: [:]) == nil)
  }
}

@Suite struct DocketTimeouts {
  @Test func aStartGetsALongerLimitThanAPoll() throws {
    let c = try JSONCoding.decode(Config.self, from: "{}")
    #expect(c.docket.timeoutSeconds == 120)
    #expect(c.docket.startTimeoutSeconds == 240)
  }

  @Test func aStartKeepsAPollLimitAboveTheDefault() throws {
    let c = try JSONCoding.decode(Config.self, from: #"{"docket": {"timeoutSeconds": 400}}"#)
    #expect(c.docket.startTimeoutSeconds == 400)
  }

  @Test func aStartLimitThatIsSetWins() throws {
    let c = try JSONCoding.decode(Config.self, from: #"{"docket": {"timeoutSeconds": 400, "startTimeoutSeconds": 30}}"#)
    #expect(c.docket.timeoutSeconds == 400)
    #expect(c.docket.startTimeoutSeconds == 30)
  }
}

@Suite struct DocketReviewDecoding {
  /// A Review as docket's list_reviews sends it, with keys that DocketReview leaves out.
  static let docketJSON = #"""
    {
      "pull_request": "PostHog/posthog#41234",
      "url": "https://github.com/PostHog/posthog/pull/41234",
      "title": "Fix the \"flag\" cache — again",
      "author": "someone",
      "state": "reviewing",
      "pr_state": "OPEN",
      "engine": "claude",
      "mode": "background",
      "started_at": "2026-11-04T10:00:00Z",
      "review_id": 3412345678,
      "submittable": false,
      "notes_path": "/Users/x/Library/Application Support/docket/notes/41234.md",
      "error": "",
      "progress": {
        "detail": "Reading \"Docket.swift\"\nthen tests",
        "waiting": true,
        "needs": "approve `git push`",
        "agents": 2,
        "updated_at": "2026-11-04T10:05:00Z"
      },
      "handoff": {"session": "abc"}
    }
    """#

  func decoded() throws -> DocketReview {
    try DocketClient.review(try #require(JSON.parse(DocketReviewDecoding.docketJSON)))
  }

  @Test func decodesSnakeCaseKeys() throws {
    let r = try decoded()

    #expect(r.pullRequest == "PostHog/posthog#41234")
    #expect(r.url == "https://github.com/PostHog/posthog/pull/41234")
    #expect(r.prState == "OPEN")
    #expect(r.notesPath == "/Users/x/Library/Application Support/docket/notes/41234.md")
  }

  @Test func decodesEscapedTextAndProgress() throws {
    let r = try decoded()

    #expect(r.title == "Fix the \"flag\" cache — again")
    #expect(r.progress?.detail == "Reading \"Docket.swift\"\nthen tests")
    #expect(r.progress?.waiting == true)
    #expect(r.progress?.needs == "approve `git push`")
  }

  @Test func decodesAMinimalReview() throws {
    let json = try #require(
      JSON.parse(#"{"pull_request": "o/r#1", "url": "https://github.com/o/r/pull/1", "state": "not_started"}"#))

    let r = try DocketClient.review(json)

    #expect(r == DocketReview(pullRequest: "o/r#1", url: "https://github.com/o/r/pull/1", state: "not_started"))
  }

  @Test func reviewsWhoseProgressDiffersOnlyInUpdatedAtOrAgentsAreEqual() throws {
    let later = DocketReviewDecoding.docketJSON.replacingOccurrences(
      of: "2026-11-04T10:05:00Z", with: "2026-11-04T10:06:00Z"
    ).replacingOccurrences(of: #""agents": 2"#, with: #""agents": 3"#)

    let second = try DocketClient.review(try #require(JSON.parse(later)))

    #expect(second == (try decoded()))
  }

  @Test func aDecodedReviewSurvivesTheEventLog() throws {
    let r = try decoded()

    let f = facts([reviewEvent(r)])

    #expect(f.docket.review == r)
  }
}

@Suite struct DocketReplay {
  /// A replay that starts from a snapshot and reads the tail gives the same
  /// facts as a full replay, at every cut of a docket row's log.
  @Test func theSnapshotAndTheTailBuildWhatAFullReplayBuilds() throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let store = try Store(path: "\(dir)/sb.db")
    let row = docketRow()
    let events = [
      reviewEvent(docketReview("preparing"), 1000),
      reviewEvent(docketReview("reviewing", progress: DocketProgress(detail: "reading", waiting: false)), 2000),
      problemEvent("docket exited", 3000),
      reviewEvent(docketReview("reviewing", progress: DocketProgress(waiting: true, needs: "approve")), 4000),
      reviewEvent(docketReview("drafted", prState: "MERGED"), 5000),
      closedEvent(6000),
    ]
    for cut in 1..<events.count {
      try store.delete(session: row.id)
      try store.save(row)
      for e in events[..<cut] { try store.append(e) }
      try Snapshots.refresh(store, row, build: "b1")
      for e in events[cut...] { try store.append(e) }

      let fromSnapshot = try Snapshots.refresh(store, row, build: "b1").snapshot.replay
      let full = SessionReplay.replaying(try store.events(session: row.id), session: row)

      #expect(fromSnapshot == full, "cut \(cut)")
      #expect(fromSnapshot.facts.docket.closed, "cut \(cut)")
    }
  }
}
