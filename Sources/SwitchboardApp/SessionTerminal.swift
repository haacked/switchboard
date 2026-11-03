import Foundation
import SwiftUI
import SwitchboardCore

/// Which terminal the panes use, fixed for the life of the process.
enum AppTerminal {
  #if SB_GHOSTTY
    static let ghosttyAvailable = true
  #else
    static let ghosttyAvailable = false
  #endif

  static let choice = TerminalBackend.choose(
    environment: ProcessInfo.processInfo.environment, ghosttyAvailable: ghosttyAvailable)

  static func announce() {
    FileHandle.standardError.write(
      Data("terminal: \(choice.backend.rawValue)\(choice.note.map { " (\($0))" } ?? "")\n".utf8))
  }
}

/// One of a session's two terminals, drawn by the chosen backend.
struct SessionTerminal: View {
  let terminals: Terminals
  let pane: Pane

  var body: some View {
    #if SB_GHOSTTY
      if AppTerminal.choice.backend == .ghostty {
        GhosttyPane(command: terminals.attachCommandLine(pane), pane: pane)
      } else {
        TerminalPane(command: terminals.attachCommand(pane))
      }
    #else
      TerminalPane(command: terminals.attachCommand(pane))
    #endif
  }
}
