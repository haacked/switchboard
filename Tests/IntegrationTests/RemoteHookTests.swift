import Foundation
import SwitchboardCore
import Testing

private let refusal = "ssh: connect to host mini.local port 22: Operation timed out"
private let forwardRefusal = "Error: remote port forwarding failed for listen path /home/haacked/.sb/sbd.sock"
private let eventIdShape = try! NSRegularExpression(pattern: "^[0-9]{20}-[0-9]+-[0-9a-f]{4}$")

private func isEventId(_ text: String) -> Bool {
  eventIdShape.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
}

private func kind(of path: String) -> String? {
  var info = stat()
  guard lstat(path, &info) == 0 else { return nil }
  switch info.st_mode & S_IFMT {
  case S_IFSOCK: return "socket"
  case S_IFDIR: return "folder"
  case S_IFLNK: return "symlink"
  default: return "file"
  }
}

/// A socket file that nothing listens on, as a dropped forward leaves.
private func makeStaleSocket(_ path: String) throws {
  try FileManager.default.createDirectory(
    atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
  close(try UnixSocket.listen(path: path))
}

/// Waits for a connection to the listener and returns it.
private func acceptOne(_ listener: Int32, seconds: Int32 = 5) throws -> Int32 {
  var waiting = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
  guard poll(&waiting, 1, seconds * 1000) == 1 else {
    throw TestError(description: "no connection reached the listener in \(seconds) s")
  }
  let fd = accept(listener, nil, nil)
  guard fd >= 0 else { throw TestError(description: "accept: \(UnixSocket.errnoText())") }
  UnixSocket.configure(fd, timeout: 5)
  return fd
}

/// What one run of the box's shim did.
private struct ShimRun {
  var status: Int32
  var stdout: String
  var seconds: Double
}

/// Runs the shim that sbd wrote on the box, as a hook of the session's claude does, and ends it after 15 s.
private func runBoxShim(_ sbd: Instance, session: String, payload: JSON) throws -> ShimRun {
  let started = Date()
  // `runCommand` reads the output on a queue of its own. A global queue gets no thread while the tests block
  // every thread of the pool.
  let r = try runCommand(
    findExecutable("python3") ?? "/usr/bin/python3", [sbd.boxShim, "hook"],
    env: [
      "HOME": sbd.boxHome, "SB_HOME": sbd.boxSB, "SB_SESSION_ID": session, "PATH": "/usr/local/bin:/usr/bin:/bin",
    ], input: Data(payload.text.utf8), timeout: 15)
  return ShimRun(status: r.status, stdout: r.stdout, seconds: Date().timeIntervalSince(started))
}

/// The hooks of a remote claude. They reach sbd through the forwarded socket of the session's host, at most once
/// and in the order of their ids, and `sb send` pastes into the pane on the box.
@Suite(.blocking(timeLimit: .seconds(240))) struct RemoteHookTests {
  /// The index of each marker's event in the whole log.
  private func order(_ sbd: Instance, _ markers: [String]) throws -> [String] {
    try sbd.allEvents().compactMap { $0.data["probe"]?.string }.filter(markers.contains)
  }

  private func probeLine(_ marker: String, session: String, id: String, kind: String = "Notification") -> String {
    Instance.hookLine(session: .string(session), payload: Instance.probePayload(marker, kind: kind), id: id)
  }

  // MARK: Setup on the box

  @Test func setupWritesTheShimAndTheHookSettingsOnTheBox() throws {
    let sbd = try Instance.remote()

    _ = try sbd.startOnHost()

    let shim = try String(contentsOfFile: sbd.boxShim, encoding: .utf8)
    #expect(shim.contains("spool.jsonl"), "the shim names no spool")
    let settings = try #require(JSON.parse(try String(contentsOfFile: sbd.boxSettings, encoding: .utf8)))
    let mac = try #require(JSON.parse(try String(contentsOfFile: sbd.home.claudeSettings, encoding: .utf8)))
    #expect(Set(settings["hooks"]?.object?.keys.map { $0 } ?? []) == Set(SessionFacts.hookKinds))
    for event in SessionFacts.hookKinds {
      let entry = try #require(settings["hooks"]?[event]?.array?.first, "no \(event) hook")
      let macEntry = try #require(mac["hooks"]?[event]?.array?.first)
      let handler = try #require(entry["hooks"]?.array?.first)
      let macHandler = try #require(macEntry["hooks"]?.array?.first)
      #expect(entry["hooks"]?.array?.count == 1)
      #expect(entry["matcher"] == macEntry["matcher"], "\(event)")
      #expect(handler["type"] == macHandler["type"], "\(event)")
      #expect(handler["timeout"] == macHandler["timeout"], "\(event)")
      // `<python> <box home>/.sb/bin/sb-shim hook`, with or without quotes around a path.
      let words = (handler["command"]?.string ?? "").replacingOccurrences(of: "'", with: "").split(separator: " ")
      try #require(words.count == 3, "\(event): \(handler.text)")
      #expect((String(words[0]) as NSString).lastPathComponent.hasPrefix("python3"), "\(event): \(words[0])")
      #expect(words[0].hasPrefix("/"), "\(event): the settings name no absolute python: \(words[0])")
      #expect(real(String(words[1])) == real(sbd.boxShim), "\(event): \(words[1])")
      #expect(words[2] == "hook")
    }
    #expect(!shim.contains(sbd.home.path + "/sbd.sock"), "the shim names the socket of this Mac")
  }

  @Test func setupForwardsTheBoxesSocketToTheHostsSocketOnThisMac() throws {
    let sbd = try Instance.remote()

    _ = try sbd.startOnHost()

    let forwards = sbd.sshStubForwards()
    try #require(forwards.count == 1, "\(forwards)")
    let argv = forwards[0]
    let spec = try #require(argv.firstIndex(of: "-R").map { argv[$0 + 1] })
    let ends = spec.split(separator: ":", maxSplits: 1).map(String.init)
    try #require(ends.count == 2, "\(spec)")
    #expect(real(ends[0]) == real(sbd.boxSocket), "\(spec)")
    #expect(real(ends[1]) == real(sbd.hostSocket("mini")), "\(spec)")
    #expect(argv.last == Instance.boxDestination)
    #expect(argv.contains { $0.hasPrefix("ControlPath=") })
    #expect(kind(of: sbd.boxSocket) == "socket")
  }

  @Test func aRemoteClaudeStartsWithTheBoxesHookSettings() throws {
    let sbd = try Instance.remote()

    let s = try sbd.startOnHost()

    let args = try #require(sbd.boxStubArgs().first).split(separator: " ").map(String.init)
    #expect(Array(args.prefix(2)) == ["--session-id", s.claudeSessionId], "\(args)")
    let settings = try #require(args.firstIndex(of: "--settings").map { args[$0 + 1] }, "\(args)")
    #expect(real(settings) == real(sbd.boxSettings))
    #expect(!args.contains(sbd.home.claudeSettings))
  }

  // MARK: Live

  @Test func aRemoteSessionShowsLiveFromItsSessionStartHook() throws {
    let sbd = try Instance.remote()
    try sbd.makeBoxFolder()

    let id = try sbd.id(of: try sbd.newOnHost("~/sb-box-repo"))
    let live = try sbd.waitFor(id, "the SessionStart of the claude on the box") { $0.live }

    #expect(live.host == "mini")
    let starts = try sbd.events(id).filter { $0.kind == "SessionStart" }
    #expect(starts.count == 1, "\(starts.count) SessionStart events")
    #expect(starts.first?.data["session_id"]?.string == live.claudeSessionId)
    #expect(try sbd.events(id).contains { $0.kind == "running" } == false, "sbd counted claude live without its hook")
  }

  @Test func aRemoteTurnRecordsItsHooksAndItsReply() throws {
    let sbd = try Instance.remote()

    let s = try sbd.startOnHost(prompt: "hello")
    let done = try sbd.waitFor(s.id, "the reply") { $0.lastReply == "Done: hello" }

    #expect(done.live)
    let kinds = try sbd.events(s.id).map(\.kind)
    let start = try #require(kinds.firstIndex(of: "SessionStart"))
    let prompt = try #require(kinds.firstIndex(of: "UserPromptSubmit"))
    let stop = try #require(kinds.firstIndex(of: "Stop"))
    #expect(start < prompt && prompt < stop, "\(kinds)")
    #expect(sbd.hookOutputs(s.claudeSessionId).isEmpty, "a hook of the remote claude printed to this Mac's home")
  }

  /// The shim spools each event before it sends it, so the spool holds the events that sbd recorded.
  @Test func theShimSpoolsEachHookOnTheBoxInTheSpoolsFormat() throws {
    let sbd = try Instance.remote()

    let s = try sbd.startOnHost(prompt: "hello")
    try sbd.waitFor(s.id, "the reply") { $0.lastReply == "Done: hello" }

    let lines = sbd.boxSpoolLines()
    let recorded = try sbd.events(s.id).filter { SessionFacts.hookKinds.contains($0.kind) }
    #expect(lines.count >= recorded.count, "\(lines.count) spool lines for \(recorded.count) recorded hooks")
    for line in lines {
      #expect(line["v"] == 1, "\(line.text)")
      #expect(line["session"]?.string == s.id, "\(line.text)")
      #expect(isEventId(line["id"]?.string ?? ""), "\(line.text)")
      #expect(line["payload"]?["hook_event_name"]?.string != nil, "\(line.text)")
      #expect(Set(line.object?.keys.map { $0 } ?? []) == ["v", "id", "session", "payload"], "\(line.text)")
    }
    let ids = lines.compactMap { $0["id"]?.string }
    #expect(Set(ids).count == ids.count, "two spool lines share an id")
    #expect(ids == ids.sorted(), "the ids of one claude's hooks are not in the order of its hooks")
    #expect(lines.first?["payload"]?["hook_event_name"] == "SessionStart")
    #expect(recorded.filter { $0.kind == "Stop" }.count == 1)
  }

  // MARK: Send

  @Test func sendPastesIntoTheRemoteSessionAndRecordsDelivered() throws {
    let sbd = try Instance.remote()
    let s = try sbd.startOnHost(prompt: "hello")
    try sbd.waitFor(s.id, "the first reply") { $0.lastReply == "Done: hello" }

    try sbd.sb("send", s.id, "second message")
    let done = try sbd.waitFor(s.id, "the reply to the sent message", timeout: 30) {
      $0.lastReply == "Done: second message"
    }

    #expect(done.host == "mini")
    #expect(try sbd.events(s.id, "sent", text: "second message").count == 1)
    try sbd.waitFor("delivered") { try sbd.events(s.id, "delivered", text: "second message").count == 1 }
    #expect(sbd.boxStubInput().contains { $0.contains("second message") })
    #expect(!sbd.stubInput().contains { $0.contains("second message") }, "the paste reached a pane on this Mac")
    #expect(sbd.boxStubArgs().count == 1, "the send started another claude: \(sbd.boxStubArgs())")
  }

  @Test func messagesSentDuringATurnQueueAndReachTheRemoteSessionInOrder() throws {
    let sbd = try Instance.remote()
    let s = try sbd.startOnHost(prompt: "slow 4")
    try sbd.waitFor(s.id, "the turn") { $0.state == .working }

    let first = try sbd.sb("send", s.id, "queued one")
    let second = try sbd.sb("send", s.id, "queued two")
    try sbd.waitFor(s.id, "the reply to the last queued message", timeout: 60) { $0.lastReply == "Done: queued two" }

    #expect(first == "queued\n")
    #expect(second == "queued\n")
    let prompts = try sbd.events(s.id).filter { $0.kind == "UserPromptSubmit" }.compactMap { $0.data["prompt"]?.string }
    #expect(prompts == ["slow 4", "queued one", "queued two"], "\(prompts)")
    for text in ["queued one", "queued two"] {
      try sbd.waitFor("delivered for \(text)") { try sbd.events(s.id, "delivered", text: text).count == 1 }
    }
    #expect(sbd.boxStubArgs().count == 1, "\(sbd.boxStubArgs())")
  }

  @Test func sendToAStoppedRemoteSessionResumesItsClaudeWithTheMessage() throws {
    let sbd = try Instance.remote()
    let s = try sbd.startOnHost(prompt: "hello")
    try sbd.waitFor(s.id, "the first reply") { $0.lastReply == "Done: hello" }
    try sbd.sb("stop", s.id)
    try sbd.waitFor(s.id, "claude to stop on the box") { $0.claudePid == nil }

    try sbd.sb("send", s.id, "wake up")
    try sbd.waitFor(s.id, "the reply after the resume", timeout: 30) { $0.lastReply == "Done: wake up" }

    let args = sbd.boxStubArgs()
    try #require(args.count == 2, "\(args)")
    #expect(args[1].hasPrefix("--resume \(s.claudeSessionId)"), "\(args[1])")
    #expect(args[1].hasSuffix("-- wake up"), "\(args[1])")
    #expect(sbd.stubArgs().isEmpty, "a claude ran on this Mac: \(sbd.stubArgs())")
  }

  // MARK: At most once

  @Test func theSameEventIdSentTwiceRecordsOneEvent() throws {
    let sbd = try Instance.remote()
    let s = try sbd.startOnHost()
    let (marker, changed) = ("dup-\(UUID().uuidString)", "dup-changed-\(UUID().uuidString)")
    let id = Instance.eventId(ns: Instance.clockNs())

    try sbd.sendProbe(marker, session: s.id, id: id)
    try sbd.waitFor("the first copy") { try sbd.probes(marker).count == 1 }
    try sbd.sendProbe(marker, session: s.id, id: id)
    // The same id with another payload is the same event.
    try sbd.sendProbe(changed, session: s.id, id: id)
    _ = try sbd.settledEvents()

    #expect(try sbd.probes(marker).count == 1)
    #expect(try sbd.probes(changed).isEmpty)
  }

  /// Both copies wait in the order window at once.
  @Test func twoCopiesOfAnEventThatArriveTogetherRecordOneEvent() throws {
    let sbd = try Instance.remote()
    let s = try sbd.startOnHost()
    let marker = "dup-together-\(UUID().uuidString)"
    let line = probeLine(marker, session: s.id, id: Instance.eventId(ns: Instance.clockNs()))

    let copies = try (0..<4).map { _ in try HeldLine(line, to: sbd.hostSocket()) }
    try sbd.waitFor("a copy") { try sbd.probes(marker).count >= 1 }
    _ = try sbd.settledEvents()

    #expect(try sbd.probes(marker).count == 1)
    copies.forEach { $0.close() }
  }

  @Test func anEventIdThatSbdRecordedBeforeItRestartedIsNotRecordedAgain() throws {
    let sbd = try Instance.remote()
    let s = try sbd.startOnHost()
    let marker = "dup-restart-\(UUID().uuidString)"
    let id = Instance.eventId(ns: Instance.clockNs())
    try sbd.sendProbe(marker, session: s.id, id: id)
    try sbd.waitFor("the first copy") { try sbd.probes(marker).count == 1 }

    sbd.stopSbd()
    try sbd.startSbd()
    try sbd.waitForLink("mini", .connected)
    try sbd.sendProbe(marker, session: s.id, id: id)
    let fresh = "after-restart-\(UUID().uuidString)"
    try sbd.sendProbe(fresh, session: s.id)
    try sbd.waitFor("a new event after the restart") { try sbd.probes(fresh).count == 1 }
    _ = try sbd.settledEvents()

    #expect(try sbd.probes(marker).count == 1)
  }

  @Test func twoEventsWithDifferentIdsAreBothRecorded() throws {
    let sbd = try Instance.remote()
    let s = try sbd.startOnHost()
    let marker = "two-\(UUID().uuidString)"
    let ns = Instance.clockNs()

    // The ids differ only in their last part.
    try sbd.sendProbe(marker, session: s.id, id: Instance.eventId(ns: ns, pid: 7, suffix: "00aa"))
    try sbd.sendProbe(marker, session: s.id, id: Instance.eventId(ns: ns, pid: 7, suffix: "00ab"))

    try sbd.waitFor("both events") { try sbd.probes(marker).count == 2 }
  }

  // MARK: Order

  @Test func twoEventsSentInReverseIdOrder50MsApartAreRecordedInIdOrder() throws {
    let sbd = try Instance.remote()
    let s = try sbd.startOnHost()
    let ns = Instance.clockNs()
    let (early, late) = ("order-early-\(UUID().uuidString)", "order-late-\(UUID().uuidString)")

    let b = try HeldLine(
      probeLine(late, session: s.id, id: Instance.eventId(ns: ns + 10_000_000)), to: sbd.hostSocket())
    usleep(50_000)
    let a = try HeldLine(probeLine(early, session: s.id, id: Instance.eventId(ns: ns)), to: sbd.hostSocket())
    try sbd.waitFor("both events") { try order(sbd, [early, late]).count == 2 }

    #expect(try order(sbd, [early, late]) == [early, late])
    let times = try [early, late].map { try #require(try sbd.probes($0).first?.t) }
    #expect(times[0] <= times[1], "the event times run backwards: \(times)")
    [a, b].forEach { $0.close() }
  }

  @Test func threeEventsThatArriveOutOfOrderWithinTheWindowAreRecordedInIdOrder() throws {
    let sbd = try Instance.remote()
    let s = try sbd.startOnHost()
    let ns = Instance.clockNs()
    let markers = (1...3).map { "order-\($0)-\(UUID().uuidString)" }
    let ids = (0..<3).map { Instance.eventId(ns: ns + UInt64($0) * 1_000_000) }

    var held: [HeldLine] = []
    for index in [2, 0, 1] {
      held.append(try HeldLine(probeLine(markers[index], session: s.id, id: ids[index]), to: sbd.hostSocket()))
      usleep(20_000)
    }
    try sbd.waitFor("the three events") { try order(sbd, markers).count == 3 }

    #expect(try order(sbd, markers) == markers)
    held.forEach { $0.close() }
  }

  /// An event that arrives after sbd applied a later one is late. sbd still records it.
  @Test func anEventThatArrivesAfterTheWindowOfALaterOneIsStillRecorded() throws {
    let sbd = try Instance.remote()
    let s = try sbd.startOnHost()
    let ns = Instance.clockNs()
    let (early, late) = ("late-early-\(UUID().uuidString)", "late-late-\(UUID().uuidString)")
    let earlyId = Instance.eventId(ns: ns)

    try sbd.sendProbe(late, session: s.id, id: Instance.eventId(ns: ns + 10_000_000))
    try sbd.waitFor("the later event") { try sbd.probes(late).count == 1 }
    usleep(300_000)
    try sbd.sendProbe(early, session: s.id, id: earlyId)
    try sbd.waitFor("the earlier event") { try sbd.probes(early).count == 1 }

    #expect(try order(sbd, [early, late]) == [late, early])
    let log = try String(contentsOfFile: sbd.home.log, encoding: .utf8)
    #expect(
      log.split(separator: "\n").contains { $0.contains(earlyId) && $0.contains("late") },
      "sbd's log names no late event \(earlyId)")
  }

  /// A PermissionRequest needs an answer, so sbd applies it at once, after the events that wait before it.
  @Test func anEventThatNeedsAnAnswerIsRecordedAfterTheEarlierEventsThatWaited() throws {
    let sbd = try Instance.remote()
    let s = try sbd.startOnHost()
    let ns = Instance.clockNs()
    let (waited, asked) = ("flush-waited-\(UUID().uuidString)", "flush-asked-\(UUID().uuidString)")

    let first = try HeldLine(probeLine(waited, session: s.id, id: Instance.eventId(ns: ns)), to: sbd.hostSocket())
    // Each line has a connection of its own, and sbd serves them on two threads. sbd answers the first once
    // it holds the event, so the request can't overtake it.
    try #require(first.wait(10) != nil, "sbd did not answer the event that waits")
    let request = try HeldLine(
      probeLine(asked, session: s.id, id: Instance.eventId(ns: ns + 5_000_000), kind: "PermissionRequest"),
      to: sbd.hostSocket())
    try sbd.waitFor(s.id, "the card of the request") { !$0.cards.isEmpty }

    // The card shows as soon as its event is recorded, and the earlier event is in the log by then.
    #expect(try order(sbd, [waited, asked]) == [waited, asked])
    #expect(!request.answered)
    [first, request].forEach { $0.close() }
  }

  @Test func anEarlierEventThatArrivesAfterOneThatNeededAnAnswerIsStillRecorded() throws {
    let sbd = try Instance.remote()
    let s = try sbd.startOnHost()
    let ns = Instance.clockNs()
    let (asked, earlier) = ("answer-first-\(UUID().uuidString)", "answer-then-\(UUID().uuidString)")

    let request = try HeldLine(
      probeLine(asked, session: s.id, id: Instance.eventId(ns: ns + 5_000_000), kind: "PermissionRequest"),
      to: sbd.hostSocket())
    try sbd.waitFor(s.id, "the card of the request") { !$0.cards.isEmpty }
    try sbd.sendProbe(earlier, session: s.id, id: Instance.eventId(ns: ns))
    try sbd.waitFor("the earlier event") { try sbd.probes(earlier).count == 1 }

    #expect(try order(sbd, [asked, earlier]) == [asked, earlier])
    request.close()
  }

  /// sbd holds a PermissionRequest that arrives on a host's socket, and answers it when its card is answered.
  @Test func aPermissionRequestOnAHostsSocketGetsItsCardsAnswer() throws {
    let sbd = try Instance.remote()
    let s = try sbd.startOnHost()
    let marker = "held-\(UUID().uuidString)"
    let request = try HeldLine(
      probeLine(marker, session: s.id, id: Instance.eventId(ns: Instance.clockNs()), kind: "PermissionRequest"),
      to: sbd.hostSocket())
    let asked = try sbd.waitFor(s.id, "the card of the request") { !$0.cards.isEmpty }
    try #require(!request.answered)

    let answer = try JSON.parse(sbd.sb("allow", "--json", s.id))

    #expect(asked.cards.first?.input == ["command": .string("touch \(marker)")])
    #expect(answer?["delivery"]?.string == "hook")
    let reply = try #require(request.wait(10), "sbd sent no answer to the held request")
    #expect(reply["ok"] == true, "\(reply.text)")
    #expect(reply["result"]?["hookSpecificOutput"]?["decision"]?["behavior"] == "allow", "\(reply.text)")
  }

  // MARK: Event time

  /// A remote event's time is its id's clock, no lower than the session's last event and no higher than now.
  @Test(arguments: [-3_600, 3_600])
  func theTimeOfARemoteEventStaysBetweenTheSessionsLastEventAndNow(secondsOff: Int) throws {
    let sbd = try Instance.remote()
    let s = try sbd.startOnHost()
    let before = try #require(try sbd.events(s.id).last)
    let marker = "time-\(UUID().uuidString)"
    let ns = UInt64(Int64(Instance.clockNs()) + Int64(secondsOff) * 1_000_000_000)

    try sbd.sendProbe(marker, session: s.id, id: Instance.eventId(ns: ns))
    try sbd.waitFor("the event") { try sbd.probes(marker).count == 1 }

    let event = try #require(try sbd.probes(marker).first)
    #expect(event.t >= before.t, "the event is \(before.t - event.t) ms before the session's last event")
    #expect(event.t <= (try sbd.now()), "the event is in the future")
  }

  @Test func theTimeOfARemoteEventIsTheTimeOfItsIdAndNotOfItsArrival() throws {
    let sbd = try Instance.remote()
    let s = try sbd.startOnHost()
    _ = try sbd.settledEvents()
    let marker = "time-id-\(UUID().uuidString)"
    let at = try sbd.now()
    let id = Instance.eventId(ns: Instance.clockNs())
    sleep(3)

    try sbd.sendProbe(marker, session: s.id, id: id)
    try sbd.waitFor("the event") { try sbd.probes(marker).count == 1 }

    let event = try #require(try sbd.probes(marker).first)
    #expect(abs(event.t - at) < 1_500, "the event's time is \(event.t - at) ms from its id's clock")
  }

  // MARK: The link is down

  @Test(arguments: ["Notification", "PermissionRequest"])
  func withTheLinkDownTheShimExitsZeroWithin3SecondsAndSpoolsItsEvent(kind: String) throws {
    let sbd = try Instance.remote()
    let s = try sbd.startOnHost()
    try sbd.dropLinkAndRefuse(refusal)
    let marker = "spooled-\(UUID().uuidString)"
    let linesBefore = sbd.boxSpoolLines().count

    let run = try runBoxShim(sbd, session: s.id, payload: Instance.probePayload(marker, kind: kind))

    #expect(run.status == 0)
    #expect(run.seconds < 3, "the shim took \(run.seconds) s")
    #expect(run.stdout.isEmpty, "\(run.stdout)")
    let lines = sbd.boxSpoolLines()
    #expect(lines.count == linesBefore + 1)
    let line = try #require(lines.last)
    #expect(line["payload"]?["probe"]?.string == marker, "\(line.text)")
    #expect(line["session"]?.string == s.id)
    #expect(line["v"] == 1)
    #expect(isEventId(line["id"]?.string ?? ""), "\(line.text)")
    #expect(try sbd.probes(marker).isEmpty, "sbd recorded an event that could not reach it")
  }

  @Test func theBoxesShimDeliversAHookWhileTheLinkIsUp() throws {
    let sbd = try Instance.remote()
    let s = try sbd.startOnHost()
    let marker = "shim-\(UUID().uuidString)"

    let run = try runBoxShim(sbd, session: s.id, payload: Instance.probePayload(marker))

    #expect(run.status == 0)
    #expect(run.stdout.isEmpty, "\(run.stdout)")
    try sbd.waitFor("the shim's event") { try sbd.probes(marker).count == 1 }
    let spooled = sbd.boxSpoolLines().filter { $0["payload"]?["probe"]?.string == marker }
    #expect(spooled.count == 1)
    _ = try sbd.settledEvents()
    #expect(try sbd.probes(marker).count == 1)
  }

  /// The dropped forward leaves its socket file on the box. Setup on the next connection replaces it.
  @Test func hooksReachSbdAgainAfterTheLinkReconnects() throws {
    let sbd = try Instance.remote()
    let s = try sbd.startOnHost(prompt: "hello")
    try sbd.waitFor(s.id, "the first reply") { $0.lastReply == "Done: hello" }

    let first = try sbd.dropLink("mini")
    try sbd.waitFor("a new master") { try sbd.sshStubPid(Instance.boxDestination).map { $0 != first } ?? false }
    try sbd.waitForLink("mini", .connected)
    try sbd.waitFor(s.id, "the claude pid after the reconnect") { $0.claudePid != nil }
    try sbd.sb("send", s.id, "after the drop")
    try sbd.waitFor(s.id, "the reply after the reconnect", timeout: 30) { $0.lastReply == "Done: after the drop" }

    #expect(sbd.sshStubForwards().count == 2, "\(sbd.sshStubForwards())")
    #expect(kind(of: sbd.boxSocket) == "socket")
    #expect(sbd.boxStubArgs().count == 1, "\(sbd.boxStubArgs())")
  }

  // MARK: The forward fails

  @Test func aForwardThatTheHostRefusesFailsTheNewSessionWithTheHostsText() throws {
    let sbd = try Instance.remote()
    try sbd.makeBoxFolder()
    try sbd.setSSHStub("refuse-forward", forwardRefusal + "\n")

    let r = try sbd.run("new", "~/sb-box-repo", "--host", "mini", "--json")

    #expect(r.status == 1)
    #expect(r.stderr.contains(forwardRefusal), "\(r.stderr)")
    #expect(try sbd.client.sessions().isEmpty)
    #expect(try sbd.boxTmuxSessions().isEmpty)
    #expect(sbd.boxStubArgs().isEmpty)
    #expect(sbd.stubArgs().isEmpty)
    #expect(kind(of: sbd.boxSocket) == nil)
  }

  @Test func aForwardThatTheHostRefusesShowsTheHostsTextInTheHostListWithTheLinkConnected() throws {
    let sbd = try Instance.remote()
    try sbd.makeBoxFolder()
    try sbd.setSSHStub("refuse-forward", forwardRefusal + "\n")
    _ = try sbd.run("new", "~/sb-box-repo", "--host", "mini", "--json")

    let rows = try #require(JSON.parse(try sbd.sb("host", "ls", "--json"))?.array)

    let mini = try #require(rows.first { $0["name"] == "mini" })
    #expect(mini["link"] == "connected")
    #expect(mini["error"]?.string?.contains(forwardRefusal) == true, "\(mini.text)")
  }

  @Test func aSessionStartsOnceTheHostTakesTheForward() throws {
    let sbd = try Instance.remote()
    try sbd.makeBoxFolder()
    try sbd.setSSHStub("refuse-forward", forwardRefusal + "\n")
    let refused = try sbd.run("new", "~/sb-box-repo", "--host", "mini", "--json")

    try sbd.clearSSHStub("refuse-forward")
    let s = try sbd.startOnHost()

    #expect(refused.status == 1)
    #expect(try sbd.get(s.id).live)
    let mini = try #require(try sbd.hosts().first { $0.name == "mini" })
    #expect(mini.error == nil, "\(mini.error ?? "")")
  }

  @Test func setupReplacesASocketFileThatAnEarlierForwardLeftOnTheBox() throws {
    let sbd = try Instance.remote()
    try makeStaleSocket(sbd.boxSocket)

    let s = try sbd.startOnHost()

    #expect(try sbd.get(s.id).live)
    #expect(kind(of: sbd.boxSocket) == "socket")
  }

  /// Setup removes the path on the box only when it is a socket.
  @Test(arguments: ["file", "folder", "symlink"])
  func setupRefusesWhenThePathOfTheBoxesSocketIsNotASocket(what: String) throws {
    let sbd = try Instance.remote()
    try sbd.makeBoxFolder()
    try FileManager.default.createDirectory(atPath: sbd.boxSB, withIntermediateDirectories: true)
    let target = "\(sbd.home.path)/keep-me"
    try "mine".write(toFile: target, atomically: true, encoding: .utf8)
    switch what {
    case "file": try "mine".write(toFile: sbd.boxSocket, atomically: true, encoding: .utf8)
    case "folder":
      try FileManager.default.createDirectory(atPath: "\(sbd.boxSocket)/inner", withIntermediateDirectories: true)
    default: try FileManager.default.createSymbolicLink(atPath: sbd.boxSocket, withDestinationPath: target)
    }

    let r = try sbd.run("new", "~/sb-box-repo", "--host", "mini", "--json")

    #expect(r.status == 1)
    #expect(r.stderr.contains("sbd.sock"), "\(r.stderr)")
    #expect(kind(of: sbd.boxSocket) == what)
    #expect(try String(contentsOfFile: target, encoding: .utf8) == "mine")
    #expect(sbd.sshStubForwards().isEmpty, "sbd asked for a forward over a path that it refused to remove")
    #expect(try sbd.client.sessions().isEmpty)
    #expect(sbd.boxStubArgs().isEmpty)
    let mini = try #require(try sbd.hosts().first { $0.name == "mini" })
    #expect(mini.link == .connected)
    #expect(mini.error?.contains("sbd.sock") == true, "\(mini.error ?? "no error")")
  }

  // MARK: The fixtures

  /// Starts a master of the ssh stub for the destination in the home, which runs `sleep`, and returns its pid.
  private func startStubMaster(_ sbd: Instance, _ destination: String) throws -> pid_t {
    try FileManager.default.createDirectory(atPath: sbd.home.sshFolder, withIntermediateDirectories: true)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: Instance.sshStub)
    p.arguments = ["-M", "-T", "-o", "ControlPath=\(sbd.home.sshFolder)/%C", "--", destination, "exec sleep 600"]
    p.standardInput = FileHandle.nullDevice
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try p.run()
    return try sbd.waitFor("the stub's master", fetch: { try sbd.sshStubPid(destination) }, until: { _ in true })
  }

  private func stubForward(_ sbd: Instance, _ destination: String, remote: String, local: String) throws
    -> CommandResult
  {
    try runCommand(
      Instance.sshStub,
      ["-O", "forward", "-R", "\(remote):\(local)", "-o", "ControlPath=\(sbd.home.sshFolder)/%C", "--", destination])
  }

  /// The pid of the relay that the stub's last `-O forward` for the destination started.
  private func relayPid(_ sbd: Instance, _ destination: String) throws -> pid_t? {
    let r = try runCommand(
      Instance.sshStub, ["-G", "-o", "ControlPath=\(sbd.home.sshFolder)/%C", "--", destination])
    let line = try #require(r.stdout.split(separator: "\n").first { $0.hasPrefix("controlpath ") })
    return sbd.stubPid("ssh-stub/\((String(line) as NSString).lastPathComponent).forward.pid")
  }

  @Test func theStubsForwardCopiesBothWaysAndPassesOnTheEndOfTheClientsData() throws {
    let sbd = try Instance()
    let (remote, local) = ("\(sbd.home.path)/far.sock", "\(sbd.home.path)/near.sock")
    let listener = try UnixSocket.listen(path: local)
    defer { close(listener) }
    _ = try startStubMaster(sbd, "t@fixture")

    let forward = try stubForward(sbd, "t@fixture", remote: remote, local: local)
    try #require(forward.status == 0, "\(forward.stderr)")
    let client = try UnixSocket.connect(path: remote, timeout: 5)
    defer { close(client) }
    try UnixSocket.write(client, Data("ping\n".utf8))
    let server = try acceptOne(listener)
    defer { close(server) }
    var fromClient = UnixSocket.LineReader(fd: server)
    let request = try fromClient.next()
    try UnixSocket.write(server, Data("pong\n".utf8))
    var fromServer = UnixSocket.LineReader(fd: client)
    let answer = try fromServer.next()
    shutdown(client, SHUT_WR)
    let end = try fromClient.next()

    #expect(request == Data("ping".utf8))
    #expect(answer == Data("pong".utf8))
    #expect(end == nil, "the listener did not see the end of the client's data")
    #expect(forward.stdout.isEmpty && forward.stderr.isEmpty)
  }

  @Test func theStubsRelayEndsWithItsMasterAndLeavesItsSocketFile() throws {
    let sbd = try Instance()
    let (remote, local) = ("\(sbd.home.path)/far.sock", "\(sbd.home.path)/near.sock")
    let listener = try UnixSocket.listen(path: local)
    defer { close(listener) }
    let master = try startStubMaster(sbd, "t@fixture")
    try #require(try stubForward(sbd, "t@fixture", remote: remote, local: local).status == 0)
    let relay = try #require(try relayPid(sbd, "t@fixture"))
    try #require(sbd.runs(Int(relay)))

    kill(master, SIGKILL)
    try sbd.waitFor("the relay to end", timeout: 2) { !sbd.runs(Int(relay)) }

    #expect(kind(of: remote) == "socket")
    #expect(throws: (any Error).self) { try UnixSocket.connect(path: remote, timeout: 1) }
  }

  @Test func theStubRefusesAForwardWithItsFilesTextOrWithoutAMasterOrOverAPathThatExists() throws {
    let sbd = try Instance()
    let (remote, local) = ("\(sbd.home.path)/far.sock", "\(sbd.home.path)/near.sock")
    let listener = try UnixSocket.listen(path: local)
    defer { close(listener) }

    let noMaster = try stubForward(sbd, "t@fixture", remote: remote, local: local)
    _ = try startStubMaster(sbd, "t@fixture")
    try sbd.setSSHStub("refuse-forward", forwardRefusal + "\n")
    let refused = try stubForward(sbd, "t@fixture", remote: remote, local: local)
    let leftByRefusal = kind(of: remote)
    try sbd.clearSSHStub("refuse-forward")
    try makeStaleSocket(remote)
    let taken = try stubForward(sbd, "t@fixture", remote: remote, local: local)

    #expect(noMaster.status == 255)
    #expect(refused.status == 255)
    #expect(refused.stderr == forwardRefusal + "\n")
    #expect(leftByRefusal == nil)
    #expect(taken.status == 255)
    #expect(taken.stderr.contains("remote port forwarding failed for listen path \(remote)"), "\(taken.stderr)")
    #expect(try relayPid(sbd, "t@fixture") == nil)
  }
}
