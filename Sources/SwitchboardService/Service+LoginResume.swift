import Foundation
import SwitchboardCore

extension Service {
  /// Continues each turn that a failed login stopped, once `LoginResume.blocker` finds that the login works. The
  /// tick calls it after it tracks every session's state.
  func resumeFailedLogins(now: Int64) {
    let failed = entries.values.filter { $0.facts.turnFailure?.isLogin == true }.map(\.session.id).sorted()
    // A continue can start claude, which needs the shared MCP servers.
    guard !failed.isEmpty, !mcpStarting(now: now) else { return }
    var live = liveCount(onHost: nil)
    for id in failed {
      let account = claudeAccount(of: id).key
      guard loginResumeBlocker(id, account: account, live: live, now: now) == nil else { continue }
      let sent = sendOnOwn(id, LoginResume.message, event: LoginResume.eventKind, data: ["account": .string(account)])
      if sent == .resumed, entries[id]?.session.host == nil { live += 1 }
    }
  }

  /// The accounts that the usage reader polls: the listed ones, then each other local account whose login stopped a
  /// session's turn. `loginWorks` sees such an account recover only through these reads.
  func usageAccounts() -> [Account] {
    var all = listedAccounts()
    for id in entries.keys.sorted() {
      guard let failure = entries[id]?.facts.turnFailure, failure.isLogin, failure.resumable,
        let folder = failure.account, let account = claudeAccount(folder: folder).map(Account.claude),
        !all.contains(account)
      else { continue }
      all.append(account)
    }
    return all
  }

  /// `account` is the key of the account that the session's claude runs under now. `live` is this Mac's count of
  /// live sessions. A session on a host counts against its host's cap.
  func loginResumeBlocker(_ id: String, account: String, live: Int, now: Int64) -> String? {
    let e = entries[id]!
    var input = LoginResumeInput(session: e.session, facts: e.facts, now: now)
    guard let process = promptProcess(id) else { return "\(e.session.host ?? "its host") is not connected" }
    input.process = process
    input.busy = messageWaiting(e, now: now)
    input.live = e.session.host.map { liveCount(onHost: $0) } ?? live
    input.liveCap = liveCap(onHost: e.session.host)
    input.account = account
    if let failure = e.facts.turnFailure, let failed = failure.account {
      input.loginWorks = quota.loginWorks(account: failed, since: failure.at)
    }
    return LoginResume.blocker(input)
  }
}
