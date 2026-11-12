import SwitchboardCore
import Testing

@testable import SwitchboardApp

@Suite struct NewSessionFormTests {
  static let alpha = KnownRepo(path: "/Users/me/dev/alpha", name: "alpha", used: 20)
  static let beta = KnownRepo(path: "/Users/me/dev/beta", name: "beta", used: 30)

  /// The sheet first offers the list kept from its last opening, whose order is stale once a session
  /// started in another repository.
  @Test func sbdsListReplacesTheRepoSelectedFromTheKeptList() {
    let form = NewSessionView.Form()

    form.offer([Self.alpha, Self.beta])
    form.offer([Self.beta, Self.alpha])

    #expect(form.repo == Self.beta)
  }

  @Test func sbdsListKeepsTheRepoThatTheUserPicked() {
    let form = NewSessionView.Form()

    form.offer([Self.alpha, Self.beta])
    form.pick(Self.alpha)
    form.offer([Self.beta, Self.alpha])

    #expect(form.repo == Self.alpha)
  }

  @Test func selectsNothingUntilAListArrives() {
    let form = NewSessionView.Form()

    form.offer(nil)
    #expect(form.repo == nil)
    form.offer([Self.alpha])
    #expect(form.repo == Self.alpha)
  }

  @Test func requestIsNilWithoutARepo() {
    #expect(NewSessionView.Form().request(worktree: false) == nil)
  }

  @Test func requestTrimsFieldsAndDropsBlankOnes() throws {
    let form = NewSessionView.Form()
    form.pick(Self.alpha)
    form.name = "  fix  "
    form.prompt = " \n "
    form.account = "  "

    let r = try #require(form.request(worktree: false))

    #expect(r.path == Self.alpha.path)
    #expect(r.name == "fix")
    #expect(r.prompt == nil)
    #expect(r.account == nil)
  }

  @Test func requestSendsTheBranchOnlyWithAWorktree() throws {
    let form = NewSessionView.Form()
    form.pick(Self.alpha)
    form.branch = "me/fix"

    #expect(try #require(form.request(worktree: true)).branch == "me/fix")
    #expect(try #require(form.request(worktree: true)).worktree == true)
    #expect(try #require(form.request(worktree: false)).branch == nil)
  }

  @Test func requestCarriesThePresetGroup() throws {
    let grouped = NewSessionView.Form(group: "g1")
    grouped.pick(Self.alpha)
    let plain = NewSessionView.Form()
    plain.pick(Self.alpha)

    #expect(try #require(grouped.request(worktree: false)).group == "g1")
    #expect(try #require(plain.request(worktree: false)).group == nil)
  }
}
