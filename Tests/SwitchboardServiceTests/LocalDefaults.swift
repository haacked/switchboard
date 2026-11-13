import Foundation
import SwitchboardCore

@testable import SwitchboardService

/// The form that names no machine, which uses this Mac. `Sources` has none, so that no session path uses this Mac
/// by default. The tests that start a local tmux server keep it.
extension TerminalHost {
  convenience init(home: Home, config: Config) throws {
    try self.init(home: home, config: config, machine: LocalMachine())
  }
}
