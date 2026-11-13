import Foundation
import SwitchboardCore

/// The forms that name no machine, which read this Mac. `Sources` has none, so that no session path reads this Mac
/// by default. The tests that read local files keep them.
extension Transcript {
  static func find(_ sessionId: String, account: String, cwd: String) -> String? {
    find(sessionId, account: account, cwd: cwd, on: LocalMachine())
  }

  static func find(_ sessionId: String, account: String, cwd: String, folders: (String) -> [String]) -> String? {
    find(sessionId, account: account, cwd: cwd, on: LocalMachine(), folders: folders)
  }

  static func tail(_ path: String) -> TranscriptTail { tail(path, on: LocalMachine()) }

  static func messages(_ path: String, limit: Int) -> [ChatMessage] {
    messages(path, limit: limit, on: LocalMachine())
  }

  static func hasUserMessage(_ path: String, holding text: String, from offset: UInt64) -> Bool {
    hasUserMessage(path, holding: text, from: offset, on: LocalMachine())
  }
}
