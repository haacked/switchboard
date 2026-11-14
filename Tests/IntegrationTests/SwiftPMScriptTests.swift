import Foundation
import SwitchboardCore
import Testing

/// One run of the fake swift: its arguments, and how many tickets the queue
/// folder held when it ran.
private struct SwiftCall: Equatable, CustomStringConvertible {
  var args: [String]
  var tickets: Int

  var description: String { "swift \(args) with \(tickets) tickets" }
}

/// A SlotQueue with a fake swift and a fake sysctl at the front of PATH. The
/// fake swift logs each call to a file and appends "swift" to the queue's
/// log, so the log shows whether it ran before or after a holder ended. For
/// --show-bin-path it prints a folder that does not exist. The fake sysctl
/// answers only hw.activecpu.
private final class ScriptRig {
  let queue: SlotQueue
  let bin: String
  let calls: String
  let cpus: Int

  init(cpus: Int = 18) throws {
    queue = try SlotQueue()
    bin = "\(queue.root)/fake bin"
    calls = "\(queue.root)/swift-calls"
    self.cpus = cpus
    try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
    try write(
      "swift",
      """
      #!/bin/sh
      {
        echo "--- tickets $(ls "$SB_BUILD_SLOTS_DIR" 2>/dev/null | grep -c '[.]ticket$')"
        for arg in "$@"; do printf '%s\\n' "$arg"; done
      } >> "$FAKE_SWIFT_CALLS"
      echo swift >> "$FAKE_SWIFT_EVENTS"
      for arg in "$@"; do
        if [ "$arg" = --show-bin-path ]; then printf '%s\\n' "$FAKE_SWIFT_BIN"; fi
      done
      exit 0
      """)
    try write(
      "sysctl",
      """
      #!/bin/sh
      case "$*" in
      "-n hw.activecpu") echo "$FAKE_CPUS" ;;
      "hw.activecpu") echo "hw.activecpu: $FAKE_CPUS" ;;
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

  func stop() { queue.stop() }

  func environment(_ extra: [String: String?] = [:]) -> [String: String] {
    var env = queue.environment(slots: "1")
    env["PATH"] = "\(bin):\(env["PATH"] ?? "/usr/bin:/bin")"
    env["FAKE_SWIFT_CALLS"] = calls
    env["FAKE_SWIFT_EVENTS"] = queue.log
    env["FAKE_SWIFT_BIN"] = "\(queue.root)/no such bin"
    env["FAKE_CPUS"] = String(cpus)
    for (key, value) in extra { env[key] = value }
    return env
  }

  /// Runs bin/lib/swiftpm and waits for it. This is the one place that
  /// names how the scripts reach it.
  func swiftpm(_ args: String..., env extra: [String: String?] = [:]) throws -> CommandResult {
    let path = Instance.root.appendingPathComponent("bin/lib/swiftpm").path
    return try runCommand(path, args, env: environment(extra), timeout: 60)
  }

  /// Runs a bash script that sources bin/lib/swift-testing.sh, as CI does.
  func sourcingSwiftTesting(_ body: String) throws -> CommandResult {
    let helper = Instance.root.appendingPathComponent("bin/lib/swift-testing.sh").path
    return try runCommand(
      "/bin/bash", ["-c", "set -euo pipefail\nsource \(shellQuote(helper))\n\(body)"], env: environment(),
      timeout: 60)
  }

  func run(
    _ script: String, _ args: [String] = [], env extra: [String: String?] = [:], timeout: Double = 120
  ) throws -> CommandResult {
    try runCommand(Instance.root.appendingPathComponent(script).path, args, env: environment(extra), timeout: timeout)
  }

  @discardableResult
  func start(_ script: String, _ args: [String] = [], env extra: [String: String?] = [:]) throws -> Process {
    try queue.launch(
      Self.id(script), Instance.root.appendingPathComponent(script).path, args, env: environment(extra))
  }

  static func id(_ script: String) -> String { script.replacingOccurrences(of: "/", with: "-") }

  func swiftCalls() -> [SwiftCall] {
    let text = (try? String(contentsOfFile: calls, encoding: .utf8)) ?? ""
    // Each argument is one line, so an empty argument is an empty line. The
    // last element is the empty text after the final newline.
    var lines = text.components(separatedBy: "\n")
    if lines.last == "" { lines.removeLast() }
    var result: [SwiftCall] = []
    for line in lines {
      if line.hasPrefix("--- tickets ") {
        result.append(SwiftCall(args: [], tickets: Int(line.dropFirst("--- tickets ".count)) ?? -1))
      } else if !result.isEmpty {
        result[result.count - 1].args.append(line)
      }
    }
    return result
  }

  /// Starts a helper that holds the only slot until the test releases "H".
  func holdTheSlot() throws {
    try queue.startHolder("H")
  }
}

private struct JobsCase: Sendable, CustomTestStringConvertible {
  var cpus: Int
  var value: String?
  var printed: String

  var testDescription: String { "cpus=\(cpus) SB_BUILD_JOBS=\(value.map { "'\($0)'" } ?? "unset")" }
}

@Suite(.blocking(timeLimit: .seconds(120))) struct SwiftPMScriptTests {
  @Test(arguments: zip([18, 4, 2, 1], [4, 4, 2, 1]))
  func buildCapsJobsAtFourOrTheCPUCount(_ cpus: Int, _ jobs: Int) throws {
    let rig = try ScriptRig(cpus: cpus)
    defer { rig.stop() }

    let r = try rig.swiftpm("build", "--product", "sb")

    #expect(r.status == 0, "\(r.stderr)")
    #expect(rig.swiftCalls().map(\.args) == [["build", "--jobs", "\(jobs)", "--product", "sb"]])
  }

  @Test func sbBuildJobsSetsTheJobsAboveTheCap() throws {
    let rig = try ScriptRig(cpus: 18)
    defer { rig.stop() }

    let r = try rig.swiftpm("build", env: ["SB_BUILD_JOBS": "6"])

    #expect(r.status == 0, "\(r.stderr)")
    #expect(rig.swiftCalls().map(\.args) == [["build", "--jobs", "6"]])
  }

  @Test func zeroBuildJobsPassesNoJobsFlag() throws {
    let rig = try ScriptRig(cpus: 18)
    defer { rig.stop() }

    let r = try rig.swiftpm("build", env: ["SB_BUILD_JOBS": "0"])

    #expect(r.status == 0, "\(r.stderr)")
    #expect(rig.swiftCalls().map(\.args) == [["build"]])
  }

  @Test(arguments: ["x", "1.5", "4x"])
  func aNonIntegerBuildJobsExitsTwoWithoutRunningSwift(_ value: String) throws {
    let rig = try ScriptRig()
    defer { rig.stop() }
    try rig.holdTheSlot()

    let r = try rig.swiftpm("build", env: ["SB_BUILD_JOBS": value])

    #expect(r.status == 2)
    #expect(r.stderr.contains("SB_BUILD_JOBS"), "\(r.stderr)")
    #expect(!r.stderr.contains(SlotQueue.waitingPrefix), "\(r.stderr)")
    #expect(rig.swiftCalls().isEmpty)
  }

  /// An empty SB_BUILD_JOBS counts as unset.
  @Test(arguments: [
    JobsCase(cpus: 18, value: nil, printed: "4"),
    JobsCase(cpus: 2, value: nil, printed: "2"),
    JobsCase(cpus: 1, value: nil, printed: "1"),
    JobsCase(cpus: 18, value: "", printed: "4"),
    JobsCase(cpus: 18, value: "6", printed: "6"),
    JobsCase(cpus: 18, value: "0", printed: "0"),
  ])
  fileprivate func jobsPrintsTheEffectiveJobCount(_ c: JobsCase) throws {
    let rig = try ScriptRig(cpus: c.cpus)
    defer { rig.stop() }

    let r = try rig.swiftpm("--jobs", env: ["SB_BUILD_JOBS": c.value])

    #expect(r.status == 0, "\(r.stderr)")
    #expect(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == c.printed, "\(r.stdout)")
  }

  @Test(arguments: ["x", "1.5", "4x", "-1"])
  func jobsRejectsABadJobCountWithExitTwo(_ value: String) throws {
    let rig = try ScriptRig()
    defer { rig.stop() }

    let r = try rig.swiftpm("--jobs", env: ["SB_BUILD_JOBS": value])

    #expect(r.status == 2)
    #expect(r.stdout == "", "\(r.stdout)")
    #expect(r.stderr == "bin/lib/swiftpm: SB_BUILD_JOBS must be a whole number, not '\(value)'\n", "\(r.stderr)")
    #expect(rig.swiftCalls().isEmpty)
  }

  /// bin/test asks for the count before a sharded run, which holds no slot.
  /// A live ticket fills the only slot, so a --jobs that queued would wait.
  @Test func jobsRunsNoSwiftAndTakesNoSlot() throws {
    let rig = try ScriptRig(cpus: 18)
    defer { rig.stop() }
    try rig.holdTheSlot()

    let r = try rig.swiftpm("--jobs")

    #expect(r.status == 0, "\(r.stderr)")
    #expect(!r.stderr.contains(SlotQueue.waitingPrefix), "\(r.stderr)")
    #expect(rig.swiftCalls().isEmpty, "\(rig.swiftCalls())")
    #expect(!rig.queue.logLines().contains("end H"))
  }

  /// swift test --skip-build accepts --jobs and ignores it.
  @Test func testWithSkipBuildGetsTheJobsFlag() throws {
    let rig = try ScriptRig(cpus: 18)
    defer { rig.stop() }

    let r = try rig.swiftpm("test", "--skip-build", "--filter", "X")

    #expect(r.status == 0, "\(r.stderr)")
    #expect(rig.swiftCalls().map(\.args) == [["test", "--jobs", "4", "--skip-build", "--filter", "X"]])
  }

  @Test func argumentsWithSpacesReachSwiftWhole() throws {
    let rig = try ScriptRig(cpus: 18)
    defer { rig.stop() }

    let r = try rig.swiftpm("build", "--scratch-path", "a b", "")

    #expect(r.status == 0, "\(r.stderr)")
    #expect(rig.swiftCalls().map(\.args) == [["build", "--jobs", "4", "--scratch-path", "a b", ""]])
  }

  /// CI's prebuild, bin/build, and bin/test must pass swift the same flags,
  /// or they stop sharing one build and the next one recompiles.
  @Test func buildTestsBinBuildAndBinTestPassSwiftTheSameFlags() throws {
    let rig = try ScriptRig(cpus: 18)
    defer { rig.stop() }

    let prebuild = try rig.sourcingSwiftTesting("build_tests")
    let build = try rig.run("bin/build")
    let test = try rig.run("bin/test", ["--all"])

    for r in [prebuild, build, test] { #expect(r.status == 0, "\(r.stderr)") }
    let calls = rig.swiftCalls().map(\.args)
    try #require(calls.count == 3, "\(calls)")
    #expect(Array(calls[0].prefix(4)) == ["build", "--jobs", "4", "--build-tests"])
    #expect(Array(calls[1].prefix(3)) == ["build", "--jobs", "4"])
    #expect(Array(calls[2].prefix(3)) == ["test", "--jobs", "4"])
    #expect(Array(calls[1].dropFirst(3)) == Array(calls[0].dropFirst(4)))
    #expect(Array(calls[2].dropFirst(3)) == Array(calls[0].dropFirst(4)))
  }

  @Test func binBuildPassesItsArgumentsToSwiftBuild() throws {
    let rig = try ScriptRig(cpus: 18)
    defer { rig.stop() }

    let r = try rig.run("bin/build", ["--product", "sb", "--scratch-path", "a b"])

    #expect(r.status == 0, "\(r.stderr)")
    let call = try #require(rig.swiftCalls().first)
    #expect(call.args.first == "build")
    #expect(Array(call.args.suffix(4)) == ["--product", "sb", "--scratch-path", "a b"])
  }

  /// bin/bundle stops after the fake swift prints a bin folder with no sb in
  /// it, before it touches build/. The status is not part of the check.
  @Test func bundleBuildsWithTheJobsFlagAndAsksForTheBinPathWithout() throws {
    let rig = try ScriptRig(cpus: 18)
    defer { rig.stop() }

    _ = try rig.run("bin/bundle")

    let calls = rig.swiftCalls().map(\.args)
    #expect(calls.first == ["build", "--jobs", "4", "-c", "release"], "\(calls)")
    let binPath = calls.filter { $0.contains("--show-bin-path") }
    #expect(binPath == [["build", "-c", "release", "--show-bin-path"]], "\(calls)")
  }

  /// The script's waiting line shows that it queued, so the empty swift log
  /// before the release is not a race.
  @Test(arguments: ["bin/test", "bin/build", "bin/bundle"])
  func aScriptWaitsForTheHeldSlotBeforeItRunsSwift(_ script: String) throws {
    let rig = try ScriptRig()
    defer { rig.stop() }
    try rig.holdTheSlot()
    let id = ScriptRig.id(script)

    let p = try rig.start(script)
    try rig.queue.waitFor("\(script) to wait") { rig.queue.stderr(id).contains(SlotQueue.waiting(1)) }

    #expect(rig.swiftCalls().isEmpty)
    rig.queue.release("H")
    _ = try rig.queue.waitForExit(id)
    let events = rig.queue.logLines().map { $0.split(separator: " ").prefix(2).joined(separator: " ") }
    #expect(Array(events.prefix(3)) == ["start H", "end H", "swift"], "\(events)")
    #expect(rig.swiftCalls().first?.tickets == 1, "\(rig.swiftCalls())")
    if script != "bin/bundle" { #expect(p.terminationStatus == 0, "\(rig.queue.stderr(id))") }
  }

  @Test func binTestInsideALiveHeldSlotRunsAtOnceWithoutASecondTicket() throws {
    let rig = try ScriptRig()
    defer { rig.stop() }
    try rig.holdTheSlot()
    let held = try rig.queue.held("H")

    let r = try rig.run("bin/test", ["--filter", "X"], env: ["SB_BUILD_SLOT_HELD": held])

    #expect(r.status == 0, "\(r.stderr)")
    #expect(!r.stderr.contains(SlotQueue.waitingPrefix), "\(r.stderr)")
    let calls = rig.swiftCalls()
    #expect(calls.count == 1, "\(calls)")
    #expect(calls.first?.tickets == 1, "\(calls)")
    #expect(!rig.queue.logLines().contains("end H"))
  }

  /// Each value names no live ticket, as when bin/test inherits the variable
  /// from a daemon that outlived an earlier run.
  @Test(arguments: [DeadHeld.empty, .missingFile, .unlockedTicket, .nonTicketFile, .directory])
  func binTestQueuesWhenTheHeldSlotIsNotLive(_ shape: DeadHeld) throws {
    let rig = try ScriptRig()
    defer { rig.stop() }
    try rig.holdTheSlot()
    let id = ScriptRig.id("bin/test")

    try rig.start("bin/test", ["--filter", "X"], env: ["SB_BUILD_SLOT_HELD": try shape.value(in: rig.queue)])
    try rig.queue.waitFor("bin/test to wait") { rig.queue.stderr(id).contains(SlotQueue.waiting(1)) }

    #expect(rig.swiftCalls().isEmpty)
    rig.queue.release("H")
    #expect(try rig.queue.waitForExit(id).terminationStatus == 0, "\(rig.queue.stderr(id))")
    #expect(rig.swiftCalls().count == 1)
  }

  /// With the queue off, the helper runs the script without setting
  /// SB_BUILD_SLOT_HELD. The script's check must still pass, or the script
  /// re-runs itself under the helper forever. A live ticket fills the only
  /// slot, so a script that queued would wait instead.
  @Test(arguments: ["bin/test", "bin/build"])
  func aScriptRunsOnceWithTheQueueOff(_ script: String) throws {
    let rig = try ScriptRig()
    defer { rig.stop() }
    try rig.holdTheSlot()

    let r = try rig.run(script, ["--filter", "X"], env: ["SB_BUILD_SLOTS": "0"], timeout: 30)

    #expect(r.status == 0, "\(r.stderr)")
    #expect(rig.swiftCalls().count == 1, "\(rig.swiftCalls())")
    #expect(!rig.queue.logLines().contains("end H"))
  }
}
