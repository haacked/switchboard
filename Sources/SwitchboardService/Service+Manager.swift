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

  /// A new conversation loads only the switchboard MCP server. Without a
  /// name, it takes the first line of `prompt`, or `Manager.untitled` until
  /// its first prompt names it.
  private func createManager(name: String?, prompt: String?) throws -> SessionSummary {
    let folder = home.managerFolder
    let named = name ?? prompt.map(Manager.name(fromPrompt:)) ?? Manager.untitled
    return try create(NewSession(path: folder, name: named, prompt: prompt), (folder, nil, nil)) {
      $0.manager = true
      $0.mcp = []
      $0.mcpScoped = true
    }
  }

  /// Where a relaunch for changed MCP servers stands.
  enum MCPRelaunch {
    /// The change waits for claude to finish its turn.
    case pending
    /// sbd stopped claude and launches it again once it exits.
    case stopping
  }

  private var managerSessions: [Session] { entries.values.map(\.session).filter { $0.manager == true } }

  /// The `manager-ls` request: every conversation, newest activity first.
  func managerList() -> [SessionSummary] {
    managerSessions.map { summary($0.id) }.sorted(by: Manager.newestFirst)
  }

  func mostRecentManager() -> String? { managerList().first?.id }

  /// The conversation that `ref` names by id, unique id prefix, or unique name.
  func managerConversation(_ ref: String) throws -> String {
    try resolveRef(ref, "Manager conversation", managerSessions.map { ($0.id, $0.name) })
  }

  /// The conversation that `ref` names, or the most recent one without a ref.
  func managerConversation(_ ref: String?) throws -> String {
    if let ref, !ref.isEmpty { return try managerConversation(ref) }
    guard let id = mostRecentManager() else {
      throw APIError("there is no Manager conversation. Start one with: sb manager")
    }
    return id
  }

  /// Names an untitled conversation after the first line of its first prompt.
  func nameConversation(_ id: String, prompt: String?) throws {
    guard entries[id]?.session.manager == true, entries[id]?.session.name == Manager.untitled else { return }
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

  /// The servers that a conversation can add, by name: sbd's shared servers
  /// on their current ports, then the user-scope servers in the
  /// conversation account's Claude config. A shared server wins a name that
  /// both hold. The name `switchboard` is never available.
  func availableMCPServers(_ id: String) -> [String: JSON] {
    var out: [String: JSON] = [:]
    let file = ClaudeAccount.configFile(claudeAccount(of: id))
    if let data = FileManager.default.contents(atPath: file), let text = String(data: data, encoding: .utf8),
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

  /// The `manager-mcp` request: shows a conversation's MCP servers, or
  /// changes them with `add`, `rm`, `all`, or `none`. A change applies when
  /// claude can take it, as `applyMCPChanges` describes.
  func managerMCP(_ args: JSON) throws -> JSON {
    guard let ref = args["session"]?.string, !ref.isEmpty else { throw APIError("name a Manager conversation") }
    let id = try managerConversation(ref)
    let add = args["add"]?.array?.compactMap(\.string) ?? []
    let remove = args["rm"]?.array?.compactMap(\.string) ?? []
    let all = args["all"]?.bool == true
    let none = args["none"]?.bool == true
    let changes = [!add.isEmpty, !remove.isEmpty, all, none].filter { $0 }.count
    if changes > 1 { throw APIError("pass one of add, rm, --all, and --none") }
    let available = availableMCPServers(id)
    let unknown = add.filter { available[$0] == nil }
    if !unknown.isEmpty {
      let known = available.keys.sorted()
      throw APIError(
        "no MCP server named \(unknown.joined(separator: ", ")). "
          + (known.isEmpty ? "No config lists a server." : "The servers are: \(known.joined(separator: ", "))."))
    }
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
    return try JSON(
      encoding: ManagerMCPAnswer(
        session: id, name: session.name, servers: session.mcp, available: available.keys.sorted(),
        pending: entries[id]?.mcpRelaunch != nil))
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
          backgroundJobs(pid, in: processChildren(of: id)) == 0, e.facts.trustCard == nil
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
