import Foundation
import SwitchboardCore

/// What sbd has seen of each child, and what it has not yet told each parent.
struct ParentNotices {
  var marks: [String: ChildMark] = [:]
  /// The lines for each parent, oldest first.
  var unsent: [String: [String]] = [:]
}

extension Service {
  private func parentOf(_ session: Session) -> String? {
    SessionTree.parentID(
      of: session.id, parent: session.parent, followup: session.followup, isKnown: { entries[$0] != nil })
  }

  private func mark(_ id: String, now: Int64) -> (mark: ChildMark, reason: String) {
    let e = entries[id]!
    // Until its first prompt, a child waits for the prompt that started it.
    if e.facts.prompts == 0, e.facts.lastReply == nil { return (.fresh, "") }
    let verdict = Attention.evaluate(e.session, e.facts, now: now, stateOf: lastState)
    return (ChildMark(state: verdict.state, pr: e.facts.pr?.number), verdict.reason)
  }

  /// Records what each child shows now, so sbd tells no parent about what
  /// happened before it started.
  func seedParentMarks(now: Int64) {
    for (id, e) in entries where parentOf(e.session) != nil { parentNotices.marks[id] = mark(id, now: now).mark }
  }

  /// Collects what changed in each child since the last tick, then sends each
  /// parent one message with everything it has not heard. A parent whose turn
  /// runs, or that still has a message on its way, hears it after the turn,
  /// so a busy parent gets one message for many changes.
  func notifyParents(now: Int64) {
    collectChildChanges(now: now)
    for parent in parentNotices.unsent.keys.sorted() {
      guard let e = entries[parent], !e.session.done else {
        parentNotices.unsent[parent] = nil
        continue
      }
      guard let lines = parentNotices.unsent[parent], !lines.isEmpty, canTakeNotice(e, now: now) else { continue }
      do {
        _ = try send(parent, ParentNotice.message(lines), byUser: false)
        parentNotices.unsent[parent] = nil
      } catch {
        logLine("can't tell \(parent) about its children: \(error)")
      }
    }
  }

  private func collectChildChanges(now: Int64) {
    var children: Set<String> = []
    for id in entries.keys.sorted() {
      guard let e = entries[id], let parent = parentOf(e.session) else { continue }
      children.insert(id)
      let (after, reason) = mark(id, now: now)
      let before = parentNotices.marks[id] ?? .fresh
      parentNotices.marks[id] = after
      guard after != before else { continue }
      parentNotices.unsent[parent, default: []] += ParentNotice.lines(
        name: e.session.name, id: id, before: before, after: after, reason: reason,
        prURL: e.facts.pr.flatMap { PRSummary($0).link?.absoluteString })
    }
    parentNotices.marks = parentNotices.marks.filter { children.contains($0.key) }
  }

  private func canTakeNotice(_ e: Entry, now: Int64) -> Bool {
    !e.messageWaiting(now: now) && !e.facts.turnRunning && !mcpStarting(now: now)
  }
}
