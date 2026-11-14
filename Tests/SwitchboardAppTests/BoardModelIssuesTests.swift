import Foundation
import SwitchboardCore
import Testing

@testable import SwitchboardApp

private func row(
  _ repo: String, _ number: Int, _ bucket: IssueBucket, updated: String = "2026-11-10T10:00:00Z",
  labels: [String] = [], session: String? = nil
) -> ListedIssue {
  ListedIssue(
    issue: InboxIssue(
      repo: repo, number: number, title: "Issue \(number)", url: "https://github.com/\(repo)/issues/\(number)",
      labels: labels, createdAt: "2026-11-01T10:00:00Z", updatedAt: updated),
    bucket: bucket, session: session)
}

private func list(_ rows: [ListedIssue], presets: [IssuePreset] = IssuePreset.defaults) -> IssueList {
  IssueList(
    viewer: "robin-k", issues: rows, sources: [IssueSource(name: "acme/ledger")], team: IssueTeam(),
    presets: presets, branchPrefix: "robin/")
}

private let rows = [
  row("acme/ledger", 1, .mine, updated: "2026-11-09T10:00:00Z"),
  row("acme/ledger", 2, .mine, updated: "2026-11-11T10:00:00Z"),
  row("acme/ledger-web", 3, .teamUnassigned),
  row("acme/ledger", 4, .teamAssigned),
  row("robin-k/dotkit", 5, .other),
  row("acme/ledger", 6, .workedOn, session: "s1"),
  row("robin-k/dotkit", 7, .teamUnassigned, updated: "2026-11-08T10:00:00Z"),
]

@MainActor
@Suite struct BoardModelIssuesTests {
  private func model(_ filter: OrgFilter = OrgFilter()) -> BoardModel {
    let model = orgFilterModel(filter)
    model.issueList = list(rows)
    return model
  }

  @Test func countIsMinePlusTeamUnassigned() {
    #expect(model().issueCount == 4)
  }

  @Test func orgFilterHidesIssuesAndTheirCount() {
    let model = model(OrgFilter(keys: ["acme"]))
    #expect(model.issueCount == 3)
    #expect(!model.issues.contains { $0.issue.repo == "robin-k/dotkit" })
  }

  @Test func teamScopeListsBucketsInOrderWithoutOther() {
    let sections = model().issueSections
    #expect(sections.map(\.id) == ["mine", "teamUnassigned", "teamAssigned", "workedOn"])
    #expect(sections[0].issues.map(\.issue.number) == [2, 1])
  }

  @Test func mineScopeListsOnlyMine() {
    let model = model()
    model.issueScope = .mine
    #expect(model.issueSections.map(\.id) == ["mine"])
  }

  @Test func allScopeAddsOther() {
    let model = model()
    model.issueScope = .all
    #expect(model.issueSections.map(\.id).contains("other"))
  }

  @Test func groupByRepoMakesARepoSectionEachAndKeepsBeingWorkedOnLast() {
    let model = model()
    model.issuesByRepo = true
    #expect(
      model.issueSections.map(\.id) == ["repo:acme/ledger", "repo:acme/ledger-web", "repo:robin-k/dotkit", "workedOn"])
  }

  @Test func collapsedSectionsLeaveTheMoveOrder() {
    let model = model()
    let numbers = { model.issueOrder.compactMap { id in rows.first { $0.id == id }?.issue.number } }
    #expect(numbers() == [2, 1, 3, 7])
    model.toggleIssueSection("teamAssigned")
    #expect(numbers() == [2, 1, 3, 7, 4])
  }

  @Test func jAndKMoveAroundTheEnds() {
    let model = model()
    #expect(model.currentIssue?.issue.number == 2)
    model.moveIssue(by: -1)
    #expect(model.currentIssue?.issue.number == 7)
    model.moveIssue(by: 1, wrap: false)
    #expect(model.currentIssue?.issue.number == 7)
  }

  @Test func issuesIsTheThirdMainViewForNextSession() {
    let model = model()
    model.show(.issues)
    model.selectAdjacentSession(by: 1)
    #expect(model.currentIssue?.issue.number == 1)
  }

  @Test func startSendsTheIssueThePresetAndThePickedGroup() async {
    let sent = await firstRequest { model in
      model.issueGroupPicks[rows[0].id] = "g1"
      model.startIssue(rows[0], preset: IssuePreset(name: "go", prompt: ""))
    }
    #expect(sent.op == "issues-start")
    #expect(sent.args == ["issue": "acme/ledger#1", "preset": "go", "group": "g1"])
  }

  @Test func startWithAChosenFolderSendsItsPath() async {
    let sent = await firstRequest { model in
      model.startIssue(rows[0], preset: IssuePreset(name: "plain", prompt: ""), path: "/tmp/ledger")
    }
    #expect(sent.args == ["issue": "acme/ledger#1", "preset": "plain", "path": "/tmp/ledger"])
  }

  @Test func notMineSendsDismiss() async {
    let sent = await firstRequest { model in model.dismissIssue(rows[2]) }
    #expect(sent.op == "issues-dismiss")
    #expect(sent.args == ["issue": "acme/ledger-web#3"])
  }

  @Test func addingASourceSendsItsFilters() async {
    let sent = await firstRequest { model in
      model.addIssueSource("acme", label: "team/billing", person: "") { _ in }
    }
    #expect(sent.op == "issues-source-add")
    #expect(sent.args == ["source": "acme", "label": "team/billing", "person": ""])
  }

  @Test func editThePromptFirstFillsTheNewSessionSheet() {
    let model = model()
    model.issueGroupPicks[rows[0].id] = "g1"
    model.editIssuePrompt(rows[0], preset: IssuePreset(name: "go", prompt: "/go --yolo {url}"))
    let request = model.newSession
    #expect(request?.repo == "acme/ledger")
    #expect(request?.branch == "robin/1-issue-1")
    #expect(request?.prompt == "/go --yolo https://github.com/acme/ledger/issues/1")
    #expect(request?.issue == IssueRef(repo: "acme/ledger", number: 1))
    #expect(request?.group == "g1")
  }

  @Test(arguments: [("robin-k", nil), ("zed-q", false), (nil, false)] as [(String?, Bool?)])
  func editThePromptFirstStartsWithoutAutoModeForAnOutsideAuthor(author: String?, autoMode: Bool?) {
    let model = model()
    var issue = rows[0]
    issue.issue.author = author
    model.editIssuePrompt(issue, preset: IssuePreset(name: "go", prompt: "/go --yolo {url}"))

    #expect(model.newSession?.autoMode == autoMode)
  }

  @Test(arguments: [("robin-k", nil), ("zed-q", false), (nil, false)] as [(String?, Bool?)])
  func followUpFencesTheTitleOnTheIssuesBranchAndStartsWithoutAutoModeForAnOutsideAuthor(
    author: String?, autoMode: Bool?
  ) async {
    var issue = rows[0]
    issue.issue.author = author
    let sent = await firstRequest { model in
      model.issueList = list(rows)
      model.followUpIssue(issue)
    }

    #expect(sent.op == "followup-add")
    #expect(sent.args["prompt"]?.string?.contains("<issue-title>Issue 1</issue-title>") == true)
    #expect(sent.args["branch"] == "robin/1-issue-1")
    #expect(sent.args["autoMode"] == autoMode.map(JSON.bool))
  }

  @Test(arguments: [nil, false] as [Bool?])
  func theSheetSendsTheRequestsAutoMode(autoMode: Bool?) {
    let form = NewSessionView.Form(request: NewSessionRequest(repo: "acme/ledger", autoMode: autoMode))
    form.offer([KnownRepo(path: "/dev/acme/ledger", name: "acme/ledger")])

    #expect(form.request(worktree: false, groups: [])?.autoMode == autoMode)
  }

  @Test func aWorkedOnIssueDoesNotStart() async {
    let (model, release, requests) = heldModel()
    model.startIssue(rows[5], preset: IssuePreset(name: "go", prompt: ""))
    release.signal()
    #expect(requests.value == 0)
    #expect(model.startingIssues.isEmpty)
  }

  @Test func lastPresetWinsThenTheDefaultThenTheFirst() {
    let presets = [IssuePreset(name: "go", prompt: ""), IssuePreset(name: "plain", prompt: "")]
    #expect(IssuePreset.choose(presets, last: "plain", default: nil)?.name == "plain")
    #expect(IssuePreset.choose(presets, last: "gone", default: nil)?.name == "go")
    #expect(IssuePreset.choose(presets, last: "gone", default: "plain")?.name == "plain")
    #expect(IssuePreset.choose(presets, last: nil, default: "gone")?.name == "go")
  }
}

@MainActor
@Suite struct NewSessionFormIssueTests {
  @Test func requestNamesTheRepoBranchPromptAndIssue() {
    let form = NewSessionView.Form(
      request: NewSessionRequest(
        group: nil, repo: "Acme/Ledger", branch: "robin/1-issue-1", prompt: "/go --yolo x",
        issue: IssueRef(repo: "acme/ledger", number: 1)))
    form.offer([
      KnownRepo(path: "/dev/acme/flagship", name: "acme/flagship", used: 2),
      KnownRepo(path: "/dev/acme/ledger", name: "acme/ledger", used: 1),
    ])
    let request = form.request(worktree: true, groups: [])
    #expect(request?.path == "/dev/acme/ledger")
    #expect(request?.branch == "robin/1-issue-1")
    #expect(request?.prompt == "/go --yolo x")
    #expect(request?.issue == IssueRef(repo: "acme/ledger", number: 1))
  }

  @Test func requestForARepoWithNoCheckoutSelectsNoRepo() {
    let form = NewSessionView.Form(
      request: NewSessionRequest(group: nil, repo: "acme/ledger-web", branch: "robin/1-issue-1", prompt: "x"))
    form.offer([KnownRepo(path: "/dev/acme/flagship", name: "acme/flagship", used: 2)])

    #expect(form.repo == nil)
    #expect(form.request(worktree: true, groups: []) == nil)
  }
}
