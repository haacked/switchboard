import Testing

@testable import SwitchboardApp

@Suite struct SurfaceLifetimeRules {
  /// A view that is in a window with a live surface.
  func live() -> SurfaceLifetime {
    var rules = SurfaceLifetime()
    #expect(rules.enteredWindow() == .create)
    rules.surfaceCreated()
    return rules
  }

  /// A view whose window closed and whose surface was freed.
  func closed() -> SurfaceLifetime {
    var rules = live()
    _ = rules.windowClosed()
    rules.surfaceFreed()
    return rules
  }

  /// A view that left its window and whose surface was freed.
  func left() -> SurfaceLifetime {
    var rules = live()
    _ = rules.leftWindow()
    rules.surfaceFreed()
    return rules
  }

  @Test func createsASurfaceWhenTheViewEntersAWindow() {
    var rules = SurfaceLifetime()
    #expect(rules.enteredWindow() == .create)
  }

  @Test func doesNotCreateASecondSurfaceWhenTheViewReentersAWindowWithOne() {
    var rules = live()
    #expect(rules.enteredWindow() == nil)
  }

  @Test func freesTheSurfaceWhenTheViewLeavesTheWindow() {
    var rules = live()
    #expect(rules.leftWindow() == .free)
    rules.surfaceFreed()
    #expect(rules.leftWindow() == nil)
  }

  @Test func createsANewSurfaceWhenAFreedViewComesBack() {
    var rules = left()
    #expect(rules.enteredWindow() == .create)
  }

  @Test func freesTheSurfaceWhenTheWindowCloses() {
    var rules = live()
    #expect(rules.windowClosed() == .free)
  }

  @Test func closingAWindowWithNoSurfaceFreesNothing() {
    var rules = SurfaceLifetime()
    _ = rules.enteredWindow()
    #expect(rules.windowClosed() == nil)
  }

  @Test func createsTheSurfaceAgainWhenAClosedWindowIsShown() {
    var rules = closed()
    #expect(rules.windowShown() == .create)
  }

  @Test func showingAWindowThatIsOpenCreatesNothing() {
    var rules = live()
    #expect(rules.windowShown() == nil)
  }

  @Test func showingAWindowTwiceCreatesOneSurface() {
    var rules = closed()
    #expect(rules.windowShown() == .create)
    rules.surfaceCreated()
    #expect(rules.windowShown() == nil)
  }

  @Test func retriesAFailedCreateWhenADisplayWakes() {
    var rules = SurfaceLifetime()
    _ = rules.enteredWindow()
    #expect(rules.displayWoke() == .create)
  }

  @Test func doesNotCreateOnWakeWhenASurfaceExists() {
    var rules = live()
    #expect(rules.displayWoke() == nil)
  }

  @Test func doesNotCreateOnWakeWhileTheWindowIsClosed() {
    var rules = closed()
    #expect(rules.displayWoke() == nil)
  }

  @Test func doesNotCreateOnWakeForAViewOutsideAWindow() {
    var rules = left()
    #expect(rules.displayWoke() == nil)
  }

  @Test func doesNotCreateWhenTheWindowIsShownForAViewOutsideAWindow() {
    var rules = closed()
    _ = rules.leftWindow()
    #expect(rules.windowShown() == nil)
  }

  @Test func aViewMovedToANewWindowAfterACloseGetsASurface() {
    var rules = closed()
    #expect(rules.enteredWindow() == .create)
  }
}
