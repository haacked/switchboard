import Foundation
import SwitchboardCore
import Testing

/// One run of the fake swift: its name, its arguments, and how many tickets
/// the queue folder held when it ran.
private struct ShardCall: Equatable, CustomStringConvertible {
  var id: String
  var args: [String]
  var tickets: Int

  var kind: String { id == "build" || id == "list" ? id : "test" }

  var description: String { "\(id): swift \(args) with \(tickets) tickets" }
}

/// A copy of the repo's bin/ folder next to an empty .build folder, with a
/// fake swift and a fake sysctl at the front of PATH. bin/test --shards runs
/// `rm -rf .build-shards` in the folder above its own bin/, so the tests run
/// only this copy. Running the repo's own bin/test --shards in CI would delete
/// the clones that the running shards use.
///
/// The fake swift answers `swift test list` with `tests`. Every other call
/// logs "start <id> <pid>" and "end <id>" to the queue's log, so SlotQueue
/// reads the order of the calls. The id of the build is "build". The id of a
/// test call joins the suites that its --filter matches with "+", such as
/// "AlphaTests". With FAKE_SWIFT_HOLD set, a test call waits until the test
/// creates go.<id> or go.all, and then exits 1 when fail.<id> exists. It
/// writes its SB_BUILD_SLOT_HELD to held.<id> and its parent's pid to
/// ppid.<id>. The fake sysctl reports no load, because bin/test waits for the
/// load to drop below the CPU count before it runs MeasureTests.
private final class ShardRig {
  static let tests = [
    "IntegrationTests.AlphaTests/a()",
    "IntegrationTests.BetaTests/b()",
    "IntegrationTests.MeasureTests/m()",
    "SwitchboardCoreTests.CoreTests/c()",
  ]
  /// With --shards 2, shards 0, 1, and 2 run Alpha, Beta, and Core at once,
  /// and then MeasureTests runs alone.
  static let parallelShards = ["AlphaTests", "BetaTests", "CoreTests"]
  static let shardIds = parallelShards + ["MeasureTests"]
  static let id = "bin-test"
  static let limitsPrefix = "bin/test: build slots:"
  static let warning = "bin/test: warning:"

  let queue: SlotQueue
  let repo: String
  let bin: String
  let calls: String
  let testList: String

  init() throws {
    queue = try SlotQueue()
    repo = "\(queue.root)/repo"
    bin = "\(queue.root)/fake bin"
    calls = "\(queue.root)/swift-calls"
    testList = "\(queue.root)/tests"
    let files = FileManager.default
    try files.createDirectory(atPath: repo, withIntermediateDirectories: true)
    try files.copyItem(atPath: Instance.root.appendingPathComponent("bin").path, toPath: "\(repo)/bin")
    try files.createDirectory(atPath: "\(repo)/.build", withIntermediateDirectories: true)
    try files.createDirectory(atPath: bin, withIntermediateDirectories: true)
    try (Self.tests.joined(separator: "\n") + "\n").write(toFile: testList, atomically: false, encoding: .utf8)
    try write(
      "swift",
      """
      #!/bin/sh
      filter= prev=
      for arg in "$@"; do
        if [ "$prev" = --filter ]; then filter=$arg; fi
        prev=$arg
      done
      if [ "$1" = build ]; then
        id=build
      elif [ "$1" = test ] && [ "${2-}" = list ]; then
        id=list
      else
        id=$(grep -E "$filter" "$FAKE_SWIFT_TESTS" | sed 's|/.*||; s|.*[.]||' | sort -u | paste -sd+ -)
        [ -n "$id" ] || id=test.$$
      fi
      {
        echo "--- $id $(ls "$SB_BUILD_SLOTS_DIR" 2>/dev/null | grep -c '[.]ticket$')"
        for arg in "$@"; do printf '%s\\n' "$arg"; done
      } >> "$FAKE_SWIFT_CALLS"
      printf '%s' "${SB_BUILD_SLOT_HELD-}" > "$FAKE_SWIFT_DIR/held.$id"
      echo "$PPID" > "$FAKE_SWIFT_DIR/ppid.$id"
      if [ "$id" = list ]; then
        cat "$FAKE_SWIFT_TESTS"
        exit 0
      fi
      echo "start $id $$" >> "$FAKE_SWIFT_EVENTS"
      if [ -n "${FAKE_SWIFT_HOLD-}" ] && [ "$id" != build ]; then
        while [ ! -e "$FAKE_SWIFT_DIR/go.$id" ] && [ ! -e "$FAKE_SWIFT_DIR/go.all" ] &&
          [ ! -e "$FAKE_SWIFT_DIR/fail.$id" ]; do
          sleep 0.05
        done
      fi
      if [ "$1" = test ] && [ -n "$filter" ]; then
        echo "Test run with $(grep -c -E "$filter" "$FAKE_SWIFT_TESTS" || true) tests passed"
      fi
      echo "end $id" >> "$FAKE_SWIFT_EVENTS"
      if [ -e "$FAKE_SWIFT_DIR/fail.$id" ]; then exit 1; fi
      exit 0
      """)
    try write(
      "sysctl",
      """
      #!/bin/sh
      case "$*" in
      "-n hw.activecpu") echo "$FAKE_CPUS" ;;
      "-n vm.loadavg") echo "{ 0.00 0.00 0.00 }" ;;
      *) exec /usr/sbin/sysctl "$@" ;;
      esac
      """)
  }

  private func write(_ name: String, _ script: String) throws {
    let path = "\(bin)/\(name)"
    guard
      FileManager.default.createFile(
        atPath: path, contents: Data(script.utf8), attributes: [.posixPermissions: 0o755])
    else { throw TestError(description: "could not write \(path)") }
  }

  /// Releases every held call before SlotQueue.stop kills what still runs,
  /// because SlotQueue releases only the ids that it launched.
  func stop() {
    FileManager.default.createFile(atPath: "\(queue.root)/go.all", contents: nil)
    queue.stop()
  }

  func environment(_ extra: [String: String?] = [:]) -> [String: String] {
    var env = queue.environment(slots: "1")
    env["CI"] = nil
    env["PATH"] = "\(bin):\(env["PATH"] ?? "/usr/bin:/bin")"
    env["FAKE_SWIFT_CALLS"] = calls
    env["FAKE_SWIFT_EVENTS"] = queue.log
    env["FAKE_SWIFT_DIR"] = queue.root
    env["FAKE_SWIFT_TESTS"] = testList
    env["FAKE_CPUS"] = "18"
    for (key, value) in extra { env[key] = value }
    return env
  }

  /// The copy's bin/test. It is never the repo's own, for the reason above.
  private func script() throws -> String {
    let path = "\(repo)/bin/test"
    try #require(!real(path).hasPrefix(real(Instance.root.path) + "/"), "\(path) is in the repo")
    return path
  }

  /// Runs the copy's bin/test and waits for it. SB_BUILD_SLOTS_DIR always
  /// stays in the environment, so the runs never join the machine's queue.
  func run(_ args: [String], env extra: [String: String?] = [:], timeout: Double = 90) throws -> CommandResult {
    try runCommand(script(), args, env: environment(extra), timeout: timeout)
  }

  /// Starts the copy's bin/test without waiting. Its output goes to files, so
  /// a fake swift that outlives its helper and keeps a pipe open can't stall
  /// the test.
  @discardableResult
  func start(_ args: [String], env extra: [String: String?] = [:]) throws -> Process {
    try queue.launch(Self.id, script(), args, env: environment(extra))
  }

  /// The stdout and stderr of the started bin/test. The shards' output,
  /// including their helpers' waiting lines, reaches bin/test's stdout.
  func output() -> String {
    let out = (try? String(contentsOfFile: queue.outPath(Self.id), encoding: .utf8)) ?? ""
    return out + queue.stderr(Self.id)
  }

  /// How many waiting lines the started bin/test's output shows.
  func waitingLines() -> Int {
    output().split(separator: "\n").filter { $0.contains(SlotQueue.waitingPrefix) }.count
  }

  func swiftCalls() -> [ShardCall] {
    let text = (try? String(contentsOfFile: calls, encoding: .utf8)) ?? ""
    var lines = text.components(separatedBy: "\n")
    if lines.last == "" { lines.removeLast() }
    var result: [ShardCall] = []
    for line in lines {
      if line.hasPrefix("--- ") {
        let words = line.dropFirst(4).split(separator: " ")
        result.append(
          ShardCall(id: words.first.map(String.init) ?? "", args: [], tickets: words.last.flatMap { Int($0) } ?? -1))
      } else if !result.isEmpty {
        result[result.count - 1].args.append(line)
      }
    }
    return result
  }

  /// The calls that compile or run tests, without `swift test list`.
  func slotCalls() -> [ShardCall] { swiftCalls().filter { $0.kind != "list" } }

  func shardCalls() -> [ShardCall] { swiftCalls().filter { $0.kind == "test" } }

  /// The ids of the test calls that started, in the order they started.
  func shardStarts() -> [(id: String, pid: pid_t)] { queue.starts().filter { $0.id != "build" } }

  func parentPid(_ id: String) throws -> pid_t {
    let text = try String(contentsOfFile: "\(queue.root)/ppid.\(id)", encoding: .utf8)
    return try #require(pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), "ppid.\(id): \(text)")
  }

  func fail(_ id: String) { FileManager.default.createFile(atPath: "\(queue.root)/fail.\(id)", contents: nil) }

  /// Waits until `count` test calls have started.
  func waitForShards(_ count: Int) throws {
    try queue.waitFor("\(count) shards to start\n\(output())") { shardStarts().count >= count }
  }

  /// Waits until the started bin/test's output shows `count` waiting lines.
  func waitForWaitingLines(_ count: Int) throws {
    try queue.waitFor("\(count) waiting lines\n\(output())") { waitingLines() >= count }
  }

  /// Releases each held call as it starts until bin/test exits.
  func releaseEveryCallUntilExit(_ p: Process) throws {
    try queue.waitFor("bin/test to exit\n\(output())", timeout: 60) {
      for start in queue.starts() { queue.release(start.id) }
      return !p.isRunning
    }
    p.waitUntilExit()
  }

  /// The lines of `text` that print the limits.
  static func limitsLines(_ text: String) -> [String] {
    text.split(separator: "\n").map(String.init).filter { $0.contains(limitsPrefix) }
  }
}

/// How bin/test runs: on one swift test process, or on shards.
private enum RunPath: String, CaseIterable, Sendable, CustomTestStringConvertible {
  case plain, shards

  var arguments: [String] { self == .plain ? ["--filter", "X"] : ["--shards", "2"] }

  var testDescription: String { rawValue }
}

/// The helpers' own tests cover how they read the variables. These cases
/// cover only the wording that bin/test adds.
private struct Limits: Sendable, CustomTestStringConvertible {
  var slots: String?
  var jobs: String?
  var line: String

  var testDescription: String { "SB_BUILD_SLOTS=\(slots ?? "unset") SB_BUILD_JOBS=\(jobs ?? "unset")" }

  static let numbers = Limits(slots: "2", jobs: "3", line: "bin/test: build slots: 2, compile jobs: 3")
  static let defaults = Limits(slots: nil, jobs: nil, line: "bin/test: build slots: 3, compile jobs: 4")
  static let zeros = Limits(slots: "0", jobs: "0", line: "bin/test: build slots: off, compile jobs: one per core")
}

/// How a shard ends without passing.
private enum ShardEnd: String, CaseIterable, Sendable, CustomTestStringConvertible {
  /// SIGKILL to the fake swift.
  case swiftKilled
  /// SIGKILL to the build-slot helper that runs the fake swift. The fake
  /// swift keeps running and stays held.
  case helperKilled
  /// The fake swift exits 1.
  case failed

  var testDescription: String { rawValue }
}

private struct WarningCase: Sendable, CustomTestStringConvertible {
  var arguments: [String]
  var ci: String?
  var warns: Bool

  var testDescription: String { "\(arguments.joined(separator: " ")) CI=\(ci ?? "unset")" }
}

/// bin/test --shards runs each shard as its own client of the build queue.
@Suite(.blocking(timeLimit: .seconds(240))) struct TestShardSlotTests {
  /// The waiting lines show that the two other parallel shards queued, so
  /// the single start before the release is not a race.
  @Test func oneSlotRunsTheBuildFirstAndThenOneShardAtATime() throws {
    let rig = try ShardRig()
    defer { rig.stop() }
    let p = try rig.start(["--shards", "2"], env: ["FAKE_SWIFT_HOLD": "1"])
    try rig.waitForShards(1)
    try rig.waitForWaitingLines(2)
    #expect(rig.shardStarts().count == 1, "\(rig.queue.logLines())")

    try rig.releaseEveryCallUntilExit(p)

    #expect(p.terminationStatus == 0, "\(rig.output())")
    let events = rig.queue.logLines()
    let firstTwo = events.prefix(2).map { $0.split(separator: " ").prefix(2).joined(separator: " ") }
    #expect(firstTwo == ["start build", "end build"], "\(events)")
    #expect(Set(rig.shardStarts().map(\.id)) == Set(ShardRig.shardIds), "\(events)")
    #expect(rig.queue.mostRunningAtOnce() == 1, "\(events)")
  }

  @Test func theBuildAndEachShardRunUnderTicketsOfTheirOwn() throws {
    let rig = try ShardRig()
    defer { rig.stop() }

    let r = try rig.run(["--shards", "2"])

    #expect(r.status == 0, "\(r.stderr)")
    let calls = rig.slotCalls()
    try #require(calls.map(\.id).sorted() == (["build"] + ShardRig.shardIds).sorted(), "\(calls)")
    let build = try #require(calls.first { $0.id == "build" })
    #expect(build.args.contains("--build-tests"), "\(build)")
    let held = try calls.map { try rig.queue.held($0.id) }
    #expect(held.allSatisfy { $0.hasSuffix(".ticket") }, "\(held)")
    #expect(Set(held).count == calls.count, "\(held)")
  }

  /// The waiting line of the third parallel shard shows that it queued, so
  /// the two starts before any release are not a race.
  @Test func twoSlotsRunTwoShardsAtOnce() throws {
    let rig = try ShardRig()
    defer { rig.stop() }
    let p = try rig.start(["--shards", "2"], env: ["FAKE_SWIFT_HOLD": "1", "SB_BUILD_SLOTS": "2"])
    try rig.waitForShards(2)
    try rig.waitForWaitingLines(1)
    #expect(rig.shardStarts().count == 2, "\(rig.queue.logLines())")

    try rig.releaseEveryCallUntilExit(p)

    #expect(p.terminationStatus == 0, "\(rig.output())")
    #expect(Set(rig.shardStarts().map(\.id)) == Set(ShardRig.shardIds))
    #expect(rig.queue.mostRunningAtOnce() == 2, "\(rig.queue.logLines())")
  }

  /// CI runs the shards with the queue off, so all three parallel shards run
  /// at once without tickets.
  @Test func theQueueOffRunsEveryParallelShardAtOnce() throws {
    let rig = try ShardRig()
    defer { rig.stop() }
    let p = try rig.start(["--shards", "2"], env: ["FAKE_SWIFT_HOLD": "1", "SB_BUILD_SLOTS": "0"])
    try rig.waitForShards(ShardRig.parallelShards.count)

    try rig.releaseEveryCallUntilExit(p)

    #expect(p.terminationStatus == 0, "\(rig.output())")
    #expect(rig.queue.mostRunningAtOnce() == ShardRig.parallelShards.count, "\(rig.queue.logLines())")
    #expect(rig.waitingLines() == 0, "\(rig.output())")
    let calls = rig.slotCalls()
    #expect(calls.allSatisfy { $0.tickets == 0 }, "\(calls)")
    for call in calls { #expect(try rig.queue.held(call.id) == "", "\(call.id)") }
  }

  /// The first shard to start is one of the three parallel shards, so the
  /// next one starts only when the first one's slot frees. A killed helper
  /// leaves its fake swift held, so the next start shows that the helper's
  /// death freed the slot. The orphan keeps bin/test's pipe to tee open until
  /// the release.
  @Test(arguments: ShardEnd.allCases)
  fileprivate func aShardThatEndsWithoutPassingFreesItsSlotAndBinTestFails(_ end: ShardEnd) throws {
    let rig = try ShardRig()
    defer { rig.stop() }
    let p = try rig.start(["--shards", "2"], env: ["FAKE_SWIFT_HOLD": "1"])
    try rig.waitForShards(1)
    try rig.waitForWaitingLines(2)
    let first = try #require(rig.shardStarts().first)
    try #require(ShardRig.parallelShards.contains(first.id), "\(first.id)")

    switch end {
    case .swiftKilled:
      kill(first.pid, SIGKILL)
    case .helperKilled:
      let helper = try rig.parentPid(first.id)
      let command = try runCommand("/bin/ps", ["-ww", "-p", "\(helper)", "-o", "command="])
      try #require(command.stdout.contains("build-slot.py"), "parent of \(first.id): \(command.stdout)")
      kill(helper, SIGKILL)
    case .failed:
      rig.fail(first.id)
    }
    try rig.waitForShards(2)
    if end == .helperKilled {
      #expect(!rig.queue.logLines().contains("end \(first.id)"), "the orphan should still be held")
    }
    try rig.releaseEveryCallUntilExit(p)

    #expect(p.terminationStatus != 0, "\(rig.output())")
    #expect(Set(rig.shardCalls().map(\.id)) == Set(ShardRig.shardIds), "\(rig.swiftCalls())")
  }

  /// With one slot and H holding it, a shard that took a ticket of its own
  /// would wait for H forever, and the run's timeout would end it.
  @Test func shardsInsideALiveHeldSlotRunWithoutNewTickets() throws {
    let rig = try ShardRig()
    defer { rig.stop() }
    try rig.queue.startHolder("H")
    let held = try rig.queue.held("H")

    let r = try rig.run(["--shards", "2"], env: ["SB_BUILD_SLOT_HELD": held], timeout: 60)

    #expect(r.status == 0, "\(r.stderr)")
    #expect(!(r.stdout + r.stderr).contains(SlotQueue.waitingPrefix), "\(r.stdout)\(r.stderr)")
    let calls = rig.slotCalls()
    #expect(calls.map(\.id).sorted() == (["build"] + ShardRig.shardIds).sorted(), "\(calls)")
    #expect(calls.allSatisfy { $0.tickets == 1 }, "\(calls)")
    for call in calls { #expect(try rig.queue.held(call.id) == held, "\(call.id)") }
    #expect(!rig.queue.logLines().contains("end H"))
  }

  @Test(
    arguments: zip(
      [RunPath.plain, .plain, .plain, .shards], [Limits.numbers, .defaults, .zeros, .numbers]))
  fileprivate func binTestPrintsTheLimitsOnceOnStderr(_ path: RunPath, _ limits: Limits) throws {
    let rig = try ShardRig()
    defer { rig.stop() }

    let r = try rig.run(path.arguments, env: ["SB_BUILD_SLOTS": limits.slots, "SB_BUILD_JOBS": limits.jobs])

    #expect(r.status == 0, "\(r.stderr)")
    #expect(ShardRig.limitsLines(r.stderr) == [limits.line], "\(r.stderr)")
    #expect(ShardRig.limitsLines(r.stdout).isEmpty, "\(r.stdout)")
  }

  /// H holds the only slot, so the plain run waits for it.
  @Test func aPlainRunPrintsTheLimitsBeforeItWaitsForASlot() throws {
    let rig = try ShardRig()
    defer { rig.stop() }
    try rig.queue.startHolder("H")
    let p = try rig.start(RunPath.plain.arguments)
    try rig.waitForWaitingLines(1)

    let lines = rig.queue.stderrLines(ShardRig.id)
    let limits = try #require(lines.firstIndex { $0.contains(ShardRig.limitsPrefix) }, "\(lines)")
    let waiting = try #require(lines.firstIndex { $0.contains(SlotQueue.waitingPrefix) }, "\(lines)")
    #expect(limits < waiting, "\(lines)")

    try rig.releaseEveryCallUntilExit(p)

    #expect(p.terminationStatus == 0, "\(rig.output())")
    #expect(ShardRig.limitsLines(rig.output()).count == 1, "\(rig.output())")
  }

  /// H holds the only slot, so a run that checked the limits inside a slot
  /// would wait for H until its timeout.
  @Test(arguments: RunPath.allCases, ["SB_BUILD_SLOTS", "SB_BUILD_JOBS"])
  fileprivate func aBadLimitStopsBinTestBeforeSwiftRuns(_ path: RunPath, _ variable: String) throws {
    let rig = try ShardRig()
    defer { rig.stop() }
    try rig.queue.startHolder("H")

    let r = try rig.run(path.arguments, env: [variable: "x"], timeout: 30)

    #expect(r.status != 0)
    #expect(r.stderr.contains("\(variable) must be a whole number"), "\(r.stderr)")
    #expect(!(r.stdout + r.stderr).contains(SlotQueue.waitingPrefix), "\(r.stdout)\(r.stderr)")
    #expect(rig.swiftCalls().isEmpty, "\(rig.swiftCalls())")
  }

  @Test(arguments: [["--shards"], ["--shards", "--force-shards", "2"], ["--shards", "2", "--filter", "X"]])
  func aMalformedShardsCallPrintsTheUsageAndRunsNothing(_ arguments: [String]) throws {
    let rig = try ShardRig()
    defer { rig.stop() }

    let r = try rig.run(arguments)

    #expect(r.status == 2, "\(r.stderr)")
    #expect(r.stderr.contains("usage: bin/test --shards N [--force-shards]"), "\(r.stderr)")
    #expect(rig.swiftCalls().isEmpty, "\(rig.swiftCalls())")
  }

  @Test func anEmptyShardCountExitsTwoBeforeSwiftRuns() throws {
    let rig = try ShardRig()
    defer { rig.stop() }

    let r = try rig.run(["--shards", ""], env: ["CI": "true"])

    #expect(r.status == 2, "\(r.stderr)")
    #expect(r.stderr.contains("--shards needs a positive count"), "\(r.stderr)")
    #expect(rig.swiftCalls().isEmpty, "\(rig.swiftCalls())")
  }

  @Test(arguments: [
    WarningCase(arguments: ["--shards", "2"], ci: nil, warns: true),
    WarningCase(arguments: ["--shards", "2"], ci: "true", warns: false),
    WarningCase(arguments: ["--shards", "2", "--force-shards"], ci: nil, warns: false),
    WarningCase(arguments: RunPath.plain.arguments, ci: nil, warns: false),
  ])
  fileprivate func shardsWarnOnlyOutsideCIWithoutForceShards(_ c: WarningCase) throws {
    let rig = try ShardRig()
    defer { rig.stop() }

    let r = try rig.run(c.arguments, env: ["CI": c.ci])

    #expect(r.status == 0, "\(r.stderr)")
    #expect((r.stdout + r.stderr).contains(ShardRig.warning) == c.warns, "\(r.stdout)\(r.stderr)")
    if c.arguments.first == "--shards" {
      #expect(Set(rig.shardCalls().map(\.id)) == Set(ShardRig.shardIds), "\(rig.swiftCalls())")
    }
  }
}
