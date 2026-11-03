import Foundation
import SwitchboardCore

extension Service {
  func groupRequest(_ op: String, _ args: JSON) throws -> JSON {
    switch op {
    case "group-ls":
      return try JSON(encoding: groupList())
    case "group-add":
      guard let name = args["name"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
        throw APIError("group add needs a name")
      }
      let ids = try sessionRefs(args)
      let notes = try args["note"].map { try [makeNote($0.string, by: args["by"]?.string, after: [])] } ?? []
      try refuseUngroupable(ids)
      let id = try createGroup(name, notes: notes).id
      try place(ids, in: id)
      return try JSON(encoding: groupSummary(id))
    case "group-rm":
      let id = try lookupGroup(args)
      let members = members(id).map(\.id)
      // This skips `place`, so a session that took its parent's group stays open to suggestions.
      for member in members { try update(member) { $0.group = nil } }
      try store.delete(group: id)
      groups[id] = nil
      return ["removed": .string(id), "ungrouped": .array(members.map(JSON.string))]
    case "group-move":
      let ids = try sessionRefs(args)
      guard !ids.isEmpty else { throw APIError("group move needs a session") }
      let group = args["ungrouped"]?.bool == true ? nil : try lookupGroup(args)
      try place(ids, in: group)
      return try JSON(encoding: ids.map(summary))
    case "group-note":
      let id = try lookupGroup(args)
      var group = groups[id]!
      group.notes.append(try makeNote(args["text"]?.string, by: args["by"]?.string, after: group.notes))
      try saveGroup(group)
      return try JSON(encoding: groupSummary(id))
    case "group-suggest":
      let suggestions = groupSuggestions()
      guard let accept = args["accept"]?.string else { return try JSON(encoding: suggestions) }
      guard let suggestion = suggestions.first(where: { $0.id == accept }) else {
        throw APIError("no suggestion \(accept). List them with: sb group suggest")
      }
      return try JSON(encoding: groupSummary(try acceptSuggestion(suggestion)))
    case "send-group":
      return try JSON(encoding: sendGroup(args))
    default:
      throw APIError("unknown request \(op)")
    }
  }

  /// The group of the session that starts a new one, or nil without a parent.
  func groupOfParent(_ parent: String?) -> String? {
    parent.flatMap { entries[$0]?.session.group }
  }

  /// Finds a group by id, by unique id prefix, or by unique name.
  private func lookupGroup(_ args: JSON) throws -> String {
    guard let key = args["group"]?.string, !key.isEmpty else { throw APIError("name a group") }
    return try resolve(key, "group", groups.values.map { ($0.id, $0.name) })
  }

  private func sessionRefs(_ args: JSON) throws -> [String] {
    try (args["sessions"]?.array ?? []).compactMap(\.string).map { try lookup(["session": .string($0)]) }
  }

  /// Refuses a name that another group has. A name then finds one group.
  private func createGroup(_ name: String, notes: [Note] = []) throws -> SessionGroup {
    if groups.values.contains(where: { $0.name == name }) { throw APIError("a group named \(name) exists") }
    let group = SessionGroup(id: shortId("g", taken: groups.keys), name: name, notes: notes, created: nowMs())
    try saveGroup(group)
    return group
  }

  private func saveGroup(_ group: SessionGroup) throws {
    try store.save(group: group)
    groups[group.id] = group
  }

  /// Moves the sessions into the group, or into no group, and marks them
  /// placed by hand, so suggestions leave them out.
  private func place(_ ids: [String], in group: String?) throws {
    try refuseUngroupable(ids)
    for id in ids {
      try update(id) {
        $0.group = group
        $0.placedByHand = true
      }
    }
  }

  /// The Manager has its own row in the app and belongs to no group.
  private func groupable(_ session: Session) -> Bool { session.manager != true }

  private func refuseUngroupable(_ ids: [String]) throws {
    if let id = ids.first(where: { entries[$0].map { !groupable($0.session) } ?? false }) {
      throw APIError("\(id) is the Manager, which belongs to no group")
    }
  }

  private func members(_ group: String) -> [Session] {
    entries.values.map(\.session).filter { $0.group == group }.sorted { $0.id < $1.id }
  }

  private func groupSummary(_ id: String) -> GroupSummary {
    GroupSummary(groups[id]!, sessions: members(id).map(\.id))
  }

  func groupList() -> GroupList {
    let sorted = groups.values.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    let ungrouped = entries.values.map(\.session).filter { groupable($0) && $0.group.map { groups[$0] == nil } ?? true }
      .map(\.id).sorted()
    return GroupList(groups: sorted.map { groupSummary($0.id) }, ungrouped: ungrouped)
  }

  func groupSuggestions() -> [GroupSuggestion] {
    let candidates = entries.values.filter { groupable($0.session) }.map { e in
      GroupSuggestions.Candidate(
        id: e.session.id, branch: e.session.branch, prTitle: e.facts.pr?.title, group: e.session.group,
        placedByHand: e.session.placedByHand ?? false)
    }
    return GroupSuggestions.make(candidates: candidates, groups: Array(groups.values))
  }

  /// Returns the id of the group that the suggestion filled.
  private func acceptSuggestion(_ suggestion: GroupSuggestion) throws -> String {
    let id: String
    if let group = suggestion.group {
      id = group
    } else {
      id = try createGroup(suggestion.name).id
    }
    try place(suggestion.sessions, in: id)
    return id
  }

  /// Sends the text to every member of the group that can take a message,
  /// only when `confirmed` is true. Without it, it returns the targets. A
  /// confirmed send names the targets that the user confirmed. It refuses
  /// when the group's targets changed since then. A member's failure doesn't
  /// stop the others. The message can't answer a member's deferred question,
  /// because the user confirmed the group and not each session's question.
  private func sendGroup(_ args: JSON) throws -> GroupSend {
    let id = try lookupGroup(args)
    guard let text = args["text"]?.string, !text.isEmpty else { throw APIError("send needs text") }
    let from = args["from"]?.string
    let targets = members(id).filter { !$0.waitsToStart && $0.id != from }
    let list = targets.map { GroupSend.Target(id: $0.id, name: $0.name) }
    guard args["confirmed"]?.bool == true else { return GroupSend(group: id, targets: list, sent: false) }
    let confirmed = args["targets"]?.array?.compactMap(\.string) ?? []
    guard confirmed.sorted() == targets.map(\.id).sorted() else {
      throw APIError("the sessions to send to changed since they were confirmed. List them again, and confirm again")
    }
    let results = targets.map { s in
      do {
        return GroupSend.Result(session: s.id, delivery: try send(s.id, text, byUser: false))
      } catch {
        return GroupSend.Result(session: s.id, error: "\(error)")
      }
    }
    return GroupSend(group: id, targets: list, sent: true, deliveries: results)
  }
}
