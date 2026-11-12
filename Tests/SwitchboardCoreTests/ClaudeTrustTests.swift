import Foundation
import Testing

@testable import SwitchboardCore

/// The entry that Claude Code 2.1.322's trust dialog writes for a folder
/// that has none. The test states it on its own, so that a wrong
/// `ClaudeTrust.defaultProject` fails.
let claudesDefaultEntry: [String: Any] = [
  "allowedTools": [Any](), "mcpContextUris": [Any](), "mcpServers": [String: Any](),
  "enabledMcpjsonServers": [Any](), "disabledMcpjsonServers": [Any](), "hasTrustDialogAccepted": true,
  "hasClaudeMdExternalIncludesApproved": false, "hasClaudeMdExternalIncludesWarningShown": false,
]

/// The parsed JSON as text with sorted keys. Two values compare equal only
/// when their keys, strings, and numbers are equal and their booleans are
/// booleans. `NSDictionary` equality reads `true` as equal to `1`.
func canonicalJSON(_ value: Any) throws -> String {
  let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
  return String(decoding: data, as: UTF8.self)
}

/// Whether the value is JSON's `true` and not the number 1.
func isJSONTrue(_ value: Any?) -> Bool {
  guard let number = value as? NSNumber else { return false }
  return CFGetTypeID(number) == CFBooleanGetTypeID() && number.boolValue
}

/// A folder under /tmp, which macOS stores as /private/tmp, with a project
/// folder `work` and an account's `.claude.json`. The folder goes away when
/// the test ends.
private final class TrustFolder {
  let path: String

  init() throws {
    var template = Array("/tmp/sbtrust.XXXXXX".utf8CString)
    guard let dir = mkdtemp(&template) else { throw APIError("mkdtemp failed") }
    path = String(cString: dir)
    try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
  }

  deinit { try? FileManager.default.removeItem(atPath: path) }

  var work: String { "\(path)/work" }
  var config: String { "\(path)/.claude.json" }
  var lock: String { "\(config).lock" }

  /// The real path of `work`, which Claude Code uses as the project's key.
  var key: String { realPath(work) }

  func write(_ text: String, mode: mode_t = 0o600) throws {
    try Data(text.utf8).write(to: URL(fileURLWithPath: config))
    chmod(config, mode)
  }

  func write(_ object: Any) throws {
    try write(String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self))
  }

  func bytes() -> Data? { FileManager.default.contents(atPath: config) }

  func parsed(_ file: String? = nil) throws -> [String: Any] {
    let data = try #require(FileManager.default.contents(atPath: file ?? config))
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  func projects() throws -> [String: Any] { try parsed()["projects"] as? [String: Any] ?? [:] }

  func trust(
    _ folder: String? = nil, lockWait: TimeInterval = 2, staleAfter: TimeInterval = 10,
    beforeRename: () -> Void = {}
  ) -> ClaudeTrust.Outcome {
    ClaudeTrust.trust(
      folder ?? work, configFile: config, lockWait: lockWait, staleAfter: staleAfter, beforeRename: beforeRename)
  }

  /// The lock dirs and temporary files that a write left in the folder.
  func leftovers() -> [String] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
    return names.filter { $0.hasSuffix(".lock") || $0.contains(".sb-") || $0.hasSuffix(".tmp") }
  }

  func mode() throws -> mode_t {
    var info = stat()
    try #require(stat(config, &info) == 0)
    return info.st_mode & 0o777
  }

  struct Stamp: Equatable {
    var inode: ino_t
    var seconds: Int
    var nanoseconds: Int
  }

  func stamp(_ file: String? = nil) throws -> Stamp {
    var info = stat()
    try #require(stat(file ?? config, &info) == 0)
    return Stamp(inode: info.st_ino, seconds: info.st_mtimespec.tv_sec, nanoseconds: info.st_mtimespec.tv_nsec)
  }
}

private func realPath(_ path: String) -> String {
  guard let resolved = realpath(path, nil) else { return path }
  defer { free(resolved) }
  return String(cString: resolved)
}

private func isRefused(_ outcome: ClaudeTrust.Outcome) -> Bool {
  if case .refused = outcome { return true }
  return false
}

/// A config with the login, numbers that `JSON` would change, a nested
/// object, non-ASCII text, and another project.
private let otherKeys = """
  {
    "oauthAccount": {"accountUuid": "0b6c-41", "emailAddress": "me@example.com", "organizationRole": "admin"},
    "numStartups": 9007199254740993,
    "tipsRatio": 0.1,
    "hasCompletedOnboarding": true,
    "promptQueueUseCount": 1,
    "nested": {"deeper": {"list": [1, 2.5, false, null, "x"]}},
    "name": "é \\"quoted\\" \\n line",
    "projects": {
      "/Users/me/elsewhere": {"allowedTools": ["Bash(ls)"], "hasTrustDialogAccepted": true, "lastCost": 0.25}
    }
  }
  """

@Suite struct ClaudeTrustWrites {
  @Test func marksANewFolderWithClaudesDefaultEntry() throws {
    let dir = try TrustFolder()
    try dir.write(["projects": ["/Users/me/elsewhere": ["hasTrustDialogAccepted": true]]])

    let outcome = dir.trust()

    #expect(outcome == .trusted(key: dir.key))
    let entry = try #require(try dir.projects()[dir.key])
    #expect(try canonicalJSON(entry) == canonicalJSON(claudesDefaultEntry))
  }

  @Test func keepsEveryOtherKeyAndProject() throws {
    let dir = try TrustFolder()
    try dir.write(otherKeys)
    var expected = try dir.parsed()
    var projects = try #require(expected["projects"] as? [String: Any])
    projects[dir.key] = claudesDefaultEntry
    expected["projects"] = projects

    let outcome = dir.trust()

    #expect(outcome == .trusted(key: dir.key))
    #expect(try canonicalJSON(dir.parsed()) == canonicalJSON(expected))
  }

  /// `JSONSerialization` parses both files, so a number that the write
  /// rounded would round the same way in both. The text keeps the exact digits.
  @Test func keepsAnIntegerAbove2To53Exactly() throws {
    let dir = try TrustFolder()
    try dir.write(otherKeys)

    _ = dir.trust()

    let text = String(decoding: try #require(dir.bytes()), as: UTF8.self)
    #expect(text.contains("9007199254740993"))
  }

  @Test(arguments: [
    #"{"allowedTools": ["Bash(ls)"], "hasTrustDialogAccepted": false, "custom": {"n": 1}, "mcpServers": {"a": {}}}"#,
    #"{"allowedTools": ["Bash(ls)"], "custom": {"n": 1}}"#,
  ])
  func flipsOnlyTheFlagOfAnExistingEntry(_ entryText: String) throws {
    let dir = try TrustFolder()
    let entry = try #require(try JSONSerialization.jsonObject(with: Data(entryText.utf8)) as? [String: Any])
    try dir.write(["projects": [dir.key: entry]])
    var expected = entry
    expected["hasTrustDialogAccepted"] = true

    let outcome = dir.trust()

    #expect(outcome == .trusted(key: dir.key))
    #expect(try canonicalJSON(try #require(try dir.projects()[dir.key])) == canonicalJSON(expected))
  }

  /// Claude Code trusts a folder only when the flag `=== true`. The number 1
  /// converts to true in Foundation, so a check through `Bool` would skip
  /// the write and leave claude at the dialog.
  @Test(arguments: ["1", "\"true\"", "null", "0", "\"yes\""])
  func aFlagThatIsNotTheBooleanTrueBecomesTrue(_ flag: String) throws {
    let dir = try TrustFolder()
    try dir.write(#"{"projects": {"\#(dir.key)": {"hasTrustDialogAccepted": \#(flag), "allowedTools": []}}}"#)

    let outcome = dir.trust()

    #expect(outcome == .trusted(key: dir.key))
    let entry = try #require(try dir.projects()[dir.key] as? [String: Any])
    #expect(isJSONTrue(entry["hasTrustDialogAccepted"]))
  }

  @Test func addsProjectsWhenTheFileHasNone() throws {
    let dir = try TrustFolder()
    try dir.write(#"{"oauthAccount": {"emailAddress": "me@example.com"}, "numStartups": 3}"#)

    let outcome = dir.trust()

    #expect(outcome == .trusted(key: dir.key))
    let expected: [String: Any] = [
      "oauthAccount": ["emailAddress": "me@example.com"], "numStartups": 3,
      "projects": [dir.key: claudesDefaultEntry],
    ]
    #expect(try canonicalJSON(dir.parsed()) == canonicalJSON(expected))
  }

  @Test func addsTheEntryToAnEmptyObject() throws {
    let dir = try TrustFolder()
    try dir.write("{}")

    let outcome = dir.trust()

    #expect(outcome == .trusted(key: dir.key))
    #expect(try canonicalJSON(dir.parsed()) == canonicalJSON(["projects": [dir.key: claudesDefaultEntry]]))
  }

  /// The checks for a repeated key and a trailing comma read keys per object
  /// and skip text inside strings.
  @Test(arguments: [
    #"{"a": {"x": 1}, "b": {"x": 2}, "c": [{"x": 1}, {"x": 2}]}"#,
    #"{"s": ",}", "t": ",]", "u": "a\"b,}", "v": "\\"}"#,
    #"{"a\"b": 1, "a": 2}"#,
  ])
  func writesTextThatJSONParseReadsTheSame(_ text: String) throws {
    let dir = try TrustFolder()
    try dir.write(text)
    let before = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])

    let outcome = dir.trust()

    #expect(outcome == .trusted(key: dir.key))
    var expected = before
    expected["projects"] = [dir.key: claudesDefaultEntry]
    #expect(try canonicalJSON(dir.parsed()) == canonicalJSON(expected))
  }

  @Test func removesItsLockAfterAWrite() throws {
    let dir = try TrustFolder()
    try dir.write("{}")

    let outcome = dir.trust()

    #expect(outcome == .trusted(key: dir.key))
    #expect(!FileManager.default.fileExists(atPath: dir.lock))
  }

  @Test func leavesNoTemporaryFileAfterAWrite() throws {
    let dir = try TrustFolder()
    try dir.write(otherKeys)

    _ = dir.trust()

    #expect(dir.leftovers().isEmpty)
  }

  @Test func keepsMode0600() throws {
    let dir = try TrustFolder()
    try dir.write(otherKeys, mode: 0o600)

    #expect(dir.trust() == .trusted(key: dir.key))

    #expect(try dir.mode() == 0o600)
  }

  @Test func keepsAWiderModeAsItWas() throws {
    let dir = try TrustFolder()
    try dir.write("{}", mode: 0o644)

    #expect(dir.trust() == .trusted(key: dir.key))

    #expect(try dir.mode() == 0o644)
  }

  /// The write replaces the link's target, so the link stays a link to it.
  @Test func keepsASymlinkedConfigFileALink() throws {
    let dir = try TrustFolder()
    let target = "\(dir.path)/real-claude.json"
    try Data(otherKeys.utf8).write(to: URL(fileURLWithPath: target))
    try FileManager.default.createSymbolicLink(atPath: dir.config, withDestinationPath: "real-claude.json")

    let outcome = dir.trust()

    #expect(outcome == .trusted(key: dir.key))
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: dir.config) == "real-claude.json")
    let projects = try #require(try dir.parsed(target)["projects"] as? [String: Any])
    #expect(try canonicalJSON(try #require(projects[dir.key])) == canonicalJSON(claudesDefaultEntry))
    #expect(dir.leftovers().isEmpty)
  }

  /// The account overload writes the `.claude.json` in the account's folder.
  @Test func theAccountOverloadWritesTheAccountsConfigFile() throws {
    let dir = try TrustFolder()
    try #require(!ClaudeAccount.isDefault(dir.path))
    try #require(ClaudeAccount.configFile(dir.path).hasPrefix(ClaudeAccount.normalize(dir.path)))
    try dir.write("{}")

    let outcome = ClaudeTrust.trust(dir.work, account: dir.path)

    #expect(outcome == .trusted(key: dir.key))
    #expect(isJSONTrue((try dir.projects()[dir.key] as? [String: Any])?["hasTrustDialogAccepted"]))
  }
}

@Suite struct ClaudeTrustKeys {
  /// Claude Code keys a folder by its real path, so a folder under /tmp is
  /// stored as /private/tmp. Each spelling of the folder resolves to that key.
  @Test(arguments: ["work", "work/", "work/../work", "./work", "link"])
  func keysTheFolderByItsRealPath(_ spelling: String) throws {
    let dir = try TrustFolder()
    try FileManager.default.createSymbolicLink(atPath: "\(dir.path)/link", withDestinationPath: dir.work)
    try dir.write("{}")
    try #require(dir.key.hasPrefix("/private/tmp/"))

    let outcome = dir.trust("\(dir.path)/\(spelling)")

    #expect(outcome == .trusted(key: dir.key))
    let projects = try dir.projects()
    #expect(Array(projects.keys) == [dir.key])
  }

  @Test func aFolderTrustedUnderItsRealPathIsAlreadyTrusted() throws {
    let dir = try TrustFolder()
    let text = #"{"projects": {"\#(dir.key)": {"hasTrustDialogAccepted": true}}}"#
    try dir.write(text)
    try #require(dir.work.hasPrefix("/tmp/"))

    let outcome = dir.trust(dir.work)

    #expect(outcome == .alreadyTrusted)
    #expect(dir.bytes() == Data(text.utf8))
  }

  /// An entry under the spelled /tmp path is not Claude Code's key, so it
  /// does not count as trust.
  @Test func anEntryUnderTheUnresolvedPathIsNotTrust() throws {
    let dir = try TrustFolder()
    try dir.write(#"{"projects": {"\#(dir.work)": {"hasTrustDialogAccepted": true}}}"#)

    let outcome = dir.trust()

    #expect(outcome == .trusted(key: dir.key))
    #expect(isJSONTrue((try dir.projects()[dir.key] as? [String: Any])?["hasTrustDialogAccepted"]))
  }

  @Test func refusesAMissingFolder() throws {
    let dir = try TrustFolder()
    try dir.write(otherKeys)
    let before = dir.bytes()

    let outcome = dir.trust("\(dir.path)/gone")

    #expect(isRefused(outcome))
    #expect(dir.bytes() == before)
    #expect(dir.leftovers().isEmpty)
  }
}

@Suite struct ClaudeTrustRefusals {
  @Test func leavesATrustedFolderAloneAndTakesNoLock() throws {
    let dir = try TrustFolder()
    let text = #"{"numStartups": 9007199254740993, "projects": {"\#(dir.key)": {"hasTrustDialogAccepted": true}}}"#
    try dir.write(text)
    let before = try dir.stamp()
    // Another process holds the lock. A call that took the lock path would
    // wait for it and give up.
    try #require(mkdir(dir.lock, 0o755) == 0)

    let outcome = dir.trust(lockWait: 0.3)

    #expect(outcome == .alreadyTrusted)
    #expect(try dir.stamp() == before)
    #expect(dir.bytes() == Data(text.utf8))
    #expect(FileManager.default.fileExists(atPath: dir.lock))
  }

  @Test func leavesATrustedFolderWithoutALockDir() throws {
    let dir = try TrustFolder()
    try dir.write(#"{"projects": {"\#(dir.key)": {"hasTrustDialogAccepted": true}}}"#)

    let outcome = dir.trust()

    #expect(outcome == .alreadyTrusted)
    #expect(dir.leftovers().isEmpty)
  }

  @Test func writesNothingWhenTheFileIsMissing() throws {
    let dir = try TrustFolder()

    let outcome = dir.trust()

    #expect(outcome == .noConfig)
    #expect(!FileManager.default.fileExists(atPath: dir.config))
    #expect(dir.leftovers().isEmpty)
  }

  /// A symlink whose target is missing is a missing file too.
  @Test func writesNothingThroughADanglingSymlink() throws {
    let dir = try TrustFolder()
    try FileManager.default.createSymbolicLink(atPath: dir.config, withDestinationPath: "gone.json")

    let outcome = dir.trust()

    #expect(outcome == .noConfig)
    #expect(!FileManager.default.fileExists(atPath: "\(dir.path)/gone.json"))
    #expect(dir.leftovers().isEmpty)
  }

  /// Claude Code reads the file with JavaScript's `JSON.parse`, which
  /// rejects a trailing comma. `JSONSerialization` accepts one.
  @Test(arguments: ["", " ", "{", "not json", #"{"projects": {}"#, #"{"a": 1,}"#, "{\n  \"a\": 1,\n}"])
  func refusesInvalidJSON(_ text: String) throws {
    try expectRefused(text)
  }

  @Test(arguments: [
    #"{"a": [1,]}"#, "{\"a\": 1 // c\n}", #"{"a": /* c */ 1}"#, #"{"a": NaN}"#, #"{"a": Infinity}"#, #"{'a': 1}"#,
    #"{a: 1}"#, #"{"a": 1} x"#, "\u{FEFF}{\"a\": 1}",
  ])
  func refusesTextThatJSONParseRejects(_ text: String) throws {
    try expectRefused(text)
  }

  /// JavaScript keeps the last of two equal keys, and `JSONSerialization`
  /// keeps the first. A rewrite would change what claude reads.
  @Test(arguments: [
    #"{"projects": {}, "numStartups": 1, "projects": {"/Users/me/x": {"hasTrustDialogAccepted": true}}}"#,
    #"{"oauthAccount": {"emailAddress": "old@example.com"}, "oauthAccount": {"emailAddress": "me@example.com"}}"#,
    #"{"a": 1, "\u0061": 2}"#,
  ])
  func refusesARepeatedKey(_ text: String) throws {
    try expectRefused(text)
  }

  /// The repeated flag in the entry decides whether claude shows the dialog.
  @Test func refusesARepeatedKeyInTheEntry() throws {
    try expectRefused { key in
      #"{"projects": {"\#(key)": {"hasTrustDialogAccepted": true, "hasTrustDialogAccepted": false}}}"#
    }
  }

  @Test(arguments: ["null", "[]", "[{}]", #""x""#, "1", "true"])
  func refusesARootThatIsNotAnObject(_ text: String) throws {
    try expectRefused(text)
  }

  @Test(arguments: ["[]", #""x""#, "1", "true", "null"])
  func refusesProjectsThatAreNotAnObject(_ projects: String) throws {
    try expectRefused(#"{"oauthAccount": {}, "projects": \#(projects)}"#)
  }

  @Test(arguments: ["[]", #""x""#, "1", "true", "null"])
  func refusesAnEntryThatIsNotAnObject(_ entry: String) throws {
    try expectRefused { key in #"{"projects": {"\#(key)": \#(entry)}}"# }
  }

  private func expectRefused(_ text: String) throws { try expectRefused { _ in text } }

  private func expectRefused(_ text: (String) -> String) throws {
    let dir = try TrustFolder()
    try dir.write(text(dir.key))
    let before = dir.bytes()

    let outcome = dir.trust()

    #expect(isRefused(outcome), "\(outcome)")
    #expect(dir.bytes() == before)
    #expect(dir.leftovers().isEmpty)
  }
}

@Suite struct ClaudeTrustLock {
  @Test func waitsForAHeldLockThenGivesUp() throws {
    let dir = try TrustFolder()
    try dir.write(otherKeys)
    let before = dir.bytes()
    try #require(mkdir(dir.lock, 0o755) == 0)
    let start = Date()

    let outcome = dir.trust(lockWait: 0.3)

    #expect(isRefused(outcome), "\(outcome)")
    #expect(Date().timeIntervalSince(start) >= 0.25)
    #expect(dir.bytes() == before)
    #expect(FileManager.default.fileExists(atPath: dir.lock))
  }

  /// Claude Code locks beside the link, not beside its target.
  @Test func waitsForTheLockBesideASymlinkedConfig() throws {
    let dir = try TrustFolder()
    let target = "\(dir.path)/real-claude.json"
    try Data(otherKeys.utf8).write(to: URL(fileURLWithPath: target))
    try FileManager.default.createSymbolicLink(atPath: dir.config, withDestinationPath: "real-claude.json")
    let before = FileManager.default.contents(atPath: target)
    try #require(mkdir(dir.lock, 0o755) == 0)

    let outcome = dir.trust(lockWait: 0.3)

    #expect(isRefused(outcome), "\(outcome)")
    #expect(FileManager.default.contents(atPath: target) == before)
    #expect(FileManager.default.fileExists(atPath: dir.lock))
  }

  @Test func takesAStaleLock() throws {
    let dir = try TrustFolder()
    try dir.write("{}")
    try #require(mkdir(dir.lock, 0o755) == 0)
    let old = Int(Date().timeIntervalSince1970) - 20
    var times = [timeval(tv_sec: old, tv_usec: 0), timeval(tv_sec: old, tv_usec: 0)]
    try #require(utimes(dir.lock, &times) == 0)

    let outcome = dir.trust()

    #expect(outcome == .trusted(key: dir.key))
    #expect(!FileManager.default.fileExists(atPath: dir.lock))
  }

  /// A lock 5 s old is fresh under Claude Code's 10 s rule, so the call waits for it.
  @Test func aLockYoungerThanTheStaleAgeIsNotTaken() throws {
    let dir = try TrustFolder()
    try dir.write("{}")
    try #require(mkdir(dir.lock, 0o755) == 0)
    let recent = Int(Date().timeIntervalSince1970) - 5
    var times = [timeval(tv_sec: recent, tv_usec: 0), timeval(tv_sec: recent, tv_usec: 0)]
    try #require(utimes(dir.lock, &times) == 0)

    let outcome = dir.trust(lockWait: 0.3)

    #expect(isRefused(outcome), "\(outcome)")
    #expect(dir.bytes() == Data("{}".utf8))
    #expect(FileManager.default.fileExists(atPath: dir.lock))
  }

  @Test func takesALockReleasedDuringTheWait() throws {
    let dir = try TrustFolder()
    try dir.write("{}")
    try #require(mkdir(dir.lock, 0o755) == 0)
    let lock = dir.lock
    // A thread of its own, because blocked tests can hold every thread of
    // the global queue in a full run.
    Thread {
      usleep(100_000)
      rmdir(lock)
    }.start()
    let start = Date()

    let outcome = dir.trust()

    #expect(outcome == .trusted(key: dir.key))
    #expect(Date().timeIntervalSince(start) >= 0.09)
    #expect(!FileManager.default.fileExists(atPath: dir.lock))
  }

  /// Each write reads the file under the lock, so writers at once keep each other's entries.
  @Test func writersAtOnceKeepEveryEntry() throws {
    let dir = try TrustFolder()
    try dir.write(otherKeys)
    let folders = (0..<6).map { "\(dir.path)/w\($0)" }
    for folder in folders { try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true) }
    let config = dir.config
    let outcomes = OutcomeList()

    DispatchQueue.concurrentPerform(iterations: folders.count) { i in
      outcomes.add(ClaudeTrust.trust(folders[i], configFile: config))
    }

    let keys = folders.map(realPath)
    #expect(outcomes.all.count == folders.count)
    #expect(outcomes.all.allSatisfy { if case .trusted = $0 { true } else { false } })
    let projects = try dir.projects()
    for key in keys { #expect(isJSONTrue((projects[key] as? [String: Any])?["hasTrustDialogAccepted"]), "\(key)") }
    #expect(projects["/Users/me/elsewhere"] != nil)
    #expect(dir.leftovers().isEmpty)
  }
}

private final class OutcomeList: @unchecked Sendable {
  private let lock = NSLock()
  private var outcomes: [ClaudeTrust.Outcome] = []

  func add(_ outcome: ClaudeTrust.Outcome) { lock.withLock { outcomes.append(outcome) } }

  var all: [ClaudeTrust.Outcome] { lock.withLock { outcomes } }
}

@Suite struct ClaudeTrustRestat {
  /// A claude that writes without the lock changes the file between sbd's
  /// read and its rename. sbd reads again, so the claude's write stays.
  @Test func startsOverWhenTheFileChangesBeforeTheRename() throws {
    let dir = try TrustFolder()
    try dir.write(otherKeys)
    let config = dir.config
    var calls = 0

    let outcome = dir.trust {
      calls += 1
      guard calls == 1, let data = FileManager.default.contents(atPath: config),
        var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
      else { return }
      root["injected"] = "by claude"
      // An atomic write gives the file a new inode, as claude's own save does.
      try? JSONSerialization.data(withJSONObject: root).write(to: URL(fileURLWithPath: config), options: .atomic)
    }

    #expect(outcome == .trusted(key: dir.key))
    #expect(calls == 2)
    let root = try dir.parsed()
    #expect(root["injected"] as? String == "by claude")
    #expect(isJSONTrue(((root["projects"] as? [String: Any])?[dir.key] as? [String: Any])?["hasTrustDialogAccepted"]))
    #expect((root["oauthAccount"] as? [String: Any])?["emailAddress"] as? String == "me@example.com")
    #expect(dir.leftovers().isEmpty)
  }

  /// A file that changes before every rename keeps the other writer's text,
  /// and sbd gives up.
  @Test func givesUpWhenTheFileKeepsChanging() throws {
    let dir = try TrustFolder()
    try dir.write(otherKeys)
    let config = dir.config
    var calls = 0

    let outcome = dir.trust {
      calls += 1
      let text = #"{"projects": {}, "writes": \#(calls), "pad": "\#(String(repeating: "x", count: calls))"}"#
      try? Data(text.utf8).write(to: URL(fileURLWithPath: config), options: .atomic)
    }

    #expect(isRefused(outcome), "\(outcome)")
    #expect(calls == 3)
    let root = try dir.parsed()
    #expect(root["writes"] as? Int == calls)
    #expect((root["projects"] as? [String: Any])?[dir.key] == nil)
    #expect(dir.leftovers().isEmpty)
  }
}

/// `ClaudeTrust.ownFolder` names a folder only when it is the one that sbd
/// created for the session's kind.
@Suite struct ClaudeTrustOwnFolder {
  static let home = Home(path: "/tmp/sbt.Own123")

  static func session(cwd: String, chat: String? = nil, manager: Bool = false) -> Session {
    var s = Session(id: "s1", name: "test", cwd: cwd, claudeSessionId: "uuid", created: 0)
    s.chat = chat
    if manager { s.manager = true }
    return s
  }

  static let trusted: [(Session, String)] = [
    (session(cwd: home.chatFolder("g1"), chat: "g1"), home.chatFolder("g1")),
    (session(cwd: home.chatFolder("g1") + "/", chat: "g1"), home.chatFolder("g1")),
    (session(cwd: "\(home.chatsFolder)/x/../g1", chat: "g1"), home.chatFolder("g1")),
    (session(cwd: "\(home.chatsFolder)/./g1", chat: "g1"), home.chatFolder("g1")),
    (session(cwd: home.managerFolder, manager: true), home.managerFolder),
    (session(cwd: home.managerFolder + "/", manager: true), home.managerFolder),
  ]

  @Test(arguments: trusted)
  func namesTheFolderThatSbdCreatedForTheKind(_ session: Session, _ own: String) throws {
    let folder = try #require(ClaudeTrust.ownFolder(session, home: Self.home))

    #expect((folder as NSString).standardizingPath == own)
  }

  static let refused: [Session] = [
    // A work session never qualifies, even in a folder that sbd made for a chat or the Manager.
    session(cwd: home.chatFolder("g1")), session(cwd: home.managerFolder), session(cwd: "\(home.path)/work"),
    session(cwd: "/Users/me/dev/repo"),
    // A chat in another group's folder, the Manager's, or a folder near its own.
    session(cwd: home.chatFolder("g2"), chat: "g1"), session(cwd: home.managerFolder, chat: "g1"),
    session(cwd: home.chatFolder("g1") + "/sub", chat: "g1"), session(cwd: home.chatFolder("g1") + "x", chat: "g1"),
    session(cwd: home.chatsFolder, chat: "g1"), session(cwd: home.path, chat: "g1"),
    session(cwd: "/tmp/sbt.Other/chats/g1", chat: "g1"), session(cwd: "", chat: "g1"),
    // The Manager in a chat's folder or near its own.
    session(cwd: home.chatFolder("g1"), manager: true), session(cwd: home.managerFolder + "-x", manager: true),
    session(cwd: home.path, manager: true), session(cwd: "\(home.managerFolder)/sub", manager: true),
  ]

  @Test(arguments: refused)
  func refusesEveryOtherFolder(_ session: Session) {
    #expect(ClaudeTrust.ownFolder(session, home: Self.home) == nil)
  }
}
