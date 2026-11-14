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

  /// Each row holds the environment, the processor count, and the width. The clamp to one less than the processor
  /// count keeps the last thread of the pool free of integration tests.
  static let widthRows: [([String: String], Int, Int)] = {
    let unset: [([String: String], Int, Int)] = [([:], 3, 2), ([:], 5, 4), ([:], 18, 4), ([:], 64, 4)]
    let valid: [([String: String], Int, Int)] = [("1", 1), ("2", 2), ("10", 10), ("17", 17), ("18", 17), ("100", 17)]
      .map { (["SB_TEST_SLOTS": $0], 18, $1) }
    let invalid: [([String: String], Int, Int)] = ["0", "-1", "x", "", " 2", "2.5", "two"]
      .map { (["SB_TEST_SLOTS": $0], 18, 4) }
    let fewProcessors: [([String: String], Int, Int)] = [1, 2].flatMap { processors in
      ([nil, "1", "2", "4", "0", "x"] as [String?]).map { value in
        (value.map { ["SB_TEST_SLOTS": $0] } ?? [:], processors, 1)
      }
    }
    let otherNames: [([String: String], Int, Int)] = [(["SB_TEST_SLOT": "2", "SB_SLOTS": "2"], 18, 4)]
    return unset + valid + invalid + fewProcessors + otherNames
  }()

  @Test(arguments: widthRows)
  func slotsWidthFollowsTheVariableAndTheProcessorCount(environment: [String: String], processors: Int, width: Int) {
    #expect(Slots.width(environment: environment, processors: processors) == width)
  }
}
