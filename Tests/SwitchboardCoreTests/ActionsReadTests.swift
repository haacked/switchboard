import Testing

@testable import SwitchboardCore

/// A PR node of an actions response whose last commit has suites with `statuses`.
private func actionsNode(
  oid: String = "abc", checks: String? = "SUCCESS", statuses: [String], hasNextPage: JSON? = false
) -> JSON {
  var suites: [String: JSON] = ["nodes": .array(statuses.map { ["status": .string($0)] })]
  if let hasNextPage { suites["pageInfo"] = ["hasNextPage": hasNextPage] }
  let commit: JSON = [
    "oid": .string(oid), "statusCheckRollup": checks.map { ["state": .string($0)] } ?? .null,
    "checkSuites": .object(suites),
  ]
  return ["id": "PR_1", "commits": ["nodes": [["commit": commit]]]]
}

@Suite struct ActionsReadTests {
  @Test func everySuiteCompletedOnOnePageIsACompletedRun() throws {
    let parsed = try #require(GitHub.parseActions(actionsNode(statuses: ["COMPLETED", "COMPLETED"])))

    #expect(parsed.id == "PR_1")
    #expect(parsed.read == ActionsRead(sha: "abc", checks: "SUCCESS", completed: true))
  }

  @Test(arguments: [
    // An external status that reports before CI queues: no Actions suite yet.
    actionsNode(statuses: []),
    actionsNode(statuses: ["COMPLETED", "IN_PROGRESS"]),
    actionsNode(statuses: ["QUEUED"]),
    // The read can't show that the suites on later pages completed.
    actionsNode(statuses: ["COMPLETED"], hasNextPage: true),
    actionsNode(statuses: ["COMPLETED"], hasNextPage: nil),
  ])
  func aReadThatCantShowEverySuiteCompletedIsNotACompletedRun(_ node: JSON) throws {
    #expect(try #require(GitHub.parseActions(node)).read.completed == false)
  }

  @Test func aNodeThatIsNotAPRParsesToNil() {
    #expect(GitHub.parseActions(.null) == nil)
  }

  @Test(arguments: [
    (ActionsRead(sha: "abc", checks: "SUCCESS", completed: true), true),
    (ActionsRead(sha: "abc", checks: "SUCCESS", completed: false), false),
    // A read of another commit, as when a push lands between the two reads.
    (ActionsRead(sha: "old", checks: "SUCCESS", completed: true), false),
    // The rollup moved between the status read and the actions read.
    (ActionsRead(sha: "abc", checks: "FAILURE", completed: true), false),
  ])
  func aFinishedRunMatchesThePRsHeadAndRollup(_ read: ActionsRead, _ shows: Bool) {
    let pr = PullRequest(id: "PR_1", number: 1, url: "", repo: "o/r", headSha: "abc", checks: "SUCCESS")

    #expect(read.showsFinishedRun(of: pr) == shows)
  }
}
