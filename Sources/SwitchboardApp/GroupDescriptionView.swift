import SwiftUI
import SwitchboardCore

/// A group's description under its name on the Board. Clicking the text turns
/// it into a field. Return or a click elsewhere saves, and Escape cancels. A
/// group without a description shows a quiet prompt to add one. A description
/// that Claude wrote says so and offers Accept.
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
      VStack(alignment: .leading, spacing: 2) {
        descriptionButton
        if group.descriptionBy == .claude, group.description != nil { claudeWrote }
      }
    }
  }

  private var descriptionButton: some View {
    Button {
      draft = group.description ?? ""
      editing = true
    } label: {
      InlineText(plain: group.description ?? "Add a description", links: false)
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

  /// Marks a description that Claude wrote. Accept makes it the user's. An edit that changes the text makes it the
  /// user's too, but a click that leaves the text as it was does not.
  private var claudeWrote: some View {
    HStack(spacing: 4) {
      Text("Written by Claude").foregroundStyle(.secondary)
      Button("Accept") { model.acceptGroupDescription(group.id) }
        .buttonStyle(.link)
        .help("Mark this description as yours")
        .accessibilityLabel("Accept the description of \(group.name)")
        .accessibilityIdentifier("group-description-accept-\(group.id)")
        .clickAnchor("group-description-accept-\(group.id)")
    }
    .font(.caption2)
    .lineLimit(1)
  }

  /// Text that the model refuses stays in the open field, so the user can shorten it.
  private func save() {
    if model.describeGroup(group.id, draft) { editing = false }
  }
}
