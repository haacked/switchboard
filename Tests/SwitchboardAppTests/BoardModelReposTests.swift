import AppKit
import SwitchboardCore
import Testing

@testable import SwitchboardApp

@MainActor
@Suite struct BoardModelRepos {
  static let alpha = KnownRepo(path: "/Users/me/dev/alpha", name: "alpha", used: 20)
  static let beta = KnownRepo(path: "/Users/me/dev/beta", name: "beta", used: 30)

  /// A re-added repository moves to the front. The model removes its older row, so no two rows share an id.
  @Test func addRepoMovesAKnownRepoFirstWithoutADuplicate() async throws {
    let model = offlineModel()
    model.knownRepos = [Self.beta, Self.alpha]
    let added = try JSON(encoding: Self.alpha)
    model.send = { op, _ in op == "repo-add" ? added : .null }

    model.addRepo(Self.alpha.path) { _ in }
    await settle { model.knownRepos?.first == Self.alpha }

    #expect(model.knownRepos == [Self.alpha, Self.beta])
  }

  /// The next sheet's `repos` request waits behind `new`, so the kept list must already have the repository first.
  @Test func createMovesTheSessionsRepoFirstBeforeSbdAnswers() {
    let model = offlineModel()
    model.knownRepos = [Self.beta, Self.alpha]
    model.send = { _, _ in .null }

    model.create(NewSession(path: Self.alpha.path))

    #expect(model.knownRepos == [Self.alpha, Self.beta])
  }

  @Test func addRepoLeavesTheListAsItIsWhenSbdRefusesThePath() async {
    let model = offlineModel()
    model.knownRepos = [Self.alpha]
    model.send = { op, _ in
      if op == "repo-add" { throw APIError("/tmp isn't in a git repository") }
      return .null
    }
    var refusal: String?

    model.addRepo("/tmp") { result in
      if case .failure(let error) = result { refusal = "\(error)" }
    }
    await settle { refusal != nil }

    #expect(refusal?.contains("isn't in a git repository") == true)
    #expect(model.knownRepos == [Self.alpha])
  }

  @Test func loadReposReplacesTheListWithSbdsAnswer() async throws {
    let model = offlineModel()
    model.knownRepos = [Self.alpha]
    let answer = try JSON(encoding: [Self.beta, Self.alpha])
    model.send = { op, _ in op == "repos" ? answer : .null }

    model.loadRepos()
    await settle { model.knownRepos?.first == Self.beta }

    #expect(model.knownRepos == [Self.beta, Self.alpha])
  }

  /// A list that never loaded becomes empty, so the picker stops showing "Loading…".
  @Test func loadReposShowsAnEmptyListWhenSbdFailsBeforeAnyLoad() async {
    let model = offlineModel()
    model.send = { op, _ in
      if op == "repos" { throw Boom() }
      return .null
    }

    model.loadRepos()
    await settle { model.knownRepos != nil }

    #expect(model.knownRepos == [])
  }

  /// The model sends requests in order on one queue, so the add's answer arrives after the failed load.
  @Test func loadReposKeepsTheListWhenSbdFails() async throws {
    let model = offlineModel()
    model.knownRepos = [Self.alpha]
    let added = try JSON(encoding: Self.beta)
    model.send = { op, _ in
      if op == "repos" { throw Boom() }
      return op == "repo-add" ? added : .null
    }

    model.loadRepos()
    model.addRepo(Self.beta.path) { _ in }
    await settle { model.knownRepos?.first == Self.beta }

    #expect(model.knownRepos == [Self.beta, Self.alpha])
  }
}
