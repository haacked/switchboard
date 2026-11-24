import SwiftUI
import SwitchboardCore

/// The known repositories that are not issue sources yet, each with a checkbox, an optional label for all of
/// them, and one button that adds the checked ones as sources. The Issues view's empty state and Settings ▸ Issues
/// show it while `offeredIssueRepos` is not empty.
struct IssueRepoOffer: View {
  @EnvironmentObject var model: BoardModel
  /// The names the user unchecked. A repository that loads after the view appears starts checked. The empty state
  /// and Settings ▸ Issues share one set, so the pane opened from the empty state keeps the user's choices.
  @Binding var unchecked: Set<String>
  /// Gets whether the label field has focus. Add takes Return while it does, so Settings ▸ Issues' other buttons give
  /// Return up then.
  var labelFocusChanged: (Bool) -> Void = { _ in }
  @FocusState private var labelFocused: Bool
  @State private var label = ""
  @State private var adding = false
  @State private var addError: String?

  var body: some View {
    let offered = model.offeredIssueRepos
    let checked = offered.filter { !unchecked.contains($0) }
    VStack(alignment: .leading, spacing: 8) {
      ScrollView {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(offered, id: \.self) { name in
            Toggle(name, isOn: isChecked(name)).toggleStyle(.checkbox)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      // The list grows with its rows up to about eight, then scrolls.
      .frame(height: CGFloat(min(offered.count, 8)) * 22)
      .scrollBounceBehavior(.basedOnSize)
      HStack {
        TextField("Label", text: $label, prompt: Text("Label (optional)"))
          .focused($labelFocused)
          .help(
            "Fetches only the issues with this label in each checked repository. Without one, a repository gives up to 1,000 open issues."
          )
        Button(checked.count == 1 ? "Add 1 Repository" : "Add \(checked.count) Repositories") { add(checked) }
          .disabled(checked.isEmpty || adding)
          .keyboardShortcut(labelFocused ? .defaultAction : nil)
      }
      RefusalLabel(refusal: addError)
    }
    .announcesRefusal(addError)
    .onChange(of: labelFocused) { labelFocusChanged(labelFocused) }
    // Settings ▸ Issues removes the offer once every repository is a source. The removed view's onChange never
    // reports the lost focus, and the pane's Add and Save buttons would not take Return.
    .onDisappear { labelFocusChanged(false) }
  }

  private func isChecked(_ name: String) -> Binding<Bool> {
    Binding(
      get: { !unchecked.contains(name) },
      set: { if $0 { unchecked.remove(name) } else { unchecked.insert(name) } })
  }

  private func add(_ names: [String]) {
    adding = true
    addError = nil
    model.addIssueSources(names, label: label, person: "") { error in
      adding = false
      addError = error
      if error == nil { label = "" }
    }
  }
}
