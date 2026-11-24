import Foundation
import SwitchboardCore

/// What sbd has seen of each child.
struct ParentNotices {
  /// What each child showed when its parent last heard about it. A parent
  /// hears at each digest.
  var marks: [String: ChildMark] = [:]
}

extension Service {
  func parentOf(_ session: Session) -> String? {
    SessionTree.parentID(
      of: session.id, parent: session.parent, followup: session.followup, isKnown: { entries[$0] != nil })
  }

  /// What the child's parent sees of it. A parent on a host sees the child as `showsGitHub` lets that host see it.
  private func mark(_ id: String, now: Int64) -> (mark: ChildMark, reason: String) {
    let e = entries[id]!
    let facts = factsForParent(id)
    let isDocket = e.session.docket != nil
    // Until its first prompt, a child waits for the prompt that started it. A docket row never gets a prompt.
    if !isDocket, facts.prompts == 0, facts.lastReply == nil { return (.fresh, "") }
    let verdict = Attention.evaluate(e.session, facts, now: now, stateOf: lastState)
    let needs = isDocket && verdict.state == .needsYou ? verdict.reason : nil
    return (ChildMark(state: verdict.state, pr: facts.pr?.number, needs: needs), verdict.reason)
  }

  /// The child's facts as its parent may read them. A parent on a host reads them as a request from that host.
  private func factsForParent(_ id: String) -> SessionFacts {
    shownFacts(id, for: RequestOrigin(host: parentOf(entries[id]!.session).flatMap { entries[$0]?.session.host }))
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

  private func prURL(_ id: String) -> String? {
    factsForParent(id).pr.flatMap { PRSummary($0).link?.absoluteString }
  }

  /// Records what each child shows now and every PR number it has had, so sbd
  /// tells no parent about what happened before it started.
  func seedParentMarks(now: Int64) {
    for (id, e) in entries where parentOf(e.session) != nil { seedMark(id, now: now) }
  }

  /// Records what the child shows now and every PR number it has had, so its
  /// parent hears only what changes after now.
  func seedMark(_ id: String, now: Int64) {
    var seeded = mark(id, now: now).mark
    seeded.heardPRs.formUnion(factsForParent(id).prNumbers)
    parentNotices.marks[id] = seeded
  }

  /// Drops the mark of a child that left its parent or was removed. A child that still has a parent and no mark
  /// gets a line for its whole current state at the next digest, so a caller that links it to a new parent
  /// calls `seedMark` afterward.
  func forgetChild(_ id: String) {
    parentNotices.marks[id] = nil
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

  /// What changed for a parent since its last digest: a line for each of its
  /// children that moved, and `otherCounts`. sbd sends a parent no message when
  /// a child changes, so this digest is how every parent hears. It is nil when
  /// none of the parent's children moved. A change in the counts alone sends no
  /// digest, because each digest stays in the conversation's context for every
  /// later call. sbd counts the digest as heard once it returns it. The
  /// operator gets none, because its turns come from schedules and waits that
  /// carry their own status.
  func digest(_ parent: String, now: Int64) -> String? {
    guard entries[parent]?.session.kind != .operator else { return nil }
    var lines: [String] = []
    for id in entries.keys.sorted() {
      guard let e = entries[id], parentOf(e.session) == parent else { continue }
      let (heard, current, reason) = hear(id, now: now)
      if let line = ParentDigest.line(
        name: e.session.name, id: id, heard: heard, now: current, reason: reason, prURL: prURL(id))
      {
        lines.append(line)
      }
    }
    guard !lines.isEmpty else { return nil }
    return ParentDigest.text(lines, elsewhere: otherCounts(parent))
  }

  /// The digest that a Manager conversation or the operator gets when its
  /// conversation starts, which a SessionStart with `source` startup reports.
  /// It is nil for every other kind and source. It leaves out every Manager
  /// conversation and the operator.
  func startDigest(_ id: String, source: String?) -> String? {
    guard let session = entries[id]?.session, session.kind.runsInManagerFolder, source == "startup" else { return nil }
    let all = summaries(for: RequestOrigin(host: session.host)).filter { $0.id != id && !$0.kind.runsInManagerFolder }
    return ParentDigest.startText(all, inbox: Triage.order(all))
  }

  func canTakeNotice(_ e: Entry, now: Int64) -> Bool {
    Pause.blocker(e.session) == nil && !messageWaiting(e, now: now) && !e.facts.turnRunning
      && !mcpStarting(now: now)
  }
}
