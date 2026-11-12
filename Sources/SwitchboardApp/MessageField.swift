import AppKit
import SwiftUI

/// A field that sends the session's Claude a message, with images dropped on it or pasted into it.
struct MessageField: View {
  @EnvironmentObject var model: BoardModel
  let session: String
  /// From `BoardModel.messageDraft(for:)`, so that the text survives a switch to another view.
  @ObservedObject var draft: Draft
  var shortcut: KeyboardShortcut?
  @FocusState private var focused: Bool
  /// The paste monitor reads this view's focus here. The draft can't hold it, because several views share one draft.
  @State private var focus = Focus()
  @State private var dropTargeted = false
  @State private var pasteMonitor: Any?

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      if !draft.images.isEmpty {
        ScrollView(.horizontal) {
          HStack(spacing: 6) {
            ForEach(draft.images) { chip($0) }
          }
        }
      }
      HStack {
        field
        Button("Send", action: send)
          .keyboardShortcut(shortcut)
          .disabled(model.sending.contains(session) || draft.isEmpty)
      }
      if let error = draft.error {
        Text(error).font(.caption).foregroundStyle(.red)
      }
    }
    .overlay {
      FileDropTarget(isTargeted: $dropTargeted) { urls in
        draft.add(paths: urls.map(\.path)).map { URL(fileURLWithPath: $0) }
      }
    }
    // A refused paste or drop changes neither the text nor the chips, so VoiceOver would say nothing.
    .onChange(of: draft.error) {
      if let error = draft.error { AccessibilityNotification.Announcement(error).post() }
    }
    .onChange(of: draft.escapeHint) {
      if draft.escapeHint { AccessibilityNotification.Announcement("Press Escape again to clear").post() }
    }
    .onAppear { pasteMonitor = Self.monitorPaste(into: draft, when: focus) }
    .onDisappear {
      pasteMonitor.map(NSEvent.removeMonitor)
      pasteMonitor = nil
    }
  }

  private var field: some View {
    TextField("Message Claude…", text: $draft.text, axis: .vertical)
      .textFieldStyle(.roundedBorder)
      .focused($focused)
      .onChange(of: focused) { focus.held = focused }
      // An input method that composes takes Esc to cancel the composition.
      .onKeyPress(phases: .down) { press in
        guard press.key == .escape else {
          draft.disarmEscape()
          return .ignored
        }
        return !TextInput.isComposing && draft.escape(at: Date()) ? .handled : .ignored
      }
      .overlay {
        if dropTargeted {
          RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 2)
        }
      }
      // The hint sits inside the field, because a row below it would resize the terminals above.
      .overlay(alignment: .trailing) {
        if draft.escapeHint {
          Text("Press Esc again to clear").font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 6).background(.background).padding(.trailing, 4).allowsHitTesting(false)
        }
      }
      .sendsOnReturn(send)
  }

  private func chip(_ image: Draft.Image) -> some View {
    HStack(spacing: 4) {
      if let thumbnail = image.thumbnail {
        SwiftUI.Image(nsImage: thumbnail).resizable().scaledToFill().frame(width: 28, height: 28)
          .clipShape(RoundedRectangle(cornerRadius: 4))
      }
      Text(image.name).font(.caption).lineLimit(1).truncationMode(.middle).frame(maxWidth: 120)
      Button {
        draft.remove(image.id)
      } label: {
        SwiftUI.Image(systemName: "xmark.circle.fill")
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .help("Remove \(image.name)")
    }
    .padding(4)
    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Self.chipLabel(image.name))
    .accessibilityAddTraits(.isButton)
    .accessibilityAction { draft.remove(image.id) }
  }

  private func send() { draft.submit(session, to: model) }

  /// The chip's VoiceOver label. Activating the chip removes the image.
  static func chipLabel(_ name: String) -> String { "Image: \(name), remove" }

  /// Watches for Command+V while the field has focus. The menu's Paste item takes the key before the
  /// field sees it, and the field editor ignores image data. A local monitor sees the key first.
  private static func monitorPaste(into draft: Draft, when focus: Focus) -> Any? {
    NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak draft] event in
      guard let draft, focus.held,
        event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
        event.charactersIgnoringModifiers == "v",
        draft.paste(from: .general)
      else { return event }
      return nil
    }
  }

  final class Focus { var held = false }
}
