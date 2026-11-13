import Foundation
import SwitchboardCore

extension Service {
  static let resolveTimeoutSeconds = 30.0

  /// A gh failure while reading a comment, as the draft shows it.
  private struct ReadFailure: Error {
    let message: String
  }

  /// `caller` lets `draft-post` refuse a client inside any session.
  /// `draft-check` changes nothing on GitHub, so any caller may run it.
  func draftReplyRequest(_ op: String, _ args: JSON, caller: Caller) throws -> JSON {
    switch op {
    case "draft-post": return try postDraft(args, caller: caller)
    case "draft-check": return try checkDraft(args)
    default: throw APIError("unknown draft op \(op)")
    }
  }

  /// Starts a gh read of each target that the session's item shows as
  /// `checking`. A recorded failure makes the draft `unresolved`, so only
  /// `draft-check` reads it again. sbd calls this after each event and tick,
  /// and once at startup.
  func resolveDraftTargets(_ id: String, _ verdict: Verdict) {
    guard let e = entries[id], DraftReplies.mayBeChecking(e.facts), let item = Triage.item(e.facts, verdict) else {
      return
    }
    for draft in item.drafts where draft.post == .checking {
      guard let replyTo = draft.replyTo, let target = try? ReplyTarget.parse(replyTo) else { continue }
      startGhJob(resolvingKey(id, ref: item.ref, number: draft.number), session: id) {
        self.resolve(target)
      } settle: { result in
        self.recordTarget(id, ref: item.ref, number: draft.number, result)
      }
    }
  }

  /// Runs `work` on the gh queue unless a job with `key` is in flight, then
  /// runs `settle` with its result on the state queue unless the session is
  /// gone. The key is in flight until then. It returns whether it started.
  @discardableResult
  private func startGhJob<T>(
    _ key: String, session id: String, work: @escaping () -> T, settle: @escaping (T) -> Void
  ) -> Bool {
    guard resolvingDrafts.insert(key).inserted else { return false }
    ghJobs.addOperation { [self] in
      let result = work()
      queue.async { [self] in
        resolvingDrafts.remove(key)
        guard entries[id] != nil else { return }
        settle(result)
      }
    }
    return true
  }

  /// Runs `body` on the state queue once the check that holds `job.key` is
  /// done, and frees the key. It throws when the session is gone.
  private func finishCheck<T>(_ job: CheckJob, _ body: () throws -> T) throws -> T {
    try queue.sync {
      resolvingDrafts.remove(job.key)
      guard entries[job.id] != nil else { throw APIError("\(job.id) was removed") }
      return try body()
    }
  }

  private func triageJSON(_ id: String) throws -> JSON { try JSON(encoding: summary(id).triage) }

  /// What `draft-check` reads with gh.
  private enum DraftCheck {
    case target(ReplyTarget)
    case outcome(PostAttempt)
  }

  private struct CheckJob {
    let id: String
    let key: String
    let ref: String
    let work: DraftCheck
  }

  private enum CheckStart {
    case settled(JSON)
    case job(CheckJob)
  }

  /// `draft-check` {session, draft} reads the target of an `unresolved`
  /// draft again, or looks on GitHub for the reply of an `unknown` post. A
  /// draft whose post waits on another draft's unknown post of the same text
  /// to the same thread checks that post. It returns the session's item. Any
  /// other draft's item comes back unchanged. A failed look for a reply
  /// throws, and the post stays unknown.
  private func checkDraft(_ args: JSON) throws -> JSON {
    guard let number = args["draft"]?.int else { throw APIError("name a draft by its number") }
    let start: CheckStart = try queue.sync {
      let id = try lookup(args)
      let e = entries[id]!
      guard let item = summary(id).triage else { throw APIError("\(e.session.name) needs nothing from you") }
      guard let draft = item.drafts.first(where: { $0.number == number }) else {
        throw APIError("\(e.session.name)'s item has no draft \(number)")
      }
      let own = DraftReplies.key(ref: item.ref, number: number)
      var work: (ref: String, number: Int, check: DraftCheck)?
      switch draft.post {
      case .unresolved:
        if let replyTo = draft.replyTo, let target = try? ReplyTarget.parse(replyTo) {
          work = (item.ref, number, .target(target))
        }
      case .unknown:
        if let attempt = e.facts.draftReplies.attempts[own] { work = (item.ref, number, .outcome(attempt)) }
      case .ready(let target), .failed(let target, _):
        if let other = e.facts.draftReplies.sameReply(draft.text, to: target, except: own)?.attempt,
          case .unknown = other.outcome
        {
          work = (other.ref, other.number, .outcome(other))
        }
      default:
        break
      }
      guard let work else { return .settled(try triageJSON(id)) }
      let key = resolvingKey(id, ref: work.ref, number: work.number)
      guard resolvingDrafts.insert(key).inserted else { return .settled(try triageJSON(id)) }
      return .job(CheckJob(id: id, key: key, ref: work.ref, work: work.check))
    }
    switch start {
    case .settled(let json): return json
    case .job(let job): return try runCheck(job, draft: number)
    }
  }

  private func runCheck(_ job: CheckJob, draft number: Int) throws -> JSON {
    switch job.work {
    case .target(let target):
      let result = resolve(target)
      return try finishCheck(job) {
        recordTarget(job.id, ref: job.ref, number: number, result)
        return try triageJSON(job.id)
      }
    case .outcome(let attempt):
      let found = Result { try findReply(attempt) }
      return try finishCheck(job) {
        settleOutcome(job.id, attempt, try found.get())
        return try triageJSON(job.id)
      }
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
      let root: Int64
      switch try ReplyTarget.resolution(of: target, comment: comment) {
      case .resolved(let resolved): return .resolved(resolved)
      case .fetchRoot(let parent): root = parent
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
    // A comment always has these. An answer without them is a bad read, and Check again retries it.
    guard json["user"]?["login"]?.string != nil, json["html_url"]?.string != nil else {
      throw ReadFailure(message: "gh api \(path) printed a comment without an author or a URL")
    }
    return json
  }

  // MARK: Posting

  /// `draft-post` {session, ref, draft, text} posts `text`, trimmed of its
  /// leading and trailing blank lines, as the user's reply to the draft's
  /// target. Only a `ready` or `failed` draft on the item that the caller
  /// saw posts, and only while its target is on the session's current PR.
  /// sbd refuses a caller that runs below any session's pane or below its
  /// tmux server, or whose ancestry it can't read, because only the user's
  /// click may post. It refuses a text with a NUL, which gh can't take. It
  /// stores `draft_posting` before gh runs, so a crash during the POST leaves
  /// a record that the restart turns into `unknown`.
  private func postDraft(_ args: JSON, caller: Caller) throws -> JSON {
    let command = "sb draft post"
    guard let number = args["draft"]?.int else { throw APIError("name a draft by its number") }
    guard let ref = args["ref"]?.string else { throw APIError("name the item that you looked at by its ref") }
    guard let raw = args["text"]?.string else { throw APIError("give the reply's text") }
    let ancestry = try caller.ancestry(command: command)
    let text = TriageDrafts.trimBlankLines(raw)
    let fresh = buildSnapshot()
    let (id, flight, attempt) = try queue.sync { () -> (String, String, PostAttempt) in
      let id = try lookup(args)
      install(fresh)
      if let refusal = postCallerRefusal(ancestry, command: command) { throw refusal }
      let e = entries[id]!
      let name = e.session.name
      guard let item = summary(id).triage else { throw APIError("\(name) needs nothing from you") }
      guard item.ref == ref else { throw APIError("\(name) has a new item since you looked. Look again") }
      guard let draft = item.drafts.first(where: { $0.number == number }) else {
        throw APIError("\(name)'s item has no draft \(number)")
      }
      let target = try postableTarget(draft, session: id)
      guard let pr = e.facts.pr, target.target.matches(pr) else {
        throw APIError(
          "draft \(number) replies on \(target.target.repo)#\(target.target.pr), which is not \(name)'s PR now")
      }
      guard !text.isEmpty else { throw APIError("the reply is empty") }
      guard !text.hasNul else { throw APIError("the reply has a NUL character, which gh can't send") }
      guard text.count <= TriageDrafts.maxLength else {
        throw APIError(
          "the reply has \(text.count) characters, and GitHub takes at most \(TriageDrafts.maxLength) here")
      }
      let key = DraftReplies.key(ref: ref, number: number)
      if let same = e.facts.draftReplies.sameReply(draft.text, to: target, except: key)?.attempt {
        throw APIError(sameReplyRefusal(same, session: id, number: number))
      }
      let flight = resolvingKey(id, ref: ref, number: number)
      guard postingDrafts.insert(flight).inserted else { throw APIError("draft \(number) is already posting") }
      let attempt = PostAttempt(
        ref: ref, number: number, target: target, text: text, draftText: draft.text, label: draft.label,
        outcome: .posting)
      do {
        try recordStored(id, DraftReplies.postingEvent, try attempt.eventData())
      } catch {
        postingDrafts.remove(flight)
        throw APIError("sbd can't record the post, so it didn't post: \(error)")
      }
      return (id, flight, attempt)
    }
    let outcome: PostOutcome
    do {
      outcome = DraftReplies.outcome(
        try runGhResult(attempt.target.postArgs(body: text), timeout: Service.reviewTimeoutSeconds))
    } catch {
      // gh didn't start, so nothing reached GitHub.
      outcome = .failed("\(error)")
    }
    return try queue.sync {
      postingDrafts.remove(flight)
      switch outcome {
      case .posted(let url, let commentId):
        record(id, DraftReplies.postedEvent, try attempt.eventData(posted: (url, commentId)))
        guard entries[id] != nil else { return ["url": .string(url)] }
        return try triageJSON(id)
      case .failed(let error):
        record(id, DraftReplies.failedEvent, attempt.outcomeData(error: error))
        throw APIError(error)
      case .unknown(let error):
        record(id, DraftReplies.unknownEvent, attempt.outcomeData(error: error))
        // GitHub may not list a reply that it just created. The user checks this one, not the tick.
        checkedUnknown.insert(flight)
        throw APIError(DraftReplies.unknownLine(error: error, session: id, number: attempt.number))
      }
    }
  }

  /// The refusal for a caller that runs below any session's pane or below
  /// sbd's tmux server, or nil. A program that a session starts with
  /// `tmux new-session` or `tmux new-window` runs below the server and
  /// outside every pane. It runs on the state queue, after `install` of a
  /// fresh snapshot.
  private func postCallerRefusal(_ ancestry: Set<Int>?, command: String) -> APIError? {
    guard let ancestry else { return nil }
    let advice = "Posting needs your click, so run it from a terminal outside the sessions."
    if let inside = entries.keys.sorted().first(where: { isInside($0, ancestry) }) {
      return APIError("`\(command)` runs inside \(inside). \(advice)")
    }
    let servers = Set(snapshot.panes.values.map(\.server).filter(Processes.isValidPid))
    guard ancestry.isDisjoint(with: servers) else {
      return APIError("`\(command)` runs in sbd's tmux server, where the sessions run. \(advice)")
    }
    return nil
  }

  /// The target of a draft that may post, or the refusal that says why it may not.
  private func postableTarget(_ draft: InboxDraft, session id: String) throws -> ResolvedTarget {
    let n = draft.number
    if let target = draft.post.postable { return target }
    switch draft.post {
    case .ready, .failed:
      throw APIError("draft \(n) can't post")
    case .posting:
      throw APIError("draft \(n) is already posting")
    case .posted(_, let url, _):
      throw APIError("draft \(n) is already posted at \(url)")
    case .unknown(_, let error):
      throw APIError("sbd can't tell whether GitHub got draft \(n): \(error). Check first: sb draft check \(id) \(n)")
    case .checking:
      throw APIError("sbd is still reading the comment that draft \(n) replies to. Look again in a moment")
    case .unresolved(let error):
      throw APIError(
        "gh can't read the comment that draft \(n) replies to: \(error). Check again: sb draft check \(id) \(n)")
    case .copyOnly(let reason):
      throw APIError("draft \(n) only copies\(reason.map { ": \($0)" } ?? "")")
    }
  }

  /// The refusal for draft `number`, whose text another draft posted, or may
  /// have posted, to the same thread.
  private func sameReplyRefusal(_ other: PostAttempt, session id: String, number: Int) -> String {
    switch other.outcome {
    case .posted(let url):
      return "this reply is already posted at \(url)"
    case .unknown(let error):
      return
        "sbd can't tell whether GitHub got the same reply from an earlier item: \(error). Check first: sb draft check \(id) \(number)"
    default:
      return "the same reply is already posting from an earlier item"
    }
  }

  // MARK: Unknown outcomes

  /// Records `draft_post_unknown` for each post that sbd started and never
  /// finished, because sbd stopped during the POST.
  func markInterruptedPosts() {
    for (id, e) in entries {
      for attempt in e.facts.draftReplies.attempts.values where attempt.outcome == .posting {
        record(id, DraftReplies.unknownEvent, attempt.outcomeData(error: DraftReplies.interrupted))
      }
    }
  }

  /// Starts one look on GitHub for the reply of each unknown post of the
  /// session that this sbd run didn't post, as after a restart. A look that
  /// fails leaves the post unknown for `draft-check`.
  func checkUnknownPosts(_ id: String) {
    guard let attempts = entries[id]?.facts.draftReplies.attempts else { return }
    for attempt in attempts.values {
      guard case .unknown = attempt.outcome else { continue }
      let key = resolvingKey(id, ref: attempt.ref, number: attempt.number)
      guard !checkedUnknown.contains(key) else { continue }
      let started = startGhJob(key, session: id) { () -> Result<(url: String, id: Int64)?, Error> in
        Result { try self.findReply(attempt) }
      } settle: { found in
        switch found {
        case .success(let reply): self.settleOutcome(id, attempt, reply)
        case .failure(let error): logLine("can't check draft \(attempt.number) of \(id): \(error)")
        }
      }
      if started { checkedUnknown.insert(key) }
    }
  }

  /// Records what a look on GitHub found for an unknown post, unless the
  /// post settled meanwhile.
  private func settleOutcome(_ id: String, _ attempt: PostAttempt, _ reply: (url: String, id: Int64)?) {
    let key = DraftReplies.key(ref: attempt.ref, number: attempt.number)
    guard case .unknown = entries[id]?.facts.draftReplies.attempts[key]?.outcome else { return }
    do {
      if let reply {
        record(id, DraftReplies.postedEvent, try attempt.eventData(posted: reply))
      } else {
        record(id, DraftReplies.failedEvent, attempt.outcomeData(error: DraftReplies.noSuchReply))
      }
    } catch {
      logLine("can't record the outcome of draft \(attempt.number) of \(id): \(error)")
    }
  }

  /// The gh user's reply in the attempt's thread whose body is the posted
  /// text, or nil when the thread has none. It runs off the state queue.
  private func findReply(_ attempt: PostAttempt) throws -> (url: String, id: Int64)? {
    let login = try viewerLogin()
    let t = attempt.target.target
    let list = t.commentsPath
    let output = try runGh(
      ["api", "--paginate", "--jq", ".[] | @json", "\(list)?per_page=100"], timeout: Service.reviewTimeoutSeconds)
    let comments = try output.split(whereSeparator: \.isNewline).map { line in
      guard let comment = JSON.parse(String(line)), comment.object != nil else {
        throw APIError("gh api \(list) printed a line that is not a comment")
      }
      return comment
    }
    return DraftReplies.matchingReply(
      in: comments, root: t.kind == .reviewComment ? attempt.target.root : nil, login: login, text: attempt.text)
  }

  /// gh's login, which sbd reads once per run.
  private func viewerLogin() throws -> String {
    if let login = queue.sync(execute: { ghLogin }) { return login }
    let login = try runGh(["api", "user", "--jq", ".login"], timeout: Service.resolveTimeoutSeconds)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !login.isEmpty else { throw APIError("gh api user printed no login") }
    queue.sync { ghLogin = login }
    return login
  }

  // MARK: The notice to the session

  /// The notice of the replies that the user posted since the work session
  /// last heard, or nil. It records `replies_heard`, so each reply's notice
  /// goes once.
  func repliesNotice(_ id: String) -> String? {
    guard let e = entries[id], e.session.kind == .work else { return nil }
    let facts = e.facts.draftReplies
    let unheard = facts.posted.filter { $0.event > facts.heardThrough }
    guard let last = unheard.last else { return nil }
    record(id, DraftReplies.heardEvent, ["through": .number(Double(last.event))])
    return DraftReplies.notice(unheard)
  }
}
