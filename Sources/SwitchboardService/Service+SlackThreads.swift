import Foundation
import SwitchboardCore

/// The scan state of the Slack thread poll, on the state queue.
struct SlackPollState {
  var last: Int64 = 0
  var running = false
  /// The last whole-poll error that sbd logged.
  var lastError: String?
  /// Why the last due scan made no call, while the account has no budget.
  var skip: String?
  /// The thread keys that Check now asked for. The next scan that starts reads them first and drops them from here.
  var soon = Set<String>()
}

/// What sbd learned about one account's Slack connector in this run. Only `Service.slackQueue` touches it.
struct SlackAccountState {
  /// The user's own Slack id, from the profile call.
  var selfId: String?
  /// The `--disallowedTools` entries that both calls pass, learned from the init messages that listed extra tools.
  var deny: [String] = []
}

/// The outcome of one poll run: the user's Slack id and each asked thread's result in the order of the asks, or why
/// the whole run failed.
typealias SlackPollOutcome = Result<
  (selfId: String, reads: [Result<SlackPoll.ThreadRead, SlackPoll.ReadError>]), SlackPoll.ReadError
>

/// sbd reads the Slack threads among the sessions' links through headless `claude -p` calls on the claude.ai Slack
/// connector of sbd's own account, and keeps one `slack_threads` row per thread.
extension Service {
  static let slackQueue = DispatchQueue(label: "sbd.slack")

  /// The threads that the open `reply` waits of `waitHolders` name. sbd reads them whether or not a link lists them,
  /// and keeps their rows.
  func replyWaitThreads() -> [SlackThreadRef] {
    waitHolders().flatMap { $0.waits ?? [] }.compactMap { wait in
      wait.kind == .reply ? wait.replyThread.flatMap(SlackThreadRef.init(target:)) : nil
    }
  }

  /// Whether sbd reads Slack threads: `slack.pollSeconds` is above 0.
  var slackPollOn: Bool { config.slack.pollSeconds > 0 }

  /// Refuses a reply wait or a Check now while the poll is off.
  func requireSlackPoll() throws {
    guard slackPollOn else {
      throw APIError(
        "sbd doesn't read Slack threads while slack.pollSeconds is 0 in \(home.config), so a reply wait would never "
          + "resolve")
    }
  }

  /// The URL of the one Slack thread among the session's listed links, for a reply wait set without a target. A
  /// reply's link and its thread's link name one thread. It refuses a session with no thread or with several.
  func replyTarget(of id: String) throws -> String {
    let e = entries[id]!
    let threads = SlackWatch.uniqueThreads(e.session.links(found: e.facts.links)).map(\.link)
    let name = e.session.name
    guard threads.count == 1 else {
      throw APIError(
        threads.isEmpty
          ? "\(name) has no Slack thread among its links, so give the thread's link as --target"
          : "\(name) has \(threads.count) Slack threads among its links, so give one as --target: "
            + threads.map(\.url).joined(separator: ", "))
    }
    return threads[0].url
  }

  /// The wait with its thread's status, for a `reply` wait whose URL parses. `watched` is the result of
  /// `watchedSlackKeys`. Only a summary calls it, so no stored wait has the status.
  func withThreadStatus(_ wait: Wait, watched: Set<String>) -> Wait {
    guard wait.kind == .reply, let target = wait.replyThread else { return wait }
    var out = wait
    out.threadStatus = slackStatus(target, watched: watched, lookedAt: wait.created)
    return out
  }

  /// `wait-check`, the Check now of a reply wait, puts the wait's thread first in the next scheduled scan. It starts
  /// no scan. Only the user sends it, because each scan spends this Mac's tokens.
  func waitCheckRequest(_ args: JSON, origin: RequestOrigin) throws -> JSON {
    let id = try lookup(args)
    try requireUser(args, "Only you can check a reply wait's thread now.")
    try requireSlackPoll()
    let wait = try openWait(id, args["wait"]?.string).wait
    guard wait.kind == .reply, let target = wait.replyThread else {
      throw APIError("wait \(wait.id) isn't a reply wait on a Slack thread")
    }
    slackPoll.soon.insert(target.key)
    return try JSON(encoding: summary(id, for: origin))
  }

  /// The links that every session lists, hidden links excluded.
  private func listedLinks() -> [ExternalLink] {
    entries.values.flatMap { $0.session.links(found: $0.facts.links) }
  }

  /// The keys of the threads that sbd still reads for any session. None while the poll is off.
  func watchedSlackKeys(now: Int64) -> Set<String> {
    guard slackPollOn else { return [] }
    return Set(SlackWatch.threads(listedLinks(), now: now, replyWaits: replyWaitThreads()).map(\.key))
  }

  /// The link with its Slack thread's status, when it is a Slack link with a row or a watch. `watched` is the
  /// result of `watchedSlackKeys`.
  func withSlackStatus(_ link: ExternalLink, facts: SessionFacts, watched: Set<String>) -> ExternalLink {
    guard let target = link.linkTarget, target.kind == .slack else { return link }
    var out = link
    out.status = slackStatus(target, watched: watched, lookedAt: SlackThreadStatus.lookedAt(link: link, facts: facts))
    return out
  }

  /// The status of the Slack target from its thread's row. `watched` is the result of `watchedSlackKeys`.
  private func slackStatus(_ target: LinkTarget, watched: Set<String>, lookedAt: Int64) -> SlackThreadStatus? {
    SlackThreadStatus(
      target: target, row: slackThreads[target.key], watched: watched.contains(target.key), lookedAt: lookedAt)
  }

  /// Runs on each tick. Once per `slack.pollSeconds`, it drops the rows that neither a session's link nor an open
  /// reply wait names, and reads the watched threads that `SlackPoll.batch` picks, with the ones that Check now
  /// asked for first.
  func pollSlackThreadsIfDue(now: Int64) {
    guard slackPollOn, !slackPoll.running,
      now - slackPoll.last >= Int64(config.slack.pollSeconds * 1000)
    else { return }
    slackPoll.last = now
    let links = listedLinks()
    let replyWaits = replyWaitThreads()
    let kept = Set(links.compactMap(\.linkTarget).filter { $0.kind == .slack }.map(\.key) + replyWaits.map(\.key))
    let stale = slackThreads.keys.filter { !kept.contains($0) }
    if !stale.isEmpty {
      for key in stale { slackThreads[key] = nil }
      saveSlackThreads([:], deleting: stale)
    }
    let refs = SlackWatch.threads(links, now: now, replyWaits: replyWaits)
    guard !refs.isEmpty else { return }
    let env = headlessEnv(session: nil, account: nil)
    let account = ClaudeAccount(folder: env["CLAUDE_CONFIG_DIR"] ?? ClaudeAccount.defaultFolder)
    guard quota.hasBudget(account: account.folder) else {
      let skip = "skipping the Slack poll: \(account.folder) has no usage left"
      if slackPoll.skip != skip { logLine(skip) }
      slackPoll.skip = skip
      return
    }
    slackPoll.skip = nil
    let asks = SlackPoll.batch(refs, rows: slackThreads, first: slackPoll.soon).map { ref in
      (
        key: ref.key,
        ask: SlackPoll.Ask(channel: ref.channel, thread: ref.thread, oldest: slackThreads[ref.key]?.oldest)
      )
    }
    slackPoll.soon.subtract(asks.map(\.key))
    slackPoll.running = true
    let model = config.slack.model
    Service.slackQueue.async { [self] in
      let outcome = runSlackPoll(asks.map(\.ask), env: env, account: account, model: model, now: now)
      queue.sync {
        slackPoll.running = false
        applySlackPoll(outcome, asks: asks, now: now)
      }
    }
  }

  /// Learns the user's Slack id when this run doesn't know it yet, then reads the threads. Runs on `slackQueue`.
  private func runSlackPoll(
    _ asks: [SlackPoll.Ask], env: [String: String], account: ClaudeAccount, model: String, now: Int64
  ) -> SlackPollOutcome {
    let label = account.isDefault ? "~/.claude" : account.folder
    var state = slackAccounts[account.folder] ?? SlackAccountState()
    defer { slackAccounts[account.folder] = state }
    let selfId: String
    if let known = state.selfId {
      selfId = known
    } else {
      let profile = slackCall(
        .slackSelf, allowed: SlackPoll.profileTool, schema: SlackPoll.selfSchema, system: SlackPoll.selfSystem,
        input: SlackPoll.selfInput, timeout: 60, env: env, account: label, model: model, deny: &state.deny,
        parse: SlackPoll.parseSelf)
      switch profile {
      case .success(let id): selfId = id
      case .failure(let error): return .failure(SlackPoll.ReadError("can't read your Slack profile: \(error)"))
      }
      state.selfId = selfId
    }
    let poll = slackCall(
      .slackThreads, allowed: SlackPoll.readTool, schema: SlackPoll.threadsSchema, system: SlackPoll.threadsSystem,
      input: SlackPoll.threadsInput(asks), timeout: 60 + 20 * Double(asks.count), env: env, account: label,
      model: model, deny: &state.deny, parse: { try SlackPoll.parseThreads($0, asked: asks, you: selfId, now: now) })
    return poll.map { (selfId: selfId, reads: $0) }.mapError { SlackPoll.ReadError(oneLine("\($0)", max: 300)) }
  }

  /// One Slack call. When its init lists tools beyond its own, sbd adds deny entries for them and retries once.
  private func slackCall<T>(
    _ kind: HeadlessKind, allowed: String, schema: JSON, system: String, input: String, timeout: Double,
    env: [String: String], account: String, model: String, deny: inout [String], parse: (String) throws -> T
  ) -> Result<T, any Error> {
    func attempt() -> (Result<T, any Error>, extra: [String]) {
      let handler = SlackPoll.LineHandler(allowed: allowed, account: account)
      let call = headlessCall(
        kind, session: nil,
        arguments: SlackPoll.arguments(model: model, schema: schema, system: system, allowed: allowed, deny: deny),
        input: input, env: env, folder: home.path, timeout: timeout, onLine: handler.onLine, parse: parse)
      return (call.result, handler.extraTools)
    }
    let first = attempt()
    guard case .failure(let error) = first.0, error is Headless.Refused, !first.extra.isEmpty else { return first.0 }
    for entry in SlackPoll.denyEntries(for: first.extra) where !deny.contains(entry) { deny.append(entry) }
    return attempt().0
  }

  /// Updates each asked thread's row. A failed read sets the row's error and keeps what an earlier read found. A
  /// successful read records `now`, the scan's time, so a read never claims a time after a reply that it missed.
  private func applySlackPoll(_ outcome: SlackPollOutcome, asks: [(key: String, ask: SlackPoll.Ask)], now: Int64) {
    switch outcome {
    case .failure(let error):
      if slackPoll.lastError != error.reason { logLine("Slack poll failed: \(error.reason)") }
      slackPoll.lastError = error.reason
    case .success:
      slackPoll.lastError = nil
    }
    var changed: [String: SlackThread] = [:]
    for (i, (key, ask)) in asks.enumerated() {
      let before = slackThreads[key]
      var row = before ?? SlackThread(channel: ask.channel, thread: ask.thread)
      row.tried = now
      switch outcome {
      case .failure(let error):
        row.error = error.reason
      case .success(let poll):
        switch poll.reads[i] {
        case .success(let read):
          row.replies = ask.oldest == nil ? read.count : (row.replies ?? 0) + read.count
          if let ts = read.lastReplyTs, let user = read.lastReplyUser {
            row.lastReplyTs = ts
            row.lastReplyUser = user
            row.lastReplyName = read.lastReplyName
            row.lastReplyYou = user == poll.selfId
          }
          if let other = read.lastOther { row.record(other: other) }
          row.read = now
          row.error = nil
        case .failure(let error):
          if row.error != error.reason { logLine("can't read the Slack thread \(key): \(error.reason)") }
          row.error = error.reason
        }
      }
      if row != before {
        slackThreads[key] = row
        changed[key] = row
      }
    }
    if !changed.isEmpty { saveSlackThreads(changed, deleting: []) }
  }

  private func saveSlackThreads(_ threads: [String: SlackThread], deleting: [String]) {
    do { try store.save(slackThreads: threads, deleting: deleting) } catch {
      logLine("can't store the Slack threads: \(error)")
    }
  }
}
