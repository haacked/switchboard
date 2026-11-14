import Foundation

/// The replies of a group chat or a Manager conversation, and how many of
/// them the user has not read. Only those sessions' summaries carry it.
public struct ChatActivity: Codable, Equatable, Sendable {
  /// The event that marks replies read. Its `replies` is the count read.
  public static let readEvent = "chat-read"

  public var replies: Int
  public var unread: Int
  /// The time of the last reply or of the last prompt that the user sent.
  public var lastMessageAt: Int64?
  /// True for a Manager conversation in the sidebar's archive.
  public var archived: Bool?

  public init(replies: Int, unread: Int, lastMessageAt: Int64? = nil, archived: Bool? = nil) {
    self.replies = replies
    self.unread = unread
    self.lastMessageAt = lastMessageAt
    self.archived = archived
  }

  public init(_ facts: SessionFacts) {
    self.init(
      replies: facts.replies, unread: max(0, facts.replies - (facts.repliesRead ?? facts.replies)),
      lastMessageAt: facts.lastMessageAt)
  }
}

/// What a button or a row shows for a chat or a Manager conversation. Every
/// surface that shows a chat's state reads it from here, so they agree.
public enum ChatMark: Equatable, Sendable {
  /// The group has no chat yet.
  case none
  /// The chat waits on the user: an open prompt, or a permission, question,
  /// trust, or send card. The text is the reason.
  case needsMe(String)
  /// Replies that the user has not read, and whether a turn is running.
  case unread(Int, working: Bool)
  /// The chat's claude is in a turn.
  case working
  /// Nothing to show beyond the time of the last message.
  case idle(lastMessageAt: Int64?)

  public init(_ s: SessionSummary?) {
    guard let s else {
      self = .none
      return
    }
    if ChatMark.needsMe(cards: s.cards, openPrompt: s.openPrompt) {
      self = .needsMe(s.cards.first { ChatMark.needsMe($0.kind) }?.reason ?? s.reason)
    } else if let unread = s.activity?.unread, unread > 0 {
      self = .unread(unread, working: s.state == .working)
    } else if s.state == .working {
      self = .working
    } else {
      self = .idle(lastMessageAt: s.activity?.lastMessageAt)
    }
  }

  /// Whether the chat waits on the user. It counts send cards, which
  /// `Triage.hasBlockingPrompt` leaves out to keep them out of the Inbox.
  public static func needsMe(cards: [Card], openPrompt: Bool) -> Bool {
    openPrompt || cards.contains { needsMe($0.kind) }
  }

  static func needsMe(_ kind: Card.Kind) -> Bool {
    switch kind {
    case .permission, .question, .trust, .send: true
    }
  }

  public var isNeedsMe: Bool {
    if case .needsMe = self { true } else { false }
  }

  public var unreadCount: Int {
    if case .unread(let n, _) = self { n } else { 0 }
  }
}
