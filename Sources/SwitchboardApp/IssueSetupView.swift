import AppKit
import SwiftUI
import SwitchboardCore

/// Settings ▸ Issues: the Issues view's sources, the team's labels and logins, and the default start preset.
struct IssueSetupView: View {
  /// The team fields and the start preset as the pane last loaded or saved them.
  struct Loaded: Equatable {
    var team: IssueTeam
    var preset: String?
  }

  @EnvironmentObject var model: BoardModel
  @State private var offerLabelFocused = false
  @State private var name = ""
  @State private var label = ""
  @State private var person = ""
  /// sbd's refusal of the last add or remove of a source.
  @State private var sourceError: String?
  /// sbd's refusal of the last save.
  @State private var saveError: String?
  @State private var adding = false
  @State private var labels = ""
  @State private var people = ""
  @State private var backlog = ""
  @State private var defaultPreset: String?
  /// The values that the fields loaded, or nil before the first read. The pane can open before it.
  @State private var loaded: Loaded?

  var body: some View {
    let list = model.issueList
    VStack(alignment: .leading, spacing: 14) {
      if !model.offeredIssueRepos.isEmpty {
        GroupBox("Your Repositories") {
          IssueRepoOffer(unchecked: $model.uncheckedIssueRepos) { offerLabelFocused = $0 }.padding(4)
        }
      }
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
                sourceError = nil
                model.removeIssueSource(source) { sourceError = $0 }
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
            .help("The orgs and repositories of your sessions and checkouts")
            .accessibilityLabel("Suggested sources")
            TextField("Label", text: $label, prompt: Text(isOrg ? "Label" : "Label (optional)"))
            TextField("Person", text: $person, prompt: Text(isOrg ? "Person" : "Person (optional)"))
            Button("Add") { add() }
              .disabled(!canAdd || adding)
              .keyboardShortcut(returnOwner == .add ? .defaultAction : nil)
          }
          if let problem = addProblem ?? sourceError {
            Text(problem).font(.caption).foregroundStyle(.red)
          } else {
            Text(
              "Sources decide which issues are fetched. A repository needs no filter. An org needs a label or a person."
            )
            .font(.caption).foregroundStyle(.secondary)
          }
        }
        .padding(4)
        .announcesRefusal(sourceError)
      }
      GroupBox("My Team") {
        VStack(alignment: .leading, spacing: 6) {
          TextField("Labels", text: $labels, prompt: Text("Labels, separated by commas"))
          TextField("People", text: $people, prompt: Text("Logins, separated by commas"))
          TextField("Backlog", text: $backlog, prompt: Text("Backlog labels, separated by commas"))
          Text(
            "Sorts fetched issues into the Mine and Team views, with backlog issues last. It doesn't change which issues are fetched."
          )
          .font(.caption).foregroundStyle(.secondary)
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
        if let saveError {
          Text(saveError).font(.caption).foregroundStyle(.red)
        }
        Spacer()
        Button("Save") { save() }
          .disabled(!hasChanges)
          .keyboardShortcut(returnOwner == .save ? .defaultAction : nil)
      }
      .announcesRefusal(saveError)
    }
    .padding(20)
    .frame(width: 600)
    .onAppear {
      if model.knownRepos == nil { model.loadRepos() }
      reload()
    }
    // The Settings window keeps the pane between opens, so a change through `sb issues` or another save shows in it.
    .onChange(of: model.issueList.map(Self.loaded)) { reload() }
  }

  /// The team and the start preset that the list gives the fields.
  static func loaded(from list: IssueList) -> Loaded {
    Loaded(team: list.team, preset: IssuePreset.choose(list.presets, last: nil, default: list.defaultPreset)?.name)
  }

  private var hasChanges: Bool {
    Self.hasChanges(labels: labels, people: people, backlog: backlog, preset: defaultPreset, loaded: loaded)
  }

  /// Whether the fields differ from what the pane loaded. Before the first read, any typed text is a change.
  static func hasChanges(labels: String, people: String, backlog: String, preset: String?, loaded: Loaded?) -> Bool {
    let team = loaded?.team ?? IssueTeam()
    return labels != text(team.labels) || people != text(team.people) || backlog != text(team.backlog)
      || preset != loaded?.preset
  }

  /// Takes sbd's team and preset into the fields, unless the user has edited a field since the last load or save.
  private func reload() {
    guard let list = model.issueList, !hasChanges else { return }
    show(Self.loaded(from: list))
  }

  private func show(_ values: Loaded) {
    loaded = values
    labels = Self.text(values.team.labels)
    people = Self.text(values.team.people)
    backlog = Self.text(values.team.backlog)
    defaultPreset = values.preset
  }

  private func save() {
    let team = IssueTeam(
      labels: Self.list(labels, loaded: loaded?.team.labels), people: Self.list(people, loaded: loaded?.team.people),
      backlog: Self.list(backlog, loaded: loaded?.team.backlog))
    saveError = nil
    // A refusal leaves config.json as it was, so the loaded values go back to sbd's, and Save works again.
    model.saveIssueSettings(
      labels: team.labels, people: team.people, backlog: team.backlog, defaultPreset: defaultPreset
    ) { error in
      guard let error else { return }
      saveError = error
      loaded = model.issueList.map(Self.loaded)
    }
    show(Loaded(team: team, preset: defaultPreset))
  }

  private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

  /// Whether the typed name is an org, which needs a label or a person. A repository takes either one as an optional
  /// filter.
  private var isOrg: Bool { IssueSource(name: trimmedName).isOrg }

  private enum ReturnOwner { case offer, add, save }

  /// The one button that Return presses. Return adds the checked repositories while the offer's label field has
  /// focus, and it adds a typed source instead of saving the pane without it.
  private var returnOwner: ReturnOwner { offerLabelFocused ? .offer : trimmedName.isEmpty ? .save : .add }

  private var canAdd: Bool { !trimmedName.isEmpty && addProblem == nil }

  /// The rule that sbd also checks, shown before Add.
  private var addProblem: String? {
    guard !trimmedName.isEmpty, isOrg else { return nil }
    let blank = { (s: String) in s.trimmingCharacters(in: .whitespaces).isEmpty }
    return blank(label) && blank(person) ? IssueSource.orgNeedsFilter : nil
  }

  private func add() {
    adding = true
    sourceError = nil
    model.addIssueSources([trimmedName], label: label, person: person) { error in
      adding = false
      sourceError = error
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

  static func text(_ list: [String]) -> String { list.joined(separator: ", ") }

  /// The entries of a field that lists them separated by commas. A field that still shows the text of the list it
  /// loaded gives that list back, because an entry that config.json or `sb issues team` set can hold a comma.
  static func list(_ text: String, loaded: [String]?) -> [String] {
    if let loaded, text == Self.text(loaded) { return loaded }
    return text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
  }
}
