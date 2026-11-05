import AppKit
import ImageIO
import SwiftUI
import SwitchboardCore
import UniformTypeIdentifiers

/// A field that sends the session's Claude a message, with images dropped on it or pasted into it.
struct MessageField: View {
  /// See SessionViewState for why this isn't `@State`.
  final class Draft: ObservableObject {
    struct Image: Identifiable {
      let id = UUID()
      let name: String
      let data: Data
      let thumbnail: NSImage?
    }

    @Published var text = ""
    @Published var images: [Image] = []
    /// Why the last dropped or pasted file was not added.
    @Published var error: String?
    /// Whether the text field has focus, which decides whether Command+V reaches `paste`.
    var focused = false

    var isEmpty: Bool { trimmed.isEmpty && images.isEmpty }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Sends the trimmed text and the images, and empties the field once sbd accepts them, unless the user
    /// changed it meanwhile.
    @MainActor func submit(_ session: String, to model: BoardModel) {
      guard !isEmpty else { return }
      let sent = trimmed
      let ids = images.map(\.id)
      model.send(session, sent, images: images.map { ($0.name, $0.data) }) { [weak self] in
        self?.clear(ifStill: sent, images: ids)
      }
    }

    /// Empties the text unless the user changed it after `sent` was sent, and removes the sent images.
    func clear(ifStill sent: String, images sentImages: [Image.ID] = []) {
      if trimmed == sent { text = "" }
      images.removeAll { sentImages.contains($0.id) }
      error = nil
    }

    /// Adds each image file, and sets `error` for each file that is not one.
    func add(paths: [String]) {
      var refused: [String] = []
      for path in paths {
        do {
          let data = try Attachments.read(path: path)
          append(name: (path as NSString).lastPathComponent, data: data)
        } catch {
          refused.append("\(error)")
        }
      }
      error = refused.isEmpty ? nil : refused.joined(separator: " ")
    }

    /// Adds the pasteboard's images and returns true, or returns false and leaves the paste to the
    /// text field. It takes file URLs when every one names an image file, and PNG or TIFF data when
    /// the pasteboard has no text.
    func paste(from pasteboard: NSPasteboard) -> Bool {
      let urls =
        pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
      if !urls.isEmpty {
        guard urls.allSatisfy({ Attachments.extensions.contains($0.pathExtension.lowercased()) }) else {
          return false
        }
        add(paths: urls.map(\.path))
        return true
      }
      guard pasteboard.string(forType: .string) == nil else { return false }
      if let png = pasteboard.data(forType: .png) {
        append(name: Self.pastedName, data: png)
      } else if let tiff = pasteboard.data(forType: .tiff),
        let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
      {
        append(name: Self.pastedName, data: png)
      } else {
        return false
      }
      error = nil
      return true
    }

    func remove(_ id: Image.ID) {
      images.removeAll { $0.id == id }
    }

    static let pastedName = "Pasted image.png"

    private func append(name: String, data: Data) {
      images.append(Image(name: name, data: data, thumbnail: Self.thumbnail(data)))
    }

    /// A small decoded copy, so that a chip does not keep the full image's bitmap.
    private static func thumbnail(_ data: Data) -> NSImage? {
      let options =
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 56,
          kCGImageSourceCreateThumbnailWithTransform: true,
        ] as CFDictionary
      guard let source = CGImageSourceCreateWithData(data as CFData, nil),
        let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options)
      else { return nil }
      return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
  }

  @EnvironmentObject var model: BoardModel
  let session: String
  var shortcut: KeyboardShortcut?
  @StateObject private var draft = Draft()
  @FocusState private var focused: Bool
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
    .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
      Task { @MainActor in draft.add(paths: await Self.paths(providers)) }
      return true
    }
    .onAppear { pasteMonitor = Self.monitorPaste(into: draft) }
    .onDisappear {
      pasteMonitor.map(NSEvent.removeMonitor)
      pasteMonitor = nil
    }
  }

  private var field: some View {
    TextField("Message Claude…", text: $draft.text, axis: .vertical)
      .lineLimit(1...4)
      .textFieldStyle(.roundedBorder)
      .focused($focused)
      .onChange(of: focused) { draft.focused = focused }
      .overlay {
        if dropTargeted {
          RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 2)
        }
      }
      // The key handler does not see keypad Enter, which sends here. An input method that passes Return on after composing also sends here.
      .onSubmit(send)
      // The handler also takes key repeats. A held Shift+Return would otherwise reach onSubmit and send.
      .onKeyPress(.return, phases: [.down, .repeat]) { press in
        // SwiftUI calls this before the input method sees the key. The check for marked text has to happen here.
        let editor = NSApp.keyWindow?.firstResponder as? NSTextView
        switch Self.keyAction(modifiers: press.modifiers, composing: editor?.hasMarkedText() == true) {
        case .send:
          send()
        case .newline:
          editor?.insertNewlineIgnoringFieldEditor(nil)
        case nil:
          return .ignored
        }
        return .handled
      }
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

  /// The file paths that dropped items name.
  private static func paths(_ providers: [NSItemProvider]) async -> [String] {
    var paths: [String] = []
    for provider in providers {
      if let url = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data,
        let path = URL(dataRepresentation: url, relativeTo: nil)?.path
      {
        paths.append(path)
      }
    }
    return paths
  }

  /// Watches for Command+V while the field has focus. The menu's Paste item takes the key before the
  /// field sees it, and the field editor ignores image data. A local monitor sees the key first.
  private static func monitorPaste(into draft: Draft) -> Any? {
    NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak draft] event in
      guard let draft, draft.focused,
        event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
        event.charactersIgnoringModifiers == "v",
        draft.paste(from: .general)
      else { return event }
      return nil
    }
  }

  enum KeyAction { case send, newline }

  /// What Return does in the field. Nil leaves the key to the field. On Return while composing, the
  /// field confirms the input method's marked text. On Option+Return, it inserts a new line.
  /// Command+Return reaches the Send button's shortcut.
  static func keyAction(modifiers: EventModifiers, composing: Bool) -> KeyAction? {
    guard !composing else { return nil }
    switch modifiers.intersection([.shift, .command, .option, .control]) {
    case []: return .send
    case .shift: return .newline
    default: return nil
    }
  }
}
