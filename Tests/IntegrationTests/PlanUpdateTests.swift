import Foundation
import SwitchboardCore
import Testing

private let posthog = "PostHog/posthog"
/// #122896's head branch. No row of `document` links #122896.
private let experimentBranch = "haacked/mcp-experiment-condition-ids"
private let experimentTitle = "feat(mcp): return condition_id from experiment tools"
/// #122953's head branch.
private let breakerBranch = "haacked/cdp-dlq-breaker-counts-lookups"
private let rfcs = "PostHog/requests-for-comments-internal"
/// #1209 in `rfcs`, whose head branch holds the RFC's file.
private let rfcPR = 1209
private let rfcBranch = "posthog-code/flag-evaluations-table"
private let rfcPath = "rfcs/flag-evaluations.md"
/// An issue in `rfcs` that the fake serves.
private let issueNumber = 1300
private let issuePath = FakeGitHub.issuePath(rfcs, issueNumber)
private let contentsPath = FakeGitHub.contentsPath(rfcs, rfcPath)

private let start = "<!-- sb:status -->"
private let end = "<!-- /sb:status -->"

private func url(_ repo: String, _ number: Int) -> String { "https://github.com/\(repo)/pull/\(number)" }

private let breakerLink = "[posthog#122953](\(url(posthog, 122953)))"
private let breakerRow = "| 1 | Breaker counts | In review (\(breakerLink)) |"
private let doneStatus = "Done (\(breakerLink))"
private let doneRow = "| 1 | Breaker counts | \(doneStatus) |"
private let docsRow = "| 2 | Docs | Not started |"
private let experimentLink = "[posthog#122896](\(url(posthog, 122896)))"
private let experimentRow = "| 3 | Experiment ids | In review (\(experimentLink)) |"
private let experimentDoneRow = "| 3 | Experiment ids | Done (\(experimentLink)) |"

/// A plan in the shape of the flag evaluations RFC: a status date line, a
/// prose link, an empty generated block, and a work table whose one row with
/// a PR link is `breakerRow`.
private let document = """
  # Flag evaluations

  Status as of 2026-11-01. The runbook is in \(url("PostHog/charts", 18303)).

  \(start)
  \(end)

  | # | Item | Status |
  | --- | --- | --- |
  \(breakerRow)
  \(docsRow)

  """

/// `document` with a second row whose PR, #122896, is open.
private let twoPRDocument = document.replacingOccurrences(of: "\(docsRow)\n", with: "\(docsRow)\n\(experimentRow)\n")

/// GitHub sends an issue body that was edited on the web with CRLF line ends.
private let crlfDocument = document.replacingOccurrences(of: "\n", with: "\r\n")

/// The text before the first start marker and after the end marker that follows it.
private func outside(_ text: String) -> [String] {
  guard let s = text.range(of: start), let e = text.range(of: end, range: s.upperBound..<text.endIndex) else {
    return [text]
  }
  return [String(text[..<s.lowerBound]), String(text[e.upperBound...])]
}

/// The text without its "status as of" lines, whose date sbd sets from its clock.
private func withoutDateLines(_ text: String) -> String {
  text.components(separatedBy: "\n").filter { !$0.lowercased().contains("status as of") }.joined(separator: "\n")
}

/// What a test compares after a write: the text outside the generated block,
/// without the date line.
private func body(_ text: String) -> [String] { outside(text).map(withoutDateLines) }

/// Answers `GET /repos/{rfcs}/pulls/1209` with the head branch that holds the file.
private func servePull(_ github: FakeGitHub) {
  let pull: JSON = [
    "number": .number(Double(rfcPR)), "state": "open", "merged": false, "html_url": .string(url(rfcs, rfcPR)),
    "head": ["ref": .string(rfcBranch), "sha": "a1b2c3", "repo": ["full_name": .string(rfcs)]],
    "base": ["ref": "main", "repo": ["full_name": .string(rfcs)]],
  ]
  github.route("repos/\(rfcs)/pulls/\(rfcPR)", etag: "\"pull-open\"", pull.text)
}

private func requests(_ github: FakeGitHub, _ method: String, to path: String) -> [FakeGitHub.RESTRequest] {
  github.restRequests(to: path).filter { $0.method == method }
}

/// The spec names these commands. Each is spelled here once.
private enum Spec {
  static func propose(_ plan: String) -> [String] { ["plan", "propose", plan, "--json"] }
  static func apply(_ proposal: String) -> [String] { ["plan", "apply", proposal, "--json"] }
  static func reject(_ proposal: String) -> [String] { ["plan", "reject", proposal, "--json"] }
  static func proposals(_ args: [String]) -> [String] { ["plan", "proposals", "--json"] + args }
  static let noQuota = "no quota left"
  static let waits = "waits until"
  static let notOutOfDate = "not out of date"
  static let changedSince = "changed since the proposal"
}

extension Instance {
  fileprivate func planProposals(_ args: String...) throws -> [PlanProposal] {
    try JSONCoding.decode([PlanProposal].self, from: try sb(Spec.proposals(args)))
  }

  fileprivate func updateProposals() throws -> [PlanProposal] { try planProposals().filter { $0.kind == .update } }

  fileprivate func rowSuggestions() throws -> [PlanProposal] {
    try planProposals("--group", "Flags").filter { $0.kind == .row }
  }

  /// Waits for the batch that a poll started on the background queue.
  fileprivate func waitForUpdateProposal(_ what: String = "the update proposal") throws -> PlanProposal {
    try waitFor(what, fetch: { try self.updateProposals().first }, until: { _ in true })
  }

  @discardableResult
  fileprivate func applyProposal(_ id: String) throws -> PlanDocument {
    try JSONCoding.decode(PlanDocument.self, from: try sb(Spec.apply(id)))
  }

  fileprivate func propose(_ plan: String) throws -> PlanProposal {
    try JSONCoding.decode(PlanProposal.self, from: try sb(Spec.propose(plan)))
  }

  /// The answer that the stub prints for the next plan update call, as row
  /// number and new status cell.
  fileprivate func writePlanAnswer(_ rows: [(row: String, status: String)]) throws {
    let answer: JSON = [
      "rows": .array(rows.map { JSON.object(["row": .string($0.row), "status": .string($0.status)]) })
    ]
    try answer.text.write(toFile: "\(home.path)/plan-answer.json", atomically: true, encoding: .utf8)
  }

  /// The arguments of each plan update call that the stub saw.
  fileprivate func planUpdateCalls() -> [String] {
    let text = (try? String(contentsOfFile: "\(home.path)/plan-calls.log", encoding: .utf8)) ?? ""
    return text.split(separator: "\0").map(String.init)
  }

  fileprivate var planInput: String {
    (try? String(contentsOfFile: "\(home.path)/plan-input.txt", encoding: .utf8)) ?? ""
  }

  fileprivate var planText: String { (try? String(contentsOfFile: planFile, encoding: .utf8)) ?? "" }

  fileprivate func planSummary(_ id: String) throws -> PlanSummary {
    let list = try JSONCoding.decode([PlanSummary].self, from: try sb("plan", "ls", "--json"))
    return try #require(list.first { $0.id == id })
  }

  /// Attaches the plan to Flags, lets sbd see #122953 open, and then merges
  /// it, so the breaker row is out of date and the poll starts a batch whose
  /// answer marks it done. `attach` returns the plan's id.
  fileprivate func mergeBreaker(_ github: FakeGitHub, attach: (Instance) throws -> String) throws -> String {
    try addGroup("Flags")
    let id = try attach(self)
    try poll(all: true)
    try poll(all: true)
    try writePlanAnswer([("1", doneStatus)])
    github.change(122953) { $0["state"] = "MERGED" }
    try poll(all: true)
    return id
  }

  /// `mergeBreaker` with `text` in a file plan.
  fileprivate func mergeBreakerInFile(_ github: FakeGitHub, _ text: String = document) throws -> String {
    try mergeBreaker(github) { sbd in
      try sbd.writePlan(sbd.planFile, text)
      return try sbd.attachPlan(sbd.planFile, group: "Flags")
    }
  }

  /// A session on #122896 that the user moved into Flags, after the poller
  /// found its PR.
  fileprivate func experimentSession() throws -> SessionSummary {
    let s = try session(in: posthog, branch: experimentBranch, folder: "experiment")
    try sb("group", "move", s.id, "--to", "Flags")
    try poll(all: true)
    try poll(all: true)
    return try waitFor(s.id, "the session's PR") { $0.pr != nil }
  }
}

@Suite(.blocking(timeLimit: .seconds(120))) struct PlanUpdateTests {
  // MARK: proposing

  @Test func outOfDateRowProducesOneUpdateProposal() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let id = try sbd.mergeBreakerInFile(github)

    let p = try sbd.waitForUpdateProposal()

    #expect(try sbd.updateProposals().map(\.id) == [p.id])
    #expect(p.id.hasPrefix("u"))
    #expect(p.plan == id)
    #expect(p.edits.filter { $0.old == breakerRow }.map(\.new) == [doneRow])
  }

  @Test func proposalNamesItsPlanGroupAndSource() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let id = try sbd.mergeBreakerInFile(github)

    let p = try sbd.waitForUpdateProposal()

    let plan = try sbd.plan(id)
    #expect(p.group == plan.group)
    #expect(p.source == plan.source)
    #expect(p.made > 0)
  }

  @Test func proposalShowsOnThePlanAndItsSummary() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let id = try sbd.mergeBreakerInFile(github)

    let p = try sbd.waitForUpdateProposal()

    #expect(try sbd.plan(id).proposal?.id == p.id)
    #expect(try sbd.planSummary(id).update == p.id)
  }

  @Test func proposalLeavesTheDocumentAlone() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    _ = try sbd.mergeBreakerInFile(github)

    _ = try sbd.waitForUpdateProposal()

    #expect(sbd.planText == document)
  }

  @Test func secondPollOfTheSameBatchAsksTheModelNoMore() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    _ = try sbd.mergeBreakerInFile(github)
    let p = try sbd.waitForUpdateProposal()

    try sbd.poll(all: true)
    sleep(1)

    #expect(try sbd.updateProposals().map(\.id) == [p.id])
    #expect(sbd.planUpdateCalls().count == 1)
  }

  /// The 30 minutes have passed, but the rows and their PR stages are the
  /// pending proposal's, so the batch is the same.
  @Test func pendingBatchIsNotAskedAgainAfterThirtyMinutes() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    _ = try sbd.mergeBreakerInFile(github)
    let p = try sbd.waitForUpdateProposal()

    try sbd.advanceClock(30 * 60_000)
    try sbd.poll(all: true)
    sleep(1)

    #expect(try sbd.updateProposals().map(\.id) == [p.id])
    #expect(sbd.planUpdateCalls().count == 1)
  }

  @Test func modelInputHoldsOnlyTheOutOfDateRow() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    _ = try sbd.mergeBreakerInFile(github, twoPRDocument)

    _ = try sbd.waitForUpdateProposal()

    #expect(sbd.planInput.contains(breakerRow))
    #expect(!sbd.planInput.contains(experimentRow))
    #expect(!sbd.planInput.contains(docsRow))
  }

  @Test func planUpdateCallsAreNotSummaryCalls() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    _ = try sbd.mergeBreakerInFile(github)

    _ = try sbd.waitForUpdateProposal()

    #expect(sbd.summaryCalls().isEmpty)
  }

  // MARK: refused answers

  /// The input numbered only the breaker row, so "2" names a row that the
  /// model was not given.
  @Test func answerThatEditsAnotherRowIsRefusedWithTheReasonOnThePlan() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    try sbd.writePlanAnswer([("2", "Done")])
    try sbd.addGroup("Flags")
    try sbd.writePlan(sbd.planFile, document)
    let id = try sbd.attachPlan(sbd.planFile, group: "Flags")
    try sbd.poll(all: true)
    try sbd.poll(all: true)
    github.change(122953) { $0["state"] = "MERGED" }

    try sbd.poll(all: true)

    _ = try sbd.waitFor("the refusal on the plan", fetch: { try sbd.plan(id).updateNote }) {
      $0.contains(Spec.notOutOfDate)
    }
    #expect(try sbd.updateProposals().isEmpty)
    #expect(try sbd.plan(id).proposal == nil)
    #expect(sbd.planText == document)

    // The failed batch waits like any other, and the next poll keeps its reason.
    try sbd.poll(all: true)
    sleep(1)

    #expect(try sbd.plan(id).updateNote?.contains(Spec.notOutOfDate) == true)
    #expect(sbd.planUpdateCalls().count == 1)
  }

  @Test func answerThatChangesNoRowSettlesTheBatch() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    try sbd.addGroup("Flags")
    try sbd.writePlan(sbd.planFile, document)
    let id = try sbd.attachPlan(sbd.planFile, group: "Flags")
    try sbd.poll(all: true)
    try sbd.poll(all: true)
    try sbd.writePlanAnswer([])
    github.change(122953) { $0["state"] = "MERGED" }

    try sbd.poll(all: true)

    _ = try sbd.waitFor("the note on the plan", fetch: { try sbd.plan(id).updateNote }) {
      $0.contains("left every row as it was")
    }
    #expect(try sbd.plan(id).settled != nil)
    #expect(try sbd.plan(id).proposal == nil)

    try sbd.advanceClock(30 * 60_000)
    try sbd.poll(all: true)
    sleep(1)

    #expect(sbd.planUpdateCalls().count == 1)
  }

  @Test func proposeOfAnAnswerThatEditsAnotherRowFailsWithTheReason() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let id = try sbd.mergeBreakerInFile(github)
    _ = try sbd.waitForUpdateProposal()
    try sbd.writePlanAnswer([("2", "Done")])

    let r = try sbd.run(Spec.propose(id))

    #expect(r.status != 0)
    #expect(r.stderr.contains(Spec.notOutOfDate))
  }

  // MARK: apply

  @Test func applyWritesTheFileOnceAndClearsTheProposal() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let id = try sbd.mergeBreakerInFile(github)
    let p = try sbd.waitForUpdateProposal()

    try sbd.applyProposal(p.id)

    #expect(body(sbd.planText) == body(document.replacingOccurrences(of: breakerRow, with: doneRow)))
    #expect(try sbd.updateProposals().isEmpty)
    #expect(try sbd.plan(id).proposal == nil)
  }

  @Test func applyPrintsThePlanWithTheWrittenRow() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let id = try sbd.mergeBreakerInFile(github)
    let p = try sbd.waitForUpdateProposal()

    let plan = try sbd.applyProposal(p.id)

    #expect(plan.id == id)
    #expect(plan.rows.map(\.text).contains(doneRow))
    #expect(!plan.rows.map(\.text).contains(breakerRow))
  }

  @Test func applySetsTheStatusDate() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    _ = try sbd.mergeBreakerInFile(github)
    let p = try sbd.waitForUpdateProposal()

    try sbd.applyProposal(p.id)

    #expect(!sbd.planText.contains("Status as of 2026-11-01."))
    #expect(sbd.planText.contains("Status as of "))
  }

  @Test func applyWritesTheIssueWithOnePatch() throws {
    let github = try FakeGitHub()
    github.serveIssue(rfcs, issueNumber, body: crlfDocument)
    let sbd = try Instance.withGitHub(github)
    let id = try sbd.mergeBreaker(github) { try $0.attachPlan("\(rfcs)#\(issueNumber)", group: "Flags") }
    let p = try sbd.waitForUpdateProposal()

    try sbd.applyProposal(p.id)

    #expect(requests(github, "PATCH", to: issuePath).count == 1)
    let written = try #require(github.issueBody(rfcs, issueNumber))
    #expect(body(written) == body(crlfDocument.replacingOccurrences(of: breakerRow, with: doneRow)))
    #expect(try sbd.plan(id).proposal == nil)
  }

  @Test func applyWritesThePRFileWithOnePut() throws {
    let github = try FakeGitHub()
    servePull(github)
    github.serveFile(rfcs, rfcPath, branch: rfcBranch, content: document)
    let sbd = try Instance.withGitHub(github)
    let id = try sbd.mergeBreaker(github) { try $0.attachPlan("\(rfcs)#\(rfcPR)", group: "Flags", path: rfcPath) }
    let p = try sbd.waitForUpdateProposal()

    try sbd.applyProposal(p.id)

    let puts = requests(github, "PUT", to: contentsPath)
    #expect(puts.count == 1)
    #expect(JSON.parse(puts.first?.body ?? "")?["branch"]?.string == rfcBranch)
    let written = try #require(github.fileContent(rfcs, rfcPath))
    #expect(body(written) == body(document.replacingOccurrences(of: breakerRow, with: doneRow)))
    #expect(try sbd.plan(id).proposal == nil)
  }

  /// Another commit changes the file between sbd's GET and its PUT. GitHub
  /// answers the stale blob SHA with a 409, and sbd rereads and retries.
  @Test func prFileEditedDuringAnApplyRetriesWithTheNewSHA() throws {
    let github = try FakeGitHub()
    servePull(github)
    github.serveFile(rfcs, rfcPath, branch: rfcBranch, content: document)
    let sbd = try Instance.withGitHub(github)
    _ = try sbd.mergeBreaker(github) { try $0.attachPlan("\(rfcs)#\(rfcPR)", group: "Flags", path: rfcPath) }
    let p = try sbd.waitForUpdateProposal()
    let editedRow = "| 2 | Docs | Drafted by Alex |"
    let edited = document.replacingOccurrences(of: docsRow, with: editedRow)
    github.afterNextGET(contentsPath) { [weak github] in github?.editFile(rfcs, rfcPath, content: edited) }

    try sbd.applyProposal(p.id)

    #expect(requests(github, "PUT", to: contentsPath).count == 2)
    let written = try #require(github.fileContent(rfcs, rfcPath))
    #expect(written.contains(editedRow))
    #expect(written.contains(doneRow))
  }

  @Test func applyToARowThatChangedSinceTheProposalIsRefused() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    _ = try sbd.mergeBreakerInFile(github)
    let p = try sbd.waitForUpdateProposal()
    let byHand = document.replacingOccurrences(
      of: breakerRow, with: "| 1 | Breaker counts | Shipped (\(breakerLink)) |")
    try sbd.writePlan(sbd.planFile, byHand)

    let r = try sbd.run(Spec.apply(p.id))

    #expect(r.status != 0)
    #expect(r.stderr.contains(Spec.changedSince))
    #expect(sbd.planText == byHand)
  }

  /// The user bumps the date line by hand while the proposal waits. The key
  /// of the batch covers only the out-of-date rows, so no new batch replaces it.
  @Test func applyAfterTheDateLineChangedWritesTheRowAndTodaysDate() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    _ = try sbd.mergeBreakerInFile(github)
    let p = try sbd.waitForUpdateProposal()
    let byHand = document.replacingOccurrences(of: "Status as of 2026-11-01.", with: "Status as of 2026-11-03.")
      .replacingOccurrences(of: docsRow, with: "| 2 | Docs | Drafted by Alex |")
    try sbd.writePlan(sbd.planFile, byHand)

    try sbd.applyProposal(p.id)

    #expect(sbd.planText.contains(doneRow))
    #expect(sbd.planText.contains("| 2 | Docs | Drafted by Alex |"))
    #expect(!sbd.planText.contains("Status as of 2026-11-03."))
    #expect(sbd.planText.contains("Status as of "))
  }

  @Test func pollAfterTheRowIsFixedByHandDropsTheProposal() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let id = try sbd.mergeBreakerInFile(github)
    _ = try sbd.waitForUpdateProposal()
    try sbd.writePlan(sbd.planFile, document.replacingOccurrences(of: breakerRow, with: doneRow))

    try sbd.poll(all: true)

    #expect(try sbd.updateProposals().isEmpty)
    #expect(try sbd.plan(id).proposal == nil)
    #expect(try sbd.plan(id).updateNote == nil)
  }

  /// A new batch gets a new id, so an Apply of the proposal it replaced is refused.
  @Test func applyOfAReplacedProposalIsRefused() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let id = try sbd.mergeBreakerInFile(github)
    let first = try sbd.waitForUpdateProposal()

    let second = try sbd.propose(id)

    #expect(second.id != first.id)
    #expect(try sbd.updateProposals().map(\.id) == [second.id])
    #expect(try sbd.run(Spec.apply(first.id)).status != 0)
    #expect(sbd.planText == document)
  }

  // MARK: auto update

  @Test func autoUpdateAppliesTheAnswerWithoutAProposal() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let id = try sbd.mergeBreaker(github) { sbd in
      try sbd.writePlan(sbd.planFile, document)
      let id = try sbd.attachPlan(sbd.planFile, group: "Flags")
      try sbd.sb("plan", "auto", id, "on")
      return id
    }

    try sbd.waitFor("the model's status in the file") { sbd.planText.contains(doneRow) }

    #expect(sbd.planText.contains(docsRow))
    #expect(try sbd.updateProposals().isEmpty)
    #expect(try sbd.plan(id).proposal == nil)
  }

  // MARK: reject

  @Test func rejectRemovesTheProposal() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let id = try sbd.mergeBreakerInFile(github)
    let p = try sbd.waitForUpdateProposal()

    try sbd.sb(Spec.reject(p.id))

    #expect(try sbd.updateProposals().isEmpty)
    #expect(try sbd.plan(id).proposal == nil)
    #expect(sbd.planText == document)
  }

  @Test func rejectedBatchIsNotProposedAgainByLaterPolls() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    _ = try sbd.mergeBreakerInFile(github)
    let p = try sbd.waitForUpdateProposal()
    try sbd.sb(Spec.reject(p.id))

    try sbd.advanceClock(30 * 60_000)
    try sbd.poll(all: true)
    sleep(1)

    #expect(try sbd.updateProposals().isEmpty)
    #expect(sbd.planUpdateCalls().count == 1)
  }

  @Test func proposeRunsARejectedBatchAgain() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let id = try sbd.mergeBreakerInFile(github)
    let p = try sbd.waitForUpdateProposal()
    try sbd.sb(Spec.reject(p.id))

    let again = try sbd.propose(id)

    #expect(again.id != p.id)
    #expect(try sbd.updateProposals().map(\.id) == [again.id])
    #expect(sbd.planUpdateCalls().count == 2)
  }

  // MARK: batching

  @Test func secondBatchWithinThirtyMinutesWaitsAndRunsAfterThem() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let id = try sbd.mergeBreakerInFile(github, twoPRDocument)
    try sbd.applyProposal(try sbd.waitForUpdateProposal("the first proposal").id)
    try sbd.writePlanAnswer([("1", "Done (\(experimentLink))")])
    github.change(122896) { $0["state"] = "MERGED" }

    try sbd.poll(all: true)

    _ = try sbd.waitFor("the wait on the plan", fetch: { try sbd.plan(id).updateNote }) { $0.contains(Spec.waits) }
    #expect(try sbd.updateProposals().isEmpty)
    #expect(sbd.planUpdateCalls().count == 1)

    try sbd.advanceClock(30 * 60_000)
    try sbd.poll(all: true)

    let second = try sbd.waitForUpdateProposal("the second proposal")
    #expect(second.edits.filter { $0.old == experimentRow }.map(\.new) == [experimentDoneRow])
    #expect(sbd.planUpdateCalls().count == 2)
  }

  @Test func proposeIgnoresTheThirtyMinutes() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let id = try sbd.mergeBreakerInFile(github, twoPRDocument)
    try sbd.applyProposal(try sbd.waitForUpdateProposal("the first proposal").id)
    try sbd.writePlanAnswer([("1", "Done (\(experimentLink))")])
    github.change(122896) { $0["state"] = "MERGED" }
    try sbd.poll(all: true)

    let p = try sbd.propose(id)

    #expect(p.edits.filter { $0.old == experimentRow }.map(\.new) == [experimentDoneRow])
  }

  // MARK: budget

  /// The active account's weekly limit is spent, and `sb usage` read it.
  @Test func noBudgetRunsNoTurnAndSaysWhy() throws {
    let fake = try FakeUsage()
    // The recorded weekly-spent reading resets on a date that has passed, so the limit here resets in 2099.
    fake.reply(#"{"limits":[{"kind":"weekly_all","percent":100,"resets_at":"2099-01-01T00:00:00+00:00"}]}"#)
    let github = try FakeGitHub()
    let sbd = try Instance(
      accounts: ["A"], inheriting: .unset,
      config: [
        "usage": ["url": .string(fake.url), "pollSeconds": 0, "keychain": false],
        "github": [
          "gh": .string("\(FakeGitHub.fixtures)/gh-stub"), "url": .string(github.url), "pollSeconds": 0,
        ],
        "tickSeconds": 1,
      ])
    try sbd.sb("account", "use", "A")
    try sbd.signIn("A", token: "token-a")
    _ = try sbd.usage()
    let id = try sbd.mergeBreakerInFile(github)

    let r = try sbd.run(Spec.propose(id))

    #expect(r.status != 0)
    #expect(r.stderr.contains(Spec.noQuota))
    let note = try sbd.waitFor("the note on the plan", fetch: { try sbd.plan(id).updateNote }) { _ in true }
    #expect(note == "no quota left for \(sbd.account("A"))")
    #expect(try sbd.updateProposals().isEmpty)
    #expect(sbd.planUpdateCalls().isEmpty)
  }

  // MARK: row suggestions

  @Test func groupSessionWhosePRNoRowLinksGetsARowSuggestion() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    try sbd.addGroup("Flags")
    try sbd.writePlan(sbd.planFile, document)
    let id = try sbd.attachPlan(sbd.planFile, group: "Flags")
    let s = try sbd.experimentSession()

    let suggestion = try #require(try sbd.rowSuggestions().first)

    #expect(suggestion.id == "\(id):posthog/posthog#122896".lowercased())
    #expect(suggestion.plan == id)
    #expect(suggestion.session == s.id)
    #expect(suggestion.edits.map(\.after) == [docsRow])
  }

  @Test func acceptedSuggestionWritesTheRowAfterTheTable() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    try sbd.addGroup("Flags")
    try sbd.writePlan(sbd.planFile, document)
    let id = try sbd.attachPlan(sbd.planFile, group: "Flags")
    _ = try sbd.experimentSession()
    let suggestion = try #require(try sbd.rowSuggestions().first)

    let plan = try sbd.applyProposal(suggestion.id)

    let lines = sbd.planText.components(separatedBy: "\n")
    let docs = try #require(lines.firstIndex(of: docsRow))
    #expect(lines[docs + 1].contains(url(posthog, 122896)))
    let row = try #require(plan.rows.first { $0.text.contains(url(posthog, 122896)) })
    #expect(row.number == "3")
    #expect(row.item == experimentTitle)
    #expect(row.status == "In progress ([\(posthog)#122896](\(url(posthog, 122896))))")
    #expect(try sbd.plan(id).rows.map(\.text).contains(row.text))
  }

  @Test func acceptedSuggestionIsNoLongerSuggested() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    try sbd.addGroup("Flags")
    try sbd.writePlan(sbd.planFile, document)
    _ = try sbd.attachPlan(sbd.planFile, group: "Flags")
    _ = try sbd.experimentSession()
    let suggestion = try #require(try sbd.rowSuggestions().first)

    try sbd.applyProposal(suggestion.id)

    #expect(try sbd.rowSuggestions().isEmpty)
  }

  @Test func declinedSuggestionStaysDeclinedAcrossARestartOfSbd() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    try sbd.addGroup("Flags")
    try sbd.writePlan(sbd.planFile, document)
    _ = try sbd.attachPlan(sbd.planFile, group: "Flags")
    let s = try sbd.experimentSession()
    let suggestion = try #require(try sbd.rowSuggestions().first)
    try sbd.sb(Spec.reject(suggestion.id))
    #expect(try sbd.rowSuggestions().isEmpty)

    sbd.stopSbd()
    try sbd.startSbd()
    try sbd.poll(all: true)
    try sbd.waitFor(s.id, "the session's PR after the restart") { $0.pr != nil && $0.group != nil }

    #expect(try sbd.rowSuggestions().isEmpty)
    #expect(sbd.planText == document)
  }

  /// Each way a row can link #122953: GitHub ignores the case of owner/name.
  static let breakerLinks = [breakerRow, "| 1 | Breaker counts | In review (\(url("posthog/PostHog", 122953))) |"]

  /// The session on #122953 joins Flags through the row's link. Only the
  /// session on #122896 gets a suggestion.
  @Test(arguments: breakerLinks)
  func sessionWhosePRARowLinksGetsNoSuggestion(_ row: String) throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let flags = try sbd.addGroup("Flags")
    try sbd.writePlan(sbd.planFile, document.replacingOccurrences(of: breakerRow, with: row))
    _ = try sbd.attachPlan(sbd.planFile, group: "Flags")
    let linked = try sbd.session(in: posthog, branch: breakerBranch)
    try sbd.poll(all: true)
    try sbd.poll(all: true)
    try sbd.waitFor(linked.id, "the session to join Flags") { $0.group == flags.id && $0.pr != nil }
    let unlinked = try sbd.experimentSession()

    #expect(try sbd.rowSuggestions().map(\.session) == [unlinked.id])
  }

  @Test func planWithoutAWorkTableGetsNoSuggestion() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    try sbd.addGroup("Flags")
    try sbd.writePlan(sbd.planFile, document)
    let withTable = try sbd.attachPlan(sbd.planFile, group: "Flags")
    let prose = "\(sbd.home.path)/notes/prose.md"
    try sbd.writePlan(prose, "# Notes\n\nFollow-up: \(url(posthog, 122953))\n")
    _ = try sbd.attachPlan(prose, group: "Flags")
    _ = try sbd.experimentSession()

    #expect(try sbd.rowSuggestions().map(\.plan) == [withTable])
  }
}

extension PlanUpdateTests {
  /// Flags and Other each have a file plan whose row links #122953, and each
  /// plan has an update that waits after #122953 merged. The fake must
  /// outlive the test, so it comes back too.
  private func updatesInTwoGroups() throws -> (FakeGitHub, Instance, flags: String, other: String) {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    var other = ""
    let flags = try sbd.mergeBreaker(github) { sbd in
      try sbd.addGroup("Other")
      let otherFile = "\(sbd.home.path)/notes/other.md"
      try sbd.writePlan(otherFile, document)
      other = try sbd.attachPlan(otherFile, group: "Other")
      try sbd.writePlan(sbd.planFile, document)
      return try sbd.attachPlan(sbd.planFile, group: "Flags")
    }
    _ = try sbd.waitFor("both plans' updates", fetch: { try sbd.updateProposals() }) { $0.count == 2 }
    return (github, sbd, flags, other)
  }

  @Test func proposalsWithAGroupListOnlyThatGroupsPlans() throws {
    let (_, sbd, flags, other) = try updatesInTwoGroups()

    #expect(try sbd.planProposals("--group", "Flags").map(\.plan) == [flags])
    #expect(try sbd.planProposals("--group", "Other").map(\.plan) == [other])
  }

  @Test func proposalsWithAPlanListOnlyThatPlan() throws {
    let (_, sbd, flags, other) = try updatesInTwoGroups()

    #expect(try sbd.planProposals("--plan", flags).map(\.plan) == [flags])
    #expect(try sbd.planProposals("--plan", other).map(\.plan) == [other])
  }

  @Test(arguments: [["--group", "Nope"], ["--plan", "pnope"]])
  func proposalsForAGroupOrPlanThatDoesNotExistAreRefused(_ args: [String]) throws {
    let (_, sbd, _, _) = try updatesInTwoGroups()

    #expect(try sbd.run(Spec.proposals(args)).status != 0)
  }
}

/// One real update turn: the installed claude with Haiku answers for a plan
/// whose PR merged, and sbd turns the answer into a proposal.
@Suite(.enabled(if: ClaudeTier.enabled, "bin/test --claude runs it"), .serialized, .blocking(timeLimit: .seconds(300)))
struct PlanUpdateClaudeTests {
  /// Checks the row edit that Haiku's answer made and prints it, so a run
  /// shows what the model wrote.
  private func checkRowEdit(_ proposal: PlanProposal, _ what: String) throws {
    let line = try #require(proposal.edits.first { $0.old == breakerRow }?.new, "\(what) has no edit for the row")
    print("Haiku wrote (\(what)): \(line)")
    let cells = line.split(separator: "|", omittingEmptySubsequences: false).dropFirst().dropLast().map {
      $0.trimmingCharacters(in: .whitespaces)
    }
    #expect(cells.count == 3)
    #expect(Array(cells.prefix(2)) == ["1", "Breaker counts"])
    let status = cells.last ?? ""
    #expect(status.contains(url(posthog, 122953)), "the new cell drops the PR link: \(status)")
    #expect(!status.lowercased().contains("in review"), "the new cell still reads In review: \(status)")
  }

  @Test func haikuRewritesTheMergedRowsStatusCell() throws {
    let claude = try #require(ClaudeTier.claude, "can't find claude. Set SB_TEST_CLAUDE_PATH to its path")
    let github = try FakeGitHub()
    let sbd = try Instance(
      inheriting: .runner,
      config: [
        "claude": .string(claude), "tickSeconds": 1,
        "github": [
          "gh": .string("\(FakeGitHub.fixtures)/gh-stub"), "url": .string(github.url), "pollSeconds": 0,
        ],
        "planUpdates": ["model": "haiku", "timeoutSeconds": 120],
      ])
    let id = try sbd.mergeBreakerInFile(github)

    // The poll that saw the merge starts a batch on its own.
    let (auto, note) = try sbd.waitFor(
      "the poll's batch", timeout: 150,
      fetch: { (try sbd.updateProposals().first, try sbd.plan(id).updateNote) },
      until: { $0.0 != nil || ($0.1 != nil && $0.1?.contains(Spec.waits) == false) })
    let first = try #require(auto, "the batch made no proposal: \(note ?? "no note")")
    try checkRowEdit(first, "the poll's batch")
    #expect(first.edits.contains { $0.old?.hasPrefix("Status as of") == true })

    let again = try sbd.propose(id)
    try checkRowEdit(again, "sb plan propose")
  }
}
