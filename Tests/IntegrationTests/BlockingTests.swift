import Foundation
import Testing
import os

/// These tests call the trait's scope directly, with slots of their own, so
/// they never wait behind the integration tests.
@Suite struct BlockingTests {
  final class Running: Sendable {
    private let counts = OSAllocatedUnfairLock(initialState: (now: 0, most: 0))
    var peak: Int { counts.withLock { $0.most } }
    func enter() {
      counts.withLock {
        $0.now += 1
        $0.most = max($0.most, $0.now)
      }
    }
    func leave() { counts.withLock { $0.now -= 1 } }
  }

  struct Thrown: Error {}

  func scope(_ trait: Blocking, _ body: @escaping @Sendable () async throws -> Void) async throws {
    try await trait.provideScope(for: Test.current!, testCase: Test.Case.current, performing: body)
  }

  @Test func runsNoMoreBodiesAtOnceThanItHasSlots() async throws {
    let trait = Blocking(slots: Slots(width: 2))
    let running = Running()
    try await withThrowingTaskGroup(of: Void.self) { group in
      for _ in 0..<6 {
        group.addTask {
          try await scope(trait) {
            running.enter()
            // The sleep keeps this body running while the others try to start.
            try await Task.sleep(for: .milliseconds(50))
            running.leave()
          }
        }
      }
      try await group.waitForAll()
    }
    #expect(running.peak == 2)
  }

  @Test func recordsAnIssueWhenTheBodyOutlastsTheLimit() async throws {
    let trait = Blocking(timeLimit: .milliseconds(10), slots: Slots(width: 1))
    try await withKnownIssue {
      try await scope(trait) { usleep(300_000) }
    } matching: {
      $0.comments.contains { $0.rawValue.hasPrefix("Time limit was exceeded") }
    }
  }

  @Test func rethrowsTheErrorOfABodyThatOutlastsTheLimit() async {
    let trait = Blocking(timeLimit: .milliseconds(10), slots: Slots(width: 1))
    await withKnownIssue {
      await #expect(throws: Thrown.self) {
        try await scope(trait) {
          usleep(300_000)
          throw Thrown()
        }
      }
    } matching: {
      $0.comments.contains { $0.rawValue.hasPrefix("Time limit was exceeded") }
    }
  }

  @Test func freesTheSlotOfABodyThatThrows() async throws {
    let trait = Blocking(slots: Slots(width: 1))
    await #expect(throws: Thrown.self) { try await scope(trait) { throw Thrown() } }
    // A leaked slot would suspend this body forever, so the test polls for it.
    let running = Running()
    Task { try await scope(trait) { running.enter() } }
    for _ in 0..<250 where running.peak == 0 { try await Task.sleep(for: .milliseconds(20)) }
    #expect(running.peak == 1)
  }

  @Test func startsTheLimitWhenTheBodyGetsASlot() async throws {
    let slots = Slots(width: 1)
    let trait = Blocking(timeLimit: .milliseconds(200), slots: slots)
    await slots.acquire()
    let waiting = Task { try await scope(trait) {} }
    try await Task.sleep(for: .milliseconds(400))
    await slots.release()
    try await waiting.value
  }

  @Test func letsTheBodyStartSbdOnlyWhileItHoldsASlot() async throws {
    withKnownIssue { Blocking.requireSlot() }
    try await scope(Blocking(slots: Slots(width: 1))) { Blocking.requireSlot() }
  }

  @Test(arguments: [3, 5, 18, 64])
  func runsAtMostFourAtOnceWhenTheVariableIsUnset(processors: Int) {
    #expect(Slots.width(environment: [:], processors: processors) == min(4, processors - 1))
  }

  @Test func takesThePositiveWidthThatTheVariableSets() {
    #expect(Slots.width(environment: ["SB_TEST_SLOTS": "2"], processors: 18) == 2)
  }

  @Test func takesAWidthOfOne() {
    #expect(Slots.width(environment: ["SB_TEST_SLOTS": "1"], processors: 18) == 1)
  }

  @Test func takesAWidthAboveTheDefault() {
    #expect(Slots.width(environment: ["SB_TEST_SLOTS": "10"], processors: 18) == 10)
  }

  @Test(arguments: ["0", "-1", "x", "", " 2", "2.5", "two"])
  func runsAtMostFourAtOnceWhenTheVariableIsInvalid(value: String) {
    #expect(Slots.width(environment: ["SB_TEST_SLOTS": value], processors: 18) == 4)
  }

  // The clamp keeps the last thread of the pool free of integration tests.
  @Test(arguments: ["17", "18", "100"])
  func leavesOneProcessorFreeOfIntegrationTests(value: String) {
    #expect(Slots.width(environment: ["SB_TEST_SLOTS": value], processors: 18) == 17)
  }

  @Test(arguments: [nil, "1", "2", "4", "0", "x"] as [String?], [1, 2])
  func runsOneAtATimeOnOneOrTwoProcessors(value: String?, processors: Int) {
    let environment = value.map { ["SB_TEST_SLOTS": $0] } ?? [:]
    #expect(Slots.width(environment: environment, processors: processors) == 1)
  }

  @Test func ignoresOtherVariables() {
    let environment = ["SB_TEST_SLOT": "2", "SB_SLOTS": "2"]
    #expect(Slots.width(environment: environment, processors: 18) == 4)
  }
}
