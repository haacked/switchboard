import Foundation
import SwitchboardCore
import Testing

@testable import SwitchboardApp

private func known(_ name: String, at path: String? = nil) -> KnownRepo {
  KnownRepo(path: path ?? "/dev/\(name)", name: name)
}

private func sourceList(_ sources: [IssueSource]) -> IssueList {
  IssueList(
    viewer: "robin-k", issues: [], sources: sources, team: IssueTeam(), presets: IssuePreset.defaults,
    branchPrefix: "robin/")
}

/// Names that `Issues.validRepo` refuses: a bare folder name, and malformed `owner/name` forms.
private let invalidRepoNames = [
  "dotfiles", "acme/ledger/web", "acme/", "/ledger", "acme/led ger", "./ledger", "acme/..", "äcme/ledger", "",
]

/// A field of the My Team group in the issue setup pane.
enum TeamField: String, CaseIterable, Sendable {
  case labels, people, backlog
}

private let batchNames = ["acme/flagship", "acme/ledger", "robin-k/dotkit"]

/// Long enough for a poll that a batch add queues after `done` to reach `send`.
private func grace() async { try? await Task.sleep(nanoseconds: 300_000_000) }

@MainActor
@Suite struct BoardModelIssueSetupTests {
  private func model(
    known repos: [KnownRepo]?, sources: [IssueSource]? = [], sessions: [SessionSummary] = []
  ) -> BoardModel {
    let model = appliedModel(sessions)
    model.knownRepos = repos
    model.issueList = sources.map(sourceList)
    return model
  }

  // MARK: - Offered known repos

  @Test func offersEachValidKnownRepo() {
    let model = model(known: [known("robin-k/dotkit"), known("acme/ledger")])

    #expect(model.offeredIssueRepos == ["robin-k/dotkit", "acme/ledger"])
  }

  @Test(arguments: invalidRepoNames)
  func doesNotOfferAKnownRepoThatIsNotOwnerAndName(name: String) {
    let model = model(known: [known(name, at: "/dev/bad"), known("acme/ledger")])

    #expect(model.offeredIssueRepos == ["acme/ledger"])
  }

  @Test(arguments: [
    IssueSource(name: "acme/ledger"),
    IssueSource(name: "ACME/Ledger"),
    IssueSource(name: "acme/ledger", label: "bug"),
    IssueSource(name: "acme/ledger", person: "robin-k"),
  ])
  func doesNotOfferARepoThatIsAlreadyASource(source: IssueSource) {
    let model = model(known: [known("Acme/ledger"), known("robin-k/dotkit")], sources: [source])

    #expect(model.offeredIssueRepos == ["robin-k/dotkit"])
  }

  @Test func anOrgSourceDoesNotHideItsRepos() {
    let model = model(known: [known("acme/ledger")], sources: [IssueSource(name: "acme", label: "team/billing")])

    #expect(model.offeredIssueRepos == ["acme/ledger"])
  }

  @Test(arguments: ["acme/ledger", "ACME/Ledger"])
  func twoCheckoutsOfOneRepoAreOfferedOnce(second: String) {
    let model = model(known: [known("acme/ledger", at: "/dev/ledger"), known(second, at: "/work/ledger")])

    #expect(model.offeredIssueRepos == ["acme/ledger"])
  }

  @Test func noKnownReposOffersNothing() {
    #expect(model(known: nil).offeredIssueRepos.isEmpty)
  }

  @Test func offersKnownReposBeforeTheIssueListLoads() {
    let model = model(known: [known("acme/ledger")], sources: nil)

    #expect(model.offeredIssueRepos == ["acme/ledger"])
  }

  // MARK: - Suggested sources

  @Test func suggestsAKnownRepoAndItsOrgWithoutSessions() {
    let model = model(known: [known("acme/ledger")])

    #expect(model.suggestedIssueSources == ["acme", "acme/ledger"])
  }

  @Test func suggestsTheOrgsThenTheReposOfSessionsAndKnownRepos() {
    let model = model(known: [known("acme/ledger")], sessions: [orgSession("s1", "robin-k/dotkit")])

    #expect(model.suggestedIssueSources == ["acme", "robin-k", "acme/ledger", "robin-k/dotkit"])
  }

  @Test func aRepoInBothASessionAndKnownReposIsSuggestedOnceWithItsOrgOnce() {
    let model = model(known: [known("acme/ledger")], sessions: [orgSession("s1", "Acme/Ledger")])

    #expect(model.suggestedIssueSources.map { $0.lowercased() } == ["acme", "acme/ledger"])
  }

  @Test(arguments: invalidRepoNames)
  func aKnownRepoThatIsNotOwnerAndNameSuggestsNeitherARepoNorAnOrg(name: String) {
    let model = model(known: [known(name)])

    #expect(model.suggestedIssueSources.isEmpty)
  }

  @Test func doesNotSuggestExistingSourcesWhateverTheirCase() {
    let model = model(
      known: [known("acme/ledger")],
      sources: [IssueSource(name: "ACME", label: "bug"), IssueSource(name: "Acme/Ledger")],
      sessions: [orgSession("s1", "acme/ledger")])

    #expect(model.suggestedIssueSources.isEmpty)
  }

  // MARK: - Adding sources

  @Test func addsEverySourceWithTheSharedFiltersInOneRequest() async {
    let sent = await firstRequest { model in
      model.addIssueSources(batchNames, label: "team/billing", person: "ana-m") { _ in }
    }

    #expect(sent.op == "issues-source-add")
    #expect(
      sent.args["sources"]
        == .array(batchNames.map { ["source": .string($0), "label": "team/billing", "person": "ana-m"] }))
  }

  @Test func pollsOnceAfterTheSourcesAreAdded() async {
    let (model, sent) = recordingModel()
    var refusal: String?? = nil
    model.addIssueSources(batchNames, label: "", person: "") { refusal = .some($0) }
    await sent.wait(for: "issues-refresh")
    await grace()

    #expect(refusal == .some(nil))
    #expect(sent.ops == ["issues-source-add", "issues-refresh"])
    #expect(sent.value.last?.args == ["maxAgeSeconds": 0])
  }

  @Test func aRefusalReachesDoneAndStartsNoPoll() async {
    let (model, sent) = recordingModel { op, _ in op == "issues-source-add" ? "acme/ledger is already a source" : nil }
    var refusal: String?? = nil
    model.addIssueSources(batchNames, label: "", person: "") { refusal = .some($0) }
    await settle { refusal != nil }
    await grace()

    #expect(refusal == .some("acme/ledger is already a source"))
    #expect(sent.ops == ["issues-source-add"])
  }

  // MARK: - Team settings

  /// An empty list goes as `[]`, which clears the labels. sbd keeps the old labels when the key is missing.
  @Test(arguments: [["backlog", "icebox"], []] as [[String]])
  func saveSendsTheBacklogLabels(_ backlog: [String]) async {
    let sent = await firstRequest { model in
      model.saveIssueSettings(
        labels: ["team/billing"], people: ["ana-m"], backlog: backlog, defaultPreset: nil
      ) { _ in }
    }

    #expect(sent.op == "issues-settings")
    #expect(sent.args["backlog"] == .array(backlog.map(JSON.string)))
    #expect(sent.args["labels"] == .array(["team/billing"]))
  }

  /// Settings ▸ Issues is its own window, so a refusal reaches the pane and not the main window's banner.
  @Test(arguments: ["issues-settings", "issues-source-rm"])
  func aRefusedSaveOrRemoveReachesDoneAndNotTheBanner(_ op: String) async {
    let (model, _) = recordingModel { sent, _ in sent == op ? "config.json is not a JSON object" : nil }
    var refusal: String?? = nil
    if op == "issues-settings" {
      model.saveIssueSettings(labels: [], people: [], backlog: [], defaultPreset: nil) { refusal = .some($0) }
    } else {
      model.removeIssueSource(IssueSource(name: "acme/ledger")) { refusal = .some($0) }
    }
    await settle { refusal != nil }

    #expect(refusal == .some("config.json is not a JSON object"))
    #expect(model.actionError == nil)
  }

  /// A label set from `sb issues team` or config.json can hold a comma. A field that still shows the loaded text
  /// gives the loaded list back, so Save leaves that label whole.
  @Test(arguments: [["backlog,icebox"], ["team/billing, west", "ops"], ["ana-m"], []] as [[String]])
  func anUnchangedFieldKeepsTheLoadedList(_ loaded: [String]) {
    #expect(IssueSetupView.list(IssueSetupView.text(loaded), loaded: loaded) == loaded)
  }

  @Test func anEditedFieldSplitsOnCommas() {
    #expect(IssueSetupView.list("backlog, icebox ,, ", loaded: ["backlog,icebox"]) == ["backlog", "icebox"])
  }

  @Test func beforeTheListLoadsAFieldSplitsOnCommas() {
    #expect(IssueSetupView.list("backlog,icebox", loaded: nil) == ["backlog", "icebox"])
  }

  // MARK: - Save enabled

  private nonisolated static let loadedTeam = IssueTeam(
    labels: ["team/billing", "ops"], people: ["ana-m"], backlog: ["icebox"])

  /// Whether the pane has changes. Each field shows the text of the loaded list unless the test gives other text.
  private func hasChanges(
    labels: String? = nil, people: String? = nil, backlog: String? = nil, preset: String? = "Fix",
    team: IssueTeam = loadedTeam, loadedPreset: String? = "Fix"
  ) -> Bool {
    IssueSetupView.hasChanges(
      labels: labels ?? IssueSetupView.text(team.labels), people: people ?? IssueSetupView.text(team.people),
      backlog: backlog ?? IssueSetupView.text(team.backlog), preset: preset,
      loaded: IssueSetupView.Loaded(team: team, preset: loadedPreset))
  }

  private func hasChanges(editing field: TeamField, to text: String) -> Bool {
    switch field {
    case .labels: hasChanges(labels: text)
    case .people: hasChanges(people: text)
    case .backlog: hasChanges(backlog: text)
    }
  }

  @Test func saveIsDisabledUntilAFieldChanges() {
    #expect(!hasChanges())
  }

  @Test(arguments: zip(TeamField.allCases, ["team/billing", "ana-m, robin-k", "icebox, later"]))
  func anEditedFieldCountsAsAChange(field: TeamField, text: String) {
    #expect(hasChanges(editing: field, to: text))
  }

  @Test(arguments: TeamField.allCases)
  func aClearedFieldCountsAsAChange(field: TeamField) {
    #expect(hasChanges(editing: field, to: ""))
  }

  /// A label set from `sb issues team` or config.json can hold a comma. Its field shows the loaded text, which
  /// splits into other entries, but the pane has no change.
  @Test func aListWithACommaInsideAnEntryShownUnchangedIsNoChange() {
    let team = IssueTeam(labels: ["team/billing, west", "ops"], people: ["ana-m"], backlog: ["backlog,icebox"])

    #expect(!hasChanges(team: team))
  }

  @Test func emptyLoadedListsShownEmptyAreNoChange() {
    #expect(!hasChanges(preset: nil, team: IssueTeam(), loadedPreset: nil))
  }

  /// Before the first read, typed text is a change, so a later read doesn't replace it.
  @Test(arguments: TeamField.allCases)
  func beforeTheFirstReadTypedTextIsAChange(field: TeamField) {
    let typed = IssueSetupView.hasChanges(
      labels: field == .labels ? "team/billing" : "", people: field == .people ? "ana-m" : "",
      backlog: field == .backlog ? "icebox" : "", preset: nil, loaded: nil)

    #expect(typed)
  }

  @Test func beforeTheFirstReadEmptyFieldsAreNoChange() {
    #expect(!IssueSetupView.hasChanges(labels: "", people: "", backlog: "", preset: nil, loaded: nil))
  }

  @Test(arguments: zip(["Plan", nil, "Fix"] as [String?], ["Fix", "Fix", nil] as [String?]))
  func aChangedPresetCountsAsAChange(preset: String?, loaded: String?) {
    #expect(hasChanges(preset: preset, loadedPreset: loaded))
  }
}
