import Foundation
import SwitchboardCore

extension Service {
  /// Who wrote a request's message or made its choice. A request comes from a Claude Code when it names a sending
  /// session in `from`, even one that sbd no longer knows, or when it carries `insideClaude`. Every other request
  /// comes from the user.
  static func author(_ args: JSON) -> MessageAuthor {
    args["from"] != nil || args["insideClaude"]?.bool == true ? .claude : .you
  }

  /// The group requests whose `by` records who wrote what they store. A user-written description and the user's links
  /// go into the system prompt of every session in the group.
  static let groupAuthorOps: Set<String> = [
    "group-add", "group-describe", "group-note", "group-link-add", "group-link-rm",
  ]

  /// The request with `by` set to `claude` when its client on this Mac runs below a session's pane or below sbd's
  /// tmux server, where every session runs, or when sbd can't read the client's parents. `sb` sends `by: claude` only
  /// while CLAUDECODE is set, and a session can unset it. A shell pane counts too, because Claude can type into it
  /// with `tmux send-keys`. It never changes `claude` to `you`. It runs off the state queue, because it takes a
  /// snapshot.
  func withCallerAuthor(_ request: Request, origin: RequestOrigin, caller: Caller) -> Request {
    guard origin == .mac, Self.groupAuthorOps.contains(request.op), case .client(let pid) = caller,
      var args = request.args.object, args["by"]?.string != Author.claude.rawValue
    else { return request }
    let ancestry = pid.flatMap(Processes.ancestors(of:))
    let fresh = buildSnapshot()
    let inSession: Bool = queue.sync {
      install(fresh)
      guard let ancestry else { return true }
      let place = callerPlace(ancestry)
      return !place.inside.isEmpty || place.inServer
    }
    guard inSession else { return request }
    args["by"] = .string(Author.claude.rawValue)
    return Request(op: request.op, args: .object(args))
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
