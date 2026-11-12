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

  private enum CodingKeys: String, CodingKey { case state, reason, error, target }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let state = try c.decode(String.self, forKey: .state)
    switch state {
    case "copyOnly": self = .copyOnly(reason: try c.decodeIfPresent(String.self, forKey: .reason))
    case "checking": self = .checking
    case "unresolved": self = .unresolved(error: try c.decode(String.self, forKey: .error))
    case "ready": self = .ready(try c.decode(ResolvedTarget.self, forKey: .target))
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
    }
  }
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

  public init(targets: [String: TargetResult] = [:]) {
    self.targets = targets
  }
}

public enum DraftReplies {
  /// sbd read a draft's target: {ref, number, and one of resolved, refused, or error}.
  public static let targetEvent = "draft_target"

  /// Names one draft: the item's ref and the draft's 1-based number.
  public static func key(ref: String, number: Int) -> String { "\(ref)/\(number)" }

  /// The draft's state on the session's item with `ref`. `pr` is the
  /// session's PR as the poller last read it.
  public static func state(_ draft: InboxDraft, ref: String, pr: PullRequest?, facts: DraftReplyFacts) -> DraftPost {
    guard let replyTo = draft.replyTo else { return .copyOnly(reason: nil) }
    let target: ReplyTarget
    do {
      target = try ReplyTarget.parse(replyTo)
    } catch {
      return .copyOnly(reason: "\(error)")
    }
    guard let pr else { return .copyOnly(reason: "sbd hasn't read this session's PR yet") }
    guard target.matches(pr) else {
      return .copyOnly(
        reason: "it replies on \(target.repo)#\(target.pr), and the session's PR is \(pr.repo)#\(pr.number)")
    }
    switch facts.targets[key(ref: ref, number: draft.number)] {
    case .resolved(let resolved) where resolved.target == target: return .ready(resolved)
    case .resolved, nil: return .checking
    case .refused(let reason): return .copyOnly(reason: reason)
    case .failed(let error): return .unresolved(error: error)
    }
  }

  /// The error that a draft shows when gh couldn't read the comment with `id`.
  public static func resolutionError(_ ghError: String, id: Int64) -> String {
    if ghError.contains("(HTTP 404)") { return "GitHub has no comment \(id), or gh can't see it" }
    if ghError.contains("(HTTP 401)") { return "GitHub refused gh's login. Run `gh auth login`, then check again" }
    return ghError
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
  /// The latest `draft_target` for a draft replaces any earlier one.
  mutating func applyDraftReplies(_ event: Event) {
    guard event.kind == DraftReplies.targetEvent, let ref = event.data["ref"]?.string,
      let number = event.data["number"]?.int
    else { return }
    let d = event.data
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
    draftReplies.targets[DraftReplies.key(ref: ref, number: number)] = result
  }
}
