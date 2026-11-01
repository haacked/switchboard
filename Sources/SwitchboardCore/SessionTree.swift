import Foundation

/// Lays out sessions under their parents, for the sidebar.
public enum SessionTree {
  public struct Row: Equatable, Sendable, Identifiable {
    public var session: SessionSummary
    /// 0 for a session with no parent in the list, 1 for its children, and so on.
    public var depth: Int
    public var id: String { session.id }
  }

  /// The session that this one is a child of, or nil. A follow-up's parent is
  /// the session that captured it, so a follow-up has no parent here. A
  /// parent that `isKnown` rejects, or the session itself, doesn't count.
  public static func parentID(
    of id: String, parent: String?, followup: Followup?, isKnown: (String) -> Bool
  ) -> String? {
    guard followup == nil, let parent, parent != id, isKnown(parent) else { return nil }
    return parent
  }

  private static func children(_ sessions: [SessionSummary]) -> [String: [SessionSummary]] {
    let ids = Set(sessions.map(\.id))
    var children: [String: [SessionSummary]] = [:]
    for s in sessions {
      if let p = parentID(of: s.id, parent: s.parent, followup: s.followup, isKnown: ids.contains) {
        children[p, default: []].append(s)
      }
    }
    return children
  }

  /// The sessions in order, each one followed by its children. A session
  /// whose parent is not in the list is a top-level row. Within a level the
  /// order of `sessions` holds.
  public static func rows(_ sessions: [SessionSummary]) -> [Row] {
    let ids = Set(sessions.map(\.id))
    let children = children(sessions)
    var out: [Row] = []
    var seen: Set<String> = []
    func visit(_ s: SessionSummary, _ depth: Int) {
      guard seen.insert(s.id).inserted else { return }
      out.append(Row(session: s, depth: depth))
      for child in children[s.id] ?? [] { visit(child, depth + 1) }
    }
    for s in sessions
    where parentID(of: s.id, parent: s.parent, followup: s.followup, isKnown: ids.contains) == nil { visit(s, 0) }
    // Sessions that name each other as parents have no top-level row to start from.
    for s in sessions { visit(s, 0) }
    return out
  }

  /// `root` and its descendants as rows, `root` at depth 0. A Done descendant
  /// has no row, because the list shows only sessions with work left. Its own
  /// children that are not Done move up to its depth, so they stay under the
  /// nearest ancestor that has a row.
  public static func subtree(of root: String, in sessions: [SessionSummary]) -> [Row] {
    guard let top = sessions.first(where: { $0.id == root }) else { return [] }
    let children = children(sessions)
    var out: [Row] = []
    var seen: Set<String> = []
    func visit(_ s: SessionSummary, _ depth: Int) {
      guard seen.insert(s.id).inserted else { return }
      let listed = s.id == root || s.state != .done
      if listed { out.append(Row(session: s, depth: depth)) }
      for child in children[s.id] ?? [] { visit(child, listed ? depth + 1 : depth) }
    }
    visit(top, 0)
    return out
  }
}
