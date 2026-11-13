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
  /// A bucket's raw value, or `repo:<owner/name>`.
  var id: String
  var title: String
  var issues: [ListedIssue]

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
  /// repository and then Being worked on. Each section's issues follow `issueSort`.
  var issueSections: [IssueSection] {
    let shown = issues.filter { issueScope.buckets.contains($0.bucket) }
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
    return sections.filter { !$0.issues.isEmpty }
  }

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

  /// Asks sbd to poll the sources when its last poll is over a minute old, as the Issues view opens.
  func refreshIssues() { readIssues("issues-refresh", ["maxAgeSeconds": 60]) }

  /// Polls the sources at once, as after a new source.
  func pollIssueSources() { readIssues("issues-refresh", ["maxAgeSeconds": 0]) }

  /// Reads the issue list off the main thread with `op`, which answers one.
  private func readIssues(_ op: String, _ args: [String: JSON] = [:]) {
    let client = client
    issueWork.async {
      let list = try? client.call(op, args, as: IssueList.self, timeout: 120)
      Task { @MainActor in self.apply(issueList: list) }
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
    IssueStart.preset(issueList, last: UserDefaults.standard.string(forKey: Self.lastIssuePresetKey) ?? "")
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

  /// Queues the issue as a follow-up that hasn't started.
  func followUpIssue(_ row: ListedIssue) {
    let issue = row.issue
    perform(
      "followup-add",
      [
        "prompt": .string("\(issue.title)\n\n\(issue.url)"), "title": .string(issue.title),
        "repository": .string(issue.repo),
      ])
  }

  /// Opens the New Session sheet filled in with the issue's checkout, branch, and the preset's prompt.
  func editIssuePrompt(_ row: ListedIssue, preset: IssuePreset) {
    newSession = NewSessionRequest(
      group: issueGroup(row), repo: row.issue.repo, branch: row.issue.branch(prefix: issueList?.branchPrefix ?? ""),
      prompt: preset.prompt(for: row.issue), issue: IssueRef(repo: row.issue.repo, number: row.issue.number))
  }
}

extension BoardModel {
  /// Adds a source, then polls it. `done` gets sbd's refusal, or nil.
  func addIssueSource(_ name: String, label: String, person: String, done: @escaping (String?) -> Void) {
    perform(
      "issues-source-add",
      ["source": .string(name), "label": .string(label), "person": .string(person)],
      then: { _ in
        done(nil)
        self.pollIssueSources()
      },
      failed: { done("\($0)") })
  }

  func removeIssueSource(_ source: IssueSource) {
    var args: [String: JSON] = ["source": .string(source.name)]
    if let label = source.label { args["label"] = .string(label) }
    if let person = source.person { args["person"] = .string(person) }
    perform("issues-source-rm", args)
  }

  /// Saves the team's labels and logins and the default preset.
  func saveIssueSettings(labels: [String], people: [String], defaultPreset: String?) {
    var args: [String: JSON] = ["labels": .array(labels.map(JSON.string)), "people": .array(people.map(JSON.string))]
    if let defaultPreset { args["defaultPreset"] = .string(defaultPreset) }
    perform("issues-settings", args) { self.apply(issueReply: $0) }
  }

  /// The orgs and repositories of the sessions, which the setup sheet suggests as sources.
  var suggestedIssueSources: [String] {
    let repos = Set(allSessions.compactMap(\.repository))
    let orgs = Set(repos.map { GitHub.ownerAndName($0).owner })
    let taken = Set((issueList?.sources ?? []).map { $0.name.lowercased() })
    return (orgs.sorted() + repos.sorted()).filter { !taken.contains($0.lowercased()) }
  }
}
