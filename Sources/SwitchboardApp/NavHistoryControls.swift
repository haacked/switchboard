import AppKit
import SwiftUI
import SwitchboardCore

/// The toolbar's Back, Forward, and Recent Places buttons. Each is its own toolbar item, so the toolbar spaces them as
/// it spaces its other buttons.
struct NavHistoryControls: ToolbarContent {
  var body: some ToolbarContent {
    ToolbarItem(placement: .navigation) { NavButton(direction: .back) }
    ToolbarItem(placement: .navigation) { NavButton(direction: .forward) }
    ToolbarItem(placement: .navigation) { RecentPlacesButton() }
  }
}

private struct NavButton: View {
  @EnvironmentObject var model: BoardModel
  let direction: NavDirection

  var body: some View {
    switch direction {
    case .back:
      HistoryButton(
        "Back", "arrow.left", help: AppShortcut.back.help("Back"), id: "nav-back", enabled: model.canGoBack
      ) {
        model.goBack()
      }
    case .forward:
      HistoryButton(
        "Forward", "arrow.right", help: AppShortcut.forward.help("Forward"), id: "nav-forward",
        enabled: model.canGoForward
      ) {
        model.goForward()
      }
    }
  }
}

/// Opens a popover, not a menu, because the snapshot hook draws popovers and not menus.
private struct RecentPlacesButton: View {
  @EnvironmentObject var model: BoardModel

  var body: some View {
    HistoryButton(
      "Recent Places", "clock", help: AppShortcut.showRecentPlaces.help("Recent places"), id: "nav-history",
      enabled: model.hasRecentPlaces
    ) {
      model.showingRecentPlaces.toggle()
    }
    .popover(isPresented: $model.showingRecentPlaces, arrowEdge: .bottom) { RecentPlacesList() }
  }
}

private struct HistoryButton: View {
  let title: String
  let icon: String
  let help: String
  let id: String
  let enabled: Bool
  let action: () -> Void

  init(
    _ title: String, _ icon: String, help: String, id: String, enabled: Bool, action: @escaping () -> Void
  ) {
    self.title = title
    self.icon = icon
    self.help = help
    self.id = id
    self.enabled = enabled
    self.action = action
  }

  var body: some View {
    Button(action: action) { Label(title, systemImage: icon) }
      .labelStyle(.iconOnly)
      .help(help)
      .accessibilityIdentifier(id)
      .disabled(!enabled)
  }
}

/// The Recent Places popover, newest first.
private struct RecentPlacesList: View {
  @EnvironmentObject var model: BoardModel

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("Recent").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.bottom, 4)
      ForEach(model.recentPlaces, id: \.self) { place in
        Button {
          model.go(to: place)
        } label: {
          HStack(spacing: 8) {
            icon(place).frame(width: 16)
            Text(model.label(for: place)).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
          }
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
    }
    .padding(8)
    .frame(width: 280)
  }

  @ViewBuilder private func icon(_ place: NavLocation) -> some View {
    if let view = place.place.mainView {
      Image(systemName: view.symbol)
    } else if case .session(let id) = place.place {
      Circle().fill(model.summary(id)?.state.color ?? .gray).frame(width: 8, height: 8)
    }
  }
}

/// Mouse buttons 4 and 5 and the three-finger swipe go back and forward in the main window.
@MainActor
enum NavMouse {
  private static var monitor: Any?

  /// Back or forward for an event, or nil when the event is neither. `buttonNumber` counts from 0, so
  /// buttons 4 and 5 are 3 and 4. A swipe to the right, with a positive `deltaX`, goes back, as in Safari.
  nonisolated static func direction(type: NSEvent.EventType, buttonNumber: Int, deltaX: CGFloat) -> NavDirection? {
    switch type {
    case .otherMouseDown:
      switch buttonNumber {
      case 3: return .back
      case 4: return .forward
      default: return nil
      }
    case .swipe:
      if deltaX > 0 { return .back }
      if deltaX < 0 { return .forward }
      return nil
    default:
      return nil
    }
  }

  static func install(_ model: BoardModel) {
    guard monitor == nil else { return }
    monitor = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown, .swipe]) { event in
      MainActor.assumeIsolated { handle(event, model) } ? nil : event
    }
  }

  /// Goes back or forward, and reports whether it used the event. It uses a back or forward event even
  /// when there is nowhere to go, so a terminal under the pointer never gets the button.
  static func handle(_ event: NSEvent, _ model: BoardModel) -> Bool {
    let deltaX = event.type == .swipe ? event.deltaX : 0
    let buttonNumber = event.type == .otherMouseDown ? event.buttonNumber : 0
    guard let direction = direction(type: event.type, buttonNumber: buttonNumber, deltaX: deltaX),
      !model.presentingSheet, event.window === NSApp.switchboardWindow
    else { return false }
    model.go(direction)
    return true
  }
}
