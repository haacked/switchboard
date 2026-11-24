import AppKit
import SwitchboardCore

/// Which buckets the Issues list shows.
enum IssueScope: String, CaseIterable {
  /// Assigned to me.
  case mine
  /// Mine, the team's, and the ones being worked on.
  case team
  /// Every bucket.
  case all

  var title: String {
    switch self {
    case .mine: "Mine"
    case .team: "Team"
    case .all: "All"
    }
  }

  var buckets: [IssueBucket] {
    switch self {
    case .mine: [.mine]
    case .team: [.mine, .teamUnassigned, .teamAssigned, .workedOn]
    case .all: IssueBucket.allCases
    }
  }
}

/// One heading of the Issues list and its issues.
struct IssueSection: Identifiable, Equatable {
  /// A bucket's raw value, `repo:<owner/name>`, or `backlogID`.
  var id: String
  var title: String
  var issues: [ListedIssue]
  /// The number of backlog issues that Hide Backlog leaves out. It is nil for a section that lists its issues.
  var hiddenCount: Int?

  static let backlogID = "backlog"

  /// Team assigned to others, Other, and Being worked on start collapsed.
  static let collapsedAtFirst: Set<String> = [
    IssueBucket.teamAssigned.rawValue, IssueBucket.other.rawValue, IssueBucket.workedOn.rawValue,
  ]
}

/// A session that Start made, which the Issues view offers to open.
struct StartedIssue: Equatable {
  var session: String
  var name: String
}

extension BoardModel {
  /// The issues that the org filter shows.
  var issues: [ListedIssue] { (issueList?.issues ?? []).filter { orgFilter.shows(repo: $0.issue.repo) } }

  /// The picker's count: issues assigned to me plus the team's unassigned ones, as the org filter shows them.
  var issueCount: Int { issueList?.count(shows: orgFilter.shows(repo:)) ?? 0 }

  /// The Issues list's sections in order: a section per bucket of the scope, or with `issuesByRepo` a section per
  /// repository and then Being worked on. The scope's backlog issues follow in one Backlog section, which holds no
  /// issues while `hidesBacklog` is on. Each section's issues follow `issueSort`.
  var issueSections: [IssueSection] {
    let inScope = issues.filter { issueScope.buckets.contains($0.bucket) }
    let shown = inScope.filter { !$0.backlog }
    let backlog = inScope.filter(\.backlog)
    let sorted = { (rows: [ListedIssue]) in rows.sorted { self.issueSort.inOrder($0.issue, $1.issue) } }
    let section = { (bucket: IssueBucket) in
      IssueSection(id: bucket.rawValue, title: bucket.title, issues: sorted(shown.filter { $0.bucket == bucket }))
    }
    var sections: [IssueSection]
    if issuesByRepo {
      sections = Dictionary(grouping: shown.filter { $0.bucket != .workedOn }, by: \.issue.repo)
        .sorted { $0.key.lowercased() < $1.key.lowercased() }
        .map { IssueSection(id: "repo:\($0.key)", title: $0.key, issues: sorted($0.value)) }
      sections.append(section(.workedOn))
    } else {
      sections = issueScope.buckets.map(section)
    }
    sections.removeAll { $0.issues.isEmpty }
    if !backlog.isEmpty {
      sections.append(
        IssueSection(
          id: IssueSection.backlogID, title: "Backlog", issues: hidesBacklog ? [] : sorted(backlog),
          hiddenCount: hidesBacklog ? backlog.count : nil))
    }
    return sections
  }

  /// Whether the sort menu offers Hide Backlog, which needs a backlog label.
  var showsBacklogToggle: Bool { !(issueList?.team.backlog.isEmpty ?? true) }

  /// The ids of the rows that the Issues list shows, in order. A collapsed section's rows are left out.
  var issueOrder: [String] {
    issueSections.filter { !collapsedIssueSections.contains($0.id) }.flatMap { $0.issues.map(\.id) }
  }

  /// The focused issue while the list shows it, else the first row.
  var currentIssue: ListedIssue? {
    let order = issueOrder
    let id = issueFocus.flatMap { order.contains($0) ? $0 : nil } ?? order.first
    return issues.first { $0.id == id }
  }

  func moveIssue(by step: Int, wrap: Bool = true) {
    guard let next = ListStep.step(issueOrder, from: currentIssue?.id, by: step, wrap: wrap) else { return }
    issueFocus = next
    issueJumps += 1
  }

  func toggleIssueSection(_ id: String) {
    if collapsedIssueSections.remove(id) == nil { collapsedIssueSections.insert(id) }
  }

  /// Turns off Hide Backlog and expands the Backlog section, so its issues show after one click.
  func showBacklog() {
    hidesBacklog = false
    collapsedIssueSections.remove(IssueSection.backlogID)
  }

  /// Asks sbd to poll the sources when its last poll is over a minute old, as the Issues view opens.
  func refreshIssues() { refreshIssues(olderThan: 60) }

  /// Polls the sources at once, as after a new source.
  func pollIssueSources() { refreshIssues(olderThan: 0) }

  /// Reads the issue list off the main thread. sbd polls the sources first when its last poll is older than
  /// `seconds`.
  private func refreshIssues(olderThan seconds: Int) {
    let send = send
    issueWork.async {
      let reply = try? send("issues-refresh", ["maxAgeSeconds": .number(Double(seconds))])
      Task { @MainActor in if let reply { self.apply(issueReply: reply) } }
    }
  }

  /// Publishes a list that sbd answered, when it differs from the one shown.
  func apply(issueList list: IssueList?) {
    if let list, issueList != list { issueList = list }
  }

  private func apply(issueReply result: JSON) {
    apply(issueList: try? JSONCoding.convert(result, to: IssueList.self))
  }

  /// The UserDefaults key of the preset that Start last ran.
  static let lastIssuePresetKey = "issuePreset"

  /// The preset that Start runs: the last one the user ran while it still exists, else config.json's default, else
  /// the first.
  var issuePreset: IssuePreset? {
    IssuePreset.choose(
      issueList?.presets ?? [], last: UserDefaults.standard.string(forKey: Self.lastIssuePresetKey),
      default: issueList?.defaultPreset)
  }

  /// The group that Start uses for the issue: the user's pick, else the group that holds the most sessions in the
  /// issue's repository.
  func issueGroup(_ row: ListedIssue) -> String? {
    issueGroupPicks[row.id] ?? KnownRepos.preferredGroup(repository: row.issue.repo, sessions: allSessions)
  }

  /// Starts the issue with `preset`, or with `issuePreset`, in `issueGroup`, and remembers the preset for the next
  /// Start. The Start button and Return in the list both call it.
  func startIssue(_ row: ListedIssue, preset: IssuePreset? = nil, path: String? = nil) {
    guard row.bucket != .workedOn, let preset = preset ?? issuePreset, beginStart(row.id) else { return }
    UserDefaults.standard.set(preset.name, forKey: Self.lastIssuePresetKey)
    sendStart(row, preset: preset.name, path: path)
  }

  /// Clones the issue's repository into the first repo root, then starts the issue there.
  func cloneAndStart(_ row: ListedIssue) {
    guard let preset = issuePreset, beginStart(row.id) else { return }
    perform(
      "issues-clone", ["repo": .string(row.issue.repo)], on: issueWork,
      then: { result in self.sendStart(row, preset: preset.name, path: result["path"]?.string) },
      failed: {
        self.startingIssues.remove(row.id)
        self.issueErrors[row.id] = "\($0)"
      })
  }

  /// Marks the issue as starting and clears its last error, or returns false while a Start of it is on its way.
  private func beginStart(_ id: String) -> Bool {
    guard startingIssues.insert(id).inserted else { return false }
    issueErrors[id] = nil
    return true
  }

  /// On success the focus moves to the next issue and the view offers to open the session.
  private func sendStart(_ row: ListedIssue, preset: String, path: String?) {
    let id = row.id
    var args: [String: JSON] = ["issue": .string(row.issue.ref), "preset": .string(preset)]
    if let group = issueGroup(row) { args["group"] = .string(group) }
    if let path { args["path"] = .string(path) }
    let next = ListStep.step(issueOrder, from: id, by: 1, wrap: false)
    perform(
      "issues-start", args, on: issueWork,
      then: { result in
        guard let session = try? JSONCoding.convert(result, to: SessionSummary.self) else { return }
        self.startedIssue = StartedIssue(session: session.id, name: session.name)
        if self.issueFocus == id || self.issueFocus == nil, next != id { self.issueFocus = next }
      },
      failed: { self.issueErrors[id] = "\($0)" },
      finally: { self.startingIssues.remove(id) })
  }

  /// "Not mine": hides the issue until it changes on GitHub.
  func dismissIssue(_ row: ListedIssue) {
    perform("issues-dismiss", ["issue": .string(row.issue.ref)]) { self.apply(issueReply: $0) }
  }

  /// Queues the issue as a follow-up that hasn't started. Its branch carries the issue's number, so the issue moves to
  /// Being worked on once the follow-up starts.
  func followUpIssue(_ row: ListedIssue) {
    let issue = row.issue
    var args: [String: JSON] = [
      "prompt": .string(IssuePreset.followup.prompt(for: issue)),
      "title": .string(issue.title), "repository": .string(issue.repo),
      "branch": .string(issue.branch(prefix: issueList?.branchPrefix ?? "")),
    ]
    if !trustsIssue(row) { args["manualMode"] = .bool(true) }
    perform("followup-add", args)
  }

  /// Whether the viewer or a teammate wrote the issue. Any other issue's session starts in manual mode. sbd's Start
  /// uses the same rule.
  func trustsIssue(_ row: ListedIssue) -> Bool {
    IssueInbox(viewer: issueList?.viewer, team: issueList?.team ?? IssueTeam()).trusts(row.issue)
  }

  /// Opens the New Session sheet filled in with the issue's checkout, branch, and the preset's prompt.
  func editIssuePrompt(_ row: ListedIssue, preset: IssuePreset) {
    newSession = NewSessionRequest(
      group: issueGroup(row), repo: row.issue.repo, branch: row.issue.branch(prefix: issueList?.branchPrefix ?? ""),
      prompt: preset.prompt(for: row.issue), issue: row.issue.issueRef,
      manualMode: !trustsIssue(row))
  }
}

extension BoardModel {
  /// Adds a source named by each of `names`, all with the same filters, in one request, then polls them. sbd adds
  /// none of them when it refuses one. `done` gets sbd's refusal, or nil.
  func addIssueSources(_ names: [String], label: String, person: String, done: @escaping (String?) -> Void) {
    let sources = names.map {
      JSON.object(["source": .string($0), "label": .string(label), "person": .string(person)])
    }
    perform(
      "issues-source-add", ["sources": .array(sources)],
      then: { _ in
        done(nil)
        self.pollIssueSources()
      },
      failed: { done("\($0)") })
  }

  /// Removes the source. `done` gets sbd's refusal, or nil, so Settings ▸ Issues can show it.
  func removeIssueSource(_ source: IssueSource, done: @escaping (String?) -> Void) {
    var args: [String: JSON] = ["source": .string(source.name)]
    if let label = source.label { args["label"] = .string(label) }
    if let person = source.person { args["person"] = .string(person) }
    perform("issues-source-rm", args, then: { _ in done(nil) }, failed: { done("\($0)") })
  }

  /// Saves the team's labels and logins and the default preset. `done` gets sbd's refusal, or nil, so Settings ▸
  /// Issues can show it.
  func saveIssueSettings(
    labels: [String], people: [String], backlog: [String], defaultPreset: String?,
    done: @escaping (String?) -> Void
  ) {
    var args: [String: JSON] = [
      "labels": .array(labels.map(JSON.string)), "people": .array(people.map(JSON.string)),
      "backlog": .array(backlog.map(JSON.string)),
    ]
    if let defaultPreset { args["defaultPreset"] = .string(defaultPreset) }
    perform(
      "issues-settings", args,
      then: { reply in
        self.apply(issueReply: reply)
        done(nil)
      },
      failed: { done("\($0)") })
  }

  /// The known repositories with a GitHub `owner/name` that are not sources yet, in `knownRepos` order. The Issues
  /// view offers them as sources. Two checkouts of one repository give one entry.
  var offeredIssueRepos: [String] { newIssueSources(knownGitHubRepos) }

  /// The orgs and repositories of the sessions and the known repositories, which Settings ▸ Issues suggests as
  /// sources.
  var suggestedIssueSources: [String] {
    let repos = allSessions.compactMap(\.repository) + knownGitHubRepos
    return newIssueSources(repos.map { GitHub.ownerAndName($0).owner }.sorted()) + newIssueSources(repos.sorted())
  }

  private var knownGitHubRepos: [String] { (knownRepos ?? []).map(\.name).filter(Issues.validRepo) }

  /// `names` without the ones that are sources already and without later names that differ only in case.
  private func newIssueSources(_ names: [String]) -> [String] {
    var seen = Set((issueList?.sources ?? []).map { $0.name.lowercased() })
    return names.filter { seen.insert($0.lowercased()).inserted }
  }
}
