import Foundation
import SwitchboardCore
import Testing

/// A queue folder for bin/lib/build-slot and a work folder for one test, and
/// the processes that the test starts. Each command that a helper runs logs
/// "start <id> <pid>" and then waits until the test creates go.<id>. It then
/// logs "end <id>" and exits. The log's order is the order the commands ran.
final class SlotQueue {
  static let helper = Instance.root.appendingPathComponent("bin/lib/build-slot").path

  let root: String
  /// The queue folder. Its name has a space in it.
  let dir: String
  let log: String
  private var processes: [(id: String, process: Process)] = []
  /// Processes that no Process object owns, such as a daemon that a command
  /// starts, with a word that their command line must contain.
  private var strays: [(pid: pid_t, command: String)] = []

  init() throws {
    var template = Array("/tmp/sbq.XXXXXX".utf8CString)
    guard let made = mkdtemp(&template) else { throw TestError(description: "mkdtemp failed") }
    root = String(cString: made)
    dir = "\(root)/build slots"
    log = "\(root)/log"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: log, contents: nil)
  }

  deinit {
    stop()
    try? FileManager.default.removeItem(atPath: root)
  }

  static func waiting(_ ahead: Int) -> String { "build-slot: waiting for a build slot (\(ahead) ahead)" }
  static let gotSlot = "build-slot: got a build slot after "

  /// The test process's environment with the queue's settings. It removes
  /// SB_BUILD_SLOT_HELD, because bin/test sets it to its own live ticket, and
  /// every helper would then skip the queue. A nil value in `extra` removes
  /// that variable.
  func environment(slots: String = "1", _ extra: [String: String?] = [:]) -> [String: String] {
    var env = ProcessInfo.processInfo.environment
    env["SB_BUILD_SLOT_HELD"] = nil
    env["SB_BUILD_JOBS"] = nil
    env["SB_BUILD_SLOTS"] = slots
    env["SB_BUILD_SLOTS_DIR"] = dir
    env["SB_BUILD_SLOT_POLL"] = "0.05"
    for (key, value) in extra { env[key] = value }
    return env
  }

  /// The command that logs its start, writes its SB_BUILD_SLOT_HELD to
  /// held.<id>, and waits for go.<id>. `before` runs first.
  func command(_ id: String, before: String = "") -> [String] {
    let script = """
      \(before)
      printf '%s' "${SB_BUILD_SLOT_HELD-}" > "$2/held.$1"
      echo "start $1 $$" >> "$2/log"
      while [ ! -e "$2/go.$1" ]; do sleep 0.05; done
      echo "end $1" >> "$2/log"
      """
    return ["/bin/sh", "-c", script, "sh", id, root]
  }

  /// Starts a helper that runs `command`, or the waiting command for `id`.
  @discardableResult
  func start(
    _ id: String, slots: String = "1", env extra: [String: String?] = [:], command: [String]? = nil
  ) throws -> Process {
    try launch(id, Self.helper, ["--"] + (command ?? self.command(id)), env: environment(slots: slots, extra))
  }

  /// Starts a program without waiting for it. Its stdout and stderr go to
  /// files, not pipes, so a daemon that keeps them open can't stall a read.
  @discardableResult
  func launch(_ id: String, _ executable: String, _ arguments: [String], env: [String: String]) throws -> Process {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: executable)
    p.arguments = arguments
    p.environment = env
    p.currentDirectoryURL = URL(fileURLWithPath: root)
    p.standardInput = FileHandle.nullDevice
    FileManager.default.createFile(atPath: errPath(id), contents: nil)
    FileManager.default.createFile(atPath: outPath(id), contents: nil)
    p.standardError = try FileHandle(forWritingTo: URL(fileURLWithPath: errPath(id)))
    p.standardOutput = try FileHandle(forWritingTo: URL(fileURLWithPath: outPath(id)))
    processes.append((id, p))
    try p.run()
    return p
  }

  func track(_ pid: pid_t, command: String) { strays.append((pid, command)) }

  func release(_ id: String) { FileManager.default.createFile(atPath: "\(root)/go.\(id)", contents: nil) }

  /// Starts the first helper, which takes a free slot, and waits until its command runs.
  @discardableResult
  func startHolder(_ id: String, command: [String]? = nil) throws -> Process {
    let p = try start(id, command: command)
    try waitFor("\(id) to start") { starts().count == 1 }
    return p
  }

  /// Waits until the helper for `id` prints that `ahead` commands are ahead of it.
  func waitUntilWaiting(_ id: String, ahead: Int) throws {
    try waitFor("\(id) to wait with \(ahead) ahead") { stderr(id).contains(Self.waiting(ahead)) }
  }

  /// Runs the helper with the queue's environment and waits for it.
  func runHelper(_ arguments: [String], slots: String = "1", env extra: [String: String?] = [:]) throws
    -> CommandResult
  {
    try runCommand(Self.helper, arguments, env: environment(slots: slots, extra), timeout: 60)
  }

  /// Lets every command finish, kills every helper, and kills each command
  /// and daemon that still runs. A pid counts only while its command line
  /// still names this test's folder or the daemon's command, so a reused pid
  /// is never killed.
  func stop() {
    for (id, _) in processes { release(id) }
    for (_, p) in processes where p.isRunning { kill(p.processIdentifier, SIGKILL) }
    for start in starts() { killIfRunning(start.pid, command: root) }
    for stray in strays { killIfRunning(stray.pid, command: stray.command) }
  }

  private func killIfRunning(_ pid: pid_t, command: String) {
    guard kill(pid, 0) == 0, let r = try? runCommand("/bin/ps", ["-ww", "-p", "\(pid)", "-o", "command="]),
      r.stdout.contains(command)
    else { return }
    kill(pid, SIGKILL)
  }

  func errPath(_ id: String) -> String { "\(root)/err.\(id)" }
  func outPath(_ id: String) -> String { "\(root)/out.\(id)" }

  func stderr(_ id: String) -> String { (try? String(contentsOfFile: errPath(id), encoding: .utf8)) ?? "" }

  func stderrLines(_ id: String) -> [String] { stderr(id).split(separator: "\n").map(String.init) }

  func logLines() -> [String] {
    ((try? String(contentsOfFile: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
  }

  /// Each command that started, in the order it started.
  func starts() -> [(id: String, pid: pid_t)] {
    logLines().compactMap { line in
      let words = line.split(separator: " ")
      guard words.count == 3, words[0] == "start", let pid = pid_t(words[2]) else { return nil }
      return (String(words[1]), pid)
    }
  }

  /// The most commands that the log shows running at the same time.
  func mostRunningAtOnce() -> Int {
    var running = 0
    var most = 0
    for line in logLines() {
      if line.hasPrefix("start ") { running += 1 } else if line.hasPrefix("end ") { running -= 1 }
      most = max(most, running)
    }
    return most
  }

  func tickets() -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".ticket") }.sorted()
  }

  /// The SB_BUILD_SLOT_HELD that the command for `id` got.
  func held(_ id: String) throws -> String {
    try String(contentsOfFile: "\(root)/held.\(id)", encoding: .utf8)
  }

  /// Writes a ticket that no process locks. Its record names pid 1, which
  /// always runs, so only the flock can show that the ticket is dead.
  func writeStaleTicket(_ path: String, seq: Int = 1) throws {
    let record = #"{"pid": 1, "seq": \#(seq), "session": null, "cwd": "/", "argv": ["true"], "started": 0}"#
    try FileManager.default.createDirectory(
      atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try record.write(toFile: path, atomically: false, encoding: .utf8)
  }

  /// Creates the file and holds an exclusive flock on it, as a live helper
  /// holds its ticket, until the caller closes the descriptor.
  func lock(_ path: String) throws -> Int32 {
    let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
    guard fd >= 0 else { throw TestError(description: "open \(path) failed: errno \(errno)") }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
      close(fd)
      throw TestError(description: "flock \(path) failed: errno \(errno)")
    }
    return fd
  }

  /// A wait that succeeds returns at once, so only a failing wait takes long.
  func waitFor(_ what: String, timeout: Double = 30, _ condition: () throws -> Bool) throws {
    let deadline = Date().addingTimeInterval(timeout * Instance.timeoutScale)
    while Date() < deadline {
      if try condition() { return }
      usleep(20_000)
    }
    throw TestError(description: "timed out waiting for \(what)\n\(diagnostics())")
  }

  func waitForExit(_ id: String) throws -> Process {
    guard let p = processes.last(where: { $0.id == id })?.process else {
      throw TestError(description: "no process named \(id)")
    }
    try waitFor("\(id) to exit") { !p.isRunning }
    p.waitUntilExit()
    return p
  }

  func diagnostics() -> String {
    var text = "log:\n\(logLines().joined(separator: "\n"))\nqueue folder: \(tickets())"
    for (id, _) in processes { text += "\nstderr of \(id):\n\(stderr(id))" }
    return text
  }
}

/// A value of SB_BUILD_SLOT_HELD that names no live ticket.
enum DeadHeld: String, CaseIterable, Sendable, CustomTestStringConvertible {
  case unset, empty, missingFile, unlockedTicket, nonTicketFile, directory

  var testDescription: String { rawValue }

  /// The value, after making any file it names. nil leaves the variable unset.
  func value(in queue: SlotQueue) throws -> String? {
    switch self {
    case .unset: return nil
    case .empty: return ""
    case .missingFile: return "\(queue.root)/gone/000000000001.ticket"
    case .unlockedTicket:
      // A folder of its own keeps the ticket out of the queue's scans, which would remove it.
      let path = "\(queue.root)/old slots/000000000001.ticket"
      try queue.writeStaleTicket(path)
      return path
    case .nonTicketFile:
      let path = "\(queue.root)/notes.txt"
      try "notes\n".write(toFile: path, atomically: false, encoding: .utf8)
      return path
    case .directory: return queue.dir
    }
  }
}

private struct StatusCase: Sendable, CustomTestStringConvertible {
  var name: String
  var arguments: [String]
  var status: Int32

  var testDescription: String { name }
}

private struct BadSetting: Sendable, CustomTestStringConvertible {
  var variable: String
  var value: String

  var testDescription: String { "\(variable)=\(value)" }
}

@Suite(.blocking(timeLimit: .seconds(120))) struct BuildSlotTests {
  /// -S leaves out site-packages, so an import outside the standard library
  /// fails. The python3 is the one that bin/lib/build-slot runs.
  @Test func theHelperRunsUnderTheToolchainsPythonWithOnlyTheStandardLibrary() throws {
    let q = try SlotQueue()
    defer { q.stop() }
    let python = try runCommand("/usr/bin/xcrun", ["--find", "python3"], timeout: 60)
    try #require(python.status == 0, "\(python.stderr)")
    let script = Instance.root.appendingPathComponent("bin/lib/build-slot.py").path

    let r = try runCommand(
      python.stdout.trimmingCharacters(in: .whitespacesAndNewlines), ["-I", "-S", script, "--", "/usr/bin/true"],
      env: q.environment(), timeout: 60)

    #expect(r.status == 0, "\(r.stderr)")
  }

  /// /usr/bin/python3 is an xcrun shim that adds these variables. An SDKROOT
  /// that names the Command Line Tools SDK breaks an Xcode swift.
  @Test func theCommandGetsTheCallersEnvironmentWithoutXcrunsAdditions() throws {
    let q = try SlotQueue()
    defer { q.stop() }
    let unset = ["SDKROOT": nil, "CPATH": nil, "LIBRARY_PATH": nil] as [String: String?]
    let script = #"printf '%s|%s|%s|%s' "${SDKROOT-unset}" "${CPATH-unset}" "${LIBRARY_PATH-unset}" "$KEEP""#

    let r = try q.runHelper(["--", "/bin/sh", "-c", script], env: unset.merging(["KEEP": "kept"]) { $1 })

    #expect(r.status == 0, "\(r.stderr)")
    #expect(r.stdout == "unset|unset|unset|kept")
  }

  /// Each waiter starts after the ticket before it appears, so the queue's
  /// order is A to E. Each waiter's waiting line shows that it scanned and
  /// chose to wait, so the count of starts after it is not a race.
  @Test func twoSlotsRunTwoCommandsAtOnceAndStartTheNextWaiterAsEachEnds() throws {
    let q = try SlotQueue()
    defer { q.stop() }
    let ids = ["A", "B", "C", "D", "E"]
    for (i, id) in ids.enumerated() {
      try q.start(id, slots: "2")
      try q.waitFor("\(id)'s ticket") { q.tickets().count == i + 1 }
    }
    try q.waitFor("A and B to start") { q.starts().count == 2 }
    for (ahead, id) in ids[2...].enumerated() {
      try q.waitUntilWaiting(id, ahead: ahead + 1)
    }
    #expect(q.starts().map(\.id) == ["A", "B"])

    for (i, finished) in ids.enumerated() {
      q.release(finished)
      let started = min(ids.count, i + 3)
      try q.waitFor("\(started) starts") { q.starts().count == started }
      for (ahead, id) in ids[started...].enumerated() {
        try q.waitUntilWaiting(id, ahead: ahead + 1)
      }
      #expect(q.starts().count == started)
    }

    for id in ids { #expect(try q.waitForExit(id).terminationStatus == 0) }
    #expect(q.starts().map(\.id) == ids)
    #expect(q.mostRunningAtOnce() == 2)
  }

  /// The test releases whichever command started last, so a wrong order
  /// shows in the log instead of hanging the test.
  @Test func oneSlotRunsWaitersInTheOrderTheyArrived() throws {
    let q = try SlotQueue()
    defer { q.stop() }
    let ids = ["A", "B", "C", "D"]
    for (i, id) in ids.enumerated() {
      try q.start(id)
      try q.waitFor("\(id)'s ticket") { q.tickets().count == i + 1 }
    }

    for i in ids.indices {
      try q.waitFor("start \(i + 1)") { q.starts().count == i + 1 }
      q.release(q.starts()[i].id)
    }

    for id in ids { #expect(try q.waitForExit(id).terminationStatus == 0) }
    #expect(q.starts().map(\.id) == ids)
    #expect(q.mostRunningAtOnce() == 1)
  }

  /// The kernel drops the helper's flock when it dies. The command it
  /// started keeps running, which is the gap the helper's header accepts.
  @Test func aSIGKILLedHolderFreesItsSlotWithinTwoSeconds() throws {
    let q = try SlotQueue()
    defer { q.stop() }
    let holder = try q.startHolder("A")
    let orphan = q.starts()[0].pid
    try q.start("B")
    try q.waitUntilWaiting("B", ahead: 1)

    let killed = ContinuousClock.now
    kill(holder.processIdentifier, SIGKILL)
    try q.waitFor("B to start") { q.starts().count == 2 }
    let waited = ContinuousClock.now - killed

    #expect(waited < .seconds(2 * Instance.timeoutScale))
    #expect(q.starts().map(\.id) == ["A", "B"])
    #expect(kill(orphan, 0) == 0, "A's command should still run")
    #expect(q.tickets().count == 1, "B's scan should remove A's dead ticket")
    kill(orphan, SIGKILL)
  }

  /// The daemon inherits every descriptor that the command's shell has.
  /// Its stdio goes to /dev/null, so only a leaked ticket descriptor could
  /// keep the slot. A helper that exits removes its ticket, so a leaked lock
  /// matters only after SIGKILL, which leaves the ticket in the folder.
  @Test func aDaemonThatTheCommandStartedDoesNotKeepAKilledHoldersSlot() throws {
    let q = try SlotQueue()
    defer { q.stop() }
    let daemon = #"sleep 60 </dev/null >/dev/null 2>&1 & echo $! > "$2/daemon.pid""#
    let holder = try q.startHolder("A", command: q.command("A", before: daemon))
    let pidText = try String(contentsOfFile: "\(q.root)/daemon.pid", encoding: .utf8)
    let sleeper = try #require(pid_t(pidText.trimmingCharacters(in: .whitespacesAndNewlines)))
    q.track(sleeper, command: "sleep 60")
    try q.start("B")
    try q.waitUntilWaiting("B", ahead: 1)

    kill(holder.processIdentifier, SIGKILL)
    try q.waitFor("B to start") { q.starts().count == 2 }

    #expect(kill(sleeper, 0) == 0, "the daemon should still run")
  }

  @Test(arguments: [SIGTERM, SIGINT, SIGHUP])
  func aSignalToAWaitingHelperRemovesItsTicketAndExits128PlusTheSignal(_ signal: Int32) throws {
    let q = try SlotQueue()
    defer { q.stop() }
    try q.startHolder("A")
    let waiter = try q.start("B")
    try q.waitUntilWaiting("B", ahead: 1)
    let holderTicket = try #require(q.tickets().first)

    kill(waiter.processIdentifier, signal)
    let exited = try q.waitForExit("B")

    #expect(exited.terminationReason == .exit)
    #expect(exited.terminationStatus == 128 + signal)
    #expect(q.tickets() == [holderTicket])
    #expect(q.starts().map(\.id) == ["A"])
  }

  /// The command exits 42 on the signal, which differs from the 128 +
  /// signal that the helper's own death or a default action would give.
  @Test(arguments: [SIGTERM, SIGINT, SIGHUP])
  func aSignalToAHoldingHelperReachesTheCommandAndTheHelperExitsWithItsStatus(_ signal: Int32) throws {
    let q = try SlotQueue()
    defer { q.stop() }
    let trap = #"trap 'echo "signal $1" >> "$2/log"; exit 42' TERM INT HUP"#
    let holder = try q.startHolder("A", command: q.command("A", before: trap))

    kill(holder.processIdentifier, signal)
    let exited = try q.waitForExit("A")

    #expect(exited.terminationReason == .exit)
    #expect(exited.terminationStatus == 42)
    #expect(q.logLines().contains("signal A"))
    #expect(q.tickets().isEmpty)
  }

  @Test(arguments: [
    StatusCase(name: "exit 7", arguments: ["--", "/bin/sh", "-c", "exit 7"], status: 7),
    StatusCase(name: "exit 7 without --", arguments: ["/bin/sh", "-c", "exit 7"], status: 7),
    StatusCase(name: "exit 0", arguments: ["--", "/usr/bin/true"], status: 0),
    StatusCase(name: "SIGTERM", arguments: ["--", "/bin/sh", "-c", "kill -TERM $$"], status: 143),
    StatusCase(name: "SIGKILL", arguments: ["--", "/bin/sh", "-c", "kill -KILL $$"], status: 137),
  ])
  fileprivate func theHelperExitsWithTheCommandsStatus(_ c: StatusCase) throws {
    let q = try SlotQueue()
    defer { q.stop() }

    let r = try q.runHelper(c.arguments)

    #expect(r.status == c.status, "\(r.stderr)")
  }

  @Test func aFreeSlotPrintsNothing() throws {
    let q = try SlotQueue()
    defer { q.stop() }

    let r = try q.runHelper(["--", "/usr/bin/true"])

    #expect(r.status == 0)
    #expect(r.stderr == "")
  }

  @Test func waitersPrintHowManyAreAheadAndWhenTheyGetTheSlot() throws {
    let q = try SlotQueue()
    defer { q.stop() }
    try q.startHolder("A")
    try q.start("B")
    try q.waitUntilWaiting("B", ahead: 1)
    try q.start("C")
    try q.waitUntilWaiting("C", ahead: 2)

    q.release("A")
    try q.waitFor("B to start") { q.starts().count == 2 }
    try q.waitUntilWaiting("C", ahead: 1)
    q.release("B")
    try q.waitFor("C to start") { q.starts().count == 3 }
    q.release("C")
    for id in ["A", "B", "C"] { _ = try q.waitForExit(id) }

    #expect(q.stderrLines("A") == [])
    let b = q.stderrLines("B")
    #expect(b.count == 2, "\(b)")
    #expect(b.first == SlotQueue.waiting(1))
    #expect(b.last?.hasPrefix(SlotQueue.gotSlot) == true, "\(b)")
    let c = q.stderrLines("C")
    #expect(c.count == 3, "\(c)")
    #expect(Array(c.prefix(2)) == [SlotQueue.waiting(2), SlotQueue.waiting(1)])
    #expect(c.last?.hasPrefix(SlotQueue.gotSlot) == true, "\(c)")
  }

  @Test func theCommandGetsItsTicketsPathInSBBuildSlotHeld() throws {
    let q = try SlotQueue()
    defer { q.stop() }
    try q.startHolder("A")

    let held = try q.held("A")

    let ticket = try #require(q.tickets().first)
    #expect(real(held) == real("\(q.dir)/\(ticket)"))
  }

  @Test func aHelperInsideALiveHeldSlotRunsAtOnceWithoutATicket() throws {
    let q = try SlotQueue()
    defer { q.stop() }
    try q.startHolder("A")
    let held = try q.held("A")

    try q.start("B", env: ["SB_BUILD_SLOT_HELD": held])
    try q.waitFor("B to start") { q.starts().count == 2 }

    #expect(q.tickets().count == 1)
    #expect(q.stderr("B") == "")
    #expect(!q.logLines().contains("end A"))
    q.release("B")
    #expect(try q.waitForExit("B").terminationStatus == 0)
  }

  @Test(arguments: DeadHeld.allCases)
  func aHelperQueuesWhenTheHeldSlotIsNotLive(_ shape: DeadHeld) throws {
    let q = try SlotQueue()
    defer { q.stop() }
    try q.startHolder("A")

    try q.start("B", env: ["SB_BUILD_SLOT_HELD": try shape.value(in: q)])
    try q.waitUntilWaiting("B", ahead: 1)

    #expect(q.starts().map(\.id) == ["A"])
    #expect(q.tickets().count == 2)
    q.release("A")
    try q.waitFor("B to start") { q.starts().count == 2 }
    q.release("B")
    #expect(try q.waitForExit("B").terminationStatus == 0)
  }

  @Test func checkExitsZeroWhenTheHeldTicketIsLive() throws {
    let q = try SlotQueue()
    defer { q.stop() }
    try q.startHolder("A")

    let r = try q.runHelper(["--check"], env: ["SB_BUILD_SLOT_HELD": try q.held("A")])

    #expect(r.status == 0, "\(r.stderr)")
  }

  /// A script runs itself under the helper when the check fails. With the
  /// queue off the helper sets no SB_BUILD_SLOT_HELD, so only this answer
  /// keeps the script from looping.
  @Test func checkExitsZeroWhenTheQueueIsOff() throws {
    let q = try SlotQueue()
    defer { q.stop() }

    let r = try q.runHelper(["--check"], slots: "0")

    #expect(r.status == 0, "\(r.stderr)")
  }

  /// A crash also exits nonzero, so the test checks that no traceback printed.
  @Test(arguments: DeadHeld.allCases)
  func checkExitsNonzeroWhenTheHeldTicketIsNotLive(_ shape: DeadHeld) throws {
    let q = try SlotQueue()
    defer { q.stop() }

    let r = try q.runHelper(["--check"], env: ["SB_BUILD_SLOT_HELD": try shape.value(in: q)])

    #expect(r.status != 0)
    #expect(!r.stderr.contains("Traceback"), "\(r.stderr)")
  }

  /// A helper that was killed while it enqueued leaves its tmp.<pid>.<seq> file.
  @Test func aStaleTicketAndATempFileDoNotBlockANewHelperAndAreRemoved() throws {
    let q = try SlotQueue()
    defer { q.stop() }
    let stale = "\(q.dir)/000000000001.ticket"
    let temp = "\(q.dir)/tmp.1.1"
    try q.writeStaleTicket(stale)
    try q.writeStaleTicket(temp)

    let r = try q.runHelper(["--", "/usr/bin/true"])

    #expect(r.status == 0, "\(r.stderr)")
    #expect(r.stderr == "")
    #expect(!FileManager.default.fileExists(atPath: stale))
    #expect(!FileManager.default.fileExists(atPath: temp))
  }

  /// The test process holds the flock, as a live helper would. Closing it
  /// makes the ticket dead, and the waiter's next scan removes it.
  @Test func aLockedTicketHoldsTheSlotAndIsKeptUntilItsLockDrops() throws {
    let q = try SlotQueue()
    defer { q.stop() }
    let ticket = "\(q.dir)/000000000001.ticket"
    let fd = try q.lock(ticket)
    var locked = true
    defer { if locked { close(fd) } }
    try q.start("B")
    try q.waitUntilWaiting("B", ahead: 1)

    #expect(FileManager.default.fileExists(atPath: ticket))
    close(fd)
    locked = false
    try q.waitFor("B to start") { q.starts().count == 1 }

    #expect(!FileManager.default.fileExists(atPath: ticket))
  }

  /// The first run writes the counter. The stale ticket's number is above it.
  @Test func aStaleTicketAboveTheCounterStillGetsALowerNumberThanTheNewHelper() throws {
    let q = try SlotQueue()
    defer { q.stop() }
    let first = try q.runHelper(["--", "/usr/bin/true"])
    try #require(first.status == 0, "\(first.stderr)")
    try q.writeStaleTicket("\(q.dir)/000000000050.ticket", seq: 50)

    try q.startHolder("A")

    let name = ((try q.held("A")) as NSString).lastPathComponent
    let seq = try #require(Int(name.prefix(while: \.isNumber)), "\(name)")
    #expect(seq > 50)
    #expect(name.hasSuffix(".ticket"))
  }

  /// The first helper's ticket is gone when the second one starts, so only
  /// the saved counter keeps the second from taking the same number.
  @Test func aTicketNumberIsNeverReused() throws {
    let q = try SlotQueue()
    defer { q.stop() }
    let first = try q.runHelper(["--", "/usr/bin/true"])
    try #require(first.status == 0, "\(first.stderr)")
    try #require(q.tickets().isEmpty)

    try q.startHolder("A")

    #expect(((try q.held("A")) as NSString).lastPathComponent == "000000000002.ticket")
  }

  /// A live ticket fills the only slot, so only a disabled queue runs the command.
  @Test func zeroSlotsRunTheCommandAtOnceWithoutATicket() throws {
    let q = try SlotQueue()
    defer { q.stop() }
    let fd = try q.lock("\(q.dir)/000000000001.ticket")
    defer { close(fd) }

    let r = try q.runHelper(["--", "/bin/ls", "-A", q.dir], slots: "0")

    #expect(r.status == 0, "\(r.stderr)")
    #expect(r.stderr == "")
    #expect(r.stdout.split(separator: "\n").filter { $0.hasSuffix(".ticket") } == ["000000000001.ticket"])
  }

  @Test(arguments: [
    BadSetting(variable: "SB_BUILD_SLOTS", value: "abc"),
    BadSetting(variable: "SB_BUILD_SLOTS", value: "-1"),
    BadSetting(variable: "SB_BUILD_SLOTS", value: "1.5"),
    BadSetting(variable: "SB_BUILD_SLOT_POLL", value: "0"),
    BadSetting(variable: "SB_BUILD_SLOT_POLL", value: "-1"),
    BadSetting(variable: "SB_BUILD_SLOT_POLL", value: "x"),
    BadSetting(variable: "SB_BUILD_SLOT_POLL", value: "inf"),
  ])
  fileprivate func aBadSettingExitsTwoWithoutRunningTheCommand(_ bad: BadSetting) throws {
    let q = try SlotQueue()
    defer { q.stop() }
    let marker = "\(q.root)/ran"

    let r = try q.runHelper(["--", "/usr/bin/touch", marker], env: [bad.variable: bad.value])

    #expect(r.status == 2)
    #expect(r.stderr.contains(bad.variable), "\(r.stderr)")
    #expect(!FileManager.default.fileExists(atPath: marker))
  }

  /// The default folder is under ~/Library/Caches, which may not exist yet.
  @Test func aMissingQueueFolderIsCreated() throws {
    let q = try SlotQueue()
    defer { q.stop() }
    let missing = "\(q.root)/new/build slots"

    let r = try q.runHelper(["--", "/usr/bin/true"], env: ["SB_BUILD_SLOTS_DIR": missing])

    #expect(r.status == 0, "\(r.stderr)")
  }
}
