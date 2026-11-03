import Foundation
import SwitchboardCore
import Testing

private let posthog = "PostHog/posthog"
/// #122953's head branch.
private let breakerBranch = "haacked/cdp-dlq-breaker-counts-lookups"
private let rfcs = "PostHog/requests-for-comments-internal"
/// #1209 in `rfcs`, whose head branch holds the RFC's file.
private let rfcPR = 1209
private let rfcBranch = "posthog-code/flag-evaluations-table"
private let rfcPath = "rfcs/flag-evaluations.md"
/// An issue in `rfcs` that the fake serves. GitHub has no fixture for it.
private let issueNumber = 1300
private let issuePath = FakeGitHub.issuePath(rfcs, issueNumber)
private let contentsPath = FakeGitHub.contentsPath(rfcs, rfcPath)

private let start = "<!-- sb:status -->"
private let end = "<!-- /sb:status -->"
private let header = "| Session | State | Wait | PR |"

private func url(_ repo: String, _ number: Int) -> String { "https://github.com/\(repo)/pull/\(number)" }

private let breakerRow = "| 1 | Breaker counts | In review ([posthog#122953](\(url(posthog, 122953)))) |"
private let docsRow = "| 2 | Docs | Not started |"

/// A plan in the shape of the flag evaluations RFC: a prose link, an empty
/// generated block, and a work table whose one row with a PR link is
/// `breakerRow`.
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

private let documentLinks = [PlanLink(repo: "PostHog/charts", number: 18303), PlanLink(repo: posthog, number: 122953)]

/// GitHub sends an issue body that was edited on the web with CRLF line ends.
private let crlfDocument = document.replacingOccurrences(of: "\n", with: "\r\n")

/// The text between the first marker pair.
private func between(_ text: String) -> String? {
  guard let s = text.range(of: start), let e = text.range(of: end, range: s.upperBound..<text.endIndex) else {
    return nil
  }
  return String(text[s.upperBound..<e.lowerBound])
}

/// The text before the first start marker and after the end marker that follows it.
private func outside(_ text: String) -> [String] {
  guard let s = text.range(of: start), let e = text.range(of: end, range: s.upperBound..<text.endIndex) else {
    return [text]
  }
  return [String(text[..<s.lowerBound]), String(text[e.upperBound...])]
}

/// Answers `GET /repos/{rfcs}/pulls/1209` with the head branch that holds the file.
private func servePull(_ github: FakeGitHub, state: String = "open") {
  let pull: JSON = [
    "number": .number(Double(rfcPR)), "state": .string(state), "merged": false,
    "html_url": .string(url(rfcs, rfcPR)),
    "head": ["ref": .string(rfcBranch), "sha": "a1b2c3", "repo": ["full_name": .string(rfcs)]],
    "base": ["ref": "main", "repo": ["full_name": .string(rfcs)]],
  ]
  github.route("repos/\(rfcs)/pulls/\(rfcPR)", etag: "\"pull-\(state)\"", pull.text)
}

private func requests(_ github: FakeGitHub, _ method: String, to path: String) -> [FakeGitHub.RESTRequest] {
  github.restRequests(to: path).filter { $0.method == method }
}

extension Instance {
  /// Runs `sb plan attach` and returns the new plan's id.
  func attachPlan(_ doc: String, group: String? = nil, session: String? = nil, path: String? = nil) throws -> String {
    var args = ["plan", "attach", "--json", doc]
    if let group { args += ["--group", group] }
    if let session { args += ["--session", session] }
    if let path { args += ["--path", path] }
    let out = try sb(args)
    return try #require(JSON.parse(out)?["id"]?.string, "sb plan attach printed no id: \(out)")
  }

  func plan(_ id: String) throws -> PlanDocument {
    try JSONCoding.decode(PlanDocument.self, from: try sb("plan", "get", "--json", id))
  }

  /// The ids that `sb plan ls --json` lists, with its extra arguments.
  func planIds(_ args: String...) throws -> [String] {
    try #require(JSON.parse(try sb(["plan", "ls", "--json"] + args))?.array).compactMap { $0["id"]?.string }
  }

  @discardableResult
  func addGroup(_ name: String) throws -> GroupSummary {
    try JSONCoding.decode(GroupSummary.self, from: try sb("group", "add", "--json", name))
  }

  func groupNamed(_ name: String) throws -> GroupSummary {
    let list = try JSONCoding.decode(GroupList.self, from: try sb("group", "ls", "--json"))
    return try #require(list.groups.first { $0.name == name })
  }

  /// The text of each out-of-date row that `sb group ls --json` shows on the group.
  func outOfDate(group name: String) throws -> [String] {
    try groupNamed(name).plans?.flatMap(\.outOfDate).map(\.text) ?? []
  }

  /// The text of each out-of-date row that `sb get --json` shows on the session.
  func outOfDate(session id: String) throws -> [String] {
    let s = try JSONCoding.decode(SessionSummary.self, from: try sb("get", "--json", id))
    return s.plans?.flatMap(\.outOfDate).map(\.text) ?? []
  }

  /// Writes the file and moves its modification time forward, so a read
  /// within the same second still sees a change.
  func writePlan(_ path: String, _ text: String) throws {
    try FileManager.default.createDirectory(
      atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    let before = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? Date()
    try text.write(toFile: path, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.modificationDate: max(before, Date()).addingTimeInterval(5)], ofItemAtPath: path)
  }

  var planFile: String { "\(home.path)/notes/flag-evaluations.md" }
}

@Suite(.timeLimit(.minutes(2))) struct PlanTests {
  // MARK: reads

  @Test func fileReadShowsLinksAndRows() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    try sbd.addGroup("Flags")
    try sbd.writePlan(sbd.planFile, document)
    let id = try sbd.attachPlan(sbd.planFile, group: "Flags")

    try sbd.poll(all: true)

    let plan = try sbd.plan(id)
    #expect(plan.source.kind == .file)
    #expect(plan.links == documentLinks)
    #expect(plan.rows.map(\.text) == [breakerRow])
    #expect(plan.error == nil)
  }

  @Test(arguments: ["\(rfcs)#\(issueNumber)", "https://github.com/\(rfcs)/issues/\(issueNumber)"])
  func issueReadShowsLinksAndRows(_ doc: String) throws {
    let github = try FakeGitHub()
    github.serveIssue(rfcs, issueNumber, body: crlfDocument)
    let sbd = try Instance.withGitHub(github)
    try sbd.addGroup("Flags")
    let id = try sbd.attachPlan(doc, group: "Flags")

    try sbd.poll(all: true)

    let plan = try sbd.plan(id)
    #expect(plan.source.kind == .issue)
    #expect(plan.links == documentLinks)
    #expect(plan.rows.map(\.text) == [breakerRow])
  }

  @Test func issueRereadSendsTheETag() throws {
    let github = try FakeGitHub()
    github.serveIssue(rfcs, issueNumber, body: document)
    let sbd = try Instance.withGitHub(github)
    try sbd.addGroup("Flags")
    _ = try sbd.attachPlan("\(rfcs)#\(issueNumber)", group: "Flags")

    try sbd.poll(all: true)
    try sbd.poll(all: true)

    let gets = requests(github, "GET", to: issuePath)
    #expect(gets.count >= 2)
    #expect(gets.last?.ifNoneMatch != nil)
  }

  @Test(arguments: ["\(rfcs)#\(rfcPR)", url(rfcs, rfcPR)])
  func prFileReadShowsLinksAndRows(_ doc: String) throws {
    let github = try FakeGitHub()
    servePull(github)
    github.serveFile(rfcs, rfcPath, branch: rfcBranch, content: document)
    let sbd = try Instance.withGitHub(github)
    try sbd.addGroup("Flags")
    let id = try sbd.attachPlan(doc, group: "Flags", path: rfcPath)

    try sbd.poll(all: true)

    let plan = try sbd.plan(id)
    #expect(plan.source.kind == .pr)
    #expect(plan.links == documentLinks)
    #expect(plan.rows.map(\.text) == [breakerRow])
    #expect(requests(github, "GET", to: contentsPath).allSatisfy { $0.query["ref"] == rfcBranch })
  }

  @Test func planSurvivesARestartOfSbd() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    try sbd.addGroup("Flags")
    try sbd.writePlan(sbd.planFile, document)
    let id = try sbd.attachPlan(sbd.planFile, group: "Flags")
    try sbd.poll(all: true)
    let before = try sbd.plan(id)

    sbd.stopSbd()
    try sbd.startSbd()

    #expect(try sbd.plan(id) == before)
  }

  // MARK: attach refusals

  @Test func prURLWithoutAPathIsRefused() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    try sbd.addGroup("Flags")

    let r = try sbd.run(["plan", "attach", url(rfcs, rfcPR), "--group", "Flags"])

    #expect(r.status != 0)
    #expect(try sbd.planIds().isEmpty)
  }

  @Test func issueThatGitHubDoesNotFindIsRefused() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    try sbd.addGroup("Flags")

    let r = try sbd.run(["plan", "attach", "\(rfcs)#\(issueNumber)", "--group", "Flags"])

    #expect(r.status != 0)
    #expect(r.stderr.contains("404"))
    #expect(try sbd.planIds().isEmpty)
  }

  @Test func failedReadRecordsTheErrorAndKeepsTheRows() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    try sbd.addGroup("Flags")
    try sbd.writePlan(sbd.planFile, document)
    let id = try sbd.attachPlan(sbd.planFile, group: "Flags")
    let rows = try sbd.plan(id).rows.map(\.text)
    #expect(!rows.isEmpty)
    try FileManager.default.removeItem(atPath: sbd.planFile)

    try sbd.poll()

    let plan = try sbd.plan(id)
    #expect(plan.error?.contains(sbd.planFile) == true)
    #expect(plan.rows.map(\.text) == rows)
  }

  @Test(arguments: [[String](), ["--group", "Flags", "--session", "SESSION"]])
  func attachNeedsExactlyOneOfGroupAndSession(_ owner: [String]) throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    try sbd.addGroup("Flags")
    let s = try sbd.new(name: "alpha")
    try sbd.writePlan(sbd.planFile, document)

    let r = try sbd.run(["plan", "attach", sbd.planFile] + owner.map { $0 == "SESSION" ? s.id : $0 })

    #expect(r.status != 0)
    #expect(try sbd.planIds().isEmpty)
  }

  // MARK: group join

  /// Each way a group plan can link #122953.
  static let joiningPlans = [
    document,
    "Follow-up: \(url(posthog, 122953))\n",
    // GitHub ignores the case of owner/name.
    "| 1 | Breaker counts | \(url("posthog/PostHog", 122953)) |\n",
  ]

  @Test(arguments: joiningPlans)
  func sessionWhosePRAGroupPlanLinksJoinsTheGroup(_ text: String) throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: posthog, branch: breakerBranch)
    let flags = try sbd.addGroup("Flags")
    try sbd.writePlan(sbd.planFile, text)
    _ = try sbd.attachPlan(sbd.planFile, group: "Flags")

    try sbd.poll(all: true)
    try sbd.poll(all: true)

    try sbd.waitFor(s.id, "the session to join Flags") { $0.group == flags.id }
  }

  /// nil places the session in no group.
  @Test(arguments: [nil, "Other"] as [String?])
  func sessionPlacedByHandStaysWhereTheUserPutIt(_ placed: String?) throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: posthog, branch: breakerBranch)
    try sbd.addGroup("Flags")
    let other = try sbd.addGroup("Other")
    if let placed {
      try sbd.sb("group", "move", s.id, "--to", placed)
    } else {
      try sbd.sb("group", "move", s.id, "--ungrouped")
    }
    try sbd.writePlan(sbd.planFile, document)
    _ = try sbd.attachPlan(sbd.planFile, group: "Flags")

    try sbd.poll(all: true)
    try sbd.poll(all: true)

    #expect(try sbd.get(s.id).group == (placed == nil ? nil : other.id))
  }

  @Test func sessionThatPlansOfTwoGroupsLinkStaysUngrouped() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: posthog, branch: breakerBranch)
    try sbd.addGroup("Flags")
    try sbd.addGroup("Other")
    try sbd.writePlan(sbd.planFile, document)
    let second = "\(sbd.home.path)/notes/other.md"
    try sbd.writePlan(second, "See \(url(posthog, 122953)).\n")
    _ = try sbd.attachPlan(sbd.planFile, group: "Flags")
    _ = try sbd.attachPlan(second, group: "Other")

    try sbd.poll(all: true)
    try sbd.poll(all: true)

    #expect(try sbd.get(s.id).group == nil)
  }

  @Test func planAttachedToASessionMovesNoSession() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: posthog, branch: breakerBranch)
    let owner = try sbd.new(name: "owner")
    try sbd.writePlan(sbd.planFile, document)
    _ = try sbd.attachPlan(sbd.planFile, session: owner.id)

    try sbd.poll(all: true)
    try sbd.poll(all: true)

    #expect(try sbd.get(s.id).group == nil)
    #expect(try sbd.get(owner.id).group == nil)
  }

  @Test func linkOnlyInTheGeneratedBlockMovesNoSession() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: posthog, branch: breakerBranch)
    try sbd.addGroup("Flags")
    try sbd.writePlan(
      sbd.planFile,
      "# Plan\n\n\(start)\n\(header)\n| --- | --- | --- | --- |\n| x | Working | | \(url(posthog, 122953)) |\n\(end)\n")
    let id = try sbd.attachPlan(sbd.planFile, group: "Flags")

    try sbd.poll(all: true)
    try sbd.poll(all: true)

    #expect(try sbd.plan(id).links.isEmpty)
    #expect(try sbd.get(s.id).group == nil)
  }

  // MARK: out of date

  /// A session on #122953 in Flags, whose file plan has `breakerRow`, after
  /// the poller read both.
  func flagsWithBreakerRow(_ github: FakeGitHub) throws -> (Instance, SessionSummary) {
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: posthog, branch: breakerBranch)
    try sbd.addGroup("Flags")
    try sbd.writePlan(sbd.planFile, document)
    _ = try sbd.attachPlan(sbd.planFile, group: "Flags")
    try sbd.poll(all: true)
    try sbd.poll(all: true)
    try sbd.waitFor(s.id, "the session to join Flags") { $0.group != nil }
    return (sbd, s)
  }

  @Test func rowWhosePROnlyStaysOpenIsCurrent() throws {
    let github = try FakeGitHub()
    let (sbd, s) = try flagsWithBreakerRow(github)

    #expect(try sbd.outOfDate(group: "Flags").isEmpty)
    #expect(try sbd.outOfDate(session: s.id).isEmpty)
  }

  @Test(arguments: ["MERGED", "CLOSED"])
  func rowWhosePRMergedOrClosedIsOutOfDateOnTheGroupAndTheSession(_ state: String) throws {
    let github = try FakeGitHub()
    let (sbd, s) = try flagsWithBreakerRow(github)

    github.change(122953) { $0["state"] = .string(state) }
    try sbd.poll(all: true)

    #expect(try sbd.outOfDate(group: "Flags") == [breakerRow])
    #expect(try sbd.outOfDate(session: s.id) == [breakerRow])
  }

  @Test func editedRowIsNoLongerOutOfDate() throws {
    let github = try FakeGitHub()
    let (sbd, s) = try flagsWithBreakerRow(github)
    github.change(122953) { $0["state"] = "MERGED" }
    try sbd.poll(all: true)
    #expect(try sbd.outOfDate(group: "Flags") == [breakerRow])

    let doneRow = "| 1 | Breaker counts | Done ([posthog#122953](\(url(posthog, 122953)))) |"
    try sbd.writePlan(sbd.planFile, document.replacingOccurrences(of: breakerRow, with: doneRow))
    try sbd.poll(all: true)

    #expect(try sbd.plan(try sbd.planIds()[0]).rows.map(\.text) == [doneRow])
    #expect(try sbd.outOfDate(group: "Flags").isEmpty)
    #expect(try sbd.outOfDate(session: s.id).isEmpty)
  }

  /// #122179 merged and deployed before the plan was attached. The poller
  /// learns the deploy from its comment after it learns the merge.
  @Test func rowAlreadyMergedAndDeployedAtAttachIsNotOutOfDate() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    try sbd.addGroup("Flags")
    let row = "| 1 | Dedup | Done ([posthog#122179](\(url(posthog, 122179)))) |"
    try sbd.writePlan(sbd.planFile, "| # | Item | Status |\n| --- | --- | --- |\n\(row)\n")
    _ = try sbd.attachPlan(sbd.planFile, group: "Flags")

    try sbd.poll(all: true)
    try sbd.poll(all: true)
    try sbd.poll(all: true)

    #expect(try sbd.outOfDate(group: "Flags").isEmpty)
  }

  // MARK: writes

  @Test func updateWritesTheTableIntoTheFile() throws {
    let github = try FakeGitHub()
    let (sbd, _) = try flagsWithBreakerRow(github)
    let id = try sbd.planIds()[0]

    try sbd.sb("plan", "update", id)

    let text = try String(contentsOfFile: sbd.planFile, encoding: .utf8)
    #expect(outside(text) == outside(document))
    let block = try #require(between(text))
    #expect(block.contains(header))
    #expect(block.contains(url(posthog, 122953)))
  }

  @Test func updateThatChangesNothingLeavesTheFileAlone() throws {
    let github = try FakeGitHub()
    let (sbd, _) = try flagsWithBreakerRow(github)
    let id = try sbd.planIds()[0]
    try sbd.sb("plan", "update", id)
    let written = try String(contentsOfFile: sbd.planFile, encoding: .utf8)
    let modified = try FileManager.default.attributesOfItem(atPath: sbd.planFile)[.modificationDate] as? Date

    try sbd.sb("plan", "update", id)

    #expect(try String(contentsOfFile: sbd.planFile, encoding: .utf8) == written)
    #expect(try FileManager.default.attributesOfItem(atPath: sbd.planFile)[.modificationDate] as? Date == modified)
  }

  @Test func updateWritesTheTableIntoTheIssue() throws {
    let github = try FakeGitHub()
    github.serveIssue(rfcs, issueNumber, body: crlfDocument)
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: posthog, branch: breakerBranch)
    try sbd.addGroup("Flags")
    let id = try sbd.attachPlan("\(rfcs)#\(issueNumber)", group: "Flags")
    try sbd.poll(all: true)
    try sbd.poll(all: true)
    try sbd.waitFor(s.id, "the session to join Flags") { $0.group != nil }

    try sbd.sb("plan", "update", id)

    #expect(requests(github, "PATCH", to: issuePath).count == 1)
    let body = try #require(github.issueBody(rfcs, issueNumber))
    #expect(outside(body) == outside(crlfDocument))
    let block = try #require(between(body))
    #expect(block.contains(header))
    #expect(block.contains(url(posthog, 122953)))
  }

  @Test func updateThatChangesNothingSendsNoPatch() throws {
    let github = try FakeGitHub()
    github.serveIssue(rfcs, issueNumber, body: crlfDocument)
    let sbd = try Instance.withGitHub(github)
    try sbd.addGroup("Flags")
    let id = try sbd.attachPlan("\(rfcs)#\(issueNumber)", group: "Flags")
    try sbd.poll(all: true)
    try sbd.sb("plan", "update", id)
    #expect(requests(github, "PATCH", to: issuePath).count == 1)

    try sbd.poll(all: true)
    try sbd.sb("plan", "update", id)

    #expect(requests(github, "PATCH", to: issuePath).count == 1)
  }

  @Test func updateWritesTheTableIntoThePRFile() throws {
    let github = try FakeGitHub()
    servePull(github)
    github.serveFile(rfcs, rfcPath, branch: rfcBranch, content: document)
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: posthog, branch: breakerBranch)
    try sbd.addGroup("Flags")
    let id = try sbd.attachPlan("\(rfcs)#\(rfcPR)", group: "Flags", path: rfcPath)
    try sbd.poll(all: true)
    try sbd.poll(all: true)
    try sbd.waitFor(s.id, "the session to join Flags") { $0.group != nil }

    try sbd.sb("plan", "update", id)

    let puts = requests(github, "PUT", to: contentsPath)
    #expect(puts.count == 1)
    #expect(JSON.parse(puts.first?.body ?? "")?["branch"]?.string == rfcBranch)
    let content = try #require(github.fileContent(rfcs, rfcPath))
    #expect(outside(content) == outside(document))
    let block = try #require(between(content))
    #expect(block.contains(header))
    #expect(block.contains(url(posthog, 122953)))
  }

  @Test func updateThatChangesNothingSendsNoPut() throws {
    let github = try FakeGitHub()
    servePull(github)
    github.serveFile(rfcs, rfcPath, branch: rfcBranch, content: document)
    let sbd = try Instance.withGitHub(github)
    try sbd.addGroup("Flags")
    let id = try sbd.attachPlan("\(rfcs)#\(rfcPR)", group: "Flags", path: rfcPath)
    try sbd.poll(all: true)
    try sbd.sb("plan", "update", id)
    #expect(requests(github, "PUT", to: contentsPath).count == 1)

    try sbd.poll(all: true)
    try sbd.sb("plan", "update", id)

    #expect(requests(github, "PUT", to: contentsPath).count == 1)
  }

  @Test func updateOfAFileInAClosedPRIsRefused() throws {
    let github = try FakeGitHub()
    servePull(github)
    github.serveFile(rfcs, rfcPath, branch: rfcBranch, content: document)
    let sbd = try Instance.withGitHub(github)
    try sbd.addGroup("Flags")
    let id = try sbd.attachPlan("\(rfcs)#\(rfcPR)", group: "Flags", path: rfcPath)
    try sbd.poll(all: true)

    servePull(github, state: "closed")
    github.change(rfcPR) { $0["state"] = "CLOSED" }
    try sbd.poll(all: true)
    let r = try sbd.run(["plan", "update", id])

    #expect(r.status != 0)
    #expect(requests(github, "PUT", to: contentsPath).isEmpty)
    #expect(github.fileContent(rfcs, rfcPath) == document)
  }

  /// Someone edits the issue between sbd's first GET and its conditional
  /// GET. sbd splices the new body, so the edit survives.
  @Test func issueEditedDuringAnUpdateKeepsTheEdit() throws {
    let github = try FakeGitHub()
    github.serveIssue(rfcs, issueNumber, body: document)
    let sbd = try Instance.withGitHub(github)
    try sbd.addGroup("Flags")
    let id = try sbd.attachPlan("\(rfcs)#\(issueNumber)", group: "Flags")
    try sbd.poll(all: true)
    let editedRow = "| 2 | Docs | Drafted by Alex |"
    let edited = document.replacingOccurrences(of: docsRow, with: editedRow)
    github.afterNextGET(issuePath) { [weak github] in github?.editIssue(rfcs, issueNumber, body: edited) }

    try sbd.sb("plan", "update", id)

    let body = try #require(github.issueBody(rfcs, issueNumber))
    #expect(body.contains(editedRow))
    #expect(try #require(between(body)).contains(header))
    #expect(requests(github, "PATCH", to: issuePath).count == 1)
  }

  /// Another commit changes the file between sbd's GET and its PUT. GitHub
  /// answers the stale blob SHA with a 409, and sbd rereads and retries.
  @Test func prFileEditedDuringAnUpdateRetriesWithTheNewSHA() throws {
    let github = try FakeGitHub()
    servePull(github)
    github.serveFile(rfcs, rfcPath, branch: rfcBranch, content: document)
    let sbd = try Instance.withGitHub(github)
    try sbd.addGroup("Flags")
    let id = try sbd.attachPlan("\(rfcs)#\(rfcPR)", group: "Flags", path: rfcPath)
    try sbd.poll(all: true)
    let editedRow = "| 2 | Docs | Drafted by Alex |"
    let edited = document.replacingOccurrences(of: docsRow, with: editedRow)
    github.afterNextGET(contentsPath) { [weak github] in github?.editFile(rfcs, rfcPath, content: edited) }

    try sbd.sb("plan", "update", id)

    #expect(requests(github, "PUT", to: contentsPath).count == 2)
    let content = try #require(github.fileContent(rfcs, rfcPath))
    #expect(content.contains(editedRow))
    #expect(try #require(between(content)).contains(header))
  }

  // MARK: auto update

  @Test func pollsWithoutAutoUpdateWriteNoPlan() throws {
    let github = try FakeGitHub()
    github.serveIssue(rfcs, issueNumber, body: document)
    servePull(github)
    github.serveFile(rfcs, rfcPath, branch: rfcBranch, content: document)
    let sbd = try Instance.withGitHub(github)
    try sbd.addGroup("Flags")
    try sbd.writePlan(sbd.planFile, document)
    _ = try sbd.attachPlan(sbd.planFile, group: "Flags")
    _ = try sbd.attachPlan("\(rfcs)#\(issueNumber)", group: "Flags")
    _ = try sbd.attachPlan("\(rfcs)#\(rfcPR)", group: "Flags", path: rfcPath)

    try sbd.poll(all: true)
    try sbd.poll(all: true)
    sleep(1)

    #expect(try String(contentsOfFile: sbd.planFile, encoding: .utf8) == document)
    #expect(requests(github, "PATCH", to: issuePath).isEmpty)
    #expect(requests(github, "PUT", to: contentsPath).isEmpty)
  }

  @Test func autoUpdateWritesOnceAndNotAgainWhileNothingChanges() throws {
    let github = try FakeGitHub()
    github.serveIssue(rfcs, issueNumber, body: crlfDocument)
    let sbd = try Instance.withGitHub(github)
    try sbd.addGroup("Flags")
    let id = try sbd.attachPlan("\(rfcs)#\(issueNumber)", group: "Flags")
    try sbd.poll(all: true)

    try sbd.sb("plan", "auto", id, "on")
    try sbd.poll(all: true)
    try sbd.waitFor("the first write") { !requests(github, "PATCH", to: issuePath).isEmpty }
    try sbd.poll(all: true)
    try sbd.poll(all: true)
    sleep(1)

    #expect(requests(github, "PATCH", to: issuePath).count == 1)
    #expect(try sbd.plan(id).autoUpdate)
  }

  @Test func autoUpdateWritesAgainWhenTheTableChanges() throws {
    let github = try FakeGitHub()
    github.serveIssue(rfcs, issueNumber, body: document)
    let sbd = try Instance.withGitHub(github)
    try sbd.addGroup("Flags")
    let id = try sbd.attachPlan("\(rfcs)#\(issueNumber)", group: "Flags")
    try sbd.sb("plan", "auto", id, "on")
    try sbd.poll(all: true)
    try sbd.waitFor("the first write") { !requests(github, "PATCH", to: issuePath).isEmpty }

    let s = try sbd.new(name: "alpha")
    try sbd.sb("group", "move", s.id, "--to", "Flags")
    try sbd.poll(all: true)

    try sbd.waitFor("the second write") { requests(github, "PATCH", to: issuePath).count >= 2 }
    let body = try #require(github.issueBody(rfcs, issueNumber))
    #expect(try #require(between(body)).contains("alpha"))
  }

  @Test func autoUpdateOffStopsTheWrites() throws {
    let github = try FakeGitHub()
    github.serveIssue(rfcs, issueNumber, body: document)
    let sbd = try Instance.withGitHub(github)
    try sbd.addGroup("Flags")
    let id = try sbd.attachPlan("\(rfcs)#\(issueNumber)", group: "Flags")
    try sbd.sb("plan", "auto", id, "on")
    try sbd.sb("plan", "auto", id, "off")

    try sbd.poll(all: true)
    try sbd.poll(all: true)
    sleep(1)

    #expect(requests(github, "PATCH", to: issuePath).isEmpty)
    #expect(try !sbd.plan(id).autoUpdate)
  }

  // MARK: list and removal

  @Test func lsFiltersByGroupAndSession() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    try sbd.addGroup("Flags")
    let s = try sbd.new(name: "owner")
    try sbd.writePlan(sbd.planFile, document)
    let onGroup = try sbd.attachPlan(sbd.planFile, group: "Flags")
    let onSession = try sbd.attachPlan(sbd.planFile, session: s.id)

    #expect(try Set(sbd.planIds()) == [onGroup, onSession])
    #expect(try sbd.planIds("--group", "Flags") == [onGroup])
    #expect(try sbd.planIds("--session", s.id) == [onSession])
  }

  @Test func detachRemovesThePlan() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    try sbd.addGroup("Flags")
    try sbd.writePlan(sbd.planFile, document)
    let id = try sbd.attachPlan(sbd.planFile, group: "Flags")

    try sbd.sb("plan", "detach", id)

    #expect(try sbd.planIds().isEmpty)
    #expect(try sbd.run(["plan", "get", id]).status != 0)
  }

  @Test func removingTheGroupDetachesItsPlans() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    try sbd.addGroup("Flags")
    try sbd.writePlan(sbd.planFile, document)
    _ = try sbd.attachPlan(sbd.planFile, group: "Flags")

    try sbd.sb("group", "rm", "Flags")

    #expect(try sbd.planIds().isEmpty)
  }

  @Test func removingTheSessionDetachesItsPlans() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.new(name: "owner")
    try sbd.writePlan(sbd.planFile, document)
    _ = try sbd.attachPlan(sbd.planFile, session: s.id)

    try sbd.sb("rm", s.id)

    #expect(try sbd.planIds().isEmpty)
  }
}
