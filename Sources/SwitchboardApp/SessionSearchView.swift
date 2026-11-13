import SwiftUI
import SwitchboardCore

enum SearchPanelKeys {
  enum Action: Equatable {
    case move(Int)
    case open
    case close
  }

  /// What a key in the search field does. ← and → stay with the field's cursor. Return and Esc stay with an
  /// input method while it composes. A key with a modifier gives nil, as `NavKey.action` decides.
  static func action(_ key: KeyEquivalent, modifiers: EventModifiers, composing: Bool) -> Action? {
    if key == .escape { return composing || !NavKey.isPlain(modifiers) ? nil : .close }
    switch NavKey.action(key, modifiers: modifiers) {
    case .move(.down): return .move(1)
    case .move(.up): return .move(-1)
    case .open: return composing ? nil : .open
    default: return nil
    }
  }

  /// The highlighted result: `highlighted` while the results hold it, else the first result.
  static func current(_ highlighted: String?, in ids: [String]) -> String? {
    highlighted.flatMap { ids.contains($0) ? $0 : nil } ?? ids.first
  }
}

/// The ⌘K panel that finds a session by name, repo, branch, PR, issue, group, reason, or note.
struct SessionSearchView: View {
  final class Search: ObservableObject {
    /// The sessions as the panel opened, so the list does not reorder under the arrows while the model refreshes.
    @Published var sessions: [SessionSummary] = []
    @Published var query = ""
    /// The result that the arrows last moved to. `SearchPanelKeys.current` falls back to the first result.
    @Published var highlighted: String?
  }

  @EnvironmentObject var model: BoardModel
  @StateObject private var search = Search()
  @FocusState private var fieldFocused: Bool

  var body: some View {
    let results = SessionSearch.rank(search.sessions, query: search.query)
    let ids = results.map(\.id)
    let current = SearchPanelKeys.current(search.highlighted, in: ids)
    VStack(spacing: 0) {
      field(ids: ids, current: current)
      Divider()
      if results.isEmpty {
        Text(search.sessions.isEmpty ? "No sessions" : "No sessions match")
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, minHeight: 80)
      } else {
        list(results, current: current)
      }
    }
    .frame(width: 600)
    .onAppear {
      search.sessions = model.board
      search.query = Snapshot.searchQuery ?? ""
      fieldFocused = true
    }
    .onChange(of: search.query) { search.highlighted = nil }
    // Focus stays in the field, so VoiceOver does not read the highlighted row. A query edit resets `highlighted` to
    // nil, so only the arrows announce a row.
    .onChange(of: search.highlighted) {
      if let name = results.first(where: { $0.id == search.highlighted })?.session.name {
        AccessibilityNotification.Announcement(name).post()
      }
    }
    .onChange(of: results.isEmpty) {
      if results.isEmpty && !search.sessions.isEmpty {
        AccessibilityNotification.Announcement("No sessions match").post()
      }
    }
    .onExitCommand { model.showingSearch = false }
  }

  private func field(ids: [String], current: String?) -> some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
      TextField("Search sessions", text: $search.query)
        .textFieldStyle(.plain)
        .font(.title3)
        .focused($fieldFocused)
        .onKeyPress(phases: [.down, .repeat]) { press in
          // SwiftUI calls this before the input method sees the key. The check for marked text has to happen here.
          guard
            let action = SearchPanelKeys.action(
              press.key, modifiers: press.modifiers, composing: TextInput.isComposing)
          else { return .ignored }
          switch action {
          case .move(let step):
            search.highlighted = ListStep.step(ids, from: current, by: step, wrap: false)
          case .open:
            open(current)
          case .close:
            model.showingSearch = false
          }
          return .handled
        }
        // Keypad Enter reaches onSubmit and not the key handler.
        .onSubmit { open(current) }
    }
    .padding(12)
  }

  private func list(_ results: [SessionSearch.Result], current: String?) -> some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(spacing: 2) {
          ForEach(results) { result in
            SearchResultRow(result: result, highlighted: result.id == current)
              .id(result.id)
              .contentShape(Rectangle())
              .onTapGesture { model.openFromSearch(result.id) }
          }
        }
        .padding(6)
      }
      .frame(maxHeight: 360)
      .onChange(of: search.highlighted) {
        if let id = search.highlighted { proxy.scrollTo(id) }
      }
    }
  }

  private func open(_ id: String?) {
    if let id { model.openFromSearch(id) }
  }
}

struct SearchResultRow: View {
  let result: SessionSearch.Result
  let highlighted: Bool

  var body: some View {
    let session = result.session
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 6) {
        Circle().fill(session.state.color).frame(width: 8, height: 8)
        Text(session.name).fontWeight(.medium).lineLimit(1)
        Spacer()
        IssueBadge(session: session, linked: false)
        if let pr = session.pr {
          Text(verbatim: pr.numberLabel).font(.caption).foregroundStyle(pr.status.color)
        }
        StateBadge(state: session.state)
      }
      let place = [result.repo, session.branch].compactMap { $0 }.joined(separator: " · ")
      if !place.isEmpty {
        Text(place).font(.caption).foregroundStyle(.secondary).lineLimit(1).padding(.leading, 14)
      }
      if let hint = result.hint {
        Text("\(hint.field.title): \(oneLine(hint.text, max: 90))")
          .font(.caption).foregroundStyle(.secondary).lineLimit(1).padding(.leading, 14)
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
    .background(
      RoundedRectangle(cornerRadius: 6).fill(highlighted ? Color.accentColor.opacity(0.2) : Color.clear)
    )
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("search-row-\(result.id)")
    .accessibilityAddTraits(highlighted ? .isSelected : [])
  }
}
