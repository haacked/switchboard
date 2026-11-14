import Foundation
import SwitchboardCore

/// `sb` in the background, for a request that a gate on the box holds or a
/// command that blocks. Its output goes to files in the home, so a full pipe
/// can't stall it. It kills sb if a test ends while sb still runs.
final class BackgroundSb {
  private let process = Process()
  private let out: String
  private let err: String

  init(_ sbd: Instance, _ args: [String], env extra: [String: String] = [:]) throws {
    let tag = UUID().uuidString.prefix(8)
    out = "\(sbd.home.path)/background-\(tag).out"
    err = "\(sbd.home.path)/background-\(tag).err"
    FileManager.default.createFile(atPath: out, contents: nil)
    FileManager.default.createFile(atPath: err, contents: nil)
    process.executableURL = URL(fileURLWithPath: "\(Instance.bin)/sb")
    process.arguments = args
    process.environment = sbd.environment(extra)
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle(forWritingAtPath: out)
    process.standardError = FileHandle(forWritingAtPath: err)
    try process.run()
  }

  deinit {
    if process.isRunning {
      kill(process.processIdentifier, SIGKILL)
      process.waitUntilExit()
    }
  }

  var isRunning: Bool { process.isRunning }
  var pid: pid_t { process.processIdentifier }
  var terminationReason: Process.TerminationReason { process.terminationReason }

  /// Whether sb exits within the seconds.
  func exits(within seconds: Double) -> Bool {
    let deadline = Date().addingTimeInterval(seconds * Instance.timeoutScale)
    while process.isRunning, Date() < deadline { usleep(50_000) }
    return !process.isRunning
  }

  /// Waits for sb to exit and returns what it printed.
  func result() -> CommandResult {
    process.waitUntilExit()
    return CommandResult(
      status: process.terminationStatus, stdout: (try? String(contentsOfFile: out, encoding: .utf8)) ?? "",
      stderr: (try? String(contentsOfFile: err, encoding: .utf8)) ?? "")
  }

  /// What sb printed once it exits within the seconds. It kills sb that still
  /// runs, and throws.
  func finish(within seconds: Double = 15) throws -> CommandResult {
    guard exits(within: seconds) else {
      kill(process.processIdentifier, SIGKILL)
      throw TestError(description: "sb \(process.arguments ?? []) still ran after \(seconds) s: \(result().stderr)")
    }
    return result()
  }
}
