import AppKit
import SwiftUI
import SwitchboardCore
import UserNotifications

extension NSApplication {
  /// The app's main window, found by the title that `SwitchboardApp` gives it.
  var switchboardWindow: NSWindow? { windows.first { $0.isVisible && $0.title == "Switchboard" } }
}

@main
struct SwitchboardApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
  @StateObject private var model = BoardModel(
    client: Client(), draftsFolder: Home().drafts,
    orgFilterStore: Bundle.main.bundleIdentifier != nil ? .standard : nil, orgFilter: Snapshot.orgFilter)

  var body: some Scene {
    Window("Switchboard", id: "main") {
      ContentView()
        .environmentObject(model)
        .onAppear {
          model.start()
          NavMouse.install(model)
          Snapshot.start(model)
        }
        .frame(minWidth: ContentView.windowMinWidth, minHeight: 560)
    }
    .defaultSize(width: 1400, height: 900)
    .commands {
      CommandGroup(after: .newItem) {
        // A sheet blocks the window's buttons but not the menu bar. Without
        // the check, a menu command opens a second sheet over the first.
        Button("New Session…") { model.openNewSession() }
          .keyboardShortcut("n")
          .disabled(model.presentingSheet)
        let newSessionGroup = model.newSessionGroup
        Button(newSessionGroup.map { "New Session in \($0.name)…" } ?? "New Session in Group…") {
          model.openNewSession(group: newSessionGroup?.id)
        }
        .keyboardShortcut("n", modifiers: [.command, .shift])
        .disabled(model.presentingSheet || newSessionGroup == nil)
        Button("Import Sessions…") { model.showingImport = true }
          .keyboardShortcut("i", modifiers: [.command, .shift])
          .disabled(model.presentingSheet)
        Button("New Group") { model.startNewGroup() }
          .keyboardShortcut("g", modifiers: [.command, .shift])
          .disabled(model.presentingSheet)
      }
      CommandMenu("Session") {
        let acknowledgeTarget = model.acknowledgeTarget
        Button("Next Needing You") { model.selectNextNeedingYou() }
          .keyboardShortcut("j")
        Button("Open Manager") { model.openManager() }
          .keyboardShortcut("m", modifiers: [.command, .shift])
        Button("Show Inbox") { model.show(.inbox) }
          .keyboardShortcut("1")
        Button("Show Board") { model.show(.board) }
          .keyboardShortcut("2")
        Button("Show Issues") { model.show(.issues) }
          .keyboardShortcut("3")
        Button("Filter by Org…") { model.showingOrgFilter.toggle() }
          .keyboardShortcut("o", modifiers: [.command, .shift])
          .disabled(model.presentingSheet)
        Divider()
        Group {
          Button("Search Sessions…") { model.showingSearch = true }
            .keyboardShortcut(NavShortcuts.searchSessions)
          Button("Next Session") { model.selectAdjacentSession(by: 1) }
            .keyboardShortcut(NavShortcuts.nextSession)
          Button("Previous Session") { model.selectAdjacentSession(by: -1) }
            .keyboardShortcut(NavShortcuts.previousSession)
          Button("Back") { model.goBack() }
            .keyboardShortcut(NavShortcuts.back)
            .disabled(!model.canGoBack)
          Button("Forward") { model.goForward() }
            .keyboardShortcut(NavShortcuts.forward)
            .disabled(!model.canGoForward)
          Button("Show Recent Places") { model.showingRecentPlaces.toggle() }
            .keyboardShortcut(NavShortcuts.showRecentPlaces)
            .disabled(!model.hasRecentPlaces)
          Button("Move Focus to List") { model.requestListFocus() }
            .keyboardShortcut(NavShortcuts.focusList)
          Button("Move Focus to Terminal") { model.focusTerminal() }
            .keyboardShortcut(NavShortcuts.focusTerminal)
            .disabled(!model.canFocusTerminal)
        }
        .disabled(model.presentingSheet)
        Divider()
        Button("Stop Claude") { model.selection.map(model.stop) }
          .keyboardShortcut(".", modifiers: [.command])
          .disabled(model.selected?.live != true)
        Button("Resume Claude") { model.selection.map(model.resume) }
          .keyboardShortcut("r", modifiers: [.command, .shift])
          .disabled(model.selected == nil || model.selected?.live == true || model.selected?.runsClaude == false)
        Button(model.selected?.shellClosed == true ? "Open Shell" : "Close Shell") {
          if let s = model.selected { model.setShellOpen(s.id, s.shellClosed == true) }
        }
        .disabled(model.selected?.hasTerminals != true)
        Button(model.selected?.markedDone == true ? "Mark Not Done" : "Mark Done") {
          if let s = model.selected { model.setDone(s.id, !s.markedDone) }
        }
        .keyboardShortcut("d", modifiers: [.command, .shift])
        .disabled(model.selected == nil)
        Button(acknowledgeTarget?.acknowledgeTitle ?? "Acknowledge") {
          if let s = model.acknowledgeTarget { model.acknowledge(s.id, undo: s.acknowledged == true) }
        }
        .keyboardShortcut("a", modifiers: [.command, .shift])
        .disabled(acknowledgeTarget?.canAcknowledge != true)
      }
    }

    MenuBarExtra {
      MenuBarContent().environmentObject(model)
    } label: {
      MenuBarLabel().environmentObject(model)
    }
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
  /// The session that the user clicked in a notification.
  static let openSession = Notification.Name("SwitchboardOpenSession")

  func applicationDidFinishLaunching(_ notification: Notification) {
    if BackgroundLaunch.applies(to: ProcessInfo.processInfo.environment) {
      BackgroundLaunch.start()
    } else {
      // A build-folder executable has no Info.plist, so it starts as a
      // background process without this.
      NSApp.setActivationPolicy(.regular)
      NSApp.activate(ignoringOtherApps: true)
    }
    // Notifications need a bundle identifier, which only the app bundle has.
    if Bundle.main.bundleIdentifier != nil { UNUserNotificationCenter.current().delegate = self }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
    withCompletionHandler done: @escaping () -> Void
  ) {
    if let id = response.notification.request.content.userInfo["session"] as? String {
      NotificationCenter.default.post(name: AppDelegate.openSession, object: id)
    }
    NSApp.activate(ignoringOtherApps: true)
    done()
  }

  /// Shows a notification even while the app is in front.
  func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
    withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    done([.banner, .sound])
  }
}

/// The menu bar item exists while the app runs, unlike the window, so it
/// handles a click on a notification when the window is closed.
struct MenuBarLabel: View {
  @EnvironmentObject var model: BoardModel
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    let count = model.needsUser.count
    Group {
      if count == 0 {
        Image(systemName: "square.grid.3x3")
      } else {
        HStack(spacing: 2) {
          Image(systemName: "exclamationmark.bubble.fill")
          Text("\(count)")
        }
      }
    }
    .onAppear { model.showWindow = { openWindow(id: "main") } }
    .onReceive(NotificationCenter.default.publisher(for: AppDelegate.openSession)) { note in
      if let id = note.object as? String { model.reveal(id) }
    }
  }
}

struct MenuBarContent: View {
  @EnvironmentObject var model: BoardModel
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    if model.unreachable != nil {
      Text("sbd isn't running")
    } else if model.needsUser.isEmpty {
      Text("Nothing needs you")
    } else {
      ForEach(model.needsUser) { s in
        Button("\(s.name): \(s.reason)") {
          model.selection = s.id
          show()
        }
      }
    }
    Divider()
    Button("Open Switchboard") { show() }
    Button("Quit") { NSApp.terminate(nil) }
  }

  private func show() {
    openWindow(id: "main")
    NSApp.activate(ignoringOtherApps: true)
  }
}
