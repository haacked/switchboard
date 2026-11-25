import AppKit
import SwiftUI
import SwitchboardCore

/// The Settings window (⌘,). Every change goes through sbd. sbd saves it in config.json, which stays the source of
/// truth.
struct SettingsView: View {
  @EnvironmentObject var model: BoardModel

  var body: some View {
    TabView(selection: $model.settingsTab) {
      GeneralSettings()
        .tabItem { Label("General", systemImage: "gearshape") }
        .tag(SettingsTab.general)
      IssueSetupView()
        .tabItem { Label("Issues", systemImage: "smallcircle.filled.circle") }
        .tag(SettingsTab.issues)
      AdvancedSettings()
        .tabItem { Label("Advanced", systemImage: "gearshape.2") }
        .tag(SettingsTab.advanced)
    }
    .onAppear { model.settingsShown = true }
    .onDisappear { model.settingsShown = false }
  }
}

/// This Mac's live cap, the auto mode of new sessions, and the account of new sessions.
struct GeneralSettings: View {
  @EnvironmentObject var model: BoardModel
  /// The number in the cap field. It reaches sbd on Return or when the field loses focus, not on each keystroke.
  @State private var capDraft = 1
  @FocusState private var capFocused: Bool

  var body: some View {
    let offline = model.unreachable != nil
    Form {
      if offline {
        Text("sbd isn't running, so these settings can't change.").foregroundStyle(.secondary)
      }
      Section {
        let cap = Binding(get: { model.liveCap ?? 1 }, set: { model.setLiveCap($0) })
        LabeledContent("Live cap on this Mac") {
          HStack {
            TextField("Live cap", value: $capDraft, format: .number)
              .focused($capFocused)
              .onSubmit { model.setLiveCap(capDraft) }
              .onChange(of: capFocused) { if !capFocused { model.setLiveCap(capDraft) } }
              .onChange(of: model.liveCap, initial: true) { capDraft = model.liveCap ?? 1 }
              .labelsHidden()
              .multilineTextAlignment(.trailing)
              .frame(width: 56)
            Stepper("Live cap", value: cap, in: 1...999).labelsHidden()
          }
        }
        .disabled(offline || model.liveCap == nil)
        Text("The most claude processes that run at once on this Mac. Starts past the cap wait in a queue.")
          .font(.caption).foregroundStyle(.secondary)
      }
      Section {
        Toggle(
          "Start new sessions in auto mode",
          isOn: Binding(get: { model.defaultAutoMode ?? false }, set: { model.setAutoMode($0) })
        )
        .disabled(offline || model.defaultAutoMode == nil)
        Text(
          "Sessions that already exist keep their mode. `sb new --no-auto` starts one session without auto mode."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
      Section {
        Toggle(
          "Open a shell in new sessions",
          isOn: Binding(get: { model.openShellByDefault ?? true }, set: { model.setOpenShell($0) })
        )
        .disabled(offline || model.openShellByDefault == nil)
        Text("Sessions that already exist keep their shell. Session ▸ Open Shell opens one later.")
          .font(.caption).foregroundStyle(.secondary)
      }
      Section {
        let rows = AccountMenu.rows(accounts: model.sessionAccounts, usage: model.usage)
        if rows.isEmpty {
          LabeledContent("Account for new sessions") { Text("Not listed yet").foregroundStyle(.secondary) }
        } else {
          Picker(
            "Account for new sessions",
            selection: Binding(
              get: { rows.first { $0.account.active }?.id ?? "" },
              set: { model.setDefaultAccount($0) })
          ) {
            ForEach(rows) { row in
              Text(row.choiceTitle).tag(row.id).disabled(row.signedOut && !row.account.active)
            }
          }
          .disabled(offline)
        }
        Text(
          "New sessions use this account unless their group names one. To move existing sessions, use the account menu in the toolbar."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
      if let error = model.settingsError {
        Text(error).font(.caption).foregroundStyle(.red)
      }
    }
    .formStyle(.grouped)
    .frame(width: 500)
    .fixedSize(horizontal: false, vertical: true)
    .announcesRefusal(model.settingsError)
    .onAppear { model.loadSettings() }
    // A read while sbd was down left the cap and the toggle disabled.
    .onChange(of: offline) { if !offline { model.loadSettings() } }
  }
}

/// Opens config.json for the settings that the window doesn't show.
struct AdvancedSettings: View {
  private let url = URL(fileURLWithPath: Home().config)
  @State private var exists = false

  var body: some View {
    Form {
      Section {
        LabeledContent("config.json") {
          Text(url.path).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
        }
        HStack {
          Button("Open config.json") { NSWorkspace.shared.open(url) }
            .disabled(!exists)
          Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([exists ? url : url.deletingLastPathComponent()])
          }
        }
        Text(
          exists
            ? "Restart sbd after you edit it by hand (`sb service install` restarts it). The settings in this window apply without a restart."
            : "No config.json yet. Every setting has its default."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .frame(width: 500)
    .fixedSize(horizontal: false, vertical: true)
    .onAppear { exists = FileManager.default.fileExists(atPath: url.path) }
  }
}
