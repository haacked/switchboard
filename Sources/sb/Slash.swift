import Foundation
import SwitchboardCore

/// `sb slash <session>` prints the commands that the user can type after `/`
/// in the session's claude, one `/<name>  <description>` per line.
func slashCommand(_ a: Args) {
  let result = call("slash-commands", ["session": .string(a.session("slash"))])
  if a.json { return printJSON(result) }
  for command in decode(result["commands"] ?? [], as: [SlashCommand].self) {
    print(controlsEscaped("/\(command.name)" + (command.description.map { "  \($0)" } ?? "")))
  }
}
