import SwiftUI
import SwitchboardCore

/// What a session's note icon shows. Nil when the session has no notes.
struct NotesBadge {
  enum Tone {
    /// Only plain notes or resolved to-dos.
    case dimmed
    /// Open to-dos on a session that is not Done.
    case secondary
    /// Open to-dos on a Done session, which is when the user can act on them.
    case needsYou
  }

  let tone: Tone
  /// The open to-dos, in the order they were added.
  let open: [Note]
  /// The notes that are not to-dos, including rows without a kind.
  let plain: [Note]
  let resolved: [Note]

  private let total: Int

  init?(_ s: SessionSummary) {
    guard !s.notes.isEmpty else { return nil }
    open = s.notes.openTodos
    plain = s.notes.plainNotes
    resolved = s.notes.resolvedTodos
    total = s.notes.count
    tone = open.isEmpty ? .dimmed : s.state == .done ? .needsYou : .secondary
  }

  /// Nil below two, because one open to-do needs no number.
  var count: Int? { open.count >= 2 ? open.count : nil }

  var help: String {
    guard let first = open.first else { return Self.notes(total) }
    return open.count == 1 ? first.text : "\(first.text) and \(open.count - 1) more"
  }

  var accessibilityLabel: String {
    guard !open.isEmpty else { return Self.notes(total) }
    let todos = open.count == 1 ? "1 open to-do" : "\(open.count) open to-dos"
    return "\(todos): " + open.map(\.text).joined(separator: "; ")
  }

  var resolvedTitle: String { "\(resolved.count) resolved" }

  private static func notes(_ n: Int) -> String { n == 1 ? "1 note" : "\(n) notes" }
}

/// What a delete or remove confirmation says about the session's open to-dos.
/// The confirmation sends `ids` as `resolve`.
/// sbd therefore still refuses a to-do that was added after the confirmation read the session.
/// `id` lets `.sheet(item:)` keep a dialog's content while it closes.
struct TodoDeletion: Identifiable {
  let ids: [String]
  var id: [String] { ids }
  /// Nil when the session has no open to-do.
  let message: String?

  init(_ s: SessionSummary) {
    let open = s.openTodos
    ids = open.map(\.id)
    message =
      open.isEmpty
      ? nil
      : (open.count == 1 ? "This also resolves its open to-do:" : "This also resolves its \(open.count) open to-dos:")
        + open.map { "\n• \($0.text)" }.joined()
  }

  /// The destructive button's title. It names the to-dos the button resolves, then `verb`.
  func button(_ verb: String) -> String {
    switch ids.count {
    case 0: verb
    case 1: "Resolve 1 To-do and \(verb)"
    default: "Resolve \(ids.count) To-dos and \(verb)"
    }
  }

  /// Joins `message` and `rest` into one dialog message.
  func message(before rest: String) -> String { [message, rest].compactMap { $0 }.joined(separator: "\n\n") }
}

extension NotesBadge.Tone {
  var style: AnyShapeStyle {
    switch self {
    case .dimmed: AnyShapeStyle(.tertiary)
    case .secondary: AnyShapeStyle(.secondary)
    case .needsYou: AnyShapeStyle(AttentionState.needsYou.color)
    }
  }
}

/// The note icon of a session with notes. A click opens the notes, where the
/// user resolves a to-do or adds a note. With `always`, the icon shows on a
/// session without notes too. The user can then add the first note.
struct NotesButton: View {
  let session: SessionSummary
  var always = false
  @State private var showing = false

  var body: some View {
    let badge = NotesBadge(session)
    if badge != nil || always {
      Button {
        showing = true
      } label: {
        HStack(spacing: 1) {
          Image(systemName: "note.text")
          if let count = badge?.count { Text("\(count)").font(.caption2.bold()) }
        }
      }
      .buttonStyle(.borderless)
      .foregroundStyle((badge?.tone ?? .dimmed).style)
      .accessibilityLabel(badge?.accessibilityLabel ?? "Add a note")
      .help(badge?.help ?? "Add a note or a to-do")
      .popover(isPresented: $showing, arrowEdge: .bottom) { NotesPopover(session: session) }
    }
  }
}

struct NotesPopover: View {
  let session: SessionSummary

  var body: some View { NotesList(session: session).padding(12).frame(width: 340) }
}

/// A session's open to-dos, plain notes, and resolved to-dos, and a field that adds a note.
struct NotesList: View {
  @EnvironmentObject var model: BoardModel
  let session: SessionSummary
  @State private var text = ""
  @State private var todo = false
  @State private var showingResolved = false

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let badge = NotesBadge(session) {
        ForEach(badge.open, id: \.id) { note in
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            row(note)
            Spacer(minLength: 0)
            Button("Resolve") { model.resolveNote(session.id, note: note.id) }
              .help("Mark the to-do done. It stays in the notes as resolved.")
              .accessibilityLabel("Resolve: \(note.text)")
          }
        }
        ForEach(badge.plain, id: \.id) { row($0) }
        if !badge.resolved.isEmpty {
          DisclosureGroup(badge.resolvedTitle, isExpanded: $showingResolved) {
            VStack(alignment: .leading, spacing: 8) {
              ForEach(badge.resolved, id: \.id) { row($0).foregroundStyle(.secondary) }
            }
            .padding(.top, 4)
          }
        }
        Divider()
      }
      HStack(spacing: 8) {
        TextField("Add a note", text: $text).onSubmit(add)
        Toggle("To-do", isOn: $todo)
          .toggleStyle(.checkbox)
          .help("A to-do is a task for you. Deleting the session asks you to resolve it first.")
      }
    }
  }

  private func row(_ note: Note) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(note.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
      Text("\(note.by.rawValue) · \(ago(note.t)) ago").font(.caption).foregroundStyle(.secondary)
    }
  }

  private func add() {
    let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty else { return }
    model.addNote(session.id, text: clean, todo: todo) {
      // A failed request keeps the text. The user can then send it again.
      if text.trimmingCharacters(in: .whitespacesAndNewlines) == clean { text = "" }
    }
  }
}
