import AppKit
import SwiftUI
import SwitchboardCore

/// The Issues view's setup sheet: the sources, the team's labels and logins, and the default start preset.
struct IssueSetupView: View {
  @EnvironmentObject var model: BoardModel
  @Environment(\.dismiss) private var dismiss
  @State private var name = ""
  @State private var label = ""
  @State private var person = ""
  @State private var addError: String?
  @State private var adding = false
  @State private var labels = ""
  @State private var people = ""
  @State private var defaultPreset: String?
  /// Whether the team and preset fields hold the list's values. The sheet can open before the first read.
  @State private var loaded = false

  var body: some View {
    let list = model.issueList
    VStack(alignment: .leading, spacing: 14) {
      Text("Issue Sources").font(.title2.bold())
      GroupBox("Sources") {
        VStack(alignment: .leading, spacing: 6) {
          if list?.sources.isEmpty ?? true {
            Text("No sources yet").foregroundStyle(.secondary)
          }
          ForEach(list?.sources ?? [], id: \.key) { source in
            HStack {
              Text(source.name).fontWeight(.medium)
              Text(filterText(source)).foregroundStyle(.secondary)
              Spacer()
              Button {
                model.removeIssueSource(source)
              } label: {
                Image(systemName: "minus.circle")
              }
              .buttonStyle(.borderless)
              .help("Remove this source")
              .accessibilityLabel("Remove \(source.key)")
            }
          }
          Divider()
          HStack {
            TextField("Org or owner/name", text: $name)
            Menu {
              ForEach(model.suggestedIssueSources, id: \.self) { suggestion in
                Button(suggestion) { name = suggestion }
              }
            } label: {
              Image(systemName: "text.badge.plus")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(model.suggestedIssueSources.isEmpty)
            .help("The orgs and repositories you already have sessions in")
            TextField("Label", text: $label)
            TextField("Person", text: $person)
            Button("Add") { add() }
              .disabled(!canAdd || adding)
              // Return adds a typed source instead of saving the sheet without it.
              .keyboardShortcut(trimmedName.isEmpty ? nil : .defaultAction)
          }
          if let problem = addProblem ?? addError {
            Text(problem).font(.caption).foregroundStyle(.red)
          }
        }
        .padding(4)
        .announcesRefusal(addError)
      }
      GroupBox("My Team") {
        VStack(alignment: .leading, spacing: 6) {
          TextField("Labels", text: $labels, prompt: Text("Labels, separated by commas"))
          TextField("People", text: $people, prompt: Text("Logins, separated by commas"))
        }
        .padding(4)
      }
      HStack {
        Picker("Start preset", selection: $defaultPreset) {
          ForEach(list?.presets ?? [], id: \.name) { Text($0.name).tag(Optional($0.name)) }
        }
        .fixedSize()
        Button("Edit Presets…") { NSWorkspace.shared.open(URL(fileURLWithPath: Home().config)) }
          .help("Presets are prompt templates under issues.presets in config.json")
      }
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Save") {
          model.saveIssueSettings(labels: split(labels), people: split(people), defaultPreset: defaultPreset)
          dismiss()
        }
        .keyboardShortcut(trimmedName.isEmpty ? .defaultAction : nil)
      }
    }
    .padding(20)
    .frame(width: 600)
    .onChange(of: model.issueList == nil, initial: true) {
      guard !loaded, let list = model.issueList else { return }
      loaded = true
      labels = list.team.labels.joined(separator: ", ")
      people = list.team.people.joined(separator: ", ")
      defaultPreset = IssuePreset.choose(list.presets, last: nil, default: list.defaultPreset)?.name
    }
  }

  private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

  private var canAdd: Bool { !trimmedName.isEmpty && addProblem == nil }

  /// The rule that sbd also checks, shown before Add.
  private var addProblem: String? {
    guard !trimmedName.isEmpty, !trimmedName.contains("/") else { return nil }
    let blank = { (s: String) in s.trimmingCharacters(in: .whitespaces).isEmpty }
    return blank(label) && blank(person) ? IssueSource.orgNeedsFilter : nil
  }

  private func add() {
    adding = true
    addError = nil
    model.addIssueSource(trimmedName, label: label, person: person) { error in
      adding = false
      addError = error
      if error == nil {
        name = ""
        label = ""
        person = ""
      }
    }
  }

  private func filterText(_ source: IssueSource) -> String {
    [source.label.map { "label \($0)" }, source.person.map { "assigned to \($0)" }].compactMap { $0 }
      .joined(separator: ", ")
  }

  private func split(_ text: String) -> [String] {
    text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
  }
}
