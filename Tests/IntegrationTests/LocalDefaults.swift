import Foundation
import SwitchboardCore

/// The forms that name no machine, which read this Mac. `Sources` has none, so that no session path reads this Mac
/// by default. The tests that read the files and processes of a local sbd keep them.
extension Transcript {
  static func find(_ sessionId: String, account: String, cwd: String) -> String? {
    find(sessionId, account: account, cwd: cwd, on: LocalMachine())
  }
}

extension Processes {
  static func byParent() -> [Int: [ProcessRow]] { byParent(on: LocalMachine()) }
}
