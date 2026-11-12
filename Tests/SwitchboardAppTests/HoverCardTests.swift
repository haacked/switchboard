import AppKit
import SwitchboardCore
import Testing

@testable import SwitchboardApp

private let delay: TimeInterval = 0.5
private let grace: TimeInterval = 0.25

/// An action that `ManualScheduler` runs only when a test fires it.
private final class ScheduledAction {
  let interval: TimeInterval
  let action: @MainActor () -> Void
  var cancelled = false
  var fired = false
  var isPending: Bool { !cancelled && !fired }

  init(interval: TimeInterval, action: @escaping @MainActor () -> Void) {
    self.interval = interval
    self.action = action
  }
}

/// A scheduler whose actions run only when the test fires them.
@MainActor
private final class ManualScheduler {
  private var actions: [ScheduledAction] = []

  /// How many actions the controller has scheduled, fired or not.
  var count: Int { actions.count }

  func schedule(_ interval: TimeInterval, _ action: @escaping @MainActor () -> Void) -> () -> Void {
    let scheduled = ScheduledAction(interval: interval, action: action)
    actions.append(scheduled)
    return { scheduled.cancelled = true }
  }

  /// Runs each action that waits `interval` and is pending now, as if that much time passed.
  func fire(_ interval: TimeInterval) {
    for scheduled in actions where scheduled.interval == interval && scheduled.isPending {
      scheduled.fired = true
      scheduled.action()
    }
  }

  /// Runs every pending action, and each action that those actions schedule, in the order they were scheduled.
  func flush() {
    var runs = 0
    while runs < 100, let next = actions.first(where: \.isPending) {
      next.fired = true
      next.action()
      runs += 1
    }
  }
}

@MainActor
private final class RecordingPresenter: HoverCardPresenter {
  private(set) var shows: [(id: String, anchor: NSView)] = []
  private(set) var hides = 0
  private(set) var refreshes = 0

  func show(_ id: String, below anchor: NSView) { shows.append((id, anchor)) }
  func hide() { hides += 1 }
  func refresh(below anchor: NSView) { refreshes += 1 }
}

private final class MouseButtons {
  var pressed = false
}

/// A hover card controller with a recording presenter, a manual scheduler, and tile anchors for A and B.
@MainActor
private final class Fixture {
  let presenter: RecordingPresenter
  let scheduler: ManualScheduler
  let buttons: MouseButtons
  let card: HoverCard
  let a = NSView()
  let b = NSView()

  init() {
    let presenter = RecordingPresenter()
    let scheduler = ManualScheduler()
    let buttons = MouseButtons()
    self.presenter = presenter
    self.scheduler = scheduler
    self.buttons = buttons
    card = HoverCard(
      presenter: presenter, delay: delay, grace: grace, schedule: { scheduler.schedule($0, $1) },
      buttonsPressed: { buttons.pressed })
  }

  /// Rests the pointer on tile A until its card shows.
  func openA() {
    card.entered("A", anchor: a)
    scheduler.fire(delay)
  }

  /// Whether A's card is open and has never closed, once every pending action has run.
  func aStaysOpen() -> Bool {
    scheduler.flush()
    return card.shown == "A" && presenter.hides == 0
  }
}

@MainActor
@Suite struct HoverCardTests {
  @MainActor
  @Suite struct Showing {
    @Test func restingOnATileShowsItsCardAfterTheDelay() {
      let f = Fixture()

      f.openA()

      #expect(f.card.shown == "A")
    }

    @Test func theCardShowsBelowTheTileUnderThePointer() {
      let f = Fixture()

      f.openA()

      #expect(f.presenter.shows.map { $0.id } == ["A"])
      #expect(f.presenter.shows.first?.anchor === f.a)
    }

    @Test func theCardDoesNotShowBeforeTheDelay() {
      let f = Fixture()

      f.card.entered("A", anchor: f.a)

      #expect(f.card.shown == nil)
      #expect(f.presenter.shows.isEmpty)
    }

    @Test func leavingTheTileBeforeTheDelayShowsNoCard() {
      let f = Fixture()
      f.card.entered("A", anchor: f.a)

      f.card.exited("A", anchor: f.a)
      f.scheduler.flush()

      #expect(f.card.shown == nil)
      #expect(f.presenter.shows.isEmpty)
    }

    @Test func theDefaultDelayIsHalfASecond() {
      let presenter = RecordingPresenter()
      let scheduler = ManualScheduler()
      let card = HoverCard(presenter: presenter, schedule: { scheduler.schedule($0, $1) }, buttonsPressed: { false })
      card.entered("A", anchor: NSView())

      scheduler.fire(0.25)
      #expect(card.shown == nil)

      scheduler.fire(0.5)
      #expect(card.shown == "A")
    }
  }

  @MainActor
  @Suite struct Leaving {
    @Test func leavingTheTileKeepsTheCardOpenUntilTheGraceEnds() {
      let f = Fixture()
      f.openA()

      f.card.exited("A", anchor: f.a)

      #expect(f.card.shown == "A")
      #expect(f.presenter.hides == 0)
    }

    @Test func leavingTheTileHidesTheCardWhenTheGraceEnds() {
      let f = Fixture()
      f.openA()

      f.card.exited("A", anchor: f.a)
      f.scheduler.fire(grace)

      #expect(f.card.shown == nil)
      #expect(f.presenter.hides == 1)
    }

    @Test func theDefaultGraceIsAQuarterSecond() {
      let presenter = RecordingPresenter()
      let scheduler = ManualScheduler()
      let card = HoverCard(presenter: presenter, schedule: { scheduler.schedule($0, $1) }, buttonsPressed: { false })
      let anchor = NSView()
      card.entered("A", anchor: anchor)
      scheduler.fire(0.5)

      card.exited("A", anchor: anchor)
      scheduler.fire(0.25)

      #expect(card.shown == nil)
    }

    @Test func movingOntoTheCardKeepsItOpen() {
      let f = Fixture()
      f.openA()

      f.card.exited("A", anchor: f.a)
      f.card.enteredCard()

      #expect(f.aStaysOpen())
    }

    @Test func returningToTheTileWithinTheGraceKeepsTheCardOpen() {
      let f = Fixture()
      f.openA()

      f.card.exited("A", anchor: f.a)
      f.card.entered("A", anchor: f.a)

      #expect(f.aStaysOpen())
    }

    @Test func leavingTheCardKeepsItOpenUntilTheGraceEnds() {
      let f = Fixture()
      f.openA()
      f.card.exited("A", anchor: f.a)
      f.card.enteredCard()

      f.card.exitedCard()

      #expect(f.card.shown == "A")
      #expect(f.presenter.hides == 0)
    }

    @Test func leavingTheCardHidesItWhenTheGraceEnds() {
      let f = Fixture()
      f.openA()
      f.card.exited("A", anchor: f.a)
      f.card.enteredCard()

      f.card.exitedCard()
      f.scheduler.fire(grace)

      #expect(f.card.shown == nil)
      #expect(f.presenter.hides == 1)
    }

    @Test func leavingTheCardForItsTileKeepsItOpen() {
      let f = Fixture()
      f.openA()
      f.card.exited("A", anchor: f.a)
      f.card.enteredCard()

      f.card.exitedCard()
      f.card.entered("A", anchor: f.a)

      #expect(f.aStaysOpen())
    }

    @Test func leavingTheCardAndComingBackKeepsItOpen() {
      let f = Fixture()
      f.openA()
      f.card.exited("A", anchor: f.a)
      f.card.enteredCard()

      f.card.exitedCard()
      f.card.enteredCard()

      #expect(f.aStaysOpen())
    }
  }

  @MainActor
  @Suite struct Interrupt {
    @Test func anInterruptHidesTheCardAtOnce() {
      let f = Fixture()
      f.openA()

      f.card.interrupt()

      #expect(f.card.shown == nil)
      #expect(f.presenter.hides == 1)
    }

    @Test func anInterruptCancelsAPendingCard() {
      let f = Fixture()
      f.card.entered("A", anchor: f.a)

      f.card.interrupt()
      f.scheduler.flush()

      #expect(f.card.shown == nil)
      #expect(f.presenter.shows.isEmpty)
    }

    @Test func theTileDoesNotShowItsCardAgainWhileThePointerStays() {
      let f = Fixture()
      f.openA()

      f.card.interrupt()
      f.scheduler.flush()

      #expect(f.card.shown == nil)
      #expect(f.presenter.shows.count == 1)
    }

    /// A click selects the session, and SwiftUI rebuilds the tile under the resting pointer.
    @Test func aTileRebuiltUnderThePointerAfterAnInterruptShowsNoCard() {
      let f = Fixture()
      f.openA()
      f.card.interrupt()

      f.card.disappeared(anchor: f.a)
      f.card.appeared("A", anchor: NSView(), pointerInside: true)
      f.scheduler.flush()

      #expect(f.card.shown == nil)
      #expect(f.presenter.shows.count == 1)
    }

    @Test func leavingAndReenteringTheTileAfterAnInterruptShowsTheCardAgain() {
      let f = Fixture()
      f.openA()
      f.card.interrupt()

      f.card.exited("A", anchor: f.a)
      f.card.entered("A", anchor: f.a)
      f.scheduler.fire(delay)

      #expect(f.card.shown == "A")
      #expect(f.presenter.shows.count == 2)
    }

    @Test func anInterruptDoesNotStopAnotherTileFromShowingItsCard() {
      let f = Fixture()
      f.openA()
      f.card.interrupt()

      f.card.exited("A", anchor: f.a)
      f.card.entered("B", anchor: f.b)
      f.scheduler.fire(delay)

      #expect(f.card.shown == "B")
    }
  }

  @MainActor
  @Suite struct Drag {
    @Test func enteringATileWithAButtonDownSchedulesNoCard() {
      let f = Fixture()
      f.buttons.pressed = true

      f.card.entered("A", anchor: f.a)

      #expect(f.scheduler.count == 0)
    }

    @Test func enteringATileWithAButtonDownShowsNoCard() {
      let f = Fixture()
      f.buttons.pressed = true

      f.card.entered("A", anchor: f.a)
      f.scheduler.flush()

      #expect(f.card.shown == nil)
      #expect(f.presenter.shows.isEmpty)
    }

    @Test func aTileThatAppearsUnderTheDragSchedulesNoCard() {
      let f = Fixture()
      f.buttons.pressed = true

      f.card.appeared("A", anchor: f.a, pointerInside: true)

      #expect(f.scheduler.count == 0)
    }

    @Test func enteringAgainAfterTheButtonComesUpShowsTheCard() {
      let f = Fixture()
      f.buttons.pressed = true
      f.card.entered("A", anchor: f.a)
      f.card.exited("A", anchor: f.a)
      f.buttons.pressed = false

      f.card.entered("A", anchor: f.a)
      f.scheduler.fire(delay)

      #expect(f.card.shown == "A")
    }
  }

  @MainActor
  @Suite struct Switching {
    /// Moves the pointer from tile A to tile B, reporting the exit first or the entry first.
    private func moveFromAToB(_ f: Fixture, exitFirst: Bool) {
      if exitFirst {
        f.card.exited("A", anchor: f.a)
        f.card.entered("B", anchor: f.b)
      } else {
        f.card.entered("B", anchor: f.b)
        f.card.exited("A", anchor: f.a)
      }
    }

    @Test(arguments: [true, false])
    func enteringAnotherTileKeepsTheOpenCardUntilTheDelayEnds(exitFirst: Bool) {
      let f = Fixture()
      f.openA()

      moveFromAToB(f, exitFirst: exitFirst)
      f.scheduler.fire(grace)

      #expect(f.card.shown == "A")
      #expect(f.presenter.shows.map { $0.id } == ["A"])
    }

    @Test(arguments: [true, false])
    func enteringAnotherTileSwitchesTheCardWhenTheDelayEnds(exitFirst: Bool) {
      let f = Fixture()
      f.openA()

      moveFromAToB(f, exitFirst: exitFirst)
      f.scheduler.fire(delay)

      #expect(f.card.shown == "B")
      #expect(f.presenter.shows.last?.id == "B")
      #expect(f.presenter.shows.last?.anchor === f.b)
    }

    /// The card can cover the tile below A, so the pointer crosses B on its way onto the card.
    @Test(arguments: [true, false])
    func enteringTheCardBeforeTheDelayCancelsTheSwitch(exitFirst: Bool) {
      let f = Fixture()
      f.openA()

      moveFromAToB(f, exitFirst: exitFirst)
      f.card.enteredCard()

      #expect(f.aStaysOpen())
      #expect(f.presenter.shows.map { $0.id } == ["A"])
    }
  }

  @MainActor
  @Suite struct SessionsChanged {
    @Test func aChangeThatStillShowsTheSessionKeepsItsCardOpen() {
      let f = Fixture()
      f.openA()

      f.card.sessionsChanged(shown: ["A", "B"])

      #expect(f.aStaysOpen())
    }

    @Test func aChangeThatStillShowsTheSessionRefreshesItsCard() {
      let f = Fixture()
      f.openA()

      f.card.sessionsChanged(shown: ["A", "B"])

      #expect(f.presenter.refreshes == 1)
    }

    @Test(arguments: [Set<String>(), ["B"]])
    func aChangeWithoutTheSessionHidesItsCard(_ shown: Set<String>) {
      let f = Fixture()
      f.openA()

      f.card.sessionsChanged(shown: shown)

      #expect(f.card.shown == nil)
      #expect(f.presenter.hides == 1)
    }
  }

  @MainActor
  @Suite struct Anchors {
    @Test func aTileRebuiltUnderThePointerKeepsTheCardOpen() {
      let f = Fixture()
      f.openA()

      f.card.disappeared(anchor: f.a)
      f.card.appeared("A", anchor: NSView(), pointerInside: true)

      #expect(f.aStaysOpen())
    }

    @Test func aTileRebuiltWhileThePointerIsOnTheCardKeepsTheCardOpen() {
      let f = Fixture()
      f.openA()
      f.card.exited("A", anchor: f.a)
      f.card.enteredCard()

      f.card.disappeared(anchor: f.a)
      f.card.appeared("A", anchor: NSView(), pointerInside: false)

      #expect(f.aStaysOpen())
    }

    @Test func theTileLeavingTheWindowDoesNotHideTheCardAtOnce() {
      let f = Fixture()
      f.openA()

      f.card.disappeared(anchor: f.a)

      #expect(f.card.shown == "A")
      #expect(f.presenter.hides == 0)
    }

    @Test func theTileLeavingTheWindowWithNoNewTileHidesTheCardWhenTheGraceEnds() {
      let f = Fixture()
      f.openA()

      f.card.disappeared(anchor: f.a)
      f.scheduler.fire(grace)

      #expect(f.card.shown == nil)
      #expect(f.presenter.hides == 1)
    }

    @Test func leavingARebuiltTileHidesTheCardWhenTheGraceEnds() {
      let f = Fixture()
      f.openA()
      let rebuilt = NSView()
      f.card.disappeared(anchor: f.a)
      f.card.appeared("A", anchor: rebuilt, pointerInside: true)

      f.card.exited("A", anchor: rebuilt)
      f.scheduler.fire(grace)

      #expect(f.card.shown == nil)
    }

    @Test func anotherTileLeavingTheWindowKeepsTheCardOpen() {
      let f = Fixture()
      f.openA()

      f.card.disappeared(anchor: f.b)

      #expect(f.aStaysOpen())
    }

    /// The same session can show in the sidebar and on the Board at once.
    @Test func aSecondTileForTheSessionDoesNotTakeTheCardFromATileStillInItsWindow() {
      _ = NSApplication.shared
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [], backing: .buffered, defer: true)
      window.isReleasedWhenClosed = false
      defer { withExtendedLifetime(window) {} }
      let f = Fixture()
      window.contentView = f.a
      f.openA()
      let other = NSView()

      f.card.appeared("A", anchor: other, pointerInside: false)
      f.card.disappeared(anchor: other)

      #expect(f.aStaysOpen())
    }

    @Test func aTileRebuiltAfterTheGraceShowsTheCardAgainOnlyAfterTheDelay() {
      let f = Fixture()
      f.openA()
      f.card.disappeared(anchor: f.a)
      f.scheduler.fire(grace)
      let rebuilt = NSView()

      f.card.appeared("A", anchor: rebuilt, pointerInside: true)
      #expect(f.card.shown == nil)

      f.scheduler.fire(delay)
      #expect(f.card.shown == "A")
      #expect(f.presenter.shows.count == 2)
      #expect(f.presenter.shows.last?.anchor === rebuilt)
    }

    @Test func anotherSessionsTileInTheOldPlaceDoesNotTakeTheCard() {
      let f = Fixture()
      f.openA()

      f.card.disappeared(anchor: f.a)
      f.card.appeared("B", anchor: f.b, pointerInside: false)
      f.scheduler.fire(grace)

      #expect(f.card.shown == nil)
    }

    @Test func aTileThatAppearsUnderThePointerShowsItsCardAfterTheDelay() {
      let f = Fixture()

      f.card.appeared("A", anchor: f.a, pointerInside: true)
      f.scheduler.fire(delay)

      #expect(f.card.shown == "A")
      #expect(f.presenter.shows.first?.anchor === f.a)
    }

    @Test func aTileThatAppearsAwayFromThePointerShowsNoCard() {
      let f = Fixture()

      f.card.appeared("A", anchor: f.a, pointerInside: false)
      f.scheduler.flush()

      #expect(f.card.shown == nil)
      #expect(f.presenter.shows.isEmpty)
    }
  }
}

/// BoardModel tells its hover card which sessions it shows after each refresh and each org filter change.
@MainActor
@Suite struct HoverCardBoardModelTests {
  private func session(_ id: String, state: AttentionState = .working, reason: String = "") -> SessionSummary {
    var s = needsItem(id, state: state)
    s.reason = reason
    return s
  }

  /// A model that shows `list`, with its hover card open on A.
  private func openOnA(
    _ model: BoardModel, _ list: [SessionSummary], followups: [SessionSummary]? = nil
  ) -> Fixture {
    let f = Fixture()
    model.hoverCard = f.card
    model.apply(.success(list), followups: followups)
    f.openA()
    return f
  }

  @Test func anUpdateToAnotherSessionKeepsTheCardOpen() {
    let model = offlineModel()
    let f = openOnA(model, [session("A"), session("B")])

    model.apply(
      .success([session("A"), session("B", state: .needsYou, reason: "answer: which flag?")]), followups: nil)

    #expect(f.aStaysOpen())
  }

  @Test func aRebuiltTileThenAnUpdateToAnotherSessionKeepsTheCardOpen() {
    let model = offlineModel()
    let f = openOnA(model, [session("A"), session("B")])
    f.card.disappeared(anchor: f.a)
    f.card.appeared("A", anchor: NSView(), pointerInside: true)

    model.apply(
      .success([session("A"), session("B", state: .needsYou, reason: "answer: which flag?")]), followups: nil)

    #expect(f.aStaysOpen())
  }

  @Test func anUpdateToTheSessionKeepsItsCardOpen() {
    let model = offlineModel()
    let f = openOnA(model, [session("A"), session("B")])

    model.apply(.success([session("A", state: .waiting, reason: "waits on CI"), session("B")]), followups: nil)

    #expect(f.aStaysOpen())
  }

  @Test func anUpdateToTheSessionRefreshesItsCard() {
    let model = offlineModel()
    let f = openOnA(model, [session("A"), session("B")])
    let before = f.presenter.refreshes

    model.apply(.success([session("A", state: .waiting, reason: "waits on CI"), session("B")]), followups: nil)

    #expect(f.presenter.refreshes > before)
  }

  @Test func anUpdateThatRemovesTheSessionHidesItsCard() {
    let model = offlineModel()
    let f = openOnA(model, [session("A"), session("B")])

    model.apply(.success([session("B")]), followups: nil)

    #expect(f.card.shown == nil)
    #expect(f.presenter.hides == 1)
  }

  @Test func anUpdateToAShownFollowupsNeighborKeepsTheFollowupsCardOpen() {
    let model = offlineModel()
    let f = Fixture()
    model.hoverCard = f.card
    model.apply(.success([session("B")]), followups: [unstartedFollowup("F", nil)])
    f.card.entered("F", anchor: f.a)
    f.scheduler.fire(delay)

    model.apply(.success([session("B", state: .needsYou, reason: "answer: which flag?")]), followups: nil)
    f.scheduler.flush()

    #expect(f.card.shown == "F")
    #expect(f.presenter.hides == 0)
  }

  @Test func aFilterChangeThatHidesTheSessionHidesItsCard() {
    let model = orgFilterModel(OrgFilter())
    let f = openOnA(model, [orgSession("A", "haacked/switchboard"), orgSession("B", "PostHog/posthog")])

    model.orgFilter = posthogOnly

    #expect(f.card.shown == nil)
    #expect(f.presenter.hides == 1)
  }

  @Test func aFilterChangeThatKeepsTheSessionKeepsItsCardOpen() {
    let model = orgFilterModel(OrgFilter())
    let f = openOnA(model, [orgSession("A", "PostHog/posthog"), orgSession("B", "haacked/switchboard")])

    model.orgFilter = posthogOnly

    #expect(f.aStaysOpen())
  }

  @Test func aFilterChangeThatKeepsTheSessionRefreshesItsCard() {
    let model = orgFilterModel(OrgFilter())
    let f = openOnA(model, [orgSession("A", "PostHog/posthog"), orgSession("B", "haacked/switchboard")])
    let before = f.presenter.refreshes

    model.orgFilter = posthogOnly

    #expect(f.presenter.refreshes > before)
  }

  @Test func aRefreshThatMovesTheSessionOutOfTheFilterHidesItsCard() {
    let model = orgFilterModel(posthogOnly)
    let f = openOnA(model, [orgSession("A", "PostHog/posthog"), orgSession("B", "PostHog/posthog-js")])

    model.apply(
      .success([orgSession("A", "haacked/switchboard"), orgSession("B", "PostHog/posthog-js")]), followups: nil)

    #expect(f.card.shown == nil)
    #expect(f.presenter.hides == 1)
  }
}
