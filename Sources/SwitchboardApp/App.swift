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
    viewSettingsStore: Bundle.main.bundleIdentifier != nil ? .standard : nil, orgFilter: Snapshot.orgFilter,
    groupFilter: Snapshot.groupFilter)

  var body: some Scene {
    Window("Switchboard", id: "main") {
      ContentView()
        .environmentObject(model)
        .onAppear {
          model.start()
          NavMouse.install(model)
          ShortcutsKey.install(model)
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
          .shortcut(.newSession)
          .disabled(model.presentingSheet)
        let newSessionGroup = model.newSessionGroup
        Button(newSessionGroup.map { "New Session in \($0.name)…" } ?? "New Session in Group…") {
          model.openNewSession(group: newSessionGroup?.id)
        }
        .shortcut(.newSessionInGroup)
        .disabled(model.presentingSheet || newSessionGroup == nil)
        Button("New Conversation") { model.openManager(new: true) }
          .shortcut(.newConversation)
          .disabled(model.presentingSheet)
        Button("Import Sessions…") { model.showingImport = true }
          .shortcut(.importSessions)
          .disabled(model.presentingSheet)
        Button("New Group") { model.startNewGroup() }
          .shortcut(.newGroup)
          .disabled(model.presentingSheet)
        Button("New Loop…") { model.loopEditor = .new }
          .disabled(model.presentingSheet)
      }
      CommandGroup(after: .sidebar) {
        ForEach(MainView.allCases, id: \.self) { view in
          Button("Show \(view.title)") { model.show(view) }
            .shortcut(view.shortcut)
        }
        Button("Filter Sessions…") { model.showingFilter.toggle() }
          .shortcut(.filterSessions)
          .disabled(model.presentingSheet)
      }
      CommandMenu("Go") {
        Group {
          Button("Back") { model.goBack() }
            .shortcut(.back)
            .disabled(!model.canGoBack)
          Button("Forward") { model.goForward() }
            .shortcut(.forward)
            .disabled(!model.canGoForward)
          Button("Show Recent Places") { model.showingRecentPlaces.toggle() }
            .shortcut(.showRecentPlaces)
            .disabled(!model.hasRecentPlaces)
        }
        .disabled(model.presentingSheet)
        Divider()
        Button("Next Needing You") { model.selectNextNeedingYou() }
          .shortcut(.nextNeedingYou)
        Group {
          Button("Next Session") { model.selectAdjacentSession(by: 1) }
            .shortcut(.nextSession)
          Button("Previous Session") { model.selectAdjacentSession(by: -1) }
            .shortcut(.previousSession)
        }
        .disabled(model.presentingSheet)
        Divider()
        Button("Open Manager") { model.openManager() }
          .shortcut(.openManager)
          .operatorTranscriptAlternate { model.openOperator() }
        Group {
          Button("Search Sessions…") { model.showingSearch = true }
            .shortcut(.searchSessions)
          Button("Ask Switchboard…") { model.openQuickAsk() }
            .shortcut(.quickAsk)
          Divider()
          Button("Move Focus to List") { model.requestListFocus() }
            .shortcut(.focusList)
          Button("Move Focus to Terminal") { model.focusTerminal() }
            .shortcut(.focusTerminal)
            .disabled(!model.canFocusTerminal)
        }
        .disabled(model.presentingSheet)
      }
      CommandGroup(replacing: .help) {
        Button("Keyboard Shortcuts", action: model.toggleShortcuts)
          .shortcut(.keyboardShortcuts)
          .disabled(!model.canToggleShortcuts)
      }
      CommandMenu("Session") {
        let acknowledgeTarget = model.acknowledgeTarget
        Button("Message Claude") { model.revealMessageField() }
          .shortcut(.messageClaude)
          .disabled(model.presentingSheet || model.messageFieldTarget == nil)
        Divider()
        // The items act on `selection`, which the detail pane does not show during a multi-selection.
        Group {
          Button("Stop Claude") { model.selection.map(model.stop) }
            .shortcut(.stopClaude)
            .disabled(model.selected?.live != true)
          Button("Resume Claude") { model.selection.map(model.resume) }
            .shortcut(.resumeClaude)
            .disabled(model.selected == nil || model.selected?.live == true || model.selected?.runsClaude == false)
          Button(model.selected?.shellClosed == true ? "Open Shell" : "Close Shell") {
            if let s = model.selected { model.setShellOpen(s.id, s.shellClosed == true) }
          }
          .disabled(model.selected?.hasTerminals != true)
          Button(model.selected?.markedDone == true ? "Mark Not Done" : "Mark Done") {
            if let s = model.selected { model.setDone(s.id, !s.markedDone) }
          }
          .shortcut(.markDone)
          .disabled(model.selected == nil)
          Button(acknowledgeTarget?.acknowledgeTitle ?? "Acknowledge") {
            if let s = model.acknowledgeTarget { model.acknowledge(s.id, undo: s.acknowledged == true) }
          }
          .shortcut(.acknowledge)
          .disabled(acknowledgeTarget?.canAcknowledge != true)
          CopyLinkMenuItem(session: model.selected)
        }
        .disabled(model.showsMultiSelection)
      }
    }

    MenuBarExtra {
      MenuBarContent().environmentObject(model)
    } label: {
      MenuBarLabel().environmentObject(model)
    }

    Settings {
      SettingsView().environmentObject(model)
    }
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    if BackgroundLaunch.isRunning {
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

  /// Launch Services calls this for a `switchboard:` URL, such as one that `sb focus` opens.
  func application(_ application: NSApplication, open urls: [URL]) {
    NSApp.activate(ignoringOtherApps: true)
    urls.forEach(LinkInbox.shared.receive)
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
    withCompletionHandler done: @escaping () -> Void
  ) {
    if let id = response.notification.request.content.userInfo["session"] as? String {
      Task { @MainActor in LinkInbox.shared.receive(SessionLink.url(for: id)) }
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
/// handles a click on a notification or a `switchboard:` URL when the window
/// is closed.
struct MenuBarLabel: View {
  @EnvironmentObject var model: BoardModel
  @Environment(\.openWindow) private var openWindow
  @Environment(\.openSettings) private var openSettings

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
    .onAppear {
      // Before the attach, because a held URL can open the window.
      model.showWindow = { openWindow(id: "main") }
      model.showSettings = {
        openSettings()
        // An app that isn't frontmost would open Settings behind the window that has focus.
        if !BackgroundLaunch.isRunning { NSApp.activate(ignoringOtherApps: true) }
      }
      LinkInbox.shared.attach(model.openExternalLink)
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
        Button(Self.title(name: model.inboxName(s), line: model.inboxLine(s))) {
          model.selection = s.id
          show()
        }
      }
    }
    Divider()
    Button("Open Switchboard") { show() }
    Button("Quit Switchboard") { NSApp.terminate(nil) }
  }

  /// A menu item names the session and its Inbox line, cut at `Triage.titleLength`, because a rule title can reach
  /// 100 characters.
  static func title(name: String, line: String) -> String {
    "\(name): \(truncated(line, max: Triage.titleLength))"
  }

  private func show() {
    openWindow(id: "main")
    NSApp.activate(ignoringOtherApps: true)
  }
}

extension View {
  /// Holding ⌥ shows "Open Operator Transcript" in place of this menu item. macOS 14 has no alternate items, so the
  /// Loops view's Transcript button is the only way to the transcript there.
  @ViewBuilder func operatorTranscriptAlternate(_ open: @escaping () -> Void) -> some View {
    if #available(macOS 15, *) {
      modifierKeyAlternate(.option) { Button("Open Operator Transcript", action: open) }
    } else {
      self
    }
  }
}
