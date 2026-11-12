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

  // MARK: The new request

  @Test func theRequestLeavesOutBlankFields() throws {
    let form = NewSessionView.Form()
    form.pick(Self.alpha)
    form.branch = "  "
    form.name = "\n"
    form.prompt = " \n "
    form.account = ""

    let request = try #require(form.request(worktree: true))

    #expect(request.path == Self.alpha.path)
    #expect(request.worktree == true)
    #expect(request.branch == nil)
    #expect(request.name == nil)
    #expect(request.prompt == nil)
    #expect(request.account == nil)
  }

  @Test func theRequestTrimsEachField() throws {
    let form = NewSessionView.Form()
    form.pick(Self.alpha)
    form.branch = " haacked/fix \n"
    form.name = " fix "
    form.prompt = "\nFix the bug.\n"
    form.account = " .claude-max "

    let request = try #require(form.request(worktree: true))

    #expect(request.branch == "haacked/fix")
    #expect(request.name == "fix")
    #expect(request.prompt == "Fix the bug.")
    #expect(request.account == ".claude-max")
  }

  @Test func theRequestHasNoBranchWithoutAWorktree() throws {
    let form = NewSessionView.Form()
    form.pick(Self.alpha)
    form.branch = "haacked/fix"

    let request = try #require(form.request(worktree: false))

    #expect(request.worktree == false)
    #expect(request.branch == nil)
  }

  @Test func thereIsNoRequestWithoutARepo() {
    let form = NewSessionView.Form()
    form.name = "fix"

    #expect(form.request(worktree: false) == nil)
  }
}
