import AppKit
import SwiftUI

/// The areas that an open shortcuts overlay lists. The model sets them when the overlay opens, so the list stays the same
/// while the view behind the overlay changes.
struct ShortcutsOverlayRequest: Equatable {
  var areas: [ShortcutArea]
}

extension BoardModel {
  /// The areas whose shortcuts work in what the window shows now, in `ShortcutArea` order.
  /// `messageFieldTarget` names the session whose Claude terminal shows now, so it decides the Terminal area.
  var shortcutAreas: [ShortcutArea] {
    let always: [ShortcutArea] = [.navigation, .sessions]
    let terminal: [ShortcutArea] = messageFieldTarget == nil ? [] : [.terminal]
    if showsMultiSelectionPane { return always }
    if selected != nil { return terminal.isEmpty ? always : always + [.messageField] + terminal }
    switch mainView {
    case .inbox: return always + [.inboxDecisions, .messageField] + terminal
    case .board: return always + [.board]
    case .issues, .loops: return always
    }
  }

  func openShortcuts() { shortcutsOverlay = ShortcutsOverlayRequest(areas: shortcutAreas) }

  func closeShortcuts() { shortcutsOverlay = nil }

  /// The Help menu's Keyboard Shortcuts item opens the overlay, or closes it while it shows, as `?` does.
  func toggleShortcuts() { if shortcutsOverlay == nil { openShortcuts() } else { closeShortcuts() } }

  /// The Help item can open the overlay when no other sheet shows, and can always close it.
  var canToggleShortcuts: Bool { !presentingSheet || shortcutsOverlay != nil }

  func showAllShortcuts() { shortcutsOverlay = ShortcutsOverlayRequest(areas: ShortcutArea.allCases) }
}

/// The `?` key, which opens and closes the shortcuts overlay.
@MainActor
enum ShortcutsKey {
  enum Action: Equatable {
    case open, close
  }

  /// Where a key went, and what the model shows.
  struct Place: Equatable {
    /// The key went to the main window.
    var isMainWindow: Bool
    /// The key went to the sheet attached to the main window.
    var isMainWindowSheet: Bool
    /// The main window has a sheet. A confirmation dialog is one too. `presentingSheet` does not count it.
    var mainWindowHasSheet: Bool
    var presentingSheet: Bool
    var overlayOpen: Bool
  }

  private static var monitor: Any?

  /// What a key does to the overlay, or nil to leave the key alone.
  ///
  /// The check takes only a `?` that no text can receive: the focused view must not take typed text and no input
  /// method may compose. A key repeat does nothing, so holding `?` does not flip the overlay. ⇧ may be held, because most layouts type `?` with it. ⌘, ⌥, and ⌃ leave the key to the
  /// menus. `?` opens the overlay over a main window that shows no sheet. It closes the overlay only from the
  /// overlay's own sheet.
  static func action(
    characters: String?, modifiers: NSEvent.ModifierFlags, isRepeat: Bool, responder: NSResponder?, composing: Bool,
    place: Place
  ) -> Action? {
    guard characters == "?", !isRepeat, modifiers.isDisjoint(with: [.command, .option, .control]), !composing,
      !(responder is NSTextInputClient)
    else { return nil }
    if place.overlayOpen { return place.isMainWindowSheet ? .close : nil }
    return place.isMainWindow && !place.mainWindowHasSheet && !place.presentingSheet ? .open : nil
  }

  static func install(_ model: BoardModel) {
    guard monitor == nil else { return }
    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      MainActor.assumeIsolated { handle(event, model) } ? nil : event
    }
  }

  /// Opens or closes the overlay. It reports whether it used the event. The hidden GUI harness has no key window,
  /// so the responder comes from the event's own window.
  private static func handle(_ event: NSEvent, _ model: BoardModel) -> Bool {
    // Most keys are not ?, so the cheap check runs before the window and model lookups.
    guard event.characters == "?" else { return false }
    let main = NSApp.switchboardWindow
    let window = event.window
    let place = Place(
      isMainWindow: window != nil && window === main,
      isMainWindowSheet: window != nil && window === main?.attachedSheet,
      mainWindowHasSheet: main?.attachedSheet != nil, presentingSheet: model.presentingSheet,
      overlayOpen: model.shortcutsOverlay != nil)
    switch action(
      characters: event.characters, modifiers: event.modifierFlags, isRepeat: event.isARepeat,
      responder: window?.firstResponder,
      composing: TextInput.isComposing, place: place)
    {
    case .open: model.openShortcuts()
    case .close: model.closeShortcuts()
    case nil: return false
    }
    return true
  }
}

/// The sheet that lists the shortcuts of the request's areas.
struct ShortcutsOverlay: View {
  @EnvironmentObject var model: BoardModel
  let request: ShortcutsOverlayRequest

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("Keyboard Shortcuts").font(.title2.bold()).padding()
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          ForEach(request.areas) { section($0) }
        }
        .padding()
      }
      Divider()
      HStack {
        Text(
          "Press \(AppShortcut.glyphs(AppShortcut.keyboardShortcuts.keys[1])) or \(AppShortcut.searchClose.glyphs) to close"
        ).font(.caption).foregroundStyle(.secondary)
        Spacer()
        if request.areas != ShortcutArea.allCases {
          Button("Show All Shortcuts", action: model.showAllShortcuts)
        }
        Button("Done") { model.closeShortcuts() }
          .keyboardShortcut(.cancelAction)
      }
      .padding()
    }
    .frame(width: 520, height: 480)
  }

  private func section(_ area: ShortcutArea) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(area.title).font(.headline).accessibilityAddTraits(.isHeader)
      ForEach(AppShortcut.allCases.filter { $0.area == area }) { entry in
        HStack(alignment: .firstTextBaseline) {
          Text(entry.title)
          Spacer(minLength: 12)
          Text(entry.glyphs).font(.body.monospaced()).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
      }
    }
  }
}
