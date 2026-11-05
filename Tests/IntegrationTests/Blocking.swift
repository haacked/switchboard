import Foundation
import Testing

/// Runs each test of a suite once it gets one of `slots`. It fails a test whose
/// body runs past `timeLimit`.
///
/// An integration test blocks a thread of Swift's cooperative pool while it
/// waits on sbd, tmux, or a command. The pool has one thread per CPU. The
/// Swift Testing in Xcode 26.0 starts every test at once and ignores
/// `SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH`. Blocked tests then hold
/// every thread. An async test waits behind hundreds of queued tests for a
/// thread to resume on. Its time limit passes while it waits. A test that
/// waits here for a slot suspends without holding a thread.
///
/// Swift Testing's `.timeLimit` counts the wait for a slot, so a suite with
/// this trait sets its limit here. The limit starts when the test gets a slot.
struct Blocking: SuiteTrait, TestTrait, TestScoping {
  var timeLimit: Duration?
  var slots = Slots.shared

  var isRecursive: Bool { true }

  @TaskLocal static var holdsSlot = false

  /// Records an issue when the caller runs outside a test with this trait.
  /// Every test that starts sbd blocks a thread, so it needs a slot.
  static func requireSlot() {
    if !holdsSlot { Issue.record("Add .blocking(timeLimit:) to the suite of a test that starts sbd") }
  }

  func provideScope(
    for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void
  ) async throws {
    guard testCase != nil else { return try await function() }
    await slots.acquire()
    do {
      try await Blocking.$holdsSlot.withValue(true) { try await run(function) }
    } catch {
      await slots.release()
      throw error
    }
    await slots.release()
  }

  /// Like Swift Testing's time limit, this records an issue when the limit
  /// passes and then waits for the body, which a synchronous test can't stop.
  private func run(_ body: @Sendable () async throws -> Void) async throws {
    guard let timeLimit else { return try await body() }
    try await withoutActuallyEscaping(body) { body in
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
          try await Task.sleep(for: timeLimit)
          Issue.record("Time limit was exceeded: \(timeLimit)")
        }
        group.addTask(operation: body)
        defer { group.cancelAll() }
        try await group.next()
      }
    }
  }
}

extension Trait where Self == Blocking {
  static func blocking(timeLimit: Duration? = nil) -> Blocking { Blocking(timeLimit: timeLimit) }
}

/// A counting semaphore whose waiters suspend instead of blocking a thread.
actor Slots {
  /// No integration test holds the last thread of the pool.
  static let shared = Slots(width: max(1, ProcessInfo.processInfo.activeProcessorCount - 1))

  private var free: Int
  private var waiting: [CheckedContinuation<Void, Never>] = []

  init(width: Int) {
    free = width
  }

  func acquire() async {
    if free > 0 {
      free -= 1
      return
    }
    await withCheckedContinuation { waiting.append($0) }
  }

  func release() {
    if waiting.isEmpty {
      free += 1
    } else {
      waiting.removeFirst().resume()
    }
  }
}
