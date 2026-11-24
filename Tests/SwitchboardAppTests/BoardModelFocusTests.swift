import AppKit
import Foundation
import SwitchboardCore
import Testing

@testable import SwitchboardApp

private let targetID = "seb4ec"
private let otherID = "s3k9ap"
private let goneID = "sgcctv"
private let thirdID = "s23456"

/// A work session with no Inbox item.
private func workSession(_ id: String, state: AttentionState = .working) -> SessionSummary {
  var s = needsItem(id, state: state)
  s.triage = nil
  return s
}

/// A Manager conversation, archived when `archived` is true.
private func conversation(_ id: String, lastActivity: Int64, archived: Bool? = nil) -> SessionSummary {
  var s = needsItem(id, manager: true)
  s.triage = nil
  s.lastActivity = lastActivity
  s.lastReply = "Done."
  s.activity = ChatActivity(replies: 1, unread: 0, lastMessageAt: lastActivity, archived: archived)
  return s
}

/// `switchboard:` URLs that `SessionLink.target(from:)` refuses. A URL that names a session names `targetID`, which
/// each test lists. Only the parser can then refuse it.
private let malformedLinks = [
  "SWITCHBOARD://session/seb4ec",
  "switchboard://session/seb4ec?x=1",
  "switchboard://session/seb4ec/",
  "switchboard://other/seb4ec",
  "switchboard:seb4ec",
  "switchboard://",
  // The decoded name has the id shape, which only the exact id text may reach.
  "switchboard://session/%73eb4ec",
  // The escape does not decode to UTF-8.
  "switchboard://session/%ff",
]

/// A work session named `name`. `needsItem` names a session by its id, and an id-shaped name is never a name target.
private func named(_ id: String, _ name: String) -> SessionSummary {
  var s = workSession(id)
  s.name = name
  return s
}

/// A model that has applied `list` and, when given, the removed sessions.
@MainActor
private func listedModel(_ list: [SessionSummary], removed: [RemovedSession]? = nil) -> BoardModel {
  let model = offlineModel()
  model.apply(.success(list), followups: nil, removed: removed)
  return model
}

/// Names that live sessions have. A space and a slash reach the URL percent-encoded.
private let linkableNames = ["fix-cache", "Fix CI chat", "posthog-code/flag-evaluations-table"]

private func ambiguousBanner(_ name: String, _ count: Int) -> String {
  "\"\(name)\" names \(count) sessions. Use the session's id link."
}

private func unknownNameBanner(_ name: String) -> String { "Switchboard has no session named \"\(name)\"" }

private func tombstone(_ id: String) -> RemovedSession {
  RemovedSession(id: id, name: "old-flag-cleanup", removed: 1_794_377_400_000)
}

/// `focus(id)` is the path that `sb focus` and a `switchboard://session/<id>` URL reach. It shows the session
/// as a sidebar click does.
@MainActor
@Suite struct BoardModelFocusTests {
  // MARK: A listed session

  @Test func focusOnAListedSessionSelectsIt() {
    let model = appliedModel([workSession(targetID), workSession(otherID)])

    model.focus(.id(targetID))

    #expect(model.selection == targetID)
  }

  @Test func focusOnAListedSessionShowsTheWindowOnce() {
    let model = appliedModel([workSession(targetID)])
    let shown = Counter()
    model.showWindow = { shown.increment() }

    model.focus(.id(targetID))

    #expect(shown.value == 1)
  }

  @Test func focusClosesTheSearchPanel() {
    let model = appliedModel([workSession(targetID)])
    model.showingSearch = true

    model.focus(.id(targetID))

    #expect(!model.showingSearch)
  }

  @Test func focusClosesRecentPlaces() {
    let model = appliedModel([workSession(targetID)])
    model.showingRecentPlaces = true

    model.focus(.id(targetID))

    #expect(!model.showingRecentPlaces)
  }

  @Test func focusOnAListedSessionLeavesNoError() {
    let model = appliedModel([workSession(targetID)])

    model.focus(.id(targetID))

    #expect(model.actionError == nil)
    #expect(model.pendingFocus == nil)
  }

  @Test func focusOnAFollowupThatHasNotStartedOpensItsSection() throws {
    let model = appliedModel([workSession(otherID)], followups: [unstartedFollowup(targetID)])
    try #require(!model.sidebarOrder.contains(targetID))

    model.focus(.id(targetID))

    #expect(model.selection == targetID)
    #expect(model.sidebarOrder.contains(targetID))
  }

  @Test func focusOnAnArchivedConversationOpensTheArchive() throws {
    let model = appliedModel([
      conversation(otherID, lastActivity: 30), conversation(targetID, lastActivity: 2, archived: true),
      workSession(thirdID),
    ])
    try #require(!model.sidebarOrder.contains(targetID))

    model.focus(.id(targetID))

    #expect(model.selection == targetID)
    #expect(model.showingArchive)
    #expect(model.sidebarOrder.contains(targetID))
  }

  @Test func focusOnASessionThatTheOrgFilterHidesShowsItsOrg() throws {
    let model = orgFilterModel(posthogOnly)
    model.apply(
      .success([orgSession("sph234", "PostHog/posthog"), orgSession(targetID, "haacked/switchboard")]),
      followups: nil)
    try #require(!model.sessions.contains { $0.id == targetID })

    model.focus(.id(targetID))

    #expect(model.selection == targetID)
    #expect(model.sessions.contains { $0.id == targetID })
  }

  @Test func focusRequestsListFocus() {
    let model = appliedModel([workSession(targetID)])
    let before = model.listFocusRequests

    model.focus(.id(targetID))

    #expect(model.listFocusRequests > before)
  }

  // MARK: History

  @Test func focusFromTheInboxAddsOneHistoryEntry() throws {
    let model = appliedModel([needsItem(targetID), needsItem(otherID), needsItem(thirdID)])
    try #require(model.selection == nil)
    let before = model.history.entries.count

    model.focus(.id(otherID))

    #expect(model.history.entries.count == before + 1)
  }

  @Test func backAfterFocusFromTheInboxReturnsToTheInbox() throws {
    let model = appliedModel([needsItem(targetID), needsItem(otherID), needsItem(thirdID)])
    try #require(model.selection == nil)
    let start = model.history.current

    model.focus(.id(otherID))
    model.goBack()

    #expect(model.selection == nil)
    #expect(model.mainView == .inbox)
    #expect(model.history.current == start)
  }

  // MARK: Sheets

  enum Sheet: String, CaseIterable {
    case newSession, importSessions

    @MainActor func open(on model: BoardModel) {
      switch self {
      case .newSession: model.openNewSession()
      case .importSessions: model.showingImport = true
      }
    }

    @MainActor func isOpen(on model: BoardModel) -> Bool {
      switch self {
      case .newSession: model.newSession != nil
      case .importSessions: model.showingImport
      }
    }
  }

  @Test(arguments: Sheet.allCases)
  func focusLeavesAnOpenSheetOpen(_ sheet: Sheet) {
    let model = appliedModel([workSession(targetID)])
    sheet.open(on: model)

    model.focus(.id(targetID))

    #expect(sheet.isOpen(on: model))
  }

  /// A list focus request would take keyboard focus from the sheet's fields.
  @Test(arguments: Sheet.allCases)
  func focusWithAnOpenSheetLeavesListFocusAlone(_ sheet: Sheet) {
    let model = appliedModel([workSession(targetID)])
    sheet.open(on: model)
    let before = model.listFocusRequests

    model.focus(.id(targetID))

    #expect(model.listFocusRequests == before)
  }

  @Test(arguments: Sheet.allCases)
  func focusWithAnOpenSheetChangesTheSelection(_ sheet: Sheet) {
    let model = appliedModel([workSession(targetID)])
    sheet.open(on: model)

    model.focus(.id(targetID))

    #expect(model.selection == targetID)
  }

  // MARK: A session that no refresh has listed yet

  @Test func focusBeforeTheFirstApplySelectsNothingYet() {
    let model = offlineModel()

    model.focus(.id(targetID))

    #expect(model.selection == nil)
    #expect(model.pendingFocus == .id(targetID))
  }

  @Test func focusBeforeTheFirstApplySelectsTheSessionAtTheApplyThatListsIt() {
    let model = offlineModel()
    model.focus(.id(targetID))

    model.apply(.success([workSession(targetID)]), followups: nil)

    #expect(model.selection == targetID)
    #expect(model.actionError == nil)
    #expect(model.pendingFocus == nil)
  }

  /// The main window starts the refreshes, so a focus that waits for one opens a closed window.
  @Test func focusOnAnUnlistedSessionShowsTheWindowOnce() {
    let model = offlineModel()
    let shown = Counter()
    model.showWindow = { shown.increment() }

    model.focus(.id(targetID))

    #expect(shown.value == 1)
    #expect(model.pendingFocus == .id(targetID))
  }

  /// `ls` leaves out an unstarted follow-up, so the next refresh must read `followup-ls` to list one.
  @Test func aFocusThatWaitsMakesTheNextRefreshReadTheFollowups() throws {
    let model = appliedModel([workSession(otherID)])
    model.refresh()
    try #require(!model.followupsDue)

    model.focus(.id(targetID))

    #expect(model.followupsDue)
  }

  /// `sb focus` usually runs while the user has a session open.
  @Test func aPendingFocusStartedWithAnotherSessionSelectedSelectsTheSessionWhenListed() {
    let model = appliedModel([workSession(otherID), workSession(thirdID)])
    model.selection = thirdID
    model.focus(.id(targetID))

    model.apply(.success([workSession(otherID), workSession(thirdID), workSession(targetID)]), followups: nil)

    #expect(model.selection == targetID)
    #expect(model.pendingFocus == nil)
  }

  @Test func aPendingFocusOnASessionListedOnlyAtTheSecondApplyWaitsForIt() {
    let model = appliedModel([workSession(otherID)])
    model.focus(.id(targetID))

    model.apply(.success([workSession(otherID)]), followups: nil)

    #expect(model.selection == nil)
    #expect(model.pendingFocus == .id(targetID))
    #expect(model.actionError == nil)
  }

  @Test func aPendingFocusOnASessionListedOnlyAtTheSecondApplySelectsItThen() {
    let model = appliedModel([workSession(otherID)])
    model.focus(.id(targetID))
    model.apply(.success([workSession(otherID)]), followups: nil)

    model.apply(.success([workSession(otherID), workSession(targetID)]), followups: nil)

    #expect(model.selection == targetID)
    #expect(model.pendingFocus == nil)
    #expect(model.actionError == nil)
  }

  /// A follow-up that `sb new` or a plan just made shows first in `followup-ls`, not in `ls`.
  @Test func aPendingFocusOnAFollowupSelectsItAndOpensItsSection() {
    let model = appliedModel([workSession(otherID)])
    model.focus(.id(targetID))

    model.apply(.success([workSession(otherID)]), followups: [unstartedFollowup(targetID)])

    #expect(model.selection == targetID)
    #expect(model.sidebarOrder.contains(targetID))
    #expect(model.pendingFocus == nil)
  }

  @Test func aPendingFocusOnASessionThatTheOrgFilterHidesSelectsItAndShowsItsOrg() {
    let model = orgFilterModel(posthogOnly)
    model.apply(.success([orgSession("sph234", "PostHog/posthog")]), followups: nil)
    model.focus(.id(targetID))

    model.apply(
      .success([orgSession("sph234", "PostHog/posthog"), orgSession(targetID, "haacked/switchboard")]),
      followups: nil)

    #expect(model.selection == targetID)
    #expect(model.sessions.contains { $0.id == targetID })
  }

  // MARK: A session that no refresh lists

  @Test func aPendingFocusSetsNoErrorAfterTwoSuccessfulApplies() {
    let model = appliedModel([workSession(otherID)])
    model.focus(.id(targetID))

    model.apply(.success([workSession(otherID)]), followups: nil)
    model.apply(.success([workSession(otherID)]), followups: nil)

    #expect(model.actionError == nil)
    #expect(model.pendingFocus == .id(targetID))
  }

  @Test func aPendingFocusOnASessionThatARefreshReportsRemovedSetsTheRemovedError() {
    let model = appliedModel([workSession(otherID)])
    model.focus(.id(goneID))

    model.apply(.success([workSession(otherID)]), followups: nil, removed: [tombstone(goneID)])

    #expect(model.actionError?.contains("removed") == true)
    #expect(model.pendingFocus == nil)
    #expect(model.selection == nil)
  }

  /// A session that the user selects while a focus waits stays selected when the focused session appears.
  @Test func aSelectionMadeWhileAFocusWaitsEndsTheWait() {
    let model = appliedModel([workSession(otherID)])
    model.focus(.id(targetID))
    model.selection = otherID

    model.apply(.success([workSession(otherID), workSession(targetID)]), followups: nil)

    #expect(model.selection == otherID)
    #expect(model.pendingFocus == nil)
    #expect(model.actionError == nil)
  }

  @Test func aPendingFocusGivesUpAtTheThirdSuccessfulApply() {
    let model = appliedModel([workSession(otherID)])
    model.focus(.id(targetID))

    for _ in 0..<3 { model.apply(.success([workSession(otherID)]), followups: nil) }

    #expect(model.actionError == "Switchboard has no session \(targetID)")
    #expect(model.pendingFocus == nil)
    #expect(model.selection == nil)
  }

  @Test func aFailedApplyDoesNotCountTowardGivingUp() {
    let model = appliedModel([workSession(otherID)])
    model.focus(.id(targetID))

    model.apply(.success([workSession(otherID)]), followups: nil)
    model.apply(.failure(Boom()), followups: nil)
    model.apply(.success([workSession(otherID)]), followups: nil)

    #expect(model.actionError == nil)
    #expect(model.pendingFocus == .id(targetID))
  }

  @Test func aFailedApplyBetweenSuccessesStillGivesUpAtTheThirdSuccess() {
    let model = appliedModel([workSession(otherID)])
    model.focus(.id(targetID))

    model.apply(.success([workSession(otherID)]), followups: nil)
    model.apply(.failure(Boom()), followups: nil)
    model.apply(.success([workSession(otherID)]), followups: nil)
    model.apply(.success([workSession(otherID)]), followups: nil)

    #expect(model.actionError == "Switchboard has no session \(targetID)")
    #expect(model.pendingFocus == nil)
  }

  /// After giving up, a later refresh that lists the id must not select it.
  @Test func aSessionListedAfterThePendingFocusGaveUpIsNotSelected() {
    let model = appliedModel([workSession(otherID)])
    model.focus(.id(targetID))
    for _ in 0..<3 { model.apply(.success([workSession(otherID)]), followups: nil) }

    model.apply(.success([workSession(otherID), workSession(targetID)]), followups: nil)

    #expect(model.selection == nil)
  }

  // MARK: A removed session

  @Test func focusOnARemovedSessionSetsTheRemovedErrorAtOnce() {
    let model = offlineModel()
    model.apply(.success([workSession(otherID)]), followups: nil, removed: [tombstone(goneID)])

    model.focus(.id(goneID))

    #expect(model.actionError?.contains("removed") == true)
  }

  /// The error banner shows only in the window, so a closed window opens for it.
  @Test func focusOnARemovedSessionShowsTheWindowOnce() {
    let model = offlineModel()
    model.apply(.success([workSession(otherID)]), followups: nil, removed: [tombstone(goneID)])
    let shown = Counter()
    model.showWindow = { shown.increment() }

    model.focus(.id(goneID))

    #expect(shown.value == 1)
  }

  @Test func focusOnARemovedSessionLeavesNoPendingFocusAndSelectsNothing() {
    let model = offlineModel()
    model.apply(.success([workSession(otherID)]), followups: nil, removed: [tombstone(goneID)])

    model.focus(.id(goneID))

    #expect(model.pendingFocus == nil)
    #expect(model.selection == nil)
  }

  // MARK: A newer focus replaces the pending one

  @Test func aSecondFocusBeforeTheFirstResolvesSelectsOnlyTheSecond() {
    let model = appliedModel([workSession(thirdID)])
    model.focus(.id(targetID))
    model.focus(.id(otherID))

    model.apply(.success([workSession(thirdID), workSession(targetID), workSession(otherID)]), followups: nil)

    #expect(model.selection == otherID)
    #expect(model.pendingFocus == nil)
  }

  @Test func anApplyThatListsOnlyTheReplacedIdSelectsNothing() {
    let model = appliedModel([workSession(thirdID)])
    model.focus(.id(targetID))
    model.focus(.id(otherID))

    model.apply(.success([workSession(thirdID), workSession(targetID)]), followups: nil)

    #expect(model.selection == nil)
    #expect(model.pendingFocus == .id(otherID))
  }

  /// A focus on a listed session drops a pending focus, so a later refresh can't move the selection away.
  @Test func aFocusOnAListedSessionDropsAPendingFocus() {
    let model = appliedModel([workSession(otherID)])
    model.focus(.id(targetID))
    model.focus(.id(otherID))

    model.apply(.success([workSession(otherID), workSession(targetID)]), followups: nil)

    #expect(model.selection == otherID)
    #expect(model.pendingFocus == nil)
  }

  // MARK: External links

  @Test func anExternalLinkToAListedSessionSelectsIt() {
    let model = appliedModel([workSession(targetID)])

    model.openExternalLink(SessionLink.url(for: targetID))

    #expect(model.selection == targetID)
  }

  @Test(arguments: malformedLinks)
  func aMalformedSwitchboardLinkSetsAnError(_ string: String) throws {
    let model = appliedModel([workSession(targetID)])
    let url = try #require(URL(string: string))

    model.openExternalLink(url)

    #expect(model.actionError != nil)
  }

  @Test(arguments: malformedLinks)
  func aMalformedSwitchboardLinkSelectsNothing(_ string: String) throws {
    let model = appliedModel([workSession(targetID)])
    let url = try #require(URL(string: string))

    model.openExternalLink(url)

    #expect(model.selection == nil)
    #expect(model.pendingFocus == nil)
  }

  /// The error banner shows only in the window, so a closed window opens for it.
  @Test func aMalformedSwitchboardLinkShowsTheWindowOnce() throws {
    let model = appliedModel([workSession(targetID)])
    let shown = Counter()
    model.showWindow = { shown.increment() }
    let url = try #require(URL(string: malformedLinks[0]))

    model.openExternalLink(url)

    #expect(shown.value == 1)
  }

  // MARK: A name link

  @Test(arguments: linkableNames)
  func anInAppNameLinkSelectsTheSession(_ name: String) {
    let model = listedModel([named(targetID, name), named(otherID, "other-work")])

    _ = model.openSessionLink(SessionLink.url(forName: name))

    #expect(model.selection == targetID)
    #expect(model.actionError == nil)
  }

  @Test(arguments: linkableNames)
  func anExternalNameLinkSelectsTheSession(_ name: String) {
    let model = listedModel([named(targetID, name), named(otherID, "other-work")])

    model.openExternalLink(SessionLink.url(forName: name))

    #expect(model.selection == targetID)
    #expect(model.actionError == nil)
    #expect(model.pendingFocus == nil)
  }

  /// A name link resolves against every session, not only the ones that the org filter shows.
  @Test func anInAppNameLinkToASessionThatTheOrgFilterHidesSelectsIt() throws {
    let model = orgFilterModel(posthogOnly)
    var hidden = orgSession(targetID, "haacked/switchboard")
    hidden.name = "fix-cache"
    model.apply(.success([orgSession("sph234", "PostHog/posthog"), hidden]), followups: nil)
    try #require(!model.sessions.contains { $0.id == targetID })

    _ = model.openSessionLink(SessionLink.url(forName: "fix-cache"))

    #expect(model.selection == targetID)
  }

  @Test func anInAppNameLinkToAFollowupThatHasNotStartedSelectsIt() {
    var followup = unstartedFollowup(targetID)
    followup.name = "fix-cache"
    let model = appliedModel([workSession(otherID)], followups: [followup])

    _ = model.openSessionLink(SessionLink.url(forName: "fix-cache"))

    #expect(model.selection == targetID)
  }

  @Test func anExternalNameLinkBeforeTheFirstApplySelectsTheSessionAtTheApplyThatListsIt() {
    let model = offlineModel()
    model.openExternalLink(SessionLink.url(forName: "fix-cache"))

    model.apply(.success([named(targetID, "fix-cache")]), followups: nil)

    #expect(model.selection == targetID)
    #expect(model.actionError == nil)
    #expect(model.pendingFocus == nil)
  }

  @Test func anExternalNameLinkSelectsASessionListedOnlyAtTheThirdApply() {
    let model = offlineModel()
    model.openExternalLink(SessionLink.url(forName: "fix-cache"))
    model.apply(.success([]), followups: nil)
    model.apply(.success([]), followups: nil)

    model.apply(.success([named(targetID, "fix-cache")]), followups: nil)

    #expect(model.selection == targetID)
    #expect(model.actionError == nil)
  }

  // MARK: A name that more than one session has

  @Test(arguments: [2, 3])
  func anInAppAmbiguousNameLinkSetsTheAmbiguousBanner(_ count: Int) {
    let ids = [targetID, otherID, thirdID].prefix(count)
    let model = listedModel(ids.map { named($0, "fix-cache") })

    _ = model.openSessionLink(SessionLink.url(forName: "fix-cache"))

    #expect(model.actionError == ambiguousBanner("fix-cache", count))
  }

  @Test func anInAppAmbiguousNameLinkSelectsNothing() {
    let model = listedModel([named(targetID, "fix-cache"), named(otherID, "fix-cache")])

    _ = model.openSessionLink(SessionLink.url(forName: "fix-cache"))

    #expect(model.selection == nil)
    #expect(model.pendingFocus == nil)
  }

  @Test(arguments: [2, 3])
  func anExternalAmbiguousNameLinkSetsTheAmbiguousBannerAtOnce(_ count: Int) {
    let ids = [targetID, otherID, thirdID].prefix(count)
    let model = listedModel(ids.map { named($0, "fix-cache") })

    model.openExternalLink(SessionLink.url(forName: "fix-cache"))

    #expect(model.actionError == ambiguousBanner("fix-cache", count))
    #expect(model.pendingFocus == nil)
  }

  @Test func anExternalAmbiguousNameLinkSelectsNothing() {
    let model = listedModel([named(targetID, "fix-cache"), named(otherID, "fix-cache")])

    model.openExternalLink(SessionLink.url(forName: "fix-cache"))

    #expect(model.selection == nil)
  }

  /// The error banner shows only in the window, so a closed window opens for it.
  @Test func anExternalAmbiguousNameLinkShowsTheWindowOnce() {
    let model = listedModel([named(targetID, "fix-cache"), named(otherID, "fix-cache")])
    let shown = Counter()
    model.showWindow = { shown.increment() }

    model.openExternalLink(SessionLink.url(forName: "fix-cache"))

    #expect(shown.value == 1)
  }

  /// A name that a waiting focus names can turn out to name more than one session at the apply that lists them.
  @Test func aPendingNameFocusSetsTheAmbiguousBannerAtTheApplyThatListsTwoSessions() {
    let model = offlineModel()
    model.openExternalLink(SessionLink.url(forName: "fix-cache"))

    model.apply(.success([named(targetID, "fix-cache"), named(otherID, "fix-cache")]), followups: nil)

    #expect(model.actionError == ambiguousBanner("fix-cache", 2))
    #expect(model.selection == nil)
    #expect(model.pendingFocus == nil)
  }

  /// The ambiguous banner shows the written name too, with each format character written as its code point.
  @Test func anAmbiguousNameBannerShowsNoFormatCharacter() {
    let name = "fix\u{202E}ehcac"
    let model = listedModel([named(targetID, name), named(otherID, name)])

    _ = model.openSessionLink(SessionLink.url(forName: name))

    #expect(model.actionError == ambiguousBanner("fix<U+202E>ehcac", 2))
  }

  /// A follow-up whose trigger fired is in both lists until it starts. Its two copies are one session.
  @Test func aNameThatAFollowupAndItsStartedCopyShareSelectsTheSession() {
    var followup = unstartedFollowup(targetID)
    followup.name = "fix-cache"
    let model = appliedModel([named(targetID, "fix-cache")], followups: [followup])

    _ = model.openSessionLink(SessionLink.url(forName: "fix-cache"))

    #expect(model.selection == targetID)
    #expect(model.actionError == nil)
  }

  // MARK: A name that no session has

  @Test func anInAppUnknownNameLinkSetsTheUnknownNameBanner() {
    let model = listedModel([named(targetID, "fix-cache")])

    _ = model.openSessionLink(SessionLink.url(forName: "no-such-session"))

    #expect(model.actionError == unknownNameBanner("no-such-session"))
    #expect(model.selection == nil)
    #expect(model.pendingFocus == nil)
  }

  /// Names match case-sensitively, as `sb` matches them.
  @Test func anInAppNameLinkInAnotherCaseSetsTheUnknownNameBanner() {
    let model = listedModel([named(targetID, "fix-cache")])

    _ = model.openSessionLink(SessionLink.url(forName: "Fix-Cache"))

    #expect(model.actionError == unknownNameBanner("Fix-Cache"))
    #expect(model.selection == nil)
  }

  /// An upper-case id is not the id text, so it is a name that no session has.
  @Test func anInAppUpperCaseIdLinkSetsTheUnknownNameBanner() throws {
    let model = listedModel([workSession(targetID)])
    let url = try #require(URL(string: "switchboard://session/SEB4EC"))

    _ = model.openSessionLink(url)

    #expect(model.actionError == unknownNameBanner("SEB4EC"))
    #expect(model.selection == nil)
  }

  /// A link never matches an id prefix.
  @Test func anInAppIdPrefixLinkSetsTheUnknownNameBanner() throws {
    let model = listedModel([workSession(targetID)])
    let url = try #require(URL(string: "switchboard://session/seb4e"))

    _ = model.openSessionLink(url)

    #expect(model.actionError == unknownNameBanner("seb4e"))
    #expect(model.selection == nil)
  }

  /// Name links resolve against the listed sessions, so a removed session's name names no session.
  @Test func anInAppNameLinkToARemovedSessionsNameSetsTheUnknownNameBanner() {
    let model = listedModel([workSession(otherID)], removed: [tombstone(goneID)])

    _ = model.openSessionLink(SessionLink.url(forName: "old-flag-cleanup"))

    #expect(model.actionError == unknownNameBanner("old-flag-cleanup"))
  }

  /// A name link can reach the app at a cold launch, before any refresh lists a session.
  @Test func anExternalUnknownNameLinkSetsNoErrorAfterTwoSuccessfulApplies() {
    let model = offlineModel()
    model.openExternalLink(SessionLink.url(forName: "no-such-session"))

    model.apply(.success([]), followups: nil)
    model.apply(.success([]), followups: nil)

    #expect(model.actionError == nil)
    #expect(model.pendingFocus == .name("no-such-session"))
  }

  @Test func anExternalUnknownNameLinkGivesUpAtTheThirdSuccessfulApply() {
    let model = offlineModel()
    model.openExternalLink(SessionLink.url(forName: "no-such-session"))

    for _ in 0..<3 { model.apply(.success([]), followups: nil) }

    #expect(model.actionError == unknownNameBanner("no-such-session"))
    #expect(model.pendingFocus == nil)
    #expect(model.selection == nil)
  }

  @Test func anExternalUnknownNameLinkShowsTheWindowOnce() {
    let model = offlineModel()
    let shown = Counter()
    model.showWindow = { shown.increment() }

    model.openExternalLink(SessionLink.url(forName: "no-such-session"))

    #expect(shown.value == 1)
  }

  /// The banner shows the written name. A format character such as a bidi override or a zero-width space would make
  /// the banner show text other than what the link holds.
  @Test(arguments: ["fix\u{202E}ehcac", "fix\u{200B}cache"])
  func anUnknownNameBannerShowsNoFormatCharacter(_ name: String) throws {
    let model = listedModel([named(targetID, "fix-cache")])

    _ = model.openSessionLink(SessionLink.url(forName: name))

    let banner = try #require(model.actionError)
    #expect(!banner.unicodeScalars.contains { $0.properties.generalCategory == .format })
  }

  // MARK: An in-app id link

  @Test func anInAppIdLinkToAListedSessionSelectsIt() {
    let model = listedModel([workSession(targetID), workSession(otherID)])

    _ = model.openSessionLink(SessionLink.url(for: targetID))

    #expect(model.selection == targetID)
    #expect(model.actionError == nil)
  }

  @Test func anInAppIdLinkToARemovedSessionSetsTheRemovedBanner() {
    let model = listedModel([workSession(otherID)], removed: [tombstone(goneID)])

    _ = model.openSessionLink(SessionLink.url(for: goneID))

    #expect(model.actionError == "Session \(goneID) was removed")
    #expect(model.selection == nil)
  }

  /// An in-app click resolves at once against the app's list, so it never waits for a refresh.
  @Test func anInAppIdLinkToAnUnknownSessionSetsTheUnknownIdBannerAtOnce() {
    let model = listedModel([workSession(otherID)])

    _ = model.openSessionLink(SessionLink.url(for: targetID))

    #expect(model.actionError == "Switchboard has no session \(targetID)")
    #expect(model.selection == nil)
    #expect(model.pendingFocus == nil)
  }

  @Test(arguments: malformedLinks)
  func anInAppMalformedLinkSetsTheCantOpenBanner(_ string: String) throws {
    let model = listedModel([workSession(targetID)])
    let url = try #require(URL(string: string))

    _ = model.openSessionLink(url)

    #expect(model.actionError == "Switchboard can't open \(url.absoluteString)")
    #expect(model.selection == nil)
  }

  /// Every `switchboard:` URL counts as handled, so that Launch Services never hands the app's own link to another
  /// copy of the app.
  @Test(
    arguments: malformedLinks + [
      SessionLink.url(for: targetID).absoluteString, SessionLink.url(for: thirdID).absoluteString,
      SessionLink.url(forName: "fix-cache").absoluteString, SessionLink.url(forName: "no-such-session").absoluteString,
    ])
  func openSessionLinkHandlesEverySwitchboardURL(_ string: String) throws {
    let model = listedModel([named(targetID, "fix-cache"), named(otherID, "fix-cache")])
    let url = try #require(URL(string: string))

    #expect(model.openSessionLink(url))
  }

  @Test(arguments: ["https://github.com/haacked/switchboard/pull/1", "mailto:someone@example.com"])
  func openSessionLinkLeavesOtherSchemesToTheSystem(_ string: String) throws {
    let model = listedModel([workSession(targetID)])
    let url = try #require(URL(string: string))

    #expect(!model.openSessionLink(url))
    #expect(model.actionError == nil)
  }

  // MARK: The in-app and external paths agree

  enum LinkCase: String, CaseIterable {
    case listedID, listedName, ambiguousName, removedID, unknownID, unknownName, malformed

    var list: [SessionSummary] {
      switch self {
      case .ambiguousName: [named(targetID, "fix-cache"), named(otherID, "fix-cache")]
      default: [named(targetID, "fix-cache"), named(otherID, "other-work")]
      }
    }

    var removed: [RemovedSession] { [tombstone(goneID)] }

    var url: URL {
      switch self {
      case .listedID: SessionLink.url(for: targetID)
      case .listedName, .ambiguousName: SessionLink.url(forName: "fix-cache")
      case .removedID: SessionLink.url(for: goneID)
      case .unknownID: SessionLink.url(for: thirdID)
      case .unknownName: SessionLink.url(forName: "no-such-session")
      case .malformed: URL(string: "switchboard://session/seb4ec?x=1")!
      }
    }
  }

  /// An external link may wait for refreshes, so the external model applies the same list until the wait ends.
  @Test(arguments: LinkCase.allCases)
  func theInAppAndExternalPathsReachTheSameSessionAndBanner(_ link: LinkCase) {
    let inApp = listedModel(link.list, removed: link.removed)
    let external = listedModel(link.list, removed: link.removed)

    _ = inApp.openSessionLink(link.url)
    external.openExternalLink(link.url)
    for _ in 0..<3 where external.pendingFocus != nil {
      external.apply(.success(link.list), followups: nil, removed: link.removed)
    }

    #expect(inApp.selection == external.selection)
    #expect(inApp.actionError == external.actionError)
  }
}
