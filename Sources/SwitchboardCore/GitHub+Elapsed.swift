import Foundation

extension GitHub {
  /// Whether `interval` ms have passed since `since`, or `since` is nil.
  public static func elapsed(since: Int64?, _ interval: Int64, now: Int64) -> Bool {
    since.map { now - $0 >= interval } ?? true
  }
}
