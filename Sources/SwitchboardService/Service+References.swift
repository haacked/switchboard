import Foundation
import SwitchboardCore
import os

extension Service {
  /// The id of the live session on `host` other than `id` whose PR has the node id `prId`, or nil when no other session
  /// on that host owns it. Sessions on another host never count, because a remote caller may not read them. It takes
  /// the state queue.
  func prOwner(of prId: String, besides id: String, onHost host: String?) -> String? {
    queue.sync {
      entries.values.first {
        $0.session.id != id && $0.session.host == host && !$0.session.done && $0.facts.pr?.id == prId
      }?.session.id
    }
  }

  /// The `ref-details` request. It answers from a session's PR, then from the Issues cache, then from sbd's cache of
  /// earlier reads, and only then reads the item from GitHub. A fresh answer in sbd's cache that is newer than the
  /// session's PR or the Issues cache wins over it. With `fresh: true` it skips those answers and reads
  /// GitHub, unless a read of the item already runs. It runs off the state queue, because a read waits on GitHub.
  func referenceDetails(_ args: JSON) throws -> ReferenceReply {
    let ref = try Self.reference(args)
    let fresh = args["fresh"]?.bool == true
    if !fresh, let local = queue.sync(execute: { localReferenceDetails(ref) }) {
      if let at = local.at, case .found(let read)? = references.fresh(ref.key), (read.read ?? .min) > at {
        return .found(read)
      }
      return .found(local.details)
    }
    guard let github else { throw APIError("GitHub polling is off, so sbd can't read \(ref.repo)#\(ref.number)") }
    switch references.answer(ref.key, fresh: fresh, read: { github.readReference(ref) }) {
    case .found(let details): return .found(details)
    case .notFound: return .notFound(repo: ref.repo, number: ref.number)
    case .failed(let message): throw APIError(message)
    }
  }

  /// The item that the arguments name: `ref` as `owner/name#N` or a GitHub issue or PR URL, or `repo` and
  /// `number`. A URL must name the item's page as the app links it, so it goes through `GitHubRef(linkableURL:)`.
  static func reference(_ args: JSON) throws -> GitHubRef {
    if let value = args["ref"] {
      guard args["repo"] == nil, args["number"] == nil else { throw APIError("give ref, or repo and number, not both") }
      let text = value.string?.trimmingCharacters(in: .whitespaces) ?? ""
      let ref = text.contains("://") ? GitHubRef(linkableURL: text) : GitHubRef(parsing: text)
      guard let ref else {
        throw APIError("name the item as owner/name#N or by its GitHub issue or pull request URL")
      }
      return ref
    }
    guard let repo = args["repo"]?.string, let number = args["number"]?.int,
      let ref = GitHubRef(repo: repo, number: number)
    else { throw APIError("name the item by ref, or by repo as owner/name and number from 1 to 999999999") }
    return ref
  }

  /// A session's PR or a cached issue that `ref` names, with the time it was read, or nil when that is unknown. A cached
  /// issue's read time is the end of the last poll that read the Issues sources. It runs on the state queue.
  private func localReferenceDetails(_ ref: GitHubRef) -> (details: ReferenceDetails, at: Int64?)? {
    let owner = entries.values.lazy.first { $0.facts.pr.map { ref.same(repo: $0.repo, number: $0.number) } == true }
    if let pr = owner?.facts.pr { return (ReferenceDetails(pr: pr), owner?.facts.prRead) }
    guard let issue = issueCache.issues.first(where: { $0.id == ref.key }) else { return nil }
    var details = ReferenceDetails(issue: issue)
    details.read = issueCache.polledAt
    return (details, issueCache.polledAt)
  }
}

/// sbd's cache of the items it read from GitHub, and the reads that run. A request for a key whose read runs waits
/// for that read and gets its answer, so one card opened twice costs one request.
final class ReferenceFetches: Sendable {
  private final class Read: @unchecked Sendable {
    /// The reader leaves the group after it sets `answer`, so a waiter reads `answer` only after the read ends.
    let done = DispatchGroup()
    var answer = ReferenceCache.Answer.failed("the read of GitHub ended without an answer")

    init() { done.enter() }
  }

  private struct State: Sendable {
    var cache = ReferenceCache()
    var running: [String: Read] = [:]
  }

  private enum Step: Sendable {
    case answered(ReferenceCache.Answer)
    case wait(Read)
    case read(Read)
  }

  private let state = OSAllocatedUnfairLock(initialState: State())

  /// The cached answer for `key` while it is fresh, else nil.
  func fresh(_ key: String) -> ReferenceCache.Answer? { state.withLock { $0.cache.fresh(key, now: nowMs()) } }

  /// The fresh cached answer for `key`, the answer of the read that runs for it, or the answer of a new read. With
  /// `fresh`, it skips the cached answer. The lock is never held while `read` runs.
  func answer(_ key: String, fresh: Bool, read: () -> ReferenceCache.Answer) -> ReferenceCache.Answer {
    let step: Step = state.withLock { s in
      if !fresh, let answer = s.cache.fresh(key, now: nowMs()) { return .answered(answer) }
      if let running = s.running[key] { return .wait(running) }
      let started = Read()
      s.running[key] = started
      return .read(started)
    }
    switch step {
    case .answered(let answer):
      return answer
    case .wait(let running):
      running.done.wait()
      return running.answer
    case .read(let started):
      let answer = read()
      started.answer = answer
      state.withLock { s in
        s.cache.store(answer, for: key, now: nowMs())
        s.running[key] = nil
      }
      started.done.leave()
      return answer
    }
  }
}

extension GitHubPoller {
  /// Reads one item with `GitHub.referenceQuery`. Every error becomes a `.failed` answer, so the requests that wait
  /// for this read always get one.
  func readReference(_ ref: GitHubRef) -> ReferenceCache.Answer {
    let (owner, name) = GitHub.ownerAndName(ref.repo)
    var stats = Stats()
    do {
      let response = try request(
        GitHub.referenceQuery, ["o": .string(owner), "n": .string(name), "num": .number(Double(ref.number))],
        stats: &stats)
      guard var details = GitHub.parseReference(response["data"] ?? .null) else { return .notFound }
      details.read = nowMs()
      return .found(details)
    } catch {
      return .failed("\(error)")
    }
  }
}
