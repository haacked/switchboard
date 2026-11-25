import SwiftUI

/// A list on the left and the current item's detail on the right, as the Inbox, Issues, and Loops show them. A drag on
/// the divider sets the list's width, which the app keeps under `widthKey` across view switches and relaunches.
///
/// It is not an `HSplitView`, because that split saves no divider position and its divider runs up through the
/// toolbar. This divider stays inside the safe area, so it ends at the toolbar.
struct ListDetailSplit<ListContent: View, Detail: View>: View {
  static var listMinWidth: CGFloat { 200 }
  static var listIdealWidth: CGFloat { 280 }
  static var listMaxWidth: CGFloat { 420 }
  static var dividerWidth: CGFloat { 1 }
  /// The narrowest the detail pane gets.
  static var detailMinWidth: CGFloat { 340 }
  /// The step of VoiceOver's increment and decrement actions on the divider.
  static var accessibilityStep: CGFloat { 20 }

  /// The list's width for a stored width, or the ideal width when nothing is stored. It stays between the list's
  /// minimum and maximum. It leaves the detail its minimum in a split `available` points wide. An `available` of 0
  /// means that the split has not been measured yet. Only the list's own bounds apply then.
  static func listWidth(stored: CGFloat?, available: CGFloat) -> CGFloat {
    var upper = listMaxWidth
    if available > 0 { upper = min(upper, available - dividerWidth - detailMinWidth) }
    return max(listMinWidth, min(stored ?? listIdealWidth, upper))
  }

  @AppStorage private var stored: Double?
  @State private var available: CGFloat = 0
  /// How far the current drag has moved the divider. The stored width changes only when the drag ends.
  @GestureState private var dragOffset: CGFloat = 0
  private let list: () -> ListContent
  private let detail: () -> Detail

  init(
    widthKey: String, @ViewBuilder list: @escaping () -> ListContent, @ViewBuilder detail: @escaping () -> Detail
  ) {
    _stored = AppStorage(widthKey)
    self.list = list
    self.detail = detail
  }

  var body: some View {
    let base = Self.listWidth(stored: stored.map { CGFloat($0) }, available: available)
    let width = Self.listWidth(stored: base + dragOffset, available: available)
    HStack(spacing: 0) {
      list().frame(width: width)
      // The detail comes later in the stack. Without the z-index, the detail covers the right part of the drag area.
      divider(base: base, width: width).zIndex(1)
      detail().frame(minWidth: Self.detailMinWidth, maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(minWidth: Self.listMinWidth + Self.dividerWidth + Self.detailMinWidth)
    // A split at least this wide gives the list its maximum. Wider widths need no new layout.
    .onGeometryChange(for: CGFloat.self) {
      min($0.size.width, Self.listMaxWidth + Self.dividerWidth + Self.detailMinWidth)
    } action: {
      available = $0
    }
  }

  private func divider(base: CGFloat, width: CGFloat) -> some View {
    Divider()
      .frame(width: Self.dividerWidth)
      .overlay {
        Color.clear
          .frame(width: 7)
          .contentShape(Rectangle())
          .pointer(.columnResize)
          .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
              .updating($dragOffset) { drag, offset, _ in offset = drag.translation.width }
              .onEnded { drag in store(Self.listWidth(stored: base + drag.translation.width, available: available)) })
      }
      .accessibilityElement()
      .accessibilityLabel("List width")
      .accessibilityValue("\(Int(width)) points")
      .accessibilityAdjustableAction { direction in
        let step = direction == .increment ? Self.accessibilityStep : -Self.accessibilityStep
        store(Self.listWidth(stored: width + step, available: available))
      }
  }

  private func store(_ width: CGFloat) { stored = Double(width) }
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
