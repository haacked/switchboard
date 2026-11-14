import Foundation
import SwitchboardCore
import Testing

@testable import SwitchboardApp

@Suite struct NewSessionFormTests {
  static let alpha = KnownRepo(path: "/Users/me/dev/alpha", name: "alpha", used: 20)
  static let beta = KnownRepo(path: "/Users/me/dev/beta", name: "beta", used: 30)

  /// A group with the given account folder, or none.
  static func group(_ id: String, account: String? = nil) -> GroupSummary {
    var g = GroupSummary(SessionGroup(id: id, name: id, created: 0), sessions: [])
    g.account = account
    return g
  }

  /// A work session in group `g1` whose main checkout is `checkout`.
  static func member(_ checkout: String, group: String = "g1") -> SessionSummary {
    var s = needsItem(UUID().uuidString)
    s.group = group
    s.checkout = checkout
    return s
  }

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
    #expect(NewSessionView.Form().request(worktree: false, groups: []) == nil)
  }

  @Test func requestTrimsFieldsAndDropsBlankOnes() throws {
    let form = NewSessionView.Form()
    form.pick(Self.alpha)
    form.name = "  fix  "
    form.prompt = " \n "
    form.account = "  "

    let r = try #require(form.request(worktree: false, groups: []))

    #expect(r.path == Self.alpha.path)
    #expect(r.name == "fix")
    #expect(r.prompt == nil)
    #expect(r.account == nil)
  }

  @Test func requestSendsTheBranchOnlyWithAWorktree() throws {
    let form = NewSessionView.Form()
    form.pick(Self.alpha)
    form.branch = "me/fix"

    #expect(try #require(form.request(worktree: true, groups: [])).branch == "me/fix")
    #expect(try #require(form.request(worktree: true, groups: [])).worktree == true)
    #expect(try #require(form.request(worktree: false, groups: [])).branch == nil)
  }

  @Test func requestCarriesThePresetGroup() throws {
    let grouped = NewSessionView.Form(group: "g1")
    grouped.pick(Self.alpha)
    let plain = NewSessionView.Form()
    plain.pick(Self.alpha)

    #expect(try #require(grouped.request(worktree: false, groups: [])).group == "g1")
    #expect(try #require(plain.request(worktree: false, groups: [])).group == nil)
  }

  // MARK: Start in plan mode

  @Test func requestSendsNoPlanModeWhenTheToggleIsOff() throws {
    let form = NewSessionView.Form()
    form.pick(Self.alpha)

    #expect(try #require(form.request(worktree: false, groups: [])).planMode == nil)
  }

  @Test func requestSendsPlanModeWhenTheToggleIsOn() throws {
    let form = NewSessionView.Form()
    form.pick(Self.alpha)
    form.planMode = true

    #expect(try #require(form.request(worktree: false, groups: [])).planMode == true)
  }

  // MARK: The default repository for a group

  @Test func offerSelectsTheRepoMostOfTheGroupsSessionsUse() {
    let form = NewSessionView.Form(group: "g1")

    form.offer([Self.alpha, Self.beta], sessions: [Self.member(Self.beta.path), Self.member(Self.beta.path)])

    #expect(form.repo == Self.beta)
  }

  @Test func offerFallsBackToTheMostRecentRepoForAnEmptyGroup() {
    let form = NewSessionView.Form(group: "g1")

    form.offer([Self.alpha, Self.beta], sessions: [Self.member(Self.beta.path, group: "g2")])

    #expect(form.repo == Self.alpha)
  }

  /// Until the user picks, each offer re-applies the default, so a later list can move it.
  @Test func aLaterOfferReDefaultsUntilTheUserPicks() {
    let form = NewSessionView.Form(group: "g1")
    form.offer([Self.alpha, Self.beta], sessions: [Self.member(Self.beta.path)])
    #expect(form.repo == Self.beta)

    form.offer([Self.beta, Self.alpha], sessions: [Self.member(Self.alpha.path), Self.member(Self.alpha.path)])

    #expect(form.repo == Self.alpha)
  }

  @Test func choosingAGroupReDefaultsAnUnpickedRepo() {
    let form = NewSessionView.Form()
    form.offer([Self.alpha, Self.beta], sessions: [Self.member(Self.beta.path)])
    #expect(form.repo == Self.alpha)

    form.choose(group: "g1")

    #expect(form.repo == Self.beta)
  }

  @Test func choosingAGroupKeepsAPickedRepo() {
    let form = NewSessionView.Form()
    form.offer([Self.alpha, Self.beta], sessions: [Self.member(Self.beta.path)])
    form.pick(Self.alpha)

    form.choose(group: "g1")

    #expect(form.repo == Self.alpha)
  }

  // MARK: The account that Start sends

  /// The group's account is fixed, so the sheet sends none and sbd applies the group's.
  @Test func requestSendsNoAccountForAGroupWithAnAccount() throws {
    let form = NewSessionView.Form(group: "g1")
    form.pick(Self.alpha)
    form.account = ""

    let r = try #require(form.request(worktree: false, groups: [Self.group("g1", account: "/accounts/B")]))

    #expect(r.account == nil)
  }

  /// A Group change after an Account pick leaves the old account in the form, which must not be sent.
  @Test func requestDropsAStaleAccountWhenTheGroupHasOne() throws {
    let form = NewSessionView.Form(group: "g1")
    form.pick(Self.alpha)
    form.account = "/accounts/A"

    let r = try #require(form.request(worktree: false, groups: [Self.group("g1", account: "/accounts/B")]))

    #expect(r.account == nil)
  }

  @Test func requestSendsTheChosenAccountForAGroupWithoutOne() throws {
    let form = NewSessionView.Form(group: "g1")
    form.pick(Self.alpha)
    form.account = "/accounts/A"

    let r = try #require(form.request(worktree: false, groups: [Self.group("g1")]))

    #expect(r.account == "/accounts/A")
  }

  @Test(arguments: [nil, "g1"] as [String?])
  func requestSendsNoAccountWhenNoneIsChosen(group: String?) throws {
    let form = NewSessionView.Form(group: group)
    form.pick(Self.alpha)
    form.account = ""

    let r = try #require(form.request(worktree: false, groups: [Self.group("g1")]))

    #expect(r.account == nil)
  }

  @Test func theRequestOfANewTaskNamesTheConversationAsParent() throws {
    let form = NewSessionView.Form(parent: "m")
    form.pick(Self.alpha)

    let request = try #require(form.request(worktree: false, groups: []))

    #expect(request.parent == "m")
  }

  @Test func theRequestWithoutAParentNamesNone() throws {
    let form = NewSessionView.Form()
    form.pick(Self.alpha)

    let request = try #require(form.request(worktree: false, groups: []))

    #expect(request.parent == nil)
  }
}
