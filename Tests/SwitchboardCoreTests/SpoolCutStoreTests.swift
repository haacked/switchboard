import Foundation
import Testing

@testable import SwitchboardCore

private let hour: UInt64 = 3_600 * 1_000_000_000
/// 2026-11-11 00:00:00 UTC in ns.
private let clock: UInt64 = 1_794_355_200_000_000_000

private func eventId(_ ns: UInt64) throws -> HostEventID {
  let digits = String(ns)
  return try #require(HostEventID("\(String(repeating: "0", count: 20 - digits.count))\(digits)-4242-a1b2"))
}

private func withStore(_ body: (Store) throws -> Void) throws {
  let dir = try tempFolder()
  defer { try? FileManager.default.removeItem(atPath: dir) }
  try body(try Store(path: "\(dir)/sb.db"))
}

private func stop(_ session: String) -> Event { Event(session: session, t: 1_000, kind: "Stop", data: [:]) }

/// What the store tells the spool cut: which ids sbd recorded for a host and a session, which sessions of a
/// host sbd removed, and which recorded ids the prune must keep.
@Suite struct SpoolCutStoreTests {
  @Test func anIdIsRecordedOnlyForTheHostAndTheSessionThatRecordedIt() throws {
    try withStore { store in
      let id = try eventId(clock)
      _ = try store.append(stop("s1"), hostEvent: id, host: "mini")

      #expect(try store.hasHostEvent(id, host: "mini", session: "s1"))
      #expect(try !store.hasHostEvent(id, host: "other", session: "s1"))
      #expect(try !store.hasHostEvent(id, host: "mini", session: "s2"))
      #expect(try !store.hasHostEvent(try eventId(clock + 1), host: "mini", session: "s1"))
    }
  }

  @Test func aRecordedIdStaysRecordedAfterItsSessionIsDeleted() throws {
    try withStore { store in
      let id = try eventId(clock)
      _ = try store.append(stop("s1"), hostEvent: id, host: "mini")

      try store.delete(session: "s1")

      #expect(try store.hasHostEvent(id, host: "mini", session: "s1"))
    }
  }

  @Test func aRemovedSessionIsListedOnlyForItsHost() throws {
    try withStore { store in
      try store.recordRemovedHostSession("gone", host: "mini")
      try store.recordRemovedHostSession("gone", host: "mini")
      try store.recordRemovedHostSession("left", host: "other")

      #expect(try store.removedHostSessions(host: "mini") == ["gone"])
      #expect(try store.removedHostSessions(host: "other") == ["left"])
      #expect(try store.removedHostSessions(host: "third").isEmpty)
    }
  }

  @Test func theRemovedSessionsSurviveAReopenOfTheStore() throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    try Store(path: "\(dir)/sb.db").recordRemovedHostSession("gone", host: "mini")

    #expect(try Store(path: "\(dir)/sb.db").removedHostSessions(host: "mini") == ["gone"])
  }

  /// A recorded line that stays in the spool is read again on each reconnect. Its id must stay recorded, however
  /// old it is, or the event is recorded twice.
  @Test func thePruneKeepsEveryIdAtOrAboveTheLowestOneStillInTheSpool() throws {
    try withStore { store in
      let old = try eventId(clock - 72 * hour)
      let inSpool = try eventId(clock - 60 * hour)
      let behind = try eventId(clock - 48 * hour)
      let new = try eventId(clock)
      for id in [old, inSpool, behind, new] { _ = try store.append(stop("s1"), hostEvent: id, host: "mini") }

      try store.pruneHostEvents(host: "mini", nowNs: clock, keeping: inSpool)

      #expect(try !store.hasHostEvent(old))
      #expect(try store.hasHostEvent(inSpool))
      #expect(try store.hasHostEvent(behind))
      #expect(try store.hasHostEvent(new))
    }
  }

  @Test func aFloorAboveTheCutoffDoesNotKeepIdsThatAreRecent() throws {
    try withStore { store in
      let old = try eventId(clock - 72 * hour)
      let recent = try eventId(clock - hour)
      let floor = try eventId(clock)
      for id in [old, recent, floor] { _ = try store.append(stop("s1"), hostEvent: id, host: "mini") }

      try store.pruneHostEvents(host: "mini", nowNs: clock, keeping: floor)

      #expect(try !store.hasHostEvent(old))
      #expect(try store.hasHostEvent(recent))
      #expect(try store.hasHostEvent(floor))
    }
  }
}
