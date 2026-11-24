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

/// A parent session leaves its children's questions in the children's own Inbox items. The user then answers
/// each question in one place.
public enum ChildQuestions {
  /// The guidance that the Manager guide, the chat guide, and the default system prompt give every agent.
  public static let guidance =
    "If you started other sessions, each one asks the user its own questions in its own Inbox item. Never ask the user a question or decision that one of those sessions already asks, whether in a reply, with `sb summary set`, or in a report. Link to that session and say in a few words what it waits on, without copying its question, such as \"[fix-cache](switchboard://session/swb_eb4ec) asks you to pick a cache size in its Inbox item.\" Ask the user only your own decisions, such as whether to merge a PR, remove a worktree, or send one message to several sessions."

}

/// How a parent session learns that a child changed. The Manager guide and the chat guide say the same in their own words.
public enum ChildChanges {
  /// The guidance that the default system prompt gives every work session.
  public static let guidance =
    "Switchboard sends you no message when a session you started changes. Instead, the context of a prompt can list what changed since your last turn: each session you started that opened a PR, moved to Needs you or Ready to merge, or reached Done, and how many other sessions are in Needs you and Ready to merge. To follow a session until it reaches a state, set a `session` wait on it with `sb wait` or `set_wait`. The wait resumes you when the session gets there."
}

/// What changed between two sightings of a child that a parent hears about: a new PR, then a move into Needs you,
/// Ready to merge, or Done.
enum ChildChange: Equatable {
  case pr(Int, url: String?)
  case needsYou(String)
  case readyToMerge(String)
  case done

  static func between(_ before: ChildMark, _ after: ChildMark, reason: String, prURL: String?) -> [ChildChange] {
    var changes: [ChildChange] = []
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

  /// The child's link goes in the line so that the parent can copy it when it points the user at the item.
  static func needsYou(id: String, reason: String) -> String {
    "needs you in its own Inbox item (\(SessionLink.url(for: id).absoluteString)): \(reason)"
  }
}

/// How many sessions outside a parent's own children need the user.
public struct BoardCounts: Sendable {
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

/// The text that a parent session gets with a prompt, through the
/// `additionalContext` of its UserPromptSubmit hook. Claude Code saves it in
/// the conversation's transcript as an attachment, so every later call in the
/// conversation reads it again.
public enum ParentDigest {
  /// The most child lines in one digest. The rest become a count.
  static let maxLines = 15

  /// One line for what changed in a child between what its parent last heard
  /// and now, or nil when nothing it would hear about changed. A child that
  /// moved into a state and out again before the parent heard gets no line.
  public static func line(
    name: String, id: String, heard: ChildMark, now: ChildMark, reason: String, prURL: String?
  ) -> String? {
    let parts = ChildChange.between(heard, now, reason: reason, prURL: prURL).map {
      switch $0 {
      case .pr(let number, let url): ChildChange.opened(number, url: url)
      case .needsYou(let reason): ChildChange.needsYou(id: id, reason: reason)
      case .readyToMerge(let reason): reason
      case .done: "done"
      }
    }
    return parts.isEmpty ? nil : "\(sessionMention(name: name, id: id)): " + parts.joined(separator: "; ")
  }

  /// `lines` holds at least one line. `Service.digest` sends nothing when no child changed.
  public static func text(_ lines: [String], elsewhere: BoardCounts) -> String {
    var out = ["Switchboard: what changed since your last turn.", "Sessions you started:"]
    out += lines.prefix(maxLines).map { "- \($0)" }
    if lines.count > maxLines { out.append("- and \(lines.count - maxLines) more") }
    out.append("Other sessions: \(elsewhere.needsYou) in Needs you, \(elsewhere.readyToMerge) in Ready to merge.")
    return out.joined(separator: "\n")
  }

  /// The digest that a new Manager conversation starts with: every session
  /// once, one line each, grouped by state, then the open Inbox items in the
  /// Inbox's order.
  public static func startText(_ sessions: [SessionSummary], inbox: [SessionSummary]) -> String {
    var out = ["Switchboard: the sessions as this conversation starts."]
    if sessions.isEmpty { out.append("There are no other sessions.") }
    for state in AttentionState.allCases {
      let rows = sessions.filter { $0.state == state }
      guard !rows.isEmpty else { continue }
      out.append("\(state.title):")
      out += rows.map { "- \(sessionMention(name: $0.name, id: $0.id)): \(oneLine($0.reason, max: 120))" }
    }
    let items = inboxLines(inbox)
    if !items.isEmpty { out += ["Inbox:"] + items }
    return out.joined(separator: "\n")
  }

  /// One line for each session in `inbox` that has an Inbox item, with the item's title.
  public static func inboxLines(_ inbox: [SessionSummary]) -> [String] {
    inbox.compactMap { s in s.triage.map { "- \(sessionMention(name: s.name, id: s.id)): \($0.title)" } }
  }

  /// What sbd answers a hook with to add `text` to the model's context.
  /// `event` is the hook's event name, such as UserPromptSubmit.
  public static func hookOutput(_ text: String, event: String) -> JSON {
    ["hookSpecificOutput": ["hookEventName": .string(event), "additionalContext": .string(text)]]
  }
}
