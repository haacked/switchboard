import SwitchboardCore

extension BoardModel {
  /// Reads the commands that the session's claude takes after `/`. A failed read keeps the stored rows, which the
  /// message field shows while sbd answers.
  func loadSlashCommands(_ session: String) {
    let send = send
    poller.async {
      let commands = try? JSONCoding.convert(
        send("slash-commands", ["session": .string(session)])["commands"], to: [SlashCommand].self)
      Task { @MainActor in
        if let commands, self.slashCommands[session] != commands { self.slashCommands[session] = commands }
      }
    }
  }
}
