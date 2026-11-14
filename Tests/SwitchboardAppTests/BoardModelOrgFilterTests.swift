import AppKit
import Combine
import SwitchboardCore
import Testing

@testable import SwitchboardApp

/// A filter and the ids of `BoardModelOrgFilterTests.list` and `.followups` that it shows.
struct FilterShape: Sendable, CustomTestStringConvertible {
  var filter: OrgFilter
  var sessions: Set<String>
  var followups: [String]
  var testDescription: String { filter.isAll ? "All Orgs" : filter.keys.sorted().joined(separator: ",") }
}

/// All Orgs, one org, Local, an org with Local, another org, and an org with no sessions.
let everyFilterShape = [
  FilterShape(filter: OrgFilter(), sessions: ["ph1", "ph2", "hk", "lo", "un", "m", "c"], followups: ["fph", "fhk"]),
  FilterShape(filter: posthogOnly, sessions: ["ph1", "ph2", "un", "m", "c"], followups: ["fph"]),
  FilterShape(filter: OrgFilter(keys: [OrgFilter.localKey]), sessions: ["lo", "un", "m", "c"], followups: []),
  FilterShape(
    filter: OrgFilter(keys: ["posthog", OrgFilter.localKey]), sessions: ["ph1", "ph2", "lo", "un", "m", "c"],
    followups: ["fph"]),
  FilterShape(filter: OrgFilter(keys: ["haacked"]), sessions: ["hk", "un", "m", "c"], followups: ["fhk"]),
  FilterShape(filter: OrgFilter(keys: ["acme"]), sessions: ["un", "m", "c"], followups: []),
]

@MainActor
@Suite struct BoardModelOrgFilterTests {
  /// Two PostHog sessions, a haacked one, a Local one, one that sbd has not read, the Manager, and a chat.
  nonisolated static let list = [
    orgSession("ph1", "PostHog/posthog", state: .needsYou),
    orgSession("ph2", "PostHog/posthog-js"),
    orgSession("hk", "haacked/switchboard", state: .needsYou),
    orgSession("lo", nil, state: .needsYou),
    orgSession("un", nil, read: nil, state: .needsYou),
    needsItem("m", manager: true),
    chatItem("c", group: "g1"),
  ]
  nonisolated static let followups = [
    unstartedFollowup("fph", "PostHog/posthog"), unstartedFollowup("fhk", "haacked/x"),
  ]
  static let hidden: Set<String> = ["hk", "lo", "fhk"]

  func model(
    _ filter: OrgFilter, _ list: [SessionSummary] = list, followups: [SessionSummary]? = followups
  ) -> BoardModel {
    let model = orgFilterModel(filter)
    model.apply(.success(list), followups: followups)
    return model
  }

  // MARK: What the filter hides

  enum Shown: String, CaseIterable, Sendable {
    case sessions, followups, needsUser, triage, sidebarGroups, workBoard, repoLabels, board

    @MainActor func ids(_ model: BoardModel) -> Set<String> {
      switch self {
      case .sessions: Set(model.sessions.map(\.id))
      case .followups: Set(model.followups.map(\.id))
      case .needsUser: Set(model.needsUser.map(\.id))
      case .triage: Set(model.triage.map(\.id))
      case .sidebarGroups: Set(model.sidebarGroups.flatMap { $0.rows.map(\.id) })
      case .workBoard: Set(model.workBoard.map(\.id))
      case .repoLabels: Set(model.repoLabels.keys)
      case .board: Set(model.board.map(\.id))
      }
    }
  }

  @Test(arguments: Shown.allCases)
  func aPosthogFilterLeavesOutOtherOrgsAndLocal(_ shown: Shown) {
    let ids = shown.ids(model(posthogOnly))
    let all = shown.ids(model(OrgFilter()))

    #expect(ids == all.subtracting(Self.hidden), "\(shown.rawValue)")
  }

  @Test(arguments: Shown.allCases)
  func allOrgsLeavesOutNothingThatTodayShows(_ shown: Shown) {
    let filtered = shown.ids(model(OrgFilter()))
    let unfiltered = shown.ids(appliedModel(Self.list, followups: Self.followups))

    #expect(filtered == unfiltered, "\(shown.rawValue)")
  }

  @Test func theManagerAndAChatStayUnderAPosthogFilter() {
    let model = model(posthogOnly)

    #expect(model.managers.map(\.id) == ["m"])
    #expect(model.chat(of: "g1")?.id == "c")
    #expect(Set(model.sessions.map(\.id)) == ["ph1", "ph2", "un", "m", "c"])
    #expect(model.followups.map(\.id) == ["fph"])
  }

  @Test func aSessionThatSbdHasNotReadShowsUnderAPosthogFilter() {
    let model = model(posthogOnly)

    #expect(model.sessions.contains { $0.id == "un" })
    #expect(model.needsUser.contains { $0.id == "un" })
  }

  @Test func allSessionsAndAllFollowupsHoldSbdsLists() {
    let model = model(posthogOnly)

    #expect(model.allSessions == Self.list)
    #expect(model.allFollowups == Self.followups)
  }

  // MARK: What each filter shape shows

  @Test(arguments: everyFilterShape)
  func eachFilterShowsItsSessionsAfterARefresh(_ shape: FilterShape) {
    let model = model(shape.filter)

    #expect(Set(model.sessions.map(\.id)) == shape.sessions)
    #expect(model.followups.map(\.id) == shape.followups)
  }

  @Test(arguments: everyFilterShape)
  func eachFilterShowsItsSessionsAfterAFilterChange(_ shape: FilterShape) {
    let model = model(OrgFilter(keys: ["haacked"]))

    model.orgFilter = shape.filter

    #expect(Set(model.sessions.map(\.id)) == shape.sessions)
    #expect(model.followups.map(\.id) == shape.followups)
  }

  @Test func changingTheFilterFiltersAgainWithoutARefresh() {
    let model = model(OrgFilter())

    model.orgFilter = posthogOnly
    #expect(!model.sessions.contains { $0.id == "hk" })

    model.orgFilter = OrgFilter()
    #expect(model.sessions.contains { $0.id == "hk" })
  }

  @Test func theFilterLeavesTheFullListsAlone() {
    let model = model(OrgFilter())

    model.orgFilter = posthogOnly

    #expect(model.allSessions == Self.list)
    #expect(model.allFollowups == Self.followups)
  }

  // MARK: Persistence

  @Test func aModelWithAStoreSavesItsKeysAndANewModelStartsWithThem() throws {
    let name = "org-filter-tests-" + UUID().uuidString
    let store = try #require(UserDefaults(suiteName: name))
    defer { store.removePersistentDomain(forName: name) }
    let first = orgFilterModel(store: store)

    first.orgFilter = OrgFilter(keys: ["posthog", OrgFilter.localKey])

    #expect(Set(store.stringArray(forKey: "orgFilter") ?? []) == ["posthog", OrgFilter.localKey])
    #expect(orgFilterModel(store: store).orgFilter == OrgFilter(keys: ["posthog", OrgFilter.localKey]))
  }

  @Test func clearingTheFilterSavesAllOrgs() throws {
    let name = "org-filter-tests-" + UUID().uuidString
    let store = try #require(UserDefaults(suiteName: name))
    defer { store.removePersistentDomain(forName: name) }
    let first = orgFilterModel(store: store)
    first.orgFilter = posthogOnly

    first.orgFilter = OrgFilter()

    #expect(orgFilterModel(store: store).orgFilter.isAll)
  }

  @Test func aModelWithoutAStoreNeverWritesTheStandardDefaults() {
    let before = UserDefaults.standard.object(forKey: "orgFilter") as? [String]
    let model = orgFilterModel(store: nil)

    model.orgFilter = OrgFilter(keys: ["posthog-tests-\(UUID().uuidString)"])

    #expect(UserDefaults.standard.object(forKey: "orgFilter") as? [String] == before)
  }

  @Test func aModelWithoutAStoreStartsWithTheFilterItIsGiven() {
    #expect(orgFilterModel(posthogOnly, store: nil).orgFilter == posthogOnly)
  }

  // MARK: Selection

  @Test func theSelectionClearsWhenAFilterChangeHidesItsSession() {
    let model = model(OrgFilter())
    model.selection = "hk"

    model.orgFilter = posthogOnly

    #expect(model.selection == nil)
  }

  @Test func theSelectionStaysWhenAFilterChangeKeepsItsSession() {
    let model = model(OrgFilter())
    model.selection = "ph1"

    model.orgFilter = posthogOnly

    #expect(model.selection == "ph1")
  }

  @Test func aPendingSelectionThatTheFilterHidesAddsItsOrgToTheFilter() {
    let model = model(posthogOnly)
    model.selectUnlisted("new")

    model.apply(.success(Self.list + [orgSession("new", "haacked/new")]), followups: nil)

    #expect(model.orgFilter == OrgFilter(keys: ["posthog", "haacked"]))
    #expect(model.selection == "new")
    #expect(model.sessions.contains { $0.id == "new" })
  }

  @Test func aPendingLocalSelectionAddsLocalToTheFilter() {
    let model = model(posthogOnly)
    model.selectUnlisted("new")

    model.apply(.success(Self.list + [orgSession("new", nil)]), followups: nil)

    #expect(model.orgFilter == OrgFilter(keys: ["posthog", OrgFilter.localKey]))
    #expect(model.selection == "new")
  }

  @Test func aPendingSelectionThatTheFilterShowsLeavesTheFilterAlone() {
    let model = model(posthogOnly)
    model.selectUnlisted("new")

    model.apply(.success(Self.list + [orgSession("new", nil, read: nil)]), followups: nil)

    #expect(model.orgFilter == posthogOnly)
    #expect(model.selection == "new")
  }

  @Test func aPendingSelectionWhoseOrgIsReadLaterAndHiddenAddsItsOrgToTheFilter() {
    let model = model(posthogOnly)
    model.selectUnlisted("new")
    model.apply(.success(Self.list + [orgSession("new", nil, read: nil)]), followups: nil)

    model.apply(.success(Self.list + [orgSession("new", "haacked/new")]), followups: nil)

    #expect(model.orgFilter == OrgFilter(keys: ["posthog", "haacked"]))
    #expect(model.selection == "new")
  }

  /// Import selects the session without `selectUnlisted`.
  @Test func aSelectionWhoseOrgIsReadLaterAndHiddenAddsItsOrgToTheFilter() {
    let model = model(posthogOnly, Self.list + [orgSession("new", nil, read: nil)])
    model.selection = "new"

    model.apply(.success(Self.list + [orgSession("new", "haacked/new")]), followups: nil)

    #expect(model.orgFilter == OrgFilter(keys: ["posthog", "haacked"]))
    #expect(model.selection == "new")
  }

  @Test func revealOfAHiddenSessionAddsItsOrgToTheFilter() {
    let model = model(posthogOnly)

    model.reveal("hk")

    #expect(model.orgFilter == OrgFilter(keys: ["posthog", "haacked"]))
    #expect(model.selection == "hk")
    #expect(model.sessions.contains { $0.id == "hk" })
  }

  @Test func revealOfAShownSessionLeavesTheFilterAlone() {
    let model = model(posthogOnly)

    model.reveal("ph1")

    #expect(model.orgFilter == posthogOnly)
    #expect(model.selection == "ph1")
  }

  /// A publish redraws every view.
  @Test func aRefreshWithTheSameListUnderAFilterWithASelectionDoesNotPublish() {
    let model = model(posthogOnly)
    model.selection = "ph1"
    var published = 0
    let subscription = model.objectWillChange.sink { published += 1 }
    defer { subscription.cancel() }

    model.apply(.success(Self.list), followups: Self.followups)

    #expect(published == 0)
  }

  // MARK: The sidebar bar and the popover

  @Test func hiddenCountsCountTheHiddenSessionsAndThoseNeedingYou() {
    let list = Self.list + [orgSession("hk2", "haacked/other")]
    let model = model(posthogOnly, list, followups: nil)

    #expect(model.hiddenCount == 3)
    #expect(model.hiddenNeedingYou == 2)
  }

  @Test func allOrgsHidesNothing() {
    let model = model(OrgFilter())

    #expect(model.hiddenCount == 0)
    #expect(model.hiddenNeedingYou == 0)
  }

  @Test func thePopoverCountsComeFromTheUnfilteredBoard() {
    let all = model(OrgFilter())
    let filtered = model(posthogOnly)

    #expect(filtered.orgEntries == all.orgEntries)
    #expect(filtered.orgEntries.first { $0.key == "haacked" }?.count == 2)
  }

  // MARK: Group lanes

  func group(_ id: String, _ sessions: [String]) -> GroupSummary {
    GroupSummary(SessionGroup(id: id, name: id, created: 0), sessions: sessions)
  }

  @Test func shownGroupsDropAGroupWhoseMembersAreAllHiddenAndKeepAnEmptyGroup() {
    let model = model(posthogOnly)
    model.groups = [
      group("posthog", ["ph1"]), group("hidden", ["hk", "lo"]), group("empty", []), group("mixed", ["hk", "un"]),
    ]

    #expect(model.shownGroups.map(\.id) == ["posthog", "empty", "mixed"])
  }

  @Test func allOrgsShowsEveryGroup() {
    let model = model(OrgFilter())
    model.groups = [group("posthog", ["ph1"]), group("hidden", ["hk", "lo"]), group("empty", [])]

    #expect(model.shownGroups.map(\.id) == ["posthog", "hidden", "empty"])
  }

  @Test func shownSuggestionsDropASuggestionThatMovesAHiddenSession() {
    let suggestions = [
      GroupSuggestion(id: "shown", name: "a", group: nil, sessions: ["ph1", "un"], reason: ""),
      GroupSuggestion(id: "mixed", name: "b", group: nil, sessions: ["ph1", "hk"], reason: ""),
    ]
    let filtered = model(posthogOnly)
    filtered.suggestions = suggestions
    let all = model(OrgFilter())
    all.suggestions = suggestions

    #expect(filtered.shownSuggestions.map(\.id) == ["shown"])
    #expect(all.shownSuggestions.map(\.id) == ["shown", "mixed"])
  }

  @Test func groupAccountMovesListAMemberThatTheFilterHides() {
    var ph = orgSession("ph1", "PostHog/posthog", group: "g1")
    ph.account = "/personal"
    var hk = orgSession("hk", "haacked/switchboard", group: "g1")
    hk.account = "/personal"
    let model = model(posthogOnly, [ph, hk], followups: nil)

    #expect(Set(model.groupAccountMoves(group: "g1", folder: "/work").map(\.id)) == ["ph1", "hk"])
  }

  // MARK: Notifications

  @Test func aHiddenSessionThatStartsNeedingYouDoesNotNotify() {
    let model = model(posthogOnly, [orgSession("ph1", "PostHog/posthog"), orgSession("hk", "haacked/switchboard")])
    let next = [orgSession("ph1", "PostHog/posthog"), orgSession("hk", "haacked/switchboard", state: .needsYou)]

    #expect(model.sessionsToNotify(next).isEmpty)
  }

  @Test func wideningTheFilterAfterAHiddenSessionStartedNeedingYouDoesNotNotify() {
    let model = model(posthogOnly, [orgSession("ph1", "PostHog/posthog"), orgSession("hk", "haacked/switchboard")])
    let next = [orgSession("ph1", "PostHog/posthog"), orgSession("hk", "haacked/switchboard", state: .needsYou)]
    model.apply(.success(next), followups: nil)

    model.orgFilter = OrgFilter()

    #expect(model.sessionsToNotify(next).isEmpty)
  }

  /// The known states cover hidden sessions. A filter that dropped them from
  /// the known states would treat the change below as a first sighting.
  @Test func aSessionThatStartsNeedingYouAfterTheFilterShowsItNotifies() {
    let model = model(posthogOnly, [orgSession("ph1", "PostHog/posthog"), orgSession("hk", "haacked/switchboard")])

    model.orgFilter = OrgFilter()

    let next = [orgSession("ph1", "PostHog/posthog"), orgSession("hk", "haacked/switchboard", state: .needsYou)]
    #expect(model.sessionsToNotify(next).map(\.id) == ["hk"])
  }

  @Test func aShownSessionThatStartsNeedingYouNotifiesTheSameUnderEveryFilterThatShowsIt() {
    let before = [
      orgSession("ph1", "PostHog/posthog"), orgSession("hk", "haacked/switchboard"), orgSession("un", nil, read: nil),
    ]
    let next = [
      orgSession("ph1", "PostHog/posthog", state: .needsYou), orgSession("hk", "haacked/switchboard"),
      orgSession("un", nil, read: nil, state: .needsYou),
    ]

    let all = model(OrgFilter(), before, followups: nil).sessionsToNotify(next).map(\.id)
    let filtered = model(posthogOnly, before, followups: nil).sessionsToNotify(next).map(\.id)

    #expect(all == ["ph1", "un"])
    #expect(filtered == all)
  }

  /// A chat has no org. Its card shows under every filter and counts in no org's row.
  @Test(arguments: everyFilterShape)
  func aChatCardShowsAndCountsUnderAnOrgFilter(_ shape: FilterShape) throws {
    let withChatCard = model(shape.filter, Self.list + [try chatCard("cc", group: "g2")])
    let withoutChatCard = model(shape.filter)

    #expect(withChatCard.needsUser.map(\.id).contains("cc"))
    #expect(withChatCard.triage.map(\.id).contains("cc"))
    #expect(withChatCard.orgEntries == withoutChatCard.orgEntries)
    #expect(withChatCard.hiddenNeedingYou == withoutChatCard.hiddenNeedingYou)
  }

  // MARK: Drafts

  func withCard(_ s: SessionSummary, _ id: Int64) throws -> SessionSummary {
    var s = s
    s.cards = [try permissionCard(id, session: s.id)]
    return s
  }

  @Test func aHiddenSessionsDraftsSurviveARefreshAndAFilterChange() throws {
    let hk = try withCard(orgSession("hk", "haacked/switchboard"), 7)
    let list = [orgSession("ph1", "PostHog/posthog"), hk]
    let model = model(OrgFilter(), list, followups: nil)
    model.draft(for: hk.cards[0]).message = "card draft"
    model.messageDraft(for: hk).text = "message draft"

    model.orgFilter = posthogOnly
    model.apply(.success(list), followups: nil)
    model.orgFilter = OrgFilter()
    model.apply(.success(list), followups: nil)

    #expect(model.draft(for: hk.cards[0]).message == "card draft")
    #expect(model.messageDraft(for: hk).text == "message draft")
  }

  /// The drafts that survive a refresh, by session, after typing one draft
  /// per session and card and then a refresh that drops session "gone".
  func survivingDrafts(_ filter: OrgFilter) throws -> [String: [String]] {
    let sessions = [
      try withCard(orgSession("ph1", "PostHog/posthog"), 1), try withCard(orgSession("hk", "haacked/switchboard"), 2),
      try withCard(orgSession("lo", nil), 3), try withCard(orgSession("un", nil, read: nil), 4),
      try withCard(orgSession("gone", "haacked/gone"), 5),
    ]
    let model = model(filter, sessions, followups: nil)
    for s in sessions {
      model.messageDraft(for: s).text = "message \(s.id)"
      model.draft(for: s.cards[0]).message = "card \(s.id)"
    }

    model.apply(.success(Array(sessions.dropLast())), followups: nil)

    return Dictionary(
      uniqueKeysWithValues: sessions.map { s in
        (s.id, [model.messageDraft(for: s).text, model.draft(for: s.cards[0]).message])
      })
  }

  @Test(arguments: [posthogOnly, OrgFilter(keys: [OrgFilter.localKey]), OrgFilter(keys: ["acme"])])
  func theDraftsThatSurviveARefreshAreTheSameUnderAFilterAndUnderAllOrgs(_ filter: OrgFilter) throws {
    let all = try survivingDrafts(OrgFilter())

    let filtered = try survivingDrafts(filter)

    #expect(filtered == all)
    #expect(all["hk"] == ["message hk", "card hk"])
    #expect(all["gone"] == ["", ""])
  }
}
