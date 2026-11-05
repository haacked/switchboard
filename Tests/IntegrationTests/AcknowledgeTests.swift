import Foundation
import SwitchboardCore
import Testing

extension Instance {
  /// The session's row in `sb ls --json`.
  func listed(_ id: String) throws -> JSON {
    let rows = try #require(JSON.parse(try sb("ls", "--json"))?.array)
    return try #require(rows.first { $0["id"]?.string == id })
  }

  /// The number of the session's events of the kind.
  func count(_ kind: String, of id: String) throws -> Int {
    try events(id).filter { $0.kind == kind }.count
  }
}

/// `sb ack` takes a session out of the Inbox until its reason changes or a new turn starts.
@Suite(.blocking(timeLimit: .seconds(120))) struct AcknowledgeTests {
  static let readTheReply = "read its last reply and decide what's next"

  /// A session whose first turn ended with an informational reply, so it needs you.
  func needsYouSession(_ sbd: Instance, name: String = "t") throws -> SessionSummary {
    let s = try sbd.new(prompt: "hello", name: name)
    return try sbd.waitFor(s.id, "the summary of the first reply") {
      $0.state == .needsYou && $0.triage?.source == .summary
    }
  }

  // Acknowledging

  @Test func acknowledgedSessionIsWaitingWithTheSameReason() throws {
    let sbd = try Instance()
    let s = try needsYouSession(sbd)

    try sbd.sb("ack", s.id)

    let row = try sbd.listed(s.id)
    #expect(row["state"]?.string == "waiting")
    #expect(row["reason"]?.string == AcknowledgeTests.readTheReply)
    #expect(row["acknowledged"]?.bool == true)
  }

  @Test func acknowledgedSessionLeavesTheInbox() throws {
    let sbd = try Instance()
    let s = try needsYouSession(sbd)

    try sbd.sb("ack", s.id)

    #expect(try sbd.listed(s.id)["triage"] == nil)
    #expect(try !sbd.triage().map(\.id).contains(s.id))
  }

  @Test func acknowledgingLeavesTheSessionsWaitsNotesAndDoneFlag() throws {
    let sbd = try Instance()
    let s = try needsYouSession(sbd)
    try sbd.sb("note", s.id, "check the logs")
    let before = try sbd.get(s.id)

    try sbd.sb("ack", s.id)

    let after = try sbd.get(s.id)
    #expect(after.waits == before.waits)
    #expect(after.notes == before.notes)
    #expect(after.markedDone == before.markedDone)
  }

  @Test func acknowledgingSendsNothingToTheSession() throws {
    let sbd = try Instance()
    let s = try needsYouSession(sbd)
    let sent = try sbd.count("sent", of: s.id)
    let runs = sbd.stubArgs().count

    try sbd.sb("ack", s.id)

    #expect(try sbd.count("sent", of: s.id) == sent)
    #expect(try sbd.count("ack", of: s.id) == 1)
    #expect(sbd.stubArgs().count == runs)
  }

  @Test func ackRequestReturnsTheAcknowledgedSummary() throws {
    let sbd = try Instance()
    let s = try needsYouSession(sbd)

    let got = try sbd.client.call("ack", ["session": .string(s.id)], as: SessionSummary.self)

    #expect(got.id == s.id)
    #expect(got.state == .waiting)
    #expect(got.acknowledged == true)
  }

  @Test func acknowledgingAnAcknowledgedSessionRecordsNoSecondEvent() throws {
    let sbd = try Instance()
    let s = try needsYouSession(sbd)
    try sbd.sb("ack", s.id)

    let again = try JSONCoding.decode(SessionSummary.self, from: try sbd.sb("ack", "--json", s.id))

    #expect(again.acknowledged == true)
    #expect(try sbd.count("ack", of: s.id) == 1)
  }

  @Test func lsAndGetMarkTheReasonAcknowledged() throws {
    let sbd = try Instance()
    let s = try needsYouSession(sbd)

    try sbd.sb("ack", s.id)

    #expect(try sbd.sb("ls").contains("\(AcknowledgeTests.readTheReply) (acknowledged)"))
    #expect(try sbd.sb("get", s.id).contains("\(AcknowledgeTests.readTheReply) (acknowledged)"))
  }

  @Test func lsDoesNotMarkAnUnacknowledgedReason() throws {
    let sbd = try Instance()
    _ = try needsYouSession(sbd)

    #expect(try !sbd.sb("ls").contains("(acknowledged)"))
  }

  @Test func acknowledgmentSurvivesAnSbdRestart() throws {
    let sbd = try Instance()
    let s = try needsYouSession(sbd)
    try sbd.sb("ack", s.id)

    sbd.stopSbd()
    try sbd.startSbd()

    let row = try sbd.listed(s.id)
    #expect(row["state"]?.string == "waiting")
    #expect(row["acknowledged"]?.bool == true)
  }

  // Coming back

  @Test func newTurnThatStopsAgainBringsTheSessionBack() throws {
    let sbd = try Instance()
    let s = try needsYouSession(sbd)
    try sbd.sb("ack", s.id)

    try sbd.sb("send", s.id, "again")

    try sbd.waitFor(s.id, "the second reply") { $0.lastReply == "Done: again" && $0.state == .needsYou }
    let row = try sbd.listed(s.id)
    #expect(row["state"]?.string == "needs_you")
    #expect(row["acknowledged"] == nil)
  }

  @Test func undoRestoresTheSessionToNeedsYou() throws {
    let sbd = try Instance()
    let s = try needsYouSession(sbd)
    try sbd.sb("ack", s.id)

    try sbd.sb("ack", "--undo", s.id)

    let row = try sbd.listed(s.id)
    #expect(row["state"]?.string == "needs_you")
    #expect(row["reason"]?.string == AcknowledgeTests.readTheReply)
    #expect(row["acknowledged"] == nil)
    #expect(try sbd.count("unack", of: s.id) == 1)
  }

  @Test func undoOfAnUnacknowledgedSessionIsRefused() throws {
    let sbd = try Instance()
    let s = try needsYouSession(sbd)

    let r = try sbd.run(["ack", "--undo", s.id])

    #expect(r.status != 0)
    #expect(r.stderr.contains("isn't acknowledged"))
    #expect(try sbd.count("unack", of: s.id) == 0)
  }

  /// The PR's head moves, so the acknowledged Ready to merge item comes back.
  @Test func pushBringsAnAcknowledgedReadyToMergeSessionBack() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withMergeStub(github)
    let s = try MergeTests().readySession(sbd)
    try sbd.sb("ack", s.id)
    #expect(try sbd.listed(s.id)["acknowledged"]?.bool == true)

    github.change(MergeTests.number) { $0["headRefOid"] = "pushed" }
    try sbd.poll(all: true)

    let row = try sbd.listed(s.id)
    #expect(row["state"]?.string == "ready_to_merge")
    #expect(row["acknowledged"] == nil)
  }

  @Test func conflictBringsAnAcknowledgedReadyToMergeSessionBackAsNeedsYou() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withMergeStub(github)
    let s = try MergeTests().readySession(sbd)
    try sbd.sb("ack", s.id)

    github.change(MergeTests.number) { $0["mergeable"] = "CONFLICTING" }
    try sbd.poll(all: true)

    let row = try sbd.listed(s.id)
    #expect(row["state"]?.string == "needs_you")
    #expect(row["reason"]?.string == "rebase; #18303 conflicts with main")
    #expect(row["acknowledged"] == nil)
  }

  // Refusals

  /// The caller and the target can each name the session by its id, its
  /// name, or a prefix of its id.
  @Test(arguments: [("id", "id"), ("name", "id"), ("prefix", "id"), ("id", "name"), ("id", "prefix")])
  func sessionCantAcknowledgeItself(_ target: String, _ caller: String) throws {
    let sbd = try Instance()
    let s = try needsYouSession(sbd, name: "worker")
    func ref(_ form: String) -> String {
      switch form {
      case "name": s.name
      case "prefix": String(s.id.prefix(s.id.count - 1))
      default: s.id
      }
    }

    let r = try sbd.run(["ack", ref(target)], env: ["CLAUDECODE": "1", "SB_SESSION_ID": ref(caller)])

    #expect(r.status != 0)
    #expect(r.stderr.contains("can't acknowledge itself"))
    #expect(try sbd.get(s.id).state == .needsYou)
    #expect(try sbd.count("ack", of: s.id) == 0)
  }

  @Test func ackRequestWithTheTargetAsCallerIsRefused() throws {
    let sbd = try Instance()
    let s = try needsYouSession(sbd)

    #expect(throws: APIError.self) {
      try sbd.client.call("ack", ["session": .string(s.id), "caller": .string(s.id)])
    }
    #expect(try sbd.get(s.id).state == .needsYou)
  }

  @Test func undoByTheSessionItselfIsRefused() throws {
    let sbd = try Instance()
    let s = try needsYouSession(sbd)
    try sbd.sb("ack", s.id)

    let r = try sbd.run(["ack", "--undo", s.id], env: ["CLAUDECODE": "1", "SB_SESSION_ID": s.id])

    #expect(r.status != 0)
    #expect(r.stderr.contains("can't acknowledge itself"))
    #expect(try sbd.get(s.id).acknowledged == true)
  }

  /// The Manager runs inside Claude Code with its own SB_SESSION_ID.
  @Test func anotherSessionCanAcknowledgeTheSession() throws {
    let sbd = try Instance()
    let s = try needsYouSession(sbd, name: "worker")
    let manager = try sbd.new(name: "manager")

    try sbd.sb(["ack", s.id], env: ["CLAUDECODE": "1", "SB_SESSION_ID": manager.id])

    let after = try sbd.get(s.id)
    #expect(after.state == .waiting)
    #expect(after.acknowledged == true)
  }

  @Test func ackWithoutASessionIsRefused() throws {
    let sbd = try Instance()
    let s = try needsYouSession(sbd)

    let r = try sbd.run(["ack"], env: ["CLAUDECODE": "1", "SB_SESSION_ID": s.id])

    #expect(r.status != 0)
    #expect(try sbd.count("ack", of: s.id) == 0)
  }

  @Test func ackOfAWorkingSessionIsRefused() throws {
    let sbd = try Instance()
    let s = try sbd.new(prompt: "slow 60", name: "busy")
    let working = try sbd.waitFor(s.id, "the slow tool call") { $0.state == .working }

    let r = try sbd.run(["ack", s.id])

    #expect(r.status != 0)
    #expect(r.stderr.contains("busy isn't in the Inbox"))
    #expect(try sbd.count("ack", of: working.id) == 0)
  }

  @Test func ackOfAWaitingSessionIsRefusedWithItsReason() throws {
    let sbd = try Instance()
    let s = try needsYouSession(sbd, name: "blocked")
    try sbd.sb("wait", s.id, "CI", "on", "#12")

    let r = try sbd.run(["ack", s.id])

    #expect(r.status != 0)
    #expect(r.stderr.contains("blocked isn't in the Inbox: CI on #12"))
    #expect(try sbd.count("ack", of: s.id) == 0)
  }

  @Test func ackOfADoneSessionIsRefused() throws {
    let sbd = try Instance()
    let s = try needsYouSession(sbd, name: "finished")
    try sbd.sb("done", s.id)

    let r = try sbd.run(["ack", s.id])

    #expect(r.status != 0)
    #expect(r.stderr.contains("finished isn't in the Inbox: marked done"))
  }
}
