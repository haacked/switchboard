import AppKit
import ImageIO
import SwiftUI
import SwitchboardCore
import UniformTypeIdentifiers

/// A field that sends the session's Claude a message, with images dropped on it or pasted into it.
struct MessageField: View {
  /// What the field holds. MessageDrafts keeps one per target, so it outlives the view.
  final class Draft: ObservableObject {
    struct Image: Identifiable {
      var id = UUID()
      let name: String
      let data: Data
      let thumbnail: NSImage?
    }

    @Published var text = ""
    @Published var images: [Image] = []
    /// Why the last drop or paste left files out.
    @Published var error: String?
    /// The time of the first Esc. A second Esc within `escapeWindow` of it clears the draft.
    @Published private var armedAt: Date?
    var escapeHint: Bool { armedAt != nil }

    var isEmpty: Bool { trimmed.isEmpty && images.isEmpty }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Sends the trimmed text and the images, and empties the field once sbd accepts them, unless the user
    /// changed it meanwhile.
    @MainActor func submit(_ session: String, ref: String? = nil, to model: BoardModel) {
      guard !isEmpty else { return }
      let sent = trimmed
      let ids = images.map(\.id)
      model.send(session, sent, images: images.map { ($0.name, $0.data) }, ref: ref) { [weak self] in
        self?.clear(ifStill: sent, images: ids)
      }
    }

    /// Empties the text unless the user changed it after `sent` was sent, and removes the sent images.
    func clear(ifStill sent: String, images sentImages: [Image.ID] = []) {
      if trimmed == sent { text = "" }
      images.removeAll { sentImages.contains($0.id) }
      error = nil
    }

    /// Adds each image file in order, and sets `error` for each file that is not one.
    /// Returns the paths it left out.
    @discardableResult
    func add(paths: [String]) -> [String] {
      attach(
        paths.map { path in
          ((path as NSString).lastPathComponent, { try Attachments.read(path: path, remaining: $0) })
        }
      ).map { paths[$0] }
    }

    /// Adds each file in order while the message stays within `Attachments.checkMessage`. It leaves out a file
    /// that fails to read or would pass a limit, and `error` names that file. The files after it still attach.
    /// A file past the count limit is not read. A file larger than the room left under the total limit is not read.
    /// Returns the indexes of the files it left out.
    @discardableResult
    private func attach(_ files: [(name: String, read: (_ remaining: Int) throws -> Data)]) -> [Int] {
      var refused: [String] = []
      var overLimit: [(reason: String, names: [String])] = []
      var leftOut: [Int] = []
      func leaveOut(_ name: String, _ error: any Error) {
        let reason = "\(error)"
        if let i = overLimit.firstIndex(where: { $0.reason == reason }) {
          overLimit[i].names.append(name)
        } else {
          overLimit.append((reason, [name]))
        }
      }
      var total = images.reduce(0) { $0 + $1.data.count }
      for (index, file) in files.enumerated() {
        leftOut.append(index)
        do {
          try Attachments.checkMessage(count: images.count + 1, total: total)
        } catch {
          leaveOut(file.name, error)
          continue
        }
        let data: Data
        do {
          data = try file.read(Attachments.totalLimit - total)
        } catch let error as Attachments.OverTotalLimit {
          leaveOut(file.name, error)
          continue
        } catch {
          refused.append("\(error)")
          continue
        }
        do {
          try Attachments.checkMessage(count: images.count + 1, total: total + data.count)
        } catch {
          leaveOut(file.name, error)
          continue
        }
        leftOut.removeLast()
        append(name: file.name, data: data)
        total += data.count
      }
      for (reason, names) in overLimit {
        refused.append("\(names.joined(separator: ", ")) \(names.count == 1 ? "isn't" : "aren't") attached: \(reason)")
      }
      error = refused.isEmpty ? nil : refused.joined(separator: " ")
      return leftOut
    }

    /// Adds the pasteboard's images and returns true, or returns false and leaves the paste to the
    /// text field. It takes file URLs when every one names an image file, and the PNG or TIFF data of
    /// each item when no item has text.
    func paste(from pasteboard: NSPasteboard) -> Bool {
      let urls = pasteboard.fileURLs
      if !urls.isEmpty {
        guard urls.allSatisfy({ Attachments.extensions.contains($0.pathExtension.lowercased()) }) else {
          return false
        }
        add(paths: urls.map(\.path))
        return true
      }
      let items = pasteboard.pasteboardItems ?? []
      guard !items.contains(where: { $0.types.contains(.string) }) else { return false }
      let images = items.filter { $0.types.contains(.png) || $0.types.contains(.tiff) }
      guard !images.isEmpty else { return false }
      attach(images.map { item in (Self.pastedName, { _ in try Self.png(item) }) })
      return true
    }

    /// The item's PNG data, or its TIFF data converted to PNG.
    private static func png(_ item: NSPasteboardItem) throws -> Data {
      let png =
        item.data(forType: .png)
        ?? item.data(forType: .tiff).flatMap {
          NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:])
        } ?? Data()
      _ = try Attachments.validate(name: pastedName, data: png)
      return png
    }

    func remove(_ id: Image.ID) {
      images.removeAll { $0.id == id }
    }

    static let escapeWindow: TimeInterval = 1

    /// Handles an Esc and returns true when it cleared the draft. A first Esc on a draft with something in it
    /// only sets `escapeHint`. The field then handles the key as it would without a draft.
    func escape(at now: Date) -> Bool {
      guard !isEmpty else {
        disarmEscape()
        return false
      }
      if let armedAt, now.timeIntervalSince(armedAt) <= Self.escapeWindow {
        text = ""
        images = []
        error = nil
        disarmEscape()
        return true
      }
      armedAt = now
      DispatchQueue.main.asyncAfter(deadline: .now() + Self.escapeWindow) { [weak self] in
        if self?.armedAt == now { self?.disarmEscape() }
      }
      return false
    }

    /// Ends the window in which a second Esc clears the draft.
    func disarmEscape() {
      if armedAt != nil { armedAt = nil }
    }

    static let pastedName = "Pasted image.png"

    func append(id: UUID = UUID(), name: String, data: Data) {
      images.append(Image(id: id, name: name, data: data, thumbnail: Self.thumbnail(data)))
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
  /// From `BoardModel.messageDraft(for:)`, so that the text survives a switch to another view.
  @ObservedObject var draft: Draft
  var shortcut: KeyboardShortcut?
  /// The ref of the Inbox item that the field answers, so sbd can hold the session while it works on the
  /// message.
  var ref: String?
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

  private func send() { draft.submit(session, ref: ref, to: model) }

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

/// Takes files dropped anywhere on the message field. AppKit gives a drag to the frontmost view that registered
/// one of its types. SwiftUI does not keep this view's AppKit host in front of the text field's host. A text
/// field with focus edits through the window's field editor, which takes a file drop and inserts the first
/// file's path as text. So while that editor edits the field under this view, the editor takes no drags, and
/// this view inserts dropped text through the editor at the drop point. The editor registers its types again
/// on each edit, so the view removes them again after each SwiftUI update. Clicks pass through this view.
struct FileDropTarget: NSViewRepresentable {
  @Binding var isTargeted: Bool
  /// Attaches the files and returns the ones it left out.
  let drop: ([URL]) -> [URL]

  func makeNSView(context: Context) -> DropView { DropView() }

  func updateNSView(_ view: DropView, context: Context) {
    view.drop = drop
    view.targeted = { isTargeted = $0 }
    DispatchQueue.main.async { view.limitFieldEditor() }
  }

  static func dismantleNSView(_ view: DropView, coordinator: ()) { view.releaseFieldEditor() }

  final class DropView: NSView {
    var drop: ([URL]) -> [URL] = { _ in [] }
    var targeted: (Bool) -> Void = { _ in }
    /// AppKit's call that writes a promise's files into the folder and runs the reader once for each file, on the
    /// queue. AppKit allows it only during `performDragOperation` and the calls around it.
    var receiveFiles:
      (NSFilePromiseReceiver, URL, OperationQueue, @escaping @Sendable (URL, (any Error)?) -> Void) -> Void = {
        promise, folder, queue, reader in
        promise.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: queue, reader: reader)
      }
    /// Keeps a promised file that the draft left out. A promise can move its file, as the screenshot thumbnail
    /// does when it is dropped, so deleting it would lose the only copy.
    var keep: (URL) -> Void = { try? FileManager.default.trashItem(at: $0, resultingItemURL: nil) }

    /// Which drop view limited each field editor. Every text field in a window shares one field editor, so
    /// focus that moves between two message fields can reach the new field's view before the old one's.
    private static let limiters = NSMapTable<NSTextView, DropView>.weakToWeakObjects()
    private weak var limited: NSTextView?
    /// What the drag that is over the view would do, which `draggingEntered` decides once per drag.
    private var operation: NSDragOperation = []

    override init(frame: NSRect) {
      super.init(frame: frame)
      registerForDraggedTypes(
        [.fileURL, .string] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The window's field editor while it edits a text field under this view.
    private var fieldEditor: NSTextView? {
      guard let editor = window?.firstResponder as? NSTextView, editor.isFieldEditor,
        let field = editor.delegate as? NSView,
        convert(bounds, to: nil).intersects(field.convert(field.bounds, to: nil))
      else { return nil }
      return editor
    }

    /// Takes every drag from the window's field editor while it edits a text field under this view, and
    /// gives back the editor's own types once it edits another field or none.
    func limitFieldEditor() {
      guard let editor = fieldEditor else { return releaseFieldEditor() }
      limit(editor)
    }

    func limit(_ editor: NSTextView) {
      if limited === editor, editor.registeredDraggedTypes.isEmpty { return }
      if limited !== editor { releaseFieldEditor() }
      editor.unregisterDraggedTypes()
      limited = editor
      Self.limiters.setObject(self, forKey: editor)
    }

    func releaseFieldEditor() {
      guard let editor = limited else { return }
      limited = nil
      guard Self.limiters.object(forKey: editor) === self else { return }
      Self.limiters.removeObject(forKey: editor)
      editor.updateDragTypeRegistration()
    }

    /// Files and promised files become images. Text goes into the field when the field has focus, as the editor
    /// would insert it.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
      let pasteboard = sender.draggingPasteboard
      let files = !pasteboard.fileURLs.isEmpty || !Self.imagePromises(pasteboard).isEmpty
      operation = files || (fieldEditor != nil && pasteboard.string(forType: .string) != nil) ? .copy : []
      targeted(files)
      return operation
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { operation }

    override func draggingExited(_ sender: NSDraggingInfo?) { targeted(false) }

    override func draggingEnded(_ sender: NSDraggingInfo) { targeted(false) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
      targeted(false)
      let pasteboard = sender.draggingPasteboard
      let urls = pasteboard.fileURLs
      if !urls.isEmpty {
        _ = drop(urls)
        return true
      }
      let promises = Self.imagePromises(pasteboard)
      if !promises.isEmpty {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("switchboard-drop-\(UUID())")
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil
        else { return false }
        receive(promises, into: folder) { [drop, keep] urls in
          for url in drop(urls) where FileManager.default.fileExists(atPath: url.path) { keep(url) }
          try? FileManager.default.removeItem(at: folder)
        }
        return true
      }
      guard let editor = fieldEditor, let text = pasteboard.string(forType: .string) else { return false }
      let index = editor.characterIndexForInsertion(at: editor.convert(sender.draggingLocation, from: nil))
      var location = min(index, (editor.string as NSString).length)
      if sender.draggingSource as AnyObject? === editor {
        // The editor takes no drags, so it never deletes the text it dragged.
        // A drop inside the dragged text changes nothing.
        let moved = editor.selectedRange()
        if moved.length > 0 {
          guard location <= moved.location || location >= NSMaxRange(moved) else { return true }
          editor.insertText("", replacementRange: moved)
          if location > moved.location { location -= moved.length }
        }
      }
      let at = NSRange(location: location, length: 0)
      editor.setSelectedRange(at)
      editor.insertText(text, replacementRange: at)
      return true
    }

    /// The drag's promises, when every file that they promise is an image. A drag that also promises another kind
    /// of file, such as a screen recording, is left to the text path or refused.
    static func imagePromises(_ pasteboard: NSPasteboard) -> [NSFilePromiseReceiver] {
      let promises = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver] ?? []
      let images = promises.allSatisfy { promise in
        !promise.fileTypes.isEmpty && promise.fileTypes.allSatisfy { UTType($0)?.conforms(to: .image) == true }
      }
      return images ? promises : []
    }

    /// Receives the promised files into the folder and calls `done` on the main queue with their URLs, in the order
    /// of the promises. Each promise writes one file per promised type. The reader of a failed promise deletes any
    /// part of the file that it wrote, so `drop` reports the file as missing.
    private func receive(
      _ promises: [NSFilePromiseReceiver], into folder: URL, then done: @escaping @MainActor ([URL]) -> Void
    ) {
      let received = Received(expected: promises.map(\.fileTypes.count))
      let group = DispatchGroup()
      let queue = OperationQueue()
      for (index, promise) in promises.enumerated() {
        for _ in promise.fileTypes { group.enter() }
        receiveFiles(promise, folder, queue) { url, error in
          if error != nil { try? FileManager.default.removeItem(at: url) }
          if received.add(url, at: index) { group.leave() }
        }
      }
      group.notify(queue: .main) { MainActor.assumeIsolated { done(received.urls) } }
    }

    /// The files that each promise wrote, which the readers add from the operation queue's threads.
    private final class Received: @unchecked Sendable {
      private let lock = NSLock()
      private let expected: [Int]
      private var files: [[URL]]

      init(expected: [Int]) {
        self.expected = expected
        files = Array(repeating: [], count: expected.count)
      }

      /// Adds the file and returns true, or returns false for a file beyond the count that the promise named.
      func add(_ url: URL, at index: Int) -> Bool {
        lock.withLock {
          guard files[index].count < expected[index] else { return false }
          files[index].append(url)
          return true
        }
      }

      var urls: [URL] { lock.withLock { files.flatMap { $0 } } }
    }
  }
}

extension NSPasteboard {
  /// The file URLs on the pasteboard, in the order of its items.
  var fileURLs: [URL] {
    readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
  }
}
