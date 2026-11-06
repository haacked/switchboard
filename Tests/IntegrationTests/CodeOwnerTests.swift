import Foundation
import SwitchboardCore
import Testing

// MARK: FakeGitHub's code owner API

/// The FakeGitHub calls that the tests below make for code owners. Each one
/// wraps the API that the plan names for Stage 2, so a change to that API
/// changes only this block.
extension FakeGitHub {
  /// The request kinds of the three code owner queries.
  fileprivate static let configKind = "codeowners"
  fileprivate static let filesKind = "files"
  fileprivate static let approvalsKind = "approvals"

  /// A `PULL_REQUEST` rule of a ruleset with this enforcement, as
  /// `ref.rules.nodes` returns it.
  fileprivate static func codeOwnerRule(_ enforcement: String = "ACTIVE", required: Bool = true) -> JSON {
    [
      "type": "PULL_REQUEST",
      "parameters": [
        "requireCodeOwnerReview": .bool(required), "dismissStaleReviewsOnPush": false,
        "requireLastPushApproval": false,
      ],
      "repositoryRuleset": ["enforcement": .string(enforcement)],
    ]
  }

  /// Sets the code owner config of PostHog/posthog's `master`, in place of
  /// an earlier one. `rules` are `ref.rules.nodes`. `protection` is
  /// `ref.branchProtectionRule`, null when nil. `files` holds the CODEOWNERS
  /// text by its path in the repo. `errors` are `codeowners.errors`, and
  /// `codeowners` is null when it is nil.
  fileprivate func ownerConfig(
    rules: [JSON] = [FakeGitHub.codeOwnerRule()], protection: JSON? = nil,
    files: [String: String] = [".github/CODEOWNERS": CodeOwnerTests.codeowners], errors: [JSON]? = []
  ) {
    codeOwners(
      repo: DepotTests.posthog, base: "master", rules: rules, protection: protection, files: files, errors: errors)
  }

  /// Sets the PR's changed files. GitHub's `files.totalCount` is `total`, or
  /// the number of paths when it is nil.
  fileprivate func changed(_ number: Int, _ paths: [String], total: Int? = nil) {
    changedFiles(number, paths, totalCount: total)
  }

  /// Makes each config query for PostHog/posthog fail.
  fileprivate func failConfig() { failCodeOwners(repo: DepotTests.posthog) }

  fileprivate func recoverConfig() { recoverCodeOwners(repo: DepotTests.posthog) }

  /// Makes the PR's node in each files query fail with an internal error.
  fileprivate func failFiles(_ number: Int) { fail(number, in: .files) }

  fileprivate func recoverFiles(_ number: Int) { recover(number, in: .files) }
}

// MARK: Helpers that use only the existing fake

extension FakeGitHub {
  /// A request to review that GitHub made for a team, as
  /// `reviewRequests.nodes` returns it.
  fileprivate static func teamRequest(_ combinedSlug: String, asCodeOwner: Bool = true) -> JSON {
    let slug = combinedSlug.split(separator: "/").last.map(String.init) ?? combinedSlug
    return [
      "asCodeOwner": .bool(asCodeOwner),
      "requestedReviewer": ["__typename": "Team", "slug": .string(slug), "combinedSlug": .string(combinedSlug)],
    ]
  }

  fileprivate static func userRequest(_ login: String, asCodeOwner: Bool = true) -> JSON {
    ["asCodeOwner": .bool(asCodeOwner), "requestedReviewer": ["__typename": "User", "login": .string(login)]]
  }

  /// Gives the PR an author and these review requests. `CodeOwnerStatus`
  /// shows nothing for a PR whose author or requests the poll did not read.
  fileprivate func ownedPR(_ number: Int, author: String = CodeOwnerTests.author, requests: [JSON]) {
    change(number) {
      $0["author"] = ["login": .string(author)]
      $0["reviewRequests"] = ["totalCount": .number(Double(requests.count)), "nodes": .array(requests)]
    }
  }

  /// Adds the reviewer's last verdict on `commit`, on behalf of `teams`, to
  /// the PR's verdicts and reviews.
  fileprivate func verdict(
    _ number: Int, by login: String, _ state: String = "APPROVED", on commit: String, for teams: [String] = [],
    at time: String = "2026-11-05T10:00:00Z"
  ) {
    let node: JSON = [
      "author": ["__typename": "User", "login": .string(login)], "state": .string(state),
      "submittedAt": .string(time), "commit": ["oid": .string(commit)],
      "onBehalfOf": ["nodes": .array(teams.map { ["combinedSlug": .string($0)] })],
    ]
    change(number) { pr in
      for key in ["latestOpinionatedReviews", "reviews"] {
        pr[key] = ["nodes": .array((pr[key]?["nodes"]?.array ?? []) + [node])]
      }
    }
  }

  /// The number of GraphQL requests of this kind after the first `mark`.
  fileprivate func count(_ kind: String, after mark: Int = 0) -> Int {
    requests.dropFirst(mark).filter { $0.kind == kind }.count
  }
}

extension Instance {
  /// The `pr.codeOwners` of `sb get --json`, or nil when it is absent.
  fileprivate func ownersShown(_ id: String) throws -> JSON? {
    let owners = JSON.parse(try sb("get", id, "--json"))?["pr"]?["codeOwners"]
    return owners == .null ? nil : owners
  }

  fileprivate func owners(_ id: String) throws -> CodeOwnerStatus? {
    try ownersShown(id).map { try JSONCoding.convert($0, to: CodeOwnerStatus.self) }
  }

  /// The `owners:` line of `sb get` without its label.
  fileprivate func ownersLine(_ id: String) throws -> String? {
    try sb("get", id).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
      .first { $0.hasPrefix("owners:") }
      .map { $0.dropFirst("owners:".count).trimmingCharacters(in: .whitespaces) }
  }
}

/// sbd reads whether a session's open PR needs a code owner review, through
/// `sb poll` against the fake GitHub, and `sb get` and `sb ls` show it.
@Suite(.blocking(timeLimit: .seconds(120))) struct CodeOwnerTests {
  static let number = DepotTests.number
  static let author = "haacked"
  static let hogql = "@PostHog/hogql"
  static let flags = "@PostHog/team-feature-flags"

  /// No line matches every path, so a path can have no owner.
  static let codeowners = """
    # Code owners of the fixture repo.
    /posthog/hogql/                  @PostHog/hogql
    /rust/feature-flags/             @PostHog/team-feature-flags
    /rust/feature-flags/README.md
    /frontend/                       @alice @PostHog/team-frontend # the inline comment ends the owners
    """

  static let hogqlPath = "posthog/hogql/printer.py"
  static let flagsPath = "rust/feature-flags/src/flag_matching.rs"
  /// The last line that matches it has no owners.
  static let ownerlessPath = "rust/feature-flags/README.md"
  /// No line matches it.
  static let unmatchedPath = "README.md"
  static let frontendPath = "frontend/src/scenes/App.tsx"

  /// #122953 with a code owner requirement for @PostHog/hogql: its base
  /// requires code owner review, its one changed file is owned by
  /// @PostHog/hogql, and it has an author. Each test that expects no field
  /// changes one of these inputs.
  func arrange(_ github: FakeGitHub, paths: [String] = [hogqlPath], requests: [JSON] = []) {
    github.ownerConfig()
    github.changed(Self.number, paths)
    github.ownedPR(Self.number, requests: requests)
  }

  func head(_ github: FakeGitHub) throws -> String {
    try #require(github.pr(Self.number)["headRefOid"]?.string)
  }

  func session(_ sbd: Instance) throws -> SessionSummary {
    try sbd.session(in: DepotTests.posthog, branch: DepotTests.branch)
  }

  /// Checks that `sb get --json` shows the PR and no `pr.codeOwners`.
  func expectNoField(_ sbd: Instance, _ s: SessionSummary, sourceLocation: SourceLocation = #_sourceLocation) throws {
    #expect(try sbd.get(s.id).pr?.number == Self.number, sourceLocation: sourceLocation)
    #expect(try sbd.ownersShown(s.id) == nil, sourceLocation: sourceLocation)
  }

  /// Polls again after the pending interval, so the poller reads #122953's
  /// status again. Its `mergeable` is UNKNOWN, which keeps it pending.
  @discardableResult
  func pollAgain(_ sbd: Instance) throws -> JSON {
    try sbd.advanceClock(30_000)
    return try sbd.poll()
  }

  // MARK: Shown

  @Test func requiredTeamThatHasNotApprovedIsWaiting() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    arrange(github, requests: [FakeGitHub.teamRequest("PostHog/hogql")])
    let s = try session(sbd)

    try sbd.poll()

    #expect(
      try sbd.owners(s.id)
        == CodeOwnerStatus(satisfied: false, groups: [CodeOwnerGroup(owners: [Self.hogql], approved: false)]))
  }

  @Test func requiredTeamShowsAsJSONWithItsOwnersAndApproval() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    arrange(github, requests: [FakeGitHub.teamRequest("PostHog/hogql")])
    let s = try session(sbd)

    try sbd.poll()

    let expected: JSON = ["satisfied": false, "groups": [["owners": ["@PostHog/hogql"], "approved": false]]]
    #expect(try sbd.ownersShown(s.id) == expected)
  }

  @Test func requiredTeamPrintsAnOwnersLine() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    arrange(github, requests: [FakeGitHub.teamRequest("PostHog/hogql")])
    let s = try session(sbd)

    try sbd.poll()

    #expect(try sbd.ownersLine(s.id) == "Code owner review required: @PostHog/hogql")
  }

  @Test func sbLsShowsTheSameCodeOwnersAsSbGet() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    arrange(github, requests: [FakeGitHub.teamRequest("PostHog/hogql")])
    let s = try session(sbd)

    try sbd.poll()

    let listed = try JSONCoding.decode([SessionSummary].self, from: try sbd.sb("ls", "--json"))
    let row = try #require(listed.first { $0.id == s.id })
    #expect(row.pr?.codeOwners != nil)
    #expect(row.pr?.codeOwners == (try sbd.owners(s.id)))
  }

  @Test func teamApprovalAtTheHeadOnBehalfOfTheTeamSatisfiesTheRequirement() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    arrange(github)
    github.verdict(Self.number, by: "hogql-member", on: try head(github), for: ["PostHog/hogql"])
    github.change(Self.number) { $0["reviewDecision"] = "APPROVED" }
    let s = try session(sbd)

    try sbd.poll()

    #expect(
      try sbd.owners(s.id)
        == CodeOwnerStatus(satisfied: true, groups: [CodeOwnerGroup(owners: [Self.hogql], approved: true)]))
    #expect(try sbd.ownersLine(s.id) == "Code owner review approved: @PostHog/hogql")
    #expect(github.count(FakeGitHub.approvalsKind) == 1)
  }

  /// A team member's approval that GitHub did not attach to the team does
  /// not count, because sbd does not read team membership.
  @Test func teamMembersApprovalWithoutOnBehalfOfLeavesTheTeamWaiting() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    arrange(github)
    github.verdict(Self.number, by: "hogql-member", on: try head(github), for: [])
    let s = try session(sbd)

    try sbd.poll()

    #expect(try sbd.owners(s.id)?.groups == [CodeOwnerGroup(owners: [Self.hogql], approved: false)])
  }

  @Test func userOwnersApprovalSatisfiesTheirGroup() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    arrange(github, paths: [Self.frontendPath])
    github.verdict(Self.number, by: "alice", on: try head(github))
    github.change(Self.number) { $0["reviewDecision"] = "APPROVED" }
    let s = try session(sbd)

    try sbd.poll()

    #expect(
      try sbd.owners(s.id)
        == CodeOwnerStatus(
          satisfied: true, groups: [CodeOwnerGroup(owners: ["@alice", "@PostHog/team-frontend"], approved: true)]))
    #expect(try sbd.ownersLine(s.id) == "Code owner review approved: @alice or @PostHog/team-frontend")
  }

  @Test func severalTeamsListEachGroupWithItsApproval() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    arrange(
      github, paths: [Self.flagsPath, Self.hogqlPath], requests: [FakeGitHub.teamRequest("PostHog/team-feature-flags")])
    github.verdict(Self.number, by: "hogql-member", on: try head(github), for: ["PostHog/hogql"])
    let s = try session(sbd)

    try sbd.poll()

    #expect(
      try sbd.owners(s.id)
        == CodeOwnerStatus(
          satisfied: false,
          groups: [
            CodeOwnerGroup(owners: [Self.hogql], approved: true),
            CodeOwnerGroup(owners: [Self.flags], approved: false),
          ]))
    #expect(
      try sbd.ownersLine(s.id)
        == "Code owner review required (1 of 2 approved); @PostHog/hogql: approved; @PostHog/team-feature-flags: waiting"
    )
  }

  @Test func classicBranchProtectionThatRequiresCodeOwnersShowsTheField() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    arrange(github)
    github.ownerConfig(rules: [], protection: ["requiresCodeOwnerReviews": true])
    let s = try session(sbd)

    try sbd.poll()

    #expect(try sbd.owners(s.id)?.groups == [CodeOwnerGroup(owners: [Self.hogql], approved: false)])
  }

  /// The PR's files are read in pages of 100, so the 101st file's owner
  /// comes from a second files request.
  @Test func ownerOfAFileOnTheSecondPageIsRequired() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let unowned = (1...100).map { "docs/page-\($0).md" }
    arrange(github, paths: unowned + [Self.hogqlPath])
    let s = try session(sbd)

    try sbd.poll()

    #expect(try sbd.owners(s.id)?.groups == [CodeOwnerGroup(owners: [Self.hogql], approved: false)])
    #expect(github.count(FakeGitHub.filesKind) == 2)
  }

  /// GitHub reads the first of `.github/CODEOWNERS`, `CODEOWNERS`, and
  /// `docs/CODEOWNERS` that exists.
  @Test(arguments: [
    ([".github/CODEOWNERS": "/posthog/hogql/ @PostHog/hogql\n"], "@PostHog/hogql"),
    (["CODEOWNERS": "/posthog/hogql/ @PostHog/hogql\n"], "@PostHog/hogql"),
    (["docs/CODEOWNERS": "/posthog/hogql/ @PostHog/hogql\n"], "@PostHog/hogql"),
    (
      [
        ".github/CODEOWNERS": "/posthog/hogql/ @PostHog/hogql\n", "CODEOWNERS": "/posthog/hogql/ @PostHog/team-devex\n",
      ],
      "@PostHog/hogql"
    ),
    (
      ["CODEOWNERS": "/posthog/hogql/ @PostHog/team-devex\n", "docs/CODEOWNERS": "/posthog/hogql/ @PostHog/hogql\n"],
      "@PostHog/team-devex"
    ),
  ])
  func codeOwnersFileComesFromTheFirstLocationThatExists(files: [String: String], owner: String) throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    arrange(github)
    github.ownerConfig(files: files)
    let s = try session(sbd)

    try sbd.poll()

    #expect(try sbd.owners(s.id)?.groups == [CodeOwnerGroup(owners: [owner], approved: false)])
  }

  // MARK: Not shown

  @Test func noCodeOwnersFileShowsNoField() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    arrange(github)
    github.ownerConfig(files: [:], errors: nil)
    let s = try session(sbd)

    try sbd.poll()

    try expectNoField(sbd, s)
    #expect(try sbd.ownersLine(s.id) == nil)
    #expect(github.count(FakeGitHub.filesKind) == 0)
  }

  @Test(arguments: [CodeOwnerTests.ownerlessPath, CodeOwnerTests.unmatchedPath])
  func changedFileWithNoOwnerShowsNoField(path: String) throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    arrange(github, paths: [path])
    let s = try session(sbd)

    try sbd.poll()

    try expectNoField(sbd, s)
    #expect(try sbd.ownersLine(s.id) == nil)
    #expect(github.count(FakeGitHub.filesKind) == 1)
  }

  /// haacked/switchboard's real answer: no rules, no protection, no
  /// CODEOWNERS. A repo with no stored config answers it.
  @Test func repoWithNoConfigMakesOneConfigRequestAndNoOther() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    github.changed(Self.number, [Self.hogqlPath])
    github.ownedPR(Self.number, requests: [])
    let s = try session(sbd)

    let result = try sbd.poll()

    try expectNoField(sbd, s)
    #expect(result["codeOwnersError"] == nil)
    #expect(result["error"] == nil)
    #expect(github.count(FakeGitHub.configKind) == 1)
    #expect(github.count(FakeGitHub.filesKind) == 0)
    #expect(github.count(FakeGitHub.approvalsKind) == 0)
  }

  @Test func protectionOffWithACodeOwnersFileShowsNoFieldAndReadsNoFiles() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    arrange(github)
    github.ownerConfig(rules: [], protection: nil)
    let s = try session(sbd)

    let result = try sbd.poll()

    try expectNoField(sbd, s)
    #expect(result["codeOwnersError"] == nil)
    #expect(result["error"] == nil)
    #expect(github.count(FakeGitHub.configKind) == 1)
    #expect(github.count(FakeGitHub.filesKind) == 0)
  }

  @Test func ruleThatDoesNotRequireCodeOwnerReviewShowsNoField() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    arrange(github)
    github.ownerConfig(
      rules: [FakeGitHub.codeOwnerRule(required: false)], protection: ["requiresCodeOwnerReviews": false])
    let s = try session(sbd)

    try sbd.poll()

    try expectNoField(sbd, s)
    #expect(github.count(FakeGitHub.filesKind) == 0)
  }

  @Test(arguments: ["EVALUATE", "DISABLED"])
  func rulesetThatIsNotActiveShowsNoField(enforcement: String) throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    arrange(github)
    github.ownerConfig(rules: [FakeGitHub.codeOwnerRule(enforcement)])
    let s = try session(sbd)

    try sbd.poll()

    try expectNoField(sbd, s)
    #expect(github.count(FakeGitHub.configKind) == 1)
    #expect(github.count(FakeGitHub.filesKind) == 0)
  }

  @Test func codeOwnersFileWithErrorsShowsNoField() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    arrange(github)
    github.ownerConfig(errors: [["line": 3, "kind": "Unknown owner"]])
    let s = try session(sbd)

    try sbd.poll()

    try expectNoField(sbd, s)
  }

  /// 1,001 is over the cap of 1,000 files. 2 is more than the one path that
  /// the pages hold.
  @Test(arguments: [CodeOwners.maxFiles + 1, 2])
  func incompleteFileListShowsNoField(total: Int) throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    arrange(github)
    github.changed(Self.number, [Self.hogqlPath], total: total)
    let s = try session(sbd)

    try sbd.poll()

    try expectNoField(sbd, s)
  }

  /// 1,000 files take 10 pages and show the field. sbd reads only the first
  /// page of 1,001, because GitHub's count is over the cap.
  @Test(arguments: [(CodeOwners.maxFiles, 10), (CodeOwners.maxFiles + 1, 1)])
  func filesAtAndOverTheCap(count: Int, requests: Int) throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    arrange(github, paths: (1..<count).map { "docs/page-\($0).md" } + [Self.hogqlPath])
    let s = try session(sbd)

    try sbd.poll()

    #expect(github.count(FakeGitHub.filesKind) == requests)
    if count <= CodeOwners.maxFiles {
      #expect(try sbd.owners(s.id)?.groups == [CodeOwnerGroup(owners: [Self.hogql], approved: false)])
    } else {
      try expectNoField(sbd, s)
    }
  }

  @Test func approvalAtAnOlderHeadLeavesTheTeamWaiting() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    arrange(github)
    github.verdict(Self.number, by: "hogql-member", on: String(repeating: "0", count: 40), for: ["PostHog/hogql"])
    let s = try session(sbd)

    try sbd.poll()

    #expect(try sbd.owners(s.id)?.groups == [CodeOwnerGroup(owners: [Self.hogql], approved: false)])
  }

  /// GitHub keeps counting an older head's approval when the ruleset keeps
  /// stale reviews. sbd does not, so it disagrees with APPROVED and hides the field.
  @Test func approvalAtAnOlderHeadThatGitHubApprovesShowsNoField() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    arrange(github)
    github.verdict(Self.number, by: "hogql-member", on: String(repeating: "0", count: 40), for: ["PostHog/hogql"])
    let s = try session(sbd)
    try sbd.poll()
    #expect(try sbd.owners(s.id) != nil)

    github.change(Self.number) { $0["reviewDecision"] = "APPROVED" }
    try pollAgain(sbd)

    try expectNoField(sbd, s)
  }

  @Test func authorsOwnApprovalLeavesTheTeamWaiting() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    arrange(github)
    github.verdict(Self.number, by: Self.author, on: try head(github), for: ["PostHog/hogql"])
    let s = try session(sbd)

    try sbd.poll()

    #expect(try sbd.owners(s.id)?.groups == [CodeOwnerGroup(owners: [Self.hogql], approved: false)])
  }

  @Test(arguments: ["CHANGES_REQUESTED", "DISMISSED", "COMMENTED"])
  func lastVerdictThatIsNotAnApprovalLeavesTheTeamWaiting(state: String) throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    arrange(github)
    github.verdict(Self.number, by: "hogql-member", state, on: try head(github), for: ["PostHog/hogql"])
    let s = try session(sbd)

    try sbd.poll()

    #expect(try sbd.owners(s.id)?.groups == [CodeOwnerGroup(owners: [Self.hogql], approved: false)])
  }

  // MARK: Guards that compare with GitHub

  @Test func gitHubApprovedWhileAGroupWaitsShowsNoField() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    arrange(github)
    let s = try session(sbd)
    try sbd.poll()
    #expect(try sbd.owners(s.id)?.satisfied == false)

    github.change(Self.number) { $0["reviewDecision"] = "APPROVED" }
    try pollAgain(sbd)

    try expectNoField(sbd, s)
  }

  /// GitHub's code owner requests come from its own matcher. One that names
  /// an owner in none of sbd's groups shows that sbd missed an owner.
  @Test(arguments: [
    FakeGitHub.teamRequest("PostHog/team-devex"),
    FakeGitHub.userRequest("bob"),
  ])
  func codeOwnerRequestForAnOwnerOutsideTheGroupsShowsNoField(request: JSON) throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    arrange(github)
    let s = try session(sbd)
    try sbd.poll()
    #expect(try sbd.owners(s.id) != nil)

    github.ownedPR(Self.number, requests: [FakeGitHub.teamRequest("PostHog/hogql"), request])
    try pollAgain(sbd)

    try expectNoField(sbd, s)
  }

  /// A request that is not a code owner request, and a team spelled in
  /// another case, name no owner that sbd missed.
  @Test(arguments: [
    FakeGitHub.teamRequest("PostHog/team-devex", asCodeOwner: false),
    FakeGitHub.userRequest("bob", asCodeOwner: false),
    FakeGitHub.teamRequest("posthog/HOGQL"),
  ])
  func requestThatNamesNoMissedOwnerKeepsTheField(request: JSON) throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    arrange(github, requests: [request])
    let s = try session(sbd)

    try sbd.poll()

    #expect(try sbd.owners(s.id)?.groups == [CodeOwnerGroup(owners: [Self.hogql], approved: false)])
  }

  /// GitHub returned fewer requests than it counts, so an unread request
  /// could name an owner that sbd missed.
  @Test func requestListLongerThanItsNodesShowsNoField() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    arrange(github)
    github.change(Self.number) {
      $0["reviewRequests"] = ["totalCount": 21, "nodes": [FakeGitHub.teamRequest("PostHog/hogql")]]
    }
    let s = try session(sbd)

    try sbd.poll()

    try expectNoField(sbd, s)
  }

  /// sbd reads code owners only for the PRs that sessions name, not for a
  /// PR that only a wait names.
  @Test func prThatOnlyAWaitNamesGetsNoFilesRead() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    arrange(github)
    github.changed(122896, [Self.hogqlPath])
    let s = try session(sbd)
    try sbd.sb("wait", s.id, "--kind", "merge", "--target", "#122896")
    let target = try #require(github.pr(122896)["id"]?.string)

    try sbd.poll()

    #expect(github.requests.contains { $0.kind == "status" && $0.ids.contains(target) })
    #expect(!github.requests.contains { $0.kind == FakeGitHub.filesKind && $0.ids.contains(target) })
    #expect(try sbd.owners(s.id) != nil)
  }

  // MARK: Failed reads

  @Test func failedConfigReadShowsNoFieldAndReportsCodeOwnersError() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    arrange(github)
    github.failConfig()
    let s = try session(sbd)

    let result = try #require(JSON.parse(try sbd.run("poll", "--json").stdout))

    #expect(result["codeOwnersError"]?.string?.isEmpty == false)
    #expect(result["error"] == nil)
    #expect(result["polled"]?.int == 1)
    try expectNoField(sbd, s)
  }

  /// A key with no successful read is due again at the next poll.
  @Test func configReadThatRecoversShowsTheFieldAtTheNextPoll() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    arrange(github)
    github.failConfig()
    let s = try session(sbd)
    try sbd.poll()

    github.recoverConfig()
    let result = try sbd.poll()

    #expect(result["codeOwnersError"] == nil)
    #expect(try sbd.owners(s.id)?.groups == [CodeOwnerGroup(owners: [Self.hogql], approved: false)])
  }

  @Test func failedFilesReadShowsNoFieldAndReportsCodeOwnersError() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    arrange(github)
    github.failFiles(Self.number)
    let s = try session(sbd)

    let result = try sbd.poll()

    #expect(result["codeOwnersError"]?.string?.isEmpty == false)
    #expect(github.count(FakeGitHub.filesKind) >= 1)
    try expectNoField(sbd, s)
  }

  @Test func filesReadThatRecoversShowsTheFieldAtTheNextPoll() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    arrange(github)
    github.failFiles(Self.number)
    let s = try session(sbd)
    try sbd.poll()

    github.recoverFiles(Self.number)
    let result = try sbd.poll()

    #expect(result["codeOwnersError"] == nil)
    #expect(try sbd.owners(s.id)?.groups == [CodeOwnerGroup(owners: [Self.hogql], approved: false)])
  }

  /// An approval whose teams sbd could not read could be the one that a
  /// group waits for.
  @Test func failedApprovalsReadShowsNoFieldAndReportsCodeOwnersError() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    arrange(github)
    github.verdict(Self.number, by: "hogql-member", on: try head(github), for: ["PostHog/hogql"])
    github.fail(Self.number, in: .approvals)
    let s = try session(sbd)

    let result = try sbd.poll()

    #expect(result["codeOwnersError"]?.string?.isEmpty == false)
    #expect(github.count(FakeGitHub.approvalsKind) == 1)
    try expectNoField(sbd, s)
  }

  /// A key that had a successful read keeps it when a later read fails, and
  /// the status read that rebuilt the PR gets the requirement back.
  @Test func failedConfigReadAfterASuccessfulOneKeepsTheField() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    arrange(github)
    let s = try session(sbd)
    try sbd.poll()
    let shown = try #require(try sbd.owners(s.id))
    let statusReads = github.count("status")

    github.failConfig()
    let result = try sbd.poll(all: true)

    #expect(result["codeOwnersError"]?.string?.isEmpty == false)
    #expect(github.count("status") > statusReads)
    #expect(try sbd.owners(s.id) == shown)
  }

  /// `checkDeploys` throws after `readPRs` rebuilt #122953 without a
  /// requirement. The requirement comes back before the poll records the PR.
  @Test func failedDeployStateReadInTheSameCycleKeepsTheField() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    arrange(github)
    let s = try session(sbd)
    try sbd.poll()
    #expect(try sbd.owners(s.id) != nil)
    let lastEvent = try sbd.events(s.id).last?.id ?? 0
    let mark = github.requests.count
    let id = try #require(github.pr(Self.number)["id"]?.string)
    github.change(122179) { $0["mergeCommit"] = ["oid": .string(DeployPollerTests.merge)] }
    try sbd.sb("wait", s.id, "--kind", "deploy", "--service", "feature-flags", "--target", "#122179")
    github.failNextGET(DeployPollerTests.statePath)
    github.change(Self.number) { $0["title"] = "a new title" }

    let result = try pollAgain(sbd)

    #expect(result["error"] != nil)
    #expect(github.restRequests(to: DeployPollerTests.statePath).count == 1)
    #expect(github.requests.dropFirst(mark).contains { $0.kind == "status" && $0.ids.contains(id) })
    let recorded = try sbd.events(s.id).filter { $0.id > lastEvent && $0.kind == "pr" }
    #expect(recorded.last?.data["pr"]?["title"]?.string == "a new title")
    #expect(recorded.allSatisfy { ($0.data["pr"]?["codeOwners"] ?? .null) != .null })
    #expect(try sbd.owners(s.id)?.groups == [CodeOwnerGroup(owners: [Self.hogql], approved: false)])
  }

  // MARK: Caches

  @Test func pushToANewHeadReadsTheFilesAgainAndChangesTheGroups() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    arrange(github)
    let s = try session(sbd)
    try sbd.poll()
    #expect(try sbd.owners(s.id)?.groups == [CodeOwnerGroup(owners: [Self.hogql], approved: false)])
    let files = github.count(FakeGitHub.filesKind)

    github.change(Self.number) { $0["headRefOid"] = .string(String(repeating: "f", count: 40)) }
    github.changed(Self.number, [Self.flagsPath])
    try pollAgain(sbd)

    #expect(github.count(FakeGitHub.filesKind) == files + 1)
    #expect(try sbd.owners(s.id)?.groups == [CodeOwnerGroup(owners: [Self.flags], approved: false)])
  }

  /// A push or a retarget between two pages of files leaves no pages to
  /// read the requirement from. The next poll reads every page at the new
  /// head and base.
  @Test(arguments: [("headRefOid", String(repeating: "f", count: 40)), ("baseRefName", "release")])
  func changeBetweenTwoPagesOfFilesKeepsNeitherPage(field: String, value: String) throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    arrange(github, paths: (1...100).map { "docs/page-\($0).md" } + [Self.hogqlPath])
    github.codeOwners(
      repo: DepotTests.posthog, base: "release", rules: [FakeGitHub.codeOwnerRule()], protection: nil,
      files: [".github/CODEOWNERS": Self.codeowners], errors: [])
    github.afterNextFiles { github.change(Self.number) { $0[field] = .string(value) } }
    let s = try session(sbd)

    let result = try sbd.poll()

    #expect(result["codeOwnersError"] == nil)
    #expect(github.count(FakeGitHub.filesKind) == 2)
    try expectNoField(sbd, s)

    try pollAgain(sbd)

    #expect(github.count(FakeGitHub.filesKind) == 4)
    #expect(try sbd.owners(s.id)?.groups == [CodeOwnerGroup(owners: [Self.hogql], approved: false)])
  }

  /// The status read is due again, so the poll rebuilds the PR. The config
  /// is not due within the idle interval, the files belong to the same head,
  /// and the approval is already read.
  @Test func secondPollAtTheSameHeadMakesNoCodeOwnerRequests() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    arrange(github)
    github.verdict(Self.number, by: "hogql-member", on: try head(github), for: ["PostHog/hogql"])
    github.change(Self.number) { $0["reviewDecision"] = "APPROVED" }
    let s = try session(sbd)
    try sbd.poll()
    #expect(github.count(FakeGitHub.configKind) == 1)
    #expect(github.count(FakeGitHub.approvalsKind) == 1)
    let mark = github.requests.count

    try pollAgain(sbd)

    #expect(github.count("status", after: mark) >= 1)
    #expect(github.count(FakeGitHub.configKind, after: mark) == 0)
    #expect(github.count(FakeGitHub.filesKind, after: mark) == 0)
    #expect(github.count(FakeGitHub.approvalsKind, after: mark) == 0)
    #expect(try sbd.owners(s.id)?.satisfied == true)
  }

  /// A new approval has a reviewer and submission time that the approval
  /// cache has not seen.
  @Test func newApprovalIsReadAtTheNextPoll() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    arrange(github)
    let s = try session(sbd)
    try sbd.poll()
    #expect(try sbd.owners(s.id)?.satisfied == false)
    let mark = github.requests.count

    github.verdict(Self.number, by: "hogql-member", on: try head(github), for: ["PostHog/hogql"])
    github.change(Self.number) { $0["reviewDecision"] = "APPROVED" }
    try pollAgain(sbd)

    #expect(github.count(FakeGitHub.approvalsKind, after: mark) == 1)
    #expect(github.count(FakeGitHub.filesKind, after: mark) == 0)
    #expect(try sbd.owners(s.id)?.satisfied == true)
  }

  @Test func pollAllReadsTheConfigAgainButNotTheFiles() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    arrange(github)
    let s = try session(sbd)
    try sbd.poll()
    let mark = github.requests.count

    try sbd.poll(all: true)

    #expect(github.count(FakeGitHub.configKind, after: mark) == 1)
    #expect(github.count(FakeGitHub.filesKind, after: mark) == 0)
    #expect(try sbd.owners(s.id) != nil)
  }

  @Test func configIsReadAgainAfterTheIdleInterval() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    arrange(github)
    let s = try session(sbd)
    try sbd.poll()
    let mark = github.requests.count

    try sbd.advanceClock(300_000)
    try sbd.poll()

    #expect(github.count(FakeGitHub.configKind, after: mark) == 1)
    #expect(github.count(FakeGitHub.filesKind, after: mark) == 0)
    #expect(try sbd.owners(s.id) != nil)
  }

  /// A CODEOWNERS change reaches the shield at the next config read.
  @Test func changedConfigChangesTheGroupsAtTheNextConfigRead() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    arrange(github)
    let s = try session(sbd)
    try sbd.poll()

    github.ownerConfig(files: [".github/CODEOWNERS": "/posthog/hogql/ @PostHog/team-devex\n"])
    try sbd.poll(all: true)

    #expect(try sbd.owners(s.id)?.groups == [CodeOwnerGroup(owners: ["@PostHog/team-devex"], approved: false)])
  }
}
