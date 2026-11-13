import Foundation
import SwitchboardCore

extension Service {
  /// The `slash-commands` request: the commands that the user can type in
  /// the session's claude. It reads the transcript and the folders off the
  /// state queue. A repeat request on the same transcript reads only the
  /// lines added since the last one.
  func slashCommands(_ args: JSON) throws -> JSON {
    let (id, findTranscript, account, cwd, machine, cached) = try queue.sync {
      () -> (String, () -> String?, String, String, any Machine, (path: String, state: SkillListing.State)?) in
      let id = try lookup(args)
      return (
        id, transcriptFinder(id), claudeAccount(of: id), entries[id]!.session.cwd, try site(of: id).machine,
        slashListings[id]
      )
    }
    var state = SkillListing.State()
    if let path = findTranscript() {
      let read: Bool
      if let cached, cached.path == path {
        state = cached.state
        read = SkillListing.read(path, from: state.offset, into: &state, on: machine)
      } else {
        read = SkillListing.read(path, into: &state, on: machine)
      }
      // A failed read drops the entry, so that the next request reads the transcript from the end again.
      queue.sync {
        if entries[id] != nil { slashListings[id] = read ? (path, state) : nil }
      }
    }
    let commands = SlashCommands.merge(
      listing: state.commands, scanned: SkillFolders.scan(account: account, cwd: cwd, on: machine),
      overrides: SkillFolders.overrides(account: account, on: machine))
    return ["commands": try JSON(encoding: commands), "listing": .bool(state.commands != nil)]
  }
}
