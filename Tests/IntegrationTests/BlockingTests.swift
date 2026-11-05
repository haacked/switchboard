import Foundation
import Testing

/// These tests call the trait's scope directly, with slots of their own, so
/// they never wait behind the integration tests.
@Suite struct BlockingTests {
  final class Running: @unchecked Sendable {
    private let lock = NSLock()
    private var now = 0
    private var most = 0
    var peak: Int { lock.withLock { most } }
    func enter() {
      lock.withLock {
        now += 1
        most = max(most, now)
      }
    }
    func leave() { lock.withLock { now -= 1 } }
  }

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
}
