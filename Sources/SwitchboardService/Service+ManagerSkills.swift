import Foundation
import SwitchboardCore

typealias SkillDecider = @Sendable (String) -> ManagerSkillGate.Decision
typealias SkillRunOutcome = Result<(key: String, answer: SkillClassifier.Answer), SkillFailure>

/// The skills that Manager conversations and the operator can load, and their `work` or `safe` labels.
extension Service {
  /// How long a refresh waits before it runs a failed key again.
  static let skillRetryMs: Int64 = 15 * 60_000
  /// How long a manager-kind prompt or Skill call waits after an account's last scan before it scans again.
  static let skillRescanMs: Int64 = 60_000

  /// The account folder of each manager-kind session on this Mac, mapped to
  /// the account's most recently active one. Runs on the state queue.
  func managerSkillAccounts() -> [String: String] {
    var latest: [String: (id: String, at: Int64)] = [:]
    for (id, e) in entries {
      guard let account = managerSkillAccount(id) else { continue }
      if let seen = latest[account], seen.at >= e.facts.lastActivity { continue }
      latest[account] = (id, e.facts.lastActivity)
    }
    return latest.mapValues(\.id)
  }

  /// The account folder of a manager-kind session on this Mac, or nil for every other session. Runs on the state
  /// queue.
  func managerSkillAccount(_ id: String) -> String? {
    guard entries[id]?.session.kind.runsInManagerFolder == true, case .local(let account) = claudeAccount(of: id)
    else { return nil }
    return account.folder
  }

  /// Scans the skills of every account that a manager-kind session uses. Runs on the state queue.
  func refreshManagerSkills() {
    for account in managerSkillAccounts().keys.sorted() { refreshManagerSkills(account: account) }
  }

  /// Scans the account's skills on `skillScanQueue`, then stores the index
  /// and queues the runs that it needs. Runs on the state queue.
  func refreshManagerSkills(account: String) {
    guard let scan = skillScan(account: account) else { return }
    skillScanQueue.async { [self] in
      let found = scan()
      queue.async { [self] in
        skillIndex[account] = found
        queueSkillRuns(account)
      }
    }
  }

  /// Runs on the state queue. It returns a function that runs discovery off
  /// the queue, with the listing of the account's most recently active
  /// manager-kind session. It returns nil when no such session uses the account.
  private func skillScan(account: String) -> (() -> [String: CatalogEntry])? {
    guard let id = managerSkillAccounts()[account] else { return nil }
    skillRefreshed[account] = nowMs()
    let (findTranscript, cached, machine, cwd) = (
      transcriptFinder(id), slashListings[id], mac.machine, home.managerFolder
    )
    return { [self] in
      let listing = skillListing(id, findTranscript: findTranscript, machine: machine, cached: cached)
      return SkillCatalog.discover(account: account, cwd: cwd, listing: listing, machine: machine)
    }
  }

  /// Queues a run for each of the account's entries whose key has no label,
  /// no run on its way, and no failure of the account in the last
  /// `skillRetryMs`. A name that config.json labels never runs. Runs on the
  /// state queue.
  func queueSkillRuns(_ account: String) {
    let settings = config.managerSkills
    let now = nowMs()
    for entry in (skillIndex[account] ?? [:]).values.sorted(by: { $0.name < $1.name }) {
      guard settings.override(entry.name) == nil, let key = entry.key(model: settings.model),
        skillLabels.labels[key] == nil, !skillQueued.contains(key)
      else { continue }
      if let failure = skillFailures[account]?[key], now - failure.t < Self.skillRetryMs { continue }
      skillQueued.insert(key)
      skillJobs.addOperation { [self] in
        let (outcome, fromClaude) = classifySkill(entry, account: account, settings: settings)
        queue.async { [self] in finishSkillRun(entry, key: key, account: account, outcome, fromClaude: fromClaude) }
      }
    }
  }

  /// Labels the entry under the account's login, off the state queue. The
  /// label's key is the hash of the text that the run read, which differs
  /// from the queued key when the file changed after the scan. `fromClaude`
  /// is true when the claude call itself failed, timed out, or didn't start.
  private func classifySkill(_ entry: CatalogEntry, account: String, settings: ManagerSkillSettings)
    -> (outcome: SkillRunOutcome, fromClaude: Bool)
  {
    func failure(_ category: SkillFailure.Category, _ message: String, fromClaude: Bool = false)
      -> (SkillRunOutcome, Bool)
    {
      (.failure(SkillFailure(category: category, message: message, t: nowMs())), fromClaude)
    }
    do {
      try requireSignedIn(["account": .string(account)])
    } catch {
      return failure(.signedOut, "\(error)")
    }
    guard queue.sync(execute: { quota }).hasBudget(account: account) else {
      return failure(.noQuota, "no quota left for \(account)")
    }
    let text: String
    let hash: String
    if let path = entry.path {
      guard let read = SkillHash.read(path, on: mac.machine) else { return failure(.failed, "can't read \(path)") }
      (text, hash) = (String(decoding: read.head, as: UTF8.self), read.hash)
    } else if let description = entry.description {
      (text, hash) = ("description: \(description)", SkillHash.listing(name: entry.name, description: description))
    } else {
      return failure(.failed, "\(entry.name) has neither a file nor a description")
    }
    if let shared = queue.sync(execute: { skillAccountFailures[account] }), nowMs() - shared.t < Self.skillRetryMs {
      return (.failure(shared), false)
    }
    let outcome = headlessCall(
      .skillLabel, session: nil, arguments: SkillClassifier.arguments(model: settings.model),
      input: SkillClassifier.input(name: entry.name, text: text),
      env: queue.sync { headlessEnv(session: nil, account: ClaudeAccount(folder: account)) }, folder: home.path,
      timeout: settings.timeoutSeconds, parse: SkillClassifier.parse)
    switch outcome.result {
    case .success(let answer):
      return (.success((SkillLabelCache.key(hash: hash, model: settings.model), answer)), false)
    case .failure(let error as Headless.TimedOut):
      return failure(.timeout, "\(error)", fromClaude: true)
    case .failure(let error) where outcome.reply == nil || error is Headless.ExitError:
      return failure(.failed, "\(error)", fromClaude: true)
    case .failure(let error):
      return failure(.badAnswer, "\(error)")
    }
  }

  /// Saves a label, or keeps the failure in memory. A failure `fromClaude` is also the account's. Runs on the
  /// state queue.
  private func finishSkillRun(
    _ entry: CatalogEntry, key: String, account: String, _ outcome: SkillRunOutcome, fromClaude: Bool
  ) {
    skillQueued.remove(key)
    switch outcome {
    case .success(let (labelKey, answer)):
      skillFailures[account]?[key] = nil
      skillAccountFailures[account] = nil
      skillLabels.labels[labelKey] = SkillLabelCache.Label(
        label: answer.label, reason: answer.reason, model: config.managerSkills.model, t: nowMs())
      saveSkillLabels()
    case .failure(let failure):
      skillFailures[account, default: [:]][key] = failure
      if fromClaude { skillAccountFailures[account] = failure }
      logLine("can't label the skill \(entry.name) of \(account): \(failure.message)")
      // Another account's scan skips the key while this run is queued. So the other accounts queue their runs now.
      for other in managerSkillAccounts().keys.sorted() where other != account { queueSkillRuns(other) }
    }
  }

  private func saveSkillLabels() {
    do {
      try skillLabels.save(home.skillLabels)
    } catch {
      logLine("can't save the skill labels: \(error)")
    }
  }

  /// The `manager-skills` request. It answers the rows of every account that
  /// a manager-kind session uses, or of `session`'s account. `relabel` and
  /// `all` scan the folders again first. Then `relabel` drops the labels and
  /// failures of those names' current keys and queues them again, and `all`
  /// does the same for every name. It runs off the state queue.
  func managerSkills(_ args: JSON) throws -> JSON {
    let all = args["all"]?.bool == true
    let names = (args["relabel"]?.array ?? []).compactMap(\.string).map { String($0.trimmingPrefix("/")) }
    let rescan = all || !names.isEmpty
    let scans = try queue.sync {
      () -> [(account: String, scan: (() -> [String: CatalogEntry])?)] in
      try skillAccounts(args["session"]?.string).sorted().map { ($0, rescan ? skillScan(account: $0) : nil) }
    }
    var found: [String: [String: CatalogEntry]] = [:]
    for (account, scan) in scans {
      if let scan { found[account] = skillScanQueue.sync(execute: scan) }
    }
    return try queue.sync {
      let accounts = scans.map(\.account)
      found.forEach { skillIndex[$0.key] = $0.value }
      if rescan { try relabelSkills(all ? nil : names, accounts: accounts) }
      let settings = config.managerSkills
      let rows = accounts.flatMap { account in
        ManagerSkillRow.rows(
          skillIndex[account] ?? [:], settings: settings, labels: skillLabels, failures: skillFailures[account] ?? [:],
          queued: skillQueued)
      }
      return try JSON(encoding: rows)
    }
  }

  /// The accounts that the request covers: every one that a manager-kind
  /// session uses, or the account of the conversation or operator that `ref`
  /// names. Runs on the state queue.
  private func skillAccounts(_ ref: String?) throws -> [String] {
    let accounts = managerSkillAccounts()
    guard let ref, !ref.isEmpty else { return Array(accounts.keys) }
    let sessions = entries.values.map(\.session).filter(\.kind.runsInManagerFolder)
    let id = try resolveRef(ref, "Manager conversation", sessions.map { ($0.id, $0.name) })
    guard case .local(let account) = claudeAccount(of: id) else { return [] }
    return [account.folder]
  }

  /// Drops the labels and failures of the names' current keys, or of every
  /// name when `names` is nil, and the accounts' failures, and queues them
  /// again. It throws for a name that no account holds. Runs on the state
  /// queue.
  private func relabelSkills(_ names: [String]?, accounts: [String]) throws {
    if let names {
      let settings = config.managerSkills
      let known = Set(accounts.flatMap { (skillIndex[$0] ?? [:]).keys } + settings.work + settings.safe)
      let unknown = names.filter { !known.contains($0) }
      guard unknown.isEmpty else { throw APIError("no skill named \(unknown.joined(separator: ", "))") }
    }
    let model = config.managerSkills.model
    for account in accounts {
      skillAccountFailures[account] = nil
      for entry in (skillIndex[account] ?? [:]).values where names?.contains(entry.name) ?? true {
        guard let key = entry.key(model: model) else { continue }
        skillLabels.labels[key] = nil
        skillFailures[account]?[key] = nil
      }
    }
    saveSkillLabels()
    accounts.forEach(queueSkillRuns)
  }

  // MARK: The gate

  /// The UserPromptSubmit gate of a manager-kind session. Each prompt clears the session's bypass. Only a prompt
  /// whose command matches the armed name gets past the gate, and its turn then lets Skill calls through. It
  /// returns the block answer for a work skill, after it records `skill_blocked` and delivers the next queued
  /// message, because Claude Code sends no Stop after a block. Runs on the state queue.
  func managerSkillPromptGate(_ id: String, _ payload: JSON, stamp: HostEventStamp?) -> JSON? {
    guard let account = gatedSkillAccount(id, stamp: stamp) else { return nil }
    let bypass = entries[id]?.skillBypass
    entries[id]?.skillBypass = nil
    let armed = bypass == .turn ? nil : bypass
    guard let name = SkillCommand.name(inPrompt: payload["prompt"]?.string ?? "") else { return nil }
    switch skillDecision(name, account: account, bypass: armed) {
    case .bypassed:
      entries[id]?.skillBypass = .turn
      record(id, "skill_bypassed", ["skill": .string(name)])
    case .blocked(let by):
      record(id, "skill_blocked", ["skill": .string(name), "via": "prompt", "by": .string(by.rawValue)])
      deliverPending(id, after: 0.5)
      return [
        "decision": "block",
        "reason": .string(ManagerSkillGate.promptReason(skill: name, session: id)),
      ]
    case .unchecked(let failure):
      recordSkillUnchecked(id, name, account: account, failure)
    case .ignored, .allowed:
      break
    }
    return nil
  }

  /// The PreToolUse gate of a manager-kind session and its subagents. It returns the deny answer for a Skill or
  /// SlashCommand call of a work skill, which a run-here turn lets through. Runs on the state queue.
  func managerSkillToolGate(_ id: String, _ payload: JSON, stamp: HostEventStamp?) -> JSON? {
    guard
      let name = SkillCommand.name(inToolCall: payload["tool_name"]?.string ?? "", input: payload["tool_input"]),
      let account = gatedSkillAccount(id, stamp: stamp)
    else { return nil }
    let bypass = entries[id]?.skillBypass == .turn ? SkillBypass.turn : nil
    switch skillDecision(name, account: account, bypass: bypass) {
    case .blocked(let by):
      record(id, "skill_blocked", ["skill": .string(name), "via": "tool", "by": .string(by.rawValue)])
      return [
        "hookSpecificOutput": [
          "hookEventName": "PreToolUse", "permissionDecision": "deny",
          "permissionDecisionReason": .string(ManagerSkillGate.toolReason(skill: name)),
        ]
      ]
    case .unchecked(let failure):
      recordSkillUnchecked(id, name, account: account, failure)
    case .ignored, .allowed, .bypassed:
      break
    }
    return nil
  }

  /// The account folder of a manager-kind session whose hook answer reaches claude, or nil for every other
  /// session. A host's hook answer never reaches claude. It scans the account again when its last scan is at
  /// least `skillRescanMs` old, and it never waits for the scan. Runs on the state queue.
  private func gatedSkillAccount(_ id: String, stamp: HostEventStamp?) -> String? {
    guard stamp == nil, let account = managerSkillAccount(id) else { return nil }
    if nowMs() - (skillRefreshed[account] ?? 0) >= Self.skillRescanMs { refreshManagerSkills(account: account) }
    return account
  }

  /// The gate's decision for a name in the account's index. Runs on the state queue.
  private func skillDecision(_ name: String, account: String, bypass: SkillBypass?) -> ManagerSkillGate.Decision {
    ManagerSkillGate.decide(
      name: name, catalog: skillIndex[account] ?? [:], labels: skillLabels, failures: skillFailures[account] ?? [:],
      settings: config.managerSkills, bypass: bypass)
  }

  /// The gate's decision without a bypass for a manager-kind session on this Mac, or nil for every other session.
  /// It decides on a copy of the account's index, labels, failures, and settings, so a caller can run it off the
  /// state queue. Unlike the hook, it never starts a scan. Runs on the state queue.
  func managerSkillDecider(_ id: String) -> SkillDecider? {
    guard let account = managerSkillAccount(id) else { return nil }
    let (catalog, labels, failures, settings) = (
      skillIndex[account] ?? [:], skillLabels, skillFailures[account] ?? [:], config.managerSkills
    )
    return { name in
      ManagerSkillGate.decide(
        name: name, catalog: catalog, labels: labels, failures: failures, settings: settings, bypass: nil)
    }
  }

  /// Records `skill_unchecked` for a skill of the account's index that the gate let through without a label, once
  /// per account, cache key, and reason in each run of sbd. A name that resolves to no entry of the index is not a
  /// skill that sbd knows, so it records nothing. Runs on the state queue.
  private func recordSkillUnchecked(_ id: String, _ name: String, account: String, _ failure: SkillFailure?) {
    let catalog = skillIndex[account] ?? [:]
    let settings = config.managerSkills
    guard let entry = catalog[ManagerSkillGate.resolve(name, catalog: catalog, settings: settings)] else { return }
    let why = failure?.category.rawValue ?? "unlabeled"
    let key = entry.key(model: settings.model) ?? "\(account)/\(name)"
    guard skillUnchecked.insert("\(why) \(account) \(key)").inserted else { return }
    var data: [String: JSON] = ["skill": .string(name), "why": .string(why)]
    if let failure { data["error"] = .string(failure.message) }
    record(id, "skill_unchecked", .object(data))
  }

  /// Whether an event ends the turn of a run-here message, whose Skill calls the bypass lets through until then.
  static func endsSkillBypass(_ event: Event) -> Bool {
    ["Stop", "StopFailure", "idle", "SessionEnd", "stopped", "exited"].contains(event.kind) && !event.fromSubagent
  }

  // MARK: Run here anyway

  /// Arms the bypass for the command that starts the text, when claude gets the text. A text without a command
  /// arms nothing. Runs on the state queue.
  func armSkillBypass(_ id: String, _ text: String) {
    guard let name = SkillCommand.name(inPrompt: text) else { return }
    entries[id]?.skillBypass = .armed(name)
  }

  /// Refuses a `send` with `runHere` from a Claude Code, so the model can't let itself run a work skill, and for a
  /// session that isn't a Manager conversation or the operator. Runs on the state queue.
  func refuseRunHere(_ id: String, _ args: JSON) throws {
    try Service.refuseClaude(args, "runs a work skill in a Manager conversation")
    guard let session = entries[id]?.session, session.kind.runsInManagerFolder else {
      throw APIError(
        "--run-here lets a work skill run in a Manager conversation or the operator, and \(id) is neither")
    }
  }
}
