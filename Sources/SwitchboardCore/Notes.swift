import Foundation

/// A note on a session. A to-do is a note that names a task for the user.
/// sbd refuses to delete a session that has an open to-do.
public struct Note: Codable, Equatable, Sendable {
  public enum Kind: String, Codable, Sendable, CaseIterable {
    case note, todo

    /// The kind that `text` names. Nil text is a plain note.
    public init(parsing text: String?) throws {
      guard let kind = Kind(rawValue: text ?? Kind.note.rawValue) else {
        throw APIError("kind is \(Kind.allCases.map(\.rawValue).joined(separator: " or ")), not \(text ?? "")")
      }
      self = kind
    }
  }

  /// How and when the user resolved a to-do.
  public struct Resolution: Codable, Equatable, Sendable {
    /// Milliseconds since the epoch.
    public var t: Int64
    /// Always `you`. Only the user resolves a to-do.
    public var by: Author
    /// "resolved", or "resolved and deleted the session".
    public var how: String

    public init(t: Int64, by: Author, how: String) {
      self.t = t
      self.by = by
      self.how = how
    }
  }

  public var id: String
  public var text: String
  public var by: Author
  /// Milliseconds since the epoch.
  public var t: Int64
  /// Nil reads as `.note`. Rows that an older sbd stored have none.
  public var kind: Kind?
  /// Nil while a to-do is open.
  public var resolved: Resolution?

  public init(id: String, text: String, by: Author, t: Int64, kind: Kind? = nil) {
    self.id = id
    self.text = text
    self.by = by
    self.t = t
    self.kind = kind
  }

  public var isOpenTodo: Bool { kind == .todo && resolved == nil }
}

/// A row of the `resolved_todos` table. The row stays after its session is deleted.
public struct ResolvedTodo: Codable, Equatable, Sendable {
  public var id: Int64?
  public var session: String
  public var name: String
  public var repo: String?
  public var branch: String?
  public var pr: Int?
  /// The note's id.
  public var note: String
  public var text: String
  /// Who added the to-do.
  public var by: Author
  /// When the to-do was added, in ms since the epoch.
  public var added: Int64
  /// When the user resolved it, in ms since the epoch.
  public var resolved: Int64
  public var how: String
}

extension ResolvedTodo {
  /// `branch` and `pr` are the branch and the PR that sbd shows for the session.
  public init(session: Session, branch: String?, note: Note, pr: Int?, resolution: Note.Resolution) {
    self.init(
      session: session.id, name: session.name, repo: session.repo, branch: branch, pr: pr, note: note.id,
      text: note.text, by: note.by, added: note.t, resolved: resolution.t, how: resolution.how)
  }
}

extension Array where Element == Note {
  /// The open to-dos, in the order they were added.
  public var openTodos: [Note] { filter(\.isOpenTodo) }
  /// The notes that are not to-dos, including rows without a kind.
  public var plainNotes: [Note] { filter { $0.kind != .todo } }
  public var resolvedTodos: [Note] { filter { $0.kind == .todo && $0.resolved != nil } }
}

extension Session {
  /// The open to-dos, in the order they were added.
  public var openTodos: [Note] { (notes ?? []).openTodos }
}

extension SessionSummary {
  /// The open to-dos, in the order they were added.
  public var openTodos: [Note] { notes.openTodos }
}
