import CryptoKit
import Foundation
import SwitchboardCore
import Testing

@testable import SwitchboardService

/// The clock of one test. A test moves it and passes the same time to `poll(now:)`.
final class LinkClock: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Int64 = 1_794_377_400_000

  var now: Int64 { lock.withLock { value } }

  func advance(_ ms: Int64) { lock.withLock { value += ms } }
}

/// One run of Fixtures/ssh-stub, from the stub's log.
struct StubRun {
  var pid: Int32
  var argv: [String]

  var isMaster: Bool { argv.contains("-M") }

  /// The values of the run's `-o K=V` options, by key.
  var options: [String: String] {
    var found: [String: String] = [:]
    for (flag, value) in zip(argv, argv.dropFirst()) where flag == "-o" {
      let parts = value.split(separator: "=", maxSplits: 1).map(String.init)
      if parts.count == 2 { found[parts[0]] = parts[1] }
    }
    return found
  }

  /// The words after `--`: the destination, then the remote command.
  var afterDashes: [String] { argv.firstIndex(of: "--").map { Array(argv[($0 + 1)...]) } ?? [] }
}

/// A command that runs on another thread, so that the test can end its link meanwhile.
final class Flight: @unchecked Sendable {
  private let lock = NSLock()
  private var outcome: Result<CommandResult, Error>?

  init(_ machine: SSHMachine, _ executable: String, _ args: [String]) {
    Thread.detachNewThread {
      let result = Result { try machine.run(executable, args) }
      self.lock.withLock { self.outcome = result }
    }
  }

  var result: Result<CommandResult, Error>? { lock.withLock { outcome } }

  /// The outcome, or nil when the command still runs after `seconds`.
  func wait(seconds: Double = 10) -> Result<CommandResult, Error>? {
    let deadline = Date().addingTimeInterval(seconds)
    while result == nil, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
    return result
  }
}

/// A `HostLink` whose ssh is Fixtures/ssh-stub, in a temporary home, with a clock that the test owns.
final class LinkBench {
  static let stub = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("IntegrationTests/Fixtures/ssh-stub").path
  static let destination = "haacked@mini.local"
  static let refusal = "ssh: connect to host mini.local port 22: Operation timed out"

  /// What a test's own ssh script may name.
  struct Layout {
    var home: String
    var stub: String
    var destination: String
    /// Where the stub puts the control socket for the destination.
    var controlPath: String
  }

  let home: Home
  let clock = LinkClock()
  let layout: Layout
  let link: HostLink
  private let root: String
  private var strays: [Int32] = []

  var stubFolder: String { "\(home.path)/ssh-stub" }
  var controlPath: String { layout.controlPath }

  /// The home is under /tmp, because a Unix socket path can't exceed 103 bytes. With `folder`,
  /// the home is the folder of that name in the temporary folder. With `ssh`, the link runs
  /// that `/bin/sh` script in place of the stub.
  init(folder: String? = nil, ssh script: ((Layout) throws -> String)? = nil) throws {
    let parsed = HostConfig.parse(["mini": ["kind": "ssh", "destination": .string(LinkBench.destination)]])
    let config = try #require(parsed.valid["mini"], "\(parsed.problems)")
    var template = Array("/tmp/sbl.XXXXXX".utf8CString)
    guard let dir = mkdtemp(&template) else { throw APIError("mkdtemp failed") }
    let root = String(cString: dir)
    self.root = root
    home = Home(path: folder.map { "\(root)/\($0)" } ?? root)
    let digest = Insecure.SHA1.hash(data: Data(LinkBench.destination.utf8)).map { String(format: "%02x", $0) }.joined()
    layout = Layout(
      home: home.path, stub: LinkBench.stub, destination: LinkBench.destination,
      controlPath: "\(home.path)/ssh/\(digest)")
    var ssh = LinkBench.stub
    do {
      try FileManager.default.createDirectory(atPath: "\(home.path)/ssh-stub/home", withIntermediateDirectories: true)
      if let script {
        ssh = "\(home.path)/ssh-wrapper"
        try Data(try script(layout).utf8).write(to: URL(fileURLWithPath: ssh))
        chmod(ssh, 0o755)
      }
    } catch {
      try? FileManager.default.removeItem(atPath: root)
      throw error
    }
    let clock = clock
    link = HostLink(config: config, destination: LinkBench.destination, ssh: ssh, home: home, now: { clock.now })
  }

  /// Ends the link and every process that the stub started, then removes the home.
  func close() {
    link.disconnect()
    for pid in runs().filter(\.isMaster).map(\.pid) + strays where !LinkBench.ended(pid) { kill(pid, SIGKILL) }
    try? FileManager.default.removeItem(atPath: root)
  }

  // MARK: The stub's files

  func set(_ file: String, _ text: String = "") throws {
    try Data(text.utf8).write(to: URL(fileURLWithPath: "\(stubFolder)/\(file)"))
  }

  func clear(_ file: String) throws {
    try FileManager.default.removeItem(atPath: "\(stubFolder)/\(file)")
  }

  var logText: String { (try? String(contentsOfFile: "\(stubFolder)/log", encoding: .utf8)) ?? "" }

  /// Every run of the stub, oldest first.
  func runs() -> [StubRun] {
    logText.split(separator: "\n").compactMap { line in
      guard let entry = JSON.parse(String(line)), let pid = entry["pid"]?.int, let argv = entry["argv"]?.array
      else { return nil }
      return StubRun(pid: Int32(pid), argv: argv.compactMap(\.string))
    }
  }

  /// Every run of the stub as a master, whether it got as far as the remote shell or not.
  func masters() -> [StubRun] { runs().filter(\.isMaster) }

  // MARK: Time

  /// Moves the test's clock and runs the link's tick at the new time.
  func tick(_ ms: Int64 = 0) {
    clock.advance(ms)
    link.poll(now: clock.now)
  }

  // MARK: Waiting

  func wait(_ what: String, seconds: Double = 15, until done: () -> Bool) throws {
    let deadline = Date().addingTimeInterval(seconds)
    while !done() {
      if Date() > deadline {
        throw APIError("timed out waiting for \(what). link: \(link.status)\nstub log:\n\(logText)")
      }
      Thread.sleep(forTimeInterval: 0.01)
    }
  }

  /// Waits for the link's status to match, and returns it.
  @discardableResult
  func waitForStatus(_ what: String, seconds: Double = 15, _ match: (HostLink.Status) -> Bool) throws
    -> HostLink.Status
  {
    var last = link.status
    try wait(what, seconds: seconds) {
      last = link.status
      return match(last)
    }
    return last
  }

  @discardableResult
  func waitFor(_ state: LinkState, failures: Int? = nil) throws -> HostLink.Status {
    try waitForStatus("the link to be \(state.rawValue)\(failures.map { " with \($0) failures" } ?? "")") {
      $0.state == state && (failures == nil || $0.failures == failures)
    }
  }

  func waitForMasters(_ count: Int) throws {
    try wait("\(count) runs of the stub as a master") { masters().count >= count }
  }

  /// Whether the process exited. A process that nothing has waited for yet counts.
  static func ended(_ pid: Int32) -> Bool {
    if kill(pid, 0) != 0 { return true }
    let state = (try? runCommand("/bin/ps", ["-o", "stat=", "-p", String(pid)]).stdout) ?? ""
    return state.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("Z")
  }

  func waitForExit(_ pid: Int32, seconds: Double = 10) throws {
    try wait("process \(pid) to exit", seconds: seconds) { LinkBench.ended(pid) }
  }

  // MARK: Steps that several tests share

  /// Connects and returns the master's run.
  @discardableResult
  func connect() throws -> StubRun {
    link.connect()
    try waitFor(.connected)
    return try #require(masters().last)
  }

  /// Fails `count` attempts in a row with the stub's `refuse` file, and leaves the file there.
  @discardableResult
  func fail(attempts count: Int) throws -> HostLink.Status {
    try set("refuse", LinkBench.refusal + "\n")
    link.connect()
    var status = try waitFor(.unreachable, failures: 1)
    for n in 1..<max(count, 1) {
      tick(retryDelayMs(failuresInARow: n))
      status = try waitFor(.unreachable, failures: n + 1)
    }
    return status
  }

  /// Kills the master as a dropped connection does, which leaves its socket file behind.
  func drop(_ master: StubRun) {
    kill(master.pid, SIGKILL)
  }

  /// Starts a command on the host that writes its pid to a file and then sleeps for 30 s.
  /// It returns once the command runs.
  func startSleeper() throws -> Flight {
    let marker = "\(home.path)/sleeper.pid"
    let flight = Flight(link.machine, "/bin/sh", ["-c", #"echo $$ >"$1"; exec sleep 30"#, "sb", marker])
    try wait("the command to start") {
      guard
        let pid = Int32((try? String(contentsOfFile: marker, encoding: .utf8))?.trimmingCharacters(in: .newlines) ?? "")
      else { return false }
      strays.append(pid)
      return true
    }
    return flight
  }
}

/// A Unix socket file at the path, bound and then closed, as a killed master leaves one.
func makeStaleSocket(at path: String) throws {
  close(try bindSocket(at: path))
}

/// A new socket bound to the path, which does not listen. The caller closes it.
func bindSocket(at path: String, type: Int32 = SOCK_STREAM) throws -> Int32 {
  let fd = socket(AF_UNIX, type, 0)
  guard fd >= 0 else { throw APIError("socket failed") }
  var addr = sockaddr_un()
  addr.sun_family = sa_family_t(AF_UNIX)
  let bytes = Array(path.utf8)
  let capacity = MemoryLayout.size(ofValue: addr.sun_path)
  guard bytes.count < capacity else { throw APIError("\(path) is too long for a socket") }
  withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
  let bound = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
  }
  guard bound == 0 else {
    let reason = String(cString: strerror(errno))
    close(fd)
    throw APIError("bind \(path): \(reason)")
  }
  return fd
}

/// A stream connect to the path that does not wait. It returns the descriptor, or nil with
/// `errno` set when the connect was refused.
func connectWithoutWaiting(to path: String) throws -> Int32? {
  let fd = socket(AF_UNIX, SOCK_STREAM, 0)
  guard fd >= 0 else { throw APIError("socket failed") }
  _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
  var code: Int32 = 0
  let result = try UnixSocket.withAddress(path) { address, length in
    let result = connect(fd, address, length)
    code = errno
    return result
  }
  if result == 0 { return fd }
  close(fd)
  errno = code
  return nil
}

/// A listener at the path whose accept queue is full, so that it refuses a stream connect as
/// a socket file with no listener does. The caller closes the descriptors.
func listenWithAFullQueue(at path: String) throws -> [Int32] {
  let listener = try bindSocket(at: path)
  var open = [listener]
  guard listen(listener, 1) == 0 else {
    close(listener)
    throw APIError("listen \(path): \(String(cString: strerror(errno)))")
  }
  for _ in 0..<8 {
    guard let fd = try connectWithoutWaiting(to: path) else { return open }
    open.append(fd)
  }
  open.forEach { close($0) }
  throw APIError("the accept queue of \(path) never filled")
}

func inode(of path: String) -> UInt64? {
  var info = stat()
  return lstat(path, &info) == 0 ? UInt64(info.st_ino) : nil
}

/// What `lstat` finds at the path: `socket`, `file`, `folder`, `symlink`, `other`, or nil for nothing.
func kindOfFile(at path: String) -> String? {
  var info = stat()
  guard lstat(path, &info) == 0 else { return nil }
  switch info.st_mode & S_IFMT {
  case S_IFSOCK: return "socket"
  case S_IFREG: return "file"
  case S_IFDIR: return "folder"
  case S_IFLNK: return "symlink"
  default: return "other"
  }
}

/// A `/bin/sh` script that stands in for ssh. It hands every run to the stub, except:
/// `onG` runs in place of a `-G` run, `beforeMaster` runs before a master starts, and a
/// master runs `command` on the host in place of the command that the link passed.
func sshWrapper(_ layout: LinkBench.Layout, onG: String? = nil, beforeMaster: String = "", command: String? = nil)
  -> String
{
  let replaceCommand = """
    seen=0
    i=0
    for a; do
      [ $i -eq 0 ] && set --
      i=$((i + 1))
      [ $seen -eq 2 ] && continue
      set -- "$@" "$a"
      if [ $seen -eq 1 ]; then seen=2; elif [ "$a" = -- ]; then seen=1; fi
    done
    exec "$stub" "$@" \(RemoteShellProtocol.quote(command ?? ""))
    """
  return """
    #!/bin/sh
    stub=\(RemoteShellProtocol.quote(layout.stub))
    case " $* " in
    *" -G "*)
      \(onG ?? #"exec "$stub" "$@""#)
      exit 0
      ;;
    *" -M "*) ;;
    *) exec "$stub" "$@" ;;
    esac
    \(beforeMaster)
    \(command == nil ? #"exec "$stub" "$@""# : replaceCommand)

    """
}

/// A folder in the home with a `stat` that runs the script. The host's shell finds it first on PATH.
private func hostCommand(withStat script: String, in layout: LinkBench.Layout) throws -> String {
  let bin = "\(layout.home)/host-bin"
  try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
  try Data("#!/bin/sh\n\(script)\n".utf8).write(to: URL(fileURLWithPath: "\(bin)/stat"))
  chmod("\(bin)/stat", 0o755)
  return "PATH=\(RemoteShellProtocol.quote(bin)):/usr/bin:/bin exec /bin/sh"
}

/// A master that runs a fake host shell: it answers the handshake, then runs `then`.
private func fakeHost(then: String, in layout: LinkBench.Layout) throws -> String {
  let script = "\(layout.home)/fake-host.sh"
  try Data(FakeShell.script(then: then).utf8).write(to: URL(fileURLWithPath: script))
  return sshWrapper(layout, command: "exec /bin/sh \(RemoteShellProtocol.quote(script))")
}

@Suite struct HostLinkTests {
  // MARK: disconnected

  @Test(.timeLimit(.minutes(1)))
  func aNewLinkIsDisconnectedAndStartsNoProcess() throws {
    let bench = try LinkBench()
    defer { bench.close() }

    let status = bench.link.status
    bench.tick(120_000)
    Thread.sleep(forTimeInterval: 0.3)

    #expect(status.state == .disconnected)
    #expect(status.failures == 0)
    #expect(status.retryAt == nil)
    #expect(status.error == nil)
    #expect(bench.link.status.state == .disconnected)
    #expect(bench.runs().isEmpty)
  }

  @Test(.timeLimit(.minutes(1)))
  func connectMovesADisconnectedLinkToConnecting() throws {
    let bench = try LinkBench()
    defer { bench.close() }
    try bench.set("hang")
    bench.clock.advance(5_000)

    bench.link.connect()
    let status = bench.link.status

    #expect(status.state == .connecting)
    #expect(status.since == bench.clock.now)
    #expect(status.failures == 0)
    #expect(status.retryAt == nil)
    try bench.waitForMasters(1)
  }

  // MARK: connecting

  @Test(.timeLimit(.minutes(1)))
  func anAttemptReachesConnectedAfterTheHandshakeAndTheControlSocketCheck() throws {
    let bench = try LinkBench()
    defer { bench.close() }
    bench.clock.advance(5_000)

    bench.link.connect()
    let status = try bench.waitFor(.connected)

    #expect(status.since == bench.clock.now)
    #expect(status.failures == 0)
    #expect(status.retryAt == nil)
    #expect(status.error == nil)
    #expect(kindOfFile(at: bench.controlPath) == "socket")
    #expect(!bench.logText.contains("multiplexing disabled"))
  }

  @Test(.timeLimit(.minutes(1)))
  func anAttemptRunsTheDocumentedSshCommands() throws {
    let bench = try LinkBench()
    defer { bench.close() }
    let pattern = "ControlPath=\(bench.home.path)/ssh/%C"

    try bench.connect()

    let runs = bench.runs()
    let resolve = try #require(runs.firstIndex { $0.argv.contains("-G") })
    let master = try #require(runs.firstIndex { $0.isMaster })
    let check = try #require(runs.firstIndex { $0.argv.contains("-O") })
    #expect(resolve < master)
    #expect(master < check)
    #expect(runs[resolve].argv == ["-G", "-o", pattern, "--", LinkBench.destination])
    #expect(
      runs[check].argv == ["-O", "check", "-o", "ControlPath=\(bench.controlPath)", "--", LinkBench.destination])
    #expect(Array(runs[master].argv.prefix(2)) == ["-M", "-T"])
    var options = runs[master].options
    let controlPath = options.removeValue(forKey: "ControlPath")
    #expect(controlPath == "\(bench.home.path)/ssh/%C" || controlPath == bench.controlPath)
    #expect(
      options == [
        "ControlPersist": "no", "ServerAliveInterval": "10", "ServerAliveCountMax": "6", "ForwardAgent": "yes",
        "BatchMode": "yes",
      ])
    #expect(runs[master].afterDashes.first == LinkBench.destination)
    #expect(runs[master].afterDashes.dropFirst().joined(separator: " ") == "exec /bin/sh")
  }

  @Test(.timeLimit(.minutes(1)))
  func anAttemptCreatesTheSshFolderThatOnlyTheUserCanOpen() throws {
    let bench = try LinkBench()
    defer { bench.close() }

    try bench.connect()

    let mode = try #require(
      try FileManager.default.attributesOfItem(atPath: bench.home.sshFolder)[.posixPermissions] as? NSNumber)
    #expect(mode.intValue == 0o700)
  }

  @Test(.timeLimit(.minutes(1)))
  func connectTwiceStartsOneProcess() throws {
    let bench = try LinkBench()
    defer { bench.close() }

    bench.link.connect()
    bench.link.connect()
    let connected = try bench.waitFor(.connected)
    bench.clock.advance(7_000)
    bench.link.connect()
    Thread.sleep(forTimeInterval: 0.3)

    #expect(bench.masters().count == 1)
    #expect(bench.link.status.state == .connected)
    #expect(bench.link.status.since == connected.since)
  }

  @Test(.timeLimit(.minutes(1)))
  func connectOnAConnectingLinkChangesNothing() throws {
    let bench = try LinkBench()
    defer { bench.close() }
    try bench.set("hang")
    bench.link.connect()
    let before = bench.link.status
    try bench.waitForMasters(1)
    bench.clock.advance(7_000)

    bench.link.connect()
    Thread.sleep(forTimeInterval: 0.3)

    #expect(bench.link.status.state == .connecting)
    #expect(bench.link.status.since == before.since)
    #expect(bench.masters().count == 1)
  }

  @Test(.timeLimit(.minutes(1)))
  func aFailedAttemptRecordsTheStubsStderrAsTheError() throws {
    let bench = try LinkBench()
    defer { bench.close() }
    try bench.set("refuse", "debug1: trying mini.local\n\(LinkBench.refusal)\n")
    bench.clock.advance(5_000)

    bench.link.connect()
    let status = try bench.waitFor(.unreachable)

    #expect(status.error?.contains(LinkBench.refusal) == true)
    #expect(status.error?.contains("debug1: trying mini.local") == true)
    #expect(status.failures == 1)
    #expect(status.since == bench.clock.now)
    #expect(status.retryAt == status.since)
  }

  @Test(.timeLimit(.minutes(1)))
  func aHostWithNoStatFailsTheAttemptWithTheHandshakesMessage() throws {
    let bench = try LinkBench { layout in
      sshWrapper(layout, command: try hostCommand(withStat: "exit 1", in: layout))
    }
    defer { bench.close() }

    bench.link.connect()
    let status = try bench.waitFor(.unreachable)

    #expect(status.error?.contains("the host has no stat or base64 that Switchboard can use") == true)
    #expect(status.failures == 1)
    let master = try #require(bench.masters().last)
    try bench.waitForExit(master.pid)
  }

  @Test(.timeLimit(.minutes(1)))
  func aHandshakeThatDoesNotParseFailsTheAttempt() throws {
    let bench = try LinkBench { layout in
      sshWrapper(layout, command: try hostCommand(withStat: "echo not a size", in: layout))
    }
    defer { bench.close() }

    bench.link.connect()
    let status = try bench.waitFor(.unreachable)

    #expect(status.error?.isEmpty == false)
    #expect(status.failures == 1)
    let master = try #require(bench.masters().last)
    try bench.waitForExit(master.pid)
  }

  @Test(.timeLimit(.minutes(1)))
  func aHungAttemptFailsWhenTheClockPassesAMinuteAndItsProcessEnds() throws {
    let bench = try LinkBench()
    defer { bench.close() }
    try bench.set("hang")
    bench.link.connect()
    try bench.waitForMasters(1)
    let hung = try #require(bench.masters().last)

    bench.tick(59_000)
    let early = bench.link.status
    bench.tick(2_000)
    let late = try bench.waitFor(.unreachable)

    #expect(early.state == .connecting)
    #expect(late.failures == 1)
    #expect(late.error?.isEmpty == false)
    #expect(late.since == bench.clock.now)
    #expect(late.retryAt == late.since)
    try bench.waitForExit(hung.pid)
  }

  @Test(.timeLimit(.minutes(1)))
  func anAttemptFailsOnceSixtySecondsHavePassedAndNotAMillisecondBefore() throws {
    let bench = try LinkBench()
    defer { bench.close() }
    try bench.set("hang")
    bench.link.connect()
    let started = bench.link.status.since

    bench.tick(59_999)
    let early = bench.link.status
    bench.tick(1)
    let late = bench.link.status

    #expect(early.state == .connecting)
    #expect(late.state == .unreachable)
    #expect(late.since == started + 60_000)
    #expect(late.failures == 1)
  }

  // MARK: Backoff

  @Test(.timeLimit(.minutes(2)))
  func failuresGrowByOnePerFailedAttemptAndRetryAtFollowsTheSchedule() throws {
    let bench = try LinkBench()
    defer { bench.close() }
    try bench.set("refuse", LinkBench.refusal + "\n")
    bench.link.connect()

    for failures in 1...9 {
      let status = try bench.waitFor(.unreachable, failures: failures)

      #expect(status.since == bench.clock.now)
      #expect(status.retryAt == status.since + retryDelayMs(failuresInARow: failures), "failures \(failures)")
      #expect(bench.masters().count == failures)
      bench.tick(retryDelayMs(failuresInARow: failures))
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func pollBeforeRetryAtStartsNothing() throws {
    let bench = try LinkBench()
    defer { bench.close() }
    let failed = try bench.fail(attempts: 3)
    let delay = retryDelayMs(failuresInARow: 3)

    bench.tick(delay - 1)
    let early = bench.link.status
    Thread.sleep(forTimeInterval: 0.3)

    #expect(delay == 2_000)
    #expect(early.state == .unreachable)
    #expect(early.since == failed.since)
    #expect(early.retryAt == failed.retryAt)
    #expect(bench.masters().count == 3)
    #expect(bench.link.status.failures == 3)
  }

  @Test(.timeLimit(.minutes(1)))
  func pollAtRetryAtMovesAnUnreachableLinkToConnecting() throws {
    let bench = try LinkBench()
    defer { bench.close() }
    try bench.fail(attempts: 3)
    try bench.clear("refuse")
    try bench.set("hang")

    bench.tick(retryDelayMs(failuresInARow: 3))
    let status = bench.link.status

    #expect(status.state == .connecting)
    #expect(status.since == bench.clock.now)
    #expect(status.failures == 3)
    try bench.waitForMasters(4)
  }

  @Test(.timeLimit(.minutes(1)))
  func connectOnAnUnreachableLinkRetriesAtOnceWithNoFailures() throws {
    let bench = try LinkBench()
    defer { bench.close() }
    let failed = try bench.fail(attempts: 4)
    try bench.clear("refuse")
    try bench.set("hang")
    bench.clock.advance(1)

    bench.link.connect()
    let status = bench.link.status

    #expect(failed.retryAt.map { $0 > bench.clock.now } == true)
    #expect(status.state == .connecting)
    #expect(status.failures == 0)
    #expect(status.retryAt == nil)
    #expect(status.since == bench.clock.now)
    try bench.waitForMasters(5)
    try bench.clear("hang")
    #expect(try bench.waitFor(.connected).failures == 0)
  }

  @Test(.timeLimit(.minutes(1)), arguments: [(59_999, 4), (60_000, 1), (3_600_000, 1)] as [(Int64, Int)])
  func aConnectionThatClosesAddsAFailureUnlessItStayedUpAMinute(uptimeMs: Int64, failures: Int) throws {
    let bench = try LinkBench()
    defer { bench.close() }
    try bench.fail(attempts: 3)
    try bench.clear("refuse")
    bench.tick(retryDelayMs(failuresInARow: 3))
    try bench.waitFor(.connected)
    let master = try #require(bench.masters().last)
    bench.clock.advance(uptimeMs)

    bench.drop(master)
    let status = try bench.waitFor(.unreachable)

    #expect(status.failures == failures)
    #expect(status.since == bench.clock.now)
    #expect(status.retryAt == status.since + retryDelayMs(failuresInARow: failures))
  }

  // MARK: connected

  @Test(.timeLimit(.minutes(1)))
  func aCommandRunsOnTheHostThroughTheLinksMachine() throws {
    let bench = try LinkBench()
    defer { bench.close() }
    let master = try bench.connect()

    let r = try bench.link.machine.run("/bin/sh", ["-c", #"printf %s "$HOME""#])

    #expect(r.status == 0)
    #expect(r.stdout == "\(bench.stubFolder)/home")
    #expect(try bench.link.shell().pid == master.pid)
  }

  @Test(.timeLimit(.minutes(1)))
  func aDroppedConnectionFailsTheCommandInFlightAndTheNextCommandGetsItsOwnOutput() throws {
    let bench = try LinkBench()
    defer { bench.close() }
    let first = try bench.connect()
    let flight = try bench.startSleeper()

    bench.drop(first)
    let outcome = try #require(flight.wait(), "the command did not return")
    let down = try bench.waitFor(.unreachable)
    bench.tick(retryDelayMs(failuresInARow: down.failures))
    try bench.waitFor(.connected)
    let second = try bench.link.machine.run("/bin/echo", ["second"])

    #expect(throws: (any Error).self) { try outcome.get() }
    #expect(down.failures == 1)
    #expect(down.error?.isEmpty == false)
    #expect(second.status == 0)
    #expect(second.stdout == "second\n")
    #expect(second.stderr == "")
    #expect(bench.masters().last.map { $0.pid != first.pid } == true)
  }

  @Test(.timeLimit(.minutes(1)))
  func aFramingErrorMovesAConnectedLinkToUnreachable() throws {
    let bench = try LinkBench { layout in
      try fakeHost(then: FakeShell.awaitRequest + "printf 'not a header\\n'\nexec cat >/dev/null", in: layout)
    }
    defer { bench.close() }
    let master = try bench.connect()

    #expect(throws: (any Error).self) { try bench.link.machine.run("/bin/echo", ["x"]) }
    let status = try bench.waitFor(.unreachable)

    #expect(status.failures == 1)
    #expect(status.error?.isEmpty == false)
    #expect(status.retryAt == status.since)
    try bench.waitForExit(master.pid)
  }

  /// A command's local deadline is its timeout plus 15 s of real time. The fake host keeps its
  /// stdout open, because `exec cat >/dev/null` would close it and end the connection at once.
  @Test(.timeLimit(.minutes(2)))
  func aLocalDeadlineMovesAConnectedLinkToUnreachable() throws {
    let bench = try LinkBench { layout in
      try fakeHost(then: FakeShell.awaitRequest + "cat >/dev/null", in: layout)
    }
    defer { bench.close() }
    let master = try bench.connect()

    #expect(throws: (any Error).self) {
      try bench.link.machine.run("/bin/echo", ["x"], env: nil, input: nil, timeout: 0.2)
    }
    let status = try bench.waitFor(.unreachable)

    #expect(status.failures == 1)
    #expect(status.error == "the host did not answer before the deadline")
    try bench.waitForExit(master.pid)
  }

  // MARK: A link that is not connected

  @Test(.timeLimit(.minutes(1)))
  func aCommandOnADisconnectedLinkThrowsAtOnceAndStartsNoProcess() throws {
    let bench = try LinkBench()
    defer { bench.close() }
    let machine = bench.link.machine
    let start = Date()

    #expect(throws: (any Error).self) { try machine.run("/bin/echo", ["x"]) }
    #expect(throws: (any Error).self) { try machine.createFolder("\(bench.home.path)/made") }
    #expect(throws: (any Error).self) { try bench.link.shell() }

    #expect(Date().timeIntervalSince(start) < 2)
    #expect(bench.link.status.state == .disconnected)
    #expect(bench.runs().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: "\(bench.home.path)/made"))
  }

  @Test(.timeLimit(.minutes(1)))
  func aFileQuestionOnADisconnectedLinkAnswersNothingAndStartsNoProcess() throws {
    let bench = try LinkBench()
    defer { bench.close() }
    let machine = bench.link.machine
    let file = "\(bench.home.path)/present.txt"
    try Data("here".utf8).write(to: URL(fileURLWithPath: file))

    #expect(machine.exists(file) == false)
    #expect(machine.isFolder(bench.home.path) == false)
    #expect(machine.read(file, from: 0, count: nil) == nil)
    #expect(machine.size(file) == nil)
    #expect(machine.modified(file) == nil)
    #expect(machine.list(bench.home.path).isEmpty)
    #expect(bench.runs().isEmpty)
  }

  @Test(.timeLimit(.minutes(1)))
  func aCommandOnAnUnreachableLinkThrowsAtOnceAndStartsNoProcess() throws {
    let bench = try LinkBench()
    defer { bench.close() }
    let failed = try bench.fail(attempts: 3)
    let start = Date()

    #expect(throws: (any Error).self) { try bench.link.machine.run("/bin/echo", ["x"]) }
    #expect(throws: (any Error).self) { try bench.link.shell() }
    Thread.sleep(forTimeInterval: 0.3)

    #expect(Date().timeIntervalSince(start) < 2)
    #expect(bench.masters().count == 3)
    #expect(bench.link.status.state == .unreachable)
    #expect(bench.link.status.since == failed.since)
  }

  @Test(.timeLimit(.minutes(1)))
  func aCommandOnAConnectingLinkThrowsAtOnce() throws {
    let bench = try LinkBench()
    defer { bench.close() }
    try bench.set("hang")
    bench.link.connect()
    try bench.waitForMasters(1)
    let start = Date()

    #expect(throws: (any Error).self) { try bench.link.machine.run("/bin/echo", ["x"]) }

    #expect(Date().timeIntervalSince(start) < 2)
    #expect(bench.link.status.state == .connecting)
    #expect(bench.masters().count == 1)
  }

  // MARK: disconnect

  @Test(.timeLimit(.minutes(1)))
  func disconnectEndsAConnectedLinksProcess() throws {
    let bench = try LinkBench()
    defer { bench.close() }
    let master = try bench.connect()
    bench.clock.advance(9_000)

    bench.link.disconnect()
    let status = bench.link.status
    try bench.waitForExit(master.pid)
    bench.tick(120_000)
    Thread.sleep(forTimeInterval: 0.3)

    #expect(status.state == .disconnected)
    #expect(status.since == bench.clock.now - 120_000)
    #expect(status.retryAt == nil)
    #expect(bench.link.status.state == .disconnected)
    #expect(bench.masters().count == 1)
    #expect(throws: (any Error).self) { try bench.link.machine.run("/bin/echo", ["x"]) }
  }

  @Test(.timeLimit(.minutes(1)))
  func disconnectDuringACommandFailsTheCommand() throws {
    let bench = try LinkBench()
    defer { bench.close() }
    let master = try bench.connect()
    let flight = try bench.startSleeper()

    bench.link.disconnect()
    let outcome = try #require(flight.wait(), "the command did not return")

    #expect(throws: (any Error).self) { try outcome.get() }
    #expect(bench.link.status.state == .disconnected)
    try bench.waitForExit(master.pid)
  }

  @Test(.timeLimit(.minutes(1)))
  func disconnectEndsAnAttemptAndDropsItsResult() throws {
    let bench = try LinkBench()
    defer { bench.close() }
    try bench.set("hang")
    bench.link.connect()
    try bench.waitForMasters(1)
    let hung = try #require(bench.masters().last)

    bench.link.disconnect()
    let status = bench.link.status
    try bench.clear("hang")
    try bench.waitForExit(hung.pid)
    bench.tick(120_000)
    Thread.sleep(forTimeInterval: 0.5)

    #expect(status.state == .disconnected)
    #expect(bench.link.status.state == .disconnected)
    #expect(bench.link.status.retryAt == nil)
    #expect(bench.masters().count == 1)
  }

  @Test(.timeLimit(.minutes(1)))
  func disconnectOnAnUnreachableLinkDropsTheRetry() throws {
    let bench = try LinkBench()
    defer { bench.close() }
    try bench.fail(attempts: 3)

    bench.link.disconnect()
    let status = bench.link.status
    bench.tick(120_000)
    Thread.sleep(forTimeInterval: 0.3)

    #expect(status.state == .disconnected)
    #expect(status.retryAt == nil)
    #expect(status.failures == 0)
    #expect(status.error == nil)
    #expect(bench.link.status.state == .disconnected)
    #expect(bench.masters().count == 3)
  }

  @Test(.timeLimit(.minutes(1)))
  func disconnectOnAConnectedLinkResetsItsFailures() throws {
    let bench = try LinkBench()
    defer { bench.close() }
    try bench.fail(attempts: 2)
    try bench.clear("refuse")
    bench.tick(retryDelayMs(failuresInARow: 2))
    let up = try bench.waitFor(.connected)

    bench.link.disconnect()
    let status = bench.link.status

    #expect(up.failures == 2)
    #expect(status.state == .disconnected)
    #expect(status.failures == 0)
    #expect(status.error == nil)
    #expect(status.retryAt == nil)
  }

  @Test(.timeLimit(.minutes(1)))
  func disconnectOnADisconnectedLinkStartsNothing() throws {
    let bench = try LinkBench()
    defer { bench.close() }

    bench.link.disconnect()

    #expect(bench.link.status.state == .disconnected)
    #expect(bench.runs().isEmpty)
  }

  /// A master that still runs could take the control path of the next one, or remove its socket.
  @Test(.timeLimit(.minutes(1)))
  func aNewAttemptWaitsForTheLastMasterToExit() throws {
    let bench = try LinkBench()
    defer { bench.close() }
    try bench.set("hang")
    bench.link.connect()
    try bench.waitForMasters(1)
    let hung = try #require(bench.masters().last)

    bench.link.disconnect()
    try bench.clear("hang")
    bench.link.connect()
    let status = try bench.waitFor(.connected)

    #expect(LinkBench.ended(hung.pid))
    #expect(status.failures == 0)
    #expect(bench.masters().count == 2)
    #expect(!bench.logText.contains("multiplexing disabled"))
    #expect(try bench.link.shell().pid == bench.masters().last?.pid)
  }

  @Test(.timeLimit(.minutes(1)))
  func anAttemptFailsWhileTheLastSshProcessStillRuns() throws {
    let bench = try LinkBench { layout in
      let starts = RemoteShellProtocol.quote("\(layout.home)/starts")
      return sshWrapper(layout, beforeMaster: "echo start >>\(starts); trap '' TERM; exec sleep 9")
    }
    defer { bench.close() }
    let starts = { (try? String(contentsOfFile: "\(bench.home.path)/starts", encoding: .utf8))?.count ?? 0 }
    bench.link.connect()
    try bench.wait("the first ssh process") { starts() > 0 }

    bench.link.disconnect()
    bench.link.connect()
    let status = try bench.waitFor(.unreachable)

    #expect(status.error?.contains("has not exited") == true, "\(status)")
    #expect(status.failures == 1)
    #expect(starts() == "start\n".count)
    #expect(bench.runs().filter { $0.argv.contains("-G") }.count == 1)
  }

  @Test(.timeLimit(.minutes(1)))
  func connectAndDisconnectInQuickSuccessionLeaveOneMaster() throws {
    let bench = try LinkBench()
    defer { bench.close() }

    for round in 0..<30 {
      bench.link.connect()
      Thread.sleep(forTimeInterval: Double(round % 6) * 0.03)
      bench.link.disconnect()
    }
    bench.link.connect()
    let status = try bench.waitFor(.connected)
    let r = try bench.link.machine.run("/bin/echo", ["last"])

    let masters = bench.masters()
    let open = try bench.link.shell().pid
    #expect(status.failures == 0)
    #expect(r.stdout == "last\n")
    #expect(masters.last?.pid == open)
    for master in masters.dropLast() { try bench.waitForExit(master.pid) }
    #expect(!bench.logText.contains("multiplexing disabled"))
    #expect(bench.link.status.state == .connected)
  }

  /// A name with no folder is what the service passes when it finds no such program on PATH.
  @Test(
    .timeLimit(.minutes(1)),
    arguments: ["/no-ssh", "no-such-ssh", "bin/test", "/ssh-stub", "/ssh-stub/", "/link-to-a-folder"])
  func anSshCommandThatDoesNotExistFailsTheAttempt(name: String) throws {
    let bench = try LinkBench()
    defer { bench.close() }
    try FileManager.default.createSymbolicLink(
      atPath: "\(bench.home.path)/link-to-a-folder", withDestinationPath: bench.stubFolder)
    let clock = bench.clock
    let ssh = name.hasPrefix("/") ? bench.home.path + name : name
    let link = HostLink(
      config: bench.link.config, destination: LinkBench.destination, ssh: ssh, home: bench.home, now: { clock.now })

    link.connect()
    try bench.wait("the attempt to fail") { link.status.state == .unreachable }

    #expect(link.status.failures == 1)
    #expect(link.status.error == "ssh not found: \(ssh)")
    #expect(link.status.retryAt == link.status.since)
    #expect(kindOfFile(at: bench.home.sshFolder) == nil)
  }

  @Test(.timeLimit(.minutes(1)))
  func aHomeWithASpaceAndQuotesConnectsAndReconnects() throws {
    let bench = try LinkBench(folder: #"a "b' \c"#)
    defer { bench.close() }

    let first = try bench.connect()
    bench.drop(first)
    let down = try bench.waitFor(.unreachable)
    try bench.waitForExit(first.pid)
    bench.tick(retryDelayMs(failuresInARow: down.failures))
    try bench.waitFor(.connected)
    let r = try bench.link.machine.run("/bin/echo", ["there"])

    #expect(bench.controlPath.contains(#"/a "b' \c/ssh/"#))
    #expect(r.stdout == "there\n")
    #expect(bench.masters().count == 2)
    #expect(!bench.logText.contains("multiplexing disabled"))
    #expect(kindOfFile(at: bench.controlPath) == "socket")
  }

  @Test(.timeLimit(.minutes(1)))
  func aHomeWithAPercentSignFailsTheAttemptBeforeSshRuns() throws {
    let bench = try LinkBench(folder: "p%hq")
    defer { bench.close() }

    bench.link.connect()
    let status = try bench.waitFor(.unreachable)

    #expect(status.error?.contains("\(bench.home.sshFolder) holds one") == true, "\(status)")
    #expect(bench.runs().isEmpty)
    #expect(kindOfFile(at: bench.home.sshFolder) == nil)
  }

  /// ssh gets its arguments in decomposed Unicode and prints the control path that way.
  @Test(.timeLimit(.minutes(1)), arguments: ["caf\u{e9}", "cafe\u{301}", "\u{fc}ber \u{f1}", "\u{ac00}", "\u{304c}"])
  func aHomeWithANonASCIINameConnectsAndReconnects(folder: String) throws {
    let bench = try LinkBench(folder: folder)
    defer { bench.close() }

    let first = try bench.connect()
    let bound = inode(of: bench.controlPath)
    bench.drop(first)
    let down = try bench.waitFor(.unreachable)
    try bench.waitForExit(first.pid)
    bench.tick(retryDelayMs(failuresInARow: down.failures))
    try bench.waitFor(.connected)

    #expect(bound != nil)
    #expect(inode(of: bench.controlPath) != bound)
    #expect(bench.masters().count == 2)
    #expect(!bench.logText.contains("multiplexing disabled"))
    #expect(try FileManager.default.contentsOfDirectory(atPath: bench.home.sshFolder).count == 1)
  }

  @Test(.timeLimit(.minutes(1)))
  func aFailedResolveLeavesOutTheLineAboutThePseudoTerminal() throws {
    let bench = try LinkBench { layout in
      let notice = "Pseudo-terminal will not be allocated because stdin is not a terminal."
      return sshWrapper(layout, onG: "echo '\(notice)' >&2; echo 'ssh: no route' >&2; exit 255")
    }
    defer { bench.close() }

    bench.link.connect()
    let status = try bench.waitFor(.unreachable)

    #expect(status.error == "ssh -G failed: ssh: no route")
  }

  @Test func theControlPathOptionQuotesAnythingButAPlainPath() {
    #expect(HostLink.controlPathOption("/tmp/sb.x_Y-1/ssh/%C") == "ControlPath=/tmp/sb.x_Y-1/ssh/%C")
    #expect(HostLink.controlPathOption("/a b/%C") == #"ControlPath="/a b/%C""#)
    #expect(HostLink.controlPathOption(#"/a"b\c/%C"#) == #"ControlPath="/a\"b\\c/%C""#)
    #expect(HostLink.controlPathOption("/a\n") == "ControlPath=\"/a\n\"")
    #expect(HostLink.controlPathOption("/é/#x") == "ControlPath=\"/é/#x\"")
  }

  @Test(.timeLimit(.minutes(1)))
  func aLinkConnectsAgainAfterADisconnect() throws {
    let bench = try LinkBench()
    defer { bench.close() }
    let first = try bench.connect()
    bench.link.disconnect()
    try bench.waitForExit(first.pid)

    let second = try bench.connect()
    let r = try bench.link.machine.run("/bin/echo", ["again"])

    #expect(second.pid != first.pid)
    #expect(r.stdout == "again\n")
    #expect(!bench.logText.contains("multiplexing disabled"))
  }
}

/// What a test puts at the control path before an attempt.
enum Squatter: String, CaseIterable {
  case regularFile, folder, symlinkToAFile, symlinkToASocket, brokenSymlink

  /// The file kind that `lstat` must still find at the path afterwards.
  var kind: String {
    switch self {
    case .regularFile: return "file"
    case .folder: return "folder"
    case .symlinkToAFile, .symlinkToASocket, .brokenSymlink: return "symlink"
    }
  }

  /// Puts the squatter at the path and returns the other paths that must outlast the attempt.
  func place(at path: String, home: String) throws -> [String] {
    let files = FileManager.default
    switch self {
    case .regularFile:
      try Data("keep me".utf8).write(to: URL(fileURLWithPath: path))
      return []
    case .folder:
      try files.createDirectory(atPath: path, withIntermediateDirectories: true)
      try Data("keep me".utf8).write(to: URL(fileURLWithPath: "\(path)/inside"))
      return ["\(path)/inside"]
    case .symlinkToAFile:
      let target = "\(home)/target.txt"
      try Data("keep me".utf8).write(to: URL(fileURLWithPath: target))
      try files.createSymbolicLink(atPath: path, withDestinationPath: target)
      return [target]
    case .symlinkToASocket:
      let target = "\(home)/target.sock"
      try makeStaleSocket(at: target)
      try files.createSymbolicLink(atPath: path, withDestinationPath: target)
      return [target]
    case .brokenSymlink:
      try files.createSymbolicLink(atPath: path, withDestinationPath: "\(home)/nothing-here")
      return []
    }
  }
}

/// A `controlpath` answer of `ssh -G` that the link must refuse.
enum UntrustedControlPath: String, CaseIterable {
  case noLine, percentLeft, outsideTheSshFolder, upAndOutOfTheSshFolder, aFolderWithTheSamePrefix, inASubfolder,
    inASubfolderBehindACombiningMark, theSshFolderItself, resolveFails

  /// The path that the `-G` answer names, or nil when it names none.
  func path(_ layout: LinkBench.Layout) -> String? {
    switch self {
    case .noLine, .resolveFails: return nil
    case .percentLeft: return "\(layout.home)/ssh/%C"
    case .outsideTheSshFolder: return "\(layout.home)/elsewhere/master.sock"
    case .upAndOutOfTheSshFolder: return "\(layout.home)/ssh/../elsewhere/master.sock"
    case .aFolderWithTheSamePrefix: return "\(layout.home)/ssh-other/master.sock"
    case .inASubfolder: return "\(layout.home)/ssh/sub/master.sock"
    // "/" and the mark that follows are one character, so a test of characters finds no "/".
    case .inASubfolderBehindACombiningMark: return "\(layout.home)/ssh/sub/\u{301}master.sock"
    case .theSshFolderItself: return "\(layout.home)/ssh"
    }
  }

  /// The script that answers `ssh -G`.
  func onG(_ layout: LinkBench.Layout) -> String {
    if self == .resolveFails { return "echo 'ssh: Could not resolve hostname mini.local' >&2; exit 255" }
    let line = path(layout).map { "printf 'controlpath %s\\n' \(RemoteShellProtocol.quote($0))" } ?? ":"
    return "echo 'hostname mini.local'; echo 'controlmaster false'; \(line); echo 'controlpersist no'"
  }
}

@Suite struct HostLinkControlPathTests {
  @Test func theControlSocketNameIsTheLastPartOfTheOneControlPathLine() throws {
    let output = "hostname mini.local\ncontrolmaster false\ncontrolpath /h/ssh/0a1b\ncontrolpersist no\n"

    #expect(try HostLink.controlSocketName(inConfig: output, sshFolder: "/h/ssh") == "0a1b")
    #expect(try HostLink.controlSocketName(inConfig: "controlpath /h/ssh/a b ", sshFolder: "/h/ssh") == "a b ")
  }

  @Test(arguments: [
    "", "hostname mini.local\n", "controlpath\n", "controlpath \n", "controlpath /h/ssh\n", "controlpath /h/ssh/\n",
    "controlpath /h/ssh/.\n", "controlpath /h/ssh/..\n", "controlpath /h/ssh/../x\n", "controlpath /h/ssh/a/b\n",
    "controlpath /h/ssh/a/\n", "controlpath /h/ssh/a/\u{301}b\n", "controlpath /h/ssh/%C\n", "controlpath /h/ssh/a%h\n",
    "controlpath /h/sshx/a\n", "controlpath /h/ssh\u{301}/a\n", "controlpath h/ssh/a\n", "controlpath  /h/ssh/a\n",
    "controlpath none\n", "ControlPath /h/ssh/a\n", " controlpath /h/ssh/a\n", "xcontrolpath /h/ssh/a\n",
    "controlpath /h/ssh/a\ncontrolpath /h/ssh/b\n", "controlpath /h/ssh/a\ncontrolpath /h/ssh/a\n",
  ])
  func aControlPathAnswerOutsideTheRuleIsRefused(output: String) {
    #expect(throws: (any Error).self) { try HostLink.controlSocketName(inConfig: output, sshFolder: "/h/ssh") }
  }

  @Test(.timeLimit(.minutes(1)))
  func aSocketLeftByAKilledStubIsRemovedAndTheNextAttemptHasAControlSocket() throws {
    let bench = try LinkBench()
    defer { bench.close() }
    let first = try bench.connect()
    bench.drop(first)
    let down = try bench.waitFor(.unreachable)
    try bench.waitForExit(first.pid)
    let left = kindOfFile(at: bench.controlPath)

    bench.tick(retryDelayMs(failuresInARow: down.failures))
    try bench.waitFor(.connected)

    let second = try #require(bench.masters().last)
    #expect(left == "socket")
    #expect(second.pid != first.pid)
    #expect(!bench.logText.contains("multiplexing disabled"))
    #expect(kindOfFile(at: bench.controlPath) == "socket")
    #expect(try runCommand(LinkBench.stub, bench.runs().last { $0.argv.contains("-O") }?.argv ?? []).status == 0)
  }

  @Test(.timeLimit(.minutes(1)))
  func aStaleSocketThatNoMasterOfThisLinkLeftIsRemovedToo() throws {
    let bench = try LinkBench()
    defer { bench.close() }
    try FileManager.default.createDirectory(
      atPath: bench.home.sshFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try makeStaleSocket(at: bench.controlPath)

    try bench.connect()

    #expect(!bench.logText.contains("multiplexing disabled"))
    #expect(kindOfFile(at: bench.controlPath) == "socket")
  }

  @Test(.timeLimit(.minutes(1)))
  func aSocketThatAProcessStillListensOnFailsTheAttemptAndStays() throws {
    let bench = try LinkBench()
    defer { bench.close() }
    try FileManager.default.createDirectory(
      atPath: bench.home.sshFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let listener = try UnixSocket.listen(path: bench.controlPath)
    defer { close(listener) }

    bench.link.connect()
    let status = try bench.waitFor(.unreachable)

    #expect(status.error?.contains("an ssh master that still runs has the control socket \(bench.controlPath)") == true)
    #expect(status.failures == 1)
    #expect(kindOfFile(at: bench.controlPath) == "socket")
    #expect((try? UnixSocket.connect(path: bench.controlPath, timeout: 1)).map { close($0) } != nil)
    #expect(bench.masters().isEmpty)
  }

  /// A stream connect to this listener is refused, as it is for a socket file that a dead
  /// master left.
  @Test(.timeLimit(.minutes(1)))
  func aSocketWhoseListenerHasAFullAcceptQueueFailsTheAttemptAndStays() throws {
    let bench = try LinkBench()
    defer { bench.close() }
    try FileManager.default.createDirectory(
      atPath: bench.home.sshFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let open = try listenWithAFullQueue(at: bench.controlPath)
    defer { open.forEach { close($0) } }
    let before = inode(of: bench.controlPath)
    let refused = try connectWithoutWaiting(to: bench.controlPath)
    let refusal = errno
    refused.map { _ = close($0) }

    bench.link.connect()
    let status = try bench.waitFor(.unreachable)

    #expect(refused == nil)
    #expect(refusal == ECONNREFUSED)
    #expect(status.error?.contains("an ssh master that still runs has the control socket \(bench.controlPath)") == true)
    #expect(before != nil)
    #expect(inode(of: bench.controlPath) == before)
    #expect(bench.masters().isEmpty)
  }

  @Test(.timeLimit(.minutes(1)))
  func aSocketThatIsBoundAndDoesNotListenFailsTheAttemptAndStays() throws {
    let bench = try LinkBench()
    defer { bench.close() }
    try FileManager.default.createDirectory(
      atPath: bench.home.sshFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let bound = try bindSocket(at: bench.controlPath)
    defer { close(bound) }
    let before = inode(of: bench.controlPath)

    bench.link.connect()
    let status = try bench.waitFor(.unreachable)

    #expect(status.error?.contains("an ssh master that still runs has the control socket \(bench.controlPath)") == true)
    #expect(inode(of: bench.controlPath) == before)
    #expect(bench.masters().isEmpty)
  }

  @Test func onlyASocketFileWithNoOpenSocketCountsAsStale() throws {
    let bench = try LinkBench()
    defer { bench.close() }
    let folder = bench.home.path
    try makeStaleSocket(at: "\(folder)/stale")
    try makeStaleSocket(at: "\(folder)/locked")
    chmod("\(folder)/locked", 0)
    try FileManager.default.createDirectory(atPath: "\(folder)/sub", withIntermediateDirectories: true)
    try makeStaleSocket(at: "\(folder)/sub/stale")
    let listener = try UnixSocket.listen(path: "\(folder)/listening")
    let full = try listenWithAFullQueue(at: "\(folder)/full")
    let bound = try bindSocket(at: "\(folder)/bound")
    let datagram = try bindSocket(at: "\(folder)/datagram", type: SOCK_DGRAM)
    try Data().write(to: URL(fileURLWithPath: "\(folder)/file"))
    let descriptor = open(folder, O_RDONLY | O_DIRECTORY)
    defer { ([listener, bound, datagram, descriptor] + full).forEach { close($0) } }
    let here = FileManager.default.currentDirectoryPath

    #expect(HostLink.hasOpenSocket("stale", inFolder: descriptor) == false)
    #expect(HostLink.hasOpenSocket("listening", inFolder: descriptor) == true)
    #expect(HostLink.hasOpenSocket("full", inFolder: descriptor) == true)
    #expect(HostLink.hasOpenSocket("bound", inFolder: descriptor) == true)
    #expect(HostLink.hasOpenSocket("datagram", inFolder: descriptor) == true)
    #expect(HostLink.hasOpenSocket("missing", inFolder: descriptor) == nil)
    #expect(HostLink.hasOpenSocket("file", inFolder: descriptor) == nil)
    #expect(HostLink.hasOpenSocket("locked", inFolder: descriptor) == nil)
    #expect(HostLink.hasOpenSocket("sub/stale", inFolder: descriptor) == nil)
    #expect(HostLink.hasOpenSocket("", inFolder: descriptor) == nil)
    #expect(HostLink.hasOpenSocket(String(repeating: "x", count: 200), inFolder: descriptor) == nil)
    #expect(HostLink.hasOpenSocket("stale", inFolder: -1) == nil)
    #expect(FileManager.default.currentDirectoryPath == here)
    #expect(kindOfFile(at: "\(here)/stale") == nil)
  }

  /// The folder at the ssh folder's path changes after the link opened it. The probe and the
  /// unlink must both act on the folder that the link opened.
  @Test func aFolderSwappedAfterTheLinkOpenedItDoesNotMoveTheProbe() throws {
    let bench = try LinkBench()
    defer { bench.close() }
    let files = FileManager.default
    let (opened, moved, decoy) = (bench.home.sshFolder, "\(bench.home.path)/moved", "\(bench.home.path)/decoy")
    for folder in [opened, decoy] { try files.createDirectory(atPath: folder, withIntermediateDirectories: true) }
    let live = try bindSocket(at: "\(opened)/s")
    try makeStaleSocket(at: "\(decoy)/s")
    let descriptor = open(opened, O_RDONLY | O_DIRECTORY)
    defer { [live, descriptor].forEach { close($0) } }
    try files.moveItem(atPath: opened, toPath: moved)
    try files.moveItem(atPath: decoy, toPath: opened)
    let before = inode(of: "\(moved)/s")

    #expect(throws: (any Error).self) {
      try HostLink.removeStaleSocket("s", inFolder: descriptor, path: "\(opened)/s")
    }
    #expect(before != nil)
    #expect(inode(of: "\(moved)/s") == before)
    #expect(kindOfFile(at: "\(opened)/s") == "socket")
  }

  /// The opened folder holds a stale socket. The folder now at the path holds a live one.
  @Test func aFolderSwappedAfterTheLinkOpenedItDoesNotMoveTheUnlink() throws {
    let bench = try LinkBench()
    defer { bench.close() }
    let files = FileManager.default
    let (opened, moved, decoy) = (bench.home.sshFolder, "\(bench.home.path)/moved", "\(bench.home.path)/decoy")
    for folder in [opened, decoy] { try files.createDirectory(atPath: folder, withIntermediateDirectories: true) }
    try makeStaleSocket(at: "\(opened)/s")
    let live = try bindSocket(at: "\(decoy)/s")
    let descriptor = open(opened, O_RDONLY | O_DIRECTORY)
    defer { [live, descriptor].forEach { close($0) } }
    try files.moveItem(atPath: opened, toPath: moved)
    try files.moveItem(atPath: decoy, toPath: opened)
    let before = inode(of: "\(opened)/s")

    try HostLink.removeStaleSocket("s", inFolder: descriptor, path: "\(opened)/s")

    #expect(before != nil)
    #expect(inode(of: "\(opened)/s") == before)
    #expect(inode(of: "\(moved)/s") == nil)
  }

  /// The opened folder holds a symlink to a stale socket. The folder now at the path holds a stale socket.
  @Test func aFolderSwappedAfterTheLinkOpenedItDoesNotMoveTheKindCheck() throws {
    let bench = try LinkBench()
    defer { bench.close() }
    let files = FileManager.default
    let (opened, moved, decoy) = (bench.home.sshFolder, "\(bench.home.path)/moved", "\(bench.home.path)/decoy")
    let target = "\(bench.home.path)/target"
    for folder in [opened, decoy] { try files.createDirectory(atPath: folder, withIntermediateDirectories: true) }
    try makeStaleSocket(at: target)
    try files.createSymbolicLink(atPath: "\(opened)/s", withDestinationPath: target)
    try makeStaleSocket(at: "\(decoy)/s")
    let descriptor = open(opened, O_RDONLY | O_DIRECTORY)
    defer { close(descriptor) }
    try files.moveItem(atPath: opened, toPath: moved)
    try files.moveItem(atPath: decoy, toPath: opened)

    #expect(throws: (any Error).self) {
      try HostLink.removeStaleSocket("s", inFolder: descriptor, path: "\(opened)/s")
    }
    #expect(kindOfFile(at: "\(moved)/s") == "symlink")
    #expect(kindOfFile(at: "\(opened)/s") == "socket")
    #expect(kindOfFile(at: target) == "socket")
  }

  /// The name is a stale socket in the folder the thread is in, so a probe that ignored the failed change would answer false.
  @Test func aFailedFolderChangeAnswersUnknown() throws {
    let bench = try LinkBench()
    defer { bench.close() }
    try makeStaleSocket(at: "\(bench.home.path)/s")
    let folder = open(bench.home.path, O_RDONLY | O_DIRECTORY)
    defer { close(folder) }
    let closed = dup(folder)
    close(closed)
    let setThreadFolder = unsafeBitCast(
      dlsym(UnsafeMutableRawPointer(bitPattern: -2), "pthread_fchdir_np"), to: (@convention(c) (Int32) -> Int32).self)
    let answer = ProbeResult<Bool?>(true)
    let done = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
      _ = setThreadFolder(folder)
      answer.value = HostLink.hasOpenSocket("s", inFolder: closed)
      _ = setThreadFolder(-1)
      done.signal()
    }
    done.wait()

    #expect(answer.value == nil)
  }

  /// A later probe would reset a folder that this one left behind, so the thread runs only one.
  @Test func theThreadIsBackInTheProcessFolderAfterOneProbe() throws {
    let bench = try LinkBench()
    defer { bench.close() }
    try makeStaleSocket(at: "\(bench.home.path)/s")
    let folder = open(bench.home.path, O_RDONLY | O_DIRECTORY)
    defer { close(folder) }
    let result = ProbeResult<(answer: Bool?, sameFolder: Bool, nameResolves: Bool)>((nil, false, true))
    let done = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
      let processFolder = inode(of: ".")
      let answer = HostLink.hasOpenSocket("s", inFolder: folder)
      result.value = (answer, inode(of: ".") == processFolder, inode(of: "s") != nil)
      done.signal()
    }
    done.wait()

    #expect(result.value.answer == false)
    #expect(result.value.sameFolder)
    #expect(!result.value.nameResolves)
  }

  @Test(.timeLimit(.minutes(1)))
  func aFileWhereTheSshFolderBelongsFailsTheAttemptAndStays() throws {
    let bench = try LinkBench()
    defer { bench.close() }
    try Data("keep".utf8).write(to: URL(fileURLWithPath: bench.home.sshFolder))

    bench.link.connect()
    _ = try bench.waitFor(.unreachable)

    #expect(kindOfFile(at: bench.home.sshFolder) == "file")
    #expect(bench.masters().isEmpty)
  }

  /// The link has no permission to connect to the file, so it cannot tell whether it is stale.
  @Test(.timeLimit(.minutes(1)))
  func aSocketThatTheLinkCannotProbeFailsTheAttemptAndStays() throws {
    let bench = try LinkBench()
    defer { bench.close() }
    try FileManager.default.createDirectory(
      atPath: bench.home.sshFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try makeStaleSocket(at: bench.controlPath)
    chmod(bench.controlPath, 0)
    let before = inode(of: bench.controlPath)

    bench.link.connect()
    let status = try bench.waitFor(.unreachable)

    #expect(
      status.error?.contains("can't tell whether an ssh master still has the control socket") == true, "\(status)")
    #expect(before != nil)
    #expect(inode(of: bench.controlPath) == before)
    #expect(bench.masters().isEmpty)
  }

  /// The unlink would otherwise reach through the link into another folder.
  @Test(.timeLimit(.minutes(1)))
  func anSshFolderThatIsASymlinkFailsTheAttemptAndDeletesNothing() throws {
    let bench = try LinkBench()
    defer { bench.close() }
    let target = "\(bench.home.path)/elsewhere"
    try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(atPath: bench.home.sshFolder, withDestinationPath: target)
    let socket = "\(target)/\((bench.controlPath as NSString).lastPathComponent)"
    try makeStaleSocket(at: socket)

    bench.link.connect()
    let status = try bench.waitFor(.unreachable)

    #expect(status.error?.contains("\(bench.home.sshFolder) must be a folder and not a link") == true, "\(status)")
    #expect(kindOfFile(at: socket) == "socket")
    #expect(kindOfFile(at: bench.home.sshFolder) == "symlink")
    #expect(bench.masters().isEmpty)
  }

  @Test(.timeLimit(.minutes(1)), arguments: Squatter.allCases)
  func anythingButASocketAtTheControlPathFailsTheAttemptAndStays(squatter: Squatter) throws {
    let bench = try LinkBench()
    defer { bench.close() }
    try FileManager.default.createDirectory(
      atPath: bench.home.sshFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let others = try squatter.place(at: bench.controlPath, home: bench.home.path)

    bench.link.connect()
    let status = try bench.waitFor(.unreachable)

    #expect(status.error?.contains("\(bench.controlPath) exists and is not a socket") == true, "\(status)")
    #expect(status.failures == 1)
    #expect(kindOfFile(at: bench.controlPath) == squatter.kind)
    #expect(others.allSatisfy { kindOfFile(at: $0) != nil })
    #expect(bench.masters().isEmpty)
  }

  @Test(.timeLimit(.minutes(1)), arguments: UntrustedControlPath.allCases)
  func aControlPathThatTheLinkCannotTrustFailsTheAttemptAndDeletesNothing(answer: UntrustedControlPath) throws {
    let bench = try LinkBench { sshWrapper($0, onG: answer.onG($0)) }
    defer { bench.close() }
    let files = FileManager.default
    for folder in ["ssh", "ssh/sub", "elsewhere", "ssh-other"] {
      try files.createDirectory(
        atPath: "\(bench.home.path)/\(folder)", withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    }
    var decoys = [bench.controlPath]
    if let named = answer.path(bench.layout), answer != .theSshFolderItself { decoys.append(named) }
    for decoy in decoys { try makeStaleSocket(at: decoy) }

    bench.link.connect()
    let status = try bench.waitFor(.unreachable)

    #expect(status.failures == 1)
    #expect(status.error?.isEmpty == false)
    #expect(decoys.allSatisfy { kindOfFile(at: $0) == "socket" }, "\(decoys.map { kindOfFile(at: $0) ?? "gone" })")
    #expect(kindOfFile(at: bench.home.sshFolder) == "folder")
    #expect(bench.masters().isEmpty)
  }

  /// Another process takes the control path between the link's `lstat` and the start of ssh.
  @Test(.timeLimit(.minutes(1)))
  func aMasterThatDisabledMultiplexingFailsTheCheckAndNeverConnects() throws {
    let bench = try LinkBench { sshWrapper($0, beforeMaster: ": >\(RemoteShellProtocol.quote($0.controlPath))") }
    defer { bench.close() }
    var states: Set<LinkState> = []

    bench.link.connect()
    let status = try bench.waitForStatus("the attempt to fail") {
      states.insert($0.state)
      return $0.state == .unreachable
    }

    let master = try #require(bench.masters().last)
    #expect(bench.logText.contains("multiplexing disabled"))
    #expect(bench.runs().contains { $0.argv.contains("-O") && $0.argv.contains("check") })
    #expect(!states.contains(.connected))
    #expect(status.failures == 1)
    #expect(status.error?.isEmpty == false)
    #expect(throws: (any Error).self) { try bench.link.machine.run("/bin/echo", ["x"]) }
    try bench.waitForExit(master.pid)
  }
}

/// A `Service` in a temporary home whose config.json names the stub as ssh and lists a valid
/// ssh host, a host with a link per box, and an invalid host.
private func withHostService(_ body: (Service, Home) throws -> Void) throws {
  var template = Array("/tmp/sbs.XXXXXX".utf8CString)
  guard let dir = mkdtemp(&template) else { throw APIError("mkdtemp failed") }
  let home = Home(path: String(cString: dir))
  defer { try? FileManager.default.removeItem(atPath: home.path) }
  let config: JSON = [
    "ssh": .string(LinkBench.stub),
    "hosts": [
      "mini": ["kind": "ssh", "destination": .string(LinkBench.destination)],
      "boxes": ["kind": "hogli", "layout": "perSession"],
      "typo": ["kind": "hogli"],
    ],
  ]
  try Data(config.text.utf8).write(to: URL(fileURLWithPath: home.config))
  let service = try Service(home: home, sbPath: "/usr/bin/true")
  defer { service.hostLinks.values.forEach { $0.disconnect() } }
  try body(service, home)
}

@Suite struct HostLinkMachineTests {
  @Test(
    .timeLimit(.minutes(1)),
    arguments: [
      ("nohost", "no host named nohost"),
      ("typo", "typo is not usable: a hogli host with the shared layout needs a workspace"),
      ("boxes", "boxes has a link per box, which this version does not open"),
      ("local", "no host named local"),
    ])
  func theMachineOfAHostWithNoLinkThrows(name: String, message: String) throws {
    try withHostService { service, _ in
      do {
        _ = try service.machine(onHost: name)
        Issue.record("\(name) has a machine")
      } catch {
        #expect("\(error)".contains(message), "\(error)")
      }
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func theMachineOfAHostThatIsNotConnectedNeverAnswersFromThisMac() throws {
    try withHostService { service, home in
      let machine = try service.machine(onHost: "mini")
      let file = "\(home.path)/present.txt"
      let made = "\(home.path)/made"
      try Data("here".utf8).write(to: URL(fileURLWithPath: file))

      #expect(throws: (any Error).self) { try machine.run("/bin/sh", ["-c", #": >"$1""#, "sb", "\(home.path)/ran"]) }
      #expect(throws: (any Error).self) { try machine.createFolder(made) }
      #expect(machine.exists(file) == false)
      #expect(machine.isFolder(home.path) == false)
      #expect(machine.read(file, from: 0, count: nil) == nil)
      #expect(machine.size(file) == nil)
      #expect(machine.modified(file) == nil)
      #expect(machine.list(home.path).isEmpty)
      #expect(LocalMachine().exists(file))
      #expect(kindOfFile(at: "\(home.path)/ran") == nil)
      #expect(kindOfFile(at: made) == nil)
      #expect(kindOfFile(at: "\(home.path)/ssh-stub") == nil)
      #expect(service.hostLinks["mini"]?.status.state == .disconnected)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func theMachineOfAConnectedHostRunsOnTheHost() throws {
    try withHostService { service, home in
      let machine = try service.machine(onHost: "mini")
      let link = try #require(service.hostLinks["mini"])
      link.connect()
      let deadline = Date().addingTimeInterval(15)
      while link.status.state != .connected {
        if Date() > deadline { throw APIError("the link is \(link.status)") }
        Thread.sleep(forTimeInterval: 0.01)
      }

      let r = try machine.run("/bin/sh", ["-c", #"printf %s "$HOME""#])

      #expect(r.status == 0)
      #expect(r.stdout == "\(home.path)/ssh-stub/home")
      #expect(machine.isFolder("\(home.path)/ssh-stub/home"))
    }
  }
}

private final class ProbeResult<T>: @unchecked Sendable {
  var value: T
  init(_ value: T) { self.value = value }
}
