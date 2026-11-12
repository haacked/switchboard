import Foundation

/// Reads the ids in `declined_suggestions`, which group suggestions share
/// with plan row suggestions. A plan row's id is its plan's id, a colon, and
/// a link such as `posthog/posthog#12`.
public enum DeclinedSuggestions {
  /// A declined id that a group suggestion has or had.
  enum Parsed {
    case word
    case merge(String, String)
    case dependency(session: String, group: String)
    case prefix(group: String?)
    case scope

    /// Nil for a plan row's id and for any other shape. A plan's id is `p`
    /// and five characters, so `prefix` is the only kind name it can equal.
    /// A `prefix` id needs a slug, which never holds the `/` and `#` of a
    /// plan row's link, so that plan's rows are not read as one.
    init?(_ id: String) {
      let f = id.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
      switch (f.first, f.count) {
      case ("word", 2...): self = .word
      case ("merge", 3): self = .merge(f[1], f[2])
      case ("dependency", 3): self = .dependency(session: f[1], group: f[2])
      case ("prefix", 2...3) where isSlug(f[1]): self = .prefix(group: f.count == 3 ? f[2] : nil)
      case ("scope", 2...): self = .scope
      default: return nil
      }
    }
  }

  /// The ids that no suggestion can have again: every `word:` id, because
  /// that kind is gone, and each merge, dependency join, and prefix join
  /// that names a group or a session that sbd no longer has. An id of any
  /// other shape stays. A `scope:` id stays because a scope's text may hold
  /// a colon, so its last field may be text and not a group.
  public static func prunable(declined: Set<String>, groups: Set<String>, sessions: Set<String>) -> Set<String> {
    declined.filter { id in
      switch Parsed(id) {
      case .word: true
      case .merge(let a, let b): !(groups.contains(a) && groups.contains(b))
      case .dependency(let session, let group): !(sessions.contains(session) && groups.contains(group))
      case .prefix(let group?): !groups.contains(group)
      case .prefix(nil), .scope, nil: false
      }
    }
  }

  /// The ids that a group suggestion can have now, sorted. A plan row's id
  /// and a `word:` id are left out.
  public static func groupSuggestionIDs(_ declined: Set<String>) -> [String] {
    declined.filter { id in
      switch Parsed(id) {
      case .word, nil: false
      default: true
      }
    }.sorted()
  }

  static func isSlug(_ text: String) -> Bool {
    !text.isEmpty && text.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
  }
}
