import Foundation
import SwitchboardCore

/// Claude Code sends no hook when Escape interrupts a turn, so sbd would keep
/// the turn running. Once a turn has had no event for 10 s, the tick asks
/// `claude agents --json` about it. A row that says `idle` ends the turn. A
/// long tool call reads `busy` and keeps its turn. Each session backs off
/// between checks (see `TurnProbe`). One `claude agents` run per account
/// answers every session that is due in that account. For the sessions on a
/// host, one run on the host answers every session that is due there.
extension Service {
  /// The tick waits for `claude agents`, so a claude that hangs gets SIGTERM
  /// after this many seconds.
  static let turnCheckTimeout = 15.0

  struct TurnCheck {
    var id: String
    var claudeSessionId: String
    var activity: Int64
  }

  /// The checks that one `claude agents` run answers: those of one account at one site.
  private struct TurnChecks {
    var site: any SessionSite
    var account: String
    var checks: [TurnCheck]
  }

  /// Ends the turns of the sessions that `claude agents` reports idle. It
  /// runs claude off the state queue.
  func endIdleTurns() {
    let all = queue.sync { dueTurnChecks(now: nowMs()) }
    guard !all.isEmpty else { return }
    let claude = findExecutable(config.claude)
    // Without this Mac's claude, only the sessions on a host can be checked.
    let due = all.filter { claude != nil || $0.site is RemoteSite }
    guard !due.isEmpty else { return }
    let answers = concurrentMap(due) { group in
      (
        group.account, group.checks,
        Result { () throws -> [ClaudeSession] in
          if let host = group.site as? RemoteSite {
            return try agentRows(at: host, seen: nowMs(), timeout: Service.turnCheckTimeout)
          }
          guard let claude else { throw APIError("can't find \(config.claude)") }
          return try agentRows(
            claude, account: group.account, seen: nowMs(), timeout: Service.turnCheckTimeout, on: group.site.machine)
        }
      )
    }
    queue.sync {
      for (account, checks, list) in answers {
        switch list {
        case .failure(let error):
          logLine("can't check the turns in \(account): \(error)")
        case .success(let rows):
          let idle = Service.idleTurns(rows)
          for check in checks where idle.contains(check.claudeSessionId) {
            endTurn(check, account: account)
          }
        }
      }
    }
  }

  /// The sessions whose turn has gone quiet, by site and account.
  private func dueTurnChecks(now: Int64) -> [TurnChecks] {
    var due: [TurnChecks] = []
    for id in entries.keys.sorted() {
      guard let e = entries[id], e.facts.live, e.facts.turnRunning, case .running = claudeState(id) else { continue }
      let activity = e.facts.lastActivity
      guard entries[id]?.turnProbe.check(activity: activity, now: now) == true else { continue }
      let site = self.site(for: e.session)
      let account = claudeAccount(of: id)
      let check = TurnCheck(id: id, claudeSessionId: e.session.claudeSessionId, activity: activity)
      if let i = due.firstIndex(where: { $0.site === site && $0.account == account }) {
        due[i].checks.append(check)
      } else {
        due.append(TurnChecks(site: site, account: account, checks: [check]))
      }
    }
    return due
  }

  /// The account of a session on the host. It names the host and is no folder.
  static func hostAccount(_ host: String) -> String { "\(host):~/.claude" }

  /// The Claude account that the session's claude runs under. SessionStart
  /// names the transcript, <account>/projects/<folder>/<id>.jsonl, in the
  /// account that claude uses, which a shell profile or a wrapper can pick.
  /// Before a SessionStart, the account is the one that the pane sets.
  /// A session on a host runs under that host's login, which is no account of this Mac. Its answer names the
  /// host and is no folder.
  func claudeAccount(of id: String) -> String {
    if let host = entries[id]?.session.host { return Service.hostAccount(host) }
    if let e = entries[id], let path = e.facts.transcriptPath,
      (path as NSString).lastPathComponent == "\(e.session.claudeSessionId).jsonl"
    {
      let projects = ((path as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent as NSString
      if projects.lastPathComponent == "projects" { return ClaudeAccount.normalize(projects.deletingLastPathComponent) }
    }
    return ClaudeAccount.normalize(paneEnv(id)["CLAUDE_CONFIG_DIR"] ?? ClaudeAccount.defaultFolder)
  }

  /// The conversations that `claude agents` lists with a running claude that sits idle.
  static func idleTurns(_ rows: [ClaudeSession]) -> Set<String> {
    Set(rows.filter { $0.running && $0.status == "idle" }.map(\.id))
  }

  /// Ends the turn unless an event arrived while claude ran.
  func endTurn(_ check: TurnCheck, account: String) {
    guard let e = entries[check.id], e.facts.turnRunning, e.facts.lastActivity == check.activity,
      e.session.claudeSessionId == check.claudeSessionId
    else { return }
    record(check.id, "idle", ["account": .string(account)])
    deliverPending(check.id, after: 0.5)
  }
}
