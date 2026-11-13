import CoreGraphics
import Foundation
import ImageIO
import Testing
import os

@testable import SwitchboardCore

/// A valid 1×1 PNG.
let onePixelPNG = Data([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00,
  0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00, 0x0A, 0x49,
  0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00, 0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00,
  0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
])

/// The start of a JPEG. Sniffing reads only the magic bytes.
let jpegHeader = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01])

/// An ISO media file's first box: its size, `ftyp`, and the major brand.
func ftyp(_ brand: String) -> Data {
  Data([0x00, 0x00, 0x00, 0x18]) + Data("ftyp\(brand)".utf8) + Data([0x00, 0x00, 0x00, 0x00]) + Data("mif1heic".utf8)
}

/// The text of the error that `body` throws, or nil when it returns.
func refusal<T>(_ body: () throws -> T) -> String? {
  do {
    _ = try body()
    return nil
  } catch {
    return String(describing: error)
  }
}

/// A new empty folder under the temporary folder.
func scratchFolder() throws -> String {
  let path = "\(NSTemporaryDirectory())attachments-\(UUID().uuidString)"
  try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
  return path
}

@Suite struct AttachmentsKindTests {
  static let images: [(String, Data, Attachments.Kind)] = [
    ("png", onePixelPNG, .png),
    ("jpeg", jpegHeader, .jpeg),
    ("gif87a", Data("GIF87a\u{01}\u{00}\u{01}\u{00}".utf8), .gif),
    ("gif89a", Data("GIF89a\u{01}\u{00}\u{01}\u{00}".utf8), .gif),
    ("webp", Data("RIFF".utf8) + Data([0x24, 0x00, 0x00, 0x00]) + Data("WEBPVP8 ".utf8), .webp),
  ]

  @Test(arguments: images)
  func sniffsEachKind(_ label: String, _ data: Data, _ kind: Attachments.Kind) {
    #expect(Attachments.kind(of: data) == kind)
  }

  @Test(arguments: ["heic", "heix", "hevc", "hevx", "heim", "heis", "mif1", "msf1"])
  func sniffsHEICByEachBrand(_ brand: String) {
    #expect(Attachments.kind(of: ftyp(brand)) == .heic)
  }

  static let notImages: [(String, Data)] = [
    ("empty", Data()),
    ("text", Data("hello, world".utf8)),
    ("PNG signature cut short", onePixelPNG.prefix(7)),
    ("JPEG marker cut short", Data([0xFF, 0xD8])),
    ("GIF of an unknown version", Data("GIF88a\u{01}\u{00}".utf8)),
    ("RIFF that is WAVE", Data("RIFF".utf8) + Data([0x24, 0x00, 0x00, 0x00]) + Data("WAVEfmt ".utf8)),
    ("RIFF cut short", Data("RIFF".utf8) + Data([0x24, 0x00])),
    ("ftyp of an MP4", ftyp("isom")),
    ("ftyp of a QuickTime movie", ftyp("qt  ")),
    ("ftyp at offset 0", Data("ftypheic".utf8) + Data([0x00, 0x00, 0x00, 0x00])),
    ("ftyp with no brand", Data([0x00, 0x00, 0x00, 0x08]) + Data("ftyp".utf8)),
  ]

  @Test(arguments: notImages)
  func findsNoKindInDataThatIsNotAnImage(_ label: String, _ data: Data) {
    #expect(Attachments.kind(of: data) == nil)
  }

  @Test(arguments: [Attachments.Kind.png, .jpeg, .gif, .webp, .heic])
  func eachKindsFileExtensionIsAnAllowedExtension(_ kind: Attachments.Kind) {
    #expect(Attachments.extensions.contains(kind.fileExtension))
  }

  @Test func allowsTheListedExtensions() {
    #expect(Set(Attachments.extensions) == ["png", "jpg", "jpeg", "gif", "webp", "heic"])
  }

  @Test func limitsAnImageTo20MB() {
    #expect(Attachments.limit == 20 * 1024 * 1024)
  }

  @Test func limitsAMessageTo20ImagesAnd100MB() {
    #expect(Attachments.countLimit == 20)
    #expect(Attachments.totalLimit == 100 * 1024 * 1024)
  }
}

@Suite struct AttachmentsMessageLimitTests {
  @Test func acceptsAMessageAtBothLimits() throws {
    try Attachments.checkMessage(count: Attachments.countLimit, total: Attachments.totalLimit)
  }

  @Test func refusesOneImageOverTheCountLimit() {
    #expect(
      refusal { try Attachments.checkMessage(count: Attachments.countLimit + 1, total: 0) }
        == "a message can carry at most 20 images.")
  }

  @Test func refusesOneByteOverTheTotalLimit() {
    #expect(
      refusal { try Attachments.checkMessage(count: 2, total: Attachments.totalLimit + 1) }
        == "a message's images can total at most 100 MB.")
  }
}

@Suite struct AttachmentsValidateTests {
  @Test func acceptsAPNGNamedPNG() throws {
    #expect(try Attachments.validate(name: "shot.png", data: onePixelPNG) == .png)
  }

  @Test func acceptsAJPEGNamedPNGAsAJPEG() throws {
    #expect(try Attachments.validate(name: "photo.png", data: jpegHeader) == .jpeg)
  }

  @Test(arguments: ["a.png", "a.jpg", "a.jpeg", "a.gif", "a.webp", "a.heic"])
  func acceptsAnImageUnderEachAllowedExtension(_ name: String) throws {
    #expect(try Attachments.validate(name: name, data: onePixelPNG) == .png)
  }

  @Test func refusesATextFileNamedTxt() {
    #expect(
      refusal { try Attachments.validate(name: "notes.txt", data: Data("hello".utf8)) } == "notes.txt isn't an image.")
  }

  @Test func refusesATextFileNamedPNG() {
    #expect(
      refusal { try Attachments.validate(name: "notes.png", data: Data("hello".utf8)) } == "notes.png isn't an image.")
  }

  /// The extension decides as well as the content, so a real image with another extension is refused.
  @Test(arguments: ["shot.txt", "shot.tiff", "shot.svg", "shot", "png", "shot.png.txt"])
  func refusesAnImageWhoseExtensionIsNotAllowed(_ name: String) {
    #expect(refusal { try Attachments.validate(name: name, data: onePixelPNG) } == "\(name) isn't an image.")
  }

  @Test func refusesEmptyData() {
    #expect(refusal { try Attachments.validate(name: "empty.png", data: Data()) } == "empty.png isn't an image.")
  }

  @Test func acceptsAnImageOfExactlyTheLimit() throws {
    let data = onePixelPNG + Data(count: Attachments.limit - onePixelPNG.count)

    #expect(try Attachments.validate(name: "big.png", data: data) == .png)
  }

  @Test func refusesAnImageOneByteOverTheLimit() {
    let data = onePixelPNG + Data(count: Attachments.limit - onePixelPNG.count + 1)

    #expect(refusal { try Attachments.validate(name: "big.png", data: data) } == "big.png is larger than 20 MB.")
  }
}

@Suite(.serialized) struct AttachmentsReadTests {
  @Test func readsAnImageFile() throws {
    let dir = try scratchFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = "\(dir)/shot.png"
    try onePixelPNG.write(to: URL(fileURLWithPath: path))

    #expect(try Attachments.read(path: path) == onePixelPNG)
  }

  @Test func readsAFileWhoseFolderHasASpace() throws {
    let dir = try scratchFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    try FileManager.default.createDirectory(atPath: "\(dir)/My Pictures", withIntermediateDirectories: true)
    let path = "\(dir)/My Pictures/shot.png"
    try onePixelPNG.write(to: URL(fileURLWithPath: path))

    #expect(try Attachments.read(path: path) == onePixelPNG)
  }

  @Test func refusesATextFileNamedPNG() throws {
    let dir = try scratchFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = "\(dir)/notes.png"
    try Data("hello".utf8).write(to: URL(fileURLWithPath: path))

    #expect(refusal { try Attachments.read(path: path) }?.contains("isn't an image") == true)
  }

  @Test func refusesASymlinkToAnImage() throws {
    let dir = try scratchFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    try onePixelPNG.write(to: URL(fileURLWithPath: "\(dir)/real.png"))
    try FileManager.default.createSymbolicLink(atPath: "\(dir)/link.png", withDestinationPath: "\(dir)/real.png")

    #expect(refusal { try Attachments.read(path: "\(dir)/link.png") } == "link.png is a symlink.")
  }

  @Test func refusesASymlinkWithARelativeTarget() throws {
    let dir = try scratchFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    try onePixelPNG.write(to: URL(fileURLWithPath: "\(dir)/real.png"))
    try FileManager.default.createSymbolicLink(atPath: "\(dir)/link.png", withDestinationPath: "real.png")

    #expect(refusal { try Attachments.read(path: "\(dir)/link.png") } != nil)
  }

  @Test func refusesAFolderNamedPNG() throws {
    let dir = try scratchFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    try FileManager.default.createDirectory(atPath: "\(dir)/folder.png", withIntermediateDirectories: true)

    #expect(refusal { try Attachments.read(path: "\(dir)/folder.png") } == "folder.png isn't an image.")
  }

  @Test func refusesAMissingFile() throws {
    let dir = try scratchFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }

    #expect(refusal { try Attachments.read(path: "\(dir)/missing.png") } != nil)
  }

  /// A FIFO with no writer blocks a plain open. The read runs on another
  /// thread, so a blocked open fails the test instead of hanging it. That
  /// thread comes from a queue of its own, because a global queue gets no
  /// thread while other tests block every thread of Swift's cooperative pool.
  @Test(.timeLimit(.minutes(1))) func refusesAFIFOWithoutBlocking() throws {
    let dir = try scratchFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = "\(dir)/pipe.png"
    #expect(mkfifo(path, 0o600) == 0)
    let finished = DispatchSemaphore(value: 0)
    let result = OSAllocatedUnfairLock<String?>(initialState: nil)

    DispatchQueue(label: "refusesAFIFOWithoutBlocking").async {
      let refused = refusal { try Attachments.read(path: path) } ?? "read returned data"
      result.withLock { $0 = refused }
      finished.signal()
    }
    let returned = finished.wait(timeout: .now() + 5) == .success
    if !returned {
      // A writer releases an open that blocked. The writer then closes at once.
      let fd = open(path, O_WRONLY | O_NONBLOCK)
      if fd >= 0 { close(fd) }
      _ = finished.wait(timeout: .now() + 5)
    }

    #expect(returned)
    let refused = result.withLock { $0 }
    #expect(refused != nil && refused != "read returned data")
  }

  @Test func refusesAFileOverTheLimitBeforeReadingIt() throws {
    let dir = try scratchFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = "\(dir)/big.png"
    try onePixelPNG.write(to: URL(fileURLWithPath: path))
    let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
    try handle.truncate(atOffset: UInt64(Attachments.limit + 1))
    try handle.close()

    #expect(refusal { try Attachments.read(path: path) } == "big.png is larger than 20 MB.")
  }

  @Test func readRefusesAFileLargerThanTheRoomLeftBeforeReadingIt() throws {
    let dir = try scratchFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = "\(dir)/big.png"
    try Data(count: 1000).write(to: URL(fileURLWithPath: path))

    // A read file would fail as "isn't an image", so this error shows the content was never read.
    #expect(
      refusal { try Attachments.read(path: path, remaining: 999) } == "a message's images can total at most 100 MB.")
    #expect(refusal { try Attachments.read(path: path, remaining: 1000) }?.contains("isn't an image") == true)
  }

  @Test func readsAFileOfExactlyTheLimit() throws {
    let dir = try scratchFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = "\(dir)/big.png"
    try onePixelPNG.write(to: URL(fileURLWithPath: path))
    let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
    try handle.truncate(atOffset: UInt64(Attachments.limit))
    try handle.close()

    #expect(try Attachments.read(path: path).count == Attachments.limit)
  }
}

@Suite struct AttachmentsHEICTests {
  /// A 4×4 HEIC that ImageIO wrote, or nil on a machine whose ImageIO can't encode HEIC.
  static let sample = heic(width: 4, height: 4)

  /// An 8×4 HEIC whose orientation turns it into a 4×8 portrait, as a camera stores one.
  static let portrait = heic(width: 8, height: 4, orientation: 6)

  static func heic(width: Int, height: Int, orientation: Int? = nil) -> Data? {
    guard
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return nil }
    context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    guard let image = context.makeImage() else { return nil }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, "public.heic" as CFString, 1, nil) else {
      return nil
    }
    let properties = orientation.map { [kCGImagePropertyOrientation: $0] as CFDictionary }
    CGImageDestinationAddImage(destination, image, properties)
    guard CGImageDestinationFinalize(destination), data.length > 0 else { return nil }
    return data as Data
  }

  @Test(.enabled(if: AttachmentsHEICTests.sample != nil)) func sniffsAnImageIOHEICAsHEIC() throws {
    let heic = try #require(Self.sample)

    #expect(Attachments.kind(of: heic) == .heic)
  }

  @Test(.enabled(if: AttachmentsHEICTests.sample != nil)) func convertsHEICToPNG() throws {
    let heic = try #require(Self.sample)

    let png = try Attachments.png(fromHEIC: heic)

    #expect(Attachments.kind(of: png) == .png)
  }

  @Test(.enabled(if: AttachmentsHEICTests.sample != nil)) func keepsTheSizeOfAConvertedImage() throws {
    let heic = try #require(Self.sample)

    let png = try Attachments.png(fromHEIC: heic)

    let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    #expect(image.width == 4)
    #expect(image.height == 4)
  }

  @Test(.enabled(if: AttachmentsHEICTests.portrait != nil)) func turnsAPortraitHEICUpright() throws {
    let heic = try #require(Self.portrait)

    let png = try Attachments.png(fromHEIC: heic)

    let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    #expect(image.width == 4)
    #expect(image.height == 8)
  }

  @Test func refusesToConvertDataThatIsNotAnImage() {
    #expect(refusal { try Attachments.png(fromHEIC: Data("hello".utf8)) } != nil)
  }
}

@Suite struct AttachmentsMessageTests {
  static let folder = "/tmp/sbt.abc/sessions/s1/attachments"
  static let spacedFolder = "/Users/me/My Home/sessions/s1/attachments"

  @Test func putsThePathsOnALineAfterTheText() {
    #expect(
      Attachments.message(text: "look at this", paths: ["\(Self.folder)/1-a.png"])
        == "look at this\n\(Self.folder)/1-a.png")
  }

  @Test func separatesThePathsWithSpaces() {
    #expect(
      Attachments.message(text: "two", paths: ["\(Self.folder)/1-a.png", "\(Self.folder)/2-b.jpg"])
        == "two\n\(Self.folder)/1-a.png \(Self.folder)/2-b.jpg")
  }

  @Test func escapesTheSpacesInAPath() {
    #expect(
      Attachments.message(text: "look", paths: ["\(Self.spacedFolder)/1-a.png"])
        == "look\n/Users/me/My\\ Home/sessions/s1/attachments/1-a.png")
  }

  @Test func trimsTheText() {
    #expect(Attachments.message(text: "  look \n\n", paths: ["/f/1-a.png"]) == "look\n/f/1-a.png")
  }

  @Test func keepsTheNewLinesInsideTheText() {
    #expect(Attachments.message(text: "one\ntwo", paths: ["/f/1-a.png"]) == "one\ntwo\n/f/1-a.png")
  }

  @Test(arguments: ["", "   ", "\n\n"])
  func sendsOnlyThePathsLineWithoutText(_ text: String) {
    #expect(Attachments.message(text: text, paths: ["/f/1-a.png"]) == "/f/1-a.png")
  }

  @Test func splitsTheTextFromThePathsLine() throws {
    let message = "look at this\n\(Self.folder)/1-a.png"

    let parts = try #require(Attachments.split(message, folder: Self.folder))

    #expect(parts.text == "look at this\n")
    #expect(parts.paths == "\(Self.folder)/1-a.png")
  }

  @Test func splitsAMessageOfOnlyPaths() throws {
    let parts = try #require(Attachments.split("\(Self.folder)/1-a.png", folder: Self.folder))

    #expect(parts.text == "")
    #expect(parts.paths == "\(Self.folder)/1-a.png")
  }

  @Test func splitsEscapedPathsInAFolderWithASpace() throws {
    let message = Attachments.message(text: "look", paths: ["\(Self.spacedFolder)/1-a.png"])

    let parts = try #require(Attachments.split(message, folder: Self.spacedFolder))

    #expect(parts.paths == "/Users/me/My\\ Home/sessions/s1/attachments/1-a.png")
  }

  @Test func findsNoPathsInPlainText() {
    #expect(Attachments.split("look at this", folder: Self.folder) == nil)
  }

  @Test func findsNoPathsInAnEmptyMessage() {
    #expect(Attachments.split("", folder: Self.folder) == nil)
  }

  @Test func findsNoPathsWhenTheyAreNotOnTheLastLine() {
    let message = "\(Self.folder)/1-a.png\nlook at this"

    #expect(Attachments.split(message, folder: Self.folder) == nil)
  }

  static let outside: [(String, String, String)] = [
    ("a path outside the folder", "look\n/Users/me/Desktop/shot.png", folder),
    ("one path inside and one outside", "look\n\(folder)/1-a.png /Users/me/Desktop/shot.png", folder),
    ("a path in a sibling whose name starts with the folder's", "look\n\(folder)-evil/1-a.png", folder),
    ("the folder itself", "look\n\(folder)", folder),
    ("a path that climbs out of the folder", "look\n\(folder)/../../other/attachments/1-a.png", folder),
    ("a path and other words", "look\n\(folder)/1-a.png and this", folder),
    ("an unescaped space in a path", "look\n\(spacedFolder)/1-a.png", spacedFolder),
    ("a relative path", "look\nsessions/s1/attachments/1-a.png", folder),
  ]

  @Test(arguments: outside)
  func findsNoPathsWhenTheLastLineHas(_ label: String, _ message: String, _ folder: String) {
    #expect(Attachments.split(message, folder: folder) == nil)
  }

  static let texts = ["", "look", "first\nsecond", "  padded  ", "ends with a backslash \\", "a\n\nblank line"]
  static let folders = [folder, spacedFolder]

  /// `split` takes back the text and paths line of each message that `message` builds.
  @Test(arguments: texts, folders)
  func splitTakesApartWhatMessageBuilds(_ text: String, _ folder: String) throws {
    let paths = ["\(folder)/1-a.png", "\(folder)/2-b c.jpg"]
    let message = Attachments.message(text: text, paths: paths)
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

    let parts = try #require(Attachments.split(message, folder: folder))

    #expect(parts.text == (trimmed.isEmpty ? "" : trimmed + "\n"))
    #expect(parts.paths == paths.map { $0.replacingOccurrences(of: " ", with: "\\ ") }.joined(separator: " "))
    #expect(parts.text + parts.paths == message)
  }
}
