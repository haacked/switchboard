import Foundation
import SwitchboardCore

extension Service {
  /// Runs gh and returns its error, or nil when it exited 0.
  func ghError(_ args: [String], timeout: TimeInterval) -> String? {
    do {
      _ = try runGh(args, timeout: timeout)
      return nil
    } catch {
      return "\(error)"
    }
  }

  /// Runs gh and returns its stdout. A non-zero exit throws gh's error, or
  /// its exit status when it printed nothing.
  func runGh(_ args: [String], timeout: TimeInterval) throws -> String {
    guard let gh = findExecutable(config.github.gh) else { throw APIError("can't find \(config.github.gh)") }
    let r = try runCommand(gh, args, timeout: timeout)
    guard r.status == 0 else {
      let text = [r.stderr, r.stdout].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
      throw APIError(text ?? "gh \(args.prefix(2).joined(separator: " ")) exited with status \(r.status)")
    }
    return r.stdout
  }
}
