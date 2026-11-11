import Foundation
import SwitchboardCore

/// What sbd has seen of each child, and what it has not yet told each parent.
struct ParentNotices {
  /// What each child showed when its parent last heard about it. A work
  /// session hears about its children at each tick. A Manager or a chat
  /// hears at each digest.
  var marks: [String: ChildMark] = [:]
  /// The lines for each parent, oldest first.
  var unsent: [String: [String]] = [:]
  /// The counts that each Manager or chat got in its last digest.
  var heardCounts: [String: BoardCounts] = [:]
}

extension Service {
  private func parentOf(_ session: Session) -> String? {
    SessionTree.parentID(
      of: session.id, parent: session.parent, followup: session.followup, isKnown: { entries[$0] != nil })
  }

  private func mark(_ id: String, now: Int64) -> (mark: ChildMark, reason: String) {
    let e = entries[id]!
    let isDocket = e.session.docket != nil
    // Until its first prompt, a child waits for the prompt that started it. A docket row never gets a prompt.
    if !isDocket, e.facts.prompts == 0, e.facts.lastReply == nil { return (.fresh, "") }
    let verdict = Attention.evaluate(e.session, e.facts, now: now, stateOf: lastState)
    let needs = isDocket && verdict.state == .needsYou ? verdict.reason : nil
    return (ChildMark(state: verdict.state, pr: e.facts.pr?.number, needs: needs), verdict.reason)
  }

  /// Records that the child's parent hears what the child shows now. It
  /// returns the mark from before and the mark from now. The mark from now
  /// keeps every PR number that the parent heard before.
  private func hear(_ id: String, now: Int64) -> (before: ChildMark, after: ChildMark, reason: String) {
    let (seen, reason) = mark(id, now: now)
    let before = parentNotices.marks[id] ?? .fresh
    let after = before.updated(to: seen)
    parentNotices.marks[id] = after
    return (before, after, reason)
  }

  private func prURL(_ e: Entry) -> String? { e.facts.pr.flatMap { PRSummary($0).link?.absoluteString } }

  private func hearsNotices(_ parent: String) -> Bool { entries[parent]?.session.kind.hearsChildNotices ?? true }

  /// Records what each child shows now, every PR number it has had, and the
  /// counts that each Manager and chat would get now, so sbd tells no parent
  /// about what happened before it started.
  func seedParentMarks(now: Int64) {
    for (id, e) in entries where parentOf(e.session) != nil {
      var seeded = mark(id, now: now).mark
      seeded.heardPRs.formUnion(e.facts.prNumbers)
      parentNotices.marks[id] = seeded
    }
    for id in entries.keys where !hearsNotices(id) { parentNotices.heardCounts[id] = otherCounts(id) }
  }

  /// The states of the work sessions that are not the parent's children. A
  /// chat counts only the sessions in its group, because its tools reach no
  /// others.
  private func otherCounts(_ parent: String) -> BoardCounts {
    let group = entries[parent]?.session.chat
    var counts = BoardCounts()
    for e in entries.values
    where e.session.kind == .work && parentOf(e.session) != parent && (group == nil || e.session.group == group) {
      counts.add(e.facts.lastState)
    }
    return counts
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
      guard hearsNotices(parent) else { continue }
      let (before, after, reason) = hear(id, now: now)
      guard after != before else { continue }
      parentNotices.unsent[parent, default: []] += ParentNotice.lines(
        name: e.session.name, id: id, before: before, after: after, reason: reason,
        prURL: prURL(e))
    }
    parentNotices.marks = parentNotices.marks.filter { children.contains($0.key) }
    parentNotices.heardCounts = parentNotices.heardCounts.filter { entries[$0.key] != nil }
  }

  /// What changed for a Manager or a chat since its last digest: a line for
  /// each of its children that moved, and `otherCounts`. It is nil for a work session, and when nothing changed. sbd
  /// counts the digest as heard once it returns it.
  func digest(_ parent: String, now: Int64) -> String? {
    guard !hearsNotices(parent) else { return nil }
    var lines: [String] = []
    for id in entries.keys.sorted() {
      guard let e = entries[id], parentOf(e.session) == parent else { continue }
      let (heard, current, reason) = hear(id, now: now)
      if let line = ParentDigest.line(
        name: e.session.name, id: id, heard: heard, now: current, reason: reason, prURL: prURL(e))
      {
        lines.append(line)
      }
    }
    let counts = otherCounts(parent)
    let countsChanged = parentNotices.heardCounts[parent] != counts
    parentNotices.heardCounts[parent] = counts
    guard !lines.isEmpty || countsChanged else { return nil }
    return ParentDigest.text(lines, elsewhere: counts)
  }

  private func canTakeNotice(_ e: Entry, now: Int64) -> Bool {
    !e.messageWaiting(now: now) && !e.facts.turnRunning && !mcpStarting(now: now)
  }
}
