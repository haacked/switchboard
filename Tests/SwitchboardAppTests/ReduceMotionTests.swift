import SwiftUI
import Testing

@testable import SwitchboardApp

/// A scroll to the focused row jumps when the system's Reduce Motion setting is on. It animates otherwise.
@Suite struct ReduceMotionTests {
  @Test func aScrollJumpsWhenReduceMotionIsOn() {
    #expect(ReduceMotion.scrollAnimation(true) == nil)
  }

  @Test func aScrollAnimatesWhenReduceMotionIsOff() {
    #expect(ReduceMotion.scrollAnimation(false) == .default)
  }
}
