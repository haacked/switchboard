import AppKit
import SwitchboardCore
import Testing

@testable import SwitchboardApp

/// AppKit numbers the side buttons 3 and 4. Users call them buttons 4 and 5.
@MainActor
@Suite struct NavMouseTests {
  struct Input: Sendable, CustomTestStringConvertible {
    var name: String
    var type: NSEvent.EventType
    var buttonNumber = 0
    var deltaX: CGFloat = 0
    var expected: NavDirection?
    var testDescription: String { name }
  }

  nonisolated static let inputs = [
    Input(name: "the back side button", type: .otherMouseDown, buttonNumber: 3, expected: .back),
    Input(name: "the forward side button", type: .otherMouseDown, buttonNumber: 4, expected: .forward),
    Input(name: "the middle button", type: .otherMouseDown, buttonNumber: 2),
    Input(name: "button zero", type: .otherMouseDown, buttonNumber: 0),
    Input(name: "a button past the side buttons", type: .otherMouseDown, buttonNumber: 5),
    // The monitor acts on the press. The release must not run the step a second time.
    Input(name: "releasing a side button", type: .otherMouseUp, buttonNumber: 3),
    Input(name: "a swipe with positive deltaX", type: .swipe, deltaX: 1, expected: .back),
    Input(name: "a swipe with negative deltaX", type: .swipe, deltaX: -1, expected: .forward),
    Input(name: "a swipe with zero deltaX", type: .swipe),
    Input(name: "a left click with button number 3", type: .leftMouseDown, buttonNumber: 3),
    Input(name: "a horizontal scroll", type: .scrollWheel, deltaX: 1),
  ]

  @Test(arguments: inputs)
  func eachEventMapsToItsDirection(_ input: Input) {
    #expect(
      NavMouse.direction(type: input.type, buttonNumber: input.buttonNumber, deltaX: input.deltaX) == input.expected)
  }

  /// A press with no window, which matches the test process's missing Switchboard window.
  private func sideButtonPress(_ button: Int) throws -> NSEvent { try #require(ShellSelfTest.otherMouseDown(button)) }

  @Test func aSideButtonDoesNothingWhileASheetShows() throws {
    let model = appliedModel(["a", "b"].map { needsItem($0) })
    model.selection = "a"
    model.selection = "b"
    model.showingNew = true

    #expect(!NavMouse.handle(try sideButtonPress(3), model))
    #expect(model.selection == "b")

    model.showingNew = false

    #expect(NavMouse.handle(try sideButtonPress(3), model))
    #expect(model.selection == "a")
  }

  /// The terminal under the pointer must never get a side button, even when there is nowhere to go.
  @Test func aSideButtonWithNowhereToGoIsStillUsed() throws {
    let model = appliedModel([needsItem("a")])
    #expect(!model.canGoForward)

    #expect(NavMouse.handle(try sideButtonPress(4), model))
  }
}
