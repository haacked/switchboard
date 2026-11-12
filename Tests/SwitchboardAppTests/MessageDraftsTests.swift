import AppKit
import SwitchboardCore
import Testing

@testable import SwitchboardApp

@MainActor
@Suite final class MessageDraftsTests {
  /// A valid 1×1 GIF, so that a test can tell two attached images apart by their data.
  static let gif = Data([
    0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x01, 0x00, 0x01, 0x00, 0x80, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0x00, 0x00, 0x00,
    0x21, 0xF9, 0x04, 0x01, 0x00, 0x00, 0x00, 0x00, 0x2C, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x02,
    0x02, 0x44, 0x01, 0x00, 0x3B,
  ])
  static let png = MessageAttachmentTests.png

  /// Holds the source image files and the store's folder.
  let root: String
  /// The folder that the store saves to.
  let folder: String

  init() throws {
    root = "\(NSTemporaryDirectory())message-drafts-\(UUID().uuidString)"
    folder = "\(root)/drafts"
    try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
  }

  deinit { try? FileManager.default.removeItem(atPath: root) }

  /// Writes the data to a file outside the store's folder and returns its path.
  func file(_ name: String, _ data: Data? = nil) throws -> String {
    let path = "\(root)/\(name)"
    try (data ?? Self.png).write(to: URL(fileURLWithPath: path))
    return path
  }

  /// The files in the store's folder other than drafts.json.
  func imageFiles() throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: folder).filter { $0 != "drafts.json" }.sorted()
  }

  /// The text of drafts.json, or an empty string when the store did not write one.
  func draftsJSON() -> String {
    (try? String(contentsOfFile: "\(folder)/drafts.json", encoding: .utf8)) ?? ""
  }

  /// A time far from now, so that no test depends on the clock.
  let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

  // MARK: draft(for:)

  @Test func draftForTheSameKeyReturnsTheSameObject() {
    let drafts = MessageDrafts(folder: folder)

    let first = drafts.draft(for: "a")
    let second = drafts.draft(for: "a")

    #expect(first === second)
  }

  @Test func draftForDifferentKeysReturnsDifferentObjects() {
    let drafts = MessageDrafts(folder: folder)

    let a = drafts.draft(for: "a")
    let b = drafts.draft(for: "b")

    #expect(a !== b)
  }

  @Test func textSetOnOneKeyStaysOnThatKey() {
    let drafts = MessageDrafts(folder: folder)

    drafts.draft(for: "a").text = "for a"
    drafts.draft(for: "b").text = "for b"

    #expect(drafts.draft(for: "a").text == "for a")
    #expect(drafts.draft(for: "b").text == "for b")
  }

  @Test func imagesAddedOnOneKeyStayOnThatKey() throws {
    let drafts = MessageDrafts(folder: folder)

    drafts.draft(for: "a").add(paths: [try file("shot.png")])

    #expect(drafts.draft(for: "a").images.map(\.name) == ["shot.png"])
    #expect(drafts.draft(for: "b").images.isEmpty)
  }

  @Test func aNewKeyStartsWithAnEmptyDraft() {
    let drafts = MessageDrafts(folder: folder)
    drafts.draft(for: "a").text = "for a"

    let draft = drafts.draft(for: "b")

    #expect(draft.isEmpty)
  }

  // MARK: submit(_:to:) through the store

  @Test func successfulSendClearsTheStoredDraft() async {
    let model = offlineModel()
    model.send = { _, _ in .null }
    let drafts = MessageDrafts(folder: folder)
    drafts.draft(for: "a").text = "hello"

    drafts.draft(for: "a").submit("a", to: model)
    await settle { drafts.draft(for: "a").text.isEmpty }

    #expect(drafts.draft(for: "a").text.isEmpty)
  }

  @Test func failedSendKeepsTheStoredDraft() async {
    let model = offlineModel()
    model.send = { _, _ in throw Boom() }
    let drafts = MessageDrafts(folder: folder)
    drafts.draft(for: "a").text = "hello"

    drafts.draft(for: "a").submit("a", to: model)
    await settle { model.actionError != nil }

    #expect(model.actionError != nil)
    #expect(drafts.draft(for: "a").text == "hello")
  }

  @Test func successfulSendLeavesOtherKeysAlone() async {
    let model = offlineModel()
    model.send = { _, _ in .null }
    let drafts = MessageDrafts(folder: folder)
    drafts.draft(for: "a").text = "hello"
    drafts.draft(for: "b").text = "hello"

    drafts.draft(for: "a").submit("a", to: model)
    await settle { drafts.draft(for: "a").text.isEmpty }

    #expect(drafts.draft(for: "b").text == "hello")
  }

  // MARK: escape(at:) and disarmEscape()

  @Test func firstEscapeOnADraftKeepsItAndPassesTheKeyOn() {
    let draft = MessageField.Draft()
    draft.text = "hello"

    let handled = draft.escape(at: t0)

    #expect(!handled)
    #expect(draft.text == "hello")
  }

  @Test func firstEscapeOnADraftShowsTheHint() {
    let draft = MessageField.Draft()
    draft.text = "hello"

    _ = draft.escape(at: t0)

    #expect(draft.escapeHint)
  }

  @Test func secondEscapeInsideTheWindowClearsTheText() {
    let draft = MessageField.Draft()
    draft.text = "hello"
    _ = draft.escape(at: t0)

    let handled = draft.escape(at: t0.addingTimeInterval(0.5))

    #expect(handled)
    #expect(draft.text.isEmpty)
    #expect(!draft.escapeHint)
  }

  @Test func secondEscapeInsideTheWindowClearsTheImagesAndTheError() throws {
    let draft = MessageField.Draft()
    draft.text = "look"
    draft.add(paths: [try file("a.png"), try file("b.gif", Self.gif)])
    draft.error = "notes.png isn't an image."
    _ = draft.escape(at: t0)

    _ = draft.escape(at: t0.addingTimeInterval(0.5))

    #expect(draft.images.isEmpty)
    #expect(draft.error == nil)
  }

  @Test func doubleEscapeClearsADraftThatHasOnlyImages() throws {
    let draft = MessageField.Draft()
    draft.add(paths: [try file("a.png")])

    let first = draft.escape(at: t0)
    let second = draft.escape(at: t0.addingTimeInterval(0.5))

    #expect(!first)
    #expect(second)
    #expect(draft.images.isEmpty)
  }

  @Test func singleEscapeKeepsTheImages() throws {
    let draft = MessageField.Draft()
    draft.add(paths: [try file("a.png")])

    _ = draft.escape(at: t0)

    #expect(draft.images.map(\.name) == ["a.png"])
  }

  @Test func lateSecondEscapeKeepsTheDraft() {
    let draft = MessageField.Draft()
    draft.text = "hello"
    _ = draft.escape(at: t0)

    let handled = draft.escape(at: t0.addingTimeInterval(1.5))

    #expect(!handled)
    #expect(draft.text == "hello")
    #expect(draft.escapeHint)
  }

  @Test func lateSecondEscapeRearmsSoAThirdEscapeClears() {
    let draft = MessageField.Draft()
    draft.text = "hello"
    _ = draft.escape(at: t0)
    _ = draft.escape(at: t0.addingTimeInterval(1.5))

    let handled = draft.escape(at: t0.addingTimeInterval(2.0))

    #expect(handled)
    #expect(draft.text.isEmpty)
  }

  @Test func disarmEscapeHidesTheHint() {
    let draft = MessageField.Draft()
    draft.text = "hello"
    _ = draft.escape(at: t0)

    draft.disarmEscape()

    #expect(!draft.escapeHint)
  }

  @Test func disarmEscapeBetweenTwoEscapesKeepsTheDraft() {
    let draft = MessageField.Draft()
    draft.text = "hello"
    _ = draft.escape(at: t0)
    draft.disarmEscape()

    let handled = draft.escape(at: t0.addingTimeInterval(0.5))

    #expect(!handled)
    #expect(draft.text == "hello")
    #expect(draft.escapeHint)
  }

  @Test func disarmEscapeBetweenEscapesRequiresTwoMoreEscapesToClear() {
    let draft = MessageField.Draft()
    draft.text = "hello"
    _ = draft.escape(at: t0)
    draft.disarmEscape()
    _ = draft.escape(at: t0.addingTimeInterval(0.2))

    let handled = draft.escape(at: t0.addingTimeInterval(0.4))

    #expect(handled)
    #expect(draft.text.isEmpty)
  }

  @Test(arguments: ["", "  \n\t"])
  func escapeOnAnEmptyDraftDoesNotArm(text: String) {
    let draft = MessageField.Draft()
    draft.text = text

    let first = draft.escape(at: t0)
    let second = draft.escape(at: t0.addingTimeInterval(0.5))

    #expect(!first)
    #expect(!second)
    #expect(!draft.escapeHint)
  }

  @Test func escapeOnAnEmptyDraftDoesNotArmForTextTypedLater() {
    let draft = MessageField.Draft()
    _ = draft.escape(at: t0)
    draft.text = "hello"

    let handled = draft.escape(at: t0.addingTimeInterval(0.5))

    #expect(!handled)
    #expect(draft.text == "hello")
  }

  @Test func escapeAfterAClearDoesNotArm() {
    let draft = MessageField.Draft()
    draft.text = "hello"
    _ = draft.escape(at: t0)
    _ = draft.escape(at: t0.addingTimeInterval(0.5))

    let handled = draft.escape(at: t0.addingTimeInterval(0.7))

    #expect(!handled)
    #expect(!draft.escapeHint)
  }

  // MARK: key(for:)

  @Test func keyForAWorkSessionIsItsId() {
    #expect(MessageDrafts.key(for: needsItem("s1")) == "s1")
  }

  @Test func keyForTheManagerIsItsId() {
    #expect(MessageDrafts.key(for: needsItem("m", manager: true)) == "m")
  }

  @Test func keyForAGroupChatNamesTheGroup() {
    #expect(MessageDrafts.key(for: chatItem("c1", group: "g1")) == "group:g1")
  }

  @Test func keyForASessionWithChatSetNamesTheGroupWhateverItsKind() {
    var session = needsItem("c1")
    session.chat = "g1"

    #expect(MessageDrafts.key(for: session) == "group:g1")
  }

  @Test func keysForTwoChatsOfTheSameGroupAreEqual() {
    let first = MessageDrafts.key(for: chatItem("c1", group: "g1"))
    let second = MessageDrafts.key(for: chatItem("c2", group: "g1"))

    #expect(first == second)
  }

  @Test func keysForChatsOfDifferentGroupsDiffer() {
    let first = MessageDrafts.key(for: chatItem("c1", group: "g1"))
    let second = MessageDrafts.key(for: chatItem("c1", group: "g2"))

    #expect(first != second)
  }

  // MARK: prune(keeping:)

  @Test func pruneDropsTheDraftOfARemovedSession() {
    let drafts = MessageDrafts(folder: folder)
    let removed = drafts.draft(for: "a")
    removed.text = "for a"

    drafts.prune(keeping: ["b"])

    #expect(drafts.draft(for: "a") !== removed)
    #expect(drafts.draft(for: "a").isEmpty)
  }

  @Test func pruneKeepsTheDraftsOfTheKeptKeys() {
    let drafts = MessageDrafts(folder: folder)
    drafts.draft(for: "a").text = "for a"
    let kept = drafts.draft(for: "b")
    kept.text = "for b"
    let group = drafts.draft(for: "group:g1")
    group.text = "for the group"

    drafts.prune(keeping: ["b", "group:g1"])

    #expect(drafts.draft(for: "b") === kept)
    #expect(drafts.draft(for: "b").text == "for b")
    #expect(drafts.draft(for: "group:g1") === group)
  }

  @Test func pruneWithAnEmptySetDropsEveryDraft() {
    let drafts = MessageDrafts(folder: folder)
    drafts.draft(for: "a").text = "for a"
    drafts.draft(for: "b").text = "for b"

    drafts.prune(keeping: [])

    #expect(drafts.draft(for: "a").isEmpty)
    #expect(drafts.draft(for: "b").isEmpty)
  }

  @Test func pruneThenSaveDeletesThePrunedDraftsImages() throws {
    let drafts = MessageDrafts(folder: folder)
    drafts.draft(for: "a").add(paths: [try file("a.png")])
    drafts.draft(for: "b").add(paths: [try file("b.gif", Self.gif)])
    drafts.saveNow()

    drafts.prune(keeping: ["b"])
    drafts.saveNow()

    let kept = try #require(drafts.draft(for: "b").images.first)
    #expect(try imageFiles().count == 1)
    #expect(try imageFiles().first?.hasPrefix(kept.id.uuidString) == true)
  }

  @Test func pruneThenSaveLeavesNoDraftToReload() throws {
    let drafts = MessageDrafts(folder: folder)
    drafts.draft(for: "removed-session").text = "for a"
    drafts.draft(for: "b").text = "for b"
    drafts.saveNow()

    drafts.prune(keeping: ["b"])
    drafts.saveNow()
    let reloaded = MessageDrafts(folder: folder)

    #expect(reloaded.draft(for: "removed-session").isEmpty)
    #expect(reloaded.draft(for: "b").text == "for b")
  }

  // MARK: saveNow() and loading

  @Test(arguments: [
    "hello",
    "line one\nline two\n",
    "quote \" backslash \\ slash / tab \t",
    "{\"text\": \"not a draft\"}",
    "null",
    "42",
    "emoji 👋 and accents ü é",
    "  padded  ",
  ])
  func saveThenReloadKeepsTheText(text: String) {
    let drafts = MessageDrafts(folder: folder)
    drafts.draft(for: "a").text = text

    drafts.saveNow()
    let reloaded = MessageDrafts(folder: folder)

    #expect(reloaded.draft(for: "a").text == text)
  }

  @Test(arguments: ["a", "group:g1", "3F2504E0-4F89-11D3-9A0C-0305E82C3301", "group:with spaces/and slash"])
  func saveThenReloadKeepsTheKey(key: String) {
    let drafts = MessageDrafts(folder: folder)
    drafts.draft(for: key).text = "hello"

    drafts.saveNow()
    let reloaded = MessageDrafts(folder: folder)

    #expect(reloaded.draft(for: key).text == "hello")
  }

  @Test func saveThenReloadKeepsTheImagesNamesAndData() throws {
    let drafts = MessageDrafts(folder: folder)
    drafts.draft(for: "a").text = "look"
    drafts.draft(for: "a").add(paths: [try file("a.png"), try file("b.gif", Self.gif)])

    drafts.saveNow()
    let reloaded = MessageDrafts(folder: folder)

    let images = reloaded.draft(for: "a").images
    #expect(images.map(\.name) == ["a.png", "b.gif"])
    #expect(images.map(\.data) == [Self.png, Self.gif])
  }

  @Test func saveThenReloadKeepsADraftThatHasOnlyImages() throws {
    let drafts = MessageDrafts(folder: folder)
    drafts.draft(for: "a").add(paths: [try file("a.png")])

    drafts.saveNow()
    let reloaded = MessageDrafts(folder: folder)

    #expect(reloaded.draft(for: "a").text.isEmpty)
    #expect(reloaded.draft(for: "a").images.map(\.data) == [Self.png])
  }

  @Test func saveThenReloadKeepsEachKeysImagesApart() throws {
    let drafts = MessageDrafts(folder: folder)
    drafts.draft(for: "a").add(paths: [try file("a.png")])
    drafts.draft(for: "group:g1").add(paths: [try file("b.gif", Self.gif)])

    drafts.saveNow()
    let reloaded = MessageDrafts(folder: folder)

    #expect(reloaded.draft(for: "a").images.map(\.name) == ["a.png"])
    #expect(reloaded.draft(for: "group:g1").images.map(\.name) == ["b.gif"])
  }

  @Test func saveWritesOneFilePerImageNamedByItsId() throws {
    let drafts = MessageDrafts(folder: folder)
    drafts.draft(for: "a").add(paths: [try file("a.png"), try file("b.gif", Self.gif)])

    drafts.saveNow()

    let ids = drafts.draft(for: "a").images.map(\.id.uuidString)
    let files = try imageFiles()
    #expect(files.count == 2)
    for id in ids { #expect(files.contains { $0.hasPrefix(id) }) }
  }

  @Test func saveWritesTheImageDataIntoItsFile() throws {
    let drafts = MessageDrafts(folder: folder)
    drafts.draft(for: "a").add(paths: [try file("b.gif", Self.gif)])

    drafts.saveNow()

    let name = try #require(try imageFiles().first)
    #expect(FileManager.default.contents(atPath: "\(folder)/\(name)") == Self.gif)
  }

  @Test func saveTwiceThenReloadKeepsTheImages() throws {
    let drafts = MessageDrafts(folder: folder)
    drafts.draft(for: "a").add(paths: [try file("a.png")])
    let ids = drafts.draft(for: "a").images.map(\.id)
    drafts.saveNow()
    let second = MessageDrafts(folder: folder)

    second.saveNow()
    let third = MessageDrafts(folder: folder)

    #expect(third.draft(for: "a").images.map(\.name) == ["a.png"])
    #expect(third.draft(for: "a").images.map(\.data) == [Self.png])
    #expect(third.draft(for: "a").images.map(\.id) == ids)
    #expect(try imageFiles().count == 1)
  }

  @Test func saveDoesNotWriteAnEmptyDraft() throws {
    let drafts = MessageDrafts(folder: folder)
    _ = drafts.draft(for: "never-typed-in")
    drafts.draft(for: "b").text = "for b"

    drafts.saveNow()

    #expect(!draftsJSON().contains("never-typed-in"))
    #expect(draftsJSON().contains("for b"))
    #expect(try imageFiles().isEmpty)
  }

  @Test func clearedDraftThenSaveLeavesNoImageFileAndNoEntry() throws {
    let drafts = MessageDrafts(folder: folder)
    let draft = drafts.draft(for: "session-cleared")
    draft.text = "look"
    draft.add(paths: [try file("a.png")])
    drafts.saveNow()
    _ = draft.escape(at: t0)
    _ = draft.escape(at: t0.addingTimeInterval(0.5))

    drafts.saveNow()

    #expect(try imageFiles().isEmpty)
    #expect(!draftsJSON().contains("session-cleared"))
    #expect(MessageDrafts(folder: folder).draft(for: "session-cleared").isEmpty)
  }

  @Test func removedImageThenSaveDeletesOnlyThatImagesFile() throws {
    let drafts = MessageDrafts(folder: folder)
    let draft = drafts.draft(for: "a")
    draft.text = "look"
    draft.add(paths: [try file("a.png"), try file("b.gif", Self.gif)])
    drafts.saveNow()
    let removed = try #require(draft.images.first { $0.name == "a.png" })

    draft.remove(removed.id)
    drafts.saveNow()

    let files = try imageFiles()
    #expect(files.count == 1)
    #expect(!files.contains { $0.hasPrefix(removed.id.uuidString) })
    #expect(MessageDrafts(folder: folder).draft(for: "a").images.map(\.name) == ["b.gif"])
  }

  @Test func saveDeletesAnImageFileThatNoDraftNames() throws {
    let stray = "\(folder)/\(UUID().uuidString)"
    try Self.png.write(to: URL(fileURLWithPath: stray))
    let drafts = MessageDrafts(folder: folder)
    drafts.draft(for: "a").text = "hello"

    drafts.saveNow()

    #expect(!FileManager.default.fileExists(atPath: stray))
  }

  @Test func saveAfterASuccessfulSendLeavesNoDraftToReload() async throws {
    let model = offlineModel()
    model.send = { _, _ in .null }
    let drafts = MessageDrafts(folder: folder)
    let draft = drafts.draft(for: "a")
    draft.text = "look"
    draft.add(paths: [try file("a.png")])
    drafts.saveNow()

    draft.submit("a", to: model)
    await settle { draft.isEmpty }
    drafts.saveNow()

    #expect(try imageFiles().isEmpty)
    #expect(MessageDrafts(folder: folder).draft(for: "a").isEmpty)
  }

  @Test func anEditSavesWithoutSaveNow() async {
    let drafts = MessageDrafts(folder: folder, saveDelay: 0.01)

    drafts.draft(for: "a").text = "typed"
    await settle { self.draftsJSON().contains("typed") }

    #expect(draftsJSON().contains("typed"))
  }

  @Test func anEditToALoadedDraftSavesWithoutSaveNow() async {
    let first = MessageDrafts(folder: folder)
    first.draft(for: "a").text = "saved"
    first.saveNow()
    let drafts = MessageDrafts(folder: folder, saveDelay: 0.01)

    drafts.draft(for: "a").text = "edited"
    await settle { self.draftsJSON().contains("edited") }

    #expect(draftsJSON().contains("edited"))
  }

  @Test func aPruneSavesWithoutSaveNow() async {
    let drafts = MessageDrafts(folder: folder, saveDelay: 0.01)
    drafts.draft(for: "a").text = "for a"
    drafts.draft(for: "b").text = "for b"
    drafts.saveNow()

    drafts.prune(keeping: ["b"])
    await settle { !self.draftsJSON().contains("for a") }

    #expect(!draftsJSON().contains("for a"))
    #expect(draftsJSON().contains("for b"))
  }

  @Test func loadSkipsAMissingImageFileAndKeepsTheRest() throws {
    let drafts = MessageDrafts(folder: folder)
    let draft = drafts.draft(for: "a")
    draft.text = "look"
    draft.add(paths: [try file("a.png"), try file("b.gif", Self.gif)])
    drafts.saveNow()
    try FileManager.default.removeItem(atPath: "\(folder)/\(draft.images[0].id.uuidString)")

    let reloaded = MessageDrafts(folder: folder).draft(for: "a")

    #expect(reloaded.text == "look")
    #expect(reloaded.images.map(\.name) == ["b.gif"])
  }

  @Test func loadOfAnUndecodableIndexLoadsNoDrafts() throws {
    try Data("not json".utf8).write(to: URL(fileURLWithPath: "\(folder)/drafts.json"))

    let drafts = MessageDrafts(folder: folder)

    #expect(drafts.draft(for: "a").isEmpty)
  }

  @Test func storeOnAMissingFolderLoadsNoDrafts() {
    let drafts = MessageDrafts(folder: "\(root)/missing")

    #expect(drafts.draft(for: "a").isEmpty)
  }

  @Test func saveCreatesTheFolderAndItsParentForTheUserOnly() throws {
    let home = "\(root)/home"
    let drafts = MessageDrafts(folder: "\(home)/drafts")
    drafts.draft(for: "a").text = "secret"

    drafts.saveNow()

    for path in [home, "\(home)/drafts"] {
      let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
      #expect(mode == 0o700)
    }
  }

  @Test func storeOnAnEmptyFolderLoadsNoDrafts() {
    let drafts = MessageDrafts(folder: folder)

    #expect(drafts.draft(for: "a").isEmpty)
    #expect(drafts.draft(for: "group:g1").isEmpty)
  }

  @Test func saveOfAnEmptyStoreThenReloadLoadsNoDrafts() throws {
    MessageDrafts(folder: folder).saveNow()

    let reloaded = MessageDrafts(folder: folder)

    #expect(reloaded.draft(for: "a").isEmpty)
    #expect(try imageFiles().isEmpty)
  }
}

@MainActor
@Suite struct BoardModelMessageDrafts {
  @Test func aRefreshDropsTheDraftOfARemovedSession() {
    let model = appliedModel([needsItem("a"), needsItem("b"), chatItem("c", group: "g")])
    model.messageDraft(for: needsItem("a")).text = "kept"
    model.messageDraft(for: needsItem("b")).text = "removed"
    model.messageDraft(for: chatItem("c", group: "g")).text = "chat"
    model.apply(.success([needsItem("a"), chatItem("c", group: "g")]), followups: nil)
    #expect(model.messageDraft(for: needsItem("a")).text == "kept")
    #expect(model.messageDraft(for: needsItem("b")).text.isEmpty)
    #expect(model.messageDraft(for: chatItem("c", group: "g")).text == "chat")
  }

  @Test func aFailedRefreshKeepsEveryDraft() {
    let model = appliedModel([needsItem("a")])
    model.messageDraft(for: needsItem("a")).text = "kept"
    model.apply(.failure(Boom()), followups: nil)
    #expect(model.messageDraft(for: needsItem("a")).text == "kept")
  }

  @Test func twoChatSessionsOfOneGroupShareOneDraft() {
    let model = appliedModel([chatItem("c", group: "g")])
    #expect(model.messageDraft(for: chatItem("c", group: "g")) === model.messageDraft(for: chatItem("d", group: "g")))
  }
}
