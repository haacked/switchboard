import Foundation
import SwitchboardCore
import Testing

@testable import SwitchboardApp

private final class Sent: @unchecked Sendable {
  private let lock = NSLock()
  private var list: [(String, [String: JSON])] = []
  var all: [(String, [String: JSON])] { lock.withLock { list } }
  func add(_ op: String, _ args: [String: JSON]) { lock.withLock { list.append((op, args)) } }
}

private func status(cap: Int?, live: Int, held: Int) -> LiveStatus {
  LiveStatus(
    cap: cap,
    live: (0..<live).map { LiveStatus.LiveSession(session: "s\($0)", name: "s\($0)", pid: $0 + 1, state: .working) },
    queued: (0..<held).map { LiveStatus.QueuedStart(session: "h\($0)", name: "h\($0)", since: Int64($0)) })
}

@Suite struct LimitMenuText {
  @Test func theLabelShowsTheRunningCountAndTheLimit() {
    #expect(LimitMenu.label(status(cap: 3, live: 2, held: 0)) == "Running 2 of 3")
  }

  @Test func theLabelOmitsTheLimitWhenThereIsNone() {
    #expect(LimitMenu.label(status(cap: nil, live: 5, held: 0)) == "Running 5")
  }

  @Test func theLabelCountsHeldStarts() {
    #expect(LimitMenu.label(status(cap: 2, live: 2, held: 3)) == "Running 2 of 2 · 3 held")
  }
}

@MainActor
@Suite struct BoardModelLimit {
  @Test func settingANumberSendsTheCap() async {
    let sent = Sent()
    let model = offlineModel()
    model.send = { op, args in
      sent.add(op, args)
      return .null
    }
    model.setLimit(2)
    await settle { !sent.all.isEmpty }
    #expect(sent.all.first?.0 == "live")
    #expect(sent.all.first?.1 == ["cap": .number(2)])
  }

  @Test func clearingTheLimitSendsUnlimited() async {
    let sent = Sent()
    let model = offlineModel()
    model.send = { op, args in
      sent.add(op, args)
      return .null
    }
    model.setLimit(nil)
    await settle { !sent.all.isEmpty }
    #expect(sent.all.first?.0 == "live")
    #expect(sent.all.first?.1 == ["unlimited": true])
  }
}
