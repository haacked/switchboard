import AppKit
import SwitchboardCore
import Testing

@testable import SwitchboardApp

@MainActor
@Suite final class MessageAttachmentTests {
  /// A valid 1×1 PNG.
  static let png = Data([
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00,
    0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00, 0x0A, 0x49,
    0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00, 0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00,
    0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
  ])

  let folder: String

  init() throws {
    folder = "\(NSTemporaryDirectory())message-attachments-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
  }

  deinit { try? FileManager.default.removeItem(atPath: folder) }

  /// Writes the data to a file in the test's folder and returns its path.
  func file(_ name: String, _ data: Data = png) throws -> String {
    let path = "\(folder)/\(name)"
    try data.write(to: URL(fileURLWithPath: path))
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
