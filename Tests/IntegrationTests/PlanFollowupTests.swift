import Foundation
import SwitchboardCore
import Testing

private let posthog = "PostHog/posthog"
/// #122953's head branch.
private let breakerBranch = "haacked/cdp-dlq-breaker-counts-lookups"
private let rfcs = "PostHog/requests-for-comments-internal"
private let rfcPR = 1209
private let rfcBranch = "posthog-code/flag-evaluations-table"
private let rfcPath = "rfcs/flag-evaluations.md"
private let issueNumber = 1300

private func url(_ repo: String, _ number: Int) -> String { "https://github.com/\(repo)/pull/\(number)" }

private let breakerRow = "| 1 | Breaker counts | In review ([posthog#122953](\(url(posthog, 122953)))) |"
private let docsRow = "| 2 | Docs | Not started |"
private let runbookRow = "| 3 | Runbook | In progress |"

/// A work table with a row that links a PR, a Not started row, and an In
/// progress row.
private let document = """
  # Flag evaluations

  <!-- sb:status -->
  <!-- /sb:status -->

  | # | Item | Status |
  | --- | --- | --- |
  \(breakerRow)
  \(docsRow)
  \(runbookRow)

  """

/// The spec names these requests, fields, and lines. Each is spelled here
/// once, so a different spelling in the implementation is a change here only.
private enum Spec {
  static let request = "plan-followup"

  static func command(_ plan: String, _ row: String) -> [String] { ["plan", "followup", plan, row] }

  static func counts(rows: Int, outOfDate: Int, toFollowUp: Int) -> String {
    "(\(rows) rows, \(outOfDate) out of date, \(toFollowUp) to follow up)"
  }

  static func line(_ plan: String, _ number: String, _ item: String) -> String {
    "not started: #\(number) \(item) (sb plan followup \(plan) \(number))"
  }
}

/// Answers `GET /repos/{rfcs}/pulls/1209` with the head branch that holds the file.
private func servePull(_ github: FakeGitHub) {
  let pull: JSON = [
    "number": .number(Double(rfcPR)), "state": "open", "merged": false, "html_url": .string(url(rfcs, rfcPR)),
    "head": ["ref": .string(rfcBranch), "sha": "a1b2c3", "repo": ["full_name": .string(rfcs)]],
    "base": ["ref": "main", "repo": ["full_name": .string(rfcs)]],
  ]
  github.route("repos/\(rfcs)/pulls/\(rfcPR)", etag: "\"pull-open\"", pull.text)
}

extension Instance {
  /// Runs `sb plan followup --json` and returns the new follow-up.
  fileprivate func planFollowup(_ plan: String, _ row: String) throws -> SessionSummary {
    try JSONCoding.decode(SessionSummary.self, from: try sb(Spec.command(plan, row) + ["--json"]))
  }

  fileprivate func followups() throws -> [SessionSummary] {
    try JSONCoding.decode([SessionSummary].self, from: try sb("followup", "ls", "--json"))
  }

  fileprivate func planSummaries(_ args: String...) throws -> [PlanSummary] {
    try JSONCoding.decode([PlanSummary].self, from: try sb(["plan", "ls", "--json"] + args))
  }

  /// The text of each row that `sb plan ls --json` lists in `canFollowUp`.
  fileprivate func canFollowUp(_ plan: String) throws -> [String] {
    let p = try #require(try planSummaries().first { $0.id == plan })
    return p.canFollowUp.map(\.text)
  }

  /// The `followup` of the row of `sb plan get --json` with this text.
  fileprivate func rowFollowup(_ plan: String, _ text: String) throws -> String? {
    let row = try #require(try self.plan(plan).rows.first { $0.text == text }, "no row \(text)")
    return row.followup
  }

  /// Flags with `document` attached as a file plan.
  fileprivate func flagsWithDocument(_ text: String = document) throws -> (group: GroupSummary, plan: String) {
    let flags = try addGroup("Flags")
    try writePlan(planFile, text)
    return (flags, try attachPlan(planFile, group: "Flags"))
  }
}

@Suite(.blocking(timeLimit: .seconds(120))) struct PlanFollowupTests {
  // MARK: making the follow-up

  @Test func notStartedRowBecomesAFollowupInThePlansGroup() throws {
    let sbd = try Instance.withGitHub(try FakeGitHub())
    let (flags, id) = try sbd.flagsWithDocument()

    let f = try sbd.planFollowup(id, "2")

    #expect(try sbd.followups().map(\.id) == [f.id])
    #expect(f.state == .notStarted)
    #expect(f.group == flags.id)
    #expect(f.parent == nil)
    #expect(f.name == "Docs")
    #expect(f.followup?.prompt == "Docs")
    #expect(f.followup?.link == (try sbd.plan(id).source.path))
    #expect(f.followup?.trigger.kind == .manual)
  }

  @Test func followupRecordsThePlanRowItCameFrom() throws {
    let sbd = try Instance.withGitHub(try FakeGitHub())
    let (_, id) = try sbd.flagsWithDocument()

    let f = try sbd.planFollowup(id, "2")

    let row = try #require(try sbd.get(f.id).followup?.planRow)
    #expect(row.source == (try sbd.plan(id).source))
    #expect(row.item == "Docs")
  }

  @Test func titleIsTheItemsFirstSentenceAndThePromptIsTheWholeItem() throws {
    let sbd = try Instance.withGitHub(try FakeGitHub())
    let item = "Split the parser. It reads each table twice."
    let (_, id) = try sbd.flagsWithDocument(document.replacingOccurrences(of: "| Docs |", with: "| \(item) |"))

    let f = try sbd.planFollowup(id, "2")

    #expect(f.name == Followup.title(item))
    #expect(f.followup?.prompt == item)
  }

  @Test func secondFollowupOfTheSameRowIsRefusedAndNamesTheFirst() throws {
    let sbd = try Instance.withGitHub(try FakeGitHub())
    let (_, id) = try sbd.flagsWithDocument()
    let f = try sbd.planFollowup(id, "2")

    let r = try sbd.run(Spec.command(id, "2"))

    #expect(r.status != 0)
    #expect(r.stderr.contains(f.id))
    #expect(try sbd.followups().map(\.id) == [f.id])
  }

  @Test func rowWithAFollowupLeavesCanFollowUpAndShowsTheFollowup() throws {
    let sbd = try Instance.withGitHub(try FakeGitHub())
    let (_, id) = try sbd.flagsWithDocument()
    #expect(try sbd.canFollowUp(id) == [docsRow])
    #expect(try sbd.rowFollowup(id, docsRow) == nil)

    let f = try sbd.planFollowup(id, "2")

    #expect(try sbd.canFollowUp(id).isEmpty)
    #expect(try sbd.rowFollowup(id, docsRow) == f.id)
  }

  /// The check and the add run in one turn of the state queue.
  @Test func twoRequestsAtOnceMakeOneFollowup() throws {
    let sbd = try Instance.withGitHub(try FakeGitHub())
    let (_, id) = try sbd.flagsWithDocument()
    let outcomes = [Outcome<JSON>(), Outcome<JSON>()]

    for outcome in outcomes {
      Thread.detachNewThread {
        outcome.result = Result {
          try Client(home: sbd.home).call(Spec.request, ["plan": .string(id), "row": "2"])
        }
        outcome.done.signal()
      }
    }
    for outcome in outcomes { #expect(outcome.done.wait(timeout: .now() + 30) == .success) }

    #expect(outcomes.filter { (try? $0.result?.get()) != nil }.count == 1)
    #expect(try sbd.followups().count == 1)
  }

  @Test func rowKeepsItsFollowupAcrossARestartOfSbd() throws {
    let sbd = try Instance.withGitHub(try FakeGitHub())
    let (_, id) = try sbd.flagsWithDocument()
    let f = try sbd.planFollowup(id, "2")

    sbd.stopSbd()
    try sbd.startSbd()

    #expect(try sbd.rowFollowup(id, docsRow) == f.id)
    #expect(try sbd.canFollowUp(id).isEmpty)
    #expect(try sbd.run(Spec.command(id, "2")).status != 0)
  }

  @Test func cliPrintsTheFollowupAsFollowupAddDoes() throws {
    let sbd = try Instance.withGitHub(try FakeGitHub())
    let (_, id) = try sbd.flagsWithDocument()

    let out = try sbd.sb(Spec.command(id, "2"))

    let f = try #require(try sbd.followups().first)
    #expect(out.hasPrefix("\(f.id)  Docs\n"))
    #expect(out.contains("prompt:  Docs"))
  }

  /// A row's item comes from text that someone else may have written, so the
  /// printed prompt shows its control characters as escapes.
  @Test func printedPromptEscapesControlCharacters() throws {
    let sbd = try Instance.withGitHub(try FakeGitHub())
    let row = "| 2 | Docs\u{1b}[2K | Not started |"
    let (_, id) = try sbd.flagsWithDocument(document.replacingOccurrences(of: docsRow, with: row))

    let out = try sbd.sb(Spec.command(id, "2"))

    #expect(!out.contains("\u{1b}"))
    #expect(out.contains("prompt:  Docs\\u{1b}[2K"))
  }

  // MARK: refusals

  @Test func rowWithAPRLinkIsRefused() throws {
    let sbd = try Instance.withGitHub(try FakeGitHub())
    let (_, id) = try sbd.flagsWithDocument()

    let r = try sbd.run(Spec.command(id, "1"))

    #expect(r.status != 0)
    #expect(r.stderr.contains("posthog#122953"))
    #expect(try sbd.followups().isEmpty)
  }

  /// The row that links a PR, named by its item text instead of its number.
  @Test func rowWithAPRLinkNamedByItsItemIsRefused() throws {
    let sbd = try Instance.withGitHub(try FakeGitHub())
    let (_, id) = try sbd.flagsWithDocument()

    #expect(failure(sbd, Spec.request, ["plan": .string(id), "row": "Breaker counts"]) != "no error")
    #expect(try sbd.followups().isEmpty)
  }

  @Test func rowWithAPRLinkThatSaysNotStartedIsRefused() throws {
    let sbd = try Instance.withGitHub(try FakeGitHub())
    let row = "| 4 | Dedup | Not started (\(url(posthog, 122179))) |"
    let (_, id) = try sbd.flagsWithDocument(document.replacingOccurrences(of: runbookRow, with: row))
    #expect(try sbd.plan(id).rows.map(\.text).contains(row))

    let r = try sbd.run(Spec.command(id, "4"))

    #expect(r.status != 0)
    #expect(try sbd.followups().isEmpty)
    #expect(try !sbd.canFollowUp(id).contains(row))
  }

  @Test(arguments: ["3", "Runbook"])
  func rowWhoseStatusIsInProgressIsRefused(_ row: String) throws {
    let sbd = try Instance.withGitHub(try FakeGitHub())
    let (_, id) = try sbd.flagsWithDocument()

    let r = try sbd.run(Spec.command(id, row))

    #expect(r.status != 0)
    #expect(try sbd.followups().isEmpty)
  }

  @Test(arguments: ["9", "Nothing like it", ""])
  func rowThatNoRowMatchesIsRefused(_ row: String) throws {
    let sbd = try Instance.withGitHub(try FakeGitHub())
    let (_, id) = try sbd.flagsWithDocument()

    #expect(failure(sbd, Spec.request, ["plan": .string(id), "row": .string(row)]) != "no error")
    #expect(try sbd.followups().isEmpty)
  }

  @Test func planThatDoesNotExistIsRefused() throws {
    let sbd = try Instance.withGitHub(try FakeGitHub())
    _ = try sbd.flagsWithDocument()

    #expect(failure(sbd, Spec.request, ["plan": "p-nothing", "row": "2"]) != "no error")
    #expect(try sbd.followups().isEmpty)
  }

  // MARK: naming the row

  static let namedRows = """
    | # | Item | Status |
    | --- | --- | --- |
    | 2 | Docs | Not started |
    | 4 | Dashboards | Not started |
    | 5 | Write the runbook | Not started |
    | 7 | 2FA rollout | Not started |
    | 8 | Alerts | Not started |

    """

  /// Each name and the item of the row it picks. The names run in order,
  /// so a row that an earlier name took is not picked again.
  static let names: [(String, String)] = [
    // `#` wins over "2FA rollout", whose item text starts with 2.
    ("2", "Docs"),
    // A prefix that only one row has, compared without case.
    ("2f", "2FA rollout"),
    // The whole item text, compared without case.
    ("DASHBOARDS", "Dashboards"),
    ("write", "Write the runbook"),
    // A leading # names the row by its `#` cell.
    ("#8", "Alerts"),
  ]

  @Test func rowIsNamedByNumberThenItemThenUniquePrefix() throws {
    let sbd = try Instance.withGitHub(try FakeGitHub())
    let (_, id) = try sbd.flagsWithDocument(PlanFollowupTests.namedRows)

    for (name, item) in PlanFollowupTests.names {
      #expect(try sbd.planFollowup(id, name).followup?.prompt == item, "\(name)")
    }
  }

  @Test func prefixThatTwoRowsShareIsRefused() throws {
    let sbd = try Instance.withGitHub(try FakeGitHub())
    let (_, id) = try sbd.flagsWithDocument(PlanFollowupTests.namedRows)

    #expect(failure(sbd, Spec.request, ["plan": .string(id), "row": "d"]) != "no error")
    #expect(try sbd.followups().isEmpty)
  }

  @Test func rowOfATableWithoutANumberIsNamedByItsItem() throws {
    let sbd = try Instance.withGitHub(try FakeGitHub())
    let (_, id) = try sbd.flagsWithDocument("| Item | Status |\n| --- | --- |\n| Docs | Not started |\n")

    let f = try sbd.planFollowup(id, "Docs")

    #expect(f.followup?.prompt == "Docs")
  }

  // MARK: which follow-ups count

  @Test(arguments: [["followup", "rm"], ["rm"]])
  func removedFollowupNoLongerCounts(_ remove: [String]) throws {
    let sbd = try Instance.withGitHub(try FakeGitHub())
    let (_, id) = try sbd.flagsWithDocument()
    let f = try sbd.planFollowup(id, "2")

    try sbd.sb(remove + [f.id])

    #expect(try sbd.canFollowUp(id) == [docsRow])
    #expect(try sbd.rowFollowup(id, docsRow) == nil)
    #expect(try sbd.planFollowup(id, "2").id != f.id)
  }

  @Test func startedFollowupStillCounts() throws {
    let repos = try Repos()
    let checkout = try repos.make("acme/widgets")
    let sbd = try Instance.withGitHub(try FakeGitHub())
    let (_, id) = try sbd.flagsWithDocument()
    let f = try sbd.planFollowup(id, "2")

    _ = try sbd.client.call("followup-start", ["session": .string(f.id), "path": .string(checkout), "branch": "b1"])

    #expect(try sbd.get(f.id).state != .notStarted)
    #expect(try sbd.canFollowUp(id).isEmpty)
    #expect(try sbd.rowFollowup(id, docsRow) == f.id)
    #expect(try sbd.run(Spec.command(id, "2")).status != 0)
  }

  /// A row is matched by plan source and item text, so a new `#` keeps it.
  @Test func renumberedRowKeepsItsFollowup() throws {
    let sbd = try Instance.withGitHub(try FakeGitHub())
    let (_, id) = try sbd.flagsWithDocument()
    let f = try sbd.planFollowup(id, "2")
    let renumbered = "| 7 | Docs | Not started |"

    try sbd.writePlan(sbd.planFile, document.replacingOccurrences(of: docsRow, with: renumbered))
    try sbd.poll(all: true)

    #expect(try sbd.rowFollowup(id, renumbered) == f.id)
    #expect(try sbd.canFollowUp(id).isEmpty)
  }

  @Test func rowWithEditedItemTextIsANewRow() throws {
    let sbd = try Instance.withGitHub(try FakeGitHub())
    let (_, id) = try sbd.flagsWithDocument()
    _ = try sbd.planFollowup(id, "2")
    let edited = "| 2 | Docs for the API | Not started |"

    try sbd.writePlan(sbd.planFile, document.replacingOccurrences(of: docsRow, with: edited))
    try sbd.poll(all: true)

    #expect(try sbd.canFollowUp(id) == [edited])
    #expect(try sbd.rowFollowup(id, edited) == nil)
  }

  /// The same document attached to two groups is two plans with one source.
  /// A row matches by source and item text, so each plan's row counts the
  /// follow-up made from either.
  @Test func followupCountsForEveryPlanOfTheSameDocument() throws {
    let sbd = try Instance.withGitHub(try FakeGitHub())
    let (_, first) = try sbd.flagsWithDocument()
    try sbd.addGroup("Other")
    let second = try sbd.attachPlan(sbd.planFile, group: "Other")

    let f = try sbd.planFollowup(first, "2")

    #expect(try sbd.rowFollowup(second, docsRow) == f.id)
    #expect(try sbd.run(Spec.command(second, "2")).status != 0)
  }

  // MARK: plans without Not started rows

  @Test func planWithNoNotStartedRowsListsNone() throws {
    let sbd = try Instance.withGitHub(try FakeGitHub())
    let (_, id) = try sbd.flagsWithDocument(document.replacingOccurrences(of: "\(docsRow)\n", with: ""))

    #expect(try sbd.canFollowUp(id).isEmpty)
    #expect(try !sbd.sb("plan", "ls").contains("not started:"))
  }

  // MARK: showing the rows

  @Test func planLsPrintsTheCountAndALinePerRowToFollowUp() throws {
    let sbd = try Instance.withGitHub(try FakeGitHub())
    let (_, id) = try sbd.flagsWithDocument()

    let out = try sbd.sb("plan", "ls")

    #expect(out.contains(Spec.counts(rows: 2, outOfDate: 0, toFollowUp: 1)))
    #expect(out.contains(Spec.line(id, "2", "Docs")))
  }

  @Test func planLsDropsTheLineOnceTheRowHasAFollowup() throws {
    let sbd = try Instance.withGitHub(try FakeGitHub())
    let (_, id) = try sbd.flagsWithDocument()
    _ = try sbd.planFollowup(id, "2")

    let out = try sbd.sb("plan", "ls")

    #expect(out.contains(Spec.counts(rows: 2, outOfDate: 0, toFollowUp: 0)))
    #expect(!out.contains(Spec.line(id, "2", "Docs")))
  }

  @Test func planGetPrintsTheRowsToFollowUp() throws {
    let sbd = try Instance.withGitHub(try FakeGitHub())
    let (_, id) = try sbd.flagsWithDocument()

    #expect(try sbd.sb("plan", "get", id).contains(Spec.line(id, "2", "Docs")))
  }

  @Test func sbGetOfASessionInTheGroupShowsCanFollowUp() throws {
    let sbd = try Instance.withGitHub(try FakeGitHub())
    let (_, id) = try sbd.flagsWithDocument()
    let s = try sbd.new(name: "alpha")
    try sbd.sb("group", "move", s.id, "--to", "Flags")

    let got = try JSONCoding.decode(SessionSummary.self, from: try sbd.sb("get", "--json", s.id))

    let plan = try #require(got.plans?.first { $0.id == id })
    #expect(plan.canFollowUp.map(\.text) == [docsRow])
    #expect(try sbd.sb("get", s.id).contains(Spec.line(id, "2", "Docs")))

    _ = try sbd.planFollowup(id, "2")
    let after = try JSONCoding.decode(SessionSummary.self, from: try sbd.sb("get", "--json", s.id))
    #expect(after.plans?.first { $0.id == id }?.canFollowUp.isEmpty == true)
  }

  @Test func groupLsShowsCanFollowUp() throws {
    let sbd = try Instance.withGitHub(try FakeGitHub())
    let (_, id) = try sbd.flagsWithDocument()

    let plan = try #require(try sbd.groupNamed("Flags").plans?.first { $0.id == id })

    #expect(plan.canFollowUp.map(\.text) == [docsRow])
    #expect(try sbd.sb("group", "ls").contains(Spec.line(id, "2", "Docs")))

    _ = try sbd.planFollowup(id, "2")
    let after = try #require(try sbd.groupNamed("Flags").plans?.first { $0.id == id })
    #expect(after.canFollowUp.isEmpty)
    #expect(try !sbd.sb("group", "ls").contains(Spec.line(id, "2", "Docs")))
  }

  /// A second work table numbers from 1 too, so `#` 2 names two rows, and a
  /// third leaves its row's `#` blank. The ref that the Board sends and that
  /// `sb plan` prints names each row alone.
  @Test func eachListedRowFollowsUpByItsRef() throws {
    let sbd = try Instance.withGitHub(try FakeGitHub())
    let more = """
      | # | Item | Status |
      | --- | --- | --- |
      | 2 | Exports | Not started |

      | # | Item | Status |
      | --- | --- | --- |
      |  | Write the docs | Not started |

      """
    let (_, id) = try sbd.flagsWithDocument(document + "\n" + more)
    let listed = try #require(try sbd.planSummaries().first { $0.id == id }).canFollowUp
    #expect(listed.map(\.ref) == ["Docs", "Exports", "Write the docs"])

    let out = try sbd.sb("plan", "ls")
    #expect(out.contains("not started: #2 Exports (sb plan followup \(id) Exports)"))
    #expect(out.contains("not started: Write the docs (sb plan followup \(id) 'Write the docs')"))

    for row in listed {
      #expect(try sbd.planFollowup(id, try #require(row.ref)).followup?.prompt == row.item)
    }
  }

  // MARK: link and repository

  /// Each remote plan's document and the link its follow-ups get.
  static let remotePlans: [(String, String?, String)] = [
    ("\(rfcs)#\(issueNumber)", nil, "https://github.com/\(rfcs)/issues/\(issueNumber)"),
    ("\(rfcs)#\(rfcPR)", rfcPath, url(rfcs, rfcPR)),
  ]

  @Test(arguments: remotePlans)
  func remotePlansFollowupLinksItsDocumentAndTakesItsRepo(_ doc: String, _ path: String?, _ link: String) throws {
    let github = try FakeGitHub()
    github.serveIssue(rfcs, issueNumber, body: document)
    servePull(github)
    github.serveFile(rfcs, rfcPath, branch: rfcBranch, content: document)
    let sbd = try Instance.withGitHub(github)
    try sbd.addGroup("Flags")
    let id = try sbd.attachPlan(doc, group: "Flags", path: path)

    let f = try sbd.planFollowup(id, "2")

    #expect(f.followup?.link == link)
    #expect(f.followup?.repository == rfcs)
  }

  @Test func filePlanInAGroupWithoutARepoMakesAFollowupWithoutOne() throws {
    let sbd = try Instance.withGitHub(try FakeGitHub())
    let (_, id) = try sbd.flagsWithDocument()

    #expect(try sbd.planFollowup(id, "2").followup?.repository == nil)
  }

  @Test func repoThatTheGroupsFollowupsShareWins() throws {
    let github = try FakeGitHub()
    github.serveIssue(rfcs, issueNumber, body: document)
    let sbd = try Instance.withGitHub(github)
    try sbd.addGroup("Flags")
    _ = try add(sbd, ["prompt": "Fix the cache.", "repository": "acme/widgets", "group": "Flags"])
    _ = try add(sbd, ["prompt": "Fix the queue.", "repository": "acme/widgets", "group": "Flags"])
    let id = try sbd.attachPlan("\(rfcs)#\(issueNumber)", group: "Flags")

    #expect(try sbd.planFollowup(id, "2").followup?.repository == "acme/widgets")
  }

  @Test func groupWhoseFollowupsHaveTwoReposFallsBackToTheDocumentsRepo() throws {
    let github = try FakeGitHub()
    github.serveIssue(rfcs, issueNumber, body: document)
    let sbd = try Instance.withGitHub(github)
    try sbd.addGroup("Flags")
    _ = try add(sbd, ["prompt": "Fix the cache.", "repository": "acme/widgets", "group": "Flags"])
    _ = try add(sbd, ["prompt": "Fix the queue.", "repository": "acme/gadgets", "group": "Flags"])
    let id = try sbd.attachPlan("\(rfcs)#\(issueNumber)", group: "Flags")

    #expect(try sbd.planFollowup(id, "2").followup?.repository == rfcs)
  }

  @Test func groupWhoseFollowupsHaveTwoReposMakesAFileFollowupWithoutOne() throws {
    let sbd = try Instance.withGitHub(try FakeGitHub())
    let (_, id) = try sbd.flagsWithDocument()
    _ = try add(sbd, ["prompt": "Fix the cache.", "repository": "acme/widgets", "group": "Flags"])
    _ = try add(sbd, ["prompt": "Fix the queue.", "repository": "acme/gadgets", "group": "Flags"])

    #expect(try sbd.planFollowup(id, "2").followup?.repository == nil)
  }

  /// The session on #122953 joins Flags through the plan's link to it.
  @Test func repoOfTheGroupsSessionPRWinsOverTheDocumentsRepo() throws {
    let github = try FakeGitHub()
    github.serveIssue(rfcs, issueNumber, body: document)
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: posthog, branch: breakerBranch)
    let flags = try sbd.addGroup("Flags")
    let id = try sbd.attachPlan("\(rfcs)#\(issueNumber)", group: "Flags")
    try sbd.poll(all: true)
    try sbd.poll(all: true)
    try sbd.waitFor(s.id, "the session to join Flags") { $0.group == flags.id && $0.pr != nil }

    #expect(try sbd.planFollowup(id, "2").followup?.repository == posthog)
  }

  // MARK: session plans

  @Test func sessionPlansFollowupIsTheSessionsChildInItsGroup() throws {
    let sbd = try Instance.withGitHub(try FakeGitHub())
    let flags = try sbd.addGroup("Flags")
    let owner = try sbd.new(name: "owner")
    try sbd.sb("group", "move", owner.id, "--to", "Flags")
    try sbd.writePlan(sbd.planFile, document)
    let id = try sbd.attachPlan(sbd.planFile, session: owner.id)

    let f = try sbd.planFollowup(id, "2")

    #expect(f.parent == owner.id)
    #expect(f.group == flags.id)
  }

  @Test func sessionPlanTakesTheSessionsRepoBeforeTheDocuments() throws {
    let github = try FakeGitHub()
    github.serveIssue(rfcs, issueNumber, body: document)
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: posthog, branch: breakerBranch)
    try sbd.poll(all: true)
    try sbd.waitFor(s.id, "the session's PR") { $0.pr != nil }
    let id = try sbd.attachPlan("\(rfcs)#\(issueNumber)", session: s.id)

    #expect(try sbd.planFollowup(id, "2").followup?.repository == posthog)
  }
}
