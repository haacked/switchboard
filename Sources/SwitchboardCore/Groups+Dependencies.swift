import Foundation

extension GroupSuggestions {
  /// The dependencies between candidates, and the suggestions that come from them.
  struct Links {
    struct Edge {
      /// The session whose PR depends on `to`'s PR.
      var from: Candidate
      var to: Candidate
      var dependency: Dependency

      /// Such as `#122896 depends on #122953`.
      var text: String {
        let label = dependency.label(from: from.repo ?? dependency.repo)
        return "\(from.pr.map { Wait.PullRequest(repository: nil, number: $0).text } ?? from.id) depends on \(label)"
      }
    }

    let groups: [String: SessionGroup]
    /// The candidates of each group that sbd still has.
    let members: [String: [Candidate]]
    /// Ordered by the id of the session that depends, then by its dependencies' order.
    let edges: [Edge]

    init(candidates: [Candidate], groups: [SessionGroup]) {
      let byId = Dictionary(candidates.map { ($0.id, $0) }) { first, _ in first }
      let groups = Dictionary(groups.map { ($0.id, $0) }) { first, _ in first }
      self.groups = groups
      members = candidates.reduce(into: [:]) { members, c in
        if let g = c.group, groups[g] != nil { members[g, default: []].append(c) }
      }
      edges = candidates.sorted { $0.id < $1.id }.flatMap { c in
        c.dependencies.compactMap { d in
          guard let other = d.session.flatMap({ byId[$0] }), other.id != c.id else { return nil }
          return Edge(from: c, to: other, dependency: d)
        }
      }
    }

    /// The candidate's group, when sbd still has that group.
    func group(of c: Candidate) -> String? { c.group.flatMap { groups[$0] == nil ? nil : $0 } }

    func reason(_ edges: [Edge]) -> String { edges.map(\.text).joined(separator: ", ") }

    /// One merge for each pair of groups that a dependency links, when the
    /// merge moves at least one session. The sessions that the user placed by
    /// hand stay. The merges that move the most sessions come first.
    func merges(declined: Set<String>) -> [GroupSuggestion] {
      var byPair: [[String]: [Edge]] = [:]
      for e in edges {
        guard let a = group(of: e.from), let b = group(of: e.to), a != b else { continue }
        byPair[[a, b].sorted(), default: []].append(e)
      }
      var out: [GroupSuggestion] = []
      for (pair, edges) in byPair {
        let id = "merge:\(pair[0]):\(pair[1])"
        guard !declined.contains(id) else { continue }
        let (keep, merged) = survivor(pair[0], pair[1])
        let leaving = members[merged] ?? []
        let moving = leaving.filter { !$0.placedByHand }.map(\.id).sorted()
        guard !moving.isEmpty else { continue }
        let stays = leaving.filter(\.placedByHand).map(\.id).sorted()
        out.append(
          GroupSuggestion(
            id: id, name: groups[keep]!.name, group: keep, sessions: moving, reason: reason(edges),
            merge: .init(group: merged, name: groups[merged]!.name), stays: stays.isEmpty ? nil : stays))
      }
      return out.sorted { a, b in (b.sessions.count, a.id) < (a.sessions.count, b.id) }
    }

    /// The group that keeps its id and name when `a` and `b` merge, and the
    /// group that merges into it. The kept group is the one with more
    /// sessions placed by hand, then the one with more sessions, then the
    /// older one, then the one with the smaller id. A merge only adds to the
    /// kept group's counts, so the next suggestion for the pair keeps the same
    /// group and never moves the sessions back.
    func survivor(_ a: String, _ b: String) -> (keep: String, merged: String) {
      func byHand(_ g: String) -> Int { members[g, default: []].filter(\.placedByHand).count }
      func size(_ g: String) -> Int { members[g, default: []].count }
      let (createdA, createdB) = (groups[a]!.created, groups[b]!.created)
      let keepA = (byHand(b), size(b), createdA, a) < (byHand(a), size(a), createdB, b)
      return keepA ? (a, b) : (b, a)
    }

    /// For each session in no group that the user didn't place there by
    /// hand, a join of the group that it has the most dependencies with.
    /// Ties go to the group whose name sorts first. A dependency on a session
    /// that one of `merges` moves counts for the group that the merge keeps.
    /// A join to the merged group would place the session there by hand, and
    /// that could change which group survives and drop the merge.
    func joins(declined: Set<String>, merges: [GroupSuggestion]) -> [GroupSuggestion] {
      var movesTo: [String: String] = [:]
      for m in merges {
        guard let keep = m.group else { continue }
        for id in m.sessions where movesTo[id] == nil { movesTo[id] = keep }
      }
      var byOpen: [String: [String: [Edge]]] = [:]
      for e in edges {
        for (loose, other) in [(e.from, e.to), (e.to, e.from)] where loose.open {
          guard let g = movesTo[other.id] ?? group(of: other) else { continue }
          byOpen[loose.id, default: [:]][g, default: []].append(e)
        }
      }
      return byOpen.keys.sorted().compactMap { session in
        let options = byOpen[session]!.filter { !declined.contains("dependency:\(session):\($0.key)") }
        let best = options.max { a, b in
          (a.value.count, groups[b.key]!.name) < (b.value.count, groups[a.key]!.name)
        }
        guard let (g, edges) = best else { return nil }
        return GroupSuggestion(
          id: "dependency:\(session):\(g)", name: groups[g]!.name, group: g, sessions: [session],
          reason: reason(edges))
      }
    }
  }
}
