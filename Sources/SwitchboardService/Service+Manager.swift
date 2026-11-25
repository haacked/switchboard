import Foundation
import SwitchboardCore

/// Manager conversations. `plans/manager-redesign.md` in the notes repo describes them.
extension Service {
  /// The `manager` request. With `new`, it starts a conversation, with
  /// `text` as its first prompt. With `session`, it sends `text` to that
  /// conversation, or without text opens it. With neither, it does the same
  /// for the most recent conversation, and starts one named "Manager" when
  /// none exists. The answer is the conversation's summary, with `delivery`
  /// when it took text.
  func managerRequest(_ args: JSON) -> Response {
    do {
      try ensureManagerFolder()
      let text = args["text"]?.string.flatMap { $0.isEmpty ? nil : $0 }
      let isNew = args["new"]?.bool == true
      if !isNew {
        let found = try queue.sync { () -> String? in
          if let ref = args["session"]?.string, !ref.isEmpty { return try managerConversation(ref) }
          return mostRecentManager()
        }
        if let id = found { return try openOrSend(id, text) }
      }
      awaitMCPServers()
      // Another request can start a conversation while this one waits off the
      // queue, so the lookup runs again on it.
      let (id, created) = try queue.sync { () -> (String, SessionSummary?) in
        if !isNew, let id = mostRecentManager() { return (id, nil) }
        let name = args["name"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        let created = try createManager(name: name ?? (isNew ? nil : Manager.name), prompt: text)
        return (created.id, created)
      }
      guard let created else { return try openOrSend(id, text) }
      return try createdAnswer(created, text: text, queued: queue.sync { entries[id]?.queuedSince != nil })
    } catch {
      return .failure("\(error)")
    }
  }

  /// A new conversation, or the operator with `isOperator`, loads only the
  /// switchboard MCP server, unless `mcp` names more, or is nil for the full setup. Without a name, it takes the
  /// first line of `prompt`, or `Manager.untitled` until its first prompt names it. `account` is a Claude config
  /// folder, kept as it is, so it need not be one that `sb account` knows. Without it, the conversation runs under
  /// the active account.
  func createManager(
    name: String?, prompt: String?, isOperator: Bool = false, account: String? = nil, mcp: [String]? = []
  ) throws -> SessionSummary {
    let folder = home.managerFolder
    let named = name ?? prompt.map(Manager.name(fromPrompt:)) ?? Manager.untitled
    let created = try create(NewSession(path: folder, name: named, prompt: prompt), (folder, nil, nil)) {
      $0.manager = true
      $0.claudeConfigDir = account
      if isOperator { $0.isOperator = true }
      $0.mcp = mcp
      $0.mcpScoped = true
    }
    // A new conversation is the most recent one, so it takes the Operator's items that no other session owns.
    syncOperatorItems()
    return summary(created.id)
  }

  /// The `manager-model` request. With `model`, it saves the model in config.json's `manager` and uses it from
  /// the next launch of each conversation. The answer is the model.
  func managerModelRequest(_ args: JSON) throws -> JSON {
    if let value = args["model"] {
      guard let model = value.string else { throw APIError("the model is a name, such as sonnet") }
      if let problem = Manager.modelProblem(model) { throw APIError(problem) }
      try saveSetting(section: "manager", "model", .string(model))
      managerModel = model
      logLine("the Manager's model is \(model)")
    }
    return .object(["model": .string(managerModel)])
  }

  /// The `operator-model` request. With `model`, it saves the model in config.json's `operator`. The operator uses
  /// it from its next launch, and every judge call from the next call. The answer is the model.
  func operatorModelRequest(_ args: JSON) throws -> JSON {
    if let value = args["model"] {
      guard let model = value.string else { throw APIError("the model is a name, such as haiku") }
      if let problem = Manager.modelProblem(model) { throw APIError(problem) }
      try saveSetting(section: "operator", "model", .string(model))
      logLine("the operator's model is \(model)")
    }
    return .object(["model": .string(operatorSettings.model)])
  }

  /// The `operator` request: sends `text` to the operator, or without text
  /// opens it. It creates the operator when none exists. The answer is the
  /// operator's summary, with `delivery` when it took text. `from` and
  /// `insideClaude` mark text that a Claude Code sent. That text doesn't
  /// close the operator's reports.
  func operatorRequest(_ args: JSON) -> Response {
    do {
      let text = args["text"]?.string.flatMap { $0.isEmpty ? nil : $0 }
      let (id, created) = try queue.sync { () -> (String, SessionSummary?) in
        if let id = operatorID() { return (id, nil) }
        let id = try ensureOperator()
        return (id, summary(id))
      }
      // An open right after the creation could read the starting claude as stopped and launch it again.
      if let created, text == nil { return .success(try JSON(encoding: created)) }
      return try openOrSend(id, text, sender: args)
    } catch {
      return .failure("\(error)")
    }
  }

  /// The operator's id. It creates the operator when none exists, with no
  /// prompt, so claude starts and the idle stop stops it later. The caller
  /// holds the state queue, so the lookup and the creation are one step.
  /// The operator loads only the switchboard MCP server, so its launch
  /// waits for no shared server.
  func ensureOperator() throws -> String {
    if let id = operatorID() { return id }
    try ensureManagerFolder()
    return try createManager(name: Manager.operatorName, prompt: nil, isOperator: true).id
  }

  /// The operator's id, or nil when none exists. When the store holds more
  /// than one, it is the oldest. sbd logs the others, unless `quiet`, and leaves them as they are.
  func operatorID(quiet: Bool = false) -> String? {
    let operators = entries.values.map(\.session).filter { $0.kind == .operator }
      .sorted { ($0.created, $0.id) < ($1.created, $1.id) }
    guard let oldest = operators.first else { return nil }
    if operators.count > 1, !quiet {
      let others = operators.dropFirst().map(\.id).joined(separator: ", ")
      logLine("found more than one operator. Using \(oldest.id), the oldest, and leaving \(others)")
    }
    return oldest.id
  }

  /// Refuses `name` for a session that is not the operator. The operator's prompt finds it with
  /// `sb get Operator`. A second session with that name makes the lookup fail.
  func refuseOperatorName(_ name: String?) throws {
    guard name == Manager.operatorName else { return }
    throw APIError(
      "the name \(Manager.operatorName) belongs to the background operator, "
        + "and a second session with it breaks `sb get \(Manager.operatorName)`. Pick another name.")
  }

  /// Refuses a rename that breaks `sb get Operator`: a new name for the operator, or the operator's name for
  /// another session. An operator that an older sbd renamed may take its name back, unless another session
  /// holds the name.
  func refuseRename(_ id: String, to name: String) throws {
    guard entries[id]?.session.kind == .operator else { return try refuseOperatorName(name) }
    if name == Manager.operatorName {
      guard let other = entries.values.first(where: { $0.session.id != id && $0.session.name == name }) else { return }
      throw APIError(
        "\(mention(other.session.id)) already has the name \(name), and a second session with it breaks "
          + "`sb get \(name)`. Rename that session first.")
    }
    throw APIError(
      "the operator keeps the name \(Manager.operatorName), because its prompt finds it with "
        + "`sb get \(Manager.operatorName)`. Rename another session instead.")
  }

  /// Refuses to remove the operator while it has an open wait or an open `needsYou` report, because the
  /// removal would drop it without a message.
  func refuseOperatorRemoval(_ id: String) throws {
    guard let e = entries[id], e.session.kind == .operator else { return }
    let name = Manager.operatorName
    let count = e.session.waits?.count ?? 0
    if count > 0 {
      let (waits, them) = count == 1 ? ("wait", "it") : ("waits", "them")
      throw APIError(
        "the operator has \(count) open \(waits), and removing it would drop \(them). "
          + "Clear \(them) first with: sb wait \(name) --clear. Then run: sb rm \(name)")
    }
    let reports = e.facts.openReports.count
    if reports > 0 {
      let (open, them) = reports == 1 ? ("an open report", "it") : ("\(reports) open reports", "them")
      throw APIError(
        "the operator has \(open) that needs you, and removing it would drop \(them). "
          + "Answer or acknowledge \(them) in the Inbox. Then run: sb rm \(name)")
    }
  }

  /// The `operator-report` request, which records a report on the operator. Only the operator may make it,
  /// so `caller` must be the operator's id. `session` names the session that the report is about.
  func operatorReport(_ args: JSON) throws -> JSON {
    guard let caller = args["caller"]?.string, let id = operatorID(), caller == id else {
      throw APIError("only the operator records reports. Send the operator a message with: sb operator <text>")
    }
    let text = oneLine(args["text"]?.string ?? "", max: TriageCard.lineLength)
    guard !text.isEmpty else { throw APIError("a report needs text") }
    let about = try args["session"]?.string.map { try lookup(["session": .string($0)]) }
    let event = try recordReport(
      text, needsYou: args["needsYou"]?.bool == true, about: about, on: id, handedFrom: entries[id]!.facts.workFrom)
    return try reportRow(OperatorReport(event)!, of: id)
  }

  /// Records a report on the operator `op`, cut to one line. `about` is the session that the report is about, and
  /// `wait` is the wait whose action made the report. A needs-you report goes to the session that `askOwner` picks,
  /// where `handedFrom` is the conversation that handed off the wait that the operator works on.
  @discardableResult
  func recordReport(
    _ text: String, needsYou: Bool, about: String? = nil, on op: String, wait: String? = nil, handedFrom: String? = nil
  ) throws -> Event {
    var data: [String: JSON] = [
      "text": .string(oneLine(text, max: TriageCard.lineLength)), "needsYou": .bool(needsYou),
    ]
    if let about { data["about"] = .string(about) }
    if let wait { data["wait"] = .string(wait) }
    let event = try recordStored(op, OperatorReport.event, .object(data))
    if needsYou, let owner = askOwner(about: about, handedFrom: handedFrom) { routeReport(event, owner: owner) }
    // `fold` skips the sync for a report, so that the ask never shows on a fallback owner before its routing.
    syncOperatorItems()
    return event
  }

  /// The `operator-reports` request: the operator's reports, oldest first, each with whether it is open. It
  /// lists the newest `Event.defaultLimit`, or every one with `all`. Without an operator, the list is empty.
  func operatorReports(_ args: JSON) throws -> JSON {
    guard let id = operatorID() else { return [] }
    let limit = args["all"]?.bool == true ? Int.max : Event.defaultLimit
    let events = try store.events(session: id, kinds: [OperatorReport.event], limit: limit, newest: true)
    return .array(try events.compactMap(OperatorReport.init).map { try reportRow($0, of: id) })
  }

  /// The report as `sb operator reports` lists it, with `open` and the name of the session that it is about.
  private func reportRow(_ report: OperatorReport, of id: String) throws -> JSON {
    var row = try JSON(encoding: report).object ?? [:]
    row["open"] = .bool(entries[id]!.facts.openReports.contains { $0.id == report.id })
    if let name = report.about.flatMap({ entries[$0]?.session.name }) { row["aboutName"] = .string(name) }
    return .object(row)
  }

  /// Where a relaunch for changed MCP servers stands.
  enum MCPRelaunch {
    /// The change waits for claude to finish its turn.
    case pending
    /// sbd stopped claude and launches it again once it exits.
    case stopping
  }

  private var managerSessions: [Session] { entries.values.map(\.session).filter { $0.kind == .manager } }

  /// The `manager-ls` request: every conversation, newest activity first.
  func managerList() -> [SessionSummary] {
    let watched = watchedSlackKeys(now: nowMs())
    return managerSessions.map { summary($0.id, watchedSlack: watched) }.sorted(by: Manager.newestFirst)
  }

  func mostRecentManager() -> String? { managerList().first?.id }

  /// The newest conversation that may own the Operator's items, read from the entries without building summaries.
  /// It orders by the fields that `Manager.newestFirst` compares. It skips a paused or done conversation, which
  /// `mostRecentManager` would give, so that an item goes to the next conversation and not to the Operator.
  func newestConversation() -> String? {
    entries.values.filter { $0.session.kind == .manager && mayOwnOperatorItems($0.session.id) }.min {
      ($0.facts.lastActivity, $0.session.created) > ($1.facts.lastActivity, $1.session.created)
    }?.session.id
  }

  /// The conversation that `ref` names by id, unique id prefix, or unique name.
  func managerConversation(_ ref: String) throws -> String {
    try conversation(ref, kinds: [.manager], noun: "Manager conversation")
  }

  /// The Manager conversation or group chat that `ref` names by id, unique id prefix, or unique name. An error names
  /// the session as a Manager conversation, as it did before a group chat could be named.
  func userConversation(_ ref: String) throws -> String {
    try conversation(ref, kinds: [.manager, .chat], noun: "Manager conversation")
  }

  /// The session of one of `kinds` that `ref` names by id, unique id prefix, or unique name. An error names the
  /// session as `noun`.
  func conversation(_ ref: String, kinds: Set<SessionKind>, noun: String) throws -> String {
    try resolveRef(ref, noun, entries.values.map(\.session).filter { kinds.contains($0.kind) }.map { ($0.id, $0.name) })
  }

  /// The conversation that `ref` names, or the most recent one without a ref.
  func managerConversation(_ ref: String?) throws -> String {
    if let ref, !ref.isEmpty { return try managerConversation(ref) }
    guard let id = mostRecentManager() else {
      throw APIError("there is no Manager conversation. Start one with: sb manager")
    }
    return id
  }

  /// Names an untitled Manager conversation or group chat after the first line of its first prompt.
  func nameConversation(_ id: String, prompt: String?) throws {
    guard entries[id]?.session.kind.isUserConversation == true, entries[id]?.session.name == Manager.untitled else {
      return
    }
    let name = Manager.name(fromPrompt: prompt ?? "")
    guard name != Manager.untitled else { return }
    try update(id) { $0.name = name }
    record(id, "renamed", ["name": .string(name)])
  }

  // MARK: MCP servers

  /// The MCP arguments of a launch. A session with an `mcp` list launches
  /// with `--strict-mcp-config`, the switchboard server, and one more
  /// config with the listed servers. A listed server that no config holds
  /// any more is left out, and the launch records an `mcp-missing` event.
  func launchMCPArgs(_ id: String, _ session: Session) -> [String] {
    let switchboard =
      session.kind == .work
      ? []
      : [
        "--mcp-config", MCPToolServer.launchConfig(sb: sbPath, home: home.path, session: id, group: session.chat).text,
      ]
    guard let names = session.mcp else { return mcpArgs + switchboard }
    var args = ["--strict-mcp-config"] + switchboard
    guard !names.isEmpty else { return args }
    let available = availableMCPServers(id)
    let missing = names.filter { available[$0] == nil }
    if !missing.isEmpty { record(id, "mcp-missing", ["servers": .array(missing.map(JSON.string))]) }
    let servers = names.compactMap { name in available[name].map { (name, $0) } }
    if !servers.isEmpty {
      args += ["--mcp-config", JSON.object(["mcpServers": .object(Dictionary(servers) { first, _ in first })]).text]
    }
    return args
  }

  /// The servers that a conversation can add, by name, on the account it runs under.
  func availableMCPServers(_ id: String) -> [String: JSON] {
    if case .local(let account) = claudeAccount(of: id) { return availableMCPServers(account: account) }
    return availableMCPServers(account: nil)
  }

  /// The servers that a conversation on `account` can add, by name: sbd's
  /// shared servers on their current ports, then the user-scope servers in
  /// the account's Claude config. A shared server wins a name that both hold.
  /// The name `switchboard` is never available. A nil account offers only
  /// the shared servers.
  func availableMCPServers(account: ClaudeAccount?) -> [String: JSON] {
    var out: [String: JSON] = [:]
    if let account,
      let data = FileManager.default.contents(atPath: account.configFile),
      let text = String(data: data, encoding: .utf8),
      let user = JSON.parse(text)?["mcpServers"]?.object
    {
      out = user
    }
    let shared = MCPServer.claudeConfig(
      Dictionary(uniqueKeysWithValues: mcp.map { ($0.name, $0.config) }),
      ports: Dictionary(uniqueKeysWithValues: mcp.map { ($0.name, $0.port) }))
    out.merge(shared["mcpServers"]?.object ?? [:]) { _, shared in shared }
    // Every conversation already loads its own switchboard server under that name.
    out["switchboard"] = nil
    return out
  }

  /// The `manager-mcp` request: shows the MCP servers of a conversation or the operator, or
  /// changes them with `add`, `rm`, `all`, or `none`.
  func managerMCP(_ args: JSON) throws -> JSON {
    guard let ref = args["session"]?.string, !ref.isEmpty else { throw APIError("name a Manager conversation") }
    let id = try resolveRef(
      ref, "Manager conversation",
      entries.values.map(\.session).filter(\.kind.runsInManagerFolder).map { ($0.id, $0.name) })
    return try JSON(
      encoding: changeMCPServers(
        id, add: args["add"]?.array?.compactMap(\.string) ?? [], remove: args["rm"]?.array?.compactMap(\.string) ?? [],
        all: args["all"]?.bool == true, none: args["none"]?.bool == true))
  }

  /// Changes a session's MCP servers by at most one of `add`, `remove`, `all`, and `none`, and answers with the
  /// list after the change. A change applies when claude can take it, as `applyMCPChanges` describes.
  func changeMCPServers(_ id: String, add: [String], remove: [String], all: Bool, none: Bool) throws
    -> ManagerMCPAnswer
  {
    let changes = [!add.isEmpty, !remove.isEmpty, all, none].filter { $0 }.count
    if changes > 1 { throw APIError("pass one of add, rm, --all, and --none") }
    let available = availableMCPServers(id)
    let unknown = add.filter { available[$0] == nil }
    if !unknown.isEmpty { throw unknownMCPServers(unknown, available: available) }
    let current = entries[id]!.session.mcp
    if current == nil, !add.isEmpty || !remove.isEmpty {
      throw APIError("\(entries[id]!.session.name) loads every server. Run --none first, then add the ones it needs")
    }
    let next: [String]? =
      all
      ? nil
      : none ? [] : current.map { add.reduce($0) { $0.contains($1) ? $0 : $0 + [$1] }.filter { !remove.contains($0) } }
    if next != current {
      try update(id) { $0.mcp = next }
      record(id, "mcp", ["servers": next.map { .array($0.map(JSON.string)) } ?? .null])
      // A relaunch already under way reads the stored list when it launches.
      if claudeState(id) != .stopped, entries[id]?.mcpRelaunch == nil { entries[id]?.mcpRelaunch = .pending }
      applyMCPChanges(now: nowMs())
    }
    let session = entries[id]!.session
    return ManagerMCPAnswer(
      session: id, name: session.name, servers: session.mcp, available: available.keys.sorted(),
      pending: entries[id]?.mcpRelaunch != nil)
  }

  /// The refusal of server names that no config holds, which names the servers that exist.
  func unknownMCPServers(_ unknown: [String], available: [String: JSON]) -> APIError {
    let known = available.keys.sorted()
    return APIError(
      "no MCP server named \(unknown.joined(separator: ", ")). "
        + (known.isEmpty ? "No config lists a server." : "The servers are: \(known.joined(separator: ", "))."))
  }

  /// Relaunches each claude whose MCP servers changed while it ran, once it
  /// can take a notice and is quiet: no message waits, no turn runs, no
  /// background job runs, and no trust dialog is open. It stops claude,
  /// and launches it again with `--resume` once it has exited. A claude that
  /// exits for another reason first, such as `sb stop`, stays stopped, and
  /// its next launch uses the new servers.
  func applyMCPChanges(now: Int64) {
    for (id, e) in entries {
      guard let phase = e.mcpRelaunch else { continue }
      switch (claudeState(id), phase) {
      case (.running(let pid), .pending):
        // A stop would lose a background job's result or an open trust dialog.
        guard canTakeNotice(e, now: now), !e.facts.exiting,
          backgroundJobs(pid, in: processes(of: id)) == 0, e.facts.trustCard == nil
        else { continue }
        entries[id]?.mcpRelaunch = .stopping
        try? stop(id, reason: "its MCP servers changed")
      case (.stopped, .stopping):
        entries[id]?.mcpRelaunch = nil
        do { try launch(id, prompt: nil, trigger: .mcp) } catch {
          logLine("can't relaunch \(id) for its MCP servers: \(error)")
        }
      case (.stopped, .pending):
        entries[id]?.mcpRelaunch = nil
      default:
        continue
      }
    }
  }

  // MARK: Guide

  /// Makes the Manager's folder a git repo with the current CLAUDE.md.
  func ensureManagerFolder() throws {
    try FileManager.default.createDirectory(atPath: home.managerFolder, withIntermediateDirectories: true)
    try refreshManagerGuide()
  }

  /// Rewrites CLAUDE.md when it differs. It does nothing until `sb manager`
  /// has made the folder, so a user who never runs `sb manager` gets none.
  func refreshManagerGuide() throws {
    let folder = home.managerFolder
    guard isDirectory(folder) else { return }
    try writeGuide(Manager.guide, in: folder)
  }

  /// Makes the folder a git repo. It writes the guide to CLAUDE.md when the file differs.
  func writeGuide(_ guide: String, in folder: String) throws {
    if !isDirectory("\(folder)/.git") { _ = try gitOutput(folder, ["init", "-q"], at: mac) }
    let path = "\(folder)/CLAUDE.md"
    if (try? String(contentsOfFile: path, encoding: .utf8)) != guide {
      try guide.write(toFile: path, atomically: true, encoding: .utf8)
    }
  }
}
