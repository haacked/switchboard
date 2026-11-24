import SwiftUI

/// A list on the left and the current item's detail on the right, as the Inbox and the Issues view show them.
struct ListDetailSplit<ListContent: View, Detail: View>: View {
  /// The narrowest the detail pane gets.
  static var detailMinWidth: CGFloat { 340 }

  @ViewBuilder let list: () -> ListContent
  @ViewBuilder let detail: () -> Detail

  var body: some View {
    HSplitView {
      list()
        .frame(minWidth: 200, idealWidth: 280, maxWidth: 420)
      detail()
        .frame(minWidth: Self.detailMinWidth, maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}

/// A list section's title and its count, above the section's rows. A section that collapses shows a chevron. The
/// count sits at the trailing edge, as in the sidebar's section headers, and a zero count does not show.
struct ListSectionHeader: View {
  let title: String
  let count: Int
  var collapsed: Bool?
  /// False for a header inside a container that already pads its content, such as the session side panel.
  var inset = true

  var body: some View {
    HStack(spacing: 4) {
      if let collapsed {
        Image(systemName: collapsed ? "chevron.right" : "chevron.down").font(.caption2).accessibilityHidden(true)
      }
      CountedTitle(title: title, count: count)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Self.spoken(title: title, count: count, collapsed: collapsed))
    .accessibilityAddTraits(.isHeader)
    .font(.caption.bold())
    .foregroundStyle(.secondary)
    .padding(
      inset ? EdgeInsets(top: 10, leading: Design.listInset, bottom: 4, trailing: Design.listInset) : EdgeInsets())
  }

  /// What VoiceOver reads for the header: the title, then the count when it is not zero, then whether a section that
  /// collapses is collapsed or expanded.
  static func spoken(title: String, count: Int, collapsed: Bool? = nil) -> String {
    var parts = [title]
    if count > 0 { parts.append("\(count)") }
    if let collapsed { parts.append(collapsed ? "collapsed" : "expanded") }
    return parts.joined(separator: ", ")
  }
}

/// A title with its count at the trailing edge. A zero count does not show.
struct CountedTitle: View {
  let title: String
  let count: Int

  var body: some View {
    HStack(spacing: 4) {
      Text(title)
      Spacer(minLength: 4)
      if count > 0 { Text("\(count)").monospacedDigit() }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(ListSectionHeader.spoken(title: title, count: count))
  }
}

extension View {
  /// A list row's padding, the accent background that marks the current row, and the ring of a highlighted session.
  /// The background sits halfway to `Design.listInset`, so the row's content starts at the list's inset.
  func listRowChrome(current: Bool, highlighted: Bool = false) -> some View {
    padding(.horizontal, Design.listInset / 2)
      .padding(.vertical, 6)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(RoundedRectangle(cornerRadius: 8).fill(current ? Color.accentColor.opacity(0.14) : Color.clear))
      .highlightRing(highlighted, cornerRadius: 8, outset: 0)
      .padding(.horizontal, Design.listInset / 2)
      .contentShape(Rectangle())
  }

  /// The keys of the list that `list` names, while it has focus. j and k call `move` with a step that goes around
  /// the ends. ↓ and ↑ call it with a step that stops at the ends. Return calls `open`.
  func listKeys(
    _ list: ListFocus, _ focused: FocusState<Bool>.Binding, model: BoardModel,
    move: @escaping (_ step: Int, _ wrap: Bool) -> Void, open: @escaping () -> Void
  ) -> some View {
    let next = String(AppShortcut.listNext.keys[0].key.character)
    let previous = String(AppShortcut.listPrevious.keys[0].key.character)
    return focusable()
      .focused(focused)
      .focusEffectDisabled()
      .onKeyPress(characters: CharacterSet(charactersIn: next + previous), phases: .down) { press in
        move(press.characters == next ? 1 : -1, true)
        return .handled
      }
      .onKeyPress(keys: [.upArrow, .downArrow, .return], phases: [.down, .repeat]) { press in
        switch NavKey.action(press.key, modifiers: press.modifiers) {
        case .move(.down): move(1, false)
        case .move(.up): move(-1, false)
        case .open: open()
        default: return .ignored
        }
        return .handled
      }
      .takesListFocus(list, focused, model: model)
      .onAppear { focused.wrappedValue = true }
  }
}
