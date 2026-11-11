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
}
