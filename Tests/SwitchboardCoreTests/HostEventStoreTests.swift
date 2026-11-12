import Foundation
import Testing

@testable import SwitchboardCore

private let hour: UInt64 = 3_600 * 1_000_000_000
/// 2026-11-11 00:00:00 UTC in ns.
private let clock: UInt64 = 1_794_355_200_000_000_000

private func eventId(_ ns: UInt64, pid: Int = 4242, _ suffix: String = "a1b2") throws -> HostEventID {
  let digits = String(ns)
  return try #require(HostEventID("\(String(repeating: "0", count: 20 - digits.count))\(digits)-\(pid)-\(suffix)"))
}

private func withStore(_ body: (Store, String) throws -> Void) throws {
  let dir = try tempFolder()
  defer { try? FileManager.default.removeItem(atPath: dir) }
  try body(try Store(path: "\(dir)/sb.db"), "\(dir)/sb.db")
}

private func stop(_ session: String = "s1", n: Int = 0) -> Event {
  Event(session: session, t: 1_000, kind: "Stop", data: ["n": .number(Double(n))])
}

/// `Store.append(_:hostEvent:host:)` records a host's hook event and its id together, at most once.
@Suite struct HostEventStoreTests {
  @Test func anEventWithANewIdIsStoredWithItsId() throws {
    try withStore { store, _ in
      let id = try eventId(clock)

      let stored = try #require(try store.append(stop(), hostEvent: id, host: "mini"))

      #expect(stored.id > 0)
      #expect(try store.events(session: "s1") == [stored])
      #expect(try store.hasHostEvent(id))
    }
  }

  @Test func theSameIdASecondTimeStoresNothing() throws {
    try withStore { store, _ in
      let id = try eventId(clock)
      _ = try store.append(stop(n: 1), hostEvent: id, host: "mini")

      let again = try store.append(stop(n: 2), hostEvent: id, host: "mini")

      #expect(again == nil)
      #expect(try store.events(session: "s1").map(\.data) == [["n": 1]])
    }
  }

  /// An id is one event, whichever host or session a second copy names.
  @Test func theSameIdFromAnotherHostOrForAnotherSessionStoresNothing() throws {
    try withStore { store, _ in
      let id = try eventId(clock)
      _ = try store.append(stop("s1"), hostEvent: id, host: "mini")

      #expect(try store.append(stop("s2"), hostEvent: id, host: "mini") == nil)
      #expect(try store.append(stop("s1"), hostEvent: id, host: "other") == nil)

      #expect(try store.events().count == 1)
    }
  }

  @Test func anIdRecordedByOneConnectionIsADuplicateForTheNext() throws {
    try withStore { store, path in
      let id = try eventId(clock)
      _ = try store.append(stop(), hostEvent: id, host: "mini")

      let reopened = try Store(path: path)

      #expect(try reopened.hasHostEvent(id))
      #expect(try reopened.append(stop(), hostEvent: id, host: "mini") == nil)
    }
  }

  @Test func idsThatDifferOnlyInTheirLastPartAreTwoEvents() throws {
    try withStore { store, _ in
      _ = try store.append(stop(n: 1), hostEvent: try eventId(clock, pid: 7, "00aa"), host: "mini")
      _ = try store.append(stop(n: 2), hostEvent: try eventId(clock, pid: 7, "00ab"), host: "mini")

      #expect(try store.events(session: "s1").count == 2)
    }
  }

  /// The id and the event share a transaction: an event that the store can't keep leaves no id behind.
  @Test func anEventThatFailsToStoreLeavesItsIdUnrecorded() throws {
    try withStore { store, path in
      let id = try eventId(clock)
      // The events insert aborts after the id's insert has already run.
      try ResolvedTodoStoreTests.block("INSERT", on: "events", in: path)

      #expect(throws: (any Error).self) { _ = try store.append(stop(), hostEvent: id, host: "mini") }

      #expect(try !store.hasHostEvent(id))
      #expect(try store.events().isEmpty)
      let dropped = try runCommand("/usr/bin/sqlite3", [path, "DROP TRIGGER block"])
      try #require(dropped.status == 0, Comment(rawValue: dropped.stderr))
      #expect(try store.append(stop(), hostEvent: id, host: "mini") != nil)
    }
  }

  @Test func theTimeOfTheLastEventIsTheNewestRowsTime() throws {
    try withStore { store, _ in
      #expect(try store.lastEventTime(session: "s1") == nil)
      try store.append(Event(session: "s1", t: 500, kind: "a"))
      try store.append(Event(session: "s2", t: 900, kind: "b"))
      try store.append(Event(session: "s1", t: 300, kind: "c"))

      #expect(try store.lastEventTime(session: "s1") == 300)
    }
  }

  // MARK: Pruning

  @Test func pruningRemovesIdsMoreThan24HoursBehindTheHostsNewest() throws {
    try withStore { store, _ in
      let old = try eventId(clock - 25 * hour)
      let kept = try eventId(clock - 23 * hour)
      let newest = try eventId(clock)
      for id in [old, kept, newest] { _ = try store.append(stop(), hostEvent: id, host: "mini") }

      try store.pruneHostEvents(host: "mini", nowNs: clock + 2 * hour)

      #expect(try !store.hasHostEvent(old))
      #expect(try store.hasHostEvent(kept))
      #expect(try store.hasHostEvent(newest))
      #expect(try store.events().count == 3, "pruning removed an event")
    }
  }

  @Test func pruningOneHostKeepsTheIdsOfAnother() throws {
    try withStore { store, _ in
      let othersOld = try eventId(clock - 48 * hour, pid: 9)
      _ = try store.append(stop(), hostEvent: othersOld, host: "other")
      _ = try store.append(stop(), hostEvent: try eventId(clock), host: "mini")

      try store.pruneHostEvents(host: "mini", nowNs: clock)

      #expect(try store.hasHostEvent(othersOld))
    }
  }

  /// One id with a clock far ahead must not make every real id look old.
  @Test func anIdWithAClockFarAheadRemovesNothingWithin24HoursOfNow() throws {
    try withStore { store, _ in
      let recent = try eventId(clock - hour)
      let old = try eventId(clock - 25 * hour)
      _ = try store.append(stop(), hostEvent: recent, host: "mini")
      _ = try store.append(stop(), hostEvent: old, host: "mini")
      _ = try store.append(stop(), hostEvent: try eventId(UInt64.max, pid: 1, "ffff"), host: "mini")

      try store.pruneHostEvents(host: "mini", nowNs: clock)

      #expect(try store.hasHostEvent(recent))
      #expect(try !store.hasHostEvent(old))
    }
  }

  @Test func pruningAHostWithNoIdsOrAClockNearZeroRemovesNothing() throws {
    try withStore { store, _ in
      try store.pruneHostEvents(host: "mini", nowNs: clock)
      let early = try eventId(5)
      _ = try store.append(stop(), hostEvent: early, host: "mini")

      try store.pruneHostEvents(host: "mini", nowNs: clock)

      #expect(try store.hasHostEvent(early))
    }
  }
}
