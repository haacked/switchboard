import Foundation
import SwitchboardCore

/// A tab of the Settings window.
enum SettingsTab: String, CaseIterable {
  case general, issues, advanced
}

extension BoardModel {
  /// Reads this Mac's live cap and the auto mode and shell settings from sbd for Settings ▸ General. The reads change nothing,
  /// so they skip the refresh that `perform` runs after each request.
  func loadSettings() {
    let send = send
    worker.async {
      let live = try? send("live", [:])
      let autoMode = try? send("auto-mode", [:])
      let openShell = try? send("open-shell", [:])
      Task { @MainActor in
        if self.pendingSettingWrites["live", default: 0] == 0 { live.map(self.applyLive) }
        if self.pendingSettingWrites["auto-mode", default: 0] == 0 { autoMode.map(self.applyAutoMode) }
        if self.pendingSettingWrites["open-shell", default: 0] == 0 { openShell.map(self.applyOpenShell) }
      }
    }
  }

  /// Sets this Mac's live cap.
  func setLiveCap(_ cap: Int) {
    guard cap != liveCap else { return }
    liveCap = cap
    changeSetting("live", ["cap": .number(Double(cap))], apply: applyLive)
  }

  /// Sets whether new sessions start in auto mode.
  func setAutoMode(_ on: Bool) {
    defaultAutoMode = on
    changeSetting("auto-mode", ["autoMode": .bool(on)], apply: applyAutoMode)
  }

  /// Sets whether new sessions open a shell.
  func setOpenShell(_ on: Bool) {
    openShellByDefault = on
    changeSetting("open-shell", ["openShell": .bool(on)], apply: applyOpenShell)
  }

  /// Makes new sessions run under the account. Unlike the toolbar's account menu, it never offers to move
  /// sessions, because that dialog belongs to the main window and would open behind Settings.
  func setDefaultAccount(_ folder: String) {
    changeSetting("account-use", ["account": .string(folder)]) { _ in }
  }

  /// Shows the Settings window at `tab`.
  func openSettings(_ tab: SettingsTab) {
    settingsTab = tab
    showSettings?()
  }

  /// Sends a Settings ▸ General change. A refusal shows in Settings instead of the main window's banner, and the
  /// controls go back to sbd's settings.
  private func changeSetting(_ op: String, _ args: [String: JSON], apply: @escaping (JSON) -> Void) {
    pendingSettingWrites[op, default: 0] += 1
    perform(
      op, args,
      then: { reply in
        self.settingsError = nil
        if self.finishSettingWrite(op) { apply(reply) }
      },
      failed: { error in
        self.settingsError = "\(error)"
        if self.finishSettingWrite(op) { self.loadSettings() }
      })
  }

  /// Counts the answer to a write of `op`, and gives whether it answers the newest one.
  private func finishSettingWrite(_ op: String) -> Bool {
    pendingSettingWrites[op, default: 1] -= 1
    return pendingSettingWrites[op] == 0
  }

  private func applyLive(_ reply: JSON) {
    if let cap = try? JSONCoding.convert(reply, to: LiveStatus.self).cap { liveCap = cap }
  }

  private func applyAutoMode(_ reply: JSON) {
    if let on = reply["autoMode"]?.bool { defaultAutoMode = on }
  }

  private func applyOpenShell(_ reply: JSON) {
    if let on = reply["openShell"]?.bool { openShellByDefault = on }
  }
}
