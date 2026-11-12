import Foundation
import SQLite3
import Testing

@testable import SwitchboardCore
@testable import SwitchboardService

private func eventId(_ n: Int) -> String { String(format: "%020lld-4242-%04x", 1_700_000_000_000_000_000 + n, n) }

private func line(_ n: Int, session: String = "s1") -> Data {
  let payload: JSON = ["hook_event_name": "Notification", "message": .string("event \(n)")]
  let fields: JSON = ["v": 1, "id": .string(eventId(n)), "session": .string(session), "payload": payload]
  return Data((fields.text + "\n").utf8)
}

private func remoteSession(_ id: String, host: String = "mini") -> Session {
  var s = Session(id: id, name: id, cwd: "/srv/repo", claudeSessionId: "u-\(id)", created: 5)
  s.host = host
  s.started = true
  return s
}

private func record(_ service: Service, _ n: Int, session: String = "s1", host: String = "mini") throws {
  let id = try #require(HostEventID(eventId(n)))
  _ = try service.store.append(
    Event(session: session, t: 1_000, kind: "Notification", data: [:]), hostEvent: id, host: host)
}

/// The count of bytes that sbd asks a host to cut from its spool. sbd removes a line only when its store holds
/// the line's id for that host and that session, or lists the line's session as one that it removed from that
/// host. Each test names what stays in the file.
@Suite struct SpoolCutServiceTests {
  private func cut(_ service: Service, _ spool: Data, from host: String = "mini") -> Int {
    service.queue.sync { service.spoolCut(spool, from: host) }
  }

  @Test(.timeLimit(.minutes(1)))
  func linesThatThisHostRecordedForTheirSessionAreCut() throws {
    try withHostService { service, _ in
      try record(service, 1)
      try record(service, 2)

      #expect(cut(service, line(1) + line(2) + line(3)) == (line(1) + line(2)).count)
    }
  }

  /// Ids are recorded once for every host. A line on one host that carries an id which another host's event
  /// recorded was never recorded for this host.
  @Test(.timeLimit(.minutes(1)))
  func aLineWhoseIdAnotherHostRecordedStopsTheCut() throws {
    try withHostService { service, _ in
      try record(service, 1)
      try record(service, 2, host: "other")

      #expect(cut(service, line(1) + line(2) + line(3)) == line(1).count)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func aLineWhoseIdAnotherSessionRecordedStopsTheCut() throws {
    try withHostService { service, _ in
      try record(service, 1)
      try record(service, 2, session: "s2")

      #expect(cut(service, line(1) + line(2, session: "s1") + line(3)) == line(1).count)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func aLineOfASessionThatSbdRemovedFromThisHostIsCut() throws {
    try withHostService { service, _ in
      try record(service, 1)
      try service.store.recordRemovedHostSession("gone", host: "mini")

      let spool = line(1) + line(2, session: "gone") + line(3, session: "gone")

      #expect(cut(service, spool) == spool.count)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func aLineOfASessionThatSbdRemovedFromAnotherHostStopsTheCut() throws {
    try withHostService { service, _ in
      try record(service, 1)
      try service.store.recordRemovedHostSession("gone", host: "other")

      #expect(cut(service, line(1) + line(2, session: "gone")) == line(1).count)
    }
  }

  /// The store lists the id as removed, and sbd holds a session of that id. The line's event may still be one
  /// that sbd must record, so only its recorded id lets it go.
  @Test(.timeLimit(.minutes(1)))
  func aLineOfARemovedSessionWhoseIdSbdHoldsAgainStopsTheCut() throws {
    try withHostService { service, _ in
      try service.store.recordRemovedHostSession("back", host: "mini")
      service.queue.sync { service.entries["back"] = Service.Entry(session: remoteSession("back")) }

      #expect(cut(service, line(1, session: "back") + line(2, session: "back")) == 0)
    }
  }

  /// A line that stays in a host's spool is read again on each reconnect, and only its recorded id stops sbd
  /// from recording its event twice. sbd knows what a spool holds only after a reconcile read it.
  @Test(.timeLimit(.minutes(1)))
  func thePruneKeepsTheIdsOfAHostWhoseSpoolNoReconcileHasRead() throws {
    try withHostService { service, _ in
      let old = try #require(HostEventID("00000000000000000001-4242-a1b2"))
      _ = try service.store.append(Event(session: "s1", t: 1, kind: "Stop", data: [:]), hostEvent: old, host: "mini")
      try record(service, 1)

      service.queue.sync { service.pruneHostEvents(now: 1) }
      let keptBeforeARead = try service.store.hasHostEvent(old)
      service.queue.sync {
        service.spoolFloors["mini"] = .some(nil)
        service.hostEventsPruned = 0
        service.pruneHostEvents(now: 1)
      }

      #expect(keptBeforeARead)
      #expect(try !service.store.hasHostEvent(old))
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func aStoreWithNothingRecordedCutsNothing() throws {
    try withHostService { service, _ in
      #expect(cut(service, line(1) + line(2)) == 0)
    }
  }

  /// A store that can't answer whether a line was recorded, or which sessions sbd removed, counts as no. The
  /// test renames the table through a second connection, so the store's query fails.
  @Test(.timeLimit(.minutes(1)), arguments: ["host_events", "removed_host_sessions"])
  func aStoreThatCantAnswerCutsNothing(table: String) throws {
    try withHostService { service, home in
      try record(service, 1)
      try record(service, 2)
      try service.store.recordRemovedHostSession("gone", host: "mini")
      let spool = table == "host_events" ? line(1) + line(2) : line(1, session: "gone") + line(2, session: "gone")
      let answered = cut(service, spool)

      try renameTable(table, to: "\(table)_gone", in: home)

      #expect(answered == spool.count)
      #expect(cut(service, spool) == 0)
    }
  }
}

/// Renames a table of the store through a second connection, so the store's queries of that table fail.
private func renameTable(_ table: String, to name: String, in home: Home) throws {
  var db: OpaquePointer?
  defer { sqlite3_close(db) }
  let opened = sqlite3_open(home.database, &db)
  try #require(opened == SQLITE_OK, "can't open \(home.database)")
  let renamed = sqlite3_exec(db, "ALTER TABLE \(table) RENAME TO \(name)", nil, nil, nil)
  try #require(renamed == SQLITE_OK, "\(String(cString: sqlite3_errmsg(db)))")
}

/// sbd forgets a recorded id only when a read of the host's spool showed that the id's line is gone. The shim
/// spools every hook, also one that it delivers live, so a line stays in the spool until the next reconcile
/// cuts it. Each test records an id two days old and an id from now, so the prune's time rule alone would
/// forget the old one.
@Suite struct SpoolCutFloorTests {
  private let now = UInt64(Date().timeIntervalSince1970 * 1_000_000_000)
  private var old: UInt64 { now - 2 * 86_400_000_000_000 }

  private func id(_ ns: UInt64) -> String { String(format: "%020llu-4242-abcd", ns) }

  private func line(_ ns: UInt64, session: String = "s1") -> Data {
    let payload: JSON = ["hook_event_name": "Notification", "message": .string("event \(ns)")]
    let fields: JSON = ["v": 1, "id": .string(id(ns)), "session": .string(session), "payload": payload]
    return Data((fields.text + "\n").utf8)
  }

  /// Records the event the way a hook from the host's socket or a spool line does.
  private func hook(_ service: Service, _ ns: UInt64) throws {
    let id = try #require(HostEventID(id(ns)))
    let payload: JSON = ["hook_event_name": "Notification", "message": .string("event \(ns)")]
    let recorded = try service.queue.sync {
      try service.hook(["session": "s1", "payload": payload], stamp: HostEventStamp(id: id, host: "mini", t: 1_000))
    }
    try #require(recorded != nil)
  }

  private func prune(_ service: Service) {
    service.queue.sync {
      service.hostEventsPruned = 0
      service.pruneHostEvents(now: 1)
    }
  }

  private func isRecorded(_ service: Service, _ ns: UInt64) throws -> Bool {
    try service.store.hasHostEvent(try #require(HostEventID(id(ns))))
  }

  private func withSession(_ body: (Service) throws -> Void) throws {
    try withHostService { service, _ in
      service.queue.sync { service.entries["s1"] = Service.Entry(session: remoteSession("s1")) }
      try body(service)
    }
  }

  /// The last reconcile cut every line. The link then stays up for more than a day, and the hooks that arrive
  /// on the socket stay in the spool.
  @Test(.timeLimit(.minutes(1)))
  func anIdRecordedAfterAReconcileCutEveryLineIsKept() throws {
    try withSession { service in
      service.queue.sync { service.setSpoolFloor("mini", keeping: []) }
      try hook(service, old)
      try hook(service, now)

      prune(service)

      #expect(try isRecorded(service, old))
    }
  }

  /// Two shims made their ids in one order and appended their lines in the other, or the host's clock stepped
  /// back. The read holds a line with a later id, and the line of the lower id came after the read.
  @Test(.timeLimit(.minutes(1)))
  func anIdRecordedDuringTheReadWhoseLineTheReadDoesNotHoldIsKept() throws {
    try withSession { service in
      try hook(service, now)
      service.queue.sync { service.spoolReadFloors["mini"] = .some(nil) }
      try hook(service, old)
      let read = Spool.parse(line(now)).lines

      service.queue.sync {
        service.setSpoolFloor("mini", keeping: read)
        service.spoolReadFloors["mini"] = nil
      }
      prune(service)

      #expect(try isRecorded(service, old))
    }
  }

  /// The shim refused the cut, or the link dropped before the cut answered. Every line that the read held is
  /// still in the spool.
  @Test(.timeLimit(.minutes(1)))
  func theIdOfALineThatACutDidNotRemoveIsKept() throws {
    try withSession { service in
      service.queue.sync { service.spoolReadFloors["mini"] = .some(nil) }
      try hook(service, old)
      try hook(service, now)
      let read = Spool.parse(line(old) + line(now)).lines

      service.queue.sync {
        service.setSpoolFloor("mini", keeping: read)
        service.spoolReadFloors["mini"] = nil
      }
      prune(service)

      #expect(try isRecorded(service, old))
    }
  }

  /// The store can't answer whether the read's lines were recorded. Each of those lines may hold an id that sbd
  /// recorded, so the floor stays at or below its id. The test renames the table away for the floor and back
  /// for the prune.
  @Test(.timeLimit(.minutes(1)))
  func anIdWhoseLineTheStoreCouldNotCheckIsKept() throws {
    try withHostService { service, home in
      service.queue.sync { service.entries["s1"] = Service.Entry(session: remoteSession("s1")) }
      try hook(service, old)
      try hook(service, now)
      service.queue.sync { service.spoolReadFloors["mini"] = .some(nil) }
      let read = Spool.parse(line(old) + line(now)).lines

      try renameTable("host_events", to: "host_events_gone", in: home)
      service.queue.sync {
        service.setSpoolFloor("mini", keeping: read)
        service.spoolReadFloors["mini"] = nil
      }
      try renameTable("host_events_gone", to: "host_events", in: home)
      prune(service)

      #expect(try isRecorded(service, old))
      #expect(service.queue.sync { service.spoolFloors["mini"] ?? nil }?.text == id(old))
    }
  }

  /// The spool can hold a line whose id the store holds for another session of the host. The dedup skips that
  /// line by its id alone, so the floor must keep the id too.
  @Test(.timeLimit(.minutes(1)))
  func anIdThatTheStoreHoldsForAnotherSessionIsKept() throws {
    try withSession { service in
      try hook(service, old)
      try hook(service, now)
      service.queue.sync { service.spoolReadFloors["mini"] = .some(nil) }

      service.queue.sync {
        service.setSpoolFloor("mini", keeping: Spool.parse(line(old, session: "s2") + line(now)).lines)
        service.spoolReadFloors["mini"] = nil
      }
      prune(service)

      #expect(try isRecorded(service, old))
      #expect(service.queue.sync { service.spoolFloors["mini"] ?? nil }?.text == id(old))
    }
  }

  /// A read that showed the line gone lets the prune forget its id.
  @Test(.timeLimit(.minutes(1)))
  func anIdRecordedBeforeTheReadWhoseLineTheReadDoesNotHoldIsForgotten() throws {
    try withSession { service in
      try hook(service, old)
      try hook(service, now)
      service.queue.sync { service.spoolReadFloors["mini"] = .some(nil) }

      service.queue.sync {
        service.setSpoolFloor("mini", keeping: Spool.parse(line(now)).lines)
        service.spoolReadFloors["mini"] = nil
      }
      prune(service)

      #expect(try !isRecorded(service, old))
      #expect(try isRecorded(service, now))
    }
  }
}

/// The read of a host's spool: one command with a timeout of 60 s, which gives the file's exact bytes and
/// refuses a spool above 64 MB.
@Suite struct SpoolCutReadTests {
  private func withBox(_ body: (BoxFacts, String) throws -> Void) throws {
    let home = try makeShortTempFolder()
    defer { try? FileManager.default.removeItem(atPath: home) }
    try FileManager.default.createDirectory(atPath: "\(home)/.sb", withIntermediateDirectories: true)
    let facts = BoxFacts(
      epoch: 1, home: home, shell: "/bin/sh", user: "", lang: "", tmux: "/usr/bin/true", git: "/usr/bin/true",
      python: "/usr/bin/true", clockOffsetMs: 0)
    try body(facts, "\(home)/.sb/spool.jsonl")
  }

  @Test(.timeLimit(.minutes(1)))
  func aMissingSpoolReadsAsEmpty() throws {
    try withBox { facts, _ in
      let read = try Service.readSpool(LocalMachine(), facts: facts, host: "mini")

      #expect(read == Data())
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func anEmptySpoolReadsAsEmpty() throws {
    try withBox { facts, path in
      try Data().write(to: URL(fileURLWithPath: path))

      let read = try Service.readSpool(LocalMachine(), facts: facts, host: "mini")

      #expect(read == Data())
    }
  }

  /// The hash that sbd sends with the cut is of the bytes that it read, so the read must not change a byte.
  @Test(.timeLimit(.minutes(1)))
  func theReadGivesTheExactBytesOfTheFile() throws {
    try withBox { facts, path in
      let bytes = line(1) + Data([0xff, 0xfe, 0x00, 0x0a]) + Data("\r\n".utf8) + line(2).dropLast(3)
      try bytes.write(to: URL(fileURLWithPath: path))

      let read = try Service.readSpool(LocalMachine(), facts: facts, host: "mini")

      let same = read == bytes
      #expect(same, "the read holds \(read.count) bytes, and the file \(bytes.count)")
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func theReadIsOneCommandWithATimeoutOfSixtySeconds() throws {
    try withBox { facts, path in
      try line(1).write(to: URL(fileURLWithPath: path))
      let machine = CallRecorder(LocalMachine())

      _ = try Service.readSpool(machine, facts: facts, host: "mini")

      #expect(machine.runs.count == 1)
      #expect(machine.runs.first?.timeout == 60)
      #expect(machine.runs.first?.args.contains(path) == true)
      #expect(machine.calls.isEmpty)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func aSpoolThatIsAFolderFailsTheRead() throws {
    try withBox { facts, path in
      try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)

      #expect(throws: APIError.self) { try Service.readSpool(LocalMachine(), facts: facts, host: "mini") }
    }
  }

  @Test(.timeLimit(.minutes(2)))
  func aSpoolOfExactlyTheLimitIsRead() throws {
    try withBox { facts, path in
      FileManager.default.createFile(atPath: path, contents: nil)
      let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
      try handle.truncate(atOffset: UInt64(Service.spoolLimitBytes))
      try handle.close()

      let read = try Service.readSpool(LocalMachine(), facts: facts, host: "mini")

      #expect(read.count == Service.spoolLimitBytes)
    }
  }

  @Test(.timeLimit(.minutes(2)))
  func aSpoolAboveTheLimitFailsTheReadWithAMessageAndIsNotLoaded() throws {
    try withBox { facts, path in
      FileManager.default.createFile(atPath: path, contents: nil)
      let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
      try handle.truncate(atOffset: UInt64(Service.spoolLimitBytes) + 1)
      try handle.close()

      do {
        _ = try Service.readSpool(LocalMachine(), facts: facts, host: "mini")
        Issue.record("the read of a spool above the limit did not fail")
      } catch {
        #expect("\(error)".contains("holds more than 64 MB"), "\(error)")
        #expect("\(error)".contains("mini"), "\(error)")
      }
    }
  }
}
