import Foundation
import Testing

@testable import SwitchboardCore

/// Fixtures/SkillListing holds `skill_listing` lines that Claude Code 2.1.318
/// and 2.1.322 wrote, trimmed to a few items. manager-launches.jsonl keeps a
/// constructed line order whose timestamps are out of order, because the fold
/// goes by line order. probe-repo/dot-claude holds the files that
/// probe-listing.jsonl was made from. Tests copy it to a temporary folder as
/// `.claude`.
private let skillListingFolder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
  .appendingPathComponent("Fixtures/SkillListing")

private func listingFixture(_ name: String) -> String {
  skillListingFolder.appendingPathComponent(name).path
}

private func fixtureLines(_ name: String) throws -> [String] {
  try String(contentsOfFile: listingFixture(name), encoding: .utf8).split(separator: "\n").map(String.init)
}

/// The listing items of one line of a fixture.
private func fixtureItems(_ name: String, line: Int = 0) throws -> [SlashCommand] {
  let object = try #require(JSON.parse(try fixtureLines(name)[line]))
  return SkillListing.items(try #require(object["attachment"]))
}

/// A `skill_listing` attachment with the names and the Markdown content.
private func attachment(_ names: [String], _ content: String, initial: Bool = true) -> JSON {
  [
    "type": "skill_listing", "content": .string(content), "skillCount": .number(Double(names.count)),
    "isInitial": .bool(initial), "names": .array(names.map(JSON.string)),
  ]
}

/// A transcript line that holds the attachment.
private func listingLine(_ attachment: JSON, sidechain: Bool = false) -> String {
  JSON.object(["type": "attachment", "isSidechain": .bool(sidechain), "attachment": attachment]).text
}

private func row(_ name: String, in commands: [SlashCommand]?) -> SlashCommand? {
  commands?.first { $0.name == name }
}

private func names(_ commands: [SlashCommand]?) -> Set<String> { Set((commands ?? []).map(\.name)) }

/// The commands by name, so that two paths compare without their order.
private func keyed(_ commands: [SlashCommand]?) -> [String: SlashCommand]? {
  commands.map { Dictionary($0.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first }) }
}

private func write(_ text: String, to path: String) throws {
  try FileManager.default.createDirectory(
    atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
  try text.write(toFile: path, atomically: true, encoding: .utf8)
}

private func append(_ text: String, to path: String) throws {
  let handle = try #require(FileHandle(forWritingAtPath: path))
  defer { try? handle.close() }
  try handle.seekToEnd()
  try handle.write(contentsOf: Data(text.utf8))
}

private func fileSize(_ path: String) throws -> UInt64 {
  try #require((try FileManager.default.attributesOfItem(atPath: path))[.size] as? UInt64)
}

/// The lines, each ended by a new line.
private func joined(_ lines: some Sequence<String>) -> String { lines.map { $0 + "\n" }.joined() }

/// A read of the whole transcript into a new state.
private func freshRead(_ path: String, on machine: any Machine = LocalMachine()) -> SkillListing.State {
  var state = SkillListing.State()
  _ = SkillListing.read(path, into: &state, on: machine)
  return state
}

/// A read that continues from the state's offset.
private func readOn(_ path: String, _ state: inout SkillListing.State, on machine: any Machine = LocalMachine()) {
  let offset = state.offset
  _ = SkillListing.read(path, from: offset, into: &state, on: machine)
}

/// A skill file with frontmatter.
private func skillFile(_ name: String, _ description: String, _ flags: String...) -> String {
  (["---", "name: \(name)", "description: \(description)"] + flags + ["---", "Say hi.", ""]).joined(separator: "\n")
}

/// A temporary account folder and a cwd, optionally holding a copy of
/// probe-repo/dot-claude as `.claude`.
private struct Folders {
  let root: String
  var account: String { "\(root)/account" }
  var cwd: String { "\(root)/repo" }

  init(probe: Bool) throws {
    root = try tempFolder()
    try FileManager.default.createDirectory(atPath: "\(root)/account", withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: "\(root)/repo", withIntermediateDirectories: true)
    if probe {
      try FileManager.default.copyItem(
        atPath: listingFixture("probe-repo/dot-claude"), toPath: "\(root)/repo/.claude")
    }
  }

  func remove() { try? FileManager.default.removeItem(atPath: root) }

  func scan() -> [ScannedSkill] { SkillFolders.scan(account: account, cwd: cwd, on: LocalMachine()) }

  /// The rows for the listing, or for the scan alone when `listing` is nil.
  func rows(listing: [SlashCommand]?) -> [SlashCommand] {
    SlashCommands.merge(
      listing: listing, scanned: scan(), overrides: SkillFolders.overrides(account: account, on: LocalMachine()))
  }
}

/// The rows that are not built-ins.
private func own(_ rows: [SlashCommand]) -> [SlashCommand] { rows.filter { $0.source != .builtIn } }

private let builtInNames = Set(SlashCommand.builtIns.map(\.name))

/// Forwards to this Mac and counts the bytes that `read` returns.
private final class CountingMachine: Machine, @unchecked Sendable {
  private let local = LocalMachine()
  private let lock = NSLock()
  private var count = 0

  var bytesRead: Int {
    get { lock.withLock { count } }
    set { lock.withLock { count = newValue } }
  }

  func run(
    _ executable: String, _ args: [String], env: [String: String]?, input: Data?, timeout: Double?
  ) throws -> CommandResult {
    try local.run(executable, args, env: env, input: input, timeout: timeout)
  }

  func read(_ path: String, from offset: UInt64, count: Int?) -> Data? {
    let data = local.read(path, from: offset, count: count)
    lock.withLock { self.count += data?.count ?? 0 }
    return data
  }

  func size(_ path: String) -> UInt64? { local.size(path) }
  func exists(_ path: String) -> Bool { local.exists(path) }
  func isFolder(_ path: String) -> Bool { local.isFolder(path) }
  func modified(_ path: String) -> Date? { local.modified(path) }
  func list(_ folder: String) -> [String] { local.list(folder) }
  func createFolder(_ path: String) throws { try local.createFolder(path) }
  func signal(_ pid: Int, _ signal: Int32) { local.signal(pid, signal) }
}

/// Forwards to this Mac, but reports `staleSize` as every file's size while
/// it is set, as a size read before the file grew does.
private final class StaleSizeMachine: Machine, @unchecked Sendable {
  private let local = LocalMachine()
  private let lock = NSLock()
  private var stale: UInt64?

  init(size: UInt64) { stale = size }

  var staleSize: UInt64? {
    get { lock.withLock { stale } }
    set { lock.withLock { stale = newValue } }
  }

  func run(
    _ executable: String, _ args: [String], env: [String: String]?, input: Data?, timeout: Double?
  ) throws -> CommandResult {
    try local.run(executable, args, env: env, input: input, timeout: timeout)
  }

  func read(_ path: String, from offset: UInt64, count: Int?) -> Data? { local.read(path, from: offset, count: count) }
  func size(_ path: String) -> UInt64? { staleSize ?? local.size(path) }
  func exists(_ path: String) -> Bool { local.exists(path) }
  func isFolder(_ path: String) -> Bool { local.isFolder(path) }
  func modified(_ path: String) -> Date? { local.modified(path) }
  func list(_ folder: String) -> [String] { local.list(folder) }
  func createFolder(_ path: String) throws { try local.createFolder(path) }
  func signal(_ pid: Int, _ signal: Int32) { local.signal(pid, signal) }
}

/// Forwards to this Mac, but returns nil for each read whose offset and count
/// `failsRead` accepts, and for every size while `failsSize` is true, as a
/// dropped SSH connection does.
private final class FailingMachine: Machine, @unchecked Sendable {
  private let local = LocalMachine()
  private let lock = NSLock()
  private var readRule: (@Sendable (UInt64, Int?) -> Bool)?
  private var sizeRule = false

  init(failsRead: (@Sendable (UInt64, Int?) -> Bool)? = nil, failsSize: Bool = false) {
    readRule = failsRead
    sizeRule = failsSize
  }

  /// Ends every failure.
  func heal() {
    lock.withLock {
      readRule = nil
      sizeRule = false
    }
  }

  func run(
    _ executable: String, _ args: [String], env: [String: String]?, input: Data?, timeout: Double?
  ) throws -> CommandResult {
    try local.run(executable, args, env: env, input: input, timeout: timeout)
  }

  func read(_ path: String, from offset: UInt64, count: Int?) -> Data? {
    if let rule = lock.withLock({ readRule }), rule(offset, count) { return nil }
    return local.read(path, from: offset, count: count)
  }

  func size(_ path: String) -> UInt64? { lock.withLock { sizeRule } ? nil : local.size(path) }
  func exists(_ path: String) -> Bool { local.exists(path) }
  func isFolder(_ path: String) -> Bool { local.isFolder(path) }
  func modified(_ path: String) -> Date? { local.modified(path) }
  func list(_ folder: String) -> [String] { local.list(folder) }
  func createFolder(_ path: String) throws { try local.createFolder(path) }
  func signal(_ pid: Int, _ signal: Int32) { local.signal(pid, signal) }
}

// MARK: - Items

@Suite struct SkillListingItemTests {
  @Test func projectListingKeepsTheOrderOfTheNamesArray() throws {
    let items = try fixtureItems("project-listing.jsonl")

    #expect(
      items.map(\.name) == [
        "commit", "adding-activity-logging", "analyzing-insights-across-teams", "conventions", "claude-api",
        "anthropic-skills:computer-use", "anthropic-skills:pdf",
      ])
  }

  @Test(arguments: [
    "analyzing-insights-across-teams", "conventions", "anthropic-skills:computer-use", "anthropic-skills:pdf",
  ])
  func bareItemHasNoDescription(_ name: String) throws {
    let items = try fixtureItems("project-listing.jsonl")

    let item = try #require(row(name, in: items))

    #expect(item.description == nil)
  }

  @Test func describedItemKeepsItsDescription() throws {
    let items = try fixtureItems("project-listing.jsonl")

    #expect(
      row("commit", in: items)?.description == "Commit staged/unstaged changes with a well-crafted commit message.")
  }

  @Test func multiLineDescriptionKeepsOnlyItsFirstLine() throws {
    let items = try fixtureItems("project-listing.jsonl")

    #expect(
      row("claude-api", in: items)?.description
        == "Reference for the Claude API / Anthropic SDK — model ids, pricing, params, streaming, tool use, MCP, agents, caching, token counting, model migration."
    )
  }

  @Test func colonNameIsNotSplitAtItsColon() throws {
    let items = try fixtureItems("project-listing.jsonl")

    #expect(items.contains { $0.name == "anthropic-skills:pdf" })
    #expect(!items.contains { $0.name == "anthropic-skills" })
  }

  @Test func describedColonNameTakesTheTextAfterTheColonThatFollowsTheName() throws {
    let items = try fixtureItems("manager-launches.jsonl", line: 3)

    let item = try #require(row("anthropic-skills:computer-use", in: items))

    #expect(item.description?.hasPrefix("Read this skill before the first step") == true)
  }

  @Test func parentheticalPluginNameIsNotPartOfTheNameOrTheDescription() throws {
    let items = try fixtureItems("parenthetical-listing.jsonl")

    #expect(items.map(\.name) == ["commit", "tone-writing-style"])
    #expect(row("tone-writing-style", in: items)?.description?.hasPrefix("Write copy") == true)
  }

  @Test func everyItemComesFromTheListing() throws {
    let items = try fixtureItems("project-listing.jsonl")

    #expect(items.allSatisfy { $0.source == .listing })
  }

  @Test func descriptionKeepsTheColonsAfterTheFirst() {
    let items = SkillListing.items(attachment(["go"], "- go: Plan: then build."))

    #expect(items.map(\.description) == ["Plan: then build."])
  }

  @Test func colonNameWithADescriptionAndAParenthesis() {
    let items = SkillListing.items(
      attachment(["anthropic-skills:pdf"], "- anthropic-skills:pdf (anthropic-skills): Reads PDFs."))

    #expect(items.map(\.name) == ["anthropic-skills:pdf"])
    #expect(items.map(\.description) == ["Reads PDFs."])
  }

  @Test func continuationLineThatStartsWithADashAndNamesNoSkillIsDropped() {
    let items = SkillListing.items(
      attachment(["alpha", "beta"], "- alpha: First line.\n- see the docs for more\n- beta: Second."))

    #expect(items.map(\.name) == ["alpha", "beta"])
    #expect(items.map(\.description) == ["First line.", "Second."])
  }

  @Test func itemOfALongerNameIsNotTakenForTheShorterName() {
    let items = SkillListing.items(attachment(["go-fast", "go"], "- go-fast: Fast.\n- go: Slow."))

    #expect(row("go", in: items)?.description == "Slow.")
    #expect(row("go-fast", in: items)?.description == "Fast.")
  }

  @Test func itemOfALongerNameBeforeTheShorterOneDoesNotHideIt() {
    let items = SkillListing.items(attachment(["go"], "- go-fast: Not this one.\n- go: This one."))

    #expect(items.map(\.name) == ["go"])
    #expect(row("go", in: items)?.description == "This one.")
  }

  @Test func pluginItemWhoseNameStartsWithABareNameDoesNotHideTheBareItem() {
    let items = SkillListing.items(
      attachment(["code-review:code-review", "code-review"], "- code-review:code-review: A.\n- code-review: B."))

    #expect(row("code-review:code-review", in: items)?.description == "A.")
    #expect(row("code-review", in: items)?.description == "B.")
  }

  @Test func bareItemBeforeAPluginItemWhoseNameStartsWithItIsNotTakenForThePluginItem() {
    let items = SkillListing.items(
      attachment(["code-review", "code-review:code-review"], "- code-review: B.\n- code-review:code-review: A."))

    #expect(row("code-review:code-review", in: items)?.description == "A.")
    #expect(row("code-review", in: items)?.description == "B.")
  }

  @Test func bareColonPluginItemDoesNotHideTheBareItem() {
    let items = SkillListing.items(
      attachment(["code-review:code-review", "code-review"], "- code-review:code-review\n- code-review: B."))

    #expect(row("code-review:code-review", in: items)?.description == nil)
    #expect(row("code-review", in: items)?.description == "B.")
  }

  @Test func itemWithAColonAndNoDescriptionHasNoDescription() {
    let items = SkillListing.items(attachment(["foo", "bar"], "- foo:\n- bar: Bar."))

    #expect(items.map(\.description) == [nil, "Bar."])
  }

  @Test func nameWithNoItemLineIsListedWithoutADescription() {
    let items = SkillListing.items(attachment(["alpha", "missing"], "- alpha: First."))

    #expect(items.map(\.name) == ["alpha", "missing"])
    #expect(row("missing", in: items)?.description == nil)
  }
}

// MARK: - Fold

@Suite struct SkillListingFoldTests {
  /// The set that manager-launches.jsonl folds to: the second launch's
  /// initial listing and the delta after it.
  static let managerSet: Set<String> = ["commit", "go", "code-review", "claude-api", "explain-open"]

  @Test func managerLaunchesFoldToTheLastInitialListingAndTheDeltasAfterIt() {
    let state = freshRead(listingFixture("manager-launches.jsonl"))

    #expect(names(state.commands) == Self.managerSet)
  }

  @Test func foldNeverRepeatsAName() throws {
    let state = freshRead(listingFixture("manager-launches.jsonl"))

    let commands = try #require(state.commands)
    #expect(commands.count == Set(commands.map(\.name)).count)
  }

  @Test func goTakesItsDescriptionFromTheSecondLaunch() throws {
    let second = try fixtureItems("manager-launches.jsonl", line: 5)

    let state = freshRead(listingFixture("manager-launches.jsonl"))

    let expected = try #require(row("go", in: second)?.description)
    #expect(row("go", in: state.commands)?.description == expected)
  }

  @Test func readingUpToTheFirstUserLineGivesTheFirstLaunch() throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = "\(dir)/t.jsonl"
    try write(joined(try fixtureLines("manager-launches.jsonl").prefix(2)), to: path)
    let first = try fixtureItems("manager-launches.jsonl", line: 0)

    let state = freshRead(path)

    #expect(names(state.commands) == ["commit", "create-pr", "go", "sessions", "loop"])
    #expect(row("go", in: state.commands)?.description == row("go", in: first)?.description)
  }

  @Test func deltaUpsertsAChangedDescriptionAndAddsNewSkills() throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = "\(dir)/t.jsonl"
    try write(joined(try fixtureLines("manager-launches.jsonl").prefix(5)), to: path)
    let delta = try fixtureItems("manager-launches.jsonl", line: 2)

    let state = freshRead(path)

    #expect(
      names(state.commands) == [
        "commit", "create-pr", "go", "sessions", "loop", "code-review", "anthropic-skills:computer-use",
      ])
    #expect(row("go", in: state.commands)?.description == row("go", in: delta)?.description)
  }

  @Test func transcriptOfOnlyDeltasUsesTheDeltas() throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = "\(dir)/t.jsonl"
    let lines = try fixtureLines("manager-launches.jsonl")
    try write(joined([lines[2], lines[3]]), to: path)

    let state = freshRead(path)

    #expect(names(state.commands) == ["go", "code-review", "anthropic-skills:computer-use"])
  }

  @Test func transcriptWithoutAListingHasNoListing() throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = "\(dir)/t.jsonl"
    let lines = try fixtureLines("manager-launches.jsonl")
    try write(joined([lines[1], lines[4]]), to: path)

    let state = freshRead(path)

    #expect(state.commands == nil)
  }

  @Test func missingTranscriptHasNoListing() throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }

    let state = freshRead("\(dir)/missing.jsonl")

    #expect(state.commands == nil)
  }

  /// Lines after the last initial listing that hold the bytes
  /// `"skill_listing"` but are not listings of the main conversation.
  static let ignoredLines: [String] = [
    listingLine(attachment(["from-a-subagent"], "- from-a-subagent: A sidechain's listing."), sidechain: true),
    listingLine(
      attachment(["from-a-subagent-delta"], "- from-a-subagent-delta: A sidechain's delta.", initial: false),
      sidechain: true),
    #"{"type":"user","isSidechain":false,"message":{"role":"user","content":"skill_listing"}}"#,
    #"{"type":"user","isSidechain":false,"message":{"role":"user","content":"skill_listing"},"attachment":{"type":"skill_listing","content":"- from-a-user-line: Not a listing.","skillCount":1,"isInitial":true,"names":["from-a-user-line"]}}"#,
    #"{"type":"attachment","isSidechain":false,"attachment":{"type":"hook_additional_context","content":["skill_listing"]}}"#,
    #"{"type":"attachment","isSidechain":false,"attachment":{"type":"skill_listing","content":"- broken: Cut off.","isInitial":true,"names":["broken"]"#,
  ]

  @Test(arguments: ignoredLines)
  func lineThatIsNotAMainListingChangesNothingInAFreshRead(_ line: String) throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = "\(dir)/t.jsonl"
    try write(joined(try fixtureLines("manager-launches.jsonl") + [line]), to: path)

    let state = freshRead(path)

    #expect(keyed(state.commands) == keyed(freshRead(listingFixture("manager-launches.jsonl")).commands))
  }

  @Test(arguments: ignoredLines)
  func lineThatIsNotAMainListingChangesNothingInAReadFromTheOffset(_ line: String) throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = "\(dir)/t.jsonl"
    try write(joined(try fixtureLines("manager-launches.jsonl")), to: path)
    var state = freshRead(path)
    try append(line + "\n", to: path)

    readOn(path, &state)

    #expect(keyed(state.commands) == keyed(freshRead(listingFixture("manager-launches.jsonl")).commands))
  }

  @Test func freshReadStopsAtTheLastInitialListing() throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = "\(dir)/t.jsonl"
    let filler =
      #"{"type":"user","isSidechain":false,"message":{"role":"user","content":""#
      + String(repeating: "x", count: 1000) + #""}}"#
    try write(
      joined(Array(repeating: filler, count: 2000) + (try fixtureLines("probe-listing.jsonl"))), to: path)
    let machine = CountingMachine()

    let state = freshRead(path, on: machine)

    #expect(names(state.commands).contains("probe-default"))
    #expect(UInt64(machine.bytesRead) < (try fileSize(path)) / 2)
  }
}

// MARK: - Reads from an offset

@Suite struct SkillListingOffsetTests {
  @Test func freshReadOfWholeLinesEndsAtTheEndOfTheFile() throws {
    let state = freshRead(listingFixture("manager-launches.jsonl"))

    #expect(state.offset == (try fileSize(listingFixture("manager-launches.jsonl"))))
  }

  @Test func readFromTheOffsetAfterANewLaunchEqualsAFreshRead() throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = "\(dir)/t.jsonl"
    let lines = try fixtureLines("manager-launches.jsonl")
    try write(joined(lines.prefix(5)), to: path)
    var state = freshRead(path)
    try append(joined(lines.dropFirst(5)), to: path)

    readOn(path, &state)

    let fresh = freshRead(path)
    #expect(names(state.commands) == SkillListingFoldTests.managerSet)
    #expect(keyed(state.commands) == keyed(fresh.commands))
    #expect(state.offset == fresh.offset)
  }

  @Test func halfWrittenLineIsLeftForTheNextRead() throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = "\(dir)/t.jsonl"
    let lines = try fixtureLines("manager-launches.jsonl")
    let last = lines[6]
    let half = last.utf8.count / 2
    try write(joined(lines.prefix(6)), to: path)
    var state = freshRead(path)
    let before = state
    try append(String(decoding: Array(last.utf8.prefix(half)), as: UTF8.self), to: path)

    readOn(path, &state)

    #expect(keyed(state.commands) == keyed(before.commands))
    #expect(state.offset == before.offset)
  }

  @Test func halfWrittenLineIsFoldedOnceItsNewLineArrives() throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = "\(dir)/t.jsonl"
    let lines = try fixtureLines("manager-launches.jsonl")
    let last = Array(lines[6].utf8)
    let half = last.count / 2
    try write(joined(lines.prefix(6)), to: path)
    var state = freshRead(path)
    try append(String(decoding: last.prefix(half), as: UTF8.self), to: path)
    readOn(path, &state)
    try append(String(decoding: last.dropFirst(half), as: UTF8.self) + "\n", to: path)

    readOn(path, &state)

    let fresh = freshRead(path)
    #expect(names(state.commands).contains("explain-open"))
    #expect(keyed(state.commands) == keyed(fresh.commands))
    #expect(state.offset == (try fileSize(path)))
  }

  @Test func halfWrittenLineAtTheEndOfAFreshReadIsFoldedOnceItsNewLineArrives() throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = "\(dir)/t.jsonl"
    let lines = try fixtureLines("manager-launches.jsonl")
    let last = Array(lines[6].utf8)
    let half = last.count / 2
    let whole = joined(lines.prefix(6))
    try write(whole + String(decoding: last.prefix(half), as: UTF8.self), to: path)
    var state = freshRead(path)
    #expect(state.offset == UInt64(whole.utf8.count))
    #expect(!names(state.commands).contains("explain-open"))
    try append(String(decoding: last.dropFirst(half), as: UTF8.self) + "\n", to: path)

    readOn(path, &state)

    #expect(keyed(state.commands) == keyed(freshRead(path).commands))
  }

  @Test func fileThatShrankIsReadFromTheStart() throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = "\(dir)/t.jsonl"
    try write(joined(try fixtureLines("manager-launches.jsonl")), to: path)
    var state = freshRead(path)
    try write(joined(try fixtureLines("probe-listing.jsonl")), to: path)
    #expect((try fileSize(path)) < state.offset)

    readOn(path, &state)

    let fresh = freshRead(path)
    #expect(names(state.commands) == ["commit", "probe-default", "probe-model-only", "probe-cmd-plain"])
    #expect(keyed(state.commands) == keyed(fresh.commands))
    #expect(state.offset == fresh.offset)
  }

  @Test func listingThatArrivesAfterAReadWithoutOneIsFound() throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = "\(dir)/t.jsonl"
    let lines = try fixtureLines("manager-launches.jsonl")
    try write(joined([lines[1]]), to: path)
    var state = freshRead(path)
    #expect(state.commands == nil)
    try append(joined(try fixtureLines("probe-listing.jsonl")), to: path)

    readOn(path, &state)

    #expect(keyed(state.commands) == keyed(freshRead(path).commands))
    #expect(names(state.commands).contains("probe-default"))
  }

  @Test func freshReadStopsAtTheSizeItReadEvenWhenTheFileHasGrown() throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = "\(dir)/t.jsonl"
    let lines = try fixtureLines("manager-launches.jsonl")
    let before = joined(lines.prefix(6))
    try write(before + joined([lines[6]]), to: path)
    let machine = StaleSizeMachine(size: UInt64(before.utf8.count))

    var state = freshRead(path, on: machine)

    #expect(!names(state.commands).contains("explain-open"))
    #expect(state.offset == UInt64(before.utf8.count))
    machine.staleSize = nil
    readOn(path, &state, on: machine)
    #expect(names(state.commands).contains("explain-open"))
    #expect(keyed(state.commands) == keyed(freshRead(path).commands))
    #expect(state.offset == (try fileSize(path)))
  }

  @Test func readOfAnUnchangedTranscriptReadsNoBytes() throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = "\(dir)/t.jsonl"
    try write(joined(try fixtureLines("manager-launches.jsonl")), to: path)
    let machine = CountingMachine()
    var state = freshRead(path, on: machine)
    let before = state
    machine.bytesRead = 0

    readOn(path, &state, on: machine)

    #expect(machine.bytesRead == 0)
    #expect(keyed(state.commands) == keyed(before.commands))
  }
}

// MARK: - Failed reads

@Suite struct SkillListingFailedReadTests {
  static let filler =
    #"{"type":"user","isSidechain":false,"message":{"role":"user","content":""#
    + String(repeating: "x", count: 1000) + #""}}"#

  /// A transcript whose initial listing is more than one 64 KB chunk before
  /// the end, so that a fresh read needs more than one read of the machine.
  func farListing(in dir: String, tail: String = "") throws -> (path: String, size: UInt64) {
    let path = "\(dir)/t.jsonl"
    try write(
      joined((try fixtureLines("probe-listing.jsonl")) + Array(repeating: Self.filler, count: 200)) + tail, to: path)
    return (path, try fileSize(path))
  }

  @Test func freshReadWhoseWalkFailsBeforeTheListingIsReadAgainFromTheStart() throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let (path, size) = try farListing(in: dir)
    let machine = FailingMachine(failsRead: { offset, _ in offset < size - 70_000 })
    var state = SkillListing.State()

    let succeeded = SkillListing.read(path, into: &state, on: machine)

    #expect(!succeeded)
    #expect(state == SkillListing.State())
    machine.heal()
    #expect(SkillListing.read(path, from: state.offset, into: &state, on: machine))
    #expect(names(state.commands) == ["commit", "probe-default", "probe-model-only", "probe-cmd-plain"])
    #expect(keyed(state.commands) == keyed(freshRead(path).commands))
  }

  @Test func freshReadWhoseFirstChunkFailsBehindAHalfWrittenLineIsReadAgainFromTheStart() throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let (path, size) = try farListing(in: dir, tail: #"{"type":"user","#)
    let machine = FailingMachine(failsRead: { offset, count in
      count != 1 && offset + UInt64(count ?? 0) == size
    })
    var state = SkillListing.State()

    let succeeded = SkillListing.read(path, into: &state, on: machine)

    #expect(!succeeded)
    #expect(state == SkillListing.State())
    machine.heal()
    #expect(SkillListing.read(path, from: state.offset, into: &state, on: machine))
    #expect(keyed(state.commands) == keyed(freshRead(path).commands))
    #expect(state.offset == freshRead(path).offset)
  }

  @Test func freshReadWhoseLastByteFailsReportsTheFailure() throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let (path, _) = try farListing(in: dir)
    var state = SkillListing.State()

    let succeeded = SkillListing.read(path, into: &state, on: FailingMachine(failsRead: { _, count in count == 1 }))

    #expect(!succeeded)
    #expect(state == SkillListing.State())
  }

  @Test func readWhoseSizeFailsReportsTheFailure() throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let (path, _) = try farListing(in: dir)
    var state = SkillListing.State()

    let succeeded = SkillListing.read(path, into: &state, on: FailingMachine(failsSize: true))

    #expect(!succeeded)
    #expect(state == SkillListing.State())
  }

  @Test func readFromTheOffsetWhoseSizeFailsLeavesNoListing() throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let (path, _) = try farListing(in: dir)
    var state = freshRead(path)
    #expect(state.commands != nil)

    let succeeded = SkillListing.read(path, from: state.offset, into: &state, on: FailingMachine(failsSize: true))

    #expect(!succeeded)
    #expect(state == SkillListing.State())
  }

  @Test func readFromAnOffsetPastTheEndWhoseWalkFailsLeavesNoListing() throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let (path, size) = try farListing(in: dir)
    var state = freshRead(path)
    state.offset = size + 1

    let succeeded = SkillListing.read(
      path, from: state.offset, into: &state, on: FailingMachine(failsRead: { offset, _ in offset < size - 70_000 }))

    #expect(!succeeded)
    #expect(state == SkillListing.State())
  }

  @Test func readFromTheOffsetThatFailsKeepsTheStateAndTheOffset() throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = "\(dir)/t.jsonl"
    let lines = try fixtureLines("manager-launches.jsonl")
    try write(joined(lines.prefix(6)), to: path)
    var state = freshRead(path)
    let before = state
    try append(joined([lines[6]]), to: path)
    let machine = FailingMachine(failsRead: { offset, _ in offset >= before.offset })

    let succeeded = SkillListing.read(path, from: state.offset, into: &state, on: machine)

    #expect(!succeeded)
    #expect(state == before)
    machine.heal()
    #expect(SkillListing.read(path, from: state.offset, into: &state, on: machine))
    #expect(names(state.commands).contains("explain-open"))
    #expect(keyed(state.commands) == keyed(freshRead(path).commands))
  }

  @Test func readsThatNeedNoBytesOrFindNoWholeLineSucceed() throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = "\(dir)/t.jsonl"
    try write("", to: path)
    var state = SkillListing.State()
    #expect(SkillListing.read(path, into: &state))
    try write(joined(try fixtureLines("probe-listing.jsonl")), to: path)
    #expect(SkillListing.read(path, into: &state))
    #expect(SkillListing.read(path, from: state.offset, into: &state))
    try append(#"{"type":"user","#, to: path)
    #expect(SkillListing.read(path, from: state.offset, into: &state))
    #expect(names(state.commands).contains("probe-default"))
  }
}

// MARK: - Frontmatter and folders

@Suite struct SkillFolderScanTests {
  /// What the scan finds in a cwd whose `.claude` holds only the file at `relative`.
  func scanned(_ relative: String, _ text: String) throws -> [ScannedSkill] {
    let folders = try Folders(probe: false)
    defer { folders.remove() }
    try write(text, to: "\(folders.cwd)/.claude/\(relative)")
    return folders.scan()
  }

  @Test func blockScalarDescriptionIsItsFirstLine() throws {
    let found = try scanned(
      "skills/block/SKILL.md", "---\nname: block\ndescription: |\n  First line.\n  Second line.\n---\nSay hi.\n")

    #expect(found.map(\.description) == ["First line."])
  }

  @Test func quotedDescriptionLosesItsQuotes() throws {
    let found = try scanned(
      "skills/quoted/SKILL.md", "---\nname: quoted\ndescription: \"Deploys: the app, then waits.\"\n---\nSay hi.\n")

    #expect(found.map(\.description) == ["Deploys: the app, then waits."])
  }

  @Test func crlfLineEndsReadAsNewLines() throws {
    let found = try scanned(
      "skills/crlf/SKILL.md",
      "---\r\nname: crlf\r\ndescription: Uses CRLF line ends.\r\ndisable-model-invocation: true\r\n---\r\nSay hi.\r\n")

    let skill = try #require(found.first)
    #expect(skill.name == "crlf")
    #expect(skill.description == "Uses CRLF line ends.")
    #expect(skill.modelInvocable == false)
  }

  @Test func commandWithoutFrontmatterTakesItsFirstNonEmptyLine() throws {
    let found = try scanned("commands/plain.md", "\n\nRuns the plain command.\nSecond line.\n")

    #expect(found.map(\.description) == ["Runs the plain command."])
  }

  @Test func commandBodyBetweenTwoRulesIsNotFrontmatter() throws {
    let found = try scanned(
      "commands/ruled.md", "Runs the ruled command.\n---\nname: other\ndisable-model-invocation: true\n---\nMore.\n")

    let command = try #require(found.first)
    #expect(command.name == "ruled")
    #expect(command.description == "Runs the ruled command.")
    #expect(command.modelInvocable)
  }

  @Test func openingRuleWithoutAClosingOneIsNotFrontmatter() throws {
    let found = try scanned("skills/open/SKILL.md", "---\nname: other\ndisable-model-invocation: true\nSay hi.\n")

    let skill = try #require(found.first)
    #expect(skill.name == "open")
    #expect(skill.modelInvocable)
  }

  @Test func frontmatterWithoutADescriptionTakesTheFirstBodyLine() throws {
    let found = try scanned("skills/nodesc/SKILL.md", "---\nname: nodesc\n---\n\nUses the body.\nMore.\n")

    #expect(found.map(\.description) == ["Uses the body."])
  }

  @Test func nameInTheFrontmatterReplacesTheFolderName() throws {
    let found = try scanned("skills/folder-name/SKILL.md", skillFile("real-name", "Named in its frontmatter."))

    #expect(found.map(\.name) == ["real-name"])
  }

  @Test func skillWithoutANameIsNamedAfterItsFolder() throws {
    let found = try scanned("skills/folder-name/SKILL.md", "---\ndescription: No name.\n---\nSay hi.\n")

    #expect(found.map(\.name) == ["folder-name"])
  }

  @Test func byteOrderMarkBeforeTheFrontmatterIsIgnored() throws {
    let found = try scanned(
      "skills/bom/SKILL.md", "\u{FEFF}---\nname: bom\ndescription: Has a BOM.\nuser-invocable: false\n---\nSay hi.\n")

    #expect(found.map(\.description) == ["Has a BOM."])
    #expect(found.map(\.userInvocable) == [false])
  }

  @Test func commandIsNamedAfterItsFile() throws {
    let found = try scanned("commands/ship-it.md", "---\ndescription: Ships it.\n---\nSay hi.\n")

    #expect(found.map(\.name) == ["ship-it"])
  }

  @Test func commandIgnoresTheNameInItsFrontmatter() throws {
    let found = try scanned("commands/ship-it.md", "---\nname: launch\ndescription: Ships it.\n---\nSay hi.\n")

    #expect(found.map(\.name) == ["ship-it"])
  }

  @Test(arguments: ["false", "False", "FALSE"])
  func userInvocableFalseInAnyCaseHidesItFromTheUser(_ value: String) throws {
    let found = try scanned("skills/hidden/SKILL.md", skillFile("hidden", "Hidden.", "user-invocable: \(value)"))

    #expect(found.map(\.userInvocable) == [false])
  }

  @Test(arguments: ["true", "True", "TRUE"])
  func disableModelInvocationTrueInAnyCaseHidesItFromTheModel(_ value: String) throws {
    let found = try scanned(
      "skills/user-only/SKILL.md", skillFile("user-only", "User only.", "disable-model-invocation: \(value)"))

    #expect(found.map(\.modelInvocable) == [false])
  }

  @Test func skillWithoutFlagsIsInvocableByTheUserAndTheModel() throws {
    let found = try scanned("skills/plain/SKILL.md", skillFile("plain", "Plain."))

    let skill = try #require(found.first)
    #expect(skill.userInvocable)
    #expect(skill.modelInvocable)
  }

  @Test func scansTheSkillsAndCommandsOfTheAccountAndTheCwd() throws {
    let folders = try Folders(probe: false)
    defer { folders.remove() }
    try write(skillFile("account-skill", "A."), to: "\(folders.account)/skills/account-skill/SKILL.md")
    try write("Account command.\n", to: "\(folders.account)/commands/account-command.md")
    try write(skillFile("repo-skill", "R."), to: "\(folders.cwd)/.claude/skills/repo-skill/SKILL.md")
    try write("Repo command.\n", to: "\(folders.cwd)/.claude/commands/repo-command.md")

    let found = folders.scan()

    #expect(Set(found.map(\.name)) == ["account-skill", "account-command", "repo-skill", "repo-command"])
  }

  @Test func leavesOutTheFoldersThatAreNotScanned() throws {
    let folders = try Folders(probe: false)
    defer { folders.remove() }
    try write("Nested command.\n", to: "\(folders.cwd)/.claude/commands/sub/nested.md")
    try write("Account nested command.\n", to: "\(folders.account)/commands/sub/nested-account.md")
    try write("Not markdown.\n", to: "\(folders.cwd)/.claude/commands/notes.txt")
    try write("No SKILL.md here.\n", to: "\(folders.cwd)/.claude/skills/no-skill-file/README.md")
    try write(skillFile("below", "Below the cwd."), to: "\(folders.cwd)/sub/.claude/skills/below/SKILL.md")
    try write(skillFile("above", "Above the cwd."), to: "\(folders.root)/.claude/skills/above/SKILL.md")

    let found = folders.scan()

    #expect(found.isEmpty, "\(found.map(\.name))")
  }

  @Test func missingFoldersGiveNothing() throws {
    let folders = try Folders(probe: false)
    defer { folders.remove() }

    #expect(
      SkillFolders.scan(account: "\(folders.root)/no-account", cwd: "\(folders.root)/no-repo", on: LocalMachine())
        .isEmpty)
  }
}

// MARK: - Merge

@Suite struct SlashCommandMergeTests {
  static let probeTypeable: Set<String> = [
    "commit", "probe-default", "probe-cmd-plain", "probe-user-only", "probe-cmd-user-only",
  ]

  @Test func overlayOfTheProbeListsWhatTheUserCanType() throws {
    let folders = try Folders(probe: true)
    defer { folders.remove() }

    let rows = folders.rows(listing: try fixtureItems("probe-listing.jsonl"))

    #expect(names(own(rows)) == Self.probeTypeable)
  }

  @Test func overlayKeepsTheListingsSourceAndMarksScannedRows() throws {
    let folders = try Folders(probe: true)
    defer { folders.remove() }

    let rows = folders.rows(listing: try fixtureItems("probe-listing.jsonl"))

    #expect(row("commit", in: rows)?.source == .listing)
    #expect(row("probe-default", in: rows)?.source == .listing)
    #expect(row("probe-user-only", in: rows)?.source == .scan)
    #expect(row("probe-cmd-user-only", in: rows)?.source == .scan)
  }

  @Test func fallbackScanOfTheProbeListsTheSameRowsWithoutCommit() throws {
    let folders = try Folders(probe: true)
    defer { folders.remove() }

    let rows = folders.rows(listing: nil)

    #expect(names(own(rows)) == Self.probeTypeable.subtracting(["commit"]))
    #expect(own(rows).allSatisfy { $0.source == .scan })
  }

  @Test func overlayAndFallbackGiveTheSameDescriptionForEverySharedRow() throws {
    let folders = try Folders(probe: true)
    defer { folders.remove() }

    let overlay = own(folders.rows(listing: try fixtureItems("probe-listing.jsonl")))
    let fallback = own(folders.rows(listing: nil))

    let shared = names(overlay).intersection(names(fallback))
    #expect(shared == Self.probeTypeable.subtracting(["commit"]))
    for name in shared {
      #expect(row(name, in: overlay)?.description != nil, "\(name)")
      #expect(row(name, in: overlay)?.description == row(name, in: fallback)?.description, "\(name)")
    }
  }

  struct ParityCase: Sendable, CustomTestStringConvertible {
    let label: String
    let name: String
    /// The file's path under `.claude`.
    let file: String
    let text: String
    /// The text after `- <name>: ` that the listing shows for the file.
    let listed: String
    var testDescription: String { label }
  }

  static let parityCases: [ParityCase] = [
    ParityCase(
      label: "quoted with a colon", name: "quoted", file: "skills/quoted/SKILL.md",
      text: "---\nname: quoted\ndescription: \"Deploys: the app, then waits.\"\n---\nSay hi.\n",
      listed: "Deploys: the app, then waits."),
    ParityCase(
      label: "block scalar", name: "block", file: "skills/block/SKILL.md",
      text: "---\nname: block\ndescription: |\n  Reads the first line.\n  Not this one.\n---\nSay hi.\n",
      listed: "Reads the first line.\nNot this one."),
    ParityCase(
      label: "CRLF", name: "crlf", file: "skills/crlf/SKILL.md",
      text: "---\r\nname: crlf\r\ndescription: Uses CRLF line ends.\r\n---\r\nSay hi.\r\n",
      listed: "Uses CRLF line ends."),
    ParityCase(
      label: "escaped characters", name: "escaped", file: "skills/escaped/SKILL.md",
      text: "---\nname: escaped\ndescription: Says \"hi\" to C:\\temp and back\\slash.\n---\nSay hi.\n",
      listed: "Says \"hi\" to C:\\temp and back\\slash."),
    ParityCase(
      label: "number", name: "number", file: "skills/number/SKILL.md",
      text: "---\nname: number\ndescription: 42\n---\nSay hi.\n", listed: "42"),
    ParityCase(
      label: "command without frontmatter", name: "plain", file: "commands/plain.md",
      text: "Runs the plain command.\n", listed: "Runs the plain command."),
  ]

  @Test(arguments: parityCases)
  func overlayAndFallbackAgreeOnTheDescription(_ c: ParityCase) throws {
    let folders = try Folders(probe: false)
    defer { folders.remove() }
    try write(c.text, to: "\(folders.cwd)/.claude/\(c.file)")
    let listing = SkillListing.items(attachment([c.name], "- \(c.name): \(c.listed)"))

    let overlay = folders.rows(listing: listing)
    let fallback = folders.rows(listing: nil)

    let described = try #require(row(c.name, in: overlay)?.description)
    #expect(row(c.name, in: fallback)?.description == described)
  }

  @Test func overlayLeavesOutAScannedSkillThatTheListingLacks() throws {
    let folders = try Folders(probe: true)
    defer { folders.remove() }
    let listing = SkillListing.items(attachment(["commit"], "- commit: Commit."))

    let rows = folders.rows(listing: listing)

    #expect(row("probe-default", in: rows) == nil)
    #expect(row("probe-user-only", in: rows) != nil)
  }

  @Test func skillOverrideOffRemovesAScannedSkill() throws {
    let folders = try Folders(probe: true)
    defer { folders.remove() }
    try write(#"{"skillOverrides":{"probe-user-only":"off"}}"#, to: "\(folders.account)/settings.json")

    let overlay = folders.rows(listing: try fixtureItems("probe-listing.jsonl"))
    let fallback = folders.rows(listing: nil)

    #expect(row("probe-user-only", in: overlay) == nil)
    #expect(row("probe-user-only", in: fallback) == nil)
  }

  @Test func skillOverrideOffRemovesAListedSkill() throws {
    let folders = try Folders(probe: true)
    defer { folders.remove() }
    try write(#"{"skillOverrides":{"commit":"off"}}"#, to: "\(folders.account)/settings.json")

    let rows = folders.rows(listing: try fixtureItems("probe-listing.jsonl"))

    #expect(row("commit", in: rows) == nil)
    #expect(row("probe-default", in: rows) != nil)
  }

  @Test func skillOverrideUserInvocableOnlyAddsAScannedSkillThatTheListingLacks() throws {
    let folders = try Folders(probe: true)
    defer { folders.remove() }
    try write(#"{"skillOverrides":{"probe-default":"user-invocable-only"}}"#, to: "\(folders.account)/settings.json")
    let listing = SkillListing.items(attachment(["commit"], "- commit: Commit."))

    let rows = folders.rows(listing: listing)

    #expect(row("probe-default", in: rows)?.source == .scan)
    #expect(row("probe-default", in: rows)?.description == "Probe skill with default invocation.")
  }

  @Test func skillOverrideOffRemovesABuiltIn() throws {
    let folders = try Folders(probe: false)
    defer { folders.remove() }
    try write(#"{"skillOverrides":{"doctor":"off"}}"#, to: "\(folders.account)/settings.json")

    #expect(row("doctor", in: folders.rows(listing: nil)) == nil)
  }

  @Test func accountCommandDoesNotHideACwdSkillOfItsName() throws {
    let folders = try Folders(probe: false)
    defer { folders.remove() }
    try write("Account command.\n", to: "\(folders.account)/commands/dup.md")
    try write(skillFile("dup", "Repo skill."), to: "\(folders.cwd)/.claude/skills/dup/SKILL.md")

    #expect(row("dup", in: folders.rows(listing: nil))?.description == "Repo skill.")
  }

  @Test func unreadableSettingsRemoveNothing() throws {
    let folders = try Folders(probe: true)
    defer { folders.remove() }
    let listing = try fixtureItems("probe-listing.jsonl")
    let without = folders.rows(listing: listing)
    try write("{not json", to: "\(folders.account)/settings.json")

    let rows = folders.rows(listing: listing)

    #expect(keyed(rows) == keyed(without))
  }

  @Test func bareListingItemTakesTheScannedDescription() throws {
    let folders = try Folders(probe: true)
    defer { folders.remove() }
    let listing = SkillListing.items(attachment(["probe-default"], "- probe-default"))

    let rows = folders.rows(listing: listing)

    #expect(row("probe-default", in: rows)?.description == "Probe skill with default invocation.")
  }

  @Test func bareListingItemWithoutAFileStaysListedWithoutADescription() throws {
    let folders = try Folders(probe: false)
    defer { folders.remove() }

    let rows = folders.rows(listing: try fixtureItems("project-listing.jsonl"))

    let item = try #require(row("anthropic-skills:computer-use", in: rows))
    #expect(item.description == nil)
  }

  @Test func accountFileHidesASkillThatTheCwdFileShows() throws {
    let folders = try Folders(probe: false)
    defer { folders.remove() }
    try write(
      skillFile("dup", "Account copy.", "user-invocable: false"), to: "\(folders.account)/skills/dup/SKILL.md")
    try write(
      skillFile("dup", "Repo copy.", "disable-model-invocation: true"), to: "\(folders.cwd)/.claude/skills/dup/SKILL.md"
    )
    let listing = SkillListing.items(attachment(["dup"], "- dup: Account copy."))

    #expect(row("dup", in: folders.rows(listing: listing)) == nil, "overlay")
    #expect(row("dup", in: folders.rows(listing: nil)) == nil, "fallback")
  }

  @Test func accountFileShowsASkillThatTheCwdFileHides() throws {
    let folders = try Folders(probe: false)
    defer { folders.remove() }
    try write(skillFile("dup", "Account copy."), to: "\(folders.account)/skills/dup/SKILL.md")
    try write(
      skillFile("dup", "Repo copy.", "user-invocable: false"), to: "\(folders.cwd)/.claude/skills/dup/SKILL.md")
    let listing = SkillListing.items(attachment(["dup"], "- dup: Account copy."))

    #expect(row("dup", in: folders.rows(listing: listing)) != nil, "overlay")
    #expect(row("dup", in: folders.rows(listing: nil))?.description == "Account copy.", "fallback")
  }

  @Test func accountFileDecidesThatAUserOnlySkillIsAdded() throws {
    let folders = try Folders(probe: false)
    defer { folders.remove() }
    try write(
      skillFile("dup", "Account copy.", "disable-model-invocation: true"),
      to: "\(folders.account)/skills/dup/SKILL.md")
    try write(skillFile("dup", "Repo copy."), to: "\(folders.cwd)/.claude/skills/dup/SKILL.md")
    let listing = SkillListing.items(attachment(["commit"], "- commit: Commit."))

    let rows = folders.rows(listing: listing)

    #expect(row("dup", in: rows)?.description == "Account copy.")
    #expect(row("dup", in: rows)?.source == .scan)
  }

  @Test func scannedSkillHidesTheBuiltInOfItsName() throws {
    try #require(builtInNames.contains("model"))
    let folders = try Folders(probe: false)
    defer { folders.remove() }
    try write(skillFile("model", "Picks the repo's model."), to: "\(folders.cwd)/.claude/skills/model/SKILL.md")

    let rows = folders.rows(listing: nil).filter { $0.name == "model" }

    #expect(rows.count == 1)
    #expect(rows.first?.source == .scan)
    #expect(rows.first?.description == "Picks the repo's model.")
  }

  @Test func listedSkillHidesTheBuiltInOfItsName() throws {
    try #require(builtInNames.contains("clear"))
    let folders = try Folders(probe: false)
    defer { folders.remove() }
    let listing = SkillListing.items(attachment(["clear"], "- clear: A listed clear."))

    let rows = folders.rows(listing: listing).filter { $0.name == "clear" }

    #expect(rows.count == 1)
    #expect(rows.first?.source == .listing)
  }

  @Test func overlayAndFallbackAddEveryBuiltIn() throws {
    let folders = try Folders(probe: true)
    defer { folders.remove() }

    let overlay = folders.rows(listing: try fixtureItems("probe-listing.jsonl"))
    let fallback = folders.rows(listing: nil)

    #expect(names(overlay.filter { $0.source == .builtIn }) == builtInNames)
    #expect(names(fallback.filter { $0.source == .builtIn }) == builtInNames)
  }

  @Test func mergeNeverRepeatsAName() throws {
    let folders = try Folders(probe: true)
    defer { folders.remove() }

    let rows = folders.rows(listing: try fixtureItems("probe-listing.jsonl"))

    #expect(rows.count == names(rows).count)
  }
}

// MARK: - Built-ins

@Suite struct SlashCommandBuiltInTests {
  @Test func builtInsHaveUniqueNamesAndDescriptions() {
    let builtIns = SlashCommand.builtIns

    #expect(builtIns.count == builtInNames.count)
    #expect(builtIns.allSatisfy { $0.source == .builtIn })
    #expect(builtIns.allSatisfy { !($0.description ?? "").isEmpty })
  }

  @Test func builtInsIncludeClear() {
    #expect(builtInNames.contains("clear"))
  }

  @Test(arguments: ["init", "simplify", "loop", "code-review", "security-review"])
  func builtInsLeaveOutCommandsThatTheListingCarries(_ name: String) {
    #expect(!builtInNames.contains(name))
  }
}

// MARK: - Ranking

@Suite struct SlashCommandRankTests {
  static func commands(_ names: [String]) -> [SlashCommand] {
    names.map { SlashCommand(name: $0, description: nil, source: .scan) }
  }

  static let mixed = commands([
    "record", "pre-commit", "commit", "help", "anthropic-skills:computer-use", "my_config", "claude-api",
    "code-review",
  ])

  @Test func emptyQueryListsEveryRowByName() {
    let ranked = SlashCommands.rank(Self.mixed, query: "")

    #expect(ranked.map(\.name) == Self.mixed.map(\.name).sorted())
  }

  @Test func prefixMatchesComeFirstThenSegmentMatchesThenSubstrings() {
    let ranked = SlashCommands.rank(Self.mixed, query: "co")

    #expect(
      ranked.map(\.name) == [
        "code-review", "commit", "anthropic-skills:computer-use", "my_config", "pre-commit", "record",
      ])
  }

  @Test func queryIgnoresCase() {
    let ranked = SlashCommands.rank(Self.commands(["anthropic-skills:pdf", "help", "pdf-tools"]), query: "PDF")

    #expect(ranked.map(\.name) == ["pdf-tools", "anthropic-skills:pdf"])
  }

  @Test func descriptionsAreNotSearched() {
    let commands = [SlashCommand(name: "zebra", description: "Mentions zzz in its description.", source: .scan)]

    #expect(SlashCommands.rank(commands, query: "zzz").isEmpty)
  }

  @Test func queryThatMatchesNoNameGivesNothing() {
    #expect(SlashCommands.rank(Self.mixed, query: "zzz").isEmpty)
  }
}
