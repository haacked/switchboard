import AppKit
import SwiftUI
import SwitchboardCore
import UserNotifications

@main
struct SwitchboardApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
  @StateObject private var model = BoardModel()

  init() { AppTerminal.announce() }

  var body: some Scene {
    Window("Switchboard", id: "main") {
      ContentView()
        .environmentObject(model)
        .onAppear {
          model.start()
          Snapshot.start(model)
        }
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.openSession)) { note in
          model.selection = note.object as? String
        }
        .frame(minWidth: 900, minHeight: 560)
    }
    .defaultSize(width: 1400, height: 900)
    .commands {
      CommandGroup(after: .newItem) {
        // A sheet blocks the window's buttons but not the menu bar. Without
        // the check, a menu command opens a second sheet over the first.
        Button("New Session…") { model.showingNew = true }
          .keyboardShortcut("n")
          .disabled(model.presentingSheet)
        Button("Import Sessions…") { model.showingImport = true }
          .keyboardShortcut("i", modifiers: [.command, .shift])
          .disabled(model.presentingSheet)
      }
      CommandMenu("Session") {
        Button("Next Needing You") { model.selectNextNeedingYou() }
          .keyboardShortcut("j")
        Button("Show Queue") { model.show(board: false) }
          .keyboardShortcut("1")
        Button("Show Board") { model.show(board: true) }
          .keyboardShortcut("2")
        Divider()
        Button("Stop Claude") { model.selection.map(model.stop) }
          .keyboardShortcut(".", modifiers: [.command])
          .disabled(model.selected?.live != true)
        Button("Resume Claude") { model.selection.map(model.resume) }
          .keyboardShortcut("r", modifiers: [.command, .shift])
          .disabled(model.selected == nil || model.selected?.live == true || model.selected?.waitsToStart == true)
        Button(model.selected?.markedDone == true ? "Mark Not Done" : "Mark Done") {
          if let s = model.selected { model.setDone(s.id, !s.markedDone) }
        }
        .keyboardShortcut("d", modifiers: [.command, .shift])
        .disabled(model.selected == nil)
      }
    }

    MenuBarExtra {
      MenuBarContent().environmentObject(model)
    } label: {
      let count = model.needsYou.count
      if count == 0 {
        Image(systemName: "square.grid.3x3")
      } else {
        HStack(spacing: 2) {
          Image(systemName: "exclamationmark.bubble.fill")
          Text("\(count)")
        }
      }
    }
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
  /// The session that the user clicked in a notification.
  static let openSession = Notification.Name("SwitchboardOpenSession")

  func applicationDidFinishLaunching(_ notification: Notification) {
    // A build-folder executable has no Info.plist, so it starts as a
    // background process without this.
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
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

struct MenuBarContent: View {
  @EnvironmentObject var model: BoardModel
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    if model.unreachable != nil {
      Text("sbd isn't running")
    } else if model.needsYou.isEmpty {
      Text("Nothing needs you")
    } else {
      ForEach(model.needsYou) { s in
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
