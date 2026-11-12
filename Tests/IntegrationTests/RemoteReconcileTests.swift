import Foundation
import SwitchboardCore
import Testing

private let refusal = "ssh: connect to host mini.local port 22: Operation timed out"
private let notConnected = "mini is not connected: "
private let linkKinds: Set<String> = ["link_down", "link_up", "reconciled"]

/// A remote session while its host's link is down, and the reconcile that brings it up to date on each reconnect.
/// A session whose host sbd can't read keeps its state and says why. The reconcile records the hooks that waited
/// in the box's spool, asks `claude agents` about running turns, reads each transcript's tail, records `link_up`,
/// and cuts the recorded lines from the spool.
@Suite(.blocking(timeLimit: .seconds(180))) struct RemoteReconcileTests {
  private typealias Remote = (id: String, claudeSessionId: String, cwd: String, pid: Int)

  /// A session on mini whose claude runs and has answered its first prompt.
  private func idle(_ sbd: Instance, _ folder: String = "sb-box-repo") throws -> Remote {
    let s = try sbd.startOnHost(folder, prompt: "hello")
    try sbd.waitFor(s.id, "the first reply") { $0.lastReply == "Done: hello" }
    _ = try sbd.settledEvents()
    return s
  }

  private func tick(_ sbd: Instance) throws {
    for _ in 0..<3 { try sbd.advanceClock(1_000) }
  }

  private func lastEvent(_ sbd: Instance, _ id: String) throws -> Int64 { try sbd.events(id).last?.id ?? 0 }

  private func kinds(_ sbd: Instance, _ id: String, after: Int64 = 0) throws -> [String] {
    try sbd.events(id).filter { $0.id > after }.map(\.kind)
  }

  /// Drops the link, keeps it down, and waits for the session's `link_down`.
  private func drop(_ sbd: Instance, _ s: Remote, after mark: Int64) throws {
    try sbd.dropLinkAndRefuse(refusal)
    try sbd.waitFor("the link_down of \(s.id)") { try kinds(sbd, s.id, after: mark).contains("link_down") }
  }

  /// Lets the link connect again and waits for the `link_up` that ends the reconcile.
  private func reconnect(_ sbd: Instance, _ s: Remote, after mark: Int64) throws {
    try sbd.restoreLink()
    try sbd.waitFor("the link_up of \(s.id)", timeout: 45) { try kinds(sbd, s.id, after: mark).contains("link_up") }
  }

  /// The lines of the box's spool behind the first `count`.
  private func spoolLines(_ sbd: Instance, behind count: Int) -> [JSON] { Array(sbd.boxSpoolLines().dropFirst(count)) }

  private func hookKind(_ line: JSON) -> String? { line["payload"]?["hook_event_name"]?.string }

  /// Waits until the box's spool has held the same bytes for a second, so no hook of the stub is mid-write.
  private func settledSpool(_ sbd: Instance) throws -> Data {
    var last = sbd.boxSpoolData
    var since = Date()
    try sbd.waitFor("the box's spool to stop growing", timeout: 30) {
      let now = sbd.boxSpoolData
      if now != last {
        last = now
        since = Date()
      }
      return Date().timeIntervalSince(since) >= 1
    }
    return last
  }

  private func prompts(_ sbd: Instance, _ id: String, _ text: String) throws -> Int {
    try sbd.events(id, kind: "UserPromptSubmit").filter { $0.data["prompt"]?.string == text }.count
  }

  // MARK: The link drops

  @Test func droppingTheLinkRecordsOneLinkDownForALiveRemoteSession() throws {
    let sbd = try Instance.remote()
    let s = try idle(sbd)
    let mark = try lastEvent(sbd, s.id)

    try drop(sbd, s, after: mark)
    try tick(sbd)
    // The link retries while it is down. Each retry is not another drop.
    sleep(3)
    try tick(sbd)

    let after = try sbd.events(s.id).filter { $0.id > mark }
    let downs = after.filter { $0.kind == "link_down" }
    #expect(downs.count == 1, "\(after.map(\.kind))")
    #expect(downs.first?.data["host"] == "mini")
    #expect(
      !after.contains { ["link_up", "exited", "stopped", "reconciled"].contains($0.kind) }, "\(after.map(\.kind))")
    #expect(sbd.runs(s.pid))
  }

  @Test func aFrozenSessionShowsItsStateUnchangedItsLinkAndTheReasonInSbLs() throws {
    let sbd = try Instance.remote()
    let s = try idle(sbd)
    let before = try sbd.get(s.id)
    let mark = try lastEvent(sbd, s.id)

    try drop(sbd, s, after: mark)

    // A link that is down retries, so it reads `connecting` during each attempt.
    let row = try sbd.waitFor(
      "sb ls to name the unreachable link",
      fetch: { JSON.parse(try sbd.sb("ls", "--json"))?.array?.first { $0["id"]?.string == s.id } },
      until: { $0["link"] == "unreachable" })
    let after = try sbd.get(s.id)
    #expect(after.state == before.state)
    #expect(after.since == before.since, "the state's start moved though the state did not change")
    #expect(row["host"] == "mini")
    #expect(row["reason"]?.string?.hasPrefix(notConnected) == true, "\(row["reason"]?.text ?? "no reason")")
    #expect((row["reason"]?.string?.count ?? 0) > notConnected.count, "the reason names no cause")
    #expect(after.lastReply == "Done: hello")
  }

  /// A session whose turn runs keeps `working`, with the host in its reason, for as long as the link is down.
  @Test func aSessionWhoseTurnRanWhenTheLinkDroppedStaysWorking() throws {
    let sbd = try Instance.remote()
    let s = try sbd.startOnHost(prompt: "slow 120")
    try sbd.waitFor(s.id, "the turn") { $0.state == .working }
    let mark = try lastEvent(sbd, s.id)

    try drop(sbd, s, after: mark)
    try sbd.advanceClock(Attention.staleAfterMs + 60_000)

    let after = try sbd.get(s.id)
    #expect(after.state == .working)
    #expect(after.reason.hasPrefix(notConnected), "\(after.reason)")
  }

  @Test func droppingTheLinkRecordsNoLinkDownForAStoppedRemoteSessionOrALocalOne() throws {
    let sbd = try Instance.remote()
    let local = try sbd.new(prompt: "hello")
    try sbd.waitFor(local.id, "the local reply") { $0.lastReply == "Done: hello" }
    let stopped = try idle(sbd, "sb-box-stopped")
    try sbd.sb("stop", stopped.id)
    try sbd.waitFor(stopped.id, "claude to stop on the box") { $0.claudePid == nil }
    let live = try idle(sbd)
    let mark = try lastEvent(sbd, live.id)

    try drop(sbd, live, after: mark)
    try tick(sbd)

    let (ofStopped, ofLocal) = (try kinds(sbd, stopped.id), try kinds(sbd, local.id))
    #expect(ofStopped.allSatisfy { !linkKinds.contains($0) }, "\(ofStopped)")
    #expect(ofLocal.allSatisfy { !linkKinds.contains($0) }, "\(ofLocal)")
    #expect(!(try sbd.get(stopped.id)).reason.hasPrefix(notConnected))
  }

  // MARK: Stale

  @Test func aFrozenSessionIsNotStaleAfterTheStaleTimeWithTheLinkDown() throws {
    let sbd = try Instance.remote()
    let s = try idle(sbd)
    let before = try sbd.get(s.id)
    let mark = try lastEvent(sbd, s.id)
    try drop(sbd, s, after: mark)

    try sbd.advanceClock(Attention.staleAfterMs + 60_000)
    try tick(sbd)

    let after = try sbd.get(s.id)
    #expect(after.state == before.state)
    #expect(after.state != .stale)
    #expect(after.reason.hasPrefix(notConnected), "\(after.reason)")
    let since = try kinds(sbd, s.id, after: mark)
    #expect(!since.contains("exited") && !since.contains("stopped"), "\(since)")
    #expect(sbd.runs(s.pid), "sbd stopped the claude of a session that it could not read")
    #expect(sbd.boxStubArgs().count == 1, "\(sbd.boxStubArgs())")
  }

  /// sbd records no `link_down` for a session whose claude had stopped on record, so nothing freezes it.
  @Test func aRemoteSessionWhoseClaudeHadStoppedBeforeTheDropGoesStale() throws {
    let sbd = try Instance.remote()
    let s = try idle(sbd)
    try sbd.sb("stop", s.id)
    try sbd.waitFor(s.id, "claude to stop on the box") { $0.claudePid == nil }
    try sbd.dropLinkAndRefuse(refusal)

    try sbd.advanceClock(Attention.staleAfterMs + 60_000)

    let after = try sbd.waitFor(s.id, "the stale state") { $0.state == .stale }
    #expect(!after.reason.hasPrefix(notConnected), "\(after.reason)")
    #expect(!(try kinds(sbd, s.id)).contains("link_down"))
    #expect(sbd.boxStubArgs().count == 1, "\(sbd.boxStubArgs())")
  }

  // MARK: The reconcile

  @Test func eventsSentWhileTheLinkIsDownAreRecordedInIdOrderOnceWithTheBoxesTimesAndLinkUpFollows() throws {
    let sbd = try Instance.remote()
    let s = try idle(sbd)
    let mark = try lastEvent(sbd, s.id)
    try drop(sbd, s, after: mark)
    let spooledBefore = sbd.boxSpoolLines().count

    for (n, text) in ["while down one", "while down two"].enumerated() {
      try sbd.typeOnBox(s.id, text)
      try sbd.waitFor("the Stop of \(text) in the box's spool", timeout: 30) {
        spoolLines(sbd, behind: spooledBefore).filter { hookKind($0) == "Stop" }.count == n + 1
      }
    }
    _ = try settledSpool(sbd)
    let down = spoolLines(sbd, behind: spooledBefore)
    let recordedWhileDown = try kinds(sbd, s.id, after: mark).filter { SessionFacts.hookKinds.contains($0) }
    // The events wait long enough that the time of the reconnect differs from the time of the work.
    sleep(3)
    try reconnect(sbd, s, after: mark)
    _ = try sbd.settledEvents()

    #expect(recordedWhileDown.isEmpty, "sbd recorded \(recordedWhileDown) with the link down")
    let after = try sbd.events(s.id).filter { $0.id > mark }
    let up = try #require(after.firstIndex { $0.kind == "link_up" })
    let hooks = after[..<up].filter { SessionFacts.hookKinds.contains($0.kind) }
    try #require(hooks.map(\.kind) == down.compactMap(hookKind), "\(after.map(\.kind))")
    #expect(down.compactMap { $0["id"]?.string } == down.compactMap { $0["id"]?.string }.sorted())
    #expect(
      hooks.filter { $0.kind == "UserPromptSubmit" }.compactMap { $0.data["prompt"]?.string }
        == ["while down one", "while down two"])
    for (event, line) in zip(hooks, down) {
      let id = try #require(HostEventID(line["id"]?.string ?? ""))
      #expect(abs(event.t - id.ms) < 1_500, "\(event.kind) is \(event.t - id.ms) ms from the box's clock")
    }
    #expect(hooks.map(\.t) == hooks.map(\.t).sorted(), "the event times run backwards")
    #expect(after.filter { $0.kind == "link_up" }.count == 1)
    #expect(!after[up...].contains { SessionFacts.hookKinds.contains($0.kind) }, "a spooled hook follows link_up")
    for text in ["while down one", "while down two"] { #expect(try prompts(sbd, s.id, text) == 1) }
    let summary = try sbd.get(s.id)
    #expect(summary.lastReply == "Done: while down two")
    #expect(!summary.reason.hasPrefix(notConnected), "\(summary.reason)")
    #expect(try sbd.summaryJSON(s.id)["link"] == "connected")
    #expect(sbd.boxStubArgs().count == 1, "\(sbd.boxStubArgs())")
  }

  @Test func afterTheReconnectTheSessionReadsRunningAndFollowsTheNormalRulesAgain() throws {
    let sbd = try Instance.remote()
    let s = try idle(sbd)
    let mark = try lastEvent(sbd, s.id)
    try drop(sbd, s, after: mark)

    try reconnect(sbd, s, after: mark)
    let back = try sbd.waitFor(s.id, "the claude pid after the reconnect") { $0.claudePid != nil }
    try sbd.advanceClock(Attention.staleAfterMs + 60_000)

    #expect(back.claudePid == s.pid)
    #expect(!back.reason.hasPrefix(notConnected), "\(back.reason)")
    try sbd.waitFor(s.id, "the stale state once the link is up") { $0.state == .stale }
  }

  @Test func afterTheReconcileTheSpoolHoldsNoLineThatSbdRecorded() throws {
    let sbd = try Instance.remote()
    let s = try idle(sbd)
    let mark = try lastEvent(sbd, s.id)
    try drop(sbd, s, after: mark)
    let markers = (0..<3).map { "cut-\($0)-\(UUID().uuidString)" }
    for marker in markers { try sbd.spoolProbe(marker, session: s.id) }
    let before = sbd.boxSpoolLines().compactMap { $0["id"]?.string }
    try #require(before.count >= markers.count + 1, "the spool holds no line from before the drop")

    try reconnect(sbd, s, after: mark)

    let left = Set(sbd.boxSpoolLines().compactMap { $0["id"]?.string })
    #expect(left.isDisjoint(with: before), "\(left.intersection(before).count) recorded lines are still in the spool")
    for marker in markers { #expect(try sbd.probes(marker).count == 1, "\(marker)") }
    #expect(Spool.parse(sbd.boxSpoolData).firstUnreadable == nil)
  }

  /// Appends a spool line that sbd never received on the socket, as a hook does while the forward is down.
  private func appendUnreceivedLine(_ sbd: Instance, session: String, marker: String) throws -> String {
    let line = spoolLine(id: Instance.eventId(ns: Instance.clockNs()), session: session, marker: marker)
    let handle = try #require(FileHandle(forWritingAtPath: sbd.boxSpool))
    try handle.seekToEnd()
    try handle.write(contentsOf: line)
    try handle.close()
    return String(decoding: line, as: UTF8.self)
  }

  /// Keeps the link up, spools hooks that sbd records from the socket and one that it never received, and lets
  /// the cut interval pass. It returns the unreceived line and its marker once the recorded lines are gone.
  private func spoolAfterTheCutInterval(_ sbd: Instance, _ s: Remote, markers: [String]) throws -> (String, String) {
    for marker in markers { try sbd.spoolProbe(marker, session: s.id) }
    try sbd.waitFor("sbd to record the hooks from the socket") {
      try markers.allSatisfy { try sbd.probes($0).count == 1 }
    }
    let unreceived = "unreceived-\(UUID().uuidString)"
    let line = try appendUnreceivedLine(sbd, session: s.id, marker: unreceived)
    try #require(sbd.boxSpoolLines().count > markers.count)

    try sbd.advanceClock(601_000)
    try sbd.waitFor("the tick to cut the recorded lines", timeout: 45) {
      try sbd.advanceClock(1_000)
      return markers.allSatisfy { sbd.boxSpoolProbes($0).isEmpty }
    }
    return (line, unreceived)
  }

  /// The tick cuts every 10 minutes (`Service.spoolCutIntervalMs`). A spool takes a day to grow 64 MB. A cut costs a
  /// read of the whole spool.
  @Test func aLinkThatStaysUpGetsTheLinesThatSbdRecordedCutFromTheSpoolOnTheInterval() throws {
    let sbd = try Instance.remote()
    let s = try idle(sbd)
    let markers = (0..<3).map { "periodic-\($0)-\(UUID().uuidString)" }

    let (line, _) = try spoolAfterTheCutInterval(sbd, s, markers: markers)

    #expect(
      String(decoding: sbd.boxSpoolData, as: UTF8.self).hasPrefix(line),
      "the spool does not start with the unreceived line")
    for marker in markers { #expect(try sbd.probes(marker).count == 1, "\(marker)") }
    #expect(try kinds(sbd, s.id).filter { $0 == "link_down" }.isEmpty)
  }

  /// A spooled PermissionRequest that sbd recorded before its live hook arrived would make the live hook dedup
  /// to an empty answer, so only the reconcile records spool lines.
  @Test func theCutOnTheIntervalRecordsNoSpoolLine() throws {
    let sbd = try Instance.remote()
    let s = try idle(sbd)

    let (line, unreceived) = try spoolAfterTheCutInterval(sbd, s, markers: ["periodic-\(UUID().uuidString)"])
    _ = try sbd.settledEvents()

    #expect(try sbd.probes(unreceived).isEmpty, "the cut recorded a line whose hook sbd never received")
    #expect(String(decoding: sbd.boxSpoolData, as: UTF8.self).hasPrefix(line))
  }

  /// The second reconcile reads a spool that the first one cut, and the ids that sbd recorded stay recorded.
  @Test func aSecondDropAndReconnectRecordsNoEventAgain() throws {
    let sbd = try Instance.remote()
    let s = try idle(sbd)
    let mark = try lastEvent(sbd, s.id)
    try drop(sbd, s, after: mark)
    let marker = "twice-\(UUID().uuidString)"
    try sbd.spoolProbe(marker, session: s.id)
    try reconnect(sbd, s, after: mark)
    let again = try lastEvent(sbd, s.id)

    try drop(sbd, s, after: again)
    try reconnect(sbd, s, after: again)
    _ = try sbd.settledEvents()

    #expect(try sbd.probes(marker).count == 1)
    let all = try kinds(sbd, s.id, after: mark)
    #expect(all.filter { $0 == "link_down" }.count == 2, "\(all)")
    #expect(all.filter { $0 == "link_up" }.count == 2, "\(all)")
    #expect(try sbd.events(s.id, kind: "SessionStart").count == 1)
  }

  /// The shim appends a line after sbd read the spool and before the cut. The cut removes only what sbd read.
  @Test func aLineAppendedDuringTheReconcileIsStillInTheSpoolAfterTheCut() throws {
    let sbd = try Instance.remoteWithGates()
    let s = try idle(sbd)
    let mark = try lastEvent(sbd, s.id)
    try drop(sbd, s, after: mark)
    let (early, during) = ("before-cut-\(UUID().uuidString)", "during-cut-\(UUID().uuidString)")
    try sbd.spoolProbe(early, session: s.id)

    try sbd.holdBoxGate(.spoolDrop)
    try sbd.restoreLink()
    try sbd.waitFor("the spool cut to reach the box", timeout: 45) { sbd.boxGateReached(.spoolDrop) }
    try sbd.spoolProbe(during, session: s.id)
    try sbd.releaseBoxGate(.spoolDrop)
    try sbd.waitFor("the link_up", timeout: 45) { try kinds(sbd, s.id, after: mark).contains("link_up") }
    _ = try sbd.settledEvents()

    #expect(sbd.boxSpoolProbes(during).count == 1, "the cut removed a line that the shim wrote during the reconcile")
    #expect(sbd.boxSpoolProbes(early).isEmpty, "the cut left a line that sbd recorded")
    #expect(try sbd.probes(early).count == 1)
    #expect(try sbd.probes(during).count <= 1)
    #expect(Spool.parse(sbd.boxSpoolData).firstUnreadable == nil)

    // The next reconcile records the line when the forward had not carried it, and never twice.
    let again = try lastEvent(sbd, s.id)
    try drop(sbd, s, after: again)
    try reconnect(sbd, s, after: again)
    _ = try sbd.settledEvents()
    #expect(try sbd.probes(during).count == 1)
    #expect(sbd.boxSpoolProbes(during).isEmpty)
  }

  /// A line that sbd did not record stops the cut. It stays, and so does every line behind it.
  @Test(arguments: ["garbage", "local", "stranger", "other-kind"])
  func aSpoolLineThatSbdDoesNotRecordStaysInTheSpoolWithEveryLineBehindIt(shape: String) throws {
    let sbd = try Instance.remote()
    let local = try sbd.new()
    let s = try idle(sbd)
    let mark = try lastEvent(sbd, s.id)
    try drop(sbd, s, after: mark)
    let (forged, behind) = ("forged-\(UUID().uuidString)", "behind-\(UUID().uuidString)")
    func spoolLine(session: String, payload: JSON) -> String {
      JSON.object([
        "v": 1, "id": .string(Instance.eventId(ns: Instance.clockNs())), "session": .string(session),
        "payload": payload,
      ]).text + "\n"
    }
    let bad: String =
      switch shape {
      case "garbage": "not a spool line \(forged)\n"
      case "local": spoolLine(session: local.id, payload: Instance.probePayload(forged))
      case "stranger": spoolLine(session: "zzzzzz", payload: Instance.probePayload(forged))
      // A kind that only sbd records, under a session of this host.
      default:
        spoolLine(
          session: s.id, payload: ["hook_event_name": "sent", "text": .string(forged), "probe": .string(forged)])
      }
    let handle = try #require(FileHandle(forWritingAtPath: sbd.boxSpool))
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(bad.utf8))
    try handle.close()
    try sbd.spoolProbe(behind, session: s.id)
    let localBefore = try sbd.events(local.id)

    try reconnect(sbd, s, after: mark)
    _ = try sbd.settledEvents()

    let spool = String(decoding: sbd.boxSpoolData, as: UTF8.self)
    #expect(spool.hasPrefix(bad), "the spool no longer starts with the line that sbd did not record")
    #expect(sbd.boxSpoolProbes(behind).count == 1, "the cut removed a line behind one that it may not remove")
    #expect(try sbd.probes(behind).count == 1)
    #expect(try sbd.allEvents().filter { $0.data.text.contains(forged) }.isEmpty, "sbd recorded the forged line")
    #expect(try sbd.events(local.id) == localBefore)

    // The line is still there at the next reconcile, which records nothing twice.
    let again = try lastEvent(sbd, s.id)
    try drop(sbd, s, after: again)
    try reconnect(sbd, s, after: again)
    _ = try sbd.settledEvents()
    #expect(try sbd.probes(behind).count == 1)
    #expect(String(decoding: sbd.boxSpoolData, as: UTF8.self).hasPrefix(bad))
    #expect(try sbd.allEvents().filter { $0.data.text.contains(forged) }.isEmpty)
  }

  // MARK: A reconcile cut short

  /// The link drops while a step of the reconcile runs on the box. sbd records no `link_up`, removes no spool line
  /// that it did not record, and the next reconnect finishes the work with each event recorded once.
  @Test(arguments: Instance.BoxGate.allCases)
  func aReconcileCutShortByASecondDropRecordsNoLinkUpAndTheNextReconnectFinishesIt(step: Instance.BoxGate) throws {
    let sbd = try Instance.remoteWithGates()
    let s = try idle(sbd)
    let mark = try lastEvent(sbd, s.id)
    try drop(sbd, s, after: mark)
    // A turn that claude was interrupted in sends no Stop, so `claude agents` has a turn to answer for.
    let spooledBefore = sbd.boxSpoolLines().count
    try sbd.typeOnBox(s.id, "interrupt go")
    try sbd.waitFor("the interrupted turn in the box's spool", timeout: 30) {
      spoolLines(sbd, behind: spooledBefore).contains { hookKind($0) == "PreToolUse" }
    }
    let markers = (0..<2).map { "short-\($0)-\(UUID().uuidString)" }
    for marker in markers { try sbd.spoolProbe(marker, session: s.id) }
    let spoolBefore = try settledSpool(sbd)

    try sbd.holdBoxGate(step, claudeSessionId: s.claudeSessionId)
    try sbd.restoreLink()
    try sbd.waitFor("the reconcile to reach \(step.rawValue) on the box", timeout: 45) { sbd.boxGateReached(step) }
    try sbd.dropLinkAndRefuse(refusal)
    try sbd.releaseBoxGate(step)
    try tick(sbd)
    _ = try sbd.settledEvents()

    let cutShort = try kinds(sbd, s.id, after: mark)
    #expect(!cutShort.contains("link_up"), "\(cutShort)")
    let frozen = try sbd.get(s.id)
    #expect(frozen.reason.hasPrefix(notConnected), "\(frozen.reason)")
    if step == .spoolRead {
      // A failed `==` of two Data values makes Swift Testing compute their difference, which is slow.
      let unchanged = sbd.boxSpoolData == spoolBefore
      #expect(unchanged, "a reconcile that never read the spool changed it")
      for marker in markers { #expect(try sbd.probes(marker).isEmpty, "\(marker)") }
    }
    // Whatever the step, a line that is gone from the spool is one that sbd recorded.
    for marker in markers where sbd.boxSpoolProbes(marker).isEmpty {
      #expect(try sbd.probes(marker).count == 1, "the spool lost \(marker), which sbd never recorded")
    }
    for marker in markers { #expect(try sbd.probes(marker).count <= 1, "\(marker)") }

    try reconnect(sbd, s, after: mark)
    try sbd.waitFor(s.id, "the interrupted turn to end", timeout: 45) { $0.state != .working }
    _ = try sbd.settledEvents()

    for marker in markers {
      #expect(try sbd.probes(marker).count == 1, "\(marker)")
      #expect(sbd.boxSpoolProbes(marker).isEmpty, "\(marker) is still in the spool")
    }
    #expect(try prompts(sbd, s.id, "interrupt go") == 1)
    #expect(try sbd.events(s.id, kind: "idle").count == 1)
    #expect(try kinds(sbd, s.id, after: mark).filter { $0 == "link_up" }.count == 1)
    #expect(try sbd.events(s.id, kind: "SessionStart").count == 1)
    #expect(!(try kinds(sbd, s.id, after: mark)).contains("exited"))
    #expect(sbd.boxStubArgs().count == 1, "\(sbd.boxStubArgs())")
  }

  /// The link drops while the last step reads the panes and processes. The spool's events are in the log by then,
  /// and the session still gets no `link_up`.
  @Test func aReconcileCutShortDuringTheReadOfThePanesRecordsNoLinkUpAndTheNextReconnectFinishesIt() throws {
    let sbd = try Instance.remote(boxBin: true)
    try sbd.installBoxPsGate()
    let s = try idle(sbd)
    let mark = try lastEvent(sbd, s.id)
    try drop(sbd, s, after: mark)
    let marker = "panes-\(UUID().uuidString)"
    try sbd.spoolProbe(marker, session: s.id)

    try? FileManager.default.removeItem(atPath: sbd.gate("ps-waiting"))
    sbd.hold("ps-gate")
    try sbd.restoreLink()
    try sbd.waitFor("the reconcile to reach the read of the panes", timeout: 45) {
      FileManager.default.fileExists(atPath: sbd.gate("ps-waiting"))
    }
    try sbd.dropLinkAndRefuse(refusal)
    try sbd.release("ps-gate")
    try tick(sbd)
    _ = try sbd.settledEvents()

    let cutShort = try kinds(sbd, s.id, after: mark)
    #expect(!cutShort.contains("link_up"), "\(cutShort)")
    #expect(!cutShort.contains("exited"), "\(cutShort)")
    #expect((try sbd.get(s.id)).reason.hasPrefix(notConnected))
    #expect(try sbd.probes(marker).count == 1)

    try reconnect(sbd, s, after: mark)
    _ = try sbd.settledEvents()

    let after = try kinds(sbd, s.id, after: mark)
    #expect(after.filter { $0 == "link_up" }.count == 1, "\(after)")
    #expect(after.filter { $0 == "link_down" }.count == 1, "\(after)")
    #expect(try sbd.probes(marker).count == 1)
    #expect(sbd.boxSpoolProbes(marker).isEmpty)
    #expect(!after.contains("exited"), "\(after)")
    #expect(sbd.runs(s.pid))
    #expect(sbd.boxStubArgs().count == 1, "\(sbd.boxStubArgs())")
  }

  /// The forward is up before the reconcile has read the spool. A hook that arrives then is not applied ahead of
  /// the earlier events that wait in the spool.
  @Test func aHookThatArrivesWhileTheReconcileRunsIsRecordedBehindTheSpooledEventsAndOnce() throws {
    let sbd = try Instance.remoteWithGates()
    let s = try idle(sbd)
    let mark = try lastEvent(sbd, s.id)
    try drop(sbd, s, after: mark)
    let (early, live) = ("spooled-\(UUID().uuidString)", "live-\(UUID().uuidString)")
    try sbd.spoolProbe(early, session: s.id)

    try sbd.holdBoxGate(.spoolRead)
    try sbd.restoreLink()
    try sbd.waitFor("the spool read to reach the box", timeout: 45) { sbd.boxGateReached(.spoolRead) }
    try sbd.spoolProbe(live, session: s.id)
    // Longer than the window that a hook from the socket waits for earlier ones.
    sleep(1)
    let recordedWhileHeld = try sbd.probes(live).count + (try sbd.probes(early).count)
    try sbd.releaseBoxGate(.spoolRead)
    try sbd.waitFor("the link_up", timeout: 45) { try kinds(sbd, s.id, after: mark).contains("link_up") }
    _ = try sbd.settledEvents()

    #expect(recordedWhileHeld == 0, "sbd recorded a hook before it read the spool")
    let after = try sbd.events(s.id).filter { $0.id > mark }
    let first = try #require(after.firstIndex { $0.data["probe"]?.string == early }, "\(after.map(\.kind))")
    let second = try #require(after.firstIndex { $0.data["probe"]?.string == live }, "\(after.map(\.kind))")
    #expect(first < second, "the hook from the socket was applied ahead of the spooled one")
    #expect(try sbd.probes(early).count == 1)
    #expect(try sbd.probes(live).count == 1)
    #expect(after.filter { $0.kind == "link_up" }.count == 1)
  }

  // MARK: The steps

  /// claude sends no hook when Escape interrupts a turn. The reconcile asks `claude agents` on the box.
  @Test func aTurnThatWasInterruptedWhileTheLinkWasDownEndsFromClaudeAgentsOnTheBox() throws {
    let sbd = try Instance.remoteWithGates()
    let s = try idle(sbd)
    let mark = try lastEvent(sbd, s.id)
    try drop(sbd, s, after: mark)
    let spooledBefore = sbd.boxSpoolLines().count
    try sbd.typeOnBox(s.id, "interrupt go")
    try sbd.waitFor("the interrupted turn in the box's spool", timeout: 30) {
      spoolLines(sbd, behind: spooledBefore).contains { hookKind($0) == "PreToolUse" }
    }

    try reconnect(sbd, s, after: mark)
    let after = try sbd.waitFor(s.id, "the interrupted turn to end", timeout: 45) { $0.state != .working }
    try tick(sbd)

    #expect(try prompts(sbd, s.id, "interrupt go") == 1)
    #expect(try sbd.events(s.id, kind: "idle").count == 1)
    #expect(!after.reason.hasPrefix(notConnected), "\(after.reason)")
    #expect(sbd.stubArgs().isEmpty, "a claude ran on this Mac: \(sbd.stubArgs())")
    #expect(try sbd.macCalls(holding: [s.claudeSessionId, "agents"]).filter { $0.runs("claude-stub") }.isEmpty)
  }

  /// The turn's Stop never reaches sbd: the test removes its line from the spool. `claude agents` on the box lists
  /// the conversation idle, which ends the turn. The transcript on the box shows the reply and when it was written,
  /// and the reconcile records both.
  @Test func aTurnThatEndedWhileDownWithItsStopLineRemovedFromTheSpoolEndsWithTheReplyOfTheTranscriptTail() throws {
    // The box's claude wrapper sets SB_HOME, where the stub's `claude agents` finds its rows.
    let sbd = try Instance.remoteWithGates()
    let s = try idle(sbd)
    let mark = try lastEvent(sbd, s.id)
    try drop(sbd, s, after: mark)
    let spooledBefore = sbd.boxSpoolLines().count
    try sbd.typeOnBox(s.id, "finish while down")
    try sbd.waitFor("the turn's Stop in the box's spool", timeout: 30) {
      spoolLines(sbd, behind: spooledBefore).contains { hookKind($0) == "Stop" }
    }
    let whole = String(decoding: try settledSpool(sbd), as: UTF8.self).split(separator: "\n").map(String.init)
    let kept = whole.enumerated().filter { index, line in
      index < spooledBefore || JSON.parse(line).flatMap(hookKind) != "Stop"
    }.map(\.element)
    try #require(kept.count == whole.count - 1, "the turn spooled \(whole.count - kept.count) Stop lines")
    try (kept.joined(separator: "\n") + "\n").write(toFile: sbd.boxSpool, atomically: true, encoding: .utf8)
    // Claude Code stamps each transcript line. The stub does not, so the test writes the turn's last line.
    let reply = "Finished while the link was down."
    try appendReply(sbd, s, reply)
    let wroteAt = try sbd.now()
    // The real claude lists a conversation whose turn ended as idle. The stub removes its row when a turn ends.
    try writeAgentsRow(sbd, s, status: "idle", pid: s.pid)

    try reconnect(sbd, s, after: mark)
    let after = try sbd.waitFor(s.id, "the turn to end from the transcript", timeout: 45) {
      $0.state != .working && $0.lastReply == reply
    }

    let since = try sbd.events(s.id).filter { $0.id > mark }
    #expect(try prompts(sbd, s.id, "finish while down") == 1)
    #expect(!since.contains { $0.kind == "Stop" }, "sbd recorded a Stop that was not in the spool")
    #expect(since.filter { $0.kind == "idle" }.count == 1, "\(since.map(\.kind))")
    let reconciled = try #require(since.first { $0.kind == "reconciled" }, "\(since.map(\.kind))")
    #expect(reconciled.data["lastReply"]?.string == reply)
    let activity = try #require(reconciled.data["lastActivity"]?.int)
    #expect(abs(Int64(activity) - wroteAt) < 5_000, "the activity is \(Int64(activity) - wroteAt) ms from the line")
    #expect(abs(after.lastActivity - wroteAt) < 5_000)
    #expect(!after.reason.hasPrefix(notConnected), "\(after.reason)")
    #expect(sbd.boxStubArgs().count == 1, "\(sbd.boxStubArgs())")
  }

  /// claude also writes text in the middle of a turn, before its next tool call. When `claude agents` does not
  /// list a running turn's conversation as idle with a claude, a newer reply in the transcript's tail ends nothing.
  /// The run fails, hangs, leaves the conversation out, lists it busy, or lists it with no claude.
  @Test(arguments: ["fails", "times out", "leaves it out", "lists it busy", "lists it with no pid"])
  func aTurnThatClaudeAgentsDidNotReportIdleDoesNotEndThroughTheTranscriptTail(shape: String) throws {
    let sbd = try Instance.remoteWithGates()
    let s = try idle(sbd)
    let mark = try lastEvent(sbd, s.id)
    try drop(sbd, s, after: mark)
    let spooledBefore = sbd.boxSpoolLines().count
    try sbd.typeOnBox(s.id, "interrupt go")
    try sbd.waitFor("the interrupted turn in the box's spool", timeout: 30) {
      spoolLines(sbd, behind: spooledBefore).contains { hookKind($0) == "PreToolUse" }
    }
    _ = try settledSpool(sbd)
    // The stub lists the interrupted turn as idle. Each shape replaces that row after the stub wrote it.
    try sbd.waitFor("the interrupted turn's row in claude agents", timeout: 30) {
      FileManager.default.fileExists(atPath: agentsRow(sbd, s))
    }
    try appendReply(sbd, s, "Let me read the next file.")
    switch shape {
    case "fails": FileManager.default.createFile(atPath: sbd.boxAgentsFail, contents: nil)
    case "times out": try sbd.holdBoxGate(.agents)
    case "leaves it out": try FileManager.default.removeItem(atPath: agentsRow(sbd, s))
    case "lists it busy": try writeAgentsRow(sbd, s, status: "busy", pid: s.pid)
    default: try writeAgentsRow(sbd, s, status: "idle", pid: nil)
    }
    defer { try? sbd.releaseBoxGate(.agents) }
    let agentsRuns = agentsRunsOnBox(sbd)

    try reconnect(sbd, s, after: mark)
    _ = try sbd.settledEvents()

    let since = try sbd.events(s.id).filter { $0.id > mark }
    #expect(!since.contains { $0.kind == "idle" }, "\(since.map(\.kind))")
    #expect(try sbd.get(s.id).state == .working)
    #expect(try prompts(sbd, s.id, "interrupt go") == 1)
    if shape == "times out" { #expect(sbd.boxGateReached(.agents)) }
    if !["fails", "times out"].contains(shape) { #expect(agentsRunsOnBox(sbd) > agentsRuns) }
  }

  /// The file of the row that `claude agents` on the box lists for the conversation. The stub writes it while a
  /// turn is interrupted, and removes it when a turn starts or ends.
  private func agentsRow(_ sbd: Instance, _ s: Remote) -> String { "\(sbd.boxSB)/claude/status/\(s.claudeSessionId)" }

  private func writeAgentsRow(_ sbd: Instance, _ s: Remote, status: String, pid: Int?) throws {
    var row: [String: JSON] = [
      "sessionId": .string(s.claudeSessionId), "cwd": .string(s.cwd), "status": .string(status),
    ]
    if let pid { row["pid"] = .number(Double(pid)) }
    try JSON.object(row).text.write(toFile: agentsRow(sbd, s), atomically: false, encoding: .utf8)
  }

  /// The count of the box's `claude agents` runs that reached the stub.
  private func agentsRunsOnBox(_ sbd: Instance) -> Int {
    sbd.boxStubCalls().filter { $0.args.hasPrefix("agents") }.count
  }

  /// Appends an assistant line with a timestamp to the session's transcript on the box. Claude Code stamps each
  /// transcript line, and the stub does not.
  private func appendReply(_ sbd: Instance, _ s: Remote, _ reply: String) throws {
    let stamp = ISO8601DateFormatter()
    stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let line: JSON = [
      "type": "assistant", "timestamp": .string(stamp.string(from: Date())),
      "message": ["role": "assistant", "content": [["type": "text", "text": .string(reply)]]],
    ]
    let transcript = try #require(sbd.boxTranscripts(s.claudeSessionId).first)
    let handle = try #require(FileHandle(forWritingAtPath: transcript))
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data((line.text + "\n").utf8))
  }

  // MARK: The prune of recorded ids

  /// A spool line of a probe for the session, as the shim writes it.
  private func spoolLine(id: String, session: String, marker: String) -> Data {
    let line: JSON = [
      "v": 1, "id": .string(id), "session": .string(session), "payload": Instance.probePayload(marker),
    ]
    return Data((line.text + "\n").utf8)
  }

  /// Appends a probe's line to the box's spool, as the shim does before it sends the hook.
  private func appendSpoolLine(_ sbd: Instance, id: String, session: String, marker: String) throws {
    try (sbd.boxSpoolData + spoolLine(id: id, session: session, marker: marker))
      .write(to: URL(fileURLWithPath: sbd.boxSpool))
  }

  /// An event id two days older than now, which the prune's time rule alone forgets.
  private func twoDaysOld() -> String { Instance.eventId(ns: Instance.clockNs() - 2 * 86_400_000_000_000) }

  /// sbd with an idle stop of a day, so the hour that `prune` moves the clock leaves the session's claude running.
  private static let dayIdleStop: [String: JSON] = ["idleStopSeconds": 86_400]

  /// Runs the tick's hourly prune of recorded ids.
  private func prune(_ sbd: Instance) throws {
    try sbd.advanceClock(3_600_000)
    try tick(sbd)
  }

  /// The shim spools every hook, also one that the forward delivers. No reconcile cuts that line while the link
  /// stays up, so the prune keeps its id, and the next reconcile does not record the event again.
  @Test func aHookDeliveredLiveIsNotRecordedAgainByTheReconcileAfterAPrune() throws {
    let sbd = try Instance.remote(config: Self.dayIdleStop)
    let s = try idle(sbd)
    let marker = "live-\(UUID().uuidString)"
    let id = twoDaysOld()
    try appendSpoolLine(sbd, id: id, session: s.id, marker: marker)
    try sbd.sendProbe(marker, session: s.id, id: id)
    try sbd.waitFor("the live hook") { try sbd.probes(marker).count == 1 }

    try prune(sbd)
    let mark = try lastEvent(sbd, s.id)
    try drop(sbd, s, after: mark)
    try reconnect(sbd, s, after: mark)
    _ = try sbd.settledEvents()

    #expect(try sbd.probes(marker).count == 1)
    #expect(sbd.boxSpoolProbes(marker).isEmpty, "the reconcile did not cut the line")
  }

  /// The shim refuses the cut because the spool changed after the read. Every line that the read held stays in
  /// the spool, so the prune keeps their ids.
  @Test func aLineThatARefusedCutLeftInTheSpoolIsNotRecordedAgainAfterAPrune() throws {
    let sbd = try Instance.remoteWithGates(config: Self.dayIdleStop)
    let s = try idle(sbd)
    let mark = try lastEvent(sbd, s.id)
    try drop(sbd, s, after: mark)
    let (spooled, ahead) = ("spooled-\(UUID().uuidString)", "ahead-\(UUID().uuidString)")
    try appendSpoolLine(sbd, id: twoDaysOld(), session: s.id, marker: spooled)

    try sbd.holdBoxGate(.spoolDrop)
    try sbd.restoreLink()
    try sbd.waitFor("the spool cut to reach the box", timeout: 45) { sbd.boxGateReached(.spoolDrop) }
    let first = spoolLine(id: Instance.eventId(ns: Instance.clockNs()), session: s.id, marker: ahead)
    try (first + sbd.boxSpoolData).write(to: URL(fileURLWithPath: sbd.boxSpool))
    try sbd.releaseBoxGate(.spoolDrop)
    try sbd.waitFor("the link_up", timeout: 45) { try kinds(sbd, s.id, after: mark).contains("link_up") }
    _ = try sbd.settledEvents()
    try #require(sbd.boxSpoolProbes(spooled).count == 1, "the shim cut the spool")
    try #require(try sbd.probes(spooled).count == 1)

    try prune(sbd)
    let again = try lastEvent(sbd, s.id)
    try drop(sbd, s, after: again)
    try reconnect(sbd, s, after: again)
    _ = try sbd.settledEvents()

    #expect(try sbd.probes(spooled).count == 1)
    #expect(try sbd.probes(ahead).count == 1)
  }

  /// A session that did nothing while the link was down gets no `reconciled`.
  @Test func aSessionWhoseTranscriptDidNotChangeGetsNoReconciledEvent() throws {
    let sbd = try Instance.remote()
    let s = try idle(sbd)
    let before = try sbd.get(s.id)
    let mark = try lastEvent(sbd, s.id)
    try drop(sbd, s, after: mark)

    try reconnect(sbd, s, after: mark)
    _ = try sbd.settledEvents()

    let after = try sbd.get(s.id)
    #expect(!(try kinds(sbd, s.id, after: mark)).contains("reconciled"))
    #expect(after.lastReply == before.lastReply)
    #expect(after.lastActivity == before.lastActivity)
    #expect(after.state == before.state)
    #expect(after.since == before.since, "the state's start moved though the state did not change")
  }

  // MARK: Cards

  /// The hook of the prompt found no sbd, so the dialog on the box still waits. The card comes from the spool, and
  /// no hook is held for it, so its answer is typed into the pane.
  @Test func aPermissionPromptThatOpenedWhileTheLinkWasDownShowsAsACardAndIsAnsweredByTyping() throws {
    let sbd = try Instance.remote()
    let s = try idle(sbd)
    let mark = try lastEvent(sbd, s.id)
    try drop(sbd, s, after: mark)
    let spooledBefore = sbd.boxSpoolLines().count
    try sbd.typeOnBox(s.id, "perm touch x")
    try sbd.waitFor("the PermissionRequest in the box's spool", timeout: 30) {
      spoolLines(sbd, behind: spooledBefore).contains { hookKind($0) == "PermissionRequest" }
    }
    let whileDown = try sbd.cards()

    try reconnect(sbd, s, after: mark)
    let asked = try sbd.waitFor(s.id, "the card") { !$0.cards.isEmpty }
    let answer = try JSON.parse(sbd.sb("allow", "--json", s.id))
    try sbd.waitFor(s.id, "the command's reply", timeout: 30) { $0.lastReply == "Ran touch x" && $0.cards.isEmpty }

    #expect(whileDown.isEmpty)
    #expect(asked.state == .needsYou)
    #expect(asked.reason == "approve `touch x`")
    let card = try #require(asked.cards.first)
    #expect(card.session == s.id)
    #expect(card.kind == .permission)
    #expect(card.input == ["command": "touch x"])
    #expect(answer?["delivery"]?.string == "terminal")
    #expect(try sbd.events(s.id).contains { $0.kind == "answered" && $0.data["behavior"] == "allow" })
    #expect(try sbd.events(s.id, kind: "PermissionRequest").count == 1)
    #expect(sbd.boxStubArgs().count == 1, "\(sbd.boxStubArgs())")
    #expect(!(try kinds(sbd, s.id, after: mark)).contains("exited"))
  }

  // MARK: sbd restarts while the link is down

  @Test func sbdRestartedWhileTheLinkIsDownShowsTheFrozenStateAndThenReconciles() throws {
    let sbd = try Instance.remote()
    let s = try idle(sbd)
    let before = try sbd.get(s.id)
    let mark = try lastEvent(sbd, s.id)
    try drop(sbd, s, after: mark)
    let marker = "restart-\(UUID().uuidString)"
    try sbd.spoolProbe(marker, session: s.id)

    sbd.stopSbd()
    try sbd.startSbd()
    let atStart = try sbd.get(s.id)
    try sbd.advanceClock(Attention.staleAfterMs + 60_000)
    let later = try sbd.get(s.id)

    #expect(atStart.state == before.state)
    #expect(atStart.reason.hasPrefix(notConnected), "\(atStart.reason)")
    #expect(later.state == before.state)
    #expect(later.reason.hasPrefix(notConnected), "\(later.reason)")
    let down = try kinds(sbd, s.id, after: mark)
    #expect(!down.contains("exited") && !down.contains("link_up"), "\(down)")
    #expect(try sbd.probes(marker).isEmpty)
    #expect(sbd.runs(s.pid))

    try reconnect(sbd, s, after: mark)
    let back = try sbd.waitFor(s.id, "the claude pid after the reconnect") { $0.claudePid != nil }
    _ = try sbd.settledEvents()

    #expect(back.claudePid == s.pid)
    #expect(!back.reason.hasPrefix(notConnected), "\(back.reason)")
    #expect(try sbd.probes(marker).count == 1)
    #expect(sbd.boxSpoolProbes(marker).isEmpty)
    #expect(sbd.boxStubArgs().count == 1, "\(sbd.boxStubArgs())")
    #expect(sbd.stubArgs().isEmpty, "a claude ran on this Mac: \(sbd.stubArgs())")
  }

  /// sbd ends between recording the spool's events and cutting the spool. The next sbd reads the same lines.
  @Test func sbdKilledDuringTheSpoolCutRecordsNoEventAgainAfterItRestarts() throws {
    let sbd = try Instance.remoteWithGates()
    let s = try idle(sbd)
    let mark = try lastEvent(sbd, s.id)
    try drop(sbd, s, after: mark)
    let marker = "killed-\(UUID().uuidString)"
    try sbd.spoolProbe(marker, session: s.id)

    try sbd.holdBoxGate(.spoolDrop)
    try sbd.restoreLink()
    try sbd.waitFor("the spool cut to reach the box", timeout: 45) { sbd.boxGateReached(.spoolDrop) }
    let recordedBeforeTheCut = try sbd.probes(marker).count
    sbd.killSbd()
    try sbd.releaseBoxGate(.spoolDrop)
    try sbd.startSbd()
    try sbd.waitFor("the link_up after the restart", timeout: 60) {
      try kinds(sbd, s.id, after: mark).contains("link_up")
    }
    _ = try sbd.settledEvents()

    #expect(recordedBeforeTheCut == 1, "sbd asked for the cut before it recorded the line's event")
    #expect(try sbd.probes(marker).count == 1)
    #expect(sbd.boxSpoolProbes(marker).isEmpty)
    #expect(try sbd.events(s.id, kind: "SessionStart").count == 1)
  }

  // MARK: Messages

  @Test func sendWhileTheLinkIsDownReturnsQueuedAndTheMessageIsDeliveredAfterTheReconnect() throws {
    let sbd = try Instance.remote()
    let s = try idle(sbd)
    let mark = try lastEvent(sbd, s.id)
    try drop(sbd, s, after: mark)

    let printed = try sbd.sb("send", s.id, "after the link is back")
    try tick(sbd)
    let whileDown = try sbd.get(s.id)
    let pastedWhileDown = sbd.boxStubInput().contains { $0.contains("after the link is back") }
    try reconnect(sbd, s, after: mark)
    try sbd.waitFor(s.id, "the reply to the queued message", timeout: 45) {
      $0.lastReply == "Done: after the link is back"
    }

    #expect(printed == "queued\n")
    #expect(whileDown.reason.hasPrefix(notConnected), "\(whileDown.reason)")
    #expect(!pastedWhileDown)
    #expect(try sbd.events(s.id, "sent", text: "after the link is back").count == 1)
    try sbd.waitFor("delivered") { try sbd.events(s.id, "delivered", text: "after the link is back").count == 1 }
    #expect(sbd.boxStubInput().filter { $0.contains("after the link is back") }.count == 1)
    #expect(try prompts(sbd, s.id, "after the link is back") == 1)
    #expect(sbd.boxStubArgs().count == 1, "the send started another claude: \(sbd.boxStubArgs())")
    #expect(!sbd.stubInput().contains { $0.contains("after the link is back") }, "the paste reached this Mac")
    let after = try kinds(sbd, s.id, after: mark)
    let up = try #require(after.firstIndex(of: "link_up"))
    let delivered = try #require(after.firstIndex(of: "delivered"))
    #expect(up < delivered, "sbd pasted before the reconcile ended: \(after)")
  }

  /// A queued message survives a restart of sbd as its `sent` event.
  @Test func aMessageQueuedWhileTheLinkIsDownIsDeliveredAfterSbdRestartsAndTheLinkReconnects() throws {
    let sbd = try Instance.remote()
    let s = try idle(sbd)
    let mark = try lastEvent(sbd, s.id)
    try drop(sbd, s, after: mark)
    let printed = try sbd.sb("send", s.id, "kept across the restart")

    sbd.stopSbd()
    try sbd.startSbd()
    try reconnect(sbd, s, after: mark)
    try sbd.waitFor(s.id, "the reply to the queued message", timeout: 45) {
      $0.lastReply == "Done: kept across the restart"
    }

    #expect(printed == "queued\n")
    #expect(try prompts(sbd, s.id, "kept across the restart") == 1)
    #expect(try sbd.events(s.id, kind: "delivery_unknown").isEmpty)
    #expect(sbd.boxStubArgs().count == 1, "\(sbd.boxStubArgs())")
  }

  /// The session's claude had stopped, so the session is not frozen. Its queued message makes sbd want the host,
  /// and the reconcile launches the session with it.
  @Test func aMessageSentToAStoppedSessionWhileTheLinkIsDownResumesItsClaudeAfterTheReconnect() throws {
    let sbd = try Instance.remote()
    let s = try idle(sbd)
    try sbd.sb("stop", s.id)
    try sbd.waitFor(s.id, "claude to stop on the box") { $0.claudePid == nil }
    try sbd.dropLinkAndRefuse(refusal)

    let printed = try sbd.sb("send", s.id, "wake up")
    try tick(sbd)
    let startedWhileDown = sbd.boxStubArgs().count
    try sbd.restoreLink()
    try sbd.waitFor(s.id, "the reply after the resume", timeout: 45) { $0.lastReply == "Done: wake up" }

    #expect(printed == "queued\n")
    #expect(startedWhileDown == 1)
    let args = sbd.boxStubArgs()
    try #require(args.count == 2, "\(args)")
    #expect(args[1].hasPrefix("--resume \(s.claudeSessionId)"), "\(args[1])")
    #expect(try prompts(sbd, s.id, "wake up") == 1)
    #expect(sbd.stubArgs().isEmpty, "a claude ran on this Mac: \(sbd.stubArgs())")
  }

  // MARK: Regression

  @Test func aLocalSessionsEventsAndStateAreUnchangedByADropAndAReconnectOfAHost() throws {
    let sbd = try Instance.remote()
    let local = try sbd.new(prompt: "hello")
    try sbd.waitFor(local.id, "the local reply") { $0.lastReply == "Done: hello" }
    let s = try idle(sbd)
    let eventsBefore = try sbd.events(local.id)
    let before = try sbd.get(local.id)
    let mark = try lastEvent(sbd, s.id)

    try drop(sbd, s, after: mark)
    try tick(sbd)
    let whileDown = try sbd.get(local.id)
    try reconnect(sbd, s, after: mark)
    try tick(sbd)

    let after = try sbd.get(local.id)
    #expect(try sbd.events(local.id) == eventsBefore)
    for summary in [whileDown, after] {
      #expect(summary.state == before.state)
      #expect(summary.reason == before.reason)
      #expect(summary.since == before.since)
      #expect(summary.claudePid == before.claudePid)
    }
    let json = try sbd.summaryJSON(local.id)
    #expect(json.object?.keys.contains("link") == false, "\(json.text)")
    #expect(json.object?.keys.contains("host") == false, "\(json.text)")
  }

  @Test func aLocalSessionOnASbdWithoutHostsRecordsNoLinkEventAndGoesStaleAsBefore() throws {
    let sbd = try Instance()
    let s = try sbd.new(prompt: "hello")
    try sbd.waitFor(s.id, "the reply") { $0.lastReply == "Done: hello" }
    let before = try sbd.get(s.id)

    sbd.stopSbd()
    try sbd.startSbd()
    let restarted = try sbd.get(s.id)
    try sbd.advanceClock(Attention.staleAfterMs + 60_000)

    #expect(restarted.state == before.state)
    #expect(restarted.reason == before.reason)
    try sbd.waitFor(s.id, "the stale state") { $0.state == .stale }
    let recorded = try kinds(sbd, s.id)
    #expect(recorded.allSatisfy { !linkKinds.contains($0) }, "\(recorded)")
  }

  // MARK: The fixtures

  /// Starts a shell on the box's PATH that reads the file on its stdin with `tail`, as sbd's remote read does.
  private func startRead(_ sbd: Instance, _ file: String) throws -> Process {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", #"exec <"$1"; exec tail -c +1"#, "sb", file]
    p.environment = ["PATH": "\(sbd.boxBin):/usr/bin:/bin", "HOME": sbd.boxHome]
    p.standardInput = FileHandle.nullDevice
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try p.run()
    return p
  }

  private func ended(_ p: Process, within seconds: Double) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while p.isRunning && Date() < deadline { usleep(20_000) }
    return !p.isRunning
  }

  @Test func aBoxGateHoldsTheReadOfItsFileAndNoOtherRead() throws {
    let sbd = try Instance.remote(boxBin: true)
    try sbd.installBoxGates()
    try FileManager.default.createDirectory(atPath: sbd.boxSB, withIntermediateDirectories: true)
    try "line\n".write(toFile: sbd.boxSpool, atomically: true, encoding: .utf8)
    let other = "\(sbd.boxSB)/other.txt"
    try "other\n".write(toFile: other, atomically: true, encoding: .utf8)

    try sbd.holdBoxGate(.spoolRead)
    let passes = try startRead(sbd, other)
    let passed = ended(passes, within: 5)
    let reachedByTheOtherRead = sbd.boxGateReached(.spoolRead)
    let held = try startRead(sbd, sbd.boxSpool)
    try sbd.waitFor("the read of the spool to reach the gate", timeout: 5) { sbd.boxGateReached(.spoolRead) }
    let endedWhileHeld = ended(held, within: 0.5)
    try sbd.releaseBoxGate(.spoolRead)

    #expect(passed, "the gate held a read of another file")
    #expect(!reachedByTheOtherRead)
    #expect(!endedWhileHeld, "the gate did not hold the read of the spool")
    #expect(ended(held, within: 5), "the read did not finish after the gate was released")
    #expect(held.terminationStatus == 0)
  }

  @Test func theBoxesClaudeWrapperHoldsOnlyItsAgentsRun() throws {
    let sbd = try Instance.remote(boxBin: true)
    try sbd.installBoxGates()
    try FileManager.default.createDirectory(atPath: sbd.boxSB, withIntermediateDirectories: true)
    let env = ["PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin", "HOME": sbd.boxHome]

    let free = try runCommand("\(sbd.boxBin)/claude-stub", ["agents", "--json"], env: env, timeout: 10)
    try sbd.holdBoxGate(.agents)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "\(sbd.boxBin)/claude-stub")
    p.arguments = ["agents", "--json"]
    p.environment = env
    p.standardInput = FileHandle.nullDevice
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try p.run()
    try sbd.waitFor("the agents run to reach the gate", timeout: 5) { sbd.boxGateReached(.agents) }
    let endedWhileHeld = ended(p, within: 0.5)
    try sbd.releaseBoxGate(.agents)

    #expect(free.status == 0)
    #expect(free.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "[]", "\(free.stdout)")
    #expect(!endedWhileHeld)
    #expect(ended(p, within: 5))
    #expect(
      sbd.boxStubCalls().filter { $0.args.hasPrefix("agents") }.count == 2, "the stub did not log under the box's .sb")
  }
}
