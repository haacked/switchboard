import Foundation
import SwitchboardCore

/// Claude Code sends no hook when Escape interrupts a turn, so sbd would keep
/// the turn running. Once a turn has had no event for 10 s, the tick asks
/// `claude agents --json` about it. A row that says `idle` ends the turn. A
/// long tool call reads `busy` and keeps its turn. Each session backs off
/// between checks (see `TurnProbe`). One `claude agents` run per account
/// answers every session that is due in that account.
extension Service {
  /// The tick waits for `claude agents`, so a claude that hangs gets SIGTERM
  /// after this many seconds.
  static let turnCheckTimeout = 15.0

  private struct TurnCheck {
    var id: String
    var claudeSessionId: String
    var activity: Int64
  }

  /// Ends the turns of the sessions that `claude agents` reports idle. It
  /// runs claude off the state queue.
  func endIdleTurns() {
    let due = queue.sync { dueTurnChecks(now: nowMs()) }
    guard !due.isEmpty else { return }
    guard let claude = findExecutable(config.claude) else { return }
    let answers = concurrentMap(Array(due)) { account, checks in
      (
        account, checks,
        Result { try agentRows(claude, account: account, seen: nowMs(), timeout: Service.turnCheckTimeout) }
      )
    }
    queue.sync {
      for (account, checks, list) in answers {
        switch list {
        case .failure(let error):
          logLine("can't check the turns in \(account): \(error)")
        case .success(let rows):
          let idle = Set(rows.filter { $0.running && $0.status == "idle" }.map(\.id))
          for check in checks where idle.contains(check.claudeSessionId) {
            endTurn(check, account: account)
          }
        }
      }
    }
  }

  /// The sessions whose turn has gone quiet, by account.
  private func dueTurnChecks(now: Int64) -> [String: [TurnCheck]] {
    var due: [String: [TurnCheck]] = [:]
    for id in entries.keys.sorted() {
      guard let e = entries[id], e.facts.live, e.facts.turnRunning, case .running = claudeState(id) else { continue }
      let activity = e.facts.lastActivity
      guard entries[id]?.turnProbe.check(activity: activity, now: now) == true else { continue }
      due[claudeAccount(of: id), default: []].append(
        TurnCheck(id: id, claudeSessionId: e.session.claudeSessionId, activity: activity))
    }
    return due
  }

  /// The Claude account that the session's claude runs under. SessionStart
  /// names the transcript, <account>/projects/<folder>/<id>.jsonl, in the
  /// account that claude uses, which a shell profile or a wrapper can pick.
  /// Before a SessionStart, the account is the one that the pane sets.
  func claudeAccount(of id: String) -> String {
    if let e = entries[id], let path = e.facts.transcriptPath,
      (path as NSString).lastPathComponent == "\(e.session.claudeSessionId).jsonl"
    {
      let projects = ((path as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent as NSString
      if projects.lastPathComponent == "projects" { return ClaudeAccount.normalize(projects.deletingLastPathComponent) }
    }
    return ClaudeAccount.normalize(paneEnv(id)["CLAUDE_CONFIG_DIR"] ?? ClaudeAccount.defaultFolder)
  }

  /// Ends the turn unless an event arrived while claude ran.
  private func endTurn(_ check: TurnCheck, account: String) {
    guard let e = entries[check.id], e.facts.turnRunning, e.facts.lastActivity == check.activity,
      e.session.claudeSessionId == check.claudeSessionId
    else { return }
    record(check.id, "idle", ["account": .string(account)])
    deliverPending(check.id, after: 0.5)
  }
}
