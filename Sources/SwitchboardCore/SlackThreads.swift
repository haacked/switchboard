import Foundation

/// What sbd knows about one Slack thread, as a row of the `slack_threads` table keyed by the thread's
/// `LinkTarget.key`. One row serves every session that links the thread.
public struct SlackThread: Codable, Equatable, Sendable {
  public var channel: String
  /// The root message's ts.
  public var thread: String
  /// The reply count, or nil before the first successful read.
  public var replies: Int?
  public var lastReplyTs: String?
  public var lastReplyUser: String?
  public var lastReplyName: String?
  /// Whether the last reply's user is the user's own Slack id. sbd decides it when it reads the reply, so the mark
  /// never needs the id later.
  public var lastReplyYou: Bool
  /// The newest reply whose user is not the user's own Slack id, as sbd parsed it from a read's message headers.
  /// sbd decides "not you" when it reads the reply, as for `lastReplyYou`. The last reply can be yours while this
  /// one is someone else's.
  public var lastOtherReplyTs: String?
  public var lastOtherReplyUser: String?
  public var lastOtherReplyName: String?
  /// When the last successful read ended, in ms since the epoch.
  public var read: Int64?
  /// When sbd last asked for the thread, whether or not the read succeeded, in ms since the epoch.
  public var tried: Int64?
  /// Why the last read failed. A successful read clears it.
  public var error: String?

  public init(channel: String, thread: String) {
    self.channel = channel
    self.thread = thread
    lastReplyYou = false
  }

  /// The `oldest` of the next read: none before the first successful read, then the last reply's ts, or the root's
  /// when the thread had no replies. `slack_read_thread` returns only the messages after it.
  public var oldest: String? { replies == nil ? nil : lastReplyTs ?? thread }

  /// Stores the header as the newest reply that isn't yours, unless the stored one has the same ts or a later one.
  public mutating func record(other header: SlackPoll.Header) {
    guard let value = SlackPoll.tsValue(header.ts) else { return }
    if let stored = lastOtherReplyTs.flatMap(SlackPoll.tsValue), stored >= value { return }
    lastOtherReplyTs = header.ts
    lastOtherReplyUser = header.user
    lastOtherReplyName = header.name
  }
}

/// A Slack thread that sbd reads: one that a session's links watch, or one that an open `reply` wait names.
public struct SlackThreadRef: Equatable, Sendable {
  public var key: String
  public var channel: String
  public var thread: String
}

/// Which Slack links sbd reads.
public enum SlackWatch {
  /// How long sbd reads a thread after its link entered a session's list.
  public static let windowMs: Int64 = 3 * 24 * 60 * 60 * 1000

  /// Whether sbd reads the link's thread: a Slack link inside its window, or one whose thread an open `reply` wait
  /// names. `target` is the link's `linkTarget`.
  public static func isWatched(_ link: ExternalLink, target: LinkTarget, now: Int64, replyWaits: Set<String>) -> Bool {
    target.kind == .slack && (now < link.t + windowMs || replyWaits.contains(target.key))
  }

  /// The threads that sbd reads, one per thread key: the links' threads in the order of their first watched link,
  /// then the open reply waits' threads that no link gives, in the order of `replyWaits`.
  public static func threads(_ links: [ExternalLink], now: Int64, replyWaits: [SlackThreadRef]) -> [SlackThreadRef] {
    let waitKeys = Set(replyWaits.map(\.key))
    var seen = Set<String>()
    var refs: [SlackThreadRef] = []
    for link in links {
      guard let target = link.linkTarget, isWatched(link, target: target, now: now, replyWaits: waitKeys),
        let channel = target.channel, let thread = target.thread, seen.insert(target.key).inserted
      else { continue }
      refs.append(SlackThreadRef(key: target.key, channel: channel, thread: thread))
    }
    return refs + replyWaits.filter { seen.insert($0.key).inserted }
  }
}

/// The `status` of a Slack link in a session summary.
public struct SlackThreadStatus: Codable, Equatable, Sendable {
  public struct LastReply: Codable, Equatable, Sendable {
    /// The reply's ts in ms since the epoch, truncated.
    public var t: Int64
    public var user: String
    public var name: String?
    public var you: Bool
  }

  public var replies: Int?
  public var lastReply: LastReply?
  public var read: Int64?
  public var error: String?
  /// Whether sbd still reads the thread for any session.
  public var watched: Bool
  /// Whether the last reply is someone else's and came after the user last looked.
  public var newReply: Bool

  /// The status of a link from its `LinkTarget` and its thread's row. It is nil for a target that is not Slack, and
  /// for a Slack thread with neither a row nor a watch. `lookedAt` is the time from `lookedAt(link:facts:)`.
  public init?(target: LinkTarget, row: SlackThread?, watched: Bool, lookedAt: Int64) {
    guard target.kind == .slack, row != nil || watched else { return nil }
    replies = row?.replies
    read = row?.read
    error = row?.error
    self.watched = watched
    if let row, (row.replies ?? 0) > 0, let ts = row.lastReplyTs, let t = SlackPoll.tsValue(ts).map({ $0 / 1000 }),
      let user = row.lastReplyUser
    {
      lastReply = LastReply(t: t, user: user, name: row.lastReplyName, you: row.lastReplyYou)
    }
    newReply = lastReply.map { !$0.you && $0.t > lookedAt } ?? false
  }

  /// When the user last looked at the link's thread: the latest of the time the link entered the list, an Open of
  /// its page from Switchboard, and the session's last acknowledgment. The floor at the link's time keeps a pasted
  /// link to an old thread from marking the replies that already exist.
  public static func lookedAt(link: ExternalLink, facts: SessionFacts) -> Int64 {
    max(link.t, facts.linkOpened[ExternalLink.pageKey(link.url)] ?? 0, facts.lastAcknowledged ?? 0)
  }

  /// The text on one line with control characters escaped, then cut to `max`. Escaping first keeps the cut a bound
  /// on what the row shows, because an escape is several characters long.
  private static func clipped(_ text: String, max: Int) -> String {
    truncated(oneLine(text, max: .max).printable, max: max)
  }

  /// The status as `sb get` and the app show it, such as "3 replies, last from Alice 2h ago, read 5m ago".
  public func line(now: Int64) -> String {
    guard let replies else {
      return (error.map { "not read: \(Self.clipped($0, max: 200))" } ?? "not read yet").printable
    }
    var text = replies == 0 ? "no replies" : replies == 1 ? "1 reply" : "\(replies) replies"
    if let lastReply {
      let who = lastReply.you ? "you" : Self.clipped(lastReply.name ?? lastReply.user, max: 80)
      text += ", last from \(who) \(ago(lastReply.t, now: now)) ago"
    }
    if let read { text += ", read \(ago(read, now: now)) ago" }
    if newReply { text += ", new reply" }
    if let error { text += "; reads since then failed: \(Self.clipped(error, max: 200))" }
    return text.printable
  }
}

extension SessionSummary {
  /// Whether any of the session's links has a Slack reply from someone else since the user last looked.
  public var hasNewReply: Bool { links?.contains { $0.status?.newReply == true } ?? false }
}
