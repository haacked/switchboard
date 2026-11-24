import Foundation
import SwitchboardCore

extension Service {
  /// Who wrote a request's message or made its choice. A request comes from a Claude Code when it names a sending
  /// session in `from`, even one that sbd no longer knows, or when it carries `insideClaude`. Every other request
  /// comes from the user.
  static func author(_ args: JSON) -> MessageAuthor {
    args["from"] != nil || args["insideClaude"]?.bool == true ? .claude : .you
  }

  /// Throws `refusal` unless the request's `by` names the user. A missing `by` means the user.
  func requireUser(_ args: JSON, _ refusal: String) throws {
    guard try Author(parsing: args["by"]?.string) == .you else { throw APIError(refusal) }
  }

  /// Throws unless the request comes from the user or from Claude in session `id`: a request whose `by` is
  /// `claude` must name `id` in `caller`. `act` names what the request does, such as "add or remove links".
  func requireOwnSession(_ id: String, _ args: JSON, _ act: String) throws {
    guard try Author(parsing: args["by"]?.string) == .claude else { return }
    guard args["caller"]?.string != nil else {
      throw APIError("Claude can \(act) only in a session that Switchboard started, which sets SB_SESSION_ID")
    }
    guard isCaller(id, args) else { throw APIError("Claude can \(act) only on its own session") }
  }

  /// Refuses a request from a Claude Code that would act for the user. `act` names what the request does.
  static func refuseClaude(_ args: JSON, _ act: String) throws {
    guard author(args) == .claude else { return }
    throw APIError("\(act) for you, so it doesn't run inside Claude Code")
  }
}
