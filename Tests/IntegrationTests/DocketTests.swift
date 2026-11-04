import Foundation
import SwitchboardCore
import Testing

extension Instance {
  static let docketStub = root.appendingPathComponent("Tests/IntegrationTests/Fixtures/docket-stub").path
}

/// The DOCKET_HOME of one test, which holds the files that Fixtures/docket-stub reads and writes.
final class DocketHome {
  static let pollMs: Int64 = 30_000

  let path: String

  init() throws {
    var template = Array("/tmp/sbk.XXXXXX".utf8CString)
    guard let dir = mkdtemp(&template) else { throw TestError(description: "mkdtemp failed") }
    path = String(cString: dir)
  }

  deinit { try? FileManager.default.removeItem(atPath: path) }

  /// The config that points sbd at the stub, with this folder as the stub's DOCKET_HOME.
  var config: [String: JSON] {
    [
      "docket": ["path": .string(Instance.docketStub), "pollSeconds": .number(Double(DocketHome.pollMs / 1000))],
      "env": ["DOCKET_HOME": .string(path)],
    ]
  }

  /// The reviews that the stub's `list_reviews` returns from now on.
  func setReviews(_ reviews: [JSON]) throws {
    try JSON.array(reviews).text.write(toFile: "\(path)/stub-reviews.json", atomically: true, encoding: .utf8)
  }

  func write(_ file: String, _ text: String = "") throws {
    try text.write(toFile: "\(path)/\(file)", atomically: true, encoding: .utf8)
  }

  func remove(_ file: String) throws {
    try FileManager.default.removeItem(atPath: "\(path)/\(file)")
  }

  /// Each tool call that the stub received, oldest first.
  func calls() -> [JSON] {
    let text = (try? String(contentsOfFile: "\(path)/stub-calls.jsonl", encoding: .utf8)) ?? ""
    return text.split(separator: "\n").compactMap { JSON.parse(String($0)) }
  }

  func calls(_ tool: String) -> [JSON] { calls().filter { $0["tool"]?.string == tool } }
}

/// A review as docket's `list_reviews` reports it, with snake_case keys.
private func listed(
  _ pr: String, _ state: String, progress: JSON? = nil, prState: String? = nil, error: String? = nil
) -> JSON {
  let parts = pr.split(separator: "#")
  var review: [String: JSON] = [
    "pull_request": .string(pr), "url": .string("https://github.com/\(parts[0])/pull/\(parts[1])"),
    "title": "Stub PR", "author": "someone", "state": .string(state), "engine": "claude", "mode": "background",
    "submittable": .bool(state == "drafted"),
  ]
  if let progress { review["progress"] = progress }
  if let prState { review["pr_state"] = .string(prState) }
  if let error { review["error"] = .string(error) }
  return .object(review)
}

/// Runs `sb docket --json` with the arguments and returns the row it printed.
private func startDocket(_ sbd: Instance, _ args: String...) throws -> SessionSummary {
  try JSONCoding.decode(SessionSummary.self, from: try sbd.sb(["docket", "--json"] + args))
}

/// The docket rows that `sb ls --json` lists.
private func docketRows(_ sbd: Instance) throws -> [SessionSummary] {
  try JSONCoding.decode([SessionSummary].self, from: try sbd.sb("ls", "--json")).filter { $0.docket != nil }
}

/// Moves sbd's clock by one poll interval, and waits for the row to match.
@discardableResult
private func poll(_ sbd: Instance, _ id: String, _ what: String, _ match: (SessionSummary) -> Bool) throws
  -> SessionSummary
{
  try sbd.advanceClock(DocketHome.pollMs)
  return try sbd.waitFor(id, what, match)
}

/// The row's `docket` events, each as the review's state, the state and
/// "waiting" while the review waits on the user, "closed", or "problem".
private func docketLog(_ sbd: Instance, _ id: String) throws -> [String] {
  try sbd.events(id).filter { $0.kind == "docket" }.map { e in
    if let review = e.data["review"] {
      let state = review["state"]?.string ?? "?"
      return review["progress"]?["waiting"]?.bool == true ? "\(state) waiting" : state
    }
    if e.data["closed"]?.bool == true { return "closed" }
    if e.data["problem"] != nil { return "problem" }
    return "?"
  }
}

@Suite(.timeLimit(.minutes(2))) struct DocketTests {
  @Test func startsAReviewAndListsItsRow() throws {
    let docket = try DocketHome()
    let sbd = try Instance(config: docket.config)

    let s = try startDocket(sbd, "o/r#1")

    #expect(s.state == .working)
    #expect(s.reason == "preparing the review")
    #expect(s.docket?.pullRequest == "o/r#1")
    #expect(s.docket?.url == "https://github.com/o/r/pull/1")
    let starts = docket.calls("start_review")
    #expect(starts.map { $0["arguments"]?["pull_request"]?.string } == ["o/r#1"])
    #expect(starts.first?["arguments"]?["existing"] == nil)
    #expect(try docketRows(sbd).map(\.id) == [s.id])
    #expect(try docketRows(sbd).first?.docket?.pullRequest == "o/r#1")
    let polled = try poll(sbd, s.id, "the first poll") { $0.docket?.review?.state == "preparing" }
    #expect(polled.state == .working)
    #expect(polled.reason == "preparing the review")
    #expect(try sbd.sb("get", s.id).contains("docket:  preparing  o/r#1"))
    #expect(sbd.stubArgs().isEmpty)
  }

  @Test func eachChangeToTheReviewMovesTheRowAndLogsOneEvent() throws {
    let docket = try DocketHome()
    let sbd = try Instance(config: docket.config)
    let s = try startDocket(sbd, "o/r#1")
    try poll(sbd, s.id, "the first poll") { $0.docket?.review?.state == "preparing" }

    let reading: JSON = ["detail": "reading Docket.swift", "waiting": false, "agents": 2, "updated_at": "T1"]
    try docket.setReviews([listed("o/r#1", "reviewing", progress: reading)])
    let reviewing = try poll(sbd, s.id, "reviewing") { $0.docket?.review?.state == "reviewing" }
    #expect(reviewing.state == .working)
    #expect(reviewing.reason == "reviewing: reading Docket.swift")

    // A poll that sees only a new updated_at records no event.
    let later: JSON = ["detail": "reading Docket.swift", "waiting": false, "agents": 2, "updated_at": "T2"]
    try docket.setReviews([listed("o/r#1", "reviewing", progress: later)])
    let polls = docket.calls("list_reviews").count
    try sbd.advanceClock(DocketHome.pollMs)
    try sbd.waitFor("a poll that changes nothing") { docket.calls("list_reviews").count > polls }

    let asking: JSON = ["detail": "reading Docket.swift", "waiting": true, "needs": "approve git push", "agents": 2]
    try docket.setReviews([listed("o/r#1", "reviewing", progress: asking)])
    let waiting = try poll(sbd, s.id, "the review to wait on the user") { $0.state == .needsYou }
    #expect(waiting.reason == "review needs you: approve git push")

    try docket.setReviews([listed("o/r#1", "drafted", prState: "OPEN")])
    let drafted = try poll(sbd, s.id, "the draft") { $0.docket?.review?.state == "drafted" }
    #expect(drafted.state == .needsYou)
    #expect(drafted.reason == "draft ready to submit")

    try docket.setReviews([])
    let closed = try poll(sbd, s.id, "docket to drop the review") { $0.state == .done }
    #expect(closed.reason == "docket closed the review")
    #expect(closed.docket?.closed == true)

    #expect(
      try docketLog(sbd, s.id) == ["preparing", "reviewing", "reviewing waiting", "drafted", "closed"])
  }

  @Test func tracksAReviewThatDocketAlreadyHasInsteadOfStartingOne() throws {
    let docket = try DocketHome()
    try docket.setReviews([listed("o/r#2", "reviewing", progress: ["detail": "reading", "waiting": false])])
    let sbd = try Instance(config: docket.config)

    let s = try startDocket(sbd, "https://github.com/o/r/pull/2")

    #expect(docket.calls("start_review").isEmpty)
    #expect(!docket.calls("list_reviews").isEmpty)
    #expect(s.docket?.pullRequest == "o/r#2")
    #expect(s.docket?.url == "https://github.com/o/r/pull/2")
    for again in ["o/r#2", "https://github.com/o/r/pull/2/files"] {
      #expect(try startDocket(sbd, again).id == s.id, "\(again)")
    }
    #expect(docket.calls("start_review").isEmpty)
    #expect(try docketRows(sbd).map(\.id) == [s.id])
    let tracked = try poll(sbd, s.id, "the tracked review") { $0.docket?.review?.state == "reviewing" }
    #expect(tracked.reason == "reviewing: reading")
  }

  @Test func aStartErrorFromDocketFailsAndAddsNoRow() throws {
    let docket = try DocketHome()
    let sbd = try Instance(config: docket.config)
    try docket.write("stub-start-error", "o/r#4 has notes of yours. Pass existing to keep them.")

    let refused = try sbd.run("docket", "--json", "o/r#4")

    #expect(refused.status != 0)
    #expect(refused.stderr.contains("o/r#4 has notes of yours. Pass existing to keep them."))
    #expect(try docketRows(sbd).isEmpty)
  }

  @Test func existingPassesThroughToStartReview() throws {
    let docket = try DocketHome()
    let sbd = try Instance(config: docket.config)

    let s = try startDocket(sbd, "--existing", "append", "o/r#4")

    #expect(docket.calls("start_review").map { $0["arguments"]?["existing"]?.string } == ["append"])
    #expect(s.docket?.pullRequest == "o/r#4")
  }

  @Test func refusesAnExistingModeThatDocketDoesNotHave() throws {
    let docket = try DocketHome()
    let sbd = try Instance(config: docket.config)

    let refused = try sbd.run("docket", "--json", "--existing", "keep", "o/r#4")

    #expect(refused.status != 0)
    #expect(refused.stderr.contains("append or overwrite"))
    #expect(docket.calls("start_review").isEmpty)
    #expect(try docketRows(sbd).isEmpty)
  }

  @Test func refusesTerminalRequestsAndRemovesTheRowWithoutAskingDocket() throws {
    let docket = try DocketHome()
    let sbd = try Instance(config: docket.config)
    let s = try startDocket(sbd, "o/r#5")
    // The row changes only after the poll that the clock starts ends, so no poll runs after this.
    try docket.setReviews([listed("o/r#5", "drafted")])
    try poll(sbd, s.id, "the draft") { $0.docket?.review?.state == "drafted" }

    for op in ["open", "send", "resume", "terminals"] {
      let answer = failure(sbd, op, ["session": .string(s.id), "text": "hi"])
      #expect(answer != "no error", "\(op)")
      #expect(answer.contains("docket"), "\(op): \(answer)")
    }
    let calls = docket.calls().count
    try sbd.sb("rm", s.id)

    #expect(try docketRows(sbd).isEmpty)
    #expect(throws: (any Error).self) { try sbd.get(s.id) }
    try sbd.advanceClock(DocketHome.pollMs)
    try sbd.advanceClock(DocketHome.pollMs)
    // The stub starts within a second of a tick that polls, so a wait of a second shows that none did.
    let called = (try? sbd.waitFor("a docket call after the rm", timeout: 1) { docket.calls().count > calls }) != nil
    #expect(!called)
    #expect(sbd.stubArgs().isEmpty)
  }

  @Test func aBrokenDocketPutsTheRowInNeedsYouUntilAPollSucceeds() throws {
    let docket = try DocketHome()
    let sbd = try Instance(config: docket.config)
    let s = try startDocket(sbd, "o/r#6")
    try docket.setReviews([listed("o/r#6", "reviewing", progress: ["detail": "reading", "waiting": false])])
    try poll(sbd, s.id, "reviewing") { $0.docket?.review?.state == "reviewing" }

    try docket.write("stub-broken")
    let broken = try poll(sbd, s.id, "the failed poll") { $0.state == .needsYou }
    #expect(broken.reason.hasPrefix("can't read docket"))
    #expect(broken.reason.contains("broken on purpose"))
    #expect(broken.docket?.review?.state == "reviewing")

    try docket.remove("stub-broken")
    let restored = try poll(sbd, s.id, "a good poll") { $0.state == .working }
    #expect(restored.reason == "reviewing: reading")
    #expect(try docketLog(sbd, s.id) == ["preparing", "reviewing", "problem", "reviewing"])
  }

  @Test func aBrokenDocketFailsAStartAndAddsNoRow() throws {
    let docket = try DocketHome()
    try docket.write("stub-broken")
    let sbd = try Instance(config: docket.config)

    let refused = try sbd.run("docket", "--json", "o/r#7")

    #expect(refused.status != 0)
    #expect(refused.stderr.contains("broken on purpose"))
    #expect(try docketRows(sbd).isEmpty)
  }

  @Test func restartsAReviewThatDocketCouldNotStart() throws {
    let docket = try DocketHome()
    let trust = "accept its trust prompt, then call start_review again"
    try docket.setReviews([listed("o/r#3", "not_started", error: trust)])
    let sbd = try Instance(config: docket.config)

    let s = try startDocket(sbd, "o/r#3")

    #expect(docket.calls("start_review").count == 1)
    #expect(s.reason == "preparing the review")

    try docket.setReviews([listed("o/r#3", "not_started", error: trust)])
    let stuck = try poll(sbd, s.id, "the failed start") { $0.docket?.review?.state == "not_started" }
    #expect(stuck.state == .needsYou)

    let again = try startDocket(sbd, "o/r#3")

    #expect(again.id == s.id)
    #expect(docket.calls("start_review").count == 2)
    #expect(again.reason == "preparing the review")
  }

  @Test func tracksAnOpenReviewNamedByABareNumberOrInAnotherCase() throws {
    let docket = try DocketHome()
    try docket.write("config.toml", "default_repo = \"o/r\"\n")
    try docket.setReviews([listed("o/r#2", "reviewing", progress: ["detail": "reading", "waiting": false])])
    let sbd = try Instance(config: docket.config)

    let s = try startDocket(sbd, "2")

    #expect(s.docket?.pullRequest == "o/r#2")
    for again in ["#2", "O/R#2", "https://www.github.com/o/R/pull/2", "o/r/pull/2"] {
      #expect(try startDocket(sbd, again).id == s.id, "\(again)")
    }
    #expect(docket.calls("start_review").isEmpty)
    #expect(try docketRows(sbd).map(\.id) == [s.id])
  }

  @Test func refusesABadParentOrGroupBeforeDocketRuns() throws {
    let docket = try DocketHome()
    let sbd = try Instance(config: docket.config)

    for args in [["--parent", "nosuch"], ["--group", "nosuch"]] {
      let refused = try sbd.run(["docket", "--json"] + args + ["o/r#1"])
      #expect(refused.status != 0, "\(args)")
    }

    #expect(docket.calls().isEmpty)
    #expect(try docketRows(sbd).isEmpty)
  }

  @Test func aPollSecondsOfZeroNeverPolls() throws {
    let docket = try DocketHome()
    var config = docket.config
    config["docket"] = ["path": .string(Instance.docketStub), "pollSeconds": 0]
    let sbd = try Instance(config: config)
    _ = try startDocket(sbd, "o/r#1")
    let calls = docket.calls().count

    try sbd.advanceClock(DocketHome.pollMs)
    try sbd.advanceClock(DocketHome.pollMs)
    // The stub starts within a second of a tick that polls, so a wait of a second shows that none did.
    let called = (try? sbd.waitFor("a docket poll", timeout: 1) { docket.calls().count > calls }) != nil
    #expect(!called)
  }

  @Test func aDocketThatHangsTimesOutAndTheRowRecovers() throws {
    let docket = try DocketHome()
    var config = docket.config
    config["docket"] = [
      "path": .string(Instance.docketStub), "pollSeconds": .number(Double(DocketHome.pollMs / 1000)),
      "timeoutSeconds": 1,
    ]
    let sbd = try Instance(config: config)
    let s = try startDocket(sbd, "o/r#12")
    try docket.write("stub-list-delay", "5")

    let hung = try poll(sbd, s.id, "the poll to time out") { $0.state == .needsYou }
    #expect(hung.reason.hasPrefix("can't read docket"))

    try docket.remove("stub-list-delay")
    let restored = try poll(sbd, s.id, "a good poll") { $0.state == .working }
    #expect(restored.reason == "preparing the review")
  }

  @Test func aPollThatStartedBeforeARowWasAddedLeavesThatRowOpen() throws {
    let docket = try DocketHome()
    let sbd = try Instance(config: docket.config)
    let first = try startDocket(sbd, "o/r#10")
    try docket.setReviews([listed("o/r#10", "reviewing", progress: ["detail": "reading", "waiting": false])])
    try docket.write("stub-list-delay", "2")
    let polls = docket.calls("list_reviews").count
    try sbd.advanceClock(DocketHome.pollMs)
    try sbd.waitFor("the slow poll to read the reviews") { docket.calls("list_reviews").count > polls }
    try docket.remove("stub-list-delay")

    let second = try startDocket(sbd, "o/r#11")
    try sbd.waitFor(first.id, "the slow poll to finish") { $0.docket?.review?.state == "reviewing" }

    let row = try sbd.get(second.id)
    #expect(row.docket?.closed == false)
    #expect(row.state == .working)
  }

  @Test func aRestartKeepsEachRowsStateFromTheEventLog() throws {
    let docket = try DocketHome()
    let sbd = try Instance(config: docket.config)
    let drafted = try startDocket(sbd, "o/r#8")
    let gone = try startDocket(sbd, "o/r#9")
    try docket.setReviews([listed("o/r#8", "drafted", prState: "MERGED")])
    try poll(sbd, drafted.id, "the draft") { $0.docket?.review?.state == "drafted" }
    try sbd.waitFor(gone.id, "docket to drop o/r#9") { $0.state == .done }
    let before = try docketRows(sbd).sorted { $0.id < $1.id }
    #expect(before.first { $0.id == drafted.id }?.reason == "draft ready to submit (PR merged)")
    #expect(before.first { $0.id == gone.id }?.reason == "docket closed the review")

    sbd.stopSbd()
    try sbd.startSbd()

    let after = try docketRows(sbd).sorted { $0.id < $1.id }
    #expect(after.map(\.id) == before.map(\.id))
    #expect(after.map(\.state) == before.map(\.state))
    #expect(after.map(\.reason) == before.map(\.reason))
    #expect(after.map(\.docket) == before.map(\.docket))
  }
}
