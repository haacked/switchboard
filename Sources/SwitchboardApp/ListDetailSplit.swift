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

/// A list section's title and its count, above the section's rows. A section that collapses shows a chevron.
struct ListSectionHeader: View {
  let title: String
  let count: Int
  var collapsed: Bool?

  var body: some View {
    HStack(spacing: 4) {
      if let collapsed {
        Image(systemName: collapsed ? "chevron.right" : "chevron.down").font(.caption2).accessibilityHidden(true)
      }
      Text("\(title) (\(count))")
    }
    .font(.caption.bold())
    .foregroundStyle(.secondary)
    .padding(.horizontal, 12)
    .padding(.top, 10)
    .padding(.bottom, 4)
  }
}

extension View {
  /// A list row's padding, and the accent background that marks the current row.
  func listRowChrome(current: Bool) -> some View {
    padding(.horizontal, 12)
      .padding(.vertical, 6)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(RoundedRectangle(cornerRadius: 8).fill(current ? Color.accentColor.opacity(0.14) : Color.clear))
      .padding(.horizontal, 6)
      .contentShape(Rectangle())
  }

  /// The keys of the list that `list` names, while it has focus. j and k call `move` with a step that goes around
  /// the ends. ↓ and ↑ call it with a step that stops at the ends. Return calls `open`.
  func listKeys(
    _ list: ListFocus, _ focused: FocusState<Bool>.Binding, model: BoardModel,
    move: @escaping (_ step: Int, _ wrap: Bool) -> Void, open: @escaping () -> Void
  ) -> some View {
    focusable()
      .focused(focused)
      .focusEffectDisabled()
      .onKeyPress(characters: CharacterSet(charactersIn: "jk"), phases: .down) { press in
        move(press.characters == "j" ? 1 : -1, true)
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
