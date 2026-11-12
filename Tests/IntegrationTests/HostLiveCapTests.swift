import Foundation
import SwitchboardCore
import Testing

private let refusal = "ssh: connect to host mini.local port 22: Operation timed out"

/// A remote session as these tests start it.
private struct OnHost {
  var id: String
  var claudeSessionId: String
}

/// Each host has its own live cap: its `liveCap` key, else config.json's `liveCap`. A host's cap counts only the
/// sessions on that host, and the Mac's cap counts only local sessions. A session whose host sbd can't read keeps
/// its slot, and sbd stops nothing on a host it can't read.
@Suite(.blocking(timeLimit: .seconds(180))) struct HostLiveCapTests {
  /// A sbd whose Mac has the cap `macCap`, with the host mini, whose `liveCap` key is `hostCap` or absent.
  private func instance(macCap: Int = 1, hostCap: Int? = 1) throws -> Instance {
    try Instance.remote(
      host: hostCap.map { ["liveCap": .number(Double($0))] } ?? [:], config: ["liveCap": .number(Double(macCap))])
  }

  /// Starts a session on mini in its own folder, named after the folder, with the prompt.
  private func newOnHost(_ sbd: Instance, _ folder: String, prompt: String) throws -> OnHost {
    try sbd.makeBoxFolder(folder)
    let summary = try sbd.newOnHost("~/\(folder)", "--prompt", prompt, "--name", folder)
    return OnHost(id: try sbd.id(of: summary), claudeSessionId: try #require(summary["claudeSessionId"]?.string))
  }

  /// A session on mini in the middle of a long tool call.
  private func busyOnHost(_ sbd: Instance, _ folder: String, seconds: Int = 30) throws -> OnHost {
    let s = try newOnHost(sbd, folder, prompt: "slow \(seconds)")
    try sbd.waitFor(s.id, "\(folder)'s slow tool on the box", timeout: 30) {
      $0.state == .working && $0.claudePid != nil
    }
    return s
  }

  /// A session on mini whose first turn has ended, with claude still running.
  private func idleOnHost(_ sbd: Instance, _ folder: String) throws -> OnHost {
    let s = try newOnHost(sbd, folder, prompt: "hello")
    try sbd.waitFor(s.id, "\(folder)'s first reply on the box", timeout: 30) {
      $0.lastReply == "Done: hello" && $0.claudePid != nil
    }
    return s
  }

  /// Whether the session's start waits for a slot. The text of a host's queued reason is not fixed, so this reads
  /// only that it is queued and names a full cap of one.
  private func isQueued(_ s: SessionSummary) -> Bool {
    s.claudePid == nil && s.reason.contains("queued") && s.reason.contains("1 of 1")
  }

  @discardableResult
  private func waitForQueued(_ sbd: Instance, _ id: String) throws -> SessionSummary {
    try sbd.waitFor(id, "the queued start", timeout: 30) { isQueued($0) }
  }

  /// The row of `sb live --json`'s `hosts` for the host.
  private func hostRow(_ sbd: Instance, _ host: String = "mini") throws -> JSON {
    let status = try sbd.liveStatus()
    let rows = try #require(status["hosts"]?.array, "sb live --json has no hosts: \(status.text)")
    return try #require(rows.first { $0["host"]?.string == host }, "no row for \(host): \(status.text)")
  }

  private func ids(_ row: JSON, _ list: String) -> [String] {
    (row[list]?.array ?? []).compactMap { $0["session"]?.string }
  }

  /// Whether the box's claude stub ever ran for the conversation.
  private func startedOnBox(_ sbd: Instance, _ s: OnHost) -> Bool {
    sbd.boxStubArgs().contains { $0.contains(s.claudeSessionId) }
  }

  // MARK: Each cap counts its own sessions

  @Test func aHostWithACapOfOneQueuesItsSecondStartWhileTheMacStartsASession() throws {
    let sbd = try instance(macCap: 1, hostCap: 1)
    _ = try busyOnHost(sbd, "a")

    let local = try sbd.new(prompt: "hello", name: "mac")
    let b = try newOnHost(sbd, "b", prompt: "hello")

    try sbd.waitFor(local.id, "the local session's reply") { $0.lastReply == "Done: hello" }
    try waitForQueued(sbd, b.id)
    try sbd.advanceClock(1_000)
    #expect(!startedOnBox(sbd, b), "the second start on mini ran past the host's cap")
    #expect(try sbd.events(b.id).contains { $0.kind == "start-queued" })
  }

  @Test func sbLiveJsonListsTheHostWithItsCapItsLiveAndItsQueuedSessions() throws {
    let sbd = try instance(macCap: 1, hostCap: 1)
    let a = try busyOnHost(sbd, "a")
    let local = try sbd.new(prompt: "hello", name: "mac")
    try sbd.waitFor(local.id, "the local session's reply") { $0.lastReply == "Done: hello" }
    let b = try newOnHost(sbd, "b", prompt: "hello")
    try waitForQueued(sbd, b.id)

    let status = try sbd.liveStatus()
    let row = try hostRow(sbd)

    #expect(status["cap"]?.int == 1)
    #expect(try sbd.liveIds("live") == [local.id], "the Mac's live list holds a session on mini")
    #expect(try sbd.liveIds("queued").isEmpty)
    #expect(row["cap"]?.int == 1)
    #expect(ids(row, "live") == [a.id])
    #expect(ids(row, "queued") == [b.id])
    #expect((row["live"]?.array ?? []).allSatisfy { $0["pid"]?.int != nil && $0["name"]?.string != nil })
    #expect(row["queued"]?.array?.first?["since"]?.int != nil)
    #expect(status["hosts"]?.array?.count == 1, "\(status.text)")
  }

  /// The text of the host's line is not fixed. It names the host, its count of live sessions, and its cap.
  @Test func sbLivePrintsALineForTheHost() throws {
    let sbd = try instance(macCap: 1, hostCap: 1)
    _ = try busyOnHost(sbd, "alpha-on-mini")
    let b = try newOnHost(sbd, "bravo-on-mini", prompt: "hello")
    try waitForQueued(sbd, b.id)

    let text = try sbd.sb("live")

    let lines = text.split(separator: "\n").map(String.init)
    #expect(lines.contains { $0.contains("mini") && $0.contains("1 of 1") }, "\(text)")
    #expect(text.contains("alpha-on-mini"), "\(text)")
    #expect(text.contains("bravo-on-mini"), "\(text)")
    #expect(lines.first?.hasPrefix("0 of 1 claude processes live, 0 queued") == true, "\(text)")
  }

  /// With no `liveCap` key, the host takes config.json's `liveCap`, and its sessions still count only against it.
  @Test func aHostWithNoLiveCapTakesTheCapOfTheConfigAndARemoteSessionLeavesTheMacsSlotFree() throws {
    let sbd = try instance(macCap: 1, hostCap: nil)
    let a = try busyOnHost(sbd, "a")

    let local = try sbd.new(prompt: "hello", name: "mac")

    let started = try sbd.waitFor(local.id, "the local session's reply") { $0.lastReply == "Done: hello" }
    #expect(started.reason.contains("queued") == false)
    let row = try hostRow(sbd)
    #expect(row["cap"]?.int == 1)
    #expect(ids(row, "live") == [a.id])
  }

  @Test func sbLiveSetSetsTheMacsCapAndLeavesTheHostsCap() throws {
    let sbd = try instance(macCap: 1, hostCap: 1)
    _ = try busyOnHost(sbd, "a")

    try sbd.sb("live", "--set", "3")

    #expect(try sbd.liveStatus()["cap"]?.int == 3)
    #expect(try hostRow(sbd)["cap"]?.int == 1)
  }

  // MARK: A slot frees on the host

  @Test func aQueuedStartOnAHostRunsWhenASlotOnThatHostFrees() throws {
    let sbd = try instance(macCap: 1, hostCap: 1)
    let a = try busyOnHost(sbd, "a")
    let b = try newOnHost(sbd, "b", prompt: "hello")
    try waitForQueued(sbd, b.id)

    try sbd.sb("stop", a.id)

    try sbd.waitFor(b.id, "the queued start on mini to run", timeout: 45) { $0.lastReply == "Done: hello" }
    #expect(ids(try hostRow(sbd), "queued").isEmpty)
  }

  @Test func anIdleRemoteSessionIsStoppedToMakeRoomOnItsHost() throws {
    let sbd = try instance(macCap: 1, hostCap: 1)
    let a = try idleOnHost(sbd, "a")

    let b = try newOnHost(sbd, "b", prompt: "hello")

    try sbd.waitFor(b.id, "b's start on mini", timeout: 45) { $0.lastReply == "Done: hello" }
    #expect(try !sbd.capStops(a.id).isEmpty)
    #expect(try sbd.get(a.id).claudePid == nil)
  }

  /// A start that waits for a slot on mini never stops a session on this Mac.
  @Test func anIdleLocalSessionIsNotStoppedForAQueuedStartOnAHost() throws {
    let sbd = try instance(macCap: 1, hostCap: 1)
    let local = try sbd.new(prompt: "hello", name: "mac")
    let idle = try sbd.waitFor(local.id, "the local reply") { $0.lastReply == "Done: hello" && $0.claudePid != nil }
    _ = try busyOnHost(sbd, "a")
    let b = try newOnHost(sbd, "b", prompt: "hello")
    try waitForQueued(sbd, b.id)

    try sbd.advanceClock(1_000)
    try sbd.advanceClock(1_000)

    #expect(try sbd.get(local.id).claudePid == idle.claudePid)
    #expect(try sbd.capStops(local.id).isEmpty)
    #expect(try !sbd.events(local.id).contains { $0.kind == "stopped" })
  }

  /// A start that waits for a slot on this Mac never stops a session on a host.
  @Test func anIdleRemoteSessionIsNotStoppedForAQueuedStartOnTheMac() throws {
    let sbd = try instance(macCap: 1, hostCap: 1)
    let remote = try idleOnHost(sbd, "a")
    let pid = try #require(try sbd.get(remote.id).claudePid)
    let busy = try sbd.new(prompt: "slow 30", name: "busy")
    try sbd.waitFor(busy.id, "the local slow tool") { $0.state == .working && $0.claudePid != nil }
    let queued = try sbd.new(prompt: "hello", name: "queued")
    try sbd.waitFor(queued.id, "the local queued start") { $0.reason.contains("queued") && $0.claudePid == nil }

    try sbd.advanceClock(1_000)
    try sbd.advanceClock(1_000)

    #expect(try sbd.get(remote.id).claudePid == pid)
    #expect(try sbd.capStops(remote.id).isEmpty)
    #expect(sbd.runs(pid))
  }

  // MARK: A host that sbd can't read

  /// A session whose host sbd can't read may still run there, so it holds its slot, and the host's queued start
  /// waits.
  @Test func aFrozenSessionKeepsItsSlotOnItsHost() throws {
    let sbd = try instance(macCap: 1, hostCap: 1)
    let a = try busyOnHost(sbd, "a")
    let b = try newOnHost(sbd, "b", prompt: "hello")
    try waitForQueued(sbd, b.id)

    try sbd.dropLinkAndRefuse(refusal)
    for _ in 0..<3 { try sbd.advanceClock(11_000) }

    #expect(!startedOnBox(sbd, b))
    #expect(try sbd.get(b.id).claudePid == nil)
    let row = try hostRow(sbd)
    #expect(ids(row, "live") == [a.id], "\(row.text)")
    #expect(ids(row, "queued") == [b.id], "\(row.text)")
    #expect(try sbd.capStops(a.id).isEmpty)
  }

  /// The turn of `a` ends on the box while the link is down, so `a` is idle there, but sbd can't read that. sbd
  /// stops nothing to make room while the host reads `.unknown`. After the reconnect, the normal rule stops `a`
  /// and `b` starts.
  @Test func anIdleSessionIsNotStoppedForASlotWhileItsHostReadsUnknown() throws {
    let sbd = try instance(macCap: 1, hostCap: 1)
    let a = try busyOnHost(sbd, "a", seconds: 12)
    let pid = try #require(try sbd.get(a.id).claudePid)
    let b = try newOnHost(sbd, "b", prompt: "hello")
    try waitForQueued(sbd, b.id)

    try sbd.dropLinkAndRefuse(refusal)
    try sbd.waitFor("a's turn to end on the box", timeout: 40) {
      sbd.boxSpoolLines().contains {
        $0["session"]?.string == a.id && $0["payload"]?["hook_event_name"]?.string == "Stop"
      }
    }
    for _ in 0..<3 { try sbd.advanceClock(11_000) }

    #expect(sbd.runs(pid), "sbd stopped a claude on a host that it could not read")
    #expect(try sbd.capStops(a.id).isEmpty)
    #expect(try !sbd.events(a.id).contains { $0.kind == "stopped" })
    #expect(!startedOnBox(sbd, b))

    try sbd.restoreLink()
    try sbd.waitFor(b.id, "b's start after the reconnect", timeout: 60) { $0.lastReply == "Done: hello" }
    #expect(try !sbd.capStops(a.id).isEmpty)
  }

  /// Sessions on a host that sbd can't read once held a slot of this Mac's cap each.
  @Test(arguments: [false, true])
  func sessionsOnADisconnectedHostDoNotHoldTheMacsSlots(running: Bool) throws {
    let sbd = try instance(macCap: 1, hostCap: nil)
    let a = try idleOnHost(sbd, "a")
    if !running {
      try sbd.sb("stop", a.id)
      try sbd.waitFor(a.id, "a to stop on the box") { $0.claudePid == nil && !$0.live }
    }
    try sbd.dropLinkAndRefuse(refusal)
    try sbd.advanceClock(1_000)

    let local = try sbd.new(prompt: "hello", name: "mac")

    let started = try sbd.waitFor(local.id, "the local session's reply") { $0.lastReply == "Done: hello" }
    #expect(!started.reason.contains("queued"))
    #expect(try sbd.liveIds("live") == [local.id])
  }
}
