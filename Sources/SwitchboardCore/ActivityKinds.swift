import Foundation

/// What a field of an app activity event may hold.
public enum ActivityField: Sendable {
  case number
  case bool
  case oneOf(Set<String>)

  func accepts(_ value: JSON) -> Bool {
    switch (self, value) {
    case (.number, .number(let n)): return n.isFinite
    case (.bool, .bool): return true
    case (.oneOf(let values), .string(let s)): return values.contains(s)
    default: return false
    }
  }
}

/// The events that the app may add to the activity log. sbd stores an event only when its kind is listed here
/// and every field it has passes that field's rule, so the log can't hold message text, search queries, paths,
/// or error messages.
public enum ActivityKinds {
  public static let places: Set<String> = ["session", "manager", "chat", "inbox", "board"]
  /// How the user reached a place. `list` is a sidebar, Inbox, or Board selection by mouse or arrow key.
  /// `launch` is a launch hook such as SB_SELECT.
  public static let navVias: Set<String> = [
    "list", "command", "back", "forward", "recent", "search", "notification", "launch",
  ]
  /// The input event that ran a command.
  public static let inputs: Set<String> = ["key", "click", "mouse-button", "swipe", "launch", "other"]
  public static let commands = Set(ActivityCommand.allCases.map(\.rawValue))
  public static let appEvents: Set<String> = ["launch", "activate", "deactivate", "quit"]

  public static let fields: [String: [String: ActivityField]] = [
    "app": ["event": .oneOf(appEvents)],
    "nav": [
      "from": .oneOf(places), "to": .oneOf(places), "via": .oneOf(navVias),
      "state": .oneOf(Set(AttentionState.allCases.map(\.rawValue))),
    ],
    "terminal.ready": ["ms": .number, "wasLive": .bool, "left": .bool, "timedOut": .bool],
    "command": ["name": .oneOf(commands), "via": .oneOf(inputs)],
    "window": ["width": .number, "height": .number, "fullScreen": .bool],
    "error": ["where": .oneOf(requests.union(["other"])), "code": .oneOf(errorCodes)],
  ]

  /// Whether sbd may store the event that the app sent.
  public static func accepts(_ event: ActivityEvent) -> Bool {
    guard let rules = fields[event.kind], case .object(let data) = event.data else { return false }
    if let session = event.session, !isSessionId(session) { return false }
    return data.allSatisfy { key, value in rules[key]?.accepts(value) == true }
  }

  /// The requests that the app sends sbd, which an `error` event names.
  public static let requests: Set<String> = [
    "account-move", "account-use", "ack", "answer", "chat", "choose", "cleanup", "done", "followup-start",
    "group-account", "group-add", "group-describe", "group-move", "group-rm", "manager", "merge", "new", "note",
    "open", "plan-followup", "repo-add", "repos", "resolve-note", "resume", "rm", "rm-done", "send", "shell", "stop",
    "terminals",
  ]
  public static let errorCodes: Set<String> = ["refused", "connection", "decoding", "other"]

  /// What kind of failure an error is, without its message.
  public static func errorCode(_ error: Error) -> String {
    if error is DecodingError { return "decoding" }
    if let api = error as? APIError { return api.description == APIError.closed ? "connection" : "refused" }
    return (error as NSError).domain == NSPOSIXErrorDomain ? "connection" : "other"
  }

  /// The shape of the ids that `shortId("s")` makes. sbd also checks that it knows the session.
  static func isSessionId(_ s: String) -> Bool {
    s.count == 6 && s.first == "s" && s.dropFirst().allSatisfy { "abcdefghijkmnpqrstuvwxyz23456789".contains($0) }
  }
}

/// The app's commands that the activity log names.
public enum ActivityCommand: String, CaseIterable, Sendable {
  case newSession, newSessionInGroup, importSessions, newGroup, nextNeedingYou, openManager, showInbox, showBoard,
    filterByOrg
  case searchSessions, nextSession, previousSession, back, forward, recentPlaces, focusList, focusTerminal
  case stop, resume, toggleShell, toggleDone, acknowledge

  /// How a navigation that the command starts is named, or nil for a command that doesn't navigate.
  public var navVia: String? {
    switch self {
    case .back, .forward: return rawValue
    case .nextNeedingYou, .openManager, .showInbox, .showBoard, .nextSession, .previousSession: return "command"
    default: return nil
    }
  }
}
