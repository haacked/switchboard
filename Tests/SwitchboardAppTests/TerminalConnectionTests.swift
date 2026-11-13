import Foundation
import SwitchboardCore
import Testing

@testable import SwitchboardApp

private let sample = Terminals(
  tmux: "/usr/bin/tmux", socket: "/tmp/sb.sock", claude: "sb-a-claude", shell: "sb-a-shell")

/// The sleeps and requests of one connection, in the order they happened.
private final class ConnectionLog: @unchecked Sendable {
  enum Entry: Equatable {
    case sleep(Duration)
    case request(String)
  }

  private let lock = NSLock()
  private var items: [Entry] = []

  var entries: [Entry] { lock.withLock { items } }
  func append(_ entry: Entry) { lock.withLock { items.append(entry) } }

  var requests: [String] {
    entries.compactMap {
      if case .request(let id) = $0 { id } else { nil }
    }
  }
}

/// A connection whose requests answer from `answer`. A sleep returns at once unless `block` returns true.
@MainActor
private func makeConnection(
  _ log: ConnectionLog, block: @escaping @Sendable () -> Bool = { false },
  answer: @escaping @Sendable (Int) throws -> Terminals = { _ in sample }
) -> TerminalConnection {
  let count = Counter()
  return TerminalConnection(
    request: { id in
      log.append(.request(id))
      return try answer(count.increment())
    },
    sleep: { duration in
      log.append(.sleep(duration))
      if block() { try await Task.sleep(for: .seconds(60)) }
    })
}

@MainActor
@Suite struct TerminalConnectionTests {
  @Test(arguments: [true, false]) func restsLessForALiveSessionThanForAStoppedOne(live: Bool) async {
    let log = ConnectionLog()
    let connection = makeConnection(log)

    await connection.connect("a", live: live)

    #expect(log.entries == [.sleep(live ? .milliseconds(150) : .milliseconds(800)), .request("a")])
    #expect(connection.terminals == sample)
  }

  /// Moving through the sidebar cancels the connection of each session it passes.
  @Test(arguments: [true, false]) func cancellingDuringTheRestSendsNoRequest(live: Bool) async {
    let log = ConnectionLog()
    let connection = makeConnection(log, block: { true })
    let task = Task { await connection.connect("a", live: live) }
    await settle { !log.entries.isEmpty }

    task.cancel()
    await task.value

    #expect(log.requests.isEmpty)
    #expect(connection.terminals == nil)
  }

  @Test func cancellingDuringARetryWaitStopsTheRetries() async {
    let log = ConnectionLog()
    let connection = makeConnection(log, block: { !log.requests.isEmpty }, answer: { _ in throw Boom() })
    let task = Task { await connection.connect("a", live: true) }
    await settle { log.entries.count == 3 }

    task.cancel()
    await task.value

    #expect(log.requests.count == 1)
  }

  /// A retry waits a second and does not rest again.
  @Test(arguments: [true, false]) func retriesAFailedRequestAfterASecond(live: Bool) async {
    let log = ConnectionLog()
    let connection = makeConnection(
      log,
      answer: { n in
        if n == 1 { throw Boom() }
        return sample
      })

    await connection.connect("a", live: live)

    let rest: Duration = live ? .milliseconds(150) : .milliseconds(800)
    #expect(log.entries == [.sleep(rest), .request("a"), .sleep(.seconds(1)), .request("a")])
    #expect(connection.terminals == sample)
  }

  @Test func givesUpAfterTenFailedRequestsAndShowsTheError() async {
    let log = ConnectionLog()
    let connection = makeConnection(log, answer: { _ in throw Boom() })

    await connection.connect("a", live: true)

    #expect(log.requests.count == 10)
    #expect(connection.terminals == nil)
    #expect(connection.error != nil)
  }
}
