import Foundation
import SwitchboardCore

extension Service {
  var autoContinueSwitch: SwitchFile { SwitchFile(home.autoContinue, label: "auto-continue") }

  /// Sets the switch when the request names `enabled`, and returns the status.
  func autoContinueRequest(_ args: JSON) throws -> JSON {
    if let on = try autoContinueSwitch.apply(args) { autoContinueOn = on }
    let now = nowMs()
    let live = liveCount(onHost: nil)
    let sessions = autoContinueCandidates(now: now).map { id, verdict in
      AutoContinueCandidate(
        session: id, name: entries[id]!.session.name,
        blocker: autoContinueBlocker(id, verdict, live: live, now: now))
    }
    return try JSON(
      encoding: AutoContinueStatus(
        enabled: autoContinueOn, settings: config.autoContinue, liveCap: liveCap, live: live,
        sessions: sessions))
  }

  /// Continues each session that no guard holds back. The tick calls it
  /// after it tracks every session's state.
  func autoContinueSessions(now: Int64) {
    // A continue can start claude, which needs the shared MCP servers.
    guard autoContinueOn, !mcpStarting(now: now) else { return }
    var live = liveCount(onHost: nil)
    for (id, verdict) in autoContinueCandidates(now: now)
    where autoContinueBlocker(id, verdict, live: live, now: now) == nil {
      if autoContinue(id, offer: verdict.reason) == .resumed, entries[id]?.session.host == nil { live += 1 }
    }
  }

  private func autoContinue(_ id: String, offer: String) -> Delivery? {
    let message = config.autoContinue.message
    var data: [String: JSON] = ["text": .string(message), "offer": .string(offer)]
    var delivery: Delivery?
    do {
      let sent = try send(id, message, byUser: false, trigger: .autoContinue)
      data["delivery"] = .string(sent.rawValue)
      delivery = sent
    } catch {
      logLine("can't continue \(id): \(error)")
      data["error"] = .string("\(error)")
    }
    record(id, AutoContinue.eventKind, .object(data))
    return delivery
  }

  /// The sessions whose tracked state is Claude can continue, oldest first,
  /// each with its verdict.
  private func autoContinueCandidates(now: Int64) -> [(id: String, verdict: Verdict)] {
    entries.values.filter { $0.facts.lastState == .canContinue }
      .sorted { ($0.facts.stateSince, $0.session.id) < ($1.facts.stateSince, $1.session.id) }
      .map { ($0.session.id, Attention.evaluate($0.session, $0.facts, now: now)) }
  }

  /// `live` is this Mac's count of live sessions. A session on a host counts against its host's cap.
  func autoContinueBlocker(_ id: String, _ verdict: Verdict, live: Int, now: Int64) -> String? {
    let e = entries[id]!
    var input = AutoContinueInput(session: e.session, facts: e.facts, verdict: verdict, now: now)
    input.settings = config.autoContinue
    input.liveCap = liveCap(onHost: e.session.host)
    switch claudeState(id) {
    case .running: input.process = .running
    case .starting: input.process = .starting
    case .stopped: input.process = .stopped
    case .unknown: return "\(e.session.host ?? "its host") is not connected"
    }
    input.busy = e.messageWaiting(now: now)
    input.onScreen = attached(id)
    input.lastViewed = e.lastViewed
    input.live = e.session.host.map { liveCount(onHost: $0) } ?? live
    input.account = claudeAccount(of: id)
    if let host = e.session.host {
      // A session on a host uses the quota of the account that the host names.
      guard let account = config.hosts[host]?.account.flatMap({ try? resolveAccount($0) }) else {
        return "\(host) names no account in config.json, so its quota can't be checked"
      }
      input.account = account
    }
    input.hasBudget = quota.hasBudget(account: input.account)
    return AutoContinue.blocker(input)
  }
}
