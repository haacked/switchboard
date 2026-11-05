import Foundation
import SwitchboardCore
import Testing

@Suite(.timeLimit(.minutes(2))) struct AttachmentTests {
  /// A valid 1×1 PNG.
  static let png = Data([
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00,
    0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00, 0x0A, 0x49,
    0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00, 0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00,
    0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
  ])

  /// The start of a JPEG. sbd sniffs only the magic bytes.
  static let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01])

  /// Writes the data to a file in the home's pictures folder, outside every session's folder.
  private func picture(_ sbd: Instance, _ name: String, _ data: Data = png) throws -> String {
    let dir = "\(sbd.home.path)/pictures"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let path = "\(dir)/\(name)"
    try data.write(to: URL(fileURLWithPath: path))
    return path
  }

  /// A session whose first turn has ended.
  private func readySession(_ sbd: Instance) throws -> SessionSummary {
    let s = try sbd.new(prompt: "hello")
    try sbd.waitFor(s.id, "the first reply") { $0.lastReply == "Done: hello" }
    return s
  }

  /// The full paths of the files in the session's attachments folder, sorted by name.
  private func copies(_ sbd: Instance, _ id: String) -> [String] {
    let folder = sbd.home.attachmentsFolder(id)
    let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
    return names.sorted().map { "\(folder)/\($0)" }
  }

  private func name(_ path: String) -> String { (path as NSString).lastPathComponent }

  private func sentTexts(_ sbd: Instance, _ id: String) throws -> [String] {
    try sbd.events(id).filter { $0.kind == "sent" }.compactMap { $0.data["text"]?.string }
  }

  /// The message that sbd sends for the copies, by the home's path or by its real path. /tmp is a link to /private/tmp.
  private func messages(_ sbd: Instance, text: String, copies: [String]) -> Set<String> {
    let home = sbd.home.path
    let realHome = real(home)
    return [
      Attachments.message(text: text, paths: copies),
      Attachments.message(text: text, paths: copies.map { realHome + $0.dropFirst(home.count) }),
    ]
  }

  /// Waits for the sent event and the reply to the message with the copies, and returns the sent text.
  @discardableResult
  private func expectDelivered(_ sbd: Instance, _ id: String, text: String, copies: [String]) throws -> String {
    let accepted = messages(sbd, text: text, copies: copies)
    let sent = try #require(try sentTexts(sbd, id).last)
    #expect(accepted.contains(sent))
    try sbd.waitFor(id, "the reply to the message with images", timeout: 20) { $0.lastReply == "Done: \(sent)" }
    return sent
  }

  /// A request near the limit is a line of about 27 MB of base64.
  @Test func sendsAnImageJustUnderTheLimit() throws {
    let sbd = try Instance()
    let s = try readySession(sbd)
    var data = Self.png
    data.append(Data(count: Attachments.limit - data.count))
    let original = try picture(sbd, "big.png", data)

    let started = Date()
    #expect(["pasted\n", "queued\n"].contains(try sbd.sb("send", s.id, "--image", original)))
    #expect(Date().timeIntervalSince(started) < 20)
    let files = copies(sbd, s.id)
    try #require(files.count == 1)
    #expect(try Data(contentsOf: URL(fileURLWithPath: files[0])) == data)
  }

  @Test func copiesTheImageIntoTheSessionsAttachmentsFolder() throws {
    let sbd = try Instance()
    let s = try readySession(sbd)
    let original = try picture(sbd, "shot.png")

    let out = try sbd.sb("send", s.id, "--image", original, "look at this")

    #expect(["pasted\n", "queued\n"].contains(out))
    let files = copies(sbd, s.id)
    try #require(files.count == 1)
    #expect(name(files[0]).range(of: #"^[0-9]+-shot(\.png)?\.png$"#, options: .regularExpression) != nil)
    #expect(try Data(contentsOf: URL(fileURLWithPath: files[0])) == Self.png)
    #expect(try Data(contentsOf: URL(fileURLWithPath: original)) == Self.png)
  }

  @Test func repliesToTheTextAndThePathsOfTheCopies() throws {
    let sbd = try Instance()
    let s = try readySession(sbd)
    let original = try picture(sbd, "shot.png")

    try sbd.sb("send", s.id, "--image", original, "look at this")

    try expectDelivered(sbd, s.id, text: "look at this", copies: copies(sbd, s.id))
  }

  @Test func sendsSeveralImagesInTheOrderGiven() throws {
    let sbd = try Instance()
    let s = try readySession(sbd)
    let b = try picture(sbd, "b.png")
    let a = try picture(sbd, "a.png")

    try sbd.sb("send", s.id, "--image", b, "--image", a, "compare these")

    let files = copies(sbd, s.id)
    try #require(files.count == 2)
    func copy(of base: String) throws -> String {
      try #require(files.first { name($0).range(of: "^[0-9]+-\(base)\\.", options: .regularExpression) != nil })
    }
    try expectDelivered(sbd, s.id, text: "compare these", copies: [try copy(of: "b"), try copy(of: "a")])
  }

  @Test func sendsAnImageWithoutText() throws {
    let sbd = try Instance()
    let s = try readySession(sbd)
    let original = try picture(sbd, "shot.png")

    try sbd.sb("send", s.id, "--image", original)

    let files = copies(sbd, s.id)
    try #require(files.count == 1)
    let sent = try expectDelivered(sbd, s.id, text: "", copies: files)
    #expect(!sent.contains("\n"))
  }

  /// Only `--image` pairs right after the session are flags.
  @Test func sendsAnImageFlagAfterTheTextAsText() throws {
    let sbd = try Instance()
    let s = try readySession(sbd)
    let original = try picture(sbd, "shot.png")

    try sbd.sb("send", s.id, "look", "--image", original)

    try sbd.waitFor(s.id, "the reply") { $0.lastReply == "Done: look --image \(original)" }
    #expect(copies(sbd, s.id).isEmpty)
  }

  @Test func namesTheCopyByTheKindOfItsContent() throws {
    let sbd = try Instance()
    let s = try readySession(sbd)
    let original = try picture(sbd, "photo.png", Self.jpeg)

    try sbd.sb("send", s.id, "--image", original, "look")

    let files = copies(sbd, s.id)
    try #require(files.count == 1)
    #expect(name(files[0]).range(of: #"^[0-9]+-photo(\.png)?\.jpg$"#, options: .regularExpression) != nil)
  }

  @Test func replacesCharactersOutsideTheSafeSetInTheName() throws {
    let sbd = try Instance()
    let s = try readySession(sbd)
    let original = try picture(sbd, "my shot (1).png")

    try sbd.sb("send", s.id, "--image", original, "look")

    let files = copies(sbd, s.id)
    try #require(files.count == 1)
    #expect(name(files[0]).range(of: #"^[0-9]+-my-shot--1-(\.png)?\.png$"#, options: .regularExpression) != nil)
    try expectDelivered(sbd, s.id, text: "look", copies: files)
  }

  /// A name with slashes from an API caller stays one file in the attachments folder.
  @Test func keepsANameWithSlashesInsideTheAttachmentsFolder() throws {
    let sbd = try Instance()
    let s = try readySession(sbd)

    _ = try sbd.client.call(
      "send",
      [
        "session": .string(s.id), "text": "look",
        "images": [["name": "../../../escaped.png", "data": .string(Self.png.base64EncodedString())]],
      ])

    let files = copies(sbd, s.id)
    try #require(files.count == 1)
    #expect(try Data(contentsOf: URL(fileURLWithPath: files[0])) == Self.png)
    let strays = FileManager.default.enumerator(atPath: sbd.home.path)?.compactMap { $0 as? String } ?? []
    #expect(strays.filter { $0.hasSuffix("escaped.png") }.allSatisfy { "\(sbd.home.path)/\($0)" == files[0] })
  }

  @Test func refusesANonImageInSb() throws {
    let sbd = try Instance()
    let s = try readySession(sbd)
    let notes = try picture(sbd, "notes.png", Data("just some text".utf8))
    let before = try sentTexts(sbd, s.id)

    let r = try sbd.run(["send", s.id, "--image", notes, "look"])

    #expect(r.status != 0)
    #expect(r.stderr.contains("notes.png isn't an image."))
    #expect(copies(sbd, s.id).isEmpty)
    #expect(try sentTexts(sbd, s.id) == before)
  }

  @Test func refusesANonImageInSbd() throws {
    let sbd = try Instance()
    let s = try readySession(sbd)
    let before = try sentTexts(sbd, s.id)

    #expect(throws: APIError.self) {
      try sbd.client.call(
        "send",
        [
          "session": .string(s.id),
          "images": [["name": "x.png", "data": .string(Data("just some text".utf8).base64EncodedString())]],
        ])
    }
    #expect(copies(sbd, s.id).isEmpty)
    #expect(try sentTexts(sbd, s.id) == before)
  }

  @Test func refusesDataThatIsNotBase64InSbd() throws {
    let sbd = try Instance()
    let s = try readySession(sbd)

    #expect(throws: APIError.self) {
      try sbd.client.call(
        "send", ["session": .string(s.id), "images": [["name": "x.png", "data": "not base64 at all!"]]])
    }
    #expect(copies(sbd, s.id).isEmpty)
  }

  /// One bad image refuses the whole message, so the good one is not sent alone.
  @Test func refusesAMessageWithOneBadImageInSbd() throws {
    let sbd = try Instance()
    let s = try readySession(sbd)
    let before = try sentTexts(sbd, s.id)

    #expect(throws: APIError.self) {
      try sbd.client.call(
        "send",
        [
          "session": .string(s.id), "text": "look",
          "images": [
            ["name": "good.png", "data": .string(Self.png.base64EncodedString())],
            ["name": "bad.png", "data": .string(Data("text".utf8).base64EncodedString())],
          ],
        ])
    }
    #expect(try sentTexts(sbd, s.id) == before)
  }

  @Test func refusesASymlinkInSb() throws {
    let sbd = try Instance()
    let s = try readySession(sbd)
    let original = try picture(sbd, "shot.png")
    let link = "\(sbd.home.path)/pictures/link.png"
    try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: original)
    let before = try sentTexts(sbd, s.id)

    let r = try sbd.run(["send", s.id, "--image", link, "look"])

    #expect(r.status != 0)
    #expect(copies(sbd, s.id).isEmpty)
    #expect(try sentTexts(sbd, s.id) == before)
  }

  @Test func refusesAnImageOverTheLimitInSb() throws {
    let sbd = try Instance()
    let s = try readySession(sbd)
    let big = try picture(sbd, "big.png")
    let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: big))
    try handle.truncate(atOffset: UInt64(Attachments.limit + 1))
    try handle.close()

    let r = try sbd.run(["send", s.id, "--image", big, "look"])

    #expect(r.status != 0)
    #expect(r.stderr.contains("big.png is larger than 20 MB."))
    #expect(copies(sbd, s.id).isEmpty)
  }

  @Test func queuesAMessageWithImagesToAStoppedSession() throws {
    let sbd = try Instance()
    let s = try readySession(sbd)
    try sbd.sb("stop", s.id)
    try sbd.waitFor(s.id, "claude to exit") { !$0.live }
    let original = try picture(sbd, "shot.png")

    let out = try sbd.sb("send", s.id, "--image", original, "look at this")

    #expect(out == "queued\n")
    try expectDelivered(sbd, s.id, text: "look at this", copies: copies(sbd, s.id))
    #expect(sbd.stubArgs().last == "--resume \(s.claudeSessionId) --settings \(sbd.home.claudeSettings)")
  }

  @Test func sendsTextAloneAsBefore() throws {
    let sbd = try Instance()
    let s = try readySession(sbd)

    try sbd.sb("send", s.id, "no images here")

    try sbd.waitFor(s.id, "the reply") { $0.lastReply == "Done: no images here" }
    #expect(try sentTexts(sbd, s.id).last == "no images here")
    #expect(copies(sbd, s.id).isEmpty)
  }

  @Test func removingTheSessionRemovesItsAttachmentsAndKeepsTheOriginal() throws {
    let sbd = try Instance()
    let s = try readySession(sbd)
    let original = try picture(sbd, "shot.png")
    try sbd.sb("send", s.id, "--image", original, "look at this")
    try #require(copies(sbd, s.id).count == 1)

    try sbd.sb("rm", s.id)

    #expect(!FileManager.default.fileExists(atPath: sbd.home.attachmentsFolder(s.id)))
    #expect(try Data(contentsOf: URL(fileURLWithPath: original)) == Self.png)
  }
}
