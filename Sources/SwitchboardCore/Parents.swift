import Foundation

/// What sbd last saw of a child session: the part of its state that a parent hears about.
public struct ChildMark: Equatable, Sendable {
  public var state: AttentionState
  /// The number of the session's PR, or nil before it has one.
  public var pr: Int?

  public init(state: AttentionState, pr: Int?) {
    self.state = state
    self.pr = pr
  }

  /// What a child that sbd hasn't seen yet counts as having shown.
  public static let fresh = ChildMark(state: .working, pr: nil)
}

/// The messages that a parent session gets about its children.
public enum ParentNotice {
  /// The most lines in one message. The rest become a count.
  static let maxLines = 20

  /// The lines that say what changed between two sightings of a child: a new
  /// PR, then a move into Needs you or Done.
  public static func lines(
    name: String, id: String, before: ChildMark, after: ChildMark, reason: String, prURL: String?
  ) -> [String] {
    var lines: [String] = []
    if let number = after.pr, number != before.pr {
      lines.append("\(name) (\(id)) opened PR #\(number)" + (prURL.map { ": \($0)" } ?? ""))
    }
    if after.state != before.state {
      switch after.state {
      case .needsYou: lines.append("\(name) (\(id)) needs you: \(oneLine(reason))")
      case .done: lines.append("\(name) (\(id)) is done")
      default: break
      }
    }
    return lines
  }

  /// One line for all the changes that a parent has not heard yet.
  public static func message(_ lines: [String]) -> String {
    let more = lines.count > maxLines ? ["and \(lines.count - maxLines) more"] : []
    return "Switchboard: sessions you started changed: " + (Array(lines.prefix(maxLines)) + more).joined(separator: "; ") + "."
  }
}
