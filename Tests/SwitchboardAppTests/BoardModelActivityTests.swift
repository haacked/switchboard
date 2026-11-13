import AppKit
import SwitchboardCore
import Testing

@testable import SwitchboardApp

/// A model that has applied `list` and whose activity log is on.
@MainActor
private func activityModel(_ list: [SessionSummary] = ["a", "b", "c"].map { needsItem($0) }) -> BoardModel {
  let model = appliedModel(list)
  model.activity.enabled = true
  return model
}

private func stopped(_ id: String) -> SessionSummary {
  var s = needsItem(id)
  s.live = false
  return s
}

private func chat(_ id: String) -> SessionSummary {
  var s = needsItem(id)
  s.kind = .chat
  s.chat = "g1"
  return s
}

@MainActor
private func events(_ model: BoardModel, _ kind: String) -> [ActivityEvent] {
  model.activity.buffer.filter { $0.kind == kind }
}

/// Settles the navigation that waits for `settleMs`, as its timer would.
@MainActor
private func settlePending(_ model: BoardModel) throws {
  let pending = try #require(model.activity.pendingNav)
  model.settleNavigation(pending.token)
}

private func keyEvent() -> NSEvent? {
  NSEvent.keyEvent(
    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
    characters: "j", charactersIgnoringModifiers: "j", isARepeat: false, keyCode: 38)
}

private func mouseEvent(_ type: NSEvent.EventType) -> NSEvent? {
  NSEvent.mouseEvent(
    with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
    clickCount: 1, pressure: 1)
}

@MainActor
@Suite struct BoardModelActivityTests {
  // MARK: Inputs

  @Test func noCurrentEventIsALaunch() {
    #expect(BoardModel.input(nil) == "launch")
  }

  @Test func aKeyDownIsAKey() throws {
    #expect(BoardModel.input(try #require(keyEvent())) == "key")
  }

  @Test func aLeftMouseUpIsAClick() throws {
    #expect(BoardModel.input(try #require(mouseEvent(.leftMouseUp))) == "click")
  }

  @Test func anOtherMouseDownIsAMouseButton() throws {
    #expect(BoardModel.input(try #require(mouseEvent(.otherMouseDown))) == "mouse-button")
  }

  @Test func anApplicationDefinedEventIsOther() throws {
    let event = try #require(
      NSEvent.otherEvent(
        with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
        subtype: 0, data1: 0, data2: 0))

    #expect(BoardModel.input(event) == "other")
  }

  // MARK: Buffer

  @Test func recordActivityDropsEventsWhileTheLogIsOff() {
    let model = offlineModel()
    model.activity.enabled = false

    model.recordActivity("app", ["event": "launch"])

    #expect(model.activity.buffer.isEmpty)
  }

  @Test func recordActivityBuffersEventsBeforeTheSwitchIsKnown() {
    let model = offlineModel()

    model.recordActivity("app", ["event": "launch"])

    #expect(model.activity.buffer.map(\.kind) == ["app"])
    #expect(model.activity.buffer.first?.data == ["event": "launch"])
  }

  @Test func recordActivityBuffersEventsWhileTheLogIsOn() {
    let model = offlineModel()
    model.activity.enabled = true

    model.recordActivity("terminal.ready", session: "a", ["ms": 10])

    let event = model.activity.buffer.first
    #expect(model.activity.buffer.count == 1)
    #expect(event?.session == "a")
    #expect(event?.data == ["ms": 10])
  }

  @Test func theBufferKeepsTheNewestEventsUpToItsCap() {
    let model = offlineModel()
    model.activity.enabled = true
    let extra = 5

    for i in 0..<(ActivityState.bufferCap + extra) { model.recordActivity("window", ["width": .number(Double(i))]) }

    #expect(model.activity.buffer.count == ActivityState.bufferCap)
    #expect(model.activity.buffer.first?.data["width"]?.int == extra)
    #expect(model.activity.buffer.last?.data["width"]?.int == ActivityState.bufferCap + extra - 1)
  }

  @Test func turningTheLogOffClearsTheBuffer() {
    let model = offlineModel()
    model.recordActivity("app", ["event": "launch"])

    model.activityEnabled(false)

    #expect(model.activity.buffer.isEmpty)
    #expect(model.activity.enabled == false)
  }

  @Test func turningTheLogOnKeepsTheBuffer() {
    let model = offlineModel()
    model.recordActivity("app", ["event": "launch"])

    model.activityEnabled(true)

    #expect(model.activity.buffer.map(\.kind) == ["app"])
  }

  // MARK: Commands

  @Test func trackRecordsTheCommandAndItsInput() throws {
    let model = activityModel()

    model.track(.nextNeedingYou) {}

    let event = try #require(events(model, "command").first)
    #expect(event.data["name"] == "nextNeedingYou")
    #expect(ActivityKinds.inputs.contains(event.data["via"]?.string ?? ""))
  }

  @Test func trackRunsTheAction() {
    let model = activityModel()
    var ran = false

    model.track(.stop) { ran = true }

    #expect(ran)
  }

  @Test func aNavCommandMarksTheNavigationAsACommandWhileItRuns() {
    let model = activityModel()
    var during: String?

    model.track(.nextNeedingYou) { during = model.activity.navVia }

    #expect(during == "command")
    #expect(model.activity.navVia == nil)
  }

  @Test(arguments: [ActivityCommand.back, .forward])
  func backAndForwardMarkTheNavigationWithTheirName(_ command: ActivityCommand) {
    let model = activityModel()
    var during: String?

    model.track(command) { during = model.activity.navVia }

    #expect(during == command.rawValue)
  }

  @Test func aCommandThatDoesNotNavigateLeavesTheNavigationUnmarked() {
    let model = activityModel()
    var during: String? = "unset"

    model.track(.stop) { during = model.activity.navVia }

    #expect(during == nil)
  }

  @Test func aNavCommandInsideAnotherNavigationKeepsTheOuterVia() {
    let model = activityModel()
    var during: String?

    model.withNavVia("search") { model.track(.nextSession) { during = model.activity.navVia } }

    #expect(during == "search")
    #expect(model.activity.navVia == nil)
  }

  // MARK: Navigation

  @Test func selectingASessionRecordsOneNavOnceItSettles() throws {
    let model = activityModel()
    model.selection = "a"
    let pending = try #require(model.activity.pendingNav)

    model.settleNavigation(pending.token)

    #expect(
      events(model, "nav") == [
        ActivityEvent(
          t: pending.t, kind: "nav", session: "a",
          data: ["to": "session", "via": "list", "state": .string(AttentionState.needsYou.rawValue)])
      ])
  }

  @Test func aNavIsNotRecordedBeforeItSettles() {
    let model = activityModel()

    model.selection = "a"

    #expect(events(model, "nav").isEmpty)
  }

  @Test func twoQuickSelectionsRecordOnlyTheLast() throws {
    let model = activityModel()
    model.selection = "a"
    let first = try #require(model.activity.pendingNav)
    model.selection = "b"
    let second = try #require(model.activity.pendingNav)

    model.settleNavigation(first.token)
    model.settleNavigation(second.token)

    #expect(events(model, "nav").map(\.session) == ["b"])
  }

  @Test func theSecondNavRecordsWhereTheUserCameFrom() throws {
    let model = activityModel()
    model.selection = "a"
    try settlePending(model)

    model.show(.board)
    try settlePending(model)

    #expect(events(model, "nav").last?.data == ["from": "session", "to": "board", "via": "list"])
  }

  @Test func returningToTheRecordedPlaceBeforeSettlingRecordsNothing() throws {
    let model = activityModel()
    model.selection = "a"
    try settlePending(model)
    model.selection = "b"
    let pending = try #require(model.activity.pendingNav)

    model.selection = "a"
    model.settleNavigation(pending.token)

    #expect(model.activity.pendingNav == nil)
    #expect(events(model, "nav").count == 1)
  }

  @Test func aReplaceWithoutAViaRecordsNothing() {
    let model = activityModel()

    model.navigate(.replace) { model.selection = "a" }

    #expect(model.activity.pendingNav == nil)
    #expect(events(model, "nav").isEmpty)
  }

  @Test func navigationWhileTheLogIsOffRecordsNothing() {
    let model = appliedModel(["a"].map { needsItem($0) })
    model.activity.enabled = false

    model.selection = "a"

    #expect(model.activity.pendingNav == nil)
  }

  @Test func goingBackRecordsANavViaBack() throws {
    let model = activityModel()
    model.selection = "a"
    try settlePending(model)
    model.selection = "b"
    try settlePending(model)

    model.goBack()
    try settlePending(model)

    let nav = try #require(events(model, "nav").last)
    #expect(nav.session == "a")
    #expect(nav.data["via"] == "back")
    #expect(nav.data["from"] == "session")
  }

  @Test func goingForwardRecordsANavViaForward() throws {
    let model = activityModel()
    model.selection = "a"
    try settlePending(model)
    model.selection = "b"
    try settlePending(model)
    model.goBack()
    try settlePending(model)

    model.goForward()
    try settlePending(model)

    let nav = try #require(events(model, "nav").last)
    #expect(nav.session == "b")
    #expect(nav.data["via"] == "forward")
  }

  @Test func aRecentPlaceRecordsANavViaRecent() throws {
    let model = activityModel()

    model.go(to: NavLocation(place: .session("b"), terminal: false))
    try settlePending(model)

    #expect(events(model, "nav").map { $0.data["via"] } == ["recent"])
  }

  @Test func aSearchResultRecordsANavViaSearch() throws {
    let model = activityModel()

    model.openFromSearch("b")
    try settlePending(model)

    #expect(events(model, "nav").map { $0.data["via"] } == ["search"])
  }

  @Test func aNotificationRecordsANavViaNotification() throws {
    let model = activityModel()

    model.reveal("b")
    try settlePending(model)

    #expect(events(model, "nav").map { $0.data["via"] } == ["notification"])
  }

  @Test func aNavCommandRecordsANavViaCommand() throws {
    let model = activityModel()

    model.track(.showBoard) { model.show(.board) }
    try settlePending(model)

    #expect(events(model, "nav").map { $0.data["via"] } == ["command"])
  }

  @Test(arguments: [
    (needsItem("m", manager: true), "manager"), (chat("g"), "chat"), (needsItem("w"), "session"),
  ])
  func aSessionPlaceIsNamedByTheSessionKind(_ summary: SessionSummary, _ kind: String) throws {
    let model = activityModel([summary])

    model.selection = summary.id
    try settlePending(model)

    #expect(events(model, "nav").first?.data["to"]?.string == kind)
  }

  // MARK: Terminal waits

  @Test func aLiveSessionRecordsReadyWhenItsTerminalsAttach() throws {
    let model = activityModel()

    model.beginTerminalWait("a")
    model.terminalsAttached("a")

    let event = try #require(events(model, "terminal.ready").first)
    #expect(events(model, "terminal.ready").count == 1)
    #expect(event.session == "a")
    #expect(event.data["wasLive"] == true)
    #expect(event.data["left"] == false)
    #expect((event.data["ms"]?.double ?? -1) >= 0)
    #expect(model.activity.terminalWaits.isEmpty)
  }

  @Test func leavingBeforeTheTerminalsAttachRecordsALeftWait() throws {
    let model = activityModel()

    model.beginTerminalWait("a")
    model.endTerminalWait("a")

    let event = try #require(events(model, "terminal.ready").first)
    #expect(event.data["left"] == true)
    #expect(event.data["wasLive"] == true)
    #expect(model.activity.terminalWaits.isEmpty)
  }

  @Test func leavingAfterTheWaitEndedRecordsNothingMore() {
    let model = activityModel()
    model.beginTerminalWait("a")
    model.terminalsAttached("a")

    model.endTerminalWait("a")

    #expect(events(model, "terminal.ready").count == 1)
  }

  @Test func aSecondBeginWhileWaitingKeepsTheFirstStart() throws {
    let model = activityModel()
    model.beginTerminalWait("a")
    let start = try #require(model.activity.terminalWaits["a"]).start

    model.beginTerminalWait("a")

    #expect(model.activity.terminalWaits["a"]?.start == start)
  }

  @Test(arguments: [nil, false] as [Bool?])
  func aTerminalWaitIsNotTimedUnlessTheLogIsOn(_ enabled: Bool?) {
    let model = appliedModel(["a"].map { needsItem($0) })
    model.activity.enabled = enabled

    model.beginTerminalWait("a")
    model.terminalsAttached("a")
    model.endTerminalWait("a")

    #expect(model.activity.terminalWaits.isEmpty)
    #expect(events(model, "terminal.ready").isEmpty)
  }

  @Test func aStoppedSessionRecordsReadyOnceClaudeGoesLive() async throws {
    let model = activityModel([stopped("a")])
    model.send = { op, _ in op == "get" ? ["live": true] : .null }

    model.beginTerminalWait("a")
    model.terminalsAttached("a")
    await settle { !events(model, "terminal.ready").isEmpty }

    let event = try #require(events(model, "terminal.ready").first)
    #expect(event.data["wasLive"] == false)
    #expect(event.data["left"] == false)
  }

  @Test func aStoppedSessionDoesNotRecordReadyWhileClaudeIsNotLive() {
    let model = activityModel([stopped("a")])
    model.send = { _, _ in ["live": false] }

    model.beginTerminalWait("a")
    model.terminalsAttached("a")

    #expect(events(model, "terminal.ready").isEmpty)
    #expect(model.activity.terminalWaits["a"]?.attached == true)
    model.endTerminalWait("a")
  }

  // MARK: Flush

  @Test func flushSendsTheBufferedEventsInOneRequest() async throws {
    var buffered: [ActivityEvent] = []

    let request = await firstRequest { model in
      model.activity.enabled = true
      model.recordActivity("app", ["event": "launch"])
      model.recordActivity("command", ["name": "back", "via": "key"])
      buffered = model.activity.buffer
      model.flushActivity(force: true)
    }

    #expect(request.op == "activity-record")
    #expect(request.args == ["events": try JSON(encoding: buffered)])
    #expect(request.count == 1)
  }

  @Test func aSuccessfulFlushEmptiesTheBuffer() async {
    let model = offlineModel()
    model.send = { _, _ in .null }
    model.activity.enabled = true
    model.recordActivity("app", ["event": "launch"])

    model.flushActivity(force: true)
    await settle { !model.activity.flushing }

    #expect(model.activity.buffer.isEmpty)
  }

  @Test func aFailedFlushPutsTheEventsBackAheadOfNewOnes() async {
    let model = offlineModel()
    model.send = { _, _ in throw Boom() }
    model.activity.enabled = true
    model.recordActivity("app", ["event": "launch"])
    let batch = model.activity.buffer

    model.flushActivity(force: true)
    model.recordActivity("app", ["event": "deactivate"])
    let later = model.activity.buffer
    await settle { !model.activity.flushing }

    #expect(model.activity.buffer == batch + later)
  }

  @Test(arguments: [nil, false] as [Bool?])
  func flushSendsNothingUnlessTheLogIsOn(_ enabled: Bool?) {
    let model = offlineModel()
    let requests = Counter()
    model.send = { _, _ in
      requests.increment()
      return .null
    }
    model.recordActivity("app", ["event": "launch"])
    let buffered = model.activity.buffer
    model.activity.enabled = enabled

    model.flushActivity(force: true)

    #expect(!model.activity.flushing)
    #expect(model.activity.buffer == buffered)
    #expect(requests.value == 0)
  }

  @Test func flushWithoutForceWaitsForTheInterval() {
    let model = offlineModel()
    model.activity.enabled = true
    model.activity.lastFlush = Date()
    model.recordActivity("app", ["event": "launch"])

    model.flushActivity()

    #expect(!model.activity.flushing)
    #expect(model.activity.buffer.count == 1)
  }

  @Test func aWaitPastTheLimitRecordsATimeOutAndEnds() throws {
    let model = activityModel([stopped("sab2cd")])
    model.send = { _, _ in ["live": false] }
    model.beginTerminalWait("sab2cd")

    model.timeOutTerminalWait("sab2cd")
    model.endTerminalWait("sab2cd")

    let waits = events(model, "terminal.ready")
    #expect(waits.count == 1)
    #expect(waits.first?.data["timedOut"] == true)
    #expect(waits.first?.data["left"] == false)
    #expect(model.activity.terminalWaits.isEmpty)
  }

  /// A session that sbd just made isn't listed yet, so it reads as `session` until the refresh shows it is the
  /// Manager.
  @Test func aNewManagerRecordsItsNavOnceListed() throws {
    let model = activityModel()
    model.selectUnlisted("smgr23")
    model.apply(.success(model.allSessions + [needsItem("smgr23", manager: true)]), followups: nil)

    try settlePending(model)

    #expect(events(model, "nav").first?.data["to"] == "manager")
    #expect(events(model, "nav").first?.session == "smgr23")
  }

  @Test func aMouseButtonOrSwipeNamesItsInput() {
    #expect(NavMouse.input(.otherMouseDown) == "mouse-button")
    #expect(NavMouse.input(.swipe) == "swipe")
  }

  @Test func goingBackWithANamedInputRecordsThatInput() throws {
    let model = activityModel()
    model.selection = "a"
    model.selection = "b"

    model.go(.back, input: "mouse-button")

    let command = try #require(events(model, "command").last)
    #expect(command.data == ["name": "back", "via": "mouse-button"])
  }

  // MARK: Errors

  @Test func recordErrorKeepsTheRequestAndTheErrorTypeButNotTheMessage() throws {
    let model = activityModel()

    model.recordError("open", APIError("x"))

    let event = try #require(events(model, "error").first)
    #expect(event.data == ["where": "open", "code": "refused"])
  }

  @Test func anErrorFromARequestOutsideTheListIsOther() throws {
    let model = activityModel()

    model.recordError("plan-apply", Boom())

    #expect(events(model, "error").first?.data == ["where": "other", "code": "other"])
  }

  @Test func aFailedSendRecordsAnErrorWithoutTheMessageOrTheText() async throws {
    let model = activityModel()
    model.send = { _, _ in throw APIError("secret failure") }

    model.send("a", "hello there")
    await settle { !events(model, "error").isEmpty }

    #expect(events(model, "error").first?.data == ["where": "send", "code": "refused"])
    let logged = String(decoding: try JSONEncoder().encode(model.activity.buffer), as: UTF8.self)
    #expect(!logged.contains("secret"))
    #expect(!logged.contains("hello"))
  }

  @Test func aSendFromTheFieldSaysSo() async {
    let request = await firstRequest { $0.send("a", "hello") }

    #expect(request.op == "send")
    #expect(request.args["via"] == "field")
  }

  // MARK: Parity with sbd

  @Test func everyEventTheAppRecordsPassesActivityKinds() throws {
    let model = activityModel([needsItem("sab2cd"), needsItem("smgr23", manager: true), chat("schat2")])
    model.recordActivity("app", ["event": "launch"])
    for id in ["sab2cd", "smgr23", "schat2"] {
      model.selection = id
      try settlePending(model)
    }
    model.track(.nextNeedingYou) {}
    model.goBack()
    try settlePending(model)
    model.beginTerminalWait("sab2cd")
    model.terminalsAttached("sab2cd")
    model.beginTerminalWait("smgr23")
    model.endTerminalWait("smgr23")
    model.recordError("open", APIError("x"))
    model.recordError("terminals", Boom())
    model.recordWindowSize(CGSize(width: 900.5, height: 600), fullScreen: false)
    let kinds = Set(model.activity.buffer.map(\.kind))
    try #require(kinds == ["app", "nav", "command", "terminal.ready", "error", "window"])

    for event in model.activity.buffer {
      #expect(ActivityKinds.accepts(event), "\(event)")
    }
  }
}
