import Foundation
import SwitchboardCore

/// The model call that names a session which started without a name.
extension Service {
  static let sessionNameEvent = "session-name"

  /// Queues the call that names the session from its first prompt, when
  /// there is a prompt and `sessionNames` is on. The session keeps its
  /// fallback name until the answer comes, and the call never delays the
  /// start. With `worktree`, sbd made the branch, so the call doesn't read
  /// it. Runs on the state queue.
  func queueSessionName(_ id: String, prompt: String?, worktree: Bool) {
    let settings = config.sessionNames
    guard let prompt, settings.enabled, let session = entries[id]?.session, session.kind == .work else { return }
    let account = triageAccount(for: id)
    guard quota.hasBudget(account: account.key) else {
      record(id, Self.sessionNameEvent, ["skipped": .string("no quota left for \(account.key)")])
      return
    }
    entries[id]?.pendingName = session.name
    let env = headlessEnv(session: id, account: account.account)
    let (site, cwd, issue) = (site(for: session), session.cwd, session.issue)
    let branch = worktree ? nil : session.branch
    nameJobs.addOperation { [self] in
      let repository = githubRepository(cwd, at: site)
      let issue = issue.map { "\($0.repo ?? repository ?? "")#\($0.number)" }
      let input = SessionNamer.input(prompt: prompt, repository: repository, branch: branch, issue: issue)
      let call = headlessCall(
        .sessionName, session: id, arguments: SessionNamer.arguments(model: settings.model), input: input, env: env,
        folder: home.path, timeout: settings.timeoutSeconds, parse: SessionNamer.parse)
      waitAtGate("hold-session-name")
      queue.async { [self] in finishSessionName(id, call) }
    }
  }

  /// Gives the session the model's name, made unique, when nothing renamed
  /// the session since the call was queued. It records one `session-name`
  /// event for a session that still exists. Runs on the state queue.
  func finishSessionName(_ id: String, _ call: HeadlessOutcome<String>) {
    guard let entry = entries[id] else {
      logLine("dropping the name for \(id): the session was removed")
      return
    }
    let fallback = entry.pendingName
    entries[id]?.pendingName = nil
    var data = call.reply?.eventFields ?? [:]
    defer { record(id, Self.sessionNameEvent, .object(data)) }
    guard let fallback, entry.session.name == fallback else {
      data["skipped"] = "renamed"
      return
    }
    let name: String
    switch call.result {
    case .success(let answer): name = answer
    case .failure(let error):
      logLine("can't name \(id): \(error)")
      data["error"] = .string("\(error)")
      return
    }
    let others = entries.values.filter { $0.session.id != id }.map { ($0.session.id, $0.session.name) }
    let free = SessionNamer.unique(name) { (try? resolveRef($0, "session", others + [(id, $0)])) == id }
    guard let free else {
      data["skipped"] = "no free name"
      return
    }
    do {
      try renameSession(id, to: free)
      data["name"] = .string(free)
      data["from"] = .string(entry.session.name)
    } catch {
      data["error"] = .string("\(error)")
    }
  }
}
