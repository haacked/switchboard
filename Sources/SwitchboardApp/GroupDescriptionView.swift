import SwiftUI
import SwitchboardCore

/// A group's description under its name on the Board. Clicking the text turns
/// it into a field. Return or a click elsewhere saves, and Escape cancels. A
/// group without a description shows a quiet prompt to add one.
struct GroupDescriptionView: View {
  @EnvironmentObject var model: BoardModel
  let group: GroupSummary
  @State private var editing = false
  @State private var draft = ""
  @FocusState private var focused: Bool

  var body: some View {
    if editing {
      TextField("Description", text: $draft, axis: .vertical)
        .lineLimit(1...5)
        .font(.caption)
        .textFieldStyle(.roundedBorder)
        .focused($focused)
        .onAppear { focused = true }
        // The key handler does not see keypad Enter, which saves here.
        .onSubmit(save)
        // A vertical field would otherwise insert a line break on Return. A description is one line, so every Return saves.
        .onKeyPress(.return) {
          // An input method that is composing text takes Return to confirm the composition.
          if TextInput.isComposing { return .ignored }
          save()
          return .handled
        }
        .onExitCommand { editing = false }
        .onChange(of: focused) { _, now in if !now && editing { save() } }
        .accessibilityLabel("Description of \(group.name)")
        .accessibilityIdentifier("group-description-field-\(group.id)")
    } else {
      Button {
        draft = group.description ?? ""
        editing = true
      } label: {
        Text(group.description ?? "Add a description")
          .font(.caption)
          .foregroundStyle(group.description == nil ? .tertiary : .secondary)
          .lineLimit(2)
          .multilineTextAlignment(.leading)
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help(group.description ?? "Describe what this group is for")
      .accessibilityLabel(group.description ?? "Add a description")
      .accessibilityHint("Edit description")
      .accessibilityIdentifier("group-description-\(group.id)")
    }
  }

  /// Text that the model refuses stays in the open field, so the user can shorten it.
  private func save() {
    if model.describeGroup(group.id, draft) { editing = false }
  }
}
