import Foundation
import SwitchboardCore

/// `sb wait --block`: sets a wait whose `then` is `caller`, follows sbd's
/// events until the wait resolves, and prints the `wait-resolved` event. The
/// exit codes match `gh-events wait`: 0 when the wait resolved, 2 when the
/// timeout passed, and 3 when sbd can't be reached. sb reads only sbd's
/// socket. sbd's poller reads GitHub as it does for any open wait.
///
/// The timeout and SIGINT, SIGTERM, and SIGHUP clear the wait, so it doesn't
/// hold the session in Waiting after sb exits. A wait that resolves before
/// the clear still exits 0.
final class BlockingWait: @unchecked Sendable {
  static let timedOut: Int32 = 2
  static let unreachable: Int32 = 3
  /// How long sb keeps trying to reach sbd after its last answer. launchd
  /// restarts sbd, and the wait and the events persist across the restart.
  /// SB_UNREACHABLE_SECONDS lets a test shorten it.
  static let unreachableSeconds =
    ProcessInfo.processInfo.environment["SB_UNREACHABLE_SECONDS"].flatMap(TimeInterval.init) ?? 30

  enum Outcome {
    case resolved(Event)
    case cleared
  }

  /// The session as the user named it, until sbd's answer gives its id.
  private var session: String
  /// Whoever exits takes this lock and never releases it, so the main loop
  /// and a signal handler never both print or exit.
  private let exiting = NSLock()
  /// The main thread holds it while sbd sets the wait. A signal handler takes
  /// it first, so it clears a wait that sbd set as the signal came.
  private let registering = NSLock()
  /// The id of the wait. It is set before `registering` unlocks and never
  /// changes after.
  private var waitId = ""
  /// Guards `cursor`, which the main loop and a signal handler both read.
  private let lock = NSLock()
  private var cursor: EventCursor
  private var signalSources: [DispatchSourceSignal] = []

  init(session: String) {
    self.session = session
    cursor = EventCursor(since: nil, session: session)
  }

  func run(_ args: [String: JSON], timeout: TimeInterval?) -> Never {
    let deadline = timeout.map { Date().addingTimeInterval($0) }
    registering.lock()
    handleSignals()
    do {
      // The cursor starts at the session's newest event from before the wait.
      _ = try cursor.next(limit: 1)
      var request = args
      request["then"] = .string(Wait.Then.caller.rawValue)
      let summary = try client.call("wait", request, as: SessionSummary.self)
      // sbd's `wait` request appends the new wait to the session's waits.
      guard let wait = summary.waits.last else { fail(APIError("sbd set no wait")) }
      session = summary.id
      waitId = wait.id
      // The id names the session after a rename. A typed name or prefix may not.
      lock.withLock { cursor = EventCursor(since: cursor.since, session: summary.id) }
      registering.unlock()
    } catch {
      fail(error)
    }
    var lastAnswer = Date()
    while true {
      do {
        if let outcome = try read() {
          exiting.lock()
          report(outcome)
        }
        lastAnswer = Date()
      } catch is SbdUnreachable where Date().timeIntervalSince(lastAnswer) < BlockingWait.unreachableSeconds {
        // sbd may be restarting, so the next pass tries again.
      } catch let error as SbdUnreachable {
        fail(error)
      } catch {
        // The wait is set, so sb clears it before it exits.
        warn("\(error)")
        cancel(exitCode: 1)
      }
      if let deadline, Date() >= deadline { cancel(exitCode: BlockingWait.timedOut) }
      let left = deadline?.timeIntervalSinceNow ?? 1
      usleep(useconds_t(max(0.05, min(1, left)) * 1_000_000))
    }
  }

  /// Reads the session's events after the cursor until it reaches the newest
  /// one or an event that ends the wait.
  private func read() throws -> Outcome? {
    while true {
      let events = try lock.withLock { try cursor.next() }
      for event in events {
        if event.kind == "wait-resolved", event.data["wait"]?["id"]?.string == waitId { return .resolved(event) }
        if event.kind == "wait-cleared", event.data["waits"]?.array?.contains(.string(waitId)) == true {
          return .cleared
        }
      }
      if events.count < Event.defaultLimit { return nil }
    }
  }

  /// The caller holds `exiting`.
  private func report(_ outcome: Outcome) -> Never {
    switch outcome {
    case .resolved(let event):
      printJSON((try? JSON(encoding: event)) ?? .null)
      exit(0)
    case .cleared:
      die("\(session)'s wait \(waitId) was cleared")
    }
  }

  /// Clears the wait and exits with `exitCode`. When the wait is already
  /// gone, it reports how it ended instead.
  private func cancel(exitCode: Int32) -> Never {
    registering.lock()
    exiting.lock()
    do {
      _ = try client.call("clear-wait", ["session": .string(session), "wait": .string(waitId)])
    } catch is SbdUnreachable {
      warn("can't reach sbd to clear \(session)'s wait \(waitId)")
      exit(BlockingWait.unreachable)
    } catch {
      if let outcome = try? read() { report(outcome) }
    }
    exit(exitCode)
  }

  private func handleSignals() {
    for sig in [SIGINT, SIGTERM, SIGHUP] {
      signal(sig, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
      source.setEventHandler { [self] in cancel(exitCode: 128 + sig) }
      source.resume()
      signalSources.append(source)
    }
  }

  private func fail(_ error: Error) -> Never {
    exiting.lock()
    warn("\(error)")
    exit(error is SbdUnreachable ? BlockingWait.unreachable : 1)
  }
}
