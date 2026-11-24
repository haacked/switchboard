import Foundation
import SwitchboardCore
import Testing

@testable import SwitchboardApp

private func looped(_ s: SessionSummary, _ schedules: [Schedule]?) -> SessionSummary {
  var s = s
  s.schedules = schedules
  return s
}

/// A PostHog work session named `name` with `schedules`.
private func loopSession(_ id: String, name: String? = nil, _ schedules: [Schedule]?) -> SessionSummary {
  var s = looped(orgSession(id, "PostHog/\(id)"), schedules)
  s.name = name ?? id
  return s
}

private func markedDone(_ s: SessionSummary) -> SessionSummary {
  var s = s
  s.markedDone = true
  s.state = .done
  return s
}

private func paused(_ s: SessionSummary) -> SessionSummary {
  var s = s
  s.pause = sessionPause
  return s
}

private func beingRemoved(_ s: SessionSummary, _ state: Removal.State) -> SessionSummary {
  var s = s
  s.removal = removalFixture(state)
  return s
}

private func operatorSession(_ schedules: [Schedule]) -> SessionSummary {
  var s = looped(needsItem("op", manager: true, state: .working), schedules)
  s.kind = .operator
  s.name = Manager.operatorName
  return s
}

private let failedRun = Schedule.Run(
  t: scheduleNow - 2 * minuteMs, outcome: .failed, skipped: 0, error: "the folder /work/gone is missing")

/// The loops below have each status at `scheduleNow` on a session that holds nothing. Each is a 30m loop, so its
/// grace is 30 minutes.
private func activeLoop(_ id: String, inMinutes: Int64 = 12) -> Schedule {
  scheduleFixture(id, next: scheduleNow + inMinutes * minuteMs)
}

private func dueLoop(_ id: String) -> Schedule { scheduleFixture(id, next: scheduleNow - 5 * minuteMs) }

private func overdueLoop(_ id: String) -> Schedule { scheduleFixture(id, next: scheduleNow - 120 * minuteMs) }

private func failedLoop(_ id: String) -> Schedule { scheduleFixture(id, last: failedRun) }

private func pausedLoop(_ id: String) -> Schedule { scheduleFixture(id, paused: true, last: failedRun) }

private func group(_ id: String, _ sessions: [String]) -> GroupSummary {
  GroupSummary(SessionGroup(id: id, name: id, created: 0), sessions: sessions)
}

/// A model that has applied `list` and, unless `groups` is nil, sbd's answer to `group-ls`.
@MainActor
private func loopModel(
  _ list: [SessionSummary], org: OrgFilter = OrgFilter(), groupFilter: GroupFilter = GroupFilter(),
  groups: [GroupSummary]? = nil, store: UserDefaults? = nil
) -> BoardModel {
  let model = orgFilterModel(org, groupFilter: groupFilter, store: store)
  model.apply(.success(list), followups: nil)
  if let groups { model.applyGroups(groups) }
  return model
}

@MainActor
private func rowIds(_ model: BoardModel, now: Int64 = scheduleNow) -> [String] {
  model.loopRows(now: now).map(\.id)
}

@MainActor
@Suite struct BoardModelLoopsTests {
  // MARK: Rows

  @Test func rowsListEveryScheduleOfEveryShownSession() {
    let model = loopModel([
      loopSession("a", [activeLoop("r1"), activeLoop("r2")]), loopSession("b", [activeLoop("r3")]),
      loopSession("c", nil),
    ])

    let rows = model.loopRows(now: scheduleNow)

    #expect(Set(rows.map(\.id)) == ["r1", "r2", "r3"])
    #expect(rows.count == 3)
  }

  @Test func eachRowNamesItsSessionAndIsIdentifiedByItsSchedule() throws {
    let model = loopModel([loopSession("a", [activeLoop("r1")]), loopSession("b", [activeLoop("r3")])])

    let row = try #require(model.loopRows(now: scheduleNow).first { $0.id == "r3" })

    #expect(row.session.id == "b")
    #expect(row.schedule.id == "r3")
  }

  @Test func aRowsStatusUsesItsSessionsHold() throws {
    let model = loopModel([markedDone(loopSession("a", [dueLoop("r1")]))])

    let row = try #require(model.loopRows(now: scheduleNow).first)

    #expect(row.status.state == .held)
    #expect(row.status.text == "held: the session is marked done")
  }

  /// The tab and the per-session `ScheduleList` compute the same status for the same loop.
  @Test(arguments: [SessionShape.free, .done, .paused, .doneAndPaused, .removalFailed])
  func aRowsStatusIsTheCaptionsStatus(_ shape: SessionShape) throws {
    var s = shape.session
    s.id = "a"
    s.schedules = [overdueLoop("r1"), dueLoop("r2"), activeLoop("r3"), failedLoop("r4"), pausedLoop("r5")]
    let model = loopModel([s])

    let rows = model.loopRows(now: scheduleNow)

    try #require(rows.count == 5)
    for row in rows {
      #expect(row.status == ScheduleCaption(row.schedule, session: row.session, now: scheduleNow).status)
    }
  }

  @Test func aSessionTheOrgFilterHidesDropsOut() {
    let model = loopModel(
      [
        looped(orgSession("ph", "PostHog/posthog"), [activeLoop("r1")]),
        looped(orgSession("hk", "haacked/switchboard"), [failedLoop("r2")]),
      ], org: posthogOnly)

    #expect(rowIds(model) == ["r1"])
    #expect(model.loopAttentionCount(now: scheduleNow) == 0)
  }

  @Test func aSessionTheGroupFilterHidesDropsOut() {
    let model = loopModel(
      [
        looped(groupedSession("i1", group: "g1"), [activeLoop("r1")]),
        looped(groupedSession("w1", group: "g2"), [failedLoop("r2")]),
        looped(chatItem("c2", group: "g2", state: .working), [overdueLoop("r3")]),
      ], groupFilter: GroupFilter(keys: ["g1"]), groups: [group("g1", ["i1"]), group("g2", ["w1"])])

    #expect(rowIds(model) == ["r1"])
    #expect(model.loopAttentionCount(now: scheduleNow) == 0)
  }

  @Test func theOperatorsLoopsStayUnderAGroupFilter() {
    let model = loopModel(
      [looped(groupedSession("w1", group: "g2"), [activeLoop("r1")]), operatorSession([failedLoop("r-op")])],
      groupFilter: GroupFilter(keys: ["g1"]), groups: [group("g1", []), group("g2", ["w1"])])

    #expect(rowIds(model) == ["r-op"])
    #expect(model.loopAttentionCount(now: scheduleNow) == 1)
  }

  @Test func theOperatorsLoopsStayUnderAnOrgFilter() {
    let model = loopModel(
      [looped(orgSession("hk", "haacked/switchboard"), [activeLoop("r1")]), operatorSession([activeLoop("r-op")])],
      org: posthogOnly)

    #expect(rowIds(model) == ["r-op"])
  }

  @Test(arguments: [Removal.State.queued, .running])
  func aSessionTheRemovalJobHoldsDropsOut(_ state: Removal.State) {
    let model = loopModel([
      loopSession("a", [activeLoop("r1")]), beingRemoved(loopSession("b", [failedLoop("r2")]), state),
    ])

    #expect(rowIds(model) == ["r1"])
    #expect(model.loopAttentionCount(now: scheduleNow) == 0)
  }

  /// A failed removal no longer holds the session, so the session shows again with its loops.
  @Test func aSessionWhoseRemovalFailedKeepsItsLoops() {
    let model = loopModel([beingRemoved(loopSession("b", [failedLoop("r2")]), .failed)])

    #expect(rowIds(model) == ["r2"])
    #expect(model.loopAttentionCount(now: scheduleNow) == 1)
  }

  @Test func theHiddenLoopCountCountsTheLoopsOfTheSessionsTheFilterHides() {
    let model = loopModel(
      [
        looped(orgSession("ph", "PostHog/posthog"), [activeLoop("r1")]),
        looped(orgSession("hk", "haacked/switchboard"), [failedLoop("r2"), activeLoop("r3")]),
        beingRemoved(looped(orgSession("hk2", "haacked/switchboard"), [activeLoop("r4")]), .queued),
      ], org: posthogOnly)

    #expect(model.hiddenLoopCount == 2)
    model.showAll()
    #expect(model.hiddenLoopCount == 0)
  }

  @Test func withNoSchedulesThereAreNoRows() {
    let model = loopModel([loopSession("a", nil), loopSession("b", [])])

    #expect(model.loopRows(now: scheduleNow).isEmpty)
    #expect(model.loopAttentionCount(now: scheduleNow) == 0)
  }

  // MARK: Sort

  /// Two sessions, a held session, and two active loops whose `next` ties.
  static let everyState = [
    loopSession(
      "a", [activeLoop("r-act2"), pausedLoop("r-paused"), dueLoop("r-due"), activeLoop("r-soon", inMinutes: 3)]),
    loopSession("b", [failedLoop("r-failed"), activeLoop("r-act1"), overdueLoop("r-overdue")]),
    markedDone(loopSession("c", [dueLoop("r-held")])),
  ]

  @Test func statusIsTheDefaultSort() {
    #expect(loopModel([]).loopSort == .status)
  }

  @Test func statusSortPutsFailedAndOverdueFirstThenDueActiveHeldAndPaused() {
    let model = loopModel(Self.everyState)

    #expect(rowIds(model) == ["r-failed", "r-overdue", "r-due", "r-soon", "r-act1", "r-act2", "r-held", "r-paused"])
  }

  /// The ids sort the other way from the names, so a sort by id or by status alone fails.
  static let threeNamedSessions = [
    loopSession("s1", name: "Charlie", [pausedLoop("rc-paused")]),
    loopSession(
      "s2", name: "Alpha",
      [activeLoop("ra-2", inMinutes: 20), activeLoop("ra-1", inMinutes: 5), overdueLoop("ra-overdue")]),
    loopSession("s3", name: "Bravo", [activeLoop("rb-active"), failedLoop("rb-failed")]),
  ]

  @Test func sessionSortGroupsByNameWithAttentionRowsStillOnTop() {
    let model = loopModel(Self.threeNamedSessions)

    model.loopSort = .session

    #expect(rowIds(model) == ["ra-overdue", "rb-failed", "ra-1", "ra-2", "rb-active", "rc-paused"])
  }

  @Test func theSortIsSavedAndReadByTheNextModel() throws {
    let name = "loops-sort-tests-" + UUID().uuidString
    let store = try #require(UserDefaults(suiteName: name))
    defer { store.removePersistentDomain(forName: name) }
    let first = loopModel([], store: store)

    first.loopSort = .session

    #expect(store.object(forKey: BoardModel.loopSortKey) != nil)
    #expect(loopModel([], store: store).loopSort == .session)
    first.loopSort = .status
    #expect(loopModel([], store: store).loopSort == .status)
  }

  @Test func withoutAStoreTheSortSavesNothing() {
    let before = UserDefaults.standard.object(forKey: BoardModel.loopSortKey) as? String
    let model = loopModel([], store: nil)

    model.loopSort = .session

    #expect(UserDefaults.standard.object(forKey: BoardModel.loopSortKey) as? String == before)
    #expect(loopModel([], store: nil).loopSort == .status)
  }

  // MARK: Session filter

  @Test func theSessionFilterNarrowsTheRows() {
    let model = loopModel(Self.everyState)

    model.loopSessionFilter = "a"

    #expect(Set(rowIds(model)) == ["r-act2", "r-paused", "r-due", "r-soon"])
  }

  @Test func theSessionFilterLeavesTheAttentionCountAlone() {
    let model = loopModel(Self.everyState)

    model.loopSessionFilter = "a"

    #expect(model.loopAttentionCount(now: scheduleNow) == 2)
  }

  @Test func theSessionFilterKeepsTheSort() {
    let model = loopModel(Self.everyState)

    model.loopSessionFilter = "b"

    #expect(rowIds(model) == ["r-failed", "r-overdue", "r-act1"])
  }

  /// "gone" is not listed, "z" has no loop, and "hk" has a loop that the org filter hides.
  @Test(arguments: ["gone", "z", "hk"])
  func aSessionFilterNamingASessionWithNoShownLoopFallsBackToAll(_ filter: String) {
    let model = loopModel(
      Self.everyState + [loopSession("z", nil), looped(orgSession("hk", "haacked/switchboard"), [activeLoop("r-hk")])],
      org: posthogOnly)
    let all = rowIds(model)

    model.loopSessionFilter = filter

    #expect(rowIds(model) == all)
  }

  @Test func aSessionFilterFallsBackToAllWhenItsSessionsLastLoopGoes() {
    let model = loopModel(Self.everyState)
    model.loopSessionFilter = "c"
    #expect(rowIds(model) == ["r-held"])

    model.apply(.success([Self.everyState[0], Self.everyState[1], markedDone(loopSession("c", nil))]), followups: nil)

    #expect(Set(rowIds(model)) == Set(["r-act2", "r-paused", "r-due", "r-soon", "r-failed", "r-act1", "r-overdue"]))
  }

  @Test func theSessionFilterIsNotSaved() throws {
    let name = "loops-session-filter-tests-" + UUID().uuidString
    let store = try #require(UserDefaults(suiteName: name))
    defer { store.removePersistentDomain(forName: name) }
    let first = loopModel(Self.everyState, store: store)

    first.loopSessionFilter = "a"

    #expect(loopModel(Self.everyState, store: store).loopSessionFilter == nil)
  }

  // MARK: Attention count

  @Test func theAttentionCountCountsFailedAndOverdueLoopsOnly() {
    let model = loopModel([
      loopSession("a", [failedLoop("r1"), overdueLoop("r2"), dueLoop("r3"), activeLoop("r4"), pausedLoop("r5")]),
      markedDone(loopSession("b", [overdueLoop("r6")])),
      paused(loopSession("c", [overdueLoop("r7")])),
    ])

    #expect(model.loopAttentionCount(now: scheduleNow) == 2)
  }

  /// The count depends on the time alone, so it changes while `ls` gives the same sessions.
  @Test func theAttentionCountTurnsOnWhenADueLoopReachesItsGrace() {
    let model = loopModel([loopSession("a", [scheduleFixture("r1", every: 30 * minuteMs, next: scheduleNow)])])

    #expect(model.loopAttentionCount(now: scheduleNow + 30 * minuteMs - 1) == 0)
    #expect(model.loopAttentionCount(now: scheduleNow + 30 * minuteMs) == 1)
  }

  // MARK: Focus and keys

  /// Three active loops in order r1, r2, r3 at the real clock, because the keys read it.
  func loopsView(focus: String?) -> BoardModel {
    let now = nowMs()
    let model = loopModel([
      loopSession("a", [scheduleFixture("r2", next: now + 120 * minuteMs)]),
      loopSession(
        "b", [scheduleFixture("r3", next: now + 180 * minuteMs), scheduleFixture("r1", next: now + 60 * minuteMs)]),
    ])
    model.show(.loops)
    model.loopFocus = focus
    return model
  }

  @Test(arguments: [nil, "gone"] as [String?])
  func theCurrentLoopFallsBackToTheFirstRow(_ focus: String?) {
    #expect(loopsView(focus: focus).currentLoop?.id == "r1")
  }

  @Test func theCurrentLoopIsTheFocusedRow() {
    #expect(loopsView(focus: "r2").currentLoop?.id == "r2")
  }

  @Test func upAndDownStopAtTheEnds() {
    let model = loopsView(focus: "r3")
    let jumps = model.loopJumps

    model.moveLoop(by: 1, wrap: false)
    #expect(model.currentLoop?.id == "r3")

    model.moveLoop(by: -1, wrap: false)
    #expect(model.currentLoop?.id == "r2")
    #expect(model.loopJumps == jumps + 2)
  }

  /// Edit… reads every listed session, so it finds a loop on a session that the filter hides.
  @Test func anEditFindsItsLoopEvenOnAHiddenSession() throws {
    let model = loopModel([looped(orgSession("hk", "haacked/switchboard"), [activeLoop("r-hk")])], org: posthogOnly)
    try #require(rowIds(model).isEmpty)

    #expect(model.editedSchedule(.edit("r-hk"))?.id == "r-hk")
    #expect(model.editedSchedule(.edit("gone")) == nil)
    #expect(model.editedSchedule(.new) == nil)
  }

  @Test func theLoopsViewCountIsTheAttentionCount() {
    let model = loopModel(Self.everyState)

    #expect(model.viewCount(.loops, now: scheduleNow) == 2)
    #expect(loopModel([]).viewCount(.loops, now: scheduleNow) == 0)
  }

  @Test func theCurrentLoopIsNilWithNoLoops() {
    let model = loopModel([loopSession("a", nil)])
    model.show(.loops)
    model.loopFocus = "gone"

    #expect(model.currentLoop == nil)
  }

  @Test func nextMovesToTheNextLoop() {
    let model = loopsView(focus: "r1")

    model.selectAdjacentSession(by: 1)

    #expect(model.currentLoop?.id == "r2")
  }

  @Test func nextFromTheLastLoopWrapsToTheFirst() {
    let model = loopsView(focus: "r3")

    model.selectAdjacentSession(by: 1)

    #expect(model.currentLoop?.id == "r1")
  }

  @Test func previousFromTheFirstLoopWrapsToTheLast() {
    let model = loopsView(focus: "r1")

    model.selectAdjacentSession(by: -1)

    #expect(model.currentLoop?.id == "r3")
  }

  @Test func theLoopsViewTargetsItsOwnListForFocus() {
    #expect(loopsView(focus: "r1").listFocusTarget == .loops)
  }

  /// The Loops view draws no terminal, so ⌘T and Return have no session to go into.
  @Test func theLoopsViewHasNoTerminalTarget() {
    #expect(loopsView(focus: "r1").terminalTarget == nil)
  }

  @Test func loopsIsTheFourthMainView() {
    #expect(MainView.allCases.last == .loops)
  }
}

// MARK: - The Operator's loop and Background Activity (#410)

/// A report on the Operator, as `recordReport` records it.
private func operatorReportEvent(_ id: Int64, _ text: String, about: String? = nil) -> Event {
  var data: [String: JSON] = ["text": .string(text), "needsYou": false]
  if let about { data["about"] = .string(about) }
  return Event(id: id, session: "op", t: id * 1000, kind: "report", data: .object(data))
}

@MainActor
extension BoardModelLoopsTests {
  /// rm76hh is a loop on the Operator. It lists and edits although the Operator has no sidebar row.
  @Test func theOperatorsLoopStillListsWithoutASidebarRow() {
    let model = loopModel([loopSession("a", [activeLoop("r1")]), operatorSession([activeLoop("rm76hh")])])

    #expect(rowIds(model).contains("rm76hh"))
  }

  @Test func theOperatorsLoopStillOpensInTheEditor() {
    let model = loopModel([loopSession("a", [activeLoop("r1")]), operatorSession([activeLoop("rm76hh")])])

    #expect(model.editedSchedule(.edit("rm76hh"))?.id == "rm76hh")
  }

  @Test func theLoopEditorStillOffersTheOperatorFirst() {
    let model = loopModel([loopSession("a", [activeLoop("r1")]), operatorSession([activeLoop("rm76hh")])])

    let choices = LoopEditor.sessionChoices(model.sessions, operatorID: model.operatorSession?.id)

    #expect(choices.first?.session == "op")
  }

  // MARK: Background Activity

  @Test func loadingTheActivityReadsTheOperatorsEvents() async {
    let (model, sent) = recordingModel()
    model.apply(.success([loopSession("a", nil), operatorSession([])]), followups: nil)

    model.loadBackgroundActivity()
    await sent.wait(for: "events")

    let args = sent.value.first { $0.op == "events" }?.args
    #expect(args?["session"] == "op")
  }

  @Test func loadingTheActivityAsksForTheActivityKinds() async {
    let (model, sent) = recordingModel()
    model.apply(.success([operatorSession([])]), followups: nil)

    model.loadBackgroundActivity()
    await sent.wait(for: "events")

    let args = sent.value.first { $0.op == "events" }?.args
    #expect(args?["kinds"] == .array(BackgroundActivity.kinds.map(JSON.string)))
  }

  @Test func loadingTheActivityAsksForTheActivityLimit() async {
    let (model, sent) = recordingModel()
    model.apply(.success([operatorSession([])]), followups: nil)

    model.loadBackgroundActivity()
    await sent.wait(for: "events")

    let args = sent.value.first { $0.op == "events" }?.args
    #expect(args?["limit"] == .number(Double(BackgroundActivity.limit)))
  }

  @Test func theActivityHoldsTheEntriesOfTheEventsAnswer() async throws {
    let model = loopModel([loopSession("a", nil), operatorSession([])])
    let events = [operatorReportEvent(1, "Merged #7", about: "a"), operatorReportEvent(2, "Removed fix-cache")]
    let answer = try JSON(encoding: events)
    model.send = { op, _ in op == "events" ? answer : .null }

    model.loadBackgroundActivity()
    await settle { !model.backgroundActivity.isEmpty }

    #expect(model.backgroundActivity == BackgroundActivity.entries(events))
  }

  @Test func withoutAnOperatorTheActivityIsEmpty() async {
    let model = loopModel([loopSession("a", nil)])
    model.backgroundActivity = BackgroundActivity.entries([operatorReportEvent(1, "Merged #7")])

    model.loadBackgroundActivity()
    await settle { model.backgroundActivity.isEmpty }

    #expect(model.backgroundActivity.isEmpty)
  }

  @Test func withoutAnOperatorTheActivityReadsNoEvents() async {
    let (model, sent) = recordingModel()
    model.apply(.success([loopSession("a", nil)]), followups: nil)

    model.loadBackgroundActivity()
    try? await Task.sleep(nanoseconds: 200_000_000)

    #expect(!sent.ops.contains("events"))
  }
}
