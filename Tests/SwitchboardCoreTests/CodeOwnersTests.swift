import Foundation
import Testing

@testable import SwitchboardCore

/// GitHub's example file from "About code owners" on docs.github.com, as of
/// 2026-11-06.
private let gitHubExampleFile = """
  # This is a comment.
  # Each line is a file pattern followed by one or more owners.

  # These owners will be the default owners for everything in
  # the repo. Unless a later match takes precedence,
  # @global-owner1 and @global-owner2 will be requested for
  # review when someone opens a pull request.
  *       @global-owner1 @global-owner2

  # Order is important; the last matching pattern takes the most
  # precedence. When someone opens a pull request that only
  # modifies JS files, only @js-owner and not the global
  # owner(s) will be requested for a review.
  *.js    @js-owner #This is an inline comment.

  # You can also use email addresses if you prefer. They'll be
  # used to look up users just like we do for commit author
  # emails.
  *.go docs@example.com

  # Teams can be specified as code owners as well. Teams should
  # be identified in the format @org/team-name. Teams must have
  # explicit write access to the repository. In this example,
  # the octocats team in the octo-org organization owns all .txt files.
  *.txt @octo-org/octocats

  # In this example, @doctocat owns any files in the build/logs
  # directory at the root of the repository and any of its
  # subdirectories.
  /build/logs/ @doctocat

  # The `docs/*` pattern will match files like
  # `docs/getting-started.md` but not further nested files like
  # `docs/build-app/troubleshooting.md`.
  docs/* docs@example.com

  # In this example, @octocat owns any file in an apps directory
  # anywhere in your repository.
  apps/ @octocat

  # In this example, @doctocat owns any file in the `/docs`
  # directory in the root of your repository and any of its
  # subdirectories.
  /docs/ @doctocat

  # In this example, any change inside the `/scripts` directory
  # will require approval from @doctocat or @octocat.
  /scripts/ @doctocat @octocat

  # In this example, @octocat owns any file in a `/logs` directory such as
  # `/build/logs`, `/scripts/logs`, and `/deeply/nested/logs`. Any changes
  # in a `/logs` directory will require approval from @octocat.
  **/logs @octocat

  # In this example, @octocat owns any file in the `/apps`
  # directory in the root of your repository except for the `/apps/github`
  # subdirectory, as its owners are left empty. Without an owner, changes
  # to `apps/github` can be made with the approval of any user who has
  # write access to the repository.
  /apps/ @octocat
  /apps/github

  # In this example, @octocat owns any file in the `/apps`
  # directory in the root of your repository except for the `/apps/github`
  # subdirectory, as this subdirectory has its own owner @doctocat
  /apps/ @octocat
  /apps/github @doctocat

  """

private let o = ["@o"]
private let none: [String] = []
private let hogql = "posthog/hogql/** @a\nposthog/hogql/database/schema/** @b"
private let apps = "/apps/ @o\n/apps/github"
private let mobile = ".github/workflows/*mobile*.yml @o"

@Suite struct CodeOwnersMatching {
  /// Each probe resolves by the last matching line of the whole file.
  @Test(
    arguments: [
      ("README.md", ["@global-owner1", "@global-owner2"]),
      ("src/app.js", ["@js-owner"]),
      ("cmd/main.go", ["docs@example.com"]),
      ("notes.txt", ["@octo-org/octocats"]),
      ("build/logs/today.log", ["@octocat"]),
      ("docs/getting-started.md", ["@doctocat"]),
      ("docs/build-app/troubleshooting.md", ["@doctocat"]),
      ("src/apps/main.c", ["@octocat"]),
      ("scripts/deploy.sh", ["@doctocat", "@octocat"]),
      ("scripts/logs/run.sh", ["@octocat"]),
      ("deeply/nested/logs/notes.txt", ["@octocat"]),
      ("apps/web/index.js", ["@octocat"]),
      ("apps/github/readme.md", ["@doctocat"]),
      ("foo/apps/github/x.c", ["@octocat"]),
      // Without the type, the Command Line Tools' Swift 6.4 cannot type-check the literal.
    ] as [(String, [String])])
  func gitHubsExampleFileGivesTheLastMatchingLinesOwners(_ path: String, _ owners: [String]) throws {
    let file = try #require(CodeOwnersFile.parse(gitHubExampleFile))

    #expect(file.owners(of: path) == owners)
  }

  /// One pattern form at a time, so that no later line hides a broken rule.
  @Test(
    arguments: [
      ("* @o", "README.md", o),
      ("* @o", "a/b/c.txt", o),
      ("*.js @o", "src/app.js", o),
      ("*.js @o", "app.jsx", none),
      ("*.go @o", "cmd/sb/main.go", o),
      ("/src/*.js @o", "src/a.js", o),
      ("/src/*.js @o", "src/lib/a.js", none),
      ("/src/file?.txt @o", "src/file1.txt", o),
      ("file?.txt @o", "file12.txt", none),
      ("/src/a?b @o", "src/a/b", none),
      ("/src/**/test.js @o", "src/test.js", o),
      ("/src/**/test.js @o", "src/a/b/test.js", o),
      ("/build/logs/ @o", "build/logs/a.log", o),
      ("/build/logs/ @o", "build/logs/sub/a.log", o),
      ("/build/logs/ @o", "x/build/logs/a.log", none),
      ("/build/logs/ @o", "build/logs", none),
      ("docs/* @o", "docs/getting-started.md", o),
      ("docs/* @o", "docs/build-app/troubleshooting.md", none),
      ("docs/* @o", "x/docs/a.md", none),
      ("apps/ @o", "apps/a.js", o),
      ("apps/ @o", "src/apps/a.js", o),
      ("apps/ @o", "apps/a/b.js", o),
      ("apps/ @o", "apps", none),
      ("apps/ @o", "myapps/a.js", none),
      ("/docs/ @o", "docs/a/b.md", o),
      ("/docs/ @o", "src/docs/a.md", none),
      ("/scripts/ @doctocat @octocat", "scripts/x.sh", ["@doctocat", "@octocat"]),
      ("**/logs @o", "logs/a", o),
      ("**/logs @o", "deeply/nested/logs/a", o),
      ("**/logs @o", "build/logs", o),
      ("**/logs @o", "catalogs/a", none),
      ("**/logs @o", "logs-old/a", none),
      (apps, "apps/github/x.js", none),
      (apps, "apps/github", none),
      (apps, "apps/other.js", o),
      (apps, "apps/github-tools/x.js", o),
      ("apps/ @o\n/apps/github", "foo/apps/github/x", o),
      (hogql, "posthog/hogql/parser.py", ["@a"]),
      (hogql, "posthog/hogql/database/schema/events.py", ["@b"]),
      (hogql, "posthog/hogql/database/models.py", ["@a"]),
      (hogql, "posthog/hogql/a/b/c.py", ["@a"]),
      (hogql, "x/posthog/hogql/parser.py", none),
      ("posthog/hogql/database/schema/** @b\nposthog/hogql/** @a", "posthog/hogql/database/schema/events.py", ["@a"]),
      ("CODEOWNERS @o", "CODEOWNERS", o),
      ("CODEOWNERS @o", ".github/CODEOWNERS", o),
      ("CODEOWNERS @o", "docs/CODEOWNERS", o),
      ("CODEOWNERS @o", "CODEOWNERS/x", o),
      ("CODEOWNERS @o", "CODEOWNERS.md", none),
      ("CODEOWNERS @o", "codeowners", none),
      (mobile, ".github/workflows/ci-mobile-build.yml", o),
      (mobile, ".github/workflows/mobile.yml", o),
      (mobile, ".github/workflows/sub/mobile.yml", none),
      (mobile, ".github/workflows/ci.yml", none),
      ("bin/dev-sandbox* @o", "bin/dev-sandbox", o),
      ("bin/dev-sandbox* @o", "bin/dev-sandbox-setup", o),
      ("bin/dev-sandbox* @o", "bin/dev-sandbox/run.sh", none),
      ("bin/dev-sandbox* @o", "foo/bin/dev-sandbox", none),
      ("/Docs/ @o", "docs/a.md", none),
      ("*.MD @o", "README.md", none),
      ("/README.md @o", "x/README.md", none),
      ("README.md @o", "x/README.md", o),
      ("src/lib @o", "src/lib/a.c", o),
      ("src/lib @o", "x/src/lib/a.c", none),
      ("a.b @o", "axb", none),
      ("x+(1).txt @o", "x+(1).txt", o),
      ("{a,b}.txt @o", "a.txt", none),
      ("{a,b}.txt @o", "{a,b}.txt", o),
      ("$tmp^ @o", "$tmp^", o),
      // Without the type, the Command Line Tools' Swift 6.4 cannot type-check the literal.
    ] as [(String, String, [String])])
  func eachPatternFormMatchesAsGitHubDocumentsIt(_ text: String, _ path: String, _ owners: [String]) throws {
    let file = try #require(CodeOwnersFile.parse(text))

    #expect(file.owners(of: path) == owners)
  }

  @Test(arguments: [
    ("# c\n\n*.js @a", "app.js", ["@a"]),
    ("*.js @a #note", "app.js", ["@a"]),
    ("*.js @a #x @b", "app.js", ["@a"]),
    ("*.js\t@a   @b", "app.js", ["@a", "@b"]),
    ("* @a\n*.js #nobody", "app.js", none),
    ("* @a\n*.js", "app.js", none),
    ("*.js @a\r\n*.go @b\r\n", "main.go", ["@b"]),
    ("*.js @a\r\n*.go @b\r\n", "app.js", ["@a"]),
  ])
  func commentsWhitespaceAndEmptyOwnersAreRead(_ text: String, _ path: String, _ owners: [String]) throws {
    let file = try #require(CodeOwnersFile.parse(text))

    #expect(file.owners(of: path) == owners)
  }

  /// GitHub does not support negation, ranges, or escapes, so sbd cannot
  /// predict how GitHub reads such a line.
  @Test(arguments: [
    "!docs/ @a",
    "  !docs/ @a",
    "*.js @a\n!*.min.js",
    "docs/[abc].md @a",
    "docs/a].md @a",
    "[Section]",
    "docs/a\\#b @a",
    "\\#notacomment @a",
  ])
  func aLineThatGitHubDoesNotSupportMakesTheFileUnusable(_ text: String) {
    #expect(CodeOwnersFile.parse(text) == nil)
  }

  /// A pattern of only slashes names no path that sbd can predict.
  @Test(arguments: ["/ @a", "// @a", "* @a\n/"])
  func aPatternOfOnlySlashesMakesTheFileUnusable(_ text: String) {
    #expect(CodeOwnersFile.parse(text) == nil)
  }

  @Test(arguments: [
    "# [comment] !x \\y\n* @a",
    "*.js @a # [inline] !comment \\x",
    "foo!bar @a",
  ])
  func unsupportedCharactersOutsideAnActivePatternAreAccepted(_ text: String) {
    #expect(CodeOwnersFile.parse(text) != nil)
  }

  /// Matching takes about 80 ms in a debug build, but seconds on a loaded CI
  /// runner. The time limit only catches a hang.
  @Test(.timeLimit(.minutes(1))) func matchingAThousandPathsReusesThePatternsThatParseCompiled() throws {
    var lines: [String] = []
    for i in 0..<20 {
      lines += [
        "posthog/module\(i)/** @PostHog/team-\(i)", "frontend/src/scenes/scene\(i)/ @PostHog/team-\(i)",
        "*.ext\(i) @PostHog/team-\(i)",
      ]
    }
    let paths = (0..<1000).map {
      $0.isMultiple(of: 2)
        ? "posthog/module\($0 % 20)/sub/dir/file\($0).py" : "frontend/src/scenes/scene\($0 % 25)/a/b/c\($0).tsx"
    }
    let compilations = CodeOwnersFile.Compilations()

    let owned = try CodeOwnersFile.$compilations.withValue(compilations) {
      let file = try #require(CodeOwnersFile.parse(lines.joined(separator: "\n")))
      #expect(compilations.count == lines.count)
      return paths.count { !file.owners(of: $0).isEmpty }
    }

    #expect(owned > 0)
    #expect(compilations.count == lines.count)
  }

  /// A backtracking regex runs for seconds to hours on each of these lines.
  @Test(arguments: [
    String(repeating: "*?", count: 12) + "*Z",
    String(repeating: "*a", count: 20) + "*Z",
    String(repeating: "**/", count: 30) + "Z",
    String(repeating: "a/**/", count: 15) + "Z",
  ])
  func aLineWithManyWildcardsMatchesQuickly(pattern: String) throws {
    let file = try #require(CodeOwnersFile.parse("\(pattern) @x"))
    let paths = [
      "frontend/src/scenes/feature-flags/components/release/v2/FeatureFlagReleaseConditions.tsx",
      String(repeating: "a", count: 200), String(repeating: "a/", count: 40) + "b",
    ]

    let elapsed = ContinuousClock().measure {
      for path in paths { #expect(file.owners(of: path).isEmpty) }
    }

    #expect(elapsed < .seconds(2))
  }

  @Test func manyWildcardsStillMatchWhatTheyDescribe() throws {
    let file = try #require(
      CodeOwnersFile.parse(
        [
          String(repeating: "*a", count: 20) + "*Z @stars", String(repeating: "**/", count: 30) + "Z @deep",
        ].joined(separator: "\n")))

    #expect(file.owners(of: String(repeating: "xa", count: 20) + "Z") == ["@stars"])
    #expect(file.owners(of: "one/two/three/Z") == ["@deep"])
    #expect(file.owners(of: "Z") == ["@deep"])
  }
}

// MARK: - Config

/// The aliases of the three `object(expression:)` reads in
/// `GitHub.codeOwnersConfigQuery`, in GitHub's order of precedence.
private let githubAlias = "github"
private let rootAlias = "root"
private let docsAlias = "docs"

private let defaultOwnerFile = "* @PostHog/team-default\n"

private func ownerBlob(_ text: String?, truncated: Bool = false, binary: Bool = false) -> JSON {
  ["text": text.map(JSON.string) ?? .null, "isTruncated": .bool(truncated), "isBinary": .bool(binary)]
}

/// A node of `ref.rules`. A rule whose type isn't PULL_REQUEST answers the
/// `... on PullRequestParameters` fragment with an empty object.
private func ownerRule(
  _ type: String = "PULL_REQUEST", requireCodeOwnerReview: Bool? = true, enforcement: String = "ACTIVE"
) -> JSON {
  let parameters: JSON =
    requireCodeOwnerReview.map { (on: Bool) -> JSON in ["requireCodeOwnerReview": .bool(on)] } ?? [:]
  return ["type": .string(type), "parameters": parameters, "repositoryRuleset": ["enforcement": .string(enforcement)]]
}

private func configResponse(
  rules: [JSON] = [ownerRule()], totalCount: Int? = nil, protection: JSON = .null, hasRef: Bool = true,
  codeowners: JSON = ["errors": []], blobs: [String: JSON] = [githubAlias: ownerBlob(defaultOwnerFile)]
) -> JSON {
  var repository: [String: JSON] = ["codeowners": codeowners]
  let ruleConnection: JSON = ["totalCount": .number(Double(totalCount ?? rules.count)), "nodes": .array(rules)]
  repository["ref"] = hasRef ? ["branchProtectionRule": protection, "rules": ruleConnection] : .null
  for alias in [githubAlias, rootAlias, docsAlias] { repository[alias] = blobs[alias] ?? .null }
  return ["data": ["repository": .object(repository)]]
}

private func adding(errors: JSON, to response: JSON) -> JSON {
  var object = response.object ?? [:]
  object["errors"] = errors
  return .object(object)
}

private func onFile(_ config: CodeOwnersConfig) -> CodeOwnersFile? {
  if case .on(let file) = config { return file }
  return nil
}

private func parsedFile(_ response: JSON) throws -> CodeOwnersFile? {
  onFile(try GitHub.parseCodeOwnersConfig(response))
}

private let truncatedRules: [JSON] =
  [ownerRule()] + (0..<99).map { _ in ownerRule("DELETION", requireCodeOwnerReview: nil) }

@Suite struct CodeOwnersConfigParsing {
  @Test func anActiveRuleThatRequiresCodeOwnerReviewWithAFileIsOn() throws {
    let file = try #require(try parsedFile(configResponse()))

    #expect(file.owners(of: "README.md") == ["@PostHog/team-default"])
  }

  @Test(
    arguments: [
      [],
      [ownerRule(requireCodeOwnerReview: false)],
      [ownerRule(enforcement: "EVALUATE")],
      [ownerRule(enforcement: "DISABLED")],
      [ownerRule("REQUIRED_STATUS_CHECKS", requireCodeOwnerReview: nil)],
      [ownerRule(enforcement: "EVALUATE"), ownerRule(requireCodeOwnerReview: false)],
      [ownerRule(enforcement: "DISABLED"), ownerRule("DELETION", requireCodeOwnerReview: nil)],
    ] as [[JSON]])
  func rulesWithoutAnActiveCodeOwnerRequirementAreOff(_ rules: [JSON]) throws {
    #expect(try parsedFile(configResponse(rules: rules)) == nil)
  }

  @Test func anActiveRequirementAmongOtherRulesIsOn() throws {
    let rules = [
      ownerRule("DELETION", requireCodeOwnerReview: nil), ownerRule(enforcement: "EVALUATE"), ownerRule(),
    ]

    #expect(try parsedFile(configResponse(rules: rules)) != nil)
  }

  @Test func protectionThatRequiresCodeOwnerReviewsWithNoRulesIsOn() throws {
    let response = configResponse(rules: [], protection: ["requiresCodeOwnerReviews": true])

    #expect(try parsedFile(response) != nil)
  }

  @Test func protectionThatDoesNotRequireCodeOwnerReviewsWithNoRulesIsOff() throws {
    let response = configResponse(rules: [], protection: ["requiresCodeOwnerReviews": false])

    #expect(try parsedFile(response) == nil)
  }

  /// An unread rule could change the stale-approval setting, so a truncated
  /// rules list is unknown even when a read rule or the protection turns the
  /// requirement on.
  @Test(arguments: [JSON.null, ["requiresCodeOwnerReviews": true]])
  func aRulesListLongerThanItsNodesIsUnknown(_ protection: JSON) throws {
    let response = configResponse(rules: truncatedRules, totalCount: 101, protection: protection)

    #expect(try parsedFile(response) == nil)
  }

  @Test func aRulesListOfExactlyItsNodesIsRead() throws {
    let response = configResponse(rules: truncatedRules, totalCount: 100)

    #expect(try parsedFile(response) != nil)
  }

  /// A rule node that failed to read could be the one that turns the
  /// requirement off or on.
  @Test func aNullRuleNodeIsUnknown() throws {
    let response = configResponse(rules: [ownerRule(), .null], totalCount: 2)

    #expect(try parsedFile(response) == nil)
  }

  @Test func aRulesConnectionWithoutACountIsUnknown() throws {
    var repository = try #require(configResponse()["data"]?["repository"]?.object)
    repository["ref"] = ["branchProtectionRule": .null, "rules": ["nodes": [ownerRule()]]]

    #expect(try parsedFile(["data": ["repository": .object(repository)]]) == nil)
  }

  @Test func aMissingBaseRefIsNotOn() throws {
    #expect(try parsedFile(configResponse(hasRef: false)) == nil)
  }

  @Test func noFileInAnyLocationIsNotOn() throws {
    #expect(try parsedFile(configResponse(blobs: [:])) == nil)
  }

  @Test(
    arguments: [
      ([githubAlias: ownerBlob("* @github"), rootAlias: ownerBlob("* @root")], "@github"),
      (
        [githubAlias: ownerBlob("* @github"), rootAlias: ownerBlob("* @root"), docsAlias: ownerBlob("* @docs")],
        "@github"
      ),
      ([rootAlias: ownerBlob("* @root"), docsAlias: ownerBlob("* @docs")], "@root"),
      ([githubAlias: ownerBlob("* @github"), docsAlias: ownerBlob("* @docs")], "@github"),
      ([rootAlias: ownerBlob("* @root")], "@root"),
      ([docsAlias: ownerBlob("* @docs")], "@docs"),
    ] as [([String: JSON], String)])
  func theFirstLocationThatHasAFileWins(_ blobs: [String: JSON], _ owner: String) throws {
    let file = try #require(try parsedFile(configResponse(blobs: blobs)))

    #expect(file.owners(of: "x") == [owner])
  }

  @Test func errorsInTheCodeOwnersFileMakeItUnknown() throws {
    let response = configResponse(codeowners: ["errors": [["line": 3, "kind": "Unknown owner"]]])

    #expect(try parsedFile(response) == nil)
  }

  @Test func aNullCodeOwnersReportWithAFileIsUnknown() throws {
    #expect(try parsedFile(configResponse(codeowners: .null)) == nil)
  }

  /// The chosen file is the first that exists. An unusable one is not skipped
  /// for the next location, because GitHub does not skip it.
  @Test(
    arguments: [
      [githubAlias: ownerBlob(defaultOwnerFile, truncated: true)],
      [githubAlias: ownerBlob(defaultOwnerFile, binary: true)],
      [githubAlias: ownerBlob(nil)],
      [githubAlias: [:]],
      [githubAlias: ownerBlob(defaultOwnerFile, truncated: true), rootAlias: ownerBlob("* @root")],
      [rootAlias: ownerBlob(nil), docsAlias: ownerBlob("* @docs")],
    ] as [[String: JSON]])
  func anUnreadableChosenFileIsUnknown(_ blobs: [String: JSON]) throws {
    #expect(try parsedFile(configResponse(blobs: blobs)) == nil)
  }

  @Test(arguments: ["!docs/ @a", "docs/[abc].md @a", "docs/a].md @a", "docs/a\\#b @a"])
  func aFileWithUnsupportedSyntaxIsUnknown(_ line: String) throws {
    let response = configResponse(blobs: [githubAlias: ownerBlob("* @a\n\(line)\n")])

    #expect(try parsedFile(response) == nil)
  }

  /// A partial answer is a failed read, not "off".
  @Test(
    arguments: [
      [["path": ["repository"], "type": "FORBIDDEN", "message": "x"]],
      [["path": ["repository", "ref"], "type": "FORBIDDEN", "message": "x"]],
      [["path": ["repository", "ref", "rules"], "type": "FORBIDDEN", "message": "x"]],
      [["path": ["repository", "codeowners"], "type": "SERVICE_UNAVAILABLE", "message": "x"]],
      [["path": ["repository", .string(githubAlias)], "type": "FORBIDDEN", "message": "x"]],
      [["message": "Something went wrong"]],
    ] as [JSON])
  func aGraphQLErrorAtTheRepositoryThrows(_ errors: JSON) {
    let response = adding(errors: errors, to: configResponse(rules: [], blobs: [:]))

    #expect(throws: (any Error).self) { try GitHub.parseCodeOwnersConfig(response) }
  }

  @Test func aResponseWithoutARepositoryThrows() {
    let response: JSON = ["data": ["repository": .null]]

    #expect(throws: (any Error).self) { try GitHub.parseCodeOwnersConfig(response) }
  }

  @Test func theQueryReadsEveryFieldThatTheParserUses() {
    let query = GitHub.codeOwnersConfigQuery

    for field in [
      "branchProtectionRule", "requiresCodeOwnerReviews", "rules(first: 100)", "totalCount",
      "requireCodeOwnerReview", "enforcement", "codeowners(refName:", "isTruncated", "isBinary",
    ] {
      #expect(query.contains(field), "\(field)")
    }
  }

  /// The parser reads each blob by its alias, so the query must use the same
  /// aliases.
  @Test(arguments: [githubAlias, rootAlias, docsAlias])
  func theQueryAliasesEachLocationThatTheParserReads(_ alias: String) {
    #expect(GitHub.codeOwnersConfigQuery.contains("\(alias): object(expression:"))
  }
}

// MARK: - Files and approval teams

private func filesNode(_ paths: [String?], total: Int, next: String?) -> JSON {
  let nodes = paths.map { path in path.map { ["path": .string($0)] as JSON } ?? .null }
  return [
    "id": "PR_42", "headRefOid": .string(samplePRHead), "baseRefName": "main",
    "files": [
      "totalCount": .number(Double(total)),
      "pageInfo": ["hasNextPage": .bool(next != nil), "endCursor": .string(next ?? "LAST")],
      "nodes": .array(nodes),
    ],
  ]
}

private func approvalNode(_ author: String, _ submittedAt: String, teams: [String]) -> JSON {
  [
    "author": ["login": .string(author)], "submittedAt": .string(submittedAt),
    "onBehalfOf": ["nodes": .array(teams.map { ["combinedSlug": .string($0)] })],
  ]
}

@Suite struct CodeOwnersFileAndTeamParsing {
  @Test func aFirstPageGivesItsPathsTheTotalAndTheNextCursor() throws {
    let node = filesNode(["a.py", "b/c.py"], total: 150, next: "CURSOR")

    let page = try #require(GitHub.parseFiles(node))

    #expect(page.paths == ["a.py", "b/c.py"])
    #expect(page.total == 150)
    #expect(page.next == "CURSOR")
  }

  @Test func theLastPageHasNoNextCursor() throws {
    let page = try #require(GitHub.parseFiles(filesNode(["a.py"], total: 101, next: nil)))

    #expect(page.next == nil)
  }

  @Test func nullFileNodesAreSkipped() throws {
    let page = try #require(GitHub.parseFiles(filesNode(["a.py", nil, "b.py"], total: 3, next: nil)))

    #expect(page.paths == ["a.py", "b.py"])
  }

  @Test func aNodeWithoutFilesIsNotAPage() {
    #expect(GitHub.parseFiles(["id": "IC_1"]) == nil)
  }

  @Test func filesQueriesReadAHundredPathsAPageWithTheirHeadAndBase() {
    for query in [GitHub.filesQuery, GitHub.filesPageQuery] {
      #expect(query.contains("files(first: 100"))
      #expect(query.contains("endCursor"))
      #expect(query.contains("totalCount"))
    }
    #expect(GitHub.filesQuery.contains("headRefOid"))
    #expect(GitHub.filesQuery.contains("baseRefName"))
    #expect(GitHub.filesPageQuery.contains("after:"))
  }

  @Test func approvalTeamsAreKeyedByReviewerAndSubmission() throws {
    let node: JSON = [
      "id": "PR_42",
      "latestOpinionatedReviews": [
        "nodes": [
          approvalNode("bob", "2026-11-01T00:00:00Z", teams: ["PostHog/hogql", "PostHog/team-devex"]),
          approvalNode("carol", "2026-11-02T00:00:00Z", teams: []),
        ]
      ],
    ]

    let teams = GitHub.parseApprovalTeams(node)

    let bob = try #require(teams.first { $0.author == "bob" })
    #expect(bob.submittedAt == "2026-11-01T00:00:00Z")
    #expect(bob.teams == ["PostHog/hogql", "PostHog/team-devex"])
    #expect(teams.first { $0.author == "carol" }?.teams == [])
  }

  @Test func theApprovalTeamsQueryReadsOnBehalfOf() {
    #expect(GitHub.approvalTeamsQuery.contains("onBehalfOf(first: 10)"))
    #expect(GitHub.approvalTeamsQuery.contains("combinedSlug"))
  }
}

// MARK: - Requirement

private func onConfig(_ text: String) throws -> CodeOwnersConfig {
  .on(try #require(CodeOwnersFile.parse(text)))
}

private func ownerRequirement(_ text: String, _ paths: [String], total: Int? = nil) throws -> CodeOwnerRequirement? {
  CodeOwners.requirement(try onConfig(text), paths: paths, total: total ?? paths.count)
}

private func groupSets(_ requirement: CodeOwnerRequirement?) -> Set<Set<String>>? {
  requirement.map { Set($0.groups.map(Set.init)) }
}

private let teamsFile = """
  *.py @PostHog/team-backend
  frontend/ @PostHog/team-frontend
  posthog/hogql/** @PostHog/hogql @alice
  posthog/hogql/legacy/** @alice @PostHog/hogql
  /unowned/
  *.go docs@example.com
  /shadowed/ docs@example.com
  /shadowed/ @PostHog/team-shadow
  /mixed/ @bob docs@example.com
  """

@Suite struct CodeOwnerRequirementBuilding {
  @Test func eachDistinctOwnerSetIsAGroup() throws {
    let r = try ownerRequirement(teamsFile, ["api.py", "frontend/src/app.tsx", "posthog/hogql/parser.ts"])

    #expect(
      groupSets(r) == [["@PostHog/team-backend"], ["@PostHog/team-frontend"], ["@PostHog/hogql", "@alice"]])
  }

  @Test func identicalOwnerSetsAreOneGroup() throws {
    let paths = ["posthog/hogql/a.ts", "posthog/hogql/b.ts", "posthog/hogql/legacy/c.ts"]

    let r = try #require(try ownerRequirement(teamsFile, paths))

    #expect(r.groups.count == 1)
  }

  @Test func noMatchingFileIsNoRequirement() throws {
    #expect(try ownerRequirement(teamsFile, ["README.md", "docs/a.md"]) == nil)
  }

  @Test func aFileWhoseOnlyMatchClearsOwnershipIsNoRequirement() throws {
    #expect(try ownerRequirement(teamsFile, ["unowned/a.md"]) == nil)
  }

  @Test func aClearedFileAddsNoGroup() throws {
    let r = try ownerRequirement(teamsFile, ["unowned/a.md", "frontend/a.tsx"])

    #expect(groupSets(r) == [["@PostHog/team-frontend"]])
  }

  @Test(arguments: [["cmd/main.go"], ["mixed/a.md"], ["api.py", "cmd/main.go"]])
  func anEmailOwnerInAMatchedGroupMakesTheRequirementUnknown(_ paths: [String]) throws {
    #expect(try ownerRequirement(teamsFile, paths) == nil)
  }

  @Test(arguments: [["api.py"], ["shadowed/a.md"]])
  func anEmailOwnerOnALineThatOwnsNoChangedFileIsNotRefused(_ paths: [String]) throws {
    #expect(try ownerRequirement(teamsFile, paths) != nil)
  }

  @Test func aTotalOverTheThousandFileCapIsUnknown() throws {
    let paths = (0..<1000).map { "f\($0).py" }

    #expect(try ownerRequirement(teamsFile, paths, total: 1001) == nil)
  }

  @Test func exactlyAThousandFilesAreRead() throws {
    let paths = (0..<1000).map { "f\($0).py" }

    #expect(try ownerRequirement(teamsFile, paths, total: 1000) != nil)
  }

  @Test(arguments: [(99, 100), (101, 100)])
  func aPathCountThatDiffersFromTheTotalIsUnknown(_ count: Int, _ total: Int) throws {
    let paths = (0..<count).map { "f\($0).py" }

    #expect(try ownerRequirement(teamsFile, paths, total: total) == nil)
  }

  @Test func noChangedFilesIsNoRequirement() throws {
    #expect(try ownerRequirement(teamsFile, [], total: 0) == nil)
  }

  @Test func anOffConfigIsNoRequirement() throws {
    let off = try GitHub.parseCodeOwnersConfig(configResponse(rules: []))

    #expect(CodeOwners.requirement(off, paths: ["api.py"], total: 1) == nil)
  }
}

// MARK: - Satisfaction and parity

private func ownedPR(
  _ groups: [[String]], verdicts: [Review] = [], decision: ReviewDecision? = .reviewRequired,
  requests: [String] = [], author: String = "haacked", state: PRState = .open, draft: Bool = false
) -> PullRequest {
  var pr = samplePR(state: state, draft: draft, reviewDecision: decision, verdicts: verdicts)
  pr.author = author
  pr.codeOwners = CodeOwnerRequirement(groups: groups)
  pr.codeOwnerRequests = requests
  return pr
}

private func ownerVerdict(
  _ author: String, _ state: String = "APPROVED", teams: [String]? = [], on commit: String? = samplePRHead
) -> Review {
  var review = sampleVerdict(author, state, on: commit)
  review.teams = teams
  return review
}

private let hogqlTeam = [["@PostHog/hogql"]]

@Suite struct CodeOwnerSatisfaction {
  @Test func aTeamApprovalOnBehalfOfTheOwnerAtTheHeadIsApproved() throws {
    let pr = ownedPR(hogqlTeam, verdicts: [ownerVerdict("bob", teams: ["PostHog/hogql"])])

    let status = try #require(CodeOwnerStatus(pr))

    #expect(status.groups.map(\.approved) == [true])
    #expect(status.satisfied)
  }

  @Test(arguments: [
    ownerVerdict("bob", teams: []),
    ownerVerdict("bob", teams: nil),
    ownerVerdict("bob", teams: ["PostHog/team-devex"]),
    ownerVerdict("bob", teams: ["PostHog/team-devex"], on: "olderhead"),
    ownerVerdict("bob", "CHANGES_REQUESTED", teams: ["PostHog/hogql"]),
    ownerVerdict("bob", "DISMISSED", teams: ["PostHog/hogql"]),
    ownerVerdict("bob", "COMMENTED", teams: ["PostHog/hogql"]),
    ownerVerdict("hogql", teams: []),
  ])
  func aTeamGroupWaitsWithoutAnApprovalOnItsBehalfAtTheHead(_ verdict: Review) throws {
    let status = try #require(CodeOwnerStatus(ownedPR(hogqlTeam, verdicts: [verdict])))

    #expect(status.groups.map(\.approved) == [false])
    #expect(!status.satisfied)
  }

  @Test func aUserOwnersApprovalIsApproved() throws {
    let status = try #require(CodeOwnerStatus(ownedPR([["@alice"]], verdicts: [ownerVerdict("alice")])))

    #expect(status.groups.map(\.approved) == [true])
  }

  @Test(arguments: [
    ownerVerdict("bob", teams: ["PostHog/hogql"]),
    ownerVerdict("bob", on: "olderhead"),
    ownerVerdict("alice", "CHANGES_REQUESTED"),
  ])
  func aUserGroupWaitsWithoutTheUsersApprovalAtTheHead(_ verdict: Review) throws {
    let status = try #require(CodeOwnerStatus(ownedPR([["@hogql"], ["@alice"]], verdicts: [verdict])))

    #expect(status.groups.map(\.approved) == [false, false])
  }

  @Test(arguments: [
    ([["@alice"]], ownerVerdict("alice")),
    ([["@alice", "@PostHog/hogql"]], ownerVerdict("alice")),
    (hogqlTeam, ownerVerdict("alice", teams: ["PostHog/hogql"])),
  ])
  func thePRAuthorsOwnApprovalDoesNotCount(_ groups: [[String]], _ verdict: Review) throws {
    let status = try #require(CodeOwnerStatus(ownedPR(groups, verdicts: [verdict], author: "alice")))

    #expect(status.groups.map(\.approved) == [false])
  }

  @Test func eitherOwnerOfALineApprovesItsGroup() throws {
    let pr = ownedPR([["@alice", "@PostHog/hogql"]], verdicts: [ownerVerdict("bob", teams: ["PostHog/hogql"])])

    #expect(CodeOwnerStatus(pr)?.groups.map(\.approved) == [true])
  }

  @Test(arguments: [
    ([["@PostHog/HogQL"]], ownerVerdict("bob", teams: ["posthog/hogql"])),
    ([["@posthog/hogql"]], ownerVerdict("bob", teams: ["PostHog/HOGQL"])),
    ([["@Alice"]], ownerVerdict("alice")),
    ([["@alice"]], ownerVerdict("ALICE")),
  ])
  func loginsAndSlugsMatchWhateverTheirCase(_ groups: [[String]], _ verdict: Review) throws {
    #expect(CodeOwnerStatus(ownedPR(groups, verdicts: [verdict]))?.groups.map(\.approved) == [true])
  }

  @Test func satisfiedNeedsEveryGroupApproved() throws {
    let groups = [["@PostHog/hogql"], ["@alice"]]

    let partly = try #require(CodeOwnerStatus(ownedPR(groups, verdicts: [ownerVerdict("alice")])))
    let fully = try #require(
      CodeOwnerStatus(
        ownedPR(groups, verdicts: [ownerVerdict("alice"), ownerVerdict("bob", teams: ["PostHog/hogql"])])))

    #expect(!partly.satisfied)
    #expect(fully.satisfied)
  }

  @Test func groupsSortByTheirOwnersIgnoringCaseAndKeepTheirSpelling() throws {
    let pr = ownedPR([["@zed"], ["@PostHog/hogql"], ["@Bob"], ["@alice", "@PostHog/team-x"]])

    let status = try #require(CodeOwnerStatus(pr))

    #expect(status.groups.map(\.owners) == [["@alice", "@PostHog/team-x"], ["@Bob"], ["@PostHog/hogql"], ["@zed"]])
  }
}

@Suite struct CodeOwnerParityGuards {
  /// GitHub's APPROVED includes the code owner rule, so a waiting group
  /// means sbd's view is wrong.
  @Test(arguments: [
    [ownerVerdict("bob", teams: ["PostHog/hogql"])],
    [ownerVerdict("bob", teams: ["PostHog/hogql"]), ownerVerdict("alice", on: "olderhead")],
    [],
  ])
  func anApprovedDecisionWithAWaitingGroupShowsNothing(_ verdicts: [Review]) {
    #expect(CodeOwnerStatus(ownedPR(hogqlTeam + [["@alice"]], verdicts: verdicts, decision: .approved)) == nil)
  }

  @Test func anApprovedDecisionWithEveryGroupApprovedIsSatisfied() throws {
    let pr = ownedPR(hogqlTeam, verdicts: [ownerVerdict("bob", teams: ["PostHog/hogql"])], decision: .approved)

    #expect(try #require(CodeOwnerStatus(pr)).satisfied)
  }

  /// GitHub can still want other reviews, so another decision alone does not refuse.
  @Test(arguments: [ReviewDecision.reviewRequired, .changesRequested])
  func anotherDecisionWithAWaitingGroupIsShown(_ decision: ReviewDecision) {
    #expect(CodeOwnerStatus(ownedPR(hogqlTeam, decision: decision)) != nil)
  }

  /// GitHub keeps an older commit's approval on a base that keeps stale
  /// reviews. sbd does not read that setting, so the owner's group may not wait.
  @Test(arguments: [
    (hogqlTeam, ownerVerdict("bob", teams: ["PostHog/hogql"], on: "olderhead")),
    (hogqlTeam, ownerVerdict("bob", teams: ["PostHog/hogql"], on: nil)),
    ([["@alice"]], ownerVerdict("alice", on: "olderhead")),
  ])
  func anOlderApprovalByAWaitingGroupsOwnerShowsNothing(_ groups: [[String]], _ verdict: Review) {
    for decision in [ReviewDecision.reviewRequired, .changesRequested] {
      #expect(CodeOwnerStatus(ownedPR(groups + [["@carol"]], verdicts: [verdict], decision: decision)) == nil)
    }
  }

  @Test func anOlderApprovalOfAGroupThatAnotherOwnerApprovedAtTheHeadIsShown() throws {
    let verdicts = [
      ownerVerdict("bob", teams: ["PostHog/hogql"]), ownerVerdict("dave", teams: ["PostHog/hogql"], on: "olderhead"),
    ]

    let status = try #require(CodeOwnerStatus(ownedPR(hogqlTeam + [["@carol"]], verdicts: verdicts)))

    #expect(status.groups.map(\.approved) == [false, true])
  }

  @Test(arguments: ["@PostHog/other", "@bob"])
  func aCodeOwnerRequestForAnOwnerInNoGroupShowsNothing(_ request: String) {
    let pr = ownedPR(hogqlTeam + [["@alice"]], requests: ["@PostHog/hogql", request])

    #expect(CodeOwnerStatus(pr) == nil)
  }

  @Test(arguments: [["@PostHog/hogql"], ["@posthog/HOGQL"], ["@alice"], ["@PostHog/hogql", "@Alice"]])
  func codeOwnerRequestsForOwnersInTheGroupsAreShown(_ requests: [String]) {
    let pr = ownedPR([["@PostHog/hogql"], ["@alice", "@PostHog/team-x"]], requests: requests)

    #expect(CodeOwnerStatus(pr) != nil)
  }

  @Test(arguments: [PRState.merged, .closed])
  func aMergedOrClosedPRShowsNothing(_ state: PRState) {
    #expect(CodeOwnerStatus(ownedPR(hogqlTeam, state: state)) == nil)
  }

  @Test func aDraftPRIsShown() {
    #expect(CodeOwnerStatus(ownedPR(hogqlTeam, draft: true)) != nil)
  }

  /// Without the author, sbd cannot leave out the author's own approval.
  @Test func aPRWhoseAuthorWasNotReadShowsNothing() {
    var pr = ownedPR(hogqlTeam)
    pr.author = nil

    #expect(CodeOwnerStatus(pr) == nil)
  }

  /// Without every code owner request, guard (b) cannot run.
  @Test func aPRWhoseCodeOwnerRequestsWereNotReadShowsNothing() {
    var pr = ownedPR(hogqlTeam)
    pr.codeOwnerRequests = nil

    #expect(CodeOwnerStatus(pr) == nil)
  }

  @Test func aPRWithoutARequirementShowsNothing() {
    var pr = ownedPR(hogqlTeam)
    pr.codeOwners = nil

    #expect(CodeOwnerStatus(pr) == nil)
  }

  @Test func aRequirementWithNoGroupsShowsNothing() {
    #expect(CodeOwnerStatus(ownedPR([])) == nil)
  }
}

// MARK: - Text

private func ownerStatus(_ groups: [([String], Bool)]) -> CodeOwnerStatus {
  CodeOwnerStatus(
    satisfied: groups.allSatisfy { $0.1 }, groups: groups.map { CodeOwnerGroup(owners: $0.0, approved: $0.1) })
}

@Suite struct CodeOwnerText {
  @Test func oneWaitingGroupNamesItsOwner() {
    let status = ownerStatus([(["@PostHog/team-feature-flags"], false)])

    #expect(status.text(separator: "\n") == "Code owner review required: @PostHog/team-feature-flags")
  }

  @Test func oneApprovedGroupNamesItsOwner() {
    let status = ownerStatus([(["@PostHog/team-feature-flags"], true)])

    #expect(status.text(separator: "\n") == "Code owner review approved: @PostHog/team-feature-flags")
  }

  @Test func oneGroupWithTwoOwnersNamesEither() {
    let status = ownerStatus([(["@alice", "@PostHog/team-x"], false)])

    #expect(status.text(separator: "\n") == "Code owner review required: @alice or @PostHog/team-x")
  }

  @Test func severalPartlyApprovedGroupsCountTheApprovalsAndListEachGroup() {
    let status = ownerStatus([
      (["@alice", "@PostHog/team-x"], false), (["@PostHog/hogql"], true), (["@PostHog/team-devex"], false),
    ])

    #expect(
      status.text(separator: "\n") == """
        Code owner review required (1 of 3 approved)
        @alice or @PostHog/team-x: waiting
        @PostHog/hogql: approved
        @PostHog/team-devex: waiting
        """)
  }

  @Test func severalApprovedGroupsSayApproved() {
    let status = ownerStatus([(["@alice"], true), (["@PostHog/hogql"], true), (["@PostHog/team-devex"], true)])

    #expect(
      status.text(separator: "\n") == """
        Code owner review approved (3 of 3)
        @alice: approved
        @PostHog/hogql: approved
        @PostHog/team-devex: approved
        """)
  }

  @Test func sbGetJoinsTheSameLinesWithSemicolons() {
    let status = ownerStatus([(["@PostHog/hogql"], true), (["@PostHog/team-devex"], false)])

    #expect(
      status.text(separator: "; ")
        == "Code owner review required (1 of 2 approved); @PostHog/hogql: approved; @PostHog/team-devex: waiting")
  }

  @Test func twelveGroupsAreAllListed() {
    let status = ownerStatus((1...12).map { (["@PostHog/team-\(String(format: "%02d", $0))"], $0 <= 5) })

    let lines = status.text(separator: "\n").components(separatedBy: "\n")

    #expect(lines.first == "Code owner review required (5 of 12 approved)")
    #expect(lines.count == 13)
    for i in 1...12 {
      #expect(lines.contains { $0.hasPrefix("@PostHog/team-\(String(format: "%02d", i)):") }, "team \(i)")
    }
  }
}

// MARK: - Model

@Suite struct CodeOwnerModel {
  @Test func theStatusEncodesSatisfiedAndOwnerGroups() throws {
    let status = ownerStatus([(["@PostHog/hogql"], false)])

    let json = JSON.parse(try JSONCoding.encode(status))

    #expect(json == ["satisfied": false, "groups": [["owners": ["@PostHog/hogql"], "approved": false]]])
  }

  @Test func thePRsRequirementEncodesItsGroups() throws {
    let json = JSON.parse(try JSONCoding.encode(ownedPR(hogqlTeam)))

    #expect(json?["codeOwners"] == ["groups": [["@PostHog/hogql"]]])
  }

  @Test func theSummaryCarriesTheStatus() {
    let pr = ownedPR(hogqlTeam, verdicts: [ownerVerdict("bob", teams: ["PostHog/hogql"])])

    #expect(PRSummary(pr).codeOwners == CodeOwnerStatus(pr))
    #expect(PRSummary(pr).codeOwners != nil)
  }

  @Test func aSummaryWithoutARequirementHasNoCodeOwnersKey() throws {
    let json = JSON.parse(try JSONCoding.encode(PRSummary(samplePR())))

    #expect(json?["codeOwners"] == nil)
  }

  /// Acknowledgment compares reason strings, so the requirement must not
  /// change the PR's line.
  @Test func theRequirementDoesNotChangeTheSummaryLine() {
    var without = ownedPR(hogqlTeam)
    without.codeOwners = nil

    #expect(PRSummary(ownedPR(hogqlTeam)).line == PRSummary(without).line)
  }

  @Test func aPRThatAnOlderSbdRecordedDecodesWithoutTheNewFields() throws {
    let text = """
      {"id": "PR_42", "number": 42, "url": "https://github.com/acme/widgets/pull/42", "repo": "acme/widgets",
       "title": "", "state": "OPEN", "draft": false, "head": "feature", "headSha": "head1", "base": "main",
       "verdicts": [{"author": "alice", "state": "APPROVED", "commit": "head1"}], "reviews": [], "labels": [],
       "reviewRequests": ["hogql"]}
      """

    let pr = try JSONCoding.decode(PullRequest.self, from: text)

    #expect(pr.author == nil)
    #expect(pr.codeOwners == nil)
    #expect(pr.codeOwnerRequests == nil)
    #expect(pr.verdicts.first?.teams == nil)
  }
}

// MARK: - Status parsing

@Suite struct CodeOwnerStatusParsing {
  @Test func readsThePRsAuthor() throws {
    let node = try editedNode(18303, ["author": ["login": "haacked"]])

    #expect(try #require(GitHub.parsePR(node)).pr.author == "haacked")
  }

  @Test func codeOwnerRequestsAreTheRequestsGitHubMadeAsCodeOwner() throws {
    let requests: JSON = [
      "nodes": [
        [
          "asCodeOwner": true,
          "requestedReviewer": ["__typename": "Team", "slug": "hogql", "combinedSlug": "PostHog/hogql"],
        ],
        ["asCodeOwner": true, "requestedReviewer": ["__typename": "User", "login": "alice"]],
        [
          "asCodeOwner": false,
          "requestedReviewer": ["__typename": "Team", "slug": "flags", "combinedSlug": "PostHog/flags"],
        ],
        ["asCodeOwner": false, "requestedReviewer": ["__typename": "User", "login": "bob"]],
      ]
    ]
    let node = try editedNode(18303, ["reviewRequests": requests])

    let pr = try #require(GitHub.parsePR(node)).pr

    #expect(pr.codeOwnerRequests == ["@PostHog/hogql", "@alice"])
    #expect(pr.reviewRequests == ["hogql", "alice", "flags", "bob"])
  }

  /// A request that sbd cannot name, or one that GitHub did not return,
  /// could be a code owner that no group names.
  @Test(
    arguments: [
      [
        "totalCount": 21,
        "nodes": [["asCodeOwner": false, "requestedReviewer": ["__typename": "User", "login": "bob"]]],
      ],
      ["nodes": [["asCodeOwner": true, "requestedReviewer": ["__typename": "Team", "slug": "hogql"]]]],
      ["nodes": [["asCodeOwner": true, "requestedReviewer": .null]]],
      ["nodes": [.null]],
      ["nodes": .null],
      .null,
    ] as [JSON])
  func codeOwnerRequestsThatCannotAllBeNamedAreUnread(_ requests: JSON) throws {
    let node = try editedNode(18303, ["reviewRequests": requests])

    #expect(try #require(GitHub.parsePR(node)).pr.codeOwnerRequests == nil)
  }

  @Test func aCompleteRequestListIsRead() throws {
    let requests: JSON = [
      "totalCount": 1,
      "nodes": [["asCodeOwner": true, "requestedReviewer": ["__typename": "User", "login": "alice"]]],
    ]
    let node = try editedNode(18303, ["reviewRequests": requests])

    #expect(try #require(GitHub.parsePR(node)).pr.codeOwnerRequests == ["@alice"])
  }

  @Test func aNodeWithoutReviewRequestsLeavesCodeOwnerRequestsUnread() throws {
    #expect(try #require(GitHub.parsePR(try editedNode(18303, [:]))).pr.codeOwnerRequests == nil)
  }

  @Test func theStatusReadLeavesTheRequirementUnset() throws {
    let node = try editedNode(18303, ["author": ["login": "haacked"]])

    #expect(try #require(GitHub.parsePR(node)).pr.codeOwners == nil)
  }

  /// onBehalfOf inside latestOpinionatedReviews across 20 PRs would raise the
  /// chunk cost from 1 point to about 5.
  @Test func theStatusQueryReadsCodeOwnerRequestsButNotApprovalTeams() {
    #expect(GitHub.statusQuery.contains("asCodeOwner"))
    #expect(GitHub.statusQuery.contains("combinedSlug"))
    #expect(GitHub.statusQuery.contains("author { login }"))
    #expect(!GitHub.statusQuery.contains("onBehalfOf"))
  }
}
