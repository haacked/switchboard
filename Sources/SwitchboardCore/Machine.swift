import Foundation

/// The computer that holds a session's claude, shell, worktree, and
/// transcript. sbd runs a session's tmux, git, and `ps` commands, reads its
/// files, and signals its processes through the session's machine. Every path
/// and pid names a file or a process on that machine.
public protocol Machine: Sendable {
  /// Runs a program and waits for it, as `runCommand` does.
  func run(
    _ executable: String, _ args: [String], env: [String: String]?, input: Data?, timeout: Double?
  ) throws -> CommandResult

  /// Up to `count` bytes of the file from byte `offset`, or every byte from
  /// `offset` when `count` is nil. The data is empty when `offset` is at or
  /// past the end. It is nil when the file can't be read.
  func read(_ path: String, from offset: UInt64, count: Int?) -> Data?

  /// The file's size in bytes, or nil when the file can't be read.
  func size(_ path: String) -> UInt64?

  func exists(_ path: String) -> Bool

  func isFolder(_ path: String) -> Bool

  /// When the file last changed, or nil when it is missing.
  func modified(_ path: String) -> Date?

  /// The names in the folder, or none when it can't be read.
  func list(_ folder: String) -> [String]

  /// Creates the folder and the missing folders above it.
  func createFolder(_ path: String) throws

  /// Sends the signal to the process. It sends nothing for a number that
  /// `Processes.isValidPid` refuses, because such a number names a process group or
  /// every process.
  func signal(_ pid: Int, _ signal: Int32)
}

extension Machine {
  public func run(_ executable: String, _ args: [String]) throws -> CommandResult {
    try run(executable, args, env: nil, input: nil, timeout: nil)
  }

  /// The whole file as text, or nil when the file can't be read.
  public func text(_ path: String) -> String? {
    read(path, from: 0, count: nil).map { String(decoding: $0, as: UTF8.self) }
  }
}

/// This Mac.
public struct LocalMachine: Machine {
  public init() {}

  public func run(
    _ executable: String, _ args: [String], env: [String: String]?, input: Data?, timeout: Double?
  ) throws -> CommandResult {
    try runCommand(executable, args, env: env, input: input, timeout: timeout)
  }

  public func read(_ path: String, from offset: UInt64, count: Int?) -> Data? {
    guard let file = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? file.close() }
    do {
      try file.seek(toOffset: offset)
      return try (count.map { try file.read(upToCount: $0) } ?? file.readToEnd()) ?? Data()
    } catch {
      return nil
    }
  }

  public func size(_ path: String) -> UInt64? {
    guard let file = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? file.close() }
    return try? file.seekToEnd()
  }

  public func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

  public func isFolder(_ path: String) -> Bool { isDirectory(path) }

  public func modified(_ path: String) -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
  }

  public func list(_ folder: String) -> [String] {
    (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
  }

  public func createFolder(_ path: String) throws {
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
  }

  public func signal(_ pid: Int, _ signal: Int32) {
    guard Processes.isValidPid(pid) else { return }
    kill(pid_t(pid), signal)
  }
}
