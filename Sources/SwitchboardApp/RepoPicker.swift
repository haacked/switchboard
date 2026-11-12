import AppKit
import SwiftUI
import SwitchboardCore

/// The rows of the repository picker's popover for a list of repositories and a filter.
struct RepoPickerList: Equatable {
  enum Row: Equatable, Identifiable {
    /// Adds the path that the filter holds.
    case addPath(String)
    case repo(KnownRepo)
    /// Opens the folder panel.
    case addFolder

    /// The row's identity in the list. It is also the row's accessibility identifier.
    var id: String {
      switch self {
      case .addPath: return "repo-add-path"
      case .repo(let repo): return "repo-row-\(repo.path)"
      case .addFolder: return "repo-add"
      }
    }
  }

  let rows: [Row]

  /// A filter that starts with `/` or `~` is a path, and the first row offers to add it. A repository
  /// matches when each word of the filter is in its name or its path, without case. The row that opens the
  /// folder panel is always last.
  init(repos: [KnownRepo], filter: String) {
    let text = filter.trimmingCharacters(in: .whitespacesAndNewlines)
    let terms = text.lowercased().split(whereSeparator: \.isWhitespace)
    let matches = repos.filter { repo in
      let fields = [repo.name, repo.path, Self.abbreviated(repo.path)].map { $0.lowercased() }
      return terms.allSatisfy { term in fields.contains { $0.contains(term) } }
    }
    let isPath = text.hasPrefix("/") || text.hasPrefix("~")
    rows = (isPath ? [.addPath(text)] : []) + matches.map(Row.repo) + [.addFolder]
  }

  /// The row that the highlight starts on, and returns to when the filter changes.
  var initialHighlight: String? { rows.first?.id }

  /// The row that an arrow moves the highlight to. It stops at both ends.
  func step(from current: String?, by step: Int) -> String? {
    ListStep.step(rows.map(\.id), from: current, by: step, wrap: false)
  }

  func row(_ id: String?) -> Row? { rows.first { $0.id == id } }

  /// The text that the filter starts with when `key` opens the closed picker, or nil when the key does
  /// not open it. ↓ and Space open it empty, and a printable character opens it with that character. A
  /// key with ⌘, ⌥, or ⌃ never opens it, so menu shortcuts keep it. Return stays the sheet's Start button.
  static func opens(_ key: KeyEquivalent, modifiers: EventModifiers) -> String? {
    guard modifiers.isDisjoint(with: [.command, .option, .control]) else { return nil }
    if key == .downArrow || key == .space { return "" }
    // AppKit sends the arrow and function keys as private use characters.
    let printable = key.character.unicodeScalars.allSatisfy {
      !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value)
    }
    return printable ? String(key.character) : nil
  }

  static func abbreviated(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }
}

/// The New Session sheet's repository control. It shows the selected repository and opens a popover that
/// filters the known repositories and adds one from a pasted path or the folder panel.
struct RepoPicker: View {
  final class Popover: ObservableObject {
    @Published var open = false
    @Published var filter = ""
    @Published var highlight: String?
    /// What sbd answered when it refused a folder.
    @Published var error: String?
  }

  @EnvironmentObject var model: BoardModel
  @Binding var selection: KnownRepo?
  @StateObject private var popover = Popover()
  @FocusState private var focused: Bool

  /// AppKit sends ⇧Tab as this character.
  private static let backtab = KeyEquivalent("\u{19}")

  private var list: RepoPickerList { RepoPickerList(repos: model.knownRepos ?? [], filter: popover.filter) }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      control
        .popover(isPresented: $popover.open, arrowEdge: .bottom) {
          RepoPickerRows(popover: popover, list: list, selected: selection?.path, choose: choose)
        }
      if let error = popover.error, !popover.open {
        Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
      }
    }
    .onAppear { DispatchQueue.main.async { focused = true } }
    .onChange(of: model.knownRepos) { old, _ in
      // Keys typed before sbd answers open the popover on only the Add repository… row. The highlight moves
      // to the new first row unless the user moved it to a row that the new list still has.
      if popover.open {
        let before = RepoPickerList(repos: old ?? [], filter: popover.filter)
        if popover.highlight == before.initialHighlight || list.row(popover.highlight) == nil {
          popover.highlight = list.initialHighlight
        }
      }
      if Snapshot.opensRepoPicker, model.knownRepos != nil, !popover.open { open(filter: "") }
    }
    .onChange(of: popover.filter) {
      popover.highlight = list.initialHighlight
      popover.error = nil
    }
    .onChange(of: popover.error) {
      // A refusal leaves the filter and the focus as they were, so VoiceOver would say nothing.
      if let error = popover.error { AccessibilityNotification.Announcement(error).post() }
    }
    .onChange(of: popover.open) {
      // Esc and a click outside close the popover without `close()`.
      if !popover.open { DispatchQueue.main.async { focused = true } }
    }
  }

  private var control: some View {
    HStack(spacing: 6) {
      if let repo = selection {
        Text(repo.name).lineLimit(1).layoutPriority(1)
        Text(RepoPickerList.abbreviated(repo.path))
          .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
      } else {
        Text(model.knownRepos == nil ? "Loading…" : "Add a repository…").foregroundStyle(.secondary)
      }
      Spacer(minLength: 4)
      Image(systemName: "chevron.up.chevron.down").imageScale(.small).foregroundStyle(.secondary)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
    .overlay(
      RoundedRectangle(cornerRadius: 6)
        .stroke(focused ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: focused ? 2 : 1)
    )
    .contentShape(Rectangle())
    // `.edit` gives the control Tab focus without the system's Keyboard Navigation setting, as a text field has.
    .focusable(interactions: .edit)
    .focused($focused)
    .focusEffectDisabled()
    .onTapGesture { open(filter: "") }
    .onKeyPress(phases: .down) { press in
      // `characters` has the shifted character, and `key` has the unshifted one.
      let key = press.characters.count == 1 ? KeyEquivalent(press.characters.first!) : press.key
      guard let seed = RepoPickerList.opens(key, modifiers: press.modifiers) else { return .ignored }
      // Keys typed before the popover's field has focus still arrive here.
      if popover.open { popover.filter += seed } else { open(filter: seed) }
      return .handled
    }
    // A view that is focusable with `.edit` interactions keeps Tab. This handler moves the focus instead.
    .onKeyPress(keys: [.tab, Self.backtab], phases: [.down, .repeat]) { press in
      guard press.modifiers.isDisjoint(with: [.command, .option, .control]) else { return .ignored }
      let window = NSApp.keyWindow ?? NSApp.switchboardWindow?.attachedSheet
      if press.key == Self.backtab || press.modifiers.contains(.shift) {
        window?.selectPreviousKeyView(nil)
      } else {
        window?.selectNextKeyView(nil)
      }
      return .handled
    }
    .help("The repository that the session starts in")
    .accessibilityElement()
    .accessibilityLabel("Repository")
    .accessibilityValue(selection?.name ?? "")
    .accessibilityAddTraits(.isButton)
    .accessibilityIdentifier("repo-picker")
  }

  private func open(filter: String) {
    popover.error = nil
    popover.filter = filter
    popover.highlight = list.initialHighlight
    popover.open = true
  }

  private func close() { popover.open = false }

  private func choose(_ row: RepoPickerList.Row) {
    switch row {
    case .repo(let repo):
      selection = repo
      close()
    case .addPath(let path):
      add(path)
    case .addFolder:
      close()
      let start = selection.map { ($0.path as NSString).deletingLastPathComponent }
      // The panel is modal, so it opens after the popover has closed.
      DispatchQueue.main.async {
        if let path = chooseFolder(message: "Choose a repository's folder", at: start) { add(path) }
      }
    }
  }

  /// Asks sbd to add the repository that holds `path`, then selects it. A refusal shows sbd's message
  /// and keeps the popover as it is.
  private func add(_ path: String) {
    model.addRepo(path) { result in
      switch result {
      case .success(let repo):
        selection = repo
        popover.error = nil
        close()
      case .failure(let error):
        popover.error = "\(error)"
      }
    }
  }
}

/// The popover of `RepoPicker`: a filter field over the rows. It is its own view because a focus state
/// does not reach across a popover.
private struct RepoPickerRows: View {
  @ObservedObject var popover: RepoPicker.Popover
  let list: RepoPickerList
  /// The path of the selected repository, which gets the checkmark.
  let selected: String?
  let choose: (RepoPickerList.Row) -> Void
  @FocusState private var filterFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      TextField("Filter, or paste a path", text: $popover.filter)
        .textFieldStyle(.plain)
        .padding(10)
        .focused($filterFocused)
        .onKeyPress(keys: [.upArrow, .downArrow, .return], phases: [.down, .repeat]) { press in
          switch NavKey.action(press.key, modifiers: press.modifiers) {
          case .move(.down): popover.highlight = list.step(from: popover.highlight, by: 1)
          case .move(.up): popover.highlight = list.step(from: popover.highlight, by: -1)
          case .open: chooseHighlighted()
          default: return .ignored
          }
          return .handled
        }
        .onKeyPress(.escape) {
          popover.open = false
          return .handled
        }
        // In a key window the field editor takes Return before `onKeyPress` sees it. Without a submit action,
        // Return then also reaches the sheet's Start button.
        .onSubmit(chooseHighlighted)
        .accessibilityIdentifier("repo-filter")
      if let error = popover.error {
        Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
          .padding(.horizontal, 10).padding(.bottom, 8)
      }
      Divider()
      ScrollViewReader { proxy in
        ScrollView {
          VStack(alignment: .leading, spacing: 1) {
            ForEach(list.rows) { row in
              if row == .addFolder, list.rows.count > 1 { Divider().padding(.vertical, 3) }
              rowView(row).id(row.id)
            }
          }
          .padding(5)
        }
        .frame(maxHeight: 300)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: popover.highlight) { proxy.scrollTo(popover.highlight) }
      }
    }
    .frame(width: 440)
    .onAppear {
      DispatchQueue.main.async {
        filterFocused = true
        deselectFilter()
      }
    }
    .onChange(of: filterFocused) { if filterFocused { deselectFilter() } }
  }

  /// Puts the insertion point after the filter's text. A field selects its text when it takes focus, so
  /// the next key would otherwise replace the key that opened the popover.
  private func deselectFilter() {
    DispatchQueue.main.async {
      let editor = NSApp.windows.lazy.compactMap { $0.firstResponder as? NSTextView }
        .first { $0.isFieldEditor && $0.string == popover.filter }
      editor?.setSelectedRange(NSRange(location: (popover.filter as NSString).length, length: 0))
    }
  }

  private func chooseHighlighted() {
    // Return can reach both the key handler and the submit action.
    guard popover.open, let row = list.row(popover.highlight) else { return }
    choose(row)
  }

  private func rowView(_ row: RepoPickerList.Row) -> some View {
    let highlighted = popover.highlight == row.id
    func icon(_ name: String) -> some View { Image(systemName: name).imageScale(.small).frame(width: 14) }
    return HStack(spacing: 8) {
      switch row {
      case .repo(let repo):
        icon("checkmark").opacity(repo.path == selected ? 1 : 0).accessibilityHidden(repo.path != selected)
        VStack(alignment: .leading, spacing: 1) {
          Text(repo.name).lineLimit(1)
          Text(RepoPickerList.abbreviated(repo.path))
            .font(.caption).lineLimit(1).truncationMode(.middle)
            .foregroundStyle(highlighted ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
        }
      case .addPath(let path):
        icon("plus")
        Text("Add \(path)").lineLimit(1).truncationMode(.middle)
      case .addFolder:
        icon("plus")
        Text("Add repository…")
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 4)
    .foregroundStyle(highlighted ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
    .background(RoundedRectangle(cornerRadius: 5).fill(highlighted ? Color.accentColor : .clear))
    .contentShape(Rectangle())
    // A continuous hover reports only pointer moves, so rows that move under a still pointer keep the highlight.
    .onContinuousHover { if case .active = $0, popover.highlight != row.id { popover.highlight = row.id } }
    .onTapGesture { choose(row) }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(highlighted ? [.isButton, .isSelected] : .isButton)
    .accessibilityIdentifier(row.id)
  }
}
