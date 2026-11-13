import Foundation
import os

/// The time that sbd runs on, in ms since the epoch. `nowMs()` reads it. A
/// test sbd moves it forward with the `clock` request, so a test can pass an
/// idle stop or a date wait without sleeping.
public enum Clock {
  private static let offset = OSAllocatedUnfairLock<Int64>(initialState: 0)

  public static func now() -> Int64 {
    offset.withLock { systemMs() + $0 }
  }

  /// Refuses an advance that would take the time past Int64's range, because
  /// `now()` would then stop the process.
  public static func advance(by ms: Int64) throws {
    try offset.withLock { current in
      let (next, overflow) = current.addingReportingOverflow(ms)
      guard !overflow, !systemMs().addingReportingOverflow(next).overflow else {
        throw APIError("can't move the clock \(ms) ms")
      }
      current = next
    }
  }

  private static func systemMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
}
