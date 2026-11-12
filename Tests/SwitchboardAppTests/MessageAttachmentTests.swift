import AppKit
import SwitchboardCore
import Testing

@testable import SwitchboardApp

@MainActor
@Suite final class MessageAttachmentTests {
  static let png = DropSelfTest.png

  let folder: String

  init() throws {
    folder = "\(NSTemporaryDirectory())message-attachments-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
  }

  deinit { try? FileManager.default.removeItem(atPath: folder) }

  /// Writes the data, or a 1×1 PNG when there is none, to a file in the test's folder and returns its path.
  func file(_ name: String, _ data: Data? = nil) throws -> String {
    let path = "\(folder)/\(name)"
    try (data ?? Self.png).write(to: URL(fileURLWithPath: path))
    return path
  }

  /// A pasteboard of its own, so a test never reads or changes the user's clipboard.
  func pasteboard() -> NSPasteboard {
    let board = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
    board.clearContents()
    return board
  }

  // MARK: add(paths:)

  @Test func addAttachesAnImageFile() throws {
    let draft = MessageField.Draft()
    let path = try file("shot.png")

    draft.add(paths: [path])

    #expect(draft.images.map(\.name) == ["shot.png"])
    #expect(draft.images.first?.data == Self.png)
    #expect(draft.error == nil)
  }

  @Test func addRefusesATextFileNamedPNG() throws {
    let draft = MessageField.Draft()
    let path = try file("notes.png", Data("just some text".utf8))

    draft.add(paths: [path])

    #expect(draft.images.isEmpty)
    #expect(draft.error?.contains("notes.png isn't an image.") == true)
  }

  @Test func addRefusesASymlink() throws {
    let draft = MessageField.Draft()
    let real = try file("shot.png")
    let link = "\(folder)/link.png"
    try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)

    draft.add(paths: [link])

    #expect(draft.images.isEmpty)
    #expect(draft.error != nil)
  }

  @Test func addKeepsTheGoodImagesWhenOneIsRefused() throws {
    let draft = MessageField.Draft()
    let good = try file("shot.png")
    let bad = try file("notes.png", Data("just some text".utf8))

    draft.add(paths: [bad, good])

    #expect(draft.images.map(\.name) == ["shot.png"])
    #expect(draft.error != nil)
  }

  @Test func addAppendsToTheImagesAlreadyAttached() throws {
    let draft = MessageField.Draft()
    draft.add(paths: [try file("a.png")])

    draft.add(paths: [try file("b.png")])

    #expect(draft.images.map(\.name) == ["a.png", "b.png"])
    #expect(Set(draft.images.map(\.id)).count == 2)
  }

  @Test func addReturnsThePathsItLeftOut() throws {
    let draft = MessageField.Draft()
    let notes = try file("notes.png", Data("just some text".utf8))
    let shot = try file("shot.png")

    #expect(draft.add(paths: [notes, shot]) == [notes])
  }

  @Test func addKeepsTheOrderOfTheDrop() throws {
    let draft = MessageField.Draft()
    let names = ["e.png", "a.png", "d.jpg", "b.gif", "c.webp"]

    draft.add(paths: try names.map { try file($0) })

    #expect(draft.images.map(\.name) == names)
    #expect(draft.error == nil)
  }

  @Test func addRefusesAFolderAndKeepsTheImagesAroundIt() throws {
    let draft = MessageField.Draft()
    let a = try file("a.png")
    let folder = "\(self.folder)/shots"
    try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    let b = try file("b.png")

    draft.add(paths: [a, folder, b])

    #expect(draft.images.map(\.name) == ["a.png", "b.png"])
    #expect(draft.error == "shots isn't an image.")
  }

  @Test func addAttachesUpToTheCountLimitAndNamesTheRest() throws {
    let draft = MessageField.Draft()
    for n in 0..<(Attachments.countLimit - 2) { draft.append(name: "old\(n).png", data: Self.png) }

    draft.add(
      paths: try ["a.png", "notes.png", "b.png", "c.png", "d.png"].map { name in
        try name == "notes.png" ? file(name, Data("just some text".utf8)) : file(name)
      })

    #expect(draft.images.count == Attachments.countLimit)
    #expect(draft.images.suffix(2).map(\.name) == ["a.png", "b.png"])
    #expect(
      draft.error == "notes.png isn't an image. c.png, d.png aren't attached: a message can carry at most 20 images.")
  }

  @Test func addRefusesAnImageThatWouldPassTheTotalLimit() throws {
    let draft = MessageField.Draft()
    let big = Self.png + Data(count: Attachments.limit - Self.png.count)
    for n in 0..<(Attachments.totalLimit / Attachments.limit) { draft.append(name: "big\(n).png", data: big) }

    draft.add(paths: [try file("a.png")])

    #expect(draft.images.count == Attachments.totalLimit / Attachments.limit)
    #expect(draft.error == "a.png isn't attached: a message's images can total at most 100 MB.")
  }

  @Test func aLaterAddClearsTheLastRefusal() throws {
    let draft = MessageField.Draft()
    draft.add(paths: [try file("notes.png", Data("just some text".utf8))])

    draft.add(paths: [try file("a.png")])

    #expect(draft.error == nil)
  }

  // MARK: FileDropTarget.DropView

  func drag(_ objects: [NSPasteboardWriting]) -> DropSelfTest.DraggingInfo {
    let board = pasteboard()
    board.writeObjects(objects)
    return DropSelfTest.DraggingInfo(window: nil, location: .zero, pasteboard: board)
  }

  @Test func dropViewRegistersFileURLsTextAndFilePromises() {
    let promises = NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }

    #expect(Set(FileDropTarget.DropView().registeredDraggedTypes) == Set([.fileURL, .string] + promises))
  }

  /// A provider's delegate, which names the promised file. AppKit asks it to write the file only during a real drag.
  final class Promise: NSObject, NSFilePromiseProviderDelegate {
    let name: String
    init(_ name: String) { self.name = name }
    func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String { name }
    func filePromiseProvider(
      _ provider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void
    ) { completionHandler(nil) }
  }

  /// Stands in for AppKit's receive call. It records each promise's folder and reader, in the order that the view
  /// asked, so that a test can write the files and run the readers later and in any order.
  final class Source: @unchecked Sendable {
    var calls: [(folder: URL, reader: @Sendable (URL, (any Error)?) -> Void)] = []

    @MainActor init(_ view: FileDropTarget.DropView) {
      view.receiveFiles = { [unowned self] _, folder, _, reader in calls.append((folder, reader)) }
    }

    /// Writes the promise's file, if `data` is set, and runs its reader from another thread.
    func fulfill(_ index: Int, _ name: String, _ data: Data?, error: (any Error)? = nil) {
      let call = calls[index]
      let url = call.folder.appendingPathComponent(name)
      if let data { try? data.write(to: url) }
      DispatchQueue.global().sync { call.reader(url, error) }
    }
  }

  /// A drag of promised files of the type, as the screenshot thumbnail offers its file.
  func promiseDrag(_ names: [String], type: String = "public.png") -> (DropSelfTest.DraggingInfo, [Promise]) {
    let promises = names.map { Promise($0) }
    return (drag(promises.map { NSFilePromiseProvider(fileType: type, delegate: $0) }), promises)
  }

  /// A drop view that attaches to the draft, and records what it keeps and when the drop ends.
  @MainActor final class Target {
    let draft = MessageField.Draft()
    let view = FileDropTarget.DropView()
    var kept: [String] = []
    var dropped = false

    init() {
      view.drop = { [unowned self] urls in
        dropped = true
        return draft.add(paths: urls.map(\.path)).map { URL(fileURLWithPath: $0) }
      }
      view.keep = { [unowned self] url in
        if FileManager.default.fileExists(atPath: url.path) { kept.append(url.lastPathComponent) }
      }
    }

    func waitForDrop() async {
      for _ in 0..<250 where !dropped { try? await Task.sleep(for: .milliseconds(20)) }
    }
  }

  struct PromiseFailed: Error {}

  @Test func dropViewAttachesPromisedImagesInTheOrderOfTheDragWhateverOrderTheyArrive() async throws {
    let target = Target()
    var targeted: [Bool] = []
    target.view.targeted = { targeted.append($0) }
    let source = Source(target.view)
    let (info, promises) = promiseDrag(["Screenshot 2.png", "Screenshot 1.png"])

    #expect(target.view.draggingEntered(info) == .copy)
    #expect(target.view.performDragOperation(info))
    try #require(source.calls.count == 2)
    source.fulfill(1, "Screenshot 1.png", Self.png)
    source.fulfill(0, "Screenshot 2.png", Self.png)
    await target.waitForDrop()

    #expect(target.draft.images.map(\.name) == ["Screenshot 2.png", "Screenshot 1.png"])
    #expect(target.draft.error == nil)
    #expect(targeted.first == true)
    #expect(target.kept.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: source.calls[0].folder.path))
    withExtendedLifetime(promises) {}
  }

  /// A promise can move its file, so a file that the draft left out goes to the Trash rather than away.
  @Test func dropViewKeepsAPromisedFileThatTheDraftLeftOut() async throws {
    let target = Target()
    let source = Source(target.view)
    let (info, promises) = promiseDrag(["notes.png", "shot.png"])

    #expect(target.view.performDragOperation(info))
    try #require(source.calls.count == 2)
    source.fulfill(0, "notes.png", Data("just some text".utf8))
    source.fulfill(1, "shot.png", Self.png)
    await target.waitForDrop()

    #expect(target.draft.images.map(\.name) == ["shot.png"])
    #expect(target.draft.error == "notes.png isn't an image.")
    #expect(target.kept == ["notes.png"])
    #expect(!FileManager.default.fileExists(atPath: source.calls[0].folder.path))
    withExtendedLifetime(promises) {}
  }

  /// A source can write part of a file before it fails. The part never attaches.
  @Test func dropViewReportsAFailedPromiseAndAttachesTheRest() async throws {
    let target = Target()
    let source = Source(target.view)
    let (info, promises) = promiseDrag(["broken.png", "shot.png"])

    #expect(target.view.performDragOperation(info))
    try #require(source.calls.count == 2)
    source.fulfill(0, "broken.png", Self.png.prefix(16), error: PromiseFailed())
    source.fulfill(1, "shot.png", Self.png)
    await target.waitForDrop()

    #expect(target.draft.images.map(\.name) == ["shot.png"])
    #expect(target.draft.error?.hasPrefix("can't read broken.png") == true)
    #expect(target.kept.isEmpty)
    withExtendedLifetime(promises) {}
  }

  @Test func dropViewIgnoresAReaderThatRunsMoreTimesThanItsPromiseNamed() async throws {
    let target = Target()
    let source = Source(target.view)
    let (info, promises) = promiseDrag(["a.png", "b.png"])

    #expect(target.view.performDragOperation(info))
    try #require(source.calls.count == 2)
    source.fulfill(0, "a.png", Self.png)
    source.fulfill(0, "extra.png", Self.png)
    source.fulfill(1, "b.png", Self.png)
    await target.waitForDrop()

    #expect(target.draft.images.map(\.name) == ["a.png", "b.png"])
    withExtendedLifetime(promises) {}
  }

  /// A screen recording's thumbnail promises a movie, which the draft would refuse after the source wrote it.
  @Test func dropViewRefusesAPromiseOfAFileThatIsNotAnImage() {
    let target = Target()
    let source = Source(target.view)
    let (info, promises) = promiseDrag(["Screen Recording.mov"], type: "com.apple.quicktime-movie")

    #expect(target.view.draggingEntered(info).isEmpty)
    #expect(!target.view.performDragOperation(info))
    #expect(source.calls.isEmpty)
    withExtendedLifetime(promises) {}
  }

  /// A drag that names a file needs no promise, so the view never waits for one.
  @Test func dropViewTakesFileURLsOverPromises() throws {
    let view = FileDropTarget.DropView()
    var dropped: [URL] = []
    view.drop = {
      dropped = $0
      return []
    }
    let source = Source(view)
    let promise = Promise("thumbnail.png")
    let info = drag([
      URL(fileURLWithPath: try file("a.png")) as NSURL,
      NSFilePromiseProvider(fileType: "public.png", delegate: promise),
    ])

    #expect(view.performDragOperation(info))
    #expect(dropped.map(\.lastPathComponent) == ["a.png"])
    #expect(source.calls.isEmpty)
  }

  @Test func dropViewPassesClicksThrough() {
    let view = FileDropTarget.DropView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))

    #expect(view.hitTest(NSPoint(x: 50, y: 50)) == nil)
  }

  @Test func dropViewHandsOverEveryFileInTheOrderOfTheDrag() throws {
    let view = FileDropTarget.DropView()
    var dropped: [URL] = []
    view.drop = {
      dropped = $0
      return []
    }
    let urls = try ["c.png", "a.png", "b.jpg"].map { URL(fileURLWithPath: try file($0)) }
    let info = drag(urls as [NSURL])

    #expect(view.draggingEntered(info) == .copy)
    #expect(view.draggingUpdated(info) == .copy)
    #expect(view.performDragOperation(info))
    #expect(dropped.map(\.lastPathComponent) == ["c.png", "a.png", "b.jpg"])
  }

  @Test func dropViewLeavesOutAWebURL() throws {
    let view = FileDropTarget.DropView()
    var dropped: [URL] = []
    view.drop = {
      dropped = $0
      return []
    }
    let info = drag([
      URL(fileURLWithPath: try file("a.png")) as NSURL, URL(string: "https://example.com/b.png")! as NSURL,
    ])

    #expect(view.performDragOperation(info))
    #expect(dropped.map(\.lastPathComponent) == ["a.png"])
  }

  /// An app that drags a file can also put the file's path on the pasteboard as text.
  @Test func dropViewTakesTheFileOfAnItemThatAlsoHasText() throws {
    let view = FileDropTarget.DropView()
    var dropped: [URL] = []
    view.drop = {
      dropped = $0
      return []
    }
    let path = try file("a.png")
    let item = NSPasteboardItem()
    item.setString(URL(fileURLWithPath: path).absoluteString, forType: .fileURL)
    item.setString(path, forType: .string)

    #expect(view.performDragOperation(drag([item])))
    #expect(dropped.map(\.lastPathComponent) == ["a.png"])
  }

  /// The view is in no window, so no field has focus to take the text.
  @Test func dropViewRefusesADragWithoutFiles() {
    let view = FileDropTarget.DropView()
    var dropped = false
    view.drop = { _ in
      dropped = true
      return []
    }
    let info = drag(["some text" as NSString])

    #expect(view.draggingEntered(info).isEmpty)
    #expect(view.draggingUpdated(info).isEmpty)
    #expect(!view.performDragOperation(info))
    #expect(!dropped)
  }

  @Test func dropViewShowsTheTargetOnlyWhileAFileDragIsOver() throws {
    let view = FileDropTarget.DropView()
    var targeted: [Bool] = []
    view.targeted = { targeted.append($0) }
    let info = drag([URL(fileURLWithPath: try file("a.png")) as NSURL])

    _ = view.draggingEntered(info)
    view.draggingExited(info)
    _ = view.draggingEntered(drag(["some text" as NSString]))

    #expect(targeted == [true, false, false])
  }

  @Test func dropViewTakesEveryDragFromTheFieldEditor() {
    let (editor, window) = editorInAWindow()
    defer { withExtendedLifetime(window) {} }

    FileDropTarget.DropView().limit(editor)

    #expect(editor.registeredDraggedTypes.isEmpty)
  }

  static let filenames = NSPasteboard.PasteboardType("NSFilenamesPboardType")

  /// A text view registers its drag types only in a window, and only once something asks it to.
  func editorInAWindow() -> (NSTextView, NSWindow) {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    let editor = NSTextView()
    window.contentView = editor
    editor.updateDragTypeRegistration()
    return (editor, window)
  }

  @Test func dropViewGivesBackTheFieldEditorsTypes() {
    let (editor, window) = editorInAWindow()
    defer { withExtendedLifetime(window) {} }
    let before = Set(editor.registeredDraggedTypes)
    #expect(before.contains(Self.filenames))
    let view = FileDropTarget.DropView()
    view.limit(editor)

    view.releaseFieldEditor()

    #expect(Set(editor.registeredDraggedTypes) == before)
  }

  /// The view is in no window, so no field editor edits a field under it.
  @Test func dropViewGivesBackTheFieldEditorWhenItEditsNoFieldUnderTheView() {
    let (editor, window) = editorInAWindow()
    defer { withExtendedLifetime(window) {} }
    let view = FileDropTarget.DropView()
    view.limit(editor)

    view.limitFieldEditor()

    #expect(editor.registeredDraggedTypes.contains(Self.filenames))
  }

  /// Focus that moves from one message field to another can update the new field's view first.
  @Test func dropViewLeavesTheFieldEditorToTheViewThatLimitedItSince() {
    let (editor, window) = editorInAWindow()
    defer { withExtendedLifetime(window) {} }
    let old = FileDropTarget.DropView()
    let new = FileDropTarget.DropView()
    old.limit(editor)
    new.limit(editor)

    old.releaseFieldEditor()

    #expect(editor.registeredDraggedTypes.isEmpty)
  }

  @Test func dropViewInsertsTextIntoTheFocusedFieldAtTheDropPoint() throws {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let field = NSTextField(frame: NSRect(x: 10, y: 10, width: 280, height: 24))
    field.stringValue = "look "
    let view = FileDropTarget.DropView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
    window.contentView?.addSubview(field)
    window.contentView?.addSubview(view)
    try #require(window.makeFirstResponder(field))
    let board = pasteboard()
    board.writeObjects(["at this" as NSString])
    let info = DropSelfTest.DraggingInfo(window: window, location: NSPoint(x: 280, y: 22), pasteboard: board)

    #expect(view.draggingEntered(info) == .copy)
    #expect(view.performDragOperation(info))
    #expect((field.currentEditor() as? NSTextView)?.string == "look at this")
  }

  @Test func dropViewInsertsTextBeforeTheTextAfterTheDropPoint() throws {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let field = NSTextField(frame: NSRect(x: 10, y: 10, width: 280, height: 24))
    field.stringValue = "world"
    let view = FileDropTarget.DropView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
    window.contentView?.addSubview(field)
    window.contentView?.addSubview(view)
    try #require(window.makeFirstResponder(field))
    let board = pasteboard()
    board.writeObjects(["hello " as NSString])
    let info = DropSelfTest.DraggingInfo(window: window, location: NSPoint(x: 2, y: 22), pasteboard: board)

    #expect(view.performDragOperation(info))
    #expect((field.currentEditor() as? NSTextView)?.string == "hello world")
  }

  /// The point lies inside "hello", so a point outside the field, which always maps to an end, can't pass.
  @Test func dropViewInsertsTextInsideAWordAtTheDropPoint() throws {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let field = NSTextField(frame: NSRect(x: 10, y: 10, width: 280, height: 24))
    field.stringValue = "hello world"
    let view = FileDropTarget.DropView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
    window.contentView?.addSubview(field)
    window.contentView?.addSubview(view)
    try #require(window.makeFirstResponder(field))
    let editor = try #require(field.currentEditor() as? NSTextView)
    let point = NSPoint(x: 40, y: 22)
    let layout = try #require(editor.layoutManager)
    let container = try #require(editor.textContainer)
    let index = layout.characterIndex(
      for: editor.convert(point, from: nil), in: container, fractionOfDistanceBetweenInsertionPoints: nil)
    try #require((1..<5).contains(index))
    let board = pasteboard()
    board.writeObjects(["-" as NSString])

    #expect(view.performDragOperation(DropSelfTest.DraggingInfo(window: window, location: point, pasteboard: board)))
    #expect(
      editor.string
        == ("hello world" as NSString).replacingCharacters(in: NSRange(location: index, length: 0), with: "-"))
  }

  /// A field that holds `text`, with `selected` selected, under a drop view. The drag starts in the field's editor.
  func movingText(_ text: String, selected: NSRange, dropAt x: CGFloat) throws -> (NSTextField, Bool) {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let field = NSTextField(frame: NSRect(x: 10, y: 10, width: 280, height: 24))
    field.stringValue = text
    let view = FileDropTarget.DropView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
    window.contentView?.addSubview(field)
    window.contentView?.addSubview(view)
    try #require(window.makeFirstResponder(field))
    let editor = try #require(field.currentEditor() as? NSTextView)
    editor.setSelectedRange(selected)
    let board = pasteboard()
    board.writeObjects([(text as NSString).substring(with: selected) as NSString])
    let info = DropSelfTest.DraggingInfo(
      window: window, location: NSPoint(x: x, y: 22), pasteboard: board, source: editor)
    _ = view.draggingEntered(info)
    let handled = view.performDragOperation(info)
    return (field, handled)
  }

  @Test func dropViewMovesTextDraggedWithinTheFocusedField() throws {
    let (field, handled) = try movingText("hello world", selected: NSRange(location: 6, length: 5), dropAt: 2)

    #expect(handled)
    #expect((field.currentEditor() as? NSTextView)?.string == "worldhello ")
  }

  @Test func dropViewLeavesTextDroppedInsideItsOwnSelection() throws {
    let (field, handled) = try movingText("hello world", selected: NSRange(location: 2, length: 7), dropAt: 40)

    #expect(handled)
    #expect((field.currentEditor() as? NSTextView)?.string == "hello world")
  }

  // MARK: paste(from:)

  @Test func pasteAttachesPNGData() {
    let draft = MessageField.Draft()
    let board = pasteboard()
    board.setData(Self.png, forType: .png)

    let handled = draft.paste(from: board)

    #expect(handled)
    #expect(draft.images.map(\.name) == ["Pasted image.png"])
    #expect(draft.images.first?.data == Self.png)
  }

  @Test func pasteAttachesTIFFDataAsAPNG() throws {
    let draft = MessageField.Draft()
    let board = pasteboard()
    let tiff = try #require(NSImage(data: Self.png)?.tiffRepresentation)
    board.setData(tiff, forType: .tiff)

    let handled = draft.paste(from: board)

    #expect(handled)
    #expect(draft.images.map(\.name) == ["Pasted image.png"])
    #expect(draft.images.first.flatMap { Attachments.kind(of: $0.data) } == .png)
  }

  /// A copy of several images in Preview's sidebar puts one item per image on the pasteboard.
  @Test func pasteAttachesTheImageDataOfEachItem() throws {
    let draft = MessageField.Draft()
    let board = pasteboard()
    let tiff = try #require(NSImage(data: Self.png)?.tiffRepresentation)
    let items = [Self.png, tiff, Self.png].enumerated().map { index, data in
      let item = NSPasteboardItem()
      item.setData(data, forType: index == 1 ? .tiff : .png)
      return item
    }
    board.writeObjects(items)

    let handled = draft.paste(from: board)

    #expect(handled)
    #expect(draft.images.count == 3)
    #expect(draft.images.allSatisfy { Attachments.kind(of: $0.data) == .png })
  }

  @Test func pasteAttachesUpToTheCountLimit() {
    let draft = MessageField.Draft()
    for n in 0..<(Attachments.countLimit - 1) { draft.append(name: "old\(n).png", data: Self.png) }
    let board = pasteboard()
    board.writeObjects(
      (0..<2).map { _ in
        let item = NSPasteboardItem()
        item.setData(Self.png, forType: .png)
        return item
      })

    let handled = draft.paste(from: board)

    #expect(handled)
    #expect(draft.images.count == Attachments.countLimit)
    #expect(draft.error == "Pasted image.png isn't attached: a message can carry at most 20 images.")
  }

  @Test func pasteLeavesItemsWithAStringInAnyItemToTheTextField() {
    let draft = MessageField.Draft()
    let board = pasteboard()
    let image = NSPasteboardItem()
    image.setData(Self.png, forType: .png)
    let text = NSPasteboardItem()
    text.setString("hello", forType: .string)
    board.writeObjects([image, text])

    let handled = draft.paste(from: board)

    #expect(!handled)
    #expect(draft.images.isEmpty)
  }

  @Test func pasteLeavesAStringToTheTextField() {
    let draft = MessageField.Draft()
    let board = pasteboard()
    board.setString("hello", forType: .string)

    let handled = draft.paste(from: board)

    #expect(!handled)
    #expect(draft.images.isEmpty)
  }

  /// A rich-text copy can carry an image of the text along with the text.
  @Test func pasteLeavesAStringWithImageDataToTheTextField() {
    let draft = MessageField.Draft()
    let board = pasteboard()
    board.declareTypes([.string, .png], owner: nil)
    board.setString("hello", forType: .string)
    board.setData(Self.png, forType: .png)

    let handled = draft.paste(from: board)

    #expect(!handled)
    #expect(draft.images.isEmpty)
  }

  @Test func pasteAttachesAnImageFileURL() throws {
    let draft = MessageField.Draft()
    let board = pasteboard()
    let path = try file("shot.png")
    board.writeObjects([URL(fileURLWithPath: path) as NSURL])

    let handled = draft.paste(from: board)

    #expect(handled)
    #expect(draft.images.map(\.name) == ["shot.png"])
    #expect(draft.images.first?.data == Self.png)
  }

  @Test func pasteAttachesSeveralImageFileURLs() throws {
    let draft = MessageField.Draft()
    let board = pasteboard()
    let a = try file("a.png")
    let b = try file("b.jpg")
    board.writeObjects([URL(fileURLWithPath: a) as NSURL, URL(fileURLWithPath: b) as NSURL])

    let handled = draft.paste(from: board)

    #expect(handled)
    #expect(draft.images.map(\.name) == ["a.png", "b.jpg"])
  }

  @Test func pasteLeavesAFileURLWithoutAnImageExtension() throws {
    let draft = MessageField.Draft()
    let board = pasteboard()
    let path = try file("notes.txt", Data("just some text".utf8))
    board.writeObjects([URL(fileURLWithPath: path) as NSURL])

    let handled = draft.paste(from: board)

    #expect(!handled)
    #expect(draft.images.isEmpty)
  }

  @Test func pasteLeavesFileURLsWhenOneHasNoImageExtension() throws {
    let draft = MessageField.Draft()
    let board = pasteboard()
    let image = try file("shot.png")
    let notes = try file("notes.txt", Data("just some text".utf8))
    board.writeObjects([URL(fileURLWithPath: image) as NSURL, URL(fileURLWithPath: notes) as NSURL])

    let handled = draft.paste(from: board)

    #expect(!handled)
    #expect(draft.images.isEmpty)
  }

  @Test func pasteOfAnImageFileURLThatIsNotAnImageSetsTheError() throws {
    let draft = MessageField.Draft()
    let board = pasteboard()
    let path = try file("notes.png", Data("just some text".utf8))
    board.writeObjects([URL(fileURLWithPath: path) as NSURL])

    _ = draft.paste(from: board)

    #expect(draft.images.isEmpty)
    #expect(draft.error?.contains("notes.png isn't an image.") == true)
  }

  @Test func pasteOfAnEmptyPasteboardReturnsFalse() {
    let draft = MessageField.Draft()

    #expect(!draft.paste(from: pasteboard()))
    #expect(draft.images.isEmpty)
  }

  // MARK: remove(_:)

  @Test func removeDropsOnlyThatImage() throws {
    let draft = MessageField.Draft()
    draft.add(paths: [try file("a.png"), try file("b.png")])
    let a = try #require(draft.images.first { $0.name == "a.png" })

    draft.remove(a.id)

    #expect(draft.images.map(\.name) == ["b.png"])
  }

  // MARK: clear(ifStill:images:)

  @Test func clearKeepsImagesAddedAfterTheSend() throws {
    let draft = MessageField.Draft()
    draft.text = "look"
    draft.add(paths: [try file("a.png")])
    let sent = draft.images.map(\.id)
    draft.add(paths: [try file("b.png")])

    draft.clear(ifStill: "look", images: sent)

    #expect(draft.text.isEmpty)
    #expect(draft.images.map(\.name) == ["b.png"])
  }

  @Test func clearRemovesTheSentImagesWhenTheTextChanged() throws {
    let draft = MessageField.Draft()
    draft.text = "look"
    draft.add(paths: [try file("a.png")])
    let sent = draft.images.map(\.id)
    draft.text = "look again"

    draft.clear(ifStill: "look", images: sent)

    #expect(draft.text == "look again")
    #expect(draft.images.isEmpty)
  }

  @Test func clearOfAnImageOnlySendEmptiesTheDraft() throws {
    let draft = MessageField.Draft()
    draft.add(paths: [try file("a.png")])
    let sent = draft.images.map(\.id)

    draft.clear(ifStill: "", images: sent)

    #expect(draft.text.isEmpty)
    #expect(draft.images.isEmpty)
  }

  @Test func clearOfATextOnlySendKeepsTheImages() throws {
    let draft = MessageField.Draft()
    draft.text = "look"
    draft.add(paths: [try file("a.png")])

    draft.clear(ifStill: "look", images: [])

    #expect(draft.text.isEmpty)
    #expect(draft.images.map(\.name) == ["a.png"])
  }

  // MARK: submit(_:to:)

  @Test func submitSendsAnImageWithoutText() async throws {
    let model = offlineModel()
    let requests = Sent()
    model.send = { op, args in
      requests.add(op, args)
      return .null
    }
    let draft = MessageField.Draft()
    draft.add(paths: [try file("a.png")])

    draft.submit("a", to: model)
    for _ in 0..<300 where !draft.images.isEmpty { try? await Task.sleep(nanoseconds: 10_000_000) }

    let request = try #require(requests.all.first)
    #expect(request.op == "send")
    #expect(request.args["text"]?.string == "")
    #expect(request.args["images"] == .array([Attachments.json(name: "a.png", data: Self.png)]))
    #expect(draft.images.isEmpty)
  }

  /// The requests that the model's `send` received.
  final class Sent: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [(op: String, args: [String: JSON])] = []
    var all: [(op: String, args: [String: JSON])] { lock.withLock { requests } }
    func add(_ op: String, _ args: [String: JSON]) { lock.withLock { requests.append((op, args)) } }
  }

  // MARK: chipLabel(_:)

  @Test func chipLabelNamesTheImageAndTheRemoveAction() {
    #expect(MessageField.chipLabel("screenshot.png") == "Image: screenshot.png, remove")
  }
}
