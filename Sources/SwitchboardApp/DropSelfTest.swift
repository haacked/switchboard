import AppKit
import SwitchboardCore
import UniformTypeIdentifiers

/// A scripted check of drops and pastes on the message field, run by `bin/test-gui`. SB_DROP_TEST=<folder>
/// writes image files, a text file, and a folder there. It then drops sets of them on the message field of
/// the session that SB_SELECT selected (or SB_INBOX focused), first without focus and then with it. A script
/// cannot move the mouse without the Accessibility permission. So each drop calls the drag-destination
/// methods of the view that AppKit's own drag hit test picks under the field's center, with a pasteboard of
/// its own. Each step logs the draft's chips, error, and text to standard error. The last step clicks Send,
/// and the app quits at the end.
@MainActor
enum DropSelfTest {
  static func start(_ model: BoardModel) {
    let env = ProcessInfo.processInfo.environment
    guard let folder = env["SB_DROP_TEST"], let session = env["SB_SELECT"] ?? env["SB_INBOX"] else { return }
    Task { @MainActor in
      if let field = await DraftSelfTest.waitForField(model, session, select: env["SB_INBOX"] == nil),
        let draft = DraftSelfTest.draft(model, session)
      {
        do {
          try await run(field, draft, folder: folder)
        } catch {
          log("error: \(error)")
        }
      }
      log("done")
      NSApp.terminate(nil)
    }
  }

  private static func run(_ field: NSTextField, _ draft: MessageField.Draft, folder: String) async throws {
    let numbered = (1...(Attachments.countLimit + 2)).map { String(format: "n%02d.png", $0) }
    for name in ["a.png", "b.jpg", "c.gif", "d.png", "e.png"] + numbered {
      try png.write(to: URL(fileURLWithPath: "\(folder)/\(name)"))
    }
    try Data("just some text".utf8).write(to: URL(fileURLWithPath: "\(folder)/notes.txt"))
    try FileManager.default.createDirectory(atPath: "\(folder)/shots", withIntermediateDirectories: true)
    let files = { (names: [String]) in pasteboard(names.map { URL(fileURLWithPath: "\(folder)/\($0)") as NSURL }) }

    func step(_ name: String, typed: String = "", _ drags: [NSPasteboard]) async {
      draft.text = typed
      draft.images = []
      draft.error = nil
      await pause()
      var targets: [String] = []
      for board in drags {
        targets.append(drop(board, on: field))
        await pause()
      }
      log(
        "\(name): targets \(targets.joined(separator: " ")) | chips \(chips(draft)) | error \(draft.error ?? "")"
          + " | text \(field.stringValue)")
    }

    await step("two", [files(["a.png", "b.jpg"])])
    await step("three", [files(["a.png", "b.jpg", "c.gif"])])
    await step("five", [files(["e.png", "a.png", "d.png", "b.jpg", "c.gif"])])
    await step("two drags", [files(["a.png"]), files(["b.jpg", "c.gif"])])
    await step("mixed", [files(["a.png", "notes.txt", "b.jpg"])])
    await step("folder", [files(["a.png", "shots"])])
    await step("over the count limit", [files(numbered)])

    field.window?.makeFirstResponder(nil)
    await pause()
    click(at: field)
    await pause()
    log("a click focuses the field: \(field.currentEditor() != nil)")
    let editor = field.currentEditor() as? NSTextView
    let typesLog = { (when: String) in
      log(
        "editor types \(when): \((editor?.registeredDraggedTypes ?? []).map(\.rawValue).sorted().joined(separator: " "))"
      )
    }
    typesLog("after a click")
    for character in "typed" {
      editor?.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
      await pause()
    }
    typesLog("after typing")
    draft.text = "set by code"
    await pause()
    typesLog("after the draft changed")
    let other = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
    other.isReleasedWhenClosed = false
    other.makeKeyAndOrderFront(nil)
    await pause()
    field.window?.makeKeyAndOrderFront(nil)
    other.close()
    await pause()
    typesLog("after another window was key")
    await step("focused one", [files(["a.png"])])
    await step("focused two", [files(["a.png", "b.jpg"])])
    await step("typed then three", typed: "look at these", [files(["a.png", "b.jpg", "c.gif"])])
    await step("focused two drags", [files(["a.png"]), files(["b.jpg", "c.gif"])])
    await step("file with its text", [fileWithText("\(folder)/a.png")])
    await step("text drag", typed: "look ", [pasteboard(["at this" as NSString])])
    await step("link drag", typed: "see ", [link("https://example.com/a.png")])

    field.window?.makeFirstResponder(nil)
    await pause()
    typesLog("after focus left")
    field.window?.makeFirstResponder(field)
    await pause()

    draft.images = []
    let items = (0..<3).map { _ in
      let item = NSPasteboardItem()
      item.setData(png, forType: .png)
      return item
    }
    log("paste of three handled \(draft.paste(from: pasteboard(items))) | chips \(chips(draft))")

    draft.images = []
    draft.add(paths: ["\(folder)/a.png"])
    await pause()
    let oneChip = field.convert(field.bounds, to: nil).minY
    draft.add(paths: numbered.prefix(Attachments.countLimit - 1).map { "\(folder)/\($0)" })
    await pause()
    log("field moved with \(draft.images.count) chips: \(field.convert(field.bounds, to: nil).minY - oneChip)")
    Snapshot.write(to: "\(folder)/chips.png")

    await step("remove setup", [files(["a.png", "b.jpg", "c.gif"])])
    if let middle = draft.images.first(where: { $0.name == "b.jpg" }) { draft.remove(middle.id) }
    log("after removing b.jpg: chips \(chips(draft))")

    await step("send", typed: "look at these", [files(["a.png", "b.jpg", "c.gif"])])
    // The Send button follows the field in an HStack with the default spacing of 8 points.
    let frame = field.convert(field.bounds, to: nil)
    if let window = field.window { click(at: NSPoint(x: frame.maxX + 28, y: frame.midY), in: window) }
    for _ in 0..<100 where !draft.images.isEmpty { try? await Task.sleep(for: .seconds(0.1)) }
    log("after send: chips \(chips(draft)) | text \(draft.text)")
  }

  /// Sends a left click at the view's center through its window, as a click of the mouse arrives.
  private static func click(at view: NSView) {
    guard let window = view.window else { return }
    click(at: view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil), in: window)
  }

  private static func click(at point: NSPoint, in window: NSWindow) {
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
      guard
        let event = NSEvent.mouseEvent(
          with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
      else { continue }
      window.sendEvent(event)
    }
  }

  private static func chips(_ draft: MessageField.Draft) -> String { draft.images.map(\.name).joined(separator: " ") }

  private static func pasteboard(_ objects: [NSPasteboardWriting]) -> NSPasteboard {
    let board = NSPasteboard(name: NSPasteboard.Name("droptest-\(UUID().uuidString)"))
    board.clearContents()
    board.writeObjects(objects)
    return board
  }

  /// A file dragged from an app that also puts the file's path on the pasteboard as text.
  private static func fileWithText(_ path: String) -> NSPasteboard {
    let item = NSPasteboardItem()
    item.setString(URL(fileURLWithPath: path).absoluteString, forType: .fileURL)
    item.setString(path, forType: .string)
    return pasteboard([item])
  }

  /// A link dragged from a browser: its URL, and its text.
  private static func link(_ string: String) -> NSPasteboard {
    let item = NSPasteboardItem()
    item.setString(string, forType: .URL)
    item.setString(string, forType: .string)
    return pasteboard([item])
  }

  /// Drops the pasteboard on the view that AppKit picks under the field's center, and returns that view's
  /// class, with "-refused" when the view refused the drop.
  private static func drop(_ board: NSPasteboard, on field: NSTextField) -> String {
    guard let window = field.window, let frame = window.contentView?.superview else { return "<no window>" }
    let point = field.convert(NSPoint(x: field.bounds.midX, y: field.bounds.midY), to: nil)
    guard let target = appKitDestination(in: frame, at: point, for: board) else { return "<none>" }
    let info = DraggingInfo(window: window, location: point, pasteboard: board)
    let name = "\(type(of: target))"
    guard !target.draggingEntered(info).isEmpty, !target.draggingUpdated(info).isEmpty,
      target.prepareForDragOperation(info), target.performDragOperation(info)
    else { return "\(name)-refused" }
    target.concludeDragOperation(info)
    target.draggingEnded(info)
    return name
  }

  /// The view that AppKit's drag hit test picks: NSView's private `_hitTest:dragTypes:`, which takes a
  /// pointer to the point in window coordinates. A real drag also offers the types that the pasteboard's
  /// types conform to, so a view that registers public.item, as SwiftUI's onDrop does, matches a file.
  private static func appKitDestination(in frame: NSView, at point: NSPoint, for board: NSPasteboard) -> NSView? {
    let selector = NSSelectorFromString("_hitTest:dragTypes:")
    guard frame.responds(to: selector) else {
      log("error: AppKit has no _hitTest:dragTypes:")
      return nil
    }
    typealias HitTest = @convention(c) (NSView, Selector, UnsafeMutablePointer<NSPoint>, NSSet) -> NSView?
    let hitTest = unsafeBitCast(frame.method(for: selector), to: HitTest.self)
    var point = point
    let types = (board.types ?? []).map(\.rawValue)
    let supertypes = types.compactMap { UTType($0) }.flatMap { $0.supertypes.map(\.identifier) }
    return hitTest(frame, selector, &point, NSSet(array: types + supertypes))
  }

  private static func pause() async { try? await Task.sleep(for: .seconds(0.3)) }

  private static func log(_ text: String) { FileHandle.standardError.write(Data("droptest: \(text)\n".utf8)) }

  /// A valid 1×1 PNG.
  static let png = Data([
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00,
    0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00, 0x0A, 0x49,
    0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00, 0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00,
    0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
  ])

  /// A drag from another app when `source` is nil.
  final class DraggingInfo: NSObject, NSDraggingInfo {
    let window: NSWindow?
    let location: NSPoint
    let pasteboard: NSPasteboard
    let source: Any?

    init(window: NSWindow?, location: NSPoint, pasteboard: NSPasteboard, source: Any? = nil) {
      self.source = source
      self.window = window
      self.location = location
      self.pasteboard = pasteboard
    }

    var draggingDestinationWindow: NSWindow? { window }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { location }
    var draggedImageLocation: NSPoint { location }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { pasteboard }
    var draggingSource: Any? { source }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    func enumerateDraggingItems(
      options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass],
      searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
      using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {
      let objects = pasteboard.readObjects(forClasses: classArray, options: searchOptions) ?? []
      var stop: ObjCBool = false
      for (index, object) in objects.enumerated() {
        guard let writer = object as? NSPasteboardWriting else { continue }
        block(NSDraggingItem(pasteboardWriter: writer), index, &stop)
        if stop.boolValue { break }
      }
    }
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
  }
}
