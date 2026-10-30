import Foundation
import SwitchboardCore

/// Keeps each session's snapshot close to the end of its event log, so that
/// the next start applies few events. A snapshot is a replay of the log, so
/// the keeper builds it the way `load` does and never copies live state.
final class SnapshotKeeper {
  let every: Int
  let build: String
  private let path: String
  private let work = DispatchQueue(label: "sbd.snapshot")
  /// Opened on `work`, because a connection belongs to one thread at a time.
  private var store: Store?
  private let lock = NSLock()
  /// The last event and session of each session's newest snapshot or failed attempt.
  private var saved: [String: (events: Int, session: Session)] = [:]
  private var running: Set<String> = []
  /// How the last start built each session, for `sb snapshots`. Only the state queue touches it.
  var loaded: [String: (replay: SessionReplay, outcome: SnapshotOutcome)] = [:]

  init(path: String, every: Int) {
    self.path = path
    self.every = every
    self.build = SnapshotKeeper.buildIdentity()
  }

  /// The size and modification time of the running executable. Any rebuild
  /// changes them, so a snapshot never outlives the code that made it.
  static func buildIdentity() -> String {
    let path = Bundle.main.executablePath ?? CommandLine.arguments[0]
    let attributes = try? FileManager.default.attributesOfItem(atPath: path)
    let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
    return "\(Version.text) \(size) \(Int64(modified * 1000))"
  }

  func note(_ id: String, events: Int, session: Session) {
    lock.withLock { saved[id] = (events, session) }
  }

  /// Whether the session has `every` events since its snapshot, or changed.
  /// A session that started after sbd did has no snapshot yet.
  func due(_ id: String, events: Int, session: Session) -> Bool {
    guard every > 0 else { return false }
    return lock.withLock {
      guard !running.contains(id) else { return false }
      guard let last = saved[id] else { return events >= every }
      return last.session != session || events - last.events >= every
    }
  }

  func compact(_ id: String, session: Session, events: Int) {
    lock.withLock { running.insert(id) }
    work.async { [self] in
      var done = (events, session)
      do {
        let store = try store ?? Store(path: path)
        self.store = store
        let snapshot = try Snapshots.refresh(store, session, build: build).snapshot
        done = (snapshot.replay.events, session)
      } catch {
        logLine("can't save the snapshot of \(id): \(error)")
      }
      lock.withLock {
        saved[id] = done
        running.remove(id)
      }
    }
  }
}

extension Service {
  /// Rebuilds a session's state at start from its snapshot and the events
  /// after it, or from every event when snapshots are off.
  func replayed(_ session: Session) throws -> SessionReplay {
    var replay: SessionReplay
    var outcome: SnapshotOutcome
    if keeper.every > 0 {
      let result = try Snapshots.refresh(store, session, build: keeper.build)
      (replay, outcome) = (result.snapshot.replay, result.outcome)
      keeper.note(session.id, events: replay.events, session: session)
    } else {
      let events = try store.events(session: session.id)
      replay = .replaying(events, session: session)
      outcome = .replay("snapshots are off", events: events.count)
    }
    replay.restarted()
    keeper.loaded[session.id] = (replay, outcome)
    return replay
  }

  /// Saves a snapshot of each session that gained `snapshotEvery` events, or
  /// whose row changed. It runs on the state queue, and the work runs off it.
  func compactSnapshots() {
    for (id, e) in entries where keeper.due(id, events: e.events, session: e.session) {
      keeper.compact(id, session: e.session, events: e.events)
    }
  }

  /// `snapshots` lists how the last start built each session. With `write`, it
  /// first brings every session's snapshot up to date.
  func snapshotRequest(_ args: JSON) throws -> JSON {
    if args["write"]?.bool == true {
      guard keeper.every > 0 else { throw APIError("snapshotEvery is 0 in config.json, so snapshots are off") }
      for (id, e) in entries {
        let snapshot = try Snapshots.refresh(store, e.session, build: keeper.build).snapshot
        keeper.note(id, events: snapshot.replay.events, session: e.session)
      }
    }
    return .array(
      try keeper.loaded.sorted { $0.key < $1.key }.map { id, loaded in
        [
          "session": .string(id), "loaded": .string(loaded.outcome.text),
          "replay": try JSON(encoding: loaded.replay),
        ]
      })
  }
}
