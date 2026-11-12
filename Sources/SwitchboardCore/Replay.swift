import Foundation

/// What one session's event log builds: its facts and the messages that wait
/// for a turn to end. `Snapshots` saves it so that sbd replays only the
/// events after it.
public struct SessionReplay: Codable, Equatable, Sendable {
  public var facts = SessionFacts()
  /// Messages that sbd accepted and has not started to paste. sbd pastes
  /// them after a restart.
  public var pending: [String] = []
  /// Messages whose paste started without a `delivered` or a `requeued`
  /// after it. The paste may or may not have reached claude, so sbd never
  /// pastes them again on its own.
  public var uncertain: [String] = []
  /// The id of the last event applied, or 0 before any.
  public var lastEvent: Int64 = 0
  /// How many events were applied.
  public var events = 0

  public init() {}

  /// The replay of `events`, which are one session's whole log.
  public static func replaying(_ events: [Event], session: Session) -> SessionReplay {
    var replay = SessionReplay()
    for event in events { replay.apply(event, session: session) }
    return replay
  }

  /// Folds one event in, and evaluates the session under `session` at the
  /// event's time.
  public mutating func apply(_ event: Event, session: Session) {
    facts.apply(event)
    Attention.track(session, &facts, now: event.t)
    let text = event.data["text"]?.string ?? ""
    switch event.kind {
    case "sent" where Delivery.awaitsDelivered(event):
      pending.append(text)
    case "pasting":
      if let i = pending.firstIndex(of: text) { uncertain.append(pending.remove(at: i)) }
    case "delivered":
      if let i = uncertain.firstIndex(of: text) {
        uncertain.remove(at: i)
      } else if let i = pending.firstIndex(of: text) {
        pending.remove(at: i)
      }
    case "delivery_unknown":
      if let i = uncertain.firstIndex(of: text) { uncertain.remove(at: i) }
    case "requeued":
      // A failed paste goes back to the front of the queue, where `Service.requeue` puts it.
      // A log from before `pasting` existed records `requeued` after a
      // direct paste whose `sent` added nothing to `pending`.
      if let i = uncertain.firstIndex(of: text) {
        pending.insert(uncertain.remove(at: i), at: 0)
      } else if !pending.contains(text) {
        pending.append(text)
      }
    default:
      break
    }
    events += 1
    if event.id > 0 { lastEvent = event.id }
  }

  /// A restart ended every held request, as `card_closed` does for one.
  /// Claude Code keeps each dialog open. A card that outlives its turn has
  /// no held request. A snapshot holds the state before this step.
  public mutating func restarted() {
    for i in facts.cards.indices.reversed() where !facts.cards[i].outlivesTurn {
      facts.closeHook(at: i)
    }
  }
}

/// A session's replay at one event, with what must still hold for sbd to use it.
public struct SessionSnapshot: Codable, Equatable, Sendable {
  /// The sbd build that made it. Another build may apply events differently.
  var build: String
  /// The session that `Attention.track` evaluated. A full replay evaluates
  /// every event under the current session, so a snapshot made under another
  /// one holds different state timestamps.
  var session: Session
  public var replay: SessionReplay
}

public enum SnapshotOutcome: Equatable, Sendable {
  /// The snapshot was valid, and `tail` events came after it.
  case snapshot(tail: Int)
  /// Every event was applied, because of `reason`.
  case replay(String, events: Int)

  public var text: String {
    switch self {
    case .snapshot(let tail): return "snapshot + \(tail) events"
    case .replay(let reason, let events): return "replay of \(events) events (\(reason))"
    }
  }
}

public enum Snapshots {
  /// Brings the session's saved snapshot up to the end of its log, and saves
  /// the result when it changed. It applies only the events after a valid
  /// snapshot, and every event when there is none or it may be stale.
  @discardableResult
  public static func refresh(_ store: Store, _ session: Session, build: String) throws
    -> (snapshot: SessionSnapshot, outcome: SnapshotOutcome)
  {
    var snapshot = SessionSnapshot(build: build, session: session, replay: SessionReplay())
    let outcome: SnapshotOutcome
    switch try usable(store, session, build: build) {
    case .success(let saved):
      snapshot = saved
      let tail = try store.events(since: saved.replay.lastEvent, session: session.id)
      for event in tail { snapshot.replay.apply(event, session: session) }
      outcome = .snapshot(tail: tail.count)
    case .failure(let why):
      let events = try store.events(session: session.id)
      snapshot.replay = .replaying(events, session: session)
      outcome = .replay(why.reason, events: events.count)
    }
    if case .snapshot(0) = outcome { return (snapshot, outcome) }
    try store.save(snapshot: JSONCoding.encode(snapshot), session: session.id)
    return (snapshot, outcome)
  }

  struct Unusable: Error {
    let reason: String
  }

  /// The saved snapshot, when it shows that it equals a full replay up to its
  /// last event.
  static func usable(_ store: Store, _ session: Session, build: String) throws -> Result<SessionSnapshot, Unusable> {
    guard let text = try store.snapshot(session: session.id) else { return .failure(Unusable(reason: "no snapshot")) }
    guard let saved = try? JSONCoding.decode(SessionSnapshot.self, from: text) else {
      return .failure(Unusable(reason: "snapshot does not decode"))
    }
    guard saved.build == build else {
      return .failure(Unusable(reason: "snapshot is from another build"))
    }
    guard saved.session == session else { return .failure(Unusable(reason: "session changed since the snapshot")) }
    guard try saved.replay.lastEvent == 0 || store.hasEvent(saved.replay.lastEvent, session: session.id) else {
      return .failure(Unusable(reason: "snapshot names an event the log lacks"))
    }
    return .success(saved)
  }
}
