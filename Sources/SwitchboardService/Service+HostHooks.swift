import Foundation
import SwitchboardCore

/// The id, the host, and the time of a hook event that a host's shim made.
struct HostEventStamp {
  var id: HostEventID
  var host: String
  /// The event's time on sbd's clock.
  var t: Int64
}

/// The hook events of one session on a host that wait for their turn in id order.
struct HostEventBuffer {
  var order = HostEventOrder()
  var payloads: [HostEventID: JSON] = [:]

  mutating func add(_ id: HostEventID, _ payload: JSON, at now: Int64) {
    order.add(id, at: now)
    if payloads[id] == nil { payloads[id] = payload }
  }
}

/// The hooks that arrive on a remote host's socket. Everything here runs for a request whose origin is that
/// host, so each step checks the session against the host again and takes nothing about it from the request.
extension Service {
  /// A clock that `sb clock` does not move, in ms. The order window is real time.
  private static func uptimeMs() -> Int64 { Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000) }

  /// The session that a request from `host` names. It throws unless sbd holds a session with exactly that
  /// id and the host on the session's record is `host`. A name, an id prefix, a local session, and a session
  /// of another host all throw. It runs on the state queue.
  func hostSession(_ args: JSON, on host: String) throws -> Session {
    guard let id = args["session"]?.string, let session = entries[id]?.session, session.id == id,
      let recorded = session.host, recorded == host
    else { throw APIError("that session is not on \(host)") }
    return session
  }

  /// Takes a hook from the socket of `host`. While the link is connected and the reconcile has not finished on
  /// that connection, the hook waits for the reconcile. An event whose id sbd holds or recorded is answered
  /// and skipped.
  /// A hook that waits for an answer is applied at once, after the session's waiting events with lower ids,
  /// and holds its request when it opened a card. Any other hook waits `HostEventOrder.windowMs` for events
  /// with lower ids and is answered at once.
  func handleHostHook(_ args: JSON, from host: String, hookGone: @escaping () -> Bool) throws -> Response {
    // The forward is up from the end of setup, before the reconcile has read the spool. A hook that arrives
    // then would be applied ahead of the earlier events that wait in the spool. So the reconcile runs first.
    // When it fails, the hook is refused, and its event stays in the spool for the next reconcile. A reconcile
    // that failed on this connection is not run again for each hook. The tick runs the next one.
    let (waits, failed) = try queue.sync { () -> (Bool, Bool) in
      _ = try hostSession(args, on: host)
      let status = remoteSites[host]?.link.status
      return (
        status?.state == .connected && reconciledOn[host] != status?.connection,
        reconcileFailedLately(host, now: nowMs())
      )
    }
    if waits {
      guard !failed, let reconciles = hostQueues[host] else {
        throw HostUnread(
          hostName: host, why: remoteSites[host]?.reconcileError ?? "sbd has not read it since it connected")
      }
      try reconciles.sync { try reconcile(host) }
    }
    let connection = remoteSites[host]?.facts?.epoch
    let (answer, opened): (JSON, (card: Int64, request: HeldRequest)?) = try queue.sync {
      let session = try hostSession(args, on: host)
      guard let payload = args["payload"], payload.object != nil else { throw APIError("a hook needs a payload") }
      guard HostHook.kind(payload) != nil else { throw Service.notAClaudeHook(host) }
      guard let id = args["id"]?.string.flatMap(HostEventID.init) else {
        throw APIError("a hook from \(host) needs an event id")
      }
      var buffer = hostEvents[session.id] ?? HostEventBuffer()
      if try store.hasHostEvent(id) || buffer.order.holds(id) { return ([:], nil) }
      if buffer.order.isLate(id) {
        logLine("host \(host): the hook event \(id) of \(session.id) is late. sbd applied a later one first")
      }
      buffer.add(id, payload, at: Service.uptimeMs())
      guard HostHook.waits(payload) else {
        hostEvents[session.id] = buffer
        queue.asyncAfter(deadline: .now() + .milliseconds(Int(HostEventOrder.windowMs) + 1)) { [self] in
          releaseHostEvents(session.id)
        }
        return ([:], nil)
      }
      let due = buffer.order.flush()
      let payloads = buffer.payloads
      buffer.payloads = [:]
      hostEvents[session.id] = buffer
      var asked: (event: Event, answer: JSON)?
      for each in due {
        guard let payload = payloads[each] else { continue }
        if each == id {
          asked = try applyHostEvent(session.id, each, payload)
        } else {
          applyWaitingHostEvent(session.id, each, payload)
        }
      }
      guard let asked else { return ([:], nil) }
      return (asked.answer, hold(asked.event, hookGone: hookGone))
    }
    return .success(
      awaitAnswer(opened, else: answer) { [self] in hookClosedByClaude(host, since: connection) })
  }

  /// Applies the session's waiting events that are due, lowest id first. It runs on the state queue.
  private func releaseHostEvents(_ session: String) {
    guard var buffer = hostEvents[session] else { return }
    let due = buffer.order.due(now: Service.uptimeMs())
    let payloads = due.map { ($0, buffer.payloads.removeValue(forKey: $0)) }
    hostEvents[session] = buffer
    for case (let id, let payload?) in payloads { applyWaitingHostEvent(session, id, payload) }
  }

  /// Applies an event that no hook waits on. A failure is logged. The event stays in the host's spool.
  private func applyWaitingHostEvent(_ session: String, _ id: HostEventID, _ payload: JSON) {
    do {
      _ = try applyHostEvent(session, id, payload)
    } catch {
      logLine("can't record the hook event \(id) of \(session): \(error)")
    }
  }

  private static func notAClaudeHook(_ host: String) -> APIError {
    APIError("a hook from \(host) needs the name of a claude hook in hook_event_name")
  }

  /// Records the event through `hook`, with its id and its time. The time is the id's clock on sbd's clock,
  /// no lower than the session's last event and no higher than now. The result is nil when the id is already
  /// recorded or sbd no longer holds the session on a host. It throws, and records nothing, when the payload's
  /// kind is not one of `SessionFacts.hookKinds`. It runs on the state queue.
  func applyHostEvent(_ session: String, _ id: HostEventID, _ payload: JSON) throws -> (
    event: Event, answer: JSON
  )? {
    guard let host = entries[session]?.session.host else { return nil }
    guard HostHook.kind(payload) != nil else { throw Service.notAClaudeHook(host) }
    let offset = remoteSites[host]?.clockOffsetMs ?? 0
    let last = try store.lastEventTime(session: session) ?? 0
    let t = min(max(id.ms &+ offset, last), nowMs())
    return try hook(
      ["session": .string(session), "payload": payload], stamp: HostEventStamp(id: id, host: host, t: t))
  }

  /// Whether a held request from `host` that closed with no reply was closed by Claude Code. It is true only
  /// when the host answers a command on the connection that the request arrived on. A request that closed
  /// because the link dropped gets false: its card stays, and its answer is typed into the pane later. It
  /// runs off the state queue.
  private func hookClosedByClaude(_ host: String, since connection: Int?) -> Bool {
    guard let site = remoteSites[host], let connection else { return false }
    let answered = try? site.confirmed("the check of a closed hook") { machine in
      let r = try machine.run("/bin/sh", ["-c", "exit 0"], env: nil, input: nil, timeout: RemoteSite.commandSeconds)
      return r.status == 0 && site.facts?.epoch == connection
    }
    return answered == true
  }

  /// Removes the recorded ids of each host's events that are too old to arrive again, at most once an hour. It
  /// keeps every id of a host whose spool no reconcile of this sbd has read, and every id at or above the
  /// host's spool floor: the lowest recorded id whose line the last read left in the spool or that sbd recorded
  /// after the read began.
  func pruneHostEvents(now: Int64) {
    guard hostEventsPruned == 0 || now - hostEventsPruned >= 3_600_000 else { return }
    hostEventsPruned = now
    let clock = UInt64(max(0, Date().timeIntervalSince1970) * 1_000_000_000)
    // A recorded id may be forgotten only when a read of the host's spool showed that its line is gone. sbd
    // knows what the spool holds only for a host whose spool a reconcile of this sbd read.
    for (host, floor) in spoolFloors {
      do { try store.pruneHostEvents(host: host, nowNs: clock, keeping: floor) } catch {
        logLine("host \(host): \(error)")
      }
    }
  }
}
