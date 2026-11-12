import Foundation
import SwitchboardCore

extension Service {
  static let resolveTimeoutSeconds = 30.0

  /// A gh failure while reading a comment, as the draft shows it.
  private struct ReadFailure: Error {
    let message: String
  }

  func draftReplyRequest(_ op: String, _ args: JSON) throws -> JSON {
    switch op {
    case "draft-check": return try checkDraft(args)
    default: throw APIError("unknown draft op \(op)")
    }
  }

  /// Starts a gh read of each target that the session's item shows as
  /// `checking`. A recorded failure makes the draft `unresolved`, so only
  /// `draft-check` reads it again. sbd calls this after each event and tick,
  /// and once at startup.
  func resolveDraftTargets(_ id: String, _ verdict: Verdict) {
    guard let e = entries[id], e.facts.sessionSummary?.drafts.contains(where: { $0.replyTo != nil }) == true,
      let item = Triage.item(e.facts, verdict)
    else { return }
    for draft in item.drafts where draft.post == .checking {
      guard let replyTo = draft.replyTo, let target = try? ReplyTarget.parse(replyTo) else { continue }
      let key = resolvingKey(id, ref: item.ref, number: draft.number)
      guard resolvingDrafts.insert(key).inserted else { continue }
      ghJobs.addOperation { [self] in
        let result = resolve(target)
        queue.async { [self] in
          resolvingDrafts.remove(key)
          guard entries[id] != nil else { return }
          recordTarget(id, ref: item.ref, number: draft.number, result)
        }
      }
    }
  }

  /// `draft-check` {session, draft} reads the target of an `unresolved`
  /// draft again, and returns the session's item. Any other draft's item
  /// comes back unchanged.
  private func checkDraft(_ args: JSON) throws -> JSON {
    guard let number = args["draft"]?.int else { throw APIError("name a draft by its number") }
    let (id, check) = try queue.sync { () -> (String, (key: String, ref: String, target: ReplyTarget)?) in
      let id = try lookup(args)
      let name = entries[id]!.session.name
      guard let item = summary(id).triage else { throw APIError("\(name) needs nothing from you") }
      guard let draft = item.drafts.first(where: { $0.number == number }) else {
        throw APIError("\(name)'s item has no draft \(number)")
      }
      guard case .unresolved = draft.post, let replyTo = draft.replyTo, let target = try? ReplyTarget.parse(replyTo)
      else { return (id, nil) }
      let key = resolvingKey(id, ref: item.ref, number: number)
      guard resolvingDrafts.insert(key).inserted else { return (id, nil) }
      return (id, (key, item.ref, target))
    }
    let result = check.map { resolve($0.target) }
    return try queue.sync {
      if let check { resolvingDrafts.remove(check.key) }
      guard entries[id] != nil else { throw APIError("\(id) was removed") }
      if let check, let result { recordTarget(id, ref: check.ref, number: number, result) }
      return try JSON(encoding: summary(id).triage)
    }
  }

  private func resolvingKey(_ id: String, ref: String, number: Int) -> String {
    "\(id) \(DraftReplies.key(ref: ref, number: number))"
  }

  private func recordTarget(_ id: String, ref: String, number: Int, _ result: TargetResult) {
    do {
      record(id, DraftReplies.targetEvent, try DraftReplies.targetData(ref: ref, number: number, result))
    } catch {
      logLine("can't record the target of draft \(number) of \(id): \(error)")
    }
  }

  /// Reads the target with gh, then the thread's root when the target is a
  /// reply. A gh failure is `failed`. A comment that GitHub places on
  /// another PR, or a root that sbd can't find, is `refused`.
  private func resolve(_ target: ReplyTarget) -> TargetResult {
    do {
      let comment = try readComment(target.getPath, id: target.id)
      let first = try ReplyTarget.resolution(of: target, comment: comment)
      if let resolved = first.resolved { return .resolved(resolved) }
      guard let root = first.rootToFetch else {
        return .refused("GitHub reports no thread root for comment \(target.id)")
      }
      let rootPath = ReplyTarget(repo: target.repo, pr: target.pr, kind: .reviewComment, id: root).getPath
      let rootComment = try readComment(rootPath, id: root)
      return .resolved(try ReplyTarget.root(of: target, rootComment: rootComment, child: comment))
    } catch let failure as ReadFailure {
      return .failed(failure.message)
    } catch {
      return .refused("\(error)")
    }
  }

  private func readComment(_ path: String, id: Int64) throws -> JSON {
    let output: String
    do {
      output = try runGh(["api", path], timeout: Service.resolveTimeoutSeconds)
    } catch {
      throw ReadFailure(message: DraftReplies.resolutionError("\(error)", id: id))
    }
    guard let json = JSON.parse(output), json.object != nil else {
      throw ReadFailure(message: "gh api \(path) printed no JSON object")
    }
    // A comment always has these, so an answer without them is a bad read, which Check again retries.
    guard json["user"]?["login"]?.string != nil, json["html_url"]?.string != nil else {
      throw ReadFailure(message: "gh api \(path) printed a comment without an author or a URL")
    }
    return json
  }
}
