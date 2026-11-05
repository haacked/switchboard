import Foundation

/// A message to several sessions that a Claude session asked for. It waits
/// for the user's decision in the app, because session text can quote PR
/// comments and logs that carry instructions.
public struct GroupMessage: Codable, Equatable, Sendable {
  /// How long a pending message waits for the user's decision before it expires.
  public static let expirySeconds: Int64 = 3600

  public var group: String
  public var groupName: String
  /// The message exactly as Claude wrote it. The app shows it and never interprets it.
  public var text: String
  /// The sessions that the message goes to when the user sends it.
  public var targets: [GroupSend.Target]
  /// Milliseconds since the epoch.
  public var expires: Int64

  public init(group: String, groupName: String, text: String, targets: [GroupSend.Target], expires: Int64) {
    self.group = group
    self.groupName = groupName
    self.text = text
    self.targets = targets
    self.expires = expires
  }

  public var summary: String {
    "a message to \(targets.count == 1 ? "1 session" : "\(targets.count) sessions") in \(groupName)"
  }
}

/// What became of a group message that waited for the user.
public enum SendDecision: String, Codable, Sendable {
  case pending
  case sent
  case cancelled
  case expired
}

extension GroupSend {
  /// The answer for a group message that waited for the user.
  public init(_ message: GroupMessage, pending: Int64, decision: SendDecision, deliveries: [Result]? = nil) {
    self.init(
      group: message.group, targets: message.targets, sent: decision == .sent, deliveries: deliveries,
      pending: pending, decision: decision, expires: message.expires)
  }
}

extension Card {
  /// The card that a `send_pending` event opens, or nil when its data isn't a group message.
  public init?(groupMessage event: Event) {
    guard let message = try? JSONCoding.convert(event.data, to: GroupMessage.self) else { return nil }
    id = event.id
    session = event.session
    kind = .send
    tool = "send_group"
    summary = message.summary
    input = [:]
    questions = []
    since = event.t
    deferred = false
    hookClosed = false
    send = message
  }
}

extension Client {
  /// Asks sbd about the group message every 0.5 s until the user decides or
  /// `timeout` seconds pass, and returns the last `GroupSend`.
  public func awaitGroupMessage(_ id: Int64, timeout: TimeInterval) throws -> GroupSend {
    let deadline = Date().addingTimeInterval(timeout)
    while true {
      let status = try call("send-pending", ["card": .number(Double(id))], as: GroupSend.self)
      if status.decision != .pending || Date() >= deadline { return status }
      Thread.sleep(forTimeInterval: 0.5)
    }
  }
}
