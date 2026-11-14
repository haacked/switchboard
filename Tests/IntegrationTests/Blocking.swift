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
    let start = ContinuousClock.now
    defer { Blocking.report(test, held: ContinuousClock.now - start) }
    do {
      try await Blocking.$holdsSlot.withValue(true) { try await run(function) }
    } catch {
      await slots.release()
      throw error
    }
    await slots.release()
  }

  /// Prints how long a test held its slot. Swift Testing's durations include
  /// the wait for a slot. bin/shard-weights sums these lines by suite to
  /// balance bin/test's shards. A single write keeps the line whole among the
  /// other output of the test process.
  private static func report(_ test: Test, held: Duration) {
    let line = "slot-seconds \(String(format: "%.3f", held / .seconds(1))) \(test.id)\n"
    FileHandle.standardOutput.write(Data(line.utf8))
  }

  /// Like Swift Testing's time limit, this records an issue when the limit
  /// passes and then waits for the body, which a synchronous test can't stop.
  private func run(_ body: @Sendable () async throws -> Void) async throws {
    guard let timeLimit else { return try await body() }
    try await withoutActuallyEscaping(body) { body in
      try await withThrowingTaskGroup(of: Bool.self) { group in
        group.addTask {
          try await Task.sleep(for: timeLimit)
          Issue.record("Time limit was exceeded: \(timeLimit)")
          return false
        }
        group.addTask {
          try await body()
          return true
        }
        defer { group.cancelAll() }
        // The group discards the error of a child that it awaits on exit.
        // This second call rethrows the error of a body that outlasts the limit.
        if try await group.next() == false { _ = try await group.next() }
      }
    }
  }
}

extension Trait where Self == Blocking {
  static func blocking(timeLimit: Duration? = nil) -> Blocking { Blocking(timeLimit: timeLimit) }
}

/// A counting semaphore whose waiters suspend instead of blocking a thread.
actor Slots {
  /// The slots of every integration suite in this test process. A test that
  /// starts sbd records an issue unless it holds a slot, so the width caps how
  /// many test sbds run at once. Each such test keeps its tmux server and stub
  /// claudes until it releases the slot, so the width caps those too. A cap
  /// around Instance.init alone would block a pool thread while it waits, and
  /// it would cover only the start of sbd. bin/test --shards N starts N test
  /// processes, so N times the width run at once.
  static let shared = Slots(
    width: width(
      environment: ProcessInfo.processInfo.environment, processors: ProcessInfo.processInfo.activeProcessorCount))

  /// SB_TEST_SLOTS sets the width as a positive integer. Without a valid
  /// value, the width is 4, or one less than the processor count when that is
  /// lower. The width never exceeds one less than the processor count, so no
  /// integration test holds the last thread of the pool. It is at least 1.
  static func width(environment: [String: String], processors: Int) -> Int {
    let most = max(1, processors - 1)
    guard let asked = environment["SB_TEST_SLOTS"].flatMap({ Int($0) }), asked > 0 else { return min(4, most) }
    return min(asked, most)
  }

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
