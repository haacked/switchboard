import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
