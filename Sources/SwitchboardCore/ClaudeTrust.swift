import Foundation

/// Marks a folder trusted in a Claude account's .claude.json, as Claude
/// Code's workspace trust dialog does. The rules come from Claude Code
/// 2.1.322. Trust is `projects[<key>].hasTrustDialogAccepted == true`, and the
/// key is the folder's real path. Claude saves the file under a lock: the
/// directory `<file>.lock`, made with mkdir. A lock whose mtime is more than
/// 10 s old is stale, and a waiter removes it and takes it again.
public enum ClaudeTrust {
  public enum Outcome: Equatable, Sendable {
    case alreadyTrusted
    case trusted(key: String)
    /// The account has no .claude.json, so nothing is written.
    case noConfig
    case refused(String)
  }

  /// The entry that Claude Code's dialog writes for a folder that has none.
  static let defaultProject: [String: Any] = [
    "allowedTools": [Any](), "mcpContextUris": [Any](), "mcpServers": [String: Any](),
    "enabledMcpjsonServers": [Any](), "disabledMcpjsonServers": [Any](), "hasTrustDialogAccepted": true,
    "hasClaudeMdExternalIncludesApproved": false, "hasClaudeMdExternalIncludesWarningShown": false,
  ]

  /// The folder that sbd created for the session's kind, which it may trust
  /// without asking: a chat's folder or the Manager's folder, when the
  /// session runs in it. A work session never has one, even in such a folder.
  public static func ownFolder(_ session: Session, home: Home) -> String? {
    let own: String
    switch session.kind {
    case .work: return nil
    case .manager: own = home.managerFolder
    case .chat:
      guard let group = session.chat else { return nil }
      own = home.chatFolder(group)
    }
    return (session.cwd as NSString).standardizingPath == (own as NSString).standardizingPath ? session.cwd : nil
  }

  public static func trust(_ folder: String, account: String) -> Outcome {
    trust(folder, configFile: ClaudeAccount.configFile(account))
  }

  /// A file that is missing or does not parse as Claude's config gets no
  /// write. The write goes to a temporary file that replaces the config. When
  /// the config changed between the read and the rename, as a claude that
  /// writes without the lock can do, the write starts over, up to 3 times.
  /// `beforeRename` lets a test change the file at that point.
  static func trust(
    _ folder: String, configFile: String, lockWait: TimeInterval = 2, staleAfter: TimeInterval = 10,
    beforeRename: () -> Void = {}
  ) -> Outcome {
    guard let key = realPath(folder) else { return .refused("\(folder) does not exist") }
    // A symlinked config stays a symlink, because the write replaces its target.
    guard let target = realPath(configFile) else { return .noConfig }
    // A read without the lock may catch a write half done, so only a trusted
    // entry ends the call here.
    if let data = FileManager.default.contents(atPath: target),
      case .success(nil) = Result(catching: { try marking(data, key: key) })
    {
      return .alreadyTrusted
    }
    // Claude Code locks the path it was given, not the resolved one, so a
    // symlinked config locks beside the link.
    let lock = "\(configFile).lock"
    if let refusal = takeLock(lock, wait: lockWait, staleAfter: staleAfter) { return .refused(refusal) }
    defer { rmdir(lock) }
    for _ in 0..<3 {
      guard let before = Stamp(target), let data = FileManager.default.contents(atPath: target) else {
        return .refused("can't read \(target)")
      }
      let marked: Data
      do {
        guard let new = try marking(data, key: key) else { return .alreadyTrusted }
        marked = new
      } catch {
        return .refused("\(target): \(error)")
      }
      let temp = "\(target).sb-\(getpid()).tmp"
      if let refusal = write(marked, to: temp, mode: before.mode) { return .refused(refusal) }
      beforeRename()
      guard Stamp(target) == before else {
        unlink(temp)
        continue
      }
      guard rename(temp, target) == 0 else {
        let reason = UnixSocket.errnoText()
        unlink(temp)
        return .refused("can't replace \(target): \(reason)")
      }
      return .trusted(key: key)
    }
    return .refused("\(target) kept changing while sbd wrote it")
  }

  /// The config with the folder trusted, or nil when the folder already is.
  /// An existing entry keeps its other keys. It throws when the file does
  /// not have the shape of Claude's config.
  static func marking(_ data: Data, key: String) throws -> Data? {
    guard !readsDifferently(data) else {
      throw APIError("claude would read it differently: it has a byte order mark, a trailing comma, or a repeated key")
    }
    guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw APIError("its root is not an object")
    }
    var projects: [String: Any] = [:]
    if let value = root["projects"] {
      guard let object = value as? [String: Any] else { throw APIError("its projects are not an object") }
      projects = object
    }
    var entry = defaultProject
    if let value = projects[key] {
      guard let object = value as? [String: Any] else { throw APIError("its entry for \(key) is not an object") }
      if isTrue(object["hasTrustDialogAccepted"]) { return nil }
      entry = object
      entry["hasTrustDialogAccepted"] = true
    }
    projects[key] = entry
    root["projects"] = projects
    return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .withoutEscapingSlashes])
  }

  /// Whether Foundation's parser reads the text differently from
  /// JavaScript's JSON.parse, which claude uses. Foundation accepts a byte
  /// order mark and a comma before a closing bracket, which JSON.parse
  /// rejects. For a key that repeats in one object, Foundation keeps the
  /// first value and JSON.parse keeps the last.
  static func readsDifferently(_ data: Data) -> Bool {
    let bytes = [UInt8](data)
    if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { return true }
    let quote = UInt8(ascii: "\"")
    let comma = UInt8(ascii: ",")
    // Each open container: an object's keys so far, or nil for an array.
    var open: [Set<String>?] = []
    var expectKey = false
    var afterComma = false
    var i = 0
    while i < bytes.count {
      let byte = bytes[i]
      switch byte {
      case UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\n"), UInt8(ascii: "\r"):
        i += 1
        continue
      case quote:
        let start = i
        i += 1
        while i < bytes.count, bytes[i] != quote {
          if bytes[i] == UInt8(ascii: "\\") { i += 1 }
          i += 1
        }
        if expectKey, i < bytes.count, !open.isEmpty, let key = key(bytes[start...i]),
          open[open.count - 1]?.insert(key).inserted == false
        {
          return true
        }
        expectKey = false
      case UInt8(ascii: "{"):
        open.append([])
        expectKey = true
      case UInt8(ascii: "["):
        open.append(nil)
        expectKey = false
      case UInt8(ascii: "}"), UInt8(ascii: "]"):
        if afterComma { return true }
        _ = open.popLast()
        expectKey = false
      case comma:
        expectKey = open.last.map { $0 != nil } ?? false
      default:
        expectKey = false
      }
      afterComma = byte == comma
      i += 1
    }
    return false
  }

  /// A quoted key's text. Only a key with an escape needs the parser, which
  /// is slow over the thousands of keys in a config.
  private static func key(_ quoted: ArraySlice<UInt8>) -> String? {
    guard quoted.contains(UInt8(ascii: "\\")) else {
      return String(decoding: quoted.dropFirst().dropLast(), as: UTF8.self)
    }
    return try? JSONSerialization.jsonObject(with: Data(quoted), options: .fragmentsAllowed) as? String
  }

  /// Whether the value is JSON's true. Foundation reads the number 1 as an
  /// NSNumber that also converts to true.
  private static func isTrue(_ value: Any?) -> Bool {
    guard let number = value as? NSNumber else { return false }
    return CFGetTypeID(number) == CFBooleanGetTypeID() && number.boolValue
  }

  /// Takes Claude's lock. It returns nil once it holds the lock, or the
  /// reason it could not take it.
  private static func takeLock(_ lock: String, wait: TimeInterval, staleAfter: TimeInterval) -> String? {
    let deadline = Date() + wait
    while mkdir(lock, 0o777) != 0 {
      guard errno == EEXIST else { return "can't make \(lock): \(UnixSocket.errnoText())" }
      var info = stat()
      if stat(lock, &info) == 0, Date().timeIntervalSince1970 - Double(info.st_mtimespec.tv_sec) > staleAfter {
        rmdir(lock)
        continue
      }
      if Date() >= deadline { return "another process held \(lock) for over \(wait) s" }
      usleep(50_000)
    }
    return nil
  }

  private static func write(_ data: Data, to path: String, mode: mode_t) -> String? {
    let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, mode)
    guard fd >= 0 else { return "can't write \(path): \(UnixSocket.errnoText())" }
    defer { close(fd) }
    // open applies the umask, so the mode is set again.
    fchmod(fd, mode)
    do {
      try UnixSocket.write(fd, data)
      guard fsync(fd) == 0 else { throw APIError(UnixSocket.errnoText()) }
    } catch {
      unlink(path)
      return "can't write \(path): \(error)"
    }
    return nil
  }

  /// What changes when another process rewrites the file.
  private struct Stamp: Equatable {
    var inode: ino_t
    var size: off_t
    var seconds: Int
    var nanoseconds: Int
    var mode: mode_t

    init?(_ path: String) {
      var info = stat()
      guard stat(path, &info) == 0 else { return nil }
      inode = info.st_ino
      size = info.st_size
      seconds = info.st_mtimespec.tv_sec
      nanoseconds = info.st_mtimespec.tv_nsec
      mode = info.st_mode & 0o7777
    }
  }
}
