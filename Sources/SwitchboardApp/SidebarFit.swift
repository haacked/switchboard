import SwiftUI

/// Whether the window's sidebar shows. A list and detail view, such as the Inbox, in a window too narrow for the
/// sidebar, the list, and a comfortable detail hides the sidebar. The sidebar shows again when that stops holding.
///
/// The user's own toggles win:
/// - The rule hides the sidebar only when the narrow list case starts, and only if the sidebar shows at that moment.
/// - The rule shows the sidebar again only if the rule hid it.
/// - A toggle in the narrow list case stops the rule from hiding the sidebar until the window is at least
///   `collapseBelow` wide again. A view switch does not end it.
struct SidebarFit: Equatable {
  /// A detail this wide shows the Inbox detail's header without truncating it.
  static var detailComfortWidth: CGFloat { 620 }

  /// The window width under which a list and detail view hides the sidebar: the width that fits the sidebar, the list,
  /// and a detail `detailComfortWidth` wide.
  static var collapseBelow: CGFloat {
    typealias Split = ListDetailSplit<EmptyView, EmptyView>
    return ContentView.sidebarIdealWidth + Split.listIdealWidth + Split.dividerWidth + detailComfortWidth
  }

  private(set) var visibility: NavigationSplitViewVisibility = .automatic
  /// True while a list and detail view shows in a window narrower than `collapseBelow`.
  private var narrowList = false
  /// True while the sidebar is hidden because the rule hid it.
  private var autoHidden = false
  /// True after the user toggled the sidebar in the narrow list case, until the window is wide again.
  private var userOverride = false

  /// `.all`, `.doubleColumn`, and `.automatic` all show a two-column split's sidebar.
  var showsSidebar: Bool { visibility != .detailOnly }

  /// Applies the rule to a window `windowWidth` points wide. A width of 0 means that the window has not been measured
  /// yet. It changes nothing.
  mutating func update(windowWidth: CGFloat, isListDetail: Bool) {
    guard windowWidth > 0 else { return }
    if windowWidth >= Self.collapseBelow { userOverride = false }
    let holds = isListDetail && windowWidth < Self.collapseBelow
    if holds && !narrowList && showsSidebar && !userOverride {
      visibility = .detailOnly
      autoHidden = true
    } else if !holds && narrowList && autoHidden {
      visibility = .all
      autoHidden = false
    }
    narrowList = holds
  }

  /// Applies a visibility that the split view sets, which is the user's toggle. A value that shows the sidebar when it
  /// already shows, or hides it when it is already hidden, is not a toggle.
  mutating func userSet(_ value: NavigationSplitViewVisibility) {
    guard (value != .detailOnly) != showsSidebar else { return }
    visibility = value
    autoHidden = false
    if narrowList { userOverride = true }
  }
}
