import SwitchboardCore
import Testing

@Suite struct SelectionProjection {
  let node = FakeGitHub.recordedPR()

  @Test func statusQueryDropsTheBaseFields() throws {
    let selection = try #require(Selection(query: GitHub.statusQuery, on: "PullRequest"))
    let projected = selection.project(node)
    #expect(projected["baseRef"] == nil)
    #expect(projected["number"] != nil)
    #expect(projected["firstComments"]?["nodes"]?.array?.first?["id"] != nil)
    #expect(projected["reviews"]?["nodes"]?.array?.first?["author"]?["login"] != nil)
  }

  @Test func baseQueryKeepsOnlyTheBaseFields() throws {
    let selection = try #require(Selection(query: GitHub.baseQuery, on: "PullRequest"))
    let projected = try #require(selection.project(node).object)
    #expect(Set(projected.keys) == ["id", "baseRefName", "repository", "baseRef"])
    #expect(projected["repository"]?["defaultBranchRef"]?["name"] != nil)
    #expect(projected["repository"]?["nameWithOwner"] == nil)
    #expect(projected["baseRef"]?["associatedPullRequests"]?["nodes"]?.array?.first?["number"] != nil)
  }

  @Test func aSelectedFieldTheNodeLacksStaysAbsent() throws {
    let selection = try #require(Selection(query: "{ ... on PullRequest { id missing } }", on: "PullRequest"))
    #expect(selection.project(["id": "x", "extra": 1]) == ["id": "x"])
  }
}
