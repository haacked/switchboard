import Foundation

/// What sbd last saw of a child session: the part of its state that a parent hears about.
public struct ChildMark: Equatable, Sendable {
  public var state: AttentionState
  /// The number of the session's PR, or nil before it has one.
  public var pr: Int?
  /// Every PR number of the child that its parent has heard about. A PR that
  /// drops out and returns keeps its number here, so the parent does not
  /// hear about it twice.
  public var heardPRs: Set<Int>
  /// What a docket row in Needs you needs, or nil for any other child. A
  /// docket row can go from one need to another between two polls, such as
  /// from a failed poll to a ready draft. Its parent hears each need.
  public var needs: String?

  public init(state: AttentionState, pr: Int?, needs: String? = nil) {
    self.state = state
    self.pr = pr
    self.needs = needs
    heardPRs = pr.map { [$0] } ?? []
  }

  /// What a child that sbd hasn't seen yet counts as having shown.
  public static let fresh = ChildMark(state: .working, pr: nil)

  /// The mark after the parent hears `next`. It keeps the PR numbers that
  /// the parent heard before.
  public func updated(to next: ChildMark) -> ChildMark {
    var mark = next
    mark.heardPRs.formUnion(heardPRs)
    return mark
  }
}

/// The messages that a parent session gets about its children.
public enum ParentNotice {
  /// The most lines in one message. The rest become a count.
  static let maxLines = 20

  /// What changed between two sightings of a child that a parent hears
  /// about: a new PR, then a move into Needs you, Ready to merge, or Done.
  enum Change: Equatable {
    case pr(Int, url: String?)
    case needsYou(String)
    case readyToMerge(String)
    case done

    static func between(_ before: ChildMark, _ after: ChildMark, reason: String, prURL: String?) -> [Change] {
      var changes: [Change] = []
      if let number = after.pr, !before.heardPRs.contains(number) { changes.append(.pr(number, url: prURL)) }
      if after.state != before.state || after.needs != before.needs {
        switch after.state {
        case .needsYou: changes.append(.needsYou(oneLine(reason)))
        case .readyToMerge: changes.append(.readyToMerge(oneLine(reason)))
        case .done: changes.append(.done)
        default: break
        }
      }
      return changes
    }

    static func opened(_ number: Int, url: String?) -> String {
      "opened PR #\(number)" + (url.map { ": \($0)" } ?? "")
    }
  }

  /// The lines that say what changed between two sightings of a child, one per change.
  public static func lines(
    name: String, id: String, before: ChildMark, after: ChildMark, reason: String, prURL: String?
  ) -> [String] {
    Change.between(before, after, reason: reason, prURL: prURL).map {
      switch $0 {
      case .pr(let number, let url): "\(name) (\(id)) \(Change.opened(number, url: url))"
      case .needsYou(let reason): "\(name) (\(id)) needs you: \(reason)"
      case .readyToMerge(let reason): "\(name) (\(id)): \(reason)"
      case .done: "\(name) (\(id)) is done"
      }
    }
  }

  /// One line for all the changes that a parent has not heard yet. A child
  /// that returns to a state before its parent hears it adds the same line
  /// twice. The message keeps only the last copy, so each child's latest
  /// line stays after its older ones.
  public static func message(_ lines: [String]) -> String {
    var seen: Set<String> = []
    let lines = Array(lines.reversed().filter { seen.insert($0).inserted }.reversed())
    let more = lines.count > maxLines ? ["and \(lines.count - maxLines) more"] : []
    return "Switchboard: sessions you started changed: "
      + (Array(lines.prefix(maxLines)) + more).joined(separator: "; ") + "."
  }
}

extension SessionKind {
  /// Whether sbd sends this kind of session a message when a child changes. A
  /// Manager or a chat instead gets a digest with the user's next prompt.
  public var hearsChildNotices: Bool { self == .work }
}

/// How many sessions outside a parent's own children need the user.
public struct BoardCounts: Equatable, Sendable {
  public var needsYou: Int
  public var readyToMerge: Int

  public init(needsYou: Int = 0, readyToMerge: Int = 0) {
    self.needsYou = needsYou
    self.readyToMerge = readyToMerge
  }

  public mutating func add(_ state: AttentionState?) {
    switch state {
    case .needsYou: needsYou += 1
    case .readyToMerge: readyToMerge += 1
    default: break
    }
  }
}

/// The text that a Manager or a chat gets with a prompt, through the
/// `additionalContext` of its UserPromptSubmit hook. Claude Code shows it to
/// the model and keeps it out of the conversation's messages.
public enum ParentDigest {
  /// The most child lines in one digest. The rest become a count.
  static let maxLines = 15

  /// One line for what changed in a child between what its parent last heard
  /// and now, or nil when nothing it would hear about changed. A child that
  /// moved into a state and out again before the parent heard gets no line.
  public static func line(
    name: String, id: String, heard: ChildMark, now: ChildMark, reason: String, prURL: String?
  ) -> String? {
    let parts = ParentNotice.Change.between(heard, now, reason: reason, prURL: prURL).map {
      switch $0 {
      case .pr(let number, let url): ParentNotice.Change.opened(number, url: url)
      case .needsYou(let reason): "needs you: \(reason)"
      case .readyToMerge(let reason): reason
      case .done: "done"
      }
    }
    return parts.isEmpty ? nil : "\(name) (\(id)): " + parts.joined(separator: "; ")
  }

  public static func text(_ lines: [String], elsewhere: BoardCounts) -> String {
    var out = ["Switchboard: what changed since your last turn."]
    if !lines.isEmpty {
      out.append("Sessions you started:")
      out += lines.prefix(maxLines).map { "- \($0)" }
      if lines.count > maxLines { out.append("- and \(lines.count - maxLines) more") }
    }
    out.append("Other sessions: \(elsewhere.needsYou) in Needs you, \(elsewhere.readyToMerge) in Ready to merge.")
    return out.joined(separator: "\n")
  }

  /// What sbd answers a UserPromptSubmit hook with to add `text` to the prompt.
  public static func hookOutput(_ text: String) -> JSON {
    ["hookSpecificOutput": ["hookEventName": "UserPromptSubmit", "additionalContext": .string(text)]]
  }
}
