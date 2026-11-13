import Foundation

/// What a draft's Post button may do, as the item shows it.
public enum DraftPost: Codable, Equatable, Sendable {
  /// The draft only copies. A reason says why a draft whose card named a
  /// `replyTo` can't post.
  case copyOnly(reason: String?)
  /// sbd is reading the target with gh.
  case checking
  /// gh couldn't read the target. `sb draft check` reads it again.
  case unresolved(error: String)
  case ready(ResolvedTarget)
  /// sbd runs gh to post the reply.
  case posting(ResolvedTarget)
  /// sbd can't tell whether GitHub got the reply. `sb draft check` looks for it.
  case unknown(ResolvedTarget, error: String)
  /// GitHub refused the reply, so no comment exists and the draft can post again.
  case failed(ResolvedTarget, error: String)
  /// GitHub has the reply at `url`, with the text that the user posted.
  case posted(ResolvedTarget, url: String, text: String)

  private enum CodingKeys: String, CodingKey { case state, reason, error, target, url, text }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let state = try c.decode(String.self, forKey: .state)
    switch state {
    case "copyOnly": self = .copyOnly(reason: try c.decodeIfPresent(String.self, forKey: .reason))
    case "checking": self = .checking
    case "unresolved": self = .unresolved(error: try c.decode(String.self, forKey: .error))
    case "ready": self = .ready(try c.decode(ResolvedTarget.self, forKey: .target))
    case "posting": self = .posting(try c.decode(ResolvedTarget.self, forKey: .target))
    case "unknown":
      self = .unknown(
        try c.decode(ResolvedTarget.self, forKey: .target), error: try c.decode(String.self, forKey: .error))
    case "failed":
      self = .failed(
        try c.decode(ResolvedTarget.self, forKey: .target), error: try c.decode(String.self, forKey: .error))
    case "posted":
      self = .posted(
        try c.decode(ResolvedTarget.self, forKey: .target), url: try c.decode(String.self, forKey: .url),
        text: try c.decode(String.self, forKey: .text))
    default:
      throw DecodingError.dataCorruptedError(forKey: .state, in: c, debugDescription: "unknown draft state \(state)")
    }
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .copyOnly(let reason):
      try c.encode("copyOnly", forKey: .state)
      try c.encodeIfPresent(reason, forKey: .reason)
    case .checking:
      try c.encode("checking", forKey: .state)
    case .unresolved(let error):
      try c.encode("unresolved", forKey: .state)
      try c.encode(error, forKey: .error)
    case .ready(let target):
      try c.encode("ready", forKey: .state)
      try c.encode(target, forKey: .target)
    case .posting(let target):
      try c.encode("posting", forKey: .state)
      try c.encode(target, forKey: .target)
    case .unknown(let target, let error):
      try c.encode("unknown", forKey: .state)
      try c.encode(target, forKey: .target)
      try c.encode(error, forKey: .error)
    case .failed(let target, let error):
      try c.encode("failed", forKey: .state)
      try c.encode(target, forKey: .target)
      try c.encode(error, forKey: .error)
    case .posted(let target, let url, let text):
      try c.encode("posted", forKey: .state)
      try c.encode(target, forKey: .target)
      try c.encode(url, forKey: .url)
      try c.encode(text, forKey: .text)
    }
  }
}

extension DraftPost {
  /// The target of a draft that has one.
  public var target: ResolvedTarget? {
    switch self {
    case .ready(let t), .posting(let t), .unknown(let t, _), .failed(let t, _), .posted(let t, _, _): t
    case .copyOnly, .checking, .unresolved: nil
    }
  }

  /// The target of a draft that may post: only a ready or a failed one.
  public var postable: ResolvedTarget? {
    switch self {
    case .ready(let t), .failed(let t, _): t
    default: nil
    }
  }
}

/// The latest post of one draft, from its `draft_posting` event and the
/// outcome event after it.
public struct PostAttempt: Codable, Equatable, Sendable {
  public enum Outcome: Codable, Equatable, Sendable {
    case posting
    case posted(url: String)
    case failed(String)
    case unknown(String)
  }

  public var ref: String
  public var number: Int
  public var target: ResolvedTarget
  /// The text that sbd sent.
  public var text: String
  /// The draft's text as the session wrote it.
  public var draftText: String
  public var label: String?
  public var outcome: Outcome

  public init(
    ref: String, number: Int, target: ResolvedTarget, text: String, draftText: String, label: String?,
    outcome: Outcome
  ) {
    self.ref = ref
    self.number = number
    self.target = target
    self.text = text
    self.draftText = draftText
    self.label = label
    self.outcome = outcome
  }

  /// The data of the `draft_posting` event, or of the `draft_posted` event
  /// with GitHub's `url` and comment `id`.
  public func eventData(posted: (url: String, id: Int64)? = nil) throws -> JSON {
    var data: [String: JSON] = [
      "ref": .string(ref), "number": .number(Double(number)), "target": try JSON(encoding: target),
      "text": .string(text), "draftText": .string(draftText),
    ]
    if let label { data["label"] = .string(label) }
    if let posted {
      data["url"] = .string(posted.url)
      data["id"] = .number(Double(posted.id))
    } else {
      data["root"] = .number(Double(target.root))
    }
    return .object(data)
  }

  /// The data of a `draft_post_failed` or `draft_post_unknown` event.
  public func outcomeData(error: String) -> JSON {
    ["ref": .string(ref), "number": .number(Double(number)), "error": .string(error)]
  }

  public var post: DraftPost {
    switch outcome {
    case .posting: .posting(target)
    case .posted(let url): .posted(target, url: url, text: text)
    case .failed(let error): .failed(target, error: error)
    case .unknown(let error): .unknown(target, error: error)
    }
  }
}

/// A reply that GitHub has, as the notice to the session names it.
public struct PostedReply: Codable, Equatable, Sendable {
  /// The id of the `draft_posted` event.
  public var event: Int64
  public var number: Int
  public var label: String?
  public var url: String
  public var text: String
  public var draftText: String
}

/// How a POST through gh ended.
public enum PostOutcome: Equatable, Sendable {
  case posted(url: String, id: Int64)
  /// GitHub refused the reply, so no comment exists.
  case failed(String)
  /// GitHub may have the reply.
  case unknown(String)
}

/// What sbd found when it read a draft's target with gh.
public enum TargetResult: Codable, Equatable, Sendable {
  case resolved(ResolvedTarget)
  /// GitHub places the comment on another PR, or sbd can't find the
  /// thread's root. Reading it again would give the same answer.
  case refused(String)
  /// gh failed, as on a 404, a refused login, or a network error.
  case failed(String)
}

/// The draft reply events of one session, folded.
public struct DraftReplyFacts: Codable, Equatable, Sendable {
  /// The latest target result of each draft, keyed by `DraftReplies.key`.
  public var targets: [String: TargetResult]
  /// The latest post of each draft, keyed by `DraftReplies.key`.
  public var attempts: [String: PostAttempt] = [:]
  /// Every `draft_posted`, oldest first.
  public var posted: [PostedReply] = []
  /// The last `draft_posted` event that a notice told the session about.
  public var heardThrough: Int64 = 0

  public init(targets: [String: TargetResult] = [:]) {
    self.targets = targets
  }

  /// Another draft's attempt that posted, or may have posted, `draftText` to
  /// the same thread as `target`. A posted one comes first.
  public func sameReply(_ draftText: String, to target: ResolvedTarget, except key: String) -> (
    key: String, attempt: PostAttempt
  )? {
    let matches = attempts.filter { k, a in
      if case .failed = a.outcome { return false }
      return k != key && a.draftText == draftText && a.target.sameThread(as: target)
    }
    .sorted { $0.key < $1.key }
    let posted = matches.first { if case .posted = $0.value.outcome { true } else { false } }
    return (posted ?? matches.first).map { ($0.key, $0.value) }
  }
}

public enum DraftReplies {
  /// sbd read a draft's target: {ref, number, and one of resolved, refused, or error}.
  public static let targetEvent = "draft_target"
  /// sbd is about to run gh: {ref, number, target, root, text, draftText, label?}.
  public static let postingEvent = "draft_posting"
  /// GitHub has the reply: {ref, number, target, url, id, text, draftText, label?}.
  public static let postedEvent = "draft_posted"
  /// GitHub refused the reply, or a check found no such reply: {ref, number, error}.
  public static let failedEvent = "draft_post_failed"
  /// sbd can't tell whether GitHub got the reply: {ref, number, error}.
  public static let unknownEvent = "draft_post_unknown"
  /// The session heard of each `draft_posted` up to the event id {through}.
  public static let heardEvent = "replies_heard"

  public static let interrupted = "sbd restarted while it was posting"
  public static let noSuchReply =
    "sbd couldn't tell whether GitHub got the reply, and the thread has no such reply, so you can post it again"
  /// How much of an edited reply the notice quotes.
  static let noticeTextLength = 2_000

  /// Names one draft: the item's ref and the draft's 1-based number.
  public static func key(ref: String, number: Int) -> String { "\(ref)/\(number)" }

  /// The draft's state on the session's item with `ref`. `pr` is the
  /// session's PR as the poller last read it.
  /// A recorded post comes first, so a later change to the PR never hides
  /// a posted link or an attempt whose outcome sbd doesn't know.
  public static func state(_ draft: InboxDraft, ref: String, pr: PullRequest?, facts: DraftReplyFacts) -> DraftPost {
    let key = key(ref: ref, number: draft.number)
    if let attempt = facts.attempts[key] { return attempt.post }
    guard let replyTo = draft.replyTo else { return .copyOnly(reason: nil) }
    let target: ReplyTarget
    do {
      target = try ReplyTarget.parse(replyTo)
    } catch {
      return .copyOnly(reason: "\(error)")
    }
    if !facts.attempts.isEmpty, case .resolved(let resolved) = facts.targets[key], resolved.target == target,
      let earlier = facts.sameReply(draft.text, to: resolved, except: key)?.attempt,
      case .posted = earlier.outcome
    {
      return earlier.post
    }
    guard let pr else { return .copyOnly(reason: "sbd hasn't read this session's PR yet") }
    guard target.matches(pr) else {
      return .copyOnly(
        reason: "it replies on \(target.repo)#\(target.pr), and the session's PR is \(pr.repo)#\(pr.number)")
    }
    switch facts.targets[key] {
    case .resolved(let resolved) where resolved.target == target: return .ready(resolved)
    case .resolved, nil: return .checking
    case .refused(let reason): return .copyOnly(reason: reason)
    case .failed(let error): return .unresolved(error: error)
    }
  }

  /// What gh's stderr says about a failure.
  struct GhFailure {
    let unauthorized: Bool
    let notFound: Bool
    let clientError: Bool
    let noLogin: Bool

    init(_ stderr: String) {
      unauthorized = stderr.contains("(HTTP 401)")
      notFound = stderr.contains("(HTTP 404)")
      clientError = stderr.contains(#/\(HTTP 4[0-9]{2}\)/#)
      noLogin = stderr.contains("gh auth login")
    }

    func refusedLogin(then again: String) -> String {
      "GitHub refused gh's login. Run `gh auth login`, then \(again)"
    }
  }

  /// The error that a draft shows when gh couldn't read the comment with `id`.
  public static func resolutionError(_ ghError: String, id: Int64) -> String {
    let failure = GhFailure(ghError)
    if failure.notFound { return "GitHub has no comment \(id), or gh can't see it" }
    if failure.unauthorized { return failure.refusedLogin(then: "check again") }
    return ghError
  }

  /// How a POST ended. Only GitHub's 4xx answer, or gh's missing login,
  /// shows that no comment exists. A timeout, a 5xx, a network error, or an
  /// answer that names no comment may hide a comment that GitHub created.
  public static func outcome(_ r: CommandResult) -> PostOutcome {
    if r.status == 0 {
      if let json = JSON.parse(r.stdout), let url = json["html_url"]?.string, let id = json["id"]?.int {
        return .posted(url: url, id: Int64(id))
      }
      return .unknown("gh printed no new comment")
    }
    let failure = GhFailure(r.stderr)
    if failure.clientError || failure.noLogin { return .failed(plainError(r.stderr)) }
    let text = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    return .unknown(text.isEmpty ? "gh stopped with status \(r.status) before it answered" : text)
  }

  /// gh's error as a draft shows it.
  public static func plainError(_ stderr: String) -> String {
    let failure = GhFailure(stderr)
    if failure.unauthorized { return failure.refusedLogin(then: "post again.") }
    if failure.noLogin { return "gh has no login. Run `gh auth login`, then post again." }
    if failure.notFound {
      return "GitHub answered Not Found: the thread is gone from GitHub, or gh can't see it"
    }
    let text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? "gh failed and printed no error" : text
  }

  /// The newest comment in `comments` by `login` whose body is `text`. With
  /// a `root`, only a reply to that review comment counts. GitHub's
  /// `created_at` and sbd's clock can disagree, so no time limits the match.
  public static func matchingReply(in comments: [JSON], root: Int64?, login: String, text: String) -> (
    url: String, id: Int64
  )? {
    let normalized = { TriageDrafts.trimBlankLines(TriageDrafts.normalize($0, unquote: false)) }
    let wanted = normalized(text)
    return comments.compactMap { c -> (url: String, id: Int64)? in
      guard c["user"]?["login"]?.string?.lowercased() == login.lowercased(),
        normalized(c["body"]?.string ?? "") == wanted, let url = c["html_url"]?.string, let id = c["id"]?.int
      else { return nil }
      if let root, ReplyTarget.parentId(c) != root { return nil }
      return (url, Int64(id))
    }
    .max { $0.id < $1.id }
  }

  /// What the next prompt tells the session about the replies that the user posted.
  public static func notice(_ posted: [PostedReply]) -> String {
    let lines = posted.map { reply in
      var line = "- \(reply.label ?? "Draft \(reply.number)"): \(reply.url)"
      if reply.text != reply.draftText {
        let cut = reply.text.count > noticeTextLength
        let text = cut ? String(reply.text.prefix(noticeTextLength)) + "… (the rest is at the URL)" : reply.text
        line += "\n  the user edited it: \(text)"
      }
      return line
    }
    return (["Switchboard: the user posted these replies that you drafted. Don't draft or post them again."] + lines)
      .joined(separator: "\n")
  }

  /// Whether the session's item may show a draft as `checking`. It is a
  /// cheap test that never builds the item. It errs toward true. Only a
  /// session summary's draft names a target. A draft with a recorded
  /// attempt or a recorded target is not waiting for a read.
  public static func mayBeChecking(_ facts: SessionFacts) -> Bool {
    guard facts.cards.isEmpty, facts.openPermission == nil, facts.openQuestion == nil,
      let summary = facts.sessionSummary
    else { return false }
    let ref = "summary:\(facts.sessionSummaryId)"
    return summary.drafts.enumerated().contains { i, draft in
      let key = key(ref: ref, number: i + 1)
      guard let replyTo = draft.replyTo, facts.draftReplies.attempts[key] == nil else { return false }
      switch facts.draftReplies.targets[key] {
      case nil: return true
      case .resolved(let resolved)?: return (try? ReplyTarget.parse(replyTo)) != resolved.target
      default: return false
      }
    }
  }

  /// The line that says sbd can't tell whether GitHub got the reply.
  public static func unknownLine(error: String, session: String, number: Int) -> String {
    "sbd can't tell whether GitHub got the reply: \(error). Check: sb draft check \(session) \(number)"
  }

  /// The `draft_target` event's data for a result.
  public static func targetData(ref: String, number: Int, _ result: TargetResult) throws -> JSON {
    var data: [String: JSON] = ["ref": .string(ref), "number": .number(Double(number))]
    switch result {
    case .resolved(let target): data["resolved"] = try JSON(encoding: target)
    case .refused(let reason): data["refused"] = .string(reason)
    case .failed(let error): data["error"] = .string(error)
    }
    return .object(data)
  }
}

extension SessionFacts {
  /// The latest `draft_target` for a draft replaces any earlier one, as does
  /// its latest post attempt.
  mutating func applyDraftReplies(_ event: Event) {
    let d = event.data
    if event.kind == DraftReplies.heardEvent, let through = d["through"]?.int {
      draftReplies.heardThrough = max(draftReplies.heardThrough, Int64(through))
      return
    }
    guard let ref = d["ref"]?.string, let number = d["number"]?.int else { return }
    let key = DraftReplies.key(ref: ref, number: number)
    switch event.kind {
    case DraftReplies.targetEvent: applyTarget(d, key: key)
    case DraftReplies.postingEvent, DraftReplies.postedEvent:
      guard let raw = d["target"], let target = try? JSONCoding.convert(raw, to: ResolvedTarget.self),
        let text = d["text"]?.string, let draftText = d["draftText"]?.string
      else { return }
      var attempt = PostAttempt(
        ref: ref, number: number, target: target, text: text, draftText: draftText, label: d["label"]?.string,
        outcome: .posting)
      if event.kind == DraftReplies.postedEvent {
        guard let url = d["url"]?.string else { return }
        attempt.outcome = .posted(url: url)
        draftReplies.posted.append(
          PostedReply(
            event: event.id, number: number, label: attempt.label, url: url, text: text, draftText: draftText))
      }
      draftReplies.attempts[key] = attempt
    case DraftReplies.failedEvent, DraftReplies.unknownEvent:
      guard let error = d["error"]?.string else { return }
      draftReplies.attempts[key]?.outcome = event.kind == DraftReplies.failedEvent ? .failed(error) : .unknown(error)
    default:
      break
    }
  }

  private mutating func applyTarget(_ d: JSON, key: String) {
    let result: TargetResult
    if let raw = d["resolved"], let target = try? JSONCoding.convert(raw, to: ResolvedTarget.self) {
      result = .resolved(target)
    } else if let reason = d["refused"]?.string {
      result = .refused(reason)
    } else if let error = d["error"]?.string {
      result = .failed(error)
    } else {
      return
    }
    draftReplies.targets[key] = result
  }
}
