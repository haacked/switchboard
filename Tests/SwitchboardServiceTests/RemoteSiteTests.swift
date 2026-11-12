import Foundation
import SwitchboardCore
import Testing

@testable import SwitchboardService

private let tmuxInstall = "tmux is not installed on mini. Install it there with `sudo apt-get install -y tmux`"

// MARK: The answers that these tests assume

/// The setup script's answer as these tests assume it: the fields in the order that the plan lists them, with a NUL
/// after each one. A tool that the host lacks is an empty field. An implementation that prints another layout
/// changes this one function.
private func setupAnswer(
  home: String = "/home/haacked", tmux: String = "/usr/bin/tmux", git: String = "/usr/bin/git",
  python: String = "/usr/bin/python3", shell: String = "/bin/bash", user: String = "haacked",
  lang: String = "C.UTF-8", clockNs: String = "1794377400000000000"
) -> Data {
  Data([home, tmux, git, python, shell, user, lang, clockNs].map { $0 + "\0" }.joined().utf8)
}

/// The batched read's answer as these tests assume it: tmux's exit status, tmux's output with its error text, ps's
/// exit status, and ps's output, with a NUL after each one. The last NUL shows that the answer is whole. An
/// implementation that prints another layout changes this one function.
private func batchedAnswer(tmux: (status: Int, output: String), ps: (status: Int, output: String)) -> Data {
  Data([String(tmux.status), tmux.output, String(ps.status), ps.output].map { $0 + "\0" }.joined().utf8)
}

/// The path with every symlink resolved, or the path itself when it does not exist.
private func resolved(_ path: String) -> String { SwitchboardCore.realPath(path) ?? path }

private func miniHost(_ extra: [String: JSON] = [:]) throws -> HostConfig {
  let base: [String: JSON] = ["kind": "ssh", "destination": .string(LinkBench.destination)]
  let parsed = HostConfig.parse(["mini": .object(base.merging(extra) { $1 })])
  return try #require(parsed.valid["mini"], "\(parsed.invalid)")
}

// MARK: The setup answer

/// `BoxFacts.parse` reads the setup script's answer. sbd refuses a home that it can't use as the base of every
/// path on the host, and a host that lacks a tool.
@Suite struct BoxFactsTests {
  private let now: Int64 = 1_794_377_400_250

  private func parse(_ answer: Data, host: HostConfig? = nil, epoch: Int = 3) throws -> BoxFacts {
    try BoxFacts.parse(answer, epoch: epoch, host: try host ?? miniHost(), now: now)
  }

  @Test func aGoodAnswerGivesEveryFact() throws {
    let facts = try parse(setupAnswer())

    #expect(
      facts
        == BoxFacts(
          epoch: 3, home: "/home/haacked", shell: "/bin/bash", user: "haacked", lang: "C.UTF-8", tmux: "/usr/bin/tmux",
          git: "/usr/bin/git", python: "/usr/bin/python3", clockOffsetMs: 250))
  }

  @Test func theEpochIsTheOneOfTheConnectionThatRanSetup() throws {
    #expect(try parse(setupAnswer(), epoch: 7).epoch == 7)
  }

  @Test(arguments: [
    ("1794377400250000000", Int64(0)), ("1794377399250000000", Int64(1000)), ("1794377460250000000", Int64(-60_000)),
  ])
  func theClockOffsetIsThisMacsClockMinusTheHosts(clockNs: String, offset: Int64) throws {
    #expect(try parse(setupAnswer(clockNs: clockNs)).clockOffsetMs == offset)
  }

  @Test func theHostsShellKeyWinsOverTheShellOfTheHost() throws {
    let facts = try parse(setupAnswer(shell: "/bin/bash"), host: try miniHost(["shell": "/usr/bin/fish"]))

    #expect(facts.shell == "/usr/bin/fish")
  }

  @Test func aShellKeyThatSetupFoundNoExecutableForIsRefused() throws {
    #expect {
      try parse(setupAnswer(shell: ""), host: try miniHost(["shell": "/bin/zhs"]))
    } throws: { "\($0)".contains("mini's shell key names \"/bin/zhs\"") }
  }

  @Test func aHostWithNoShellRunsBinSh() throws {
    #expect(try parse(setupAnswer(shell: "")).shell == "/bin/sh")
  }

  @Test func aHomeWithASpaceIsKept() throws {
    #expect(try parse(setupAnswer(home: "/Users/phil haack")).home == "/Users/phil haack")
  }

  @Test(arguments: ["", "home/haacked", "~", "~/x", "./home", "/home/haacked\n/tmp", "\n", "/home/haacked\n"])
  func aHomeThatIsEmptyRelativeOrHoldsANewlineIsRefused(home: String) throws {
    #expect(throws: (any Error).self) { try parse(setupAnswer(home: home)) }
  }

  @Test func aHostWithNoTmuxFailsWithTheInstallMessage() throws {
    do {
      _ = try parse(setupAnswer(tmux: ""))
      Issue.record("a host with no tmux gave facts")
    } catch {
      #expect("\(error)".contains(tmuxInstall), "\(error)")
    }
  }

  @Test(arguments: ["git", "python3"])
  func aHostThatLacksAToolFailsWithAMessageThatNamesTheToolAndTheHost(tool: String) throws {
    let answer = tool == "git" ? setupAnswer(git: "") : setupAnswer(python: "")

    do {
      _ = try parse(answer)
      Issue.record("a host with no \(tool) gave facts")
    } catch {
      #expect("\(error)".contains("\(tool) is not installed on mini"), "\(error)")
    }
  }

  @Test(arguments: ["tmux", "bin/git", "./python3"])
  func aToolPathThatIsNotAbsoluteIsRefused(path: String) throws {
    #expect(throws: (any Error).self) { try parse(setupAnswer(tmux: path)) }
  }

  @Test(arguments: ["", "soon", "17943774000000000001794377400000000000", "-5", "1794377400.5"])
  func aClockThatIsNotAWholeNumberOfNanosecondsIsRefused(clock: String) throws {
    #expect(throws: (any Error).self) { try parse(setupAnswer(clockNs: clock)) }
  }

  @Test func anEmptyAnswerIsRefused() throws {
    #expect(throws: (any Error).self) { try parse(Data()) }
  }

  @Test(arguments: [
    "Welcome to Ubuntu 24.04\n", "/home/haacked\n/usr/bin/tmux\n/usr/bin/git\n", "\0\0\0\0\0\0\0\0", "\u{0}",
  ])
  func garbageIsRefused(text: String) throws {
    #expect(throws: (any Error).self) { try parse(Data(text.utf8)) }
  }

  @Test func bytesThatAreNotTextAreRefused() throws {
    #expect(throws: (any Error).self) { try parse(Data([0xFF, 0xFE, 0x00, 0xC3, 0x28, 0x00])) }
  }

  /// A cut answer must never read as a shorter home or a missing tool.
  @Test func everyCutOfAGoodAnswerIsRefused() throws {
    let whole = setupAnswer()

    for length in 0..<whole.count {
      #expect(throws: (any Error).self, "the first \(length) bytes parsed") { try parse(whole.prefix(length)) }
    }
  }

  @Test func anAnswerWithFieldsAfterTheLastOneIsRefused() throws {
    #expect(throws: (any Error).self) { try parse(setupAnswer() + Data("extra\0".utf8)) }
  }
}

// MARK: The batched read's answer

/// `RemoteSite.parseBatchedRead` turns one answer into a snapshot. Only an answer whose two parts both ran, or
/// whose tmux part says that no server runs, is a snapshot.
@Suite struct RemoteSiteBatchedReadTests {
  /// `ps -A -o pid=,ppid=,pgid=,args=` as macOS prints it.
  static let macPs = """
        1     0     1 /sbin/launchd
      480     1   480 tmux -S /Users/haacked/.sb/tmux.sock -f /Users/haacked/.sb/tmux.conf new-session -d -s s1-claude
      501   480   501 /bin/zsh -l -i -c source "$SB_HOME/sessions/$SB_SESSION_ID/claude.sh"
      530   501   501 claude --session-id 6f1c0c5e-2c0f-4b0a-9a51-0d6f3a9e1b11
      502   480   502 -zsh
      977   502   977 tail -f /tmp/claude
    60114     1 60114 /System/Library/Frameworks/CoreServices.framework/Frameworks/Metadata.framework/Support/mdworker_shared -s mdworker -c MDSImporterWorker -m com.apple.mdworker.shared

    """

  /// The same command as procps-ng 4 prints it on Ubuntu 24.04, with a kernel thread, whose pgid is 0.
  static let procps = """
          1       0       1 /sbin/init
          2       0       0 [kthreadd]
       2011       2       0 [kworker/0:1-events]
        812       1     812 tmux -S /home/haacked/.sb/tmux.sock -f /home/haacked/.sb/tmux.conf new-session -d -s s1-claude -x 200 -y 50
        813     812     813 /bin/bash -l -i -c source "$SB_HOME/sessions/$SB_SESSION_ID/claude.sh"
        840     813     813 node /home/haacked/.local/bin/claude --resume 6f1c0c5e-2c0f-4b0a-9a51-0d6f3a9e1b11
        814     812     814 -bash
    4194304     814 4194304 sleep 600

    """

  static let macPanes = "s1-claude\t501\t0\t1\ns1-shell\t502\t0\t0\n"
  static let procpsPanes = "s1-claude\t813\t0\t0\ns1-shell\t814\t0\t0\n"

  private func parse(_ answer: Data) throws -> Service.Snapshot {
    try RemoteSite.parseBatchedRead(answer, claudeProgram: "claude")
  }

  @Test func aMacOSAnswerGivesThePanesTheProcessesAndTheClaudeOfEachSession() throws {
    let s = try parse(batchedAnswer(tmux: (0, Self.macPanes), ps: (0, Self.macPs)))

    #expect(s.panes.keys.sorted() == ["s1-claude", "s1-shell"])
    #expect(s.panes["s1-claude"]?.pid == 501)
    #expect(s.panes["s1-claude"]?.clients == 1)
    #expect(s.panes["s1-claude"]?.dead == false)
    #expect(s.claudePids == ["s1": 530])
    #expect(s.children[501]?.map(\.pid) == [530])
    #expect(s.children[501]?.first?.command == "claude --session-id 6f1c0c5e-2c0f-4b0a-9a51-0d6f3a9e1b11")
    #expect(s.children[1]?.map(\.pid).sorted() == [480, 60114])
    #expect(s.children.values.map(\.count).reduce(0, +) == 7)
  }

  @Test func aProcpsAnswerGivesThePanesTheProcessesAndTheClaudeOfEachSession() throws {
    let s = try parse(batchedAnswer(tmux: (0, Self.procpsPanes), ps: (0, Self.procps)))

    #expect(s.panes["s1-claude"]?.pid == 813)
    #expect(s.claudePids == ["s1": 840])
    #expect(s.children[813]?.first?.pgid == 813)
    #expect(
      s.children[813]?.first?.command
        == "node /home/haacked/.local/bin/claude --resume 6f1c0c5e-2c0f-4b0a-9a51-0d6f3a9e1b11")
    #expect(s.children[2]?.first?.command == "[kworker/0:1-events]")
    #expect(s.children[814]?.map(\.pid) == [4_194_304])
    #expect(s.children.values.map(\.count).reduce(0, +) == 8)
  }

  @Test func aDeadClaudePaneHasNoClaude() throws {
    let s = try parse(batchedAnswer(tmux: (0, "s1-claude\t501\t1\t0\n"), ps: (0, Self.macPs)))

    #expect(s.panes["s1-claude"]?.dead == true)
    #expect(s.claudePids.isEmpty)
  }

  @Test func aShellPaneHasNoClaudeThoughAProcessBelowItNamesClaude() throws {
    let s = try parse(batchedAnswer(tmux: (0, "s1-shell\t502\t0\t0\n"), ps: (0, Self.macPs)))

    #expect(s.claudePids.isEmpty)
  }

  @Test(arguments: [
    "no server running on /home/haacked/.sb/tmux.sock\n",
    "error connecting to /home/haacked/.sb/tmux.sock (No such file or directory)\n",
  ])
  func tmuxsReportThatNoServerRunsIsASnapshotWithNoPanes(report: String) throws {
    let s = try parse(batchedAnswer(tmux: (1, report), ps: (0, Self.procps)))

    #expect(s.panes.isEmpty)
    #expect(s.claudePids.isEmpty)
    #expect(s.children[813]?.map(\.pid) == [840])
  }

  @Test(arguments: [
    (1, "error connecting to /home/haacked/.sb/tmux.sock (Permission denied)\n"),
    (1, "/home/haacked/.sb/tmux.conf: No such file or directory\n"), (127, "sh: 1: /usr/bin/tmux: not found\n"),
    (1, ""), (143, ""), (1, RemoteSiteBatchedReadTests.procpsPanes),
  ])
  func anyOtherTmuxFailureIsNotASnapshot(status: Int, output: String) throws {
    #expect(throws: (any Error).self) { try parse(batchedAnswer(tmux: (status, output), ps: (0, Self.procps))) }
  }

  @Test(arguments: [1, 127, 137, 143])
  func aFailedPsIsNotASnapshot(status: Int) throws {
    #expect(throws: (any Error).self) { try parse(batchedAnswer(tmux: (0, Self.procpsPanes), ps: (status, ""))) }
    #expect(throws: (any Error).self) {
      try parse(batchedAnswer(tmux: (0, Self.procpsPanes), ps: (status, Self.procps)))
    }
  }

  @Test func aFailedPsIsNotASnapshotThoughNoTmuxServerRuns() throws {
    let report = "no server running on /home/haacked/.sb/tmux.sock\n"

    #expect(throws: (any Error).self) { try parse(batchedAnswer(tmux: (1, report), ps: (1, ""))) }
  }

  /// A cut answer would list fewer processes, and a session whose claude is missing from the list reads as stopped.
  @Test func everyCutOfAGoodAnswerIsRefused() throws {
    let whole = batchedAnswer(tmux: (0, Self.procpsPanes), ps: (0, Self.procps))

    for length in 0..<whole.count {
      #expect(throws: (any Error).self, "the first \(length) bytes parsed") { try parse(whole.prefix(length)) }
    }
  }

  @Test func everyCutOfANoServerAnswerIsRefused() throws {
    let whole = batchedAnswer(tmux: (1, "no server running on /home/haacked/.sb/tmux.sock\n"), ps: (0, Self.macPs))

    for length in 0..<whole.count {
      #expect(throws: (any Error).self, "the first \(length) bytes parsed") { try parse(whole.prefix(length)) }
    }
  }

  @Test(arguments: ["", "bash: ps: command not found\n", "zero\0\0zero\0\0", "0\0\0", "\0\0\0\0"])
  func garbageIsRefused(text: String) throws {
    #expect(throws: (any Error).self) { try parse(Data(text.utf8)) }
  }
}

// MARK: A site over the ssh stub

/// A `RemoteSite` over a `LinkBench`. The stub runs the host's commands on this Mac with HOME set to `boxHome`.
///
/// The host's tmux is a script that starts no server. For `list-panes` it prints the home's `panes` file, or fails
/// with the text of the home's `panes-error` file when that exists.
///
/// The host's shell finds `box-bin/ps` before `/bin/ps`. It runs `/bin/ps`. A `ps -A` then runs the home's
/// `after-read` script once, after it printed. Any other `ps` first runs the home's `before-check` script once.
///
/// With `scripts`, each `/bin/sh -c` command that sbd sends runs `box-bin/sh` in place of `/bin/sh`. It exits
/// with the status in the home's `script-status` file, or runs until a signal ends it while the home's
/// `script-hangs` file exists, and runs `/bin/sh` otherwise. The host's shell also finds `box-bin/sleep`, which
/// ends after 0.2 s while the home's `short-timeouts` file exists, so a command's timeout ends it then. The
/// script that lists a folder prints the home's `box-list` file when that exists. The host's shell is then two
/// processes, and killing the master does not close the connection, so a test that drops it leaves `scripts` off.
final class SiteBench {
  let bench: LinkBench
  let host: HostConfig
  let site: RemoteSite
  /// Every call that the site's machine sent to the link.
  let sent = CallRecorder.Tap()
  private var processes: [Process] = []
  private var strays: [Int] = []

  var home: String { bench.home.path }
  var boxHome: String { "\(home)/ssh-stub/home" }
  var link: HostLink { bench.link }

  /// `environment` is a shell prefix of the host's shell, such as `HOME= `.
  init(
    host extra: [String: JSON] = [:], scripts: Bool = false, environment: @escaping (String) -> String = { _ in "" }
  ) throws {
    bench = try LinkBench(ssh: { layout in
      let bin = "\(layout.home)/box-bin"
      try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
      try SiteBench.write(
        """
        #!/bin/sh
        d=\(shellQuote(layout.home))
        if [ -f "$d/script-status" ]; then exit "$(cat "$d/script-status")"; fi
        if [ -f "$d/script-hangs" ]; then exec /bin/sleep 300; fi
        case $2 in
        'cd -- "$1"'*) if [ -f "$d/box-list" ]; then cat "$d/box-list"; exit 0; fi ;;
        esac
        exec /bin/sh "$@"

        """, to: "\(bin)/sh")
      try SiteBench.write(
        """
        #!/bin/sh
        if [ -f \(shellQuote(layout.home))/short-timeouts ]; then exec /bin/sleep 0.2; fi
        exec /bin/sleep "$@"

        """, to: "\(bin)/sleep")
      try SiteBench.write(
        """
        #!/bin/sh
        d=\(shellQuote(layout.home))
        case " $* " in
        *" -A "*)
          /bin/ps "$@"
          s=$?
          if [ -f "$d/after-read" ]; then
            mv "$d/after-read" "$d/after-read.ran"
            /bin/sh "$d/after-read.ran" >/dev/null 2>&1
          fi
          exit $s
          ;;
        esac
        if [ -f "$d/before-check" ]; then
          mv "$d/before-check" "$d/before-check.ran"
          /bin/sh "$d/before-check.ran" >/dev/null 2>&1
        fi
        exec /bin/ps "$@"

        """, to: "\(bin)/ps")
      try SiteBench.write(
        """
        #!/bin/sh
        d=\(shellQuote(layout.home))
        case " $* " in
        *" list-panes "*)
          if [ -f "$d/panes-error" ]; then cat "$d/panes-error" >&2; exit 1; fi
          cat "$d/panes" 2>/dev/null
          ;;
        esac
        exit 0

        """, to: "\(layout.home)/fake-tmux")
      let shell = "\(environment(layout.home))PATH=\(shellQuote(bin)):/usr/bin:/bin"
      guard scripts else { return sshWrapper(layout, command: "\(shell) exec /bin/sh") }
      // A command's line is `sb_run <number> '<timeout>' '<program>' …`.
      let swap = "s|^\\(sb_run [0-9]* '[0-9.]*' \\)'/bin/sh' '-c' |\\1'\(bin)/sh' '-c' |"
      return sshWrapper(layout, command: "/usr/bin/sed -l -e \(shellQuote(swap)) | \(shell) /bin/sh")
    })
    let tmux: [String: JSON] = ["tmux": .string("\(bench.home.path)/fake-tmux")]
    host = try miniHost(tmux.merging(extra) { $1 })
    let sent = sent
    site = RemoteSite(link: bench.link, config: host, home: bench.home, tap: { sent.wrap($0) })
  }

  private static func write(_ script: String, to path: String) throws {
    try Data(script.utf8).write(to: URL(fileURLWithPath: path))
    chmod(path, 0o755)
  }

  func close() {
    for pid in strays where !LinkBench.ended(Int32(pid)) { kill(pid_t(pid), SIGKILL) }
    for p in processes {
      if p.isRunning { kill(p.processIdentifier, SIGKILL) }
      p.waitUntilExit()
    }
    bench.close()
  }

  /// Connects the link and runs setup on the connection.
  @discardableResult
  func ready() throws -> BoxFacts {
    try bench.connect()
    return try site.prepare()
  }

  /// Drops the connection and waits for the next one. The site has not run setup on it.
  func reconnect() throws {
    let master = try #require(bench.masters().last)
    bench.drop(master)
    try bench.waitFor(.unreachable)
    bench.tick()
    try bench.waitFor(.connected)
  }

  func set(_ file: String, _ text: String) throws {
    try Data(text.utf8).write(to: URL(fileURLWithPath: "\(home)/\(file)"))
  }

  /// The panes that the host's tmux lists.
  func setPanes(_ rows: [(name: String, pid: Int, dead: Bool)]) throws {
    try set("panes", rows.map { "\($0.name)\t\($0.pid)\t\($0.dead ? 1 : 0)\t0\n" }.joined())
  }

  /// A pane's process with one child that runs the command. `sleep` stands in for claude.
  struct Tree {
    var pane: Int
    var child: Int
  }

  func tree(_ command: String = "sleep 300") throws -> Tree {
    let marker = "\(home)/child.\(processes.count).pid"
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = [
      "-c", "\(command) & echo $! >\(shellQuote(marker)).tmp; mv \(shellQuote(marker)).tmp \(shellQuote(marker)); wait",
    ]
    p.standardInput = FileHandle.nullDevice
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try p.run()
    processes.append(p)
    var child: Int?
    try bench.wait("the pane's child to start") {
      child = Int((try? String(contentsOfFile: marker, encoding: .utf8))?.trimmingCharacters(in: .newlines) ?? "")
      return child != nil
    }
    let pid = try #require(child)
    strays.append(pid)
    return Tree(pane: Int(p.processIdentifier), child: pid)
  }

  func runs(_ pid: Int) -> Bool { !LinkBench.ended(Int32(pid)) }

  /// Waits a moment and says whether the process still runs. A signal that was sent has arrived by then.
  func stillRuns(_ pid: Int) -> Bool {
    Thread.sleep(forTimeInterval: 0.3)
    return runs(pid)
  }
}

extension CallRecorder {
  /// Collects the recording machines that a site wrapped around the machines it built.
  final class Tap: @unchecked Sendable {
    private let lock = NSLock()
    private var machines: [CallRecorder] = []

    func wrap(_ machine: any Machine) -> any Machine {
      let recording = CallRecorder(machine)
      lock.withLock { machines.append(recording) }
      return recording
    }

    var runs: [CallRecorder.Run] { lock.withLock { machines }.flatMap(\.runs) }
    var calls: [String] { lock.withLock { machines }.flatMap(\.calls) }
  }
}

private func withSite(
  host extra: [String: JSON] = [:], scripts: Bool = false, environment: @escaping (String) -> String = { _ in "" },
  _ body: (SiteBench) throws -> Void
) throws {
  let bench = try SiteBench(host: extra, scripts: scripts, environment: environment)
  defer { bench.close() }
  try body(bench)
}

/// Whether the error is `HostUnread` for mini.
private func isUnread(_ error: any Error) -> Bool { (error as? HostUnread)?.hostName == "mini" }

/// Puts a link to `target` at `path`, after it moves what is at `path` to `keeping`. It creates `target` and the
/// folder that holds `path` when they are missing.
func replaceWithLink(_ path: String, to target: String, keeping: String) throws {
  let files = FileManager.default
  try files.createDirectory(atPath: target, withIntermediateDirectories: true)
  try files.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
  if files.fileExists(atPath: path) { try files.moveItem(atPath: path, toPath: keeping) }
  try files.createSymbolicLink(atPath: path, withDestinationPath: target)
}

/// The paths inside the folder, sorted.
func paths(inside folder: String) throws -> [String] {
  try FileManager.default.subpathsOfDirectory(atPath: folder).sorted()
}

// MARK: Setup

@Suite struct RemoteSiteSetupTests {
  @Test(.timeLimit(.minutes(1)))
  func aNewSiteNamesItsHostAndHasNoFacts() throws {
    try withSite { b in
      #expect(b.site.hostName == "mini")
      #expect(b.site.facts == nil)
      #expect(b.site.setupError == nil)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func prepareThrowsOnALinkThatIsNotConnectedAndStartsNoProcess() throws {
    try withSite { b in
      #expect { try b.site.prepare() } throws: { isUnread($0) }
      #expect(b.site.facts == nil)
      #expect(b.bench.runs().isEmpty)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func prepareReadsTheFactsOfTheBox() throws {
    try withSite { b in
      let facts = try b.ready()

      #expect(resolved(facts.home) == resolved(b.boxHome))
      #expect(facts.home.hasPrefix("/"))
      #expect(facts.user == NSUserName())
      #expect(facts.tmux == "\(b.home)/fake-tmux")
      #expect(facts.git.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: facts.git))
      #expect((facts.git as NSString).lastPathComponent == "git")
      #expect(facts.python.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: facts.python))
      #expect((facts.python as NSString).lastPathComponent == "python3")
      #expect(facts.shell.hasPrefix("/"))
      #expect(abs(facts.clockOffsetMs) < 5_000)
      #expect(b.site.facts == facts)
      #expect(b.site.setupError == nil)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func theFactsBelongToTheConnectionThatRanSetup() throws {
    try withSite { b in
      let first = try b.ready()
      #expect(first.epoch == b.link.status.connection)

      try b.reconnect()
      #expect(b.site.facts == nil)
      let second = try b.site.prepare()

      #expect(second.epoch == b.link.status.connection)
      #expect(second.epoch > first.epoch)
      #expect(b.site.facts == second)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func theConnectionCounterGrowsEachTimeTheLinkConnects() throws {
    try withSite { b in
      let before = b.link.status.connection
      try b.bench.connect()
      let first = b.link.status.connection
      try b.reconnect()

      #expect(first == before + 1)
      #expect(b.link.status.connection == first + 1)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func prepareTwiceOnOneConnectionRunsSetupOnce() throws {
    try withSite { b in
      let first = try b.ready()
      let sent = b.sent.runs.count

      let second = try b.site.prepare()

      #expect(second == first)
      #expect(b.sent.runs.count == sent)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func theSetupCommandNamesATimeoutOfTwentySeconds() throws {
    try withSite { b in
      try b.ready()

      #expect(b.sent.runs.first?.timeout == 20)
      #expect(b.sent.runs.first?.executable == "/bin/sh")
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func setupCreatesTheBoxesFoldersForTheUserOnlyAndWritesTheTmuxConfig() throws {
    try withSite { b in
      try b.ready()

      for folder in [".sb", ".sb/bin", ".sb/sessions"] {
        let attributes = try FileManager.default.attributesOfItem(atPath: "\(b.boxHome)/\(folder)")
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700, "\(folder)")
        #expect(attributes[.type] as? FileAttributeType == .typeDirectory, "\(folder)")
      }
      #expect(
        try String(contentsOfFile: "\(b.boxHome)/.sb/tmux.conf", encoding: .utf8) == TerminalHost.configText)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func setupPointsTheBoxesAgentSocketAtTheConnectionsAgent() throws {
    try withSite(environment: { _ in "SSH_AUTH_SOCK=/tmp/sb-test-agent.sock " }) { b in
      try b.ready()

      #expect(
        try FileManager.default.destinationOfSymbolicLink(atPath: "\(b.boxHome)/.sb/agent.sock")
          == "/tmp/sb-test-agent.sock")
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func setupReplacesTheAgentSocketOfTheLastConnection() throws {
    try withSite(environment: { _ in "SSH_AUTH_SOCK=/tmp/sb-test-agent.sock " }) { b in
      try FileManager.default.createDirectory(atPath: "\(b.boxHome)/.sb", withIntermediateDirectories: true)
      try FileManager.default.createSymbolicLink(
        atPath: "\(b.boxHome)/.sb/agent.sock", withDestinationPath: "/tmp/sb-old-agent.sock")

      try b.ready()

      #expect(
        try FileManager.default.destinationOfSymbolicLink(atPath: "\(b.boxHome)/.sb/agent.sock")
          == "/tmp/sb-test-agent.sock")
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func setupMakesNoAgentSocketWhenTheConnectionHasNoAgent() throws {
    try withSite(environment: { _ in "unset SSH_AUTH_SOCK; " }) { b in
      try b.ready()

      #expect(kindOfFile(at: "\(b.boxHome)/.sb/agent.sock") == nil)
    }
  }

  /// A link at one of the box's folders would lead setup's writes, and its chmod, into the folder that it leads to.
  @Test(.timeLimit(.minutes(1)), arguments: [".sb", ".sb/bin", ".sb/sessions"])
  func aLinkAtOneOfTheBoxesFoldersFailsSetupAndChangesNothingWhereItLeads(linked: String) throws {
    try withSite { b in
      let target = "\(b.home)/elsewhere"
      try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)
      try Data("keep\n".utf8).write(to: URL(fileURLWithPath: "\(target)/canary"))
      chmod(target, 0o755)
      try replaceWithLink("\(b.boxHome)/\(linked)", to: target, keeping: "\(b.home)/moved")
      try b.bench.connect()

      #expect(throws: (any Error).self) { try b.site.prepare() }

      #expect(b.site.setupError?.contains("is a link") == true, "\(b.site.setupError ?? "nil")")
      #expect(try paths(inside: target) == ["canary"])
      let attributes = try FileManager.default.attributesOfItem(atPath: target)
      #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o755)
    }
  }

  /// The hook write runs after setup on each connect. A link that appears at the box's folder or its `bin` in
  /// between would lead the writes of the shim and the settings into the folder that it leads to.
  @Test(.timeLimit(.minutes(1)), arguments: [".sb", ".sb/bin"])
  func theHookWriteRefusesALinkAtTheBoxesFolderAndWritesNothingWhereItLeads(linked: String) throws {
    try withSite { b in
      let facts = try b.ready()
      let target = "\(b.home)/elsewhere"
      try FileManager.default.createDirectory(
        atPath: linked == ".sb" ? "\(target)/bin" : target, withIntermediateDirectories: true)
      let before = try paths(inside: target)
      try replaceWithLink("\(facts.home)/\(linked)", to: target, keeping: "\(b.home)/moved")

      let r = try b.site.machine.run(
        "/bin/sh", ["-c", RemoteSite.hookScript, "sb", facts.folder, "shim", "{}"], env: nil, input: nil,
        timeout: 20)

      #expect(r.status == 1, "\(r.stderr)")
      #expect(try paths(inside: target) == before)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func theHookWriteRefusesABinThatIsAFileAndLeavesTheFileAsItWas() throws {
    try withSite { b in
      let facts = try b.ready()
      let bin = "\(facts.folder)/bin"
      try FileManager.default.removeItem(atPath: bin)
      try Data("keep\n".utf8).write(to: URL(fileURLWithPath: bin))

      let r = try b.site.machine.run(
        "/bin/sh", ["-c", RemoteSite.hookScript, "sb", facts.folder, "shim", "{}"], env: nil, input: nil,
        timeout: 20)

      #expect(r.status == 1, "\(r.stderr)")
      #expect(FileManager.default.contents(atPath: bin) == Data("keep\n".utf8))
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func theHostsShellKeyIsTheShellOfTheFacts() throws {
    try withSite(host: ["shell": "/bin/dash"]) { b in
      let facts = try b.ready()

      #expect(facts.shell == "/bin/dash")
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func aHostWithNoShellKeyUsesTheShellOfTheBox() throws {
    try withSite(environment: { _ in "SHELL=/bin/ksh " }) { b in
      let facts = try b.ready()

      #expect(facts.shell == "/bin/ksh")
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func aHostWithNoTmuxFailsSetupWithTheInstallMessageAndStaysConnected() throws {
    try withSite(host: ["tmux": "/nonexistent/sb/tmux"]) { b in
      try b.bench.connect()

      do {
        _ = try b.site.prepare()
        Issue.record("setup passed on a host with no tmux")
      } catch {
        #expect("\(error)".contains(tmuxInstall), "\(error)")
      }
      #expect(b.site.facts == nil)
      #expect(b.site.setupError?.contains(tmuxInstall) == true, "\(b.site.setupError ?? "nil")")
      #expect(b.link.status.state == .connected)
    }
  }

  /// The `shell` key starts every Claude pane on the host, so setup refuses one that can't start there.
  @Test(.timeLimit(.minutes(1)), arguments: ["/nonexistent/sb/zsh", "/etc/hosts", "/bin", "zsh", "bin/sh"])
  func aShellKeyThatIsNotAnAbsolutePathToAnExecutableFileFailsSetupWithTheKeyAndTheHost(shell: String) throws {
    try withSite(host: ["shell": .string(shell)]) { b in
      try b.bench.connect()
      let refusal = "mini's shell key names \"\(shell)\", which is not an absolute path to an executable file on mini"

      #expect { try b.site.prepare() } throws: { "\($0)".contains(refusal) }

      #expect(b.site.facts == nil)
      #expect(b.site.setupError?.contains(refusal) == true, "\(b.site.setupError ?? "nil")")
      #expect(b.link.status.state == .connected)
    }
  }

  /// Makes the next setup wait in the box's `id` until the test removes the home's `setup-gate`. The setup has
  /// reached the box when the home holds `setup-waiting`. Each later setup runs at once.
  private func holdNextSetup(_ b: SiteBench) throws {
    try b.set("setup-gate", "")
    try b.set("hold-setup", "")
    let path = "\(b.home)/box-bin/id"
    try Data(
      """
      #!/bin/sh
      d=\(shellQuote(b.home))
      if [ -f "$d/hold-setup" ]; then
        rm -f "$d/hold-setup"
        : >"$d/setup-waiting"
        while [ -f "$d/setup-gate" ]; do /bin/sleep 0.05; done
      fi
      exec /usr/bin/id "$@"

      """.utf8
    ).write(to: URL(fileURLWithPath: path))
    chmod(path, 0o755)
  }

  /// The link drops while setup runs. The link connects again, and setup runs on the new connection, well within
  /// the wait.
  @Test(.timeLimit(.minutes(1)))
  func aLinkThatDropsDuringSetupIsReadyOnTheNextConnectionWithinTheWait() throws {
    try withSite { b in
      try holdNextSetup(b)
      defer { try? FileManager.default.removeItem(atPath: "\(b.home)/setup-gate") }
      let first = try b.bench.connect()
      let connection = b.link.status.connection
      let lock = NSLock()
      var outcome: Result<Void, any Error>?
      let finished = DispatchSemaphore(value: 0)
      let started = Date()
      Thread.detachNewThread {
        let r = Result { try b.site.awaitReady(seconds: 15) }
        lock.withLock { outcome = r }
        finished.signal()
      }
      try #require(waitUntil(seconds: 20) { FileManager.default.fileExists(atPath: "\(b.home)/setup-waiting") })

      b.bench.drop(first)

      #expect(finished.wait(timeout: .now() + 20) == .success)
      #expect(throws: Never.self) { try lock.withLock { outcome }?.get() }
      #expect(Date().timeIntervalSince(started) < 15)
      #expect(b.bench.masters().count >= 2)
      #expect(b.site.facts?.epoch == b.link.status.connection)
      #expect(b.site.facts?.epoch != connection)
    }
  }

  /// A setup that fails while its connection stays up fails at once and does not wait out the deadline.
  @Test(.timeLimit(.minutes(1)))
  func aSetupThatFailsWhileTheLinkStaysUpFailsAtOnce() throws {
    try withSite(host: ["tmux": "/nonexistent/sb/tmux"]) { b in
      try b.bench.connect()
      let started = Date()

      #expect { try b.site.awaitReady(seconds: 15) } throws: { "\($0)".contains(tmuxInstall) }

      #expect(Date().timeIntervalSince(started) < 7)
      #expect(b.bench.masters().count == 1)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func aFailedSetupRunsAgainOnTheNextCall() throws {
    try withSite(host: ["tmux": "/nonexistent/sb/tmux"]) { b in
      try b.bench.connect()
      #expect(throws: (any Error).self) { try b.site.prepare() }
      let sent = b.sent.runs.count

      #expect(throws: (any Error).self) { try b.site.prepare() }

      #expect(b.sent.runs.count > sent)
    }
  }

  /// The box's shell starts in the test's home, so a relative HOME names a folder there and not in the worktree.
  @Test(
    .timeLimit(.minutes(1)),
    arguments: [
      "HOME= ", "HOME=rel ", "HOME=./rel ", #"HOME="$(printf '%s\nb' "$PWD/a")" "#,
    ])
  func aBoxWhoseHomeIsEmptyRelativeOrHoldsANewlineFailsSetup(assignment: String) throws {
    try withSite(environment: { "cd \(shellQuote($0)) && \(assignment)" }) { b in
      try b.bench.connect()

      #expect(throws: (any Error).self) { try b.site.prepare() }

      #expect(b.site.facts == nil)
      #expect(b.site.setupError != nil)
      #expect(throws: (any Error).self) { try b.site.terminals() }
      let made = FileManager.default.enumerator(atPath: b.home)?.compactMap { $0 as? String } ?? []
      #expect(!made.contains { ($0 as NSString).lastPathComponent == ".sb" }, "setup made \(made)")
    }
  }
}

// MARK: Paths and members

@Suite struct RemoteSitePathTests {
  struct Unreached: Error {}

  @Test(.timeLimit(.minutes(1)))
  func expandTurnsATildeIntoTheBoxesHome() throws {
    try withSite { b in
      let home = try b.ready().home

      #expect(try b.site.expand("~") == home)
      #expect(try b.site.expand("~/x") == "\(home)/x")
      #expect(try b.site.expand("~/a b/c") == "\(home)/a b/c")
    }
  }

  @Test(.timeLimit(.minutes(1)), arguments: ["/", "/srv/repo", "/a/~/b", "/a b/~"])
  func expandKeepsAnAbsolutePath(path: String) throws {
    try withSite { b in
      try b.ready()

      #expect(try b.site.expand(path) == path)
    }
  }

  @Test(.timeLimit(.minutes(1)), arguments: ["~other", "~other/x", "~root", "~haacked/repo", "~~", "~+"])
  func expandRefusesTheHomeOfAnotherUser(path: String) throws {
    try withSite { b in
      try b.ready()

      #expect(throws: (any Error).self) { try b.site.expand(path) }
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func expandNeverAnswersWithThisMacsHome() throws {
    try withSite { b in
      try b.ready()

      #expect(try !b.site.expand("~/x").hasPrefix(NSHomeDirectory()))
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func expandThrowsBeforeSetupRan() throws {
    try withSite { b in
      #expect { try b.site.expand("~/x") } throws: { isUnread($0) }
      try b.bench.connect()
      #expect { try b.site.expand("~/x") } throws: { isUnread($0) }
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func theSessionFolderIsUnderTheBoxesSwitchboardFolder() throws {
    try withSite { b in
      let home = try b.ready().home

      #expect(try b.site.sessionFolder("s1") == "\(home)/.sb/sessions/s1")
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func theWorktreeRootIsTheHostsRootWithTheTildeResolvedOnTheBox() throws {
    try withSite { b in
      let home = try b.ready().home

      #expect(try b.site.worktreeRoot() == "\(home)/worktrees")
    }
    try withSite(host: ["worktreeRoot": "~/trees"]) { b in
      let home = try b.ready().home

      #expect(try b.site.worktreeRoot() == "\(home)/trees")
    }
    try withSite(host: ["worktreeRoot": "/srv/trees"]) { b in
      try b.ready()

      #expect(try b.site.worktreeRoot() == "/srv/trees")
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func gitIsTheGitOfTheBox() throws {
    try withSite { b in
      let facts = try b.ready()

      #expect(try b.site.git() == facts.git)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func theTerminalsAreTheTmuxServerOfTheBox() throws {
    try withSite(host: ["shell": "/bin/dash"]) { b in
      let facts = try b.ready()

      let terminals = try b.site.terminals()

      #expect(terminals.tmux == facts.tmux)
      #expect(terminals.socket == "\(facts.home)/.sb/tmux.sock")
      #expect(terminals.shell == "/bin/dash")
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func aTmuxCommandOfTheTerminalsRunsOnTheBoxWithATimeoutOfFiveSecondsAndTheBoxesEnvironment() throws {
    try withSite(environment: { _ in "SSH_AUTH_SOCK=/tmp/sb-test-agent.sock LANG=C.UTF-8 " }) { b in
      let facts = try b.ready()
      let before = b.sent.runs.count

      _ = try b.site.terminals().run(["list-panes", "-a"])

      let run = try #require(b.sent.runs.dropFirst(before).first)
      #expect(run.executable == facts.tmux)
      #expect(Array(run.args.prefix(4)) == ["-S", "\(facts.home)/.sb/tmux.sock", "-f", "\(facts.home)/.sb/tmux.conf"])
      #expect(run.timeout == 5)
      let env = try #require(run.env)
      #expect(env["HOME"] == facts.home)
      #expect(env["USER"] == facts.user)
      #expect(env["LOGNAME"] == facts.user)
      #expect(env["SHELL"] == facts.shell)
      #expect(env["LANG"] == "C.UTF-8")
      #expect(env["TERM"] == "xterm-256color")
      #expect(env["PATH"] == "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
      #expect(env["SSH_AUTH_SOCK"] == "\(facts.home)/.sb/agent.sock")
      #expect(env["TMPDIR"] == nil)
      #expect(env["CLAUDE_CONFIG_DIR"] == nil)
      #expect(
        Set(env.keys).isSubset(of: ["TERM", "SHELL", "HOME", "USER", "LOGNAME", "LANG", "PATH", "SSH_AUTH_SOCK"]))
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func theTerminalsThrowUntilSetupRanOnTheCurrentConnection() throws {
    try withSite { b in
      #expect { try b.site.terminals() } throws: { isUnread($0) }
      #expect { try b.site.git() } throws: { isUnread($0) }
      #expect { try b.site.worktreeRoot() } throws: { isUnread($0) }
      #expect { try b.site.sessionFolder("s1") } throws: { isUnread($0) }
      try b.ready()
      _ = try b.site.terminals()

      try b.reconnect()

      #expect { try b.site.terminals() } throws: { isUnread($0) }
      #expect { try b.site.git() } throws: { isUnread($0) }
      #expect { try b.site.sessionFolder("s1") } throws: { isUnread($0) }
    }
  }

  // MARK: Parity with this Mac

  /// The paths of one case, in a folder of the test's home. The stub's box is this Mac, so the remote scripts and
  /// `MacSite` read the same files and must give the same answers.
  private func paths(_ b: SiteBench) throws -> [String: String] {
    let root = "\(b.home)/paths"
    let fm = FileManager.default
    try fm.createDirectory(atPath: "\(root)/folder/inner", withIntermediateDirectories: true)
    try fm.createDirectory(atPath: "\(root)/a b's $HOME \"q\"", withIntermediateDirectories: true)
    try fm.createDirectory(atPath: "\(root)/line\nbreak", withIntermediateDirectories: true)
    try fm.createDirectory(atPath: "\(root)/-dash", withIntermediateDirectories: true)
    fm.createFile(atPath: "\(root)/file", contents: Data("x".utf8))
    try fm.createSymbolicLink(atPath: "\(root)/link", withDestinationPath: "\(root)/folder")
    try fm.createSymbolicLink(atPath: "\(root)/relative-link", withDestinationPath: "folder/inner")
    try fm.createSymbolicLink(atPath: "\(root)/dangling", withDestinationPath: "\(root)/nowhere")
    return [
      "folder": "\(root)/folder", "inner": "\(root)/folder/inner", "through link": "\(root)/link/inner",
      "link": "\(root)/link", "relative link": "\(root)/relative-link", "dangling": "\(root)/dangling",
      "file": "\(root)/file", "below a file": "\(root)/file/x", "missing": "\(root)/missing",
      "missing below missing": "\(root)/gone/deeper/still", "missing below link": "\(root)/link/gone/x",
      "quoted": "\(root)/a b's $HOME \"q\"", "newline": "\(root)/line\nbreak", "dash": "\(root)/-dash",
      "dots": "\(root)/folder/../folder/./inner", "trailing slash": "\(root)/folder/", "root": "/", "tmp": "/tmp",
      "relative name": "-relative", "empty": "",
    ]
  }

  private func mac(_ b: SiteBench) throws -> MacSite {
    try FileManager.default.createDirectory(atPath: "\(b.home)/mac", withIntermediateDirectories: true)
    var config = Config()
    config.tmux = "\(b.home)/fake-tmux"
    return try MacSite(home: Home(path: "\(b.home)/mac"), config: config)
  }

  @Test(.timeLimit(.minutes(2)))
  func realPathAnswersAsThisMacDoesForEveryShapeOfPath() throws {
    try withSite { b in
      try b.ready()
      let cases = try paths(b)
      let mac = try mac(b)

      for (label, path) in cases.sorted(by: { $0.key < $1.key }) where !path.isEmpty && path.hasPrefix("/") {
        #expect(try b.site.realPath(path) == mac.realPath(path), "\(label)")
      }
      #expect(try b.site.realPath(try #require(cases["missing"])) == nil)
      #expect(try b.site.realPath(try #require(cases["link"])) == resolved(try #require(cases["folder"])))
    }
  }

  @Test(.timeLimit(.minutes(2)))
  func folderGoneAnswersAsThisMacDoesForEveryShapeOfPath() throws {
    try withSite { b in
      try b.ready()
      let cases = try paths(b)
      let mac = try mac(b)

      for (label, path) in cases.sorted(by: { $0.key < $1.key }) where path.hasPrefix("/") {
        #expect(try b.site.folderGone(path) == mac.folderGone(path), "\(label)")
      }
      #expect(try b.site.folderGone(try #require(cases["missing"])))
      #expect(try b.site.folderGone(try #require(cases["dangling"])))
      #expect(try !b.site.folderGone(try #require(cases["folder"])))
      #expect(try !b.site.folderGone(try #require(cases["below a file"])))
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func folderGoneIsFalseForAFolderThatTheHostCantRead() throws {
    try withSite { b in
      try b.ready()
      let locked = "\(b.home)/locked"
      try FileManager.default.createDirectory(atPath: "\(locked)/inner", withIntermediateDirectories: true)
      chmod(locked, 0)
      defer { chmod(locked, 0o700) }

      #expect(try !b.site.folderGone("\(locked)/inner"))
    }
  }

  @Test(.timeLimit(.minutes(3)))
  func samePathAnswersAsThisMacDoesForEveryPairOfPaths() throws {
    try withSite { b in
      try b.ready()
      let cases = try paths(b).filter { $0.value.hasPrefix("/") }.sorted { $0.key < $1.key }
      let mac = try mac(b)

      for (first, a) in cases {
        for (second, other) in cases {
          #expect(try b.site.samePath(a, other) == mac.samePath(a, other), "\(first) and \(second)")
        }
      }
      let named = Dictionary(uniqueKeysWithValues: cases.map { ($0.key, $0.value) })
      #expect(try b.site.samePath(try #require(named["link"]), try #require(named["folder"])))
      #expect(try b.site.samePath(try #require(named["through link"]), try #require(named["inner"])))
      #expect(try !b.site.samePath(try #require(named["folder"]), try #require(named["inner"])))
      #expect(try !b.site.samePath(try #require(named["missing"]), try #require(named["missing below missing"])))
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func thePathChecksThrowWhenTheHostDoesNotAnswer() throws {
    try withSite { b in
      try b.ready()
      let master = try #require(b.bench.masters().last)
      b.bench.drop(master)
      try b.bench.waitFor(.unreachable)

      #expect { try b.site.folderGone("\(b.home)/missing") } throws: { isUnread($0) }
      #expect { try b.site.realPath("\(b.home)/missing") } throws: { isUnread($0) }
      #expect { try b.site.samePath("\(b.home)/a", "\(b.home)/b") } throws: { isUnread($0) }
    }
  }
}

// MARK: The guard

/// `confirmed` returns its body's result only when the link was connected, setup ran on the connection, and the
/// host answered every command that the body sent.
@Suite struct RemoteSiteConfirmedTests {
  struct BodyFailure: Error {}

  /// Runs `confirmed` and reports whether the body ran.
  private func attempt<T>(_ site: RemoteSite, _ body: @escaping (any Machine) throws -> T) -> (
    result: Result<T, any Error>, ran: Bool
  ) {
    var ran = false
    let result = Result<T, any Error> {
      try site.confirmed("a test read") { machine in
        ran = true
        return try body(machine)
      }
    }
    return (result, ran)
  }

  private func expectUnread<T>(_ result: Result<T, any Error>, _ comment: Comment = "") {
    switch result {
    case .success(let value): Issue.record("confirmed returned \(value). \(comment)")
    case .failure(let error): #expect(isUnread(error), "\(error). \(comment)")
    }
  }

  // MARK: Before the body

  @Test(.timeLimit(.minutes(1)))
  func aDisconnectedLinkThrowsBeforeTheBodyRuns() throws {
    try withSite { b in
      let r = attempt(b.site) { $0.exists("/") }

      expectUnread(r.result)
      #expect(!r.ran)
      #expect(b.bench.runs().isEmpty)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func aConnectingLinkThrowsBeforeTheBodyRuns() throws {
    try withSite { b in
      try b.bench.set("hang")
      b.link.connect()
      try b.bench.waitFor(.connecting)

      let r = attempt(b.site) { $0.exists("/") }

      expectUnread(r.result)
      #expect(!r.ran)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func anUnreachableLinkThrowsBeforeTheBodyRunsAndNamesTheLinksError() throws {
    try withSite { b in
      try b.bench.fail(attempts: 1)

      let r = attempt(b.site) { $0.exists("/") }

      expectUnread(r.result)
      #expect(!r.ran)
      if case .failure(let error) = r.result {
        #expect("\(error)".hasPrefix("mini is not connected: "), "\(error)")
        #expect("\(error)".contains(LinkBench.refusal), "\(error)")
      }
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func aLinkThatDroppedAfterSetupThrowsBeforeTheBodyRuns() throws {
    try withSite { b in
      try b.ready()
      b.bench.drop(try #require(b.bench.masters().last))
      try b.bench.waitFor(.unreachable)

      let r = attempt(b.site) { $0.exists("/") }

      expectUnread(r.result)
      #expect(!r.ran)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func aDisconnectedLinkThatWasReadyThrowsBeforeTheBodyRuns() throws {
    try withSite { b in
      try b.ready()
      b.link.disconnect()

      let r = attempt(b.site) { $0.exists("/") }

      expectUnread(r.result)
      #expect(!r.ran)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func aConnectedLinkWhoseSetupHasNotRunThrowsBeforeTheBodyRuns() throws {
    try withSite { b in
      try b.bench.connect()

      let r = attempt(b.site) { $0.exists("/") }

      expectUnread(r.result)
      #expect(!r.ran)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func aSiteWhoseSetupFailedThrowsBeforeTheBodyRunsAndSaysWhy() throws {
    try withSite(host: ["tmux": "/nonexistent/sb/tmux"]) { b in
      try b.bench.connect()
      #expect(throws: (any Error).self) { try b.site.prepare() }

      let r = attempt(b.site) { $0.exists("/") }

      expectUnread(r.result)
      #expect(!r.ran)
      if case .failure(let error) = r.result { #expect("\(error)".contains(tmuxInstall), "\(error)") }
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func aReconnectedLinkWhoseSetupRanOnlyOnTheLastConnectionThrowsBeforeTheBodyRuns() throws {
    try withSite { b in
      try b.ready()
      try b.reconnect()

      let r = attempt(b.site) { $0.exists("/") }

      expectUnread(r.result)
      #expect(!r.ran)
    }
  }

  // MARK: Answers

  @Test(.timeLimit(.minutes(1)))
  func aBodyWhoseCommandsAllAnsweredReturnsItsValue() throws {
    try withSite { b in
      try b.ready()
      try b.set("note", "hello")

      let text = try b.site.confirmed("a read") { machine in
        _ = machine.exists(b.home)
        return machine.text("\(b.home)/note")
      }

      #expect(text == "hello")
    }
  }

  /// Each of these results is what an unanswered command also returns. Here the host gave it as an answer.
  @Test(.timeLimit(.minutes(1)))
  func anAnsweredFalseNilAndEmptyResultIsReturnedAsTheAnswer() throws {
    try withSite { b in
      try b.ready()
      let missing = "\(b.home)/missing"

      #expect(try b.site.confirmed("exists") { $0.exists(missing) } == false)
      #expect(try b.site.confirmed("isFolder") { $0.isFolder(missing) } == false)
      #expect(try b.site.confirmed("text") { $0.text(missing) } == nil)
      #expect(try b.site.confirmed("size") { $0.size(missing) } == nil)
      #expect(try b.site.confirmed("modified") { $0.modified(missing) } == nil)
      #expect(try b.site.confirmed("list") { $0.list(missing) } == [])
      #expect(try b.site.confirmed("status") { try $0.run("/usr/bin/false", []).status } == 1)
      #expect(try b.site.confirmed("nothing") { _ in 7 } == 7)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func anAnsweredTrueIsReturned() throws {
    try withSite { b in
      try b.ready()

      #expect(try b.site.confirmed("exists") { $0.exists(b.home) })
      #expect(try b.site.confirmed("isFolder") { $0.isFolder(b.home) })
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func aBodysOwnErrorPassesThroughWhenEveryCommandAnswered() throws {
    try withSite { b in
      try b.ready()

      #expect(throws: BodyFailure.self) {
        try b.site.confirmed("a check") { machine -> Bool in
          guard machine.exists("\(b.home)/missing") else { throw BodyFailure() }
          return true
        }
      }
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func theBodysMachineGivesEachRunATimeout() throws {
    try withSite { b in
      try b.ready()
      let before = b.sent.runs.count

      _ = try b.site.confirmed("a run") { try $0.run("/usr/bin/true", []) }

      let runs = b.sent.runs.dropFirst(before)
      #expect(!runs.isEmpty)
      #expect(runs.allSatisfy { $0.timeout != nil })
    }
  }

  // MARK: A command that got no answer

  @Test(.timeLimit(.minutes(1)))
  func aBodyWhoseCommandFollowsTheDropThrowsThoughTheCommandReturnedFalse() throws {
    try withSite { b in
      try b.ready()
      let master = try #require(b.bench.masters().last)
      var seen: Bool?

      let r = attempt(b.site) { machine -> Bool in
        b.bench.drop(master)
        try b.bench.waitForExit(master.pid)
        let exists = machine.exists(b.home)
        seen = exists
        return exists
      }

      #expect(r.ran)
      #expect(seen == false)
      expectUnread(r.result, "the folder exists, and the unanswered check said it does not")
    }
  }

  @Test(
    .timeLimit(.minutes(1)),
    arguments: ["exists", "isFolder", "text", "size", "modified", "list", "run", "createFolder"])
  func aBodyThrowsWhenAMemberOfAnyKindGotNoAnswer(member: String) throws {
    try withSite { b in
      try b.ready()
      try b.set("note", "hello")
      let master = try #require(b.bench.masters().last)

      let r = attempt(b.site) { machine -> String in
        b.bench.drop(master)
        try b.bench.waitForExit(master.pid)
        switch member {
        case "exists": return String(machine.exists(b.home))
        case "isFolder": return String(machine.isFolder(b.home))
        case "text": return machine.text("\(b.home)/note") ?? "nil"
        case "size": return machine.size("\(b.home)/note").map(String.init) ?? "nil"
        case "modified": return machine.modified("\(b.home)/note").map { "\($0)" } ?? "nil"
        case "list": return machine.list(b.home).joined()
        case "run": return (try? machine.run("/usr/bin/true", []).status).map(String.init) ?? "threw"
        default: return (try? machine.createFolder("\(b.home)/new")) == nil ? "threw" : "made"
        }
      }

      #expect(r.ran)
      expectUnread(r.result)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func aBodyWhoseCommandIsCutWhileItRunsThrowsThoughTheBodySwallowedTheFailure() throws {
    try withSite { b in
      try b.ready()
      let master = try #require(b.bench.masters().last)
      let marker = "\(b.home)/cut.started"

      let r = attempt(b.site) { machine -> String in
        Thread.detachNewThread {
          _ = waitUntil(seconds: 10) { FileManager.default.fileExists(atPath: marker) }
          b.bench.drop(master)
        }
        let result = try? machine.run(
          "/bin/sh", ["-c", #": >"$1"; exec sleep 30"#, "sb", marker], env: nil, input: nil, timeout: 40)
        return result == nil ? "no answer" : "answered"
      }

      #expect(r.ran)
      expectUnread(r.result)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func aBodyThatRethrowsAnUnansweredCommandThrowsHostUnread() throws {
    try withSite { b in
      try b.ready()
      let master = try #require(b.bench.masters().last)

      let r = attempt(b.site) { machine -> Int32 in
        b.bench.drop(master)
        try b.bench.waitForExit(master.pid)
        return try machine.run("/usr/bin/true", []).status
      }

      expectUnread(r.result)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func aCommandThatPassesItsDeadlineThrows() throws {
    try withSite { b in
      try b.ready()

      let r = attempt(b.site) { machine -> String in
        // The host's shell is stopped, so the command gets no answer by its deadline.
        let master = try #require(b.bench.masters().last)
        kill(master.pid, SIGSTOP)
        defer { kill(master.pid, SIGCONT) }
        return (try? machine.run("/usr/bin/true", [], env: nil, input: nil, timeout: 1)) == nil
          ? "no answer" : "answered"
      }

      expectUnread(r.result)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func aDropAndReconnectBetweenTwoCommandsOfOneBodyThrowsThoughBothAnswered() throws {
    try withSite { b in
      try b.ready()
      try b.set("note", "hello")
      var answers: [String?] = []

      let r = attempt(b.site) { machine -> [String?] in
        answers.append(machine.text("\(b.home)/note"))
        try b.reconnect()
        answers.append(machine.text("\(b.home)/note"))
        return answers
      }

      #expect(r.ran)
      #expect(answers.first == "hello")
      expectUnread(r.result, "the two reads came from two connections")
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func aDropAndReconnectAfterTheLastCommandOfABodyThrows() throws {
    try withSite { b in
      try b.ready()

      let r = attempt(b.site) { machine -> Bool in
        let exists = machine.exists(b.home)
        try b.reconnect()
        return exists
      }

      expectUnread(r.result)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func aReadWorksAgainOnceSetupRanOnTheNewConnection() throws {
    try withSite { b in
      try b.ready()
      try b.reconnect()
      try b.site.prepare()

      #expect(try b.site.confirmed("exists") { $0.exists(b.home) })
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func oneFailedCallDoesNotFailTheNext() throws {
    try withSite { b in
      try b.ready()
      let first = attempt(b.site) { _ -> Bool in throw BodyFailure() }

      let second = try b.site.confirmed("exists") { $0.exists(b.home) }

      #expect(throws: BodyFailure.self) { try first.result.get() }
      #expect(second)
    }
  }
}

// MARK: A file check that the host ended

/// Inside `confirmed`, a file member returns nil, false, or nothing only when the host's script answered that.
/// A script that its timeout ended, or that the host could not run, is not an answer.
@Suite struct RemoteSiteFileAnswerTests {
  static let members = ["exists", "isFolder", "text", "size", "modified", "list"]

  /// What the member returns for a file or folder that exists, as text. "no" is what an unanswered call returns.
  private func ask(_ member: String, _ machine: any Machine, _ b: SiteBench) -> String {
    let note = "\(b.home)/note"
    switch member {
    case "exists": return machine.exists(note) ? "yes" : "no"
    case "isFolder": return machine.isFolder(b.home) ? "yes" : "no"
    case "text": return machine.text(note) == nil ? "no" : "yes"
    case "size": return machine.size(note) == nil ? "no" : "yes"
    case "modified": return machine.modified(note) == nil ? "no" : "yes"
    default: return machine.list(b.home).isEmpty ? "no" : "yes"
    }
  }

  private func expectUnread(_ member: String, _ b: SiteBench, _ comment: Comment) {
    var seen: String?
    do {
      let value = try b.site.confirmed("a test read") { machine in
        seen = ask(member, machine, b)
        return seen
      }
      Issue.record("confirmed returned \(value ?? "nil") for \(member). \(comment)")
    } catch {
      #expect(isUnread(error), "\(error). \(comment)")
    }
    #expect(seen == "no", "\(member) is built to return its negative when the host gives no answer")
  }

  @Test(.timeLimit(.minutes(1)), arguments: members)
  func theScriptsRunThroughTheBenchsShellAndAnswer(member: String) throws {
    try withSite(scripts: true) { b in
      try b.ready()
      try b.set("note", "hello")

      #expect(try b.site.confirmed("a test read") { ask(member, $0, b) } == "yes")
    }
  }

  @Test(.timeLimit(.minutes(1)), arguments: members)
  func aFileCheckThatOutlastsItsTimeoutIsNotAnAnswer(member: String) throws {
    try withSite(scripts: true) { b in
      try b.ready()
      try b.set("note", "hello")
      try b.set("script-hangs", "")
      try b.set("short-timeouts", "")

      expectUnread(member, b, "the host ended the check at its timeout, and the file exists")
      #expect(b.link.status.state == .connected, "the host answered with a status, so the link stays up")
    }
  }

  @Test(.timeLimit(.minutes(1)), arguments: members, [2, 126, 127, 137, 143])
  func aFileCheckThatTheHostCouldNotRunIsNotAnAnswer(member: String, status: Int) throws {
    try withSite(scripts: true) { b in
      try b.ready()
      try b.set("note", "hello")
      try b.set("script-status", String(status))

      expectUnread(member, b, "the script exited with \(status), which is not how it says no")
    }
  }

  /// Status 1 is how each script says no.
  @Test(.timeLimit(.minutes(1)))
  func anAnsweredNoIsStillTheAnswer() throws {
    try withSite(scripts: true) { b in
      try b.ready()
      let missing = "\(b.home)/missing"

      #expect(try b.site.confirmed("exists") { $0.exists(missing) } == false)
      #expect(try b.site.confirmed("isFolder") { $0.isFolder(missing) } == false)
      #expect(try b.site.confirmed("text") { $0.text(missing) } == nil)
      #expect(try b.site.confirmed("size") { $0.size(missing) } == nil)
      #expect(try b.site.confirmed("modified") { $0.modified(missing) } == nil)
      #expect(try b.site.confirmed("list") { $0.list(missing) } == [])
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func aStatThatPrintsNoSizeIsNotAnAnswer() throws {
    try withSite(scripts: true) { b in
      try b.ready()
      try b.set("note", "hello")
      try b.set("script-status", "0")

      for member in ["size", "modified"] {
        expectUnread(member, b, "the script exited 0 and printed nothing that names a size or a time")
      }
    }
  }

  /// A signal ends a program with status 143 or 137, as the host's timeout does.
  @Test(.timeLimit(.minutes(1)), arguments: [137, 143])
  func aRunThatASignalEndedIsNotAnAnswer(status: Int) throws {
    try withSite { b in
      try b.ready()
      var seen: Int32?

      do {
        _ = try b.site.confirmed("a test run") { machine in
          seen = try machine.run("/bin/sh", ["-c", "exit \(status)"], env: nil, input: nil, timeout: 5).status
          return seen
        }
        Issue.record("confirmed returned the status of a run that a signal ended")
      } catch {
        #expect(isUnread(error), "\(error)")
      }
      #expect(seen == Int32(status))
    }
  }

  @Test(.timeLimit(.minutes(1)), arguments: [2, 126, 127, 137, 143])
  func aSignalThatTheHostCouldNotSendIsNotAnAnswer(status: Int) throws {
    try withSite(scripts: true) { b in
      try b.ready()
      try b.set("script-status", String(status))
      let pid = try b.tree().child

      #expect {
        try b.site.confirmed("a test signal") { $0.signal(pid, SIGCONT) }
      } throws: { isUnread($0) }
    }
  }

  /// The shell's `kill` exits 1 for a process that is gone.
  @Test(.timeLimit(.minutes(1)))
  func aSignalToAProcessThatIsGoneIsAnAnswer() throws {
    try withSite(scripts: true) { b in
      try b.ready()
      let gone = Process()
      gone.executableURL = URL(fileURLWithPath: "/usr/bin/true")
      try gone.run()
      gone.waitUntilExit()

      try b.site.confirmed("a test signal") { $0.signal(Int(gone.processIdentifier), SIGCONT) }
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func aRunThatOutlastsItsTimeoutIsNotAnAnswer() throws {
    try withSite { b in
      try b.ready()

      #expect {
        try b.site.confirmed("a test run") { machine in
          try machine.run("/bin/sleep", ["30"], env: nil, input: nil, timeout: 0.3).status
        }
      } throws: { isUnread($0) }
    }
  }

  @Test(.timeLimit(.minutes(1)), arguments: [1, 2, 3, 126, 127, 128])
  func aRunsOwnStatusIsTheAnswer(status: Int) throws {
    try withSite { b in
      try b.ready()

      let seen = try b.site.confirmed("a test run") { machine in
        try machine.run("/bin/sh", ["-c", "exit \(status)"], env: nil, input: nil, timeout: 5).status
      }

      #expect(seen == Int32(status))
    }
  }
}

// MARK: The answer check

@Suite struct AnswerCheckTests {
  struct First: Error {}
  struct Second: Error {}

  @Test func aNewCheckHoldsNoFailure() {
    #expect(AnswerCheck().failure == nil)
  }

  @Test func aMissedCommandIsTheFailure() {
    let check = AnswerCheck()

    check.missed(First())

    #expect(check.failure is First)
  }

  @Test func twoMissedCommandsLeaveAFailure() {
    let check = AnswerCheck()

    check.missed(First())
    check.missed(Second())

    #expect(check.failure != nil)
  }

  @Test func commandsMissedOnManyThreadsLeaveAFailure() {
    let check = AnswerCheck()

    DispatchQueue.concurrentPerform(iterations: 64) { _ in check.missed(First()) }

    #expect(check.failure is First)
  }
}

// MARK: The snapshot

@Suite struct RemoteSiteSnapshotTests {
  @Test(.timeLimit(.minutes(1)))
  func readSnapshotFindsTheClaudeBelowASessionsLivePane() throws {
    try withSite { b in
      try b.ready()
      let claude = try b.tree()
      let shell = try b.tree()
      try b.setPanes([("s1-claude", claude.pane, false), ("s1-shell", shell.pane, false)])

      let s = try b.site.readSnapshot(claudeProgram: "sleep")

      #expect(s.panes.keys.sorted() == ["s1-claude", "s1-shell"])
      #expect(s.panes["s1-claude"]?.pid == claude.pane)
      #expect(s.claudePids == ["s1": claude.child])
      #expect(s.children[claude.pane]?.map(\.pid) == [claude.child])
      #expect(s.taken > 0)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func readSnapshotGivesNoClaudeToADeadPane() throws {
    try withSite { b in
      try b.ready()
      let claude = try b.tree()
      try b.setPanes([("s1-claude", claude.pane, true)])

      let s = try b.site.readSnapshot(claudeProgram: "sleep")

      #expect(s.panes["s1-claude"]?.dead == true)
      #expect(s.claudePids.isEmpty)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func readSnapshotHasNoPanesWhenNoTmuxServerRunsOnTheBox() throws {
    try withSite { b in
      try b.ready()
      try b.set("panes-error", "no server running on \(b.boxHome)/.sb/tmux.sock\n")

      let s = try b.site.readSnapshot(claudeProgram: "sleep")

      #expect(s.panes.isEmpty)
      #expect(!s.children.isEmpty)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func readSnapshotThrowsWhenTmuxCantListThePanes() throws {
    try withSite { b in
      try b.ready()
      try b.set("panes-error", "error connecting to \(b.boxHome)/.sb/tmux.sock (Permission denied)\n")

      #expect(throws: (any Error).self) { try b.site.readSnapshot(claudeProgram: "sleep") }
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func readSnapshotThrowsWhenPsFailsOnTheBox() throws {
    try withSite { b in
      try b.ready()
      try b.setPanes([])
      try Data("#!/bin/sh\nexit 1\n".utf8).write(to: URL(fileURLWithPath: "\(b.home)/box-bin/ps"))

      #expect(throws: (any Error).self) { try b.site.readSnapshot(claudeProgram: "sleep") }
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func readSnapshotSendsOneCommandWithATimeoutOfFiveSeconds() throws {
    try withSite { b in
      try b.ready()
      try b.setPanes([])
      let before = b.sent.runs.count

      _ = try b.site.readSnapshot(claudeProgram: "sleep")

      let runs = Array(b.sent.runs.dropFirst(before))
      #expect(runs.count == 1)
      #expect(runs.first?.timeout == 5)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func readSnapshotThrowsOnALinkThatIsDown() throws {
    try withSite { b in
      #expect { try b.site.readSnapshot(claudeProgram: "sleep") } throws: { isUnread($0) }
      try b.ready()
      b.bench.drop(try #require(b.bench.masters().last))
      try b.bench.waitFor(.unreachable)

      #expect { try b.site.readSnapshot(claudeProgram: "sleep") } throws: { isUnread($0) }
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func readSnapshotThrowsWhenTheLinkDropsWhileTheReadRuns() throws {
    try withSite { b in
      try b.ready()
      let claude = try b.tree()
      try b.setPanes([("s1-claude", claude.pane, false)])
      let master = try #require(b.bench.masters().last)
      try b.set("after-read", "kill -KILL \(master.pid)\nsleep 1\n")

      #expect { try b.site.readSnapshot(claudeProgram: "sleep") } throws: { isUnread($0) }
    }
  }
}

// MARK: The checked kill

/// `stopClaude` signals a pid only when a process read of this connection, taken in this call, shows it below the
/// session's Claude pane and running claude, and its parent is still that one when the signal goes. A `sleep` below
/// a shell stands in for claude below its pane. Each test that refuses also checks that the process still runs.
@Suite struct RemoteSiteStopClaudeTests {
  private func expectRefused(_ b: SiteBench, _ pid: Int, below pane: Int, _ comment: Comment = "") {
    #expect(throws: (any Error).self, comment) { try b.site.stopClaude(pid, below: pane, program: "sleep") }
  }

  @Test(.timeLimit(.minutes(1)))
  func theClaudeBelowThePaneGetsSIGTERM() throws {
    try withSite { b in
      try b.ready()
      let claude = try b.tree()
      let bystander = try b.tree()
      try b.setPanes([("s1-claude", claude.pane, false), ("s2-claude", bystander.pane, false)])

      try b.site.stopClaude(claude.child, below: claude.pane, program: "sleep")

      try b.bench.waitForExit(Int32(claude.child))
      #expect(b.runs(bystander.child))
      #expect(b.runs(bystander.pane))
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func theSignalIsSentByNameWithATimeoutOfFiveSeconds() throws {
    try withSite { b in
      try b.ready()
      let claude = try b.tree()
      try b.setPanes([("s1-claude", claude.pane, false)])
      let before = b.sent.runs.count

      try b.site.stopClaude(claude.child, below: claude.pane, program: "sleep")

      let runs = Array(b.sent.runs.dropFirst(before))
      #expect(runs.count == 2, "a fresh read, then one command that checks the parent and signals: \(runs)")
      #expect(runs.allSatisfy { $0.timeout == 5 })
      let kill = try #require(runs.last)
      #expect(kill.args.contains(String(claude.child)))
      #expect(kill.args.contains(String(claude.pane)))
      #expect(kill.args.contains { $0.contains("kill -s TERM") })
      #expect(b.sent.calls.filter { $0.hasPrefix("signal") }.isEmpty, "the site signalled without the parent check")
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func aPidThatExitedSinceTheCallersSnapshotIsRefused() throws {
    try withSite { b in
      try b.ready()
      let claude = try b.tree()
      let bystander = try b.tree()
      try b.setPanes([("s1-claude", claude.pane, false)])
      kill(pid_t(claude.child), SIGKILL)
      try b.bench.waitForExit(Int32(claude.child))

      expectRefused(b, claude.child, below: claude.pane)

      #expect(b.stillRuns(bystander.child))
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func aPidThatAnotherProgramReusedOutsideThePaneIsRefused() throws {
    try withSite { b in
      try b.ready()
      let claude = try b.tree()
      let other = try b.tree()
      try b.setPanes([("s1-claude", claude.pane, false)])

      expectRefused(b, other.child, below: claude.pane)

      #expect(b.stillRuns(other.child))
      #expect(b.runs(claude.child))
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func aPidThatDiffersFromTheClaudeThatTheFreshReadFindsIsRefused() throws {
    try withSite { b in
      try b.ready()
      let claude = try b.tree()
      try b.setPanes([("s1-claude", claude.pane, false)])

      expectRefused(b, claude.pane, below: claude.pane, "the pane's own shell is not its claude")

      #expect(b.stillRuns(claude.pane))
      #expect(b.runs(claude.child))
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func aClaudeBelowAnotherSessionsPaneIsRefused() throws {
    try withSite { b in
      try b.ready()
      let mine = try b.tree()
      let theirs = try b.tree()
      try b.setPanes([("s1-claude", mine.pane, false), ("s2-claude", theirs.pane, false)])

      expectRefused(b, theirs.child, below: mine.pane)

      #expect(b.stillRuns(theirs.child))
      #expect(b.runs(mine.child))
    }
  }

  /// `findClaude` picks a process whose second word names claude. Only a process that is claude gets a signal.
  @Test(.timeLimit(.minutes(1)))
  func aProcessWhoseSecondWordNamesClaudeIsRefused() throws {
    try withSite { b in
      try b.ready()
      try FileManager.default.createDirectory(atPath: "\(b.home)/logs", withIntermediateDirectories: true)
      FileManager.default.createFile(atPath: "\(b.home)/logs/sleep", contents: nil)
      let decoy = try b.tree("tail -f \(shellQuote("\(b.home)/logs/sleep"))")
      try b.setPanes([("s1-claude", decoy.pane, false)])

      expectRefused(b, decoy.child, below: decoy.pane)

      #expect(b.stillRuns(decoy.child))
    }
  }

  @Test(.timeLimit(.minutes(1)), arguments: [0, 1, -1, -2, Int(Int32.max) + 1, Int.min])
  func aNumberThatNamesNoSingleProcessOfThePaneIsRefused(pid: Int) throws {
    try withSite { b in
      try b.ready()
      let claude = try b.tree()
      try b.setPanes([("s1-claude", claude.pane, false)])
      let before = b.sent.runs.count

      expectRefused(b, pid, below: claude.pane)

      #expect(b.stillRuns(claude.child))
      #expect(b.runs(claude.pane))
      #expect(!b.sent.runs.dropFirst(before).contains { $0.args.contains { $0.contains("kill") } })
      #expect(b.sent.calls.filter { $0.hasPrefix("signal") }.isEmpty)
    }
  }

  @Test(.timeLimit(.minutes(1)), arguments: [0, 1, -1])
  func aPaneNumberThatNamesNoSingleProcessIsRefused(pane: Int) throws {
    try withSite { b in
      try b.ready()
      let claude = try b.tree()
      try b.setPanes([("s1-claude", claude.pane, false)])

      expectRefused(b, claude.child, below: pane)

      #expect(b.stillRuns(claude.child))
    }
  }

  /// The pane's shell dies after the fresh read, so the claude's parent is no longer the one that the read showed.
  @Test(.timeLimit(.minutes(1)))
  func aPaneThatChangedBetweenTheReadAndTheKillLeavesTheProcessUnsignalled() throws {
    try withSite { b in
      try b.ready()
      let claude = try b.tree()
      try b.setPanes([("s1-claude", claude.pane, false)])
      try b.set(
        "after-read", "kill -KILL \(claude.pane)\nwhile kill -0 \(claude.pane) 2>/dev/null; do sleep 0.05; done\n")

      do {
        try b.site.stopClaude(claude.child, below: claude.pane, program: "sleep")
        Issue.record("the claude was signalled though its pane changed")
      } catch {
        #expect("\(error)".contains("the claude process changed, so nothing was signalled"), "\(error)")
      }

      #expect(FileManager.default.fileExists(atPath: "\(b.home)/after-read.ran"), "the box's ps never ran the read")
      #expect(b.stillRuns(claude.child))
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func aLinkThatDropsBetweenTheReadAndTheKillLeavesTheProcessUnsignalled() throws {
    try withSite { b in
      try b.ready()
      let claude = try b.tree()
      try b.setPanes([("s1-claude", claude.pane, false)])
      let master = try #require(b.bench.masters().last)
      try b.set("after-read", "kill -KILL \(master.pid)\nsleep 1\n")

      #expect { try b.site.stopClaude(claude.child, below: claude.pane, program: "sleep") } throws: { isUnread($0) }

      #expect(FileManager.default.fileExists(atPath: "\(b.home)/after-read.ran"), "the box's ps never ran the read")
      #expect(b.stillRuns(claude.child))
    }
  }

  /// sbd can't say whether the signal went, so it reports the host as unread and the caller records nothing.
  @Test(.timeLimit(.minutes(1)))
  func aLinkThatDropsDuringTheKillThrowsHostUnread() throws {
    try withSite { b in
      try b.ready()
      let claude = try b.tree()
      try b.setPanes([("s1-claude", claude.pane, false)])
      let master = try #require(b.bench.masters().last)
      try b.set("before-check", "kill -KILL \(master.pid)\nsleep 1\n")

      #expect { try b.site.stopClaude(claude.child, below: claude.pane, program: "sleep") } throws: { isUnread($0) }

      #expect(FileManager.default.fileExists(atPath: "\(b.home)/before-check.ran"), "the kill never checked the parent")
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func aLinkThatIsDownLeavesTheProcessUnsignalled() throws {
    try withSite { b in
      try b.ready()
      let claude = try b.tree()
      try b.setPanes([("s1-claude", claude.pane, false)])
      b.bench.drop(try #require(b.bench.masters().last))
      try b.bench.waitFor(.unreachable)

      #expect { try b.site.stopClaude(claude.child, below: claude.pane, program: "sleep") } throws: { isUnread($0) }

      #expect(b.stillRuns(claude.child))
    }
  }

  /// The caller's pid comes from a snapshot of the last connection, and setup has not run on this one.
  @Test(.timeLimit(.minutes(1)))
  func aPidFromTheSnapshotOfAnEarlierConnectionIsNotSignalledBeforeSetupRuns() throws {
    try withSite { b in
      try b.ready()
      let claude = try b.tree()
      try b.setPanes([("s1-claude", claude.pane, false)])
      try b.reconnect()

      #expect { try b.site.stopClaude(claude.child, below: claude.pane, program: "sleep") } throws: { isUnread($0) }

      #expect(b.stillRuns(claude.child))
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func aFreshReadThatFailsLeavesTheProcessUnsignalled() throws {
    try withSite { b in
      try b.ready()
      let claude = try b.tree()
      try b.set("panes-error", "error connecting to \(b.boxHome)/.sb/tmux.sock (Permission denied)\n")

      expectRefused(b, claude.child, below: claude.pane)

      #expect(b.stillRuns(claude.child))
    }
  }
}

// MARK: Timeouts

/// No command of a remote site reaches the link without a timeout. The recording machine stands between the
/// site's `TimedMachine` and the link's machine.
@Suite struct RemoteSiteTimeoutTests {
  @Test(.timeLimit(.minutes(2)))
  func noRunOfAStartAStopAndAResumeReachesTheLinkWithoutATimeout() throws {
    try withSite { b in
      let facts = try b.ready()
      let claude = try b.tree()
      try b.setPanes([("s1-claude", claude.pane, false)])
      let folder = "\(facts.home)/repo"
      let terminals = try b.site.terminals()

      // A start: the folder checks, the worktree's git, the launcher's folder, and the two panes.
      try b.site.machine.createFolder(folder)
      _ = try b.site.confirmed("the folder") { $0.isFolder(folder) }
      _ = try b.site.samePath(folder, "\(folder)/.")
      _ = try b.site.realPath(folder)
      _ = try b.site.folderGone(folder)
      _ = try b.site.machine.run(try b.site.git(), ["-C", folder, "branch", "--show-current"])
      _ = try b.site.machine.run(
        try b.site.git(), ["-C", folder, "status"], env: ["LANG": "C"], input: nil, timeout: nil)
      try b.site.machine.createFolder(try b.site.sessionFolder("s1"))
      try terminals.create("s1-shell", cwd: folder, env: ["SB_SESSION_ID": "s1"], command: nil)
      try terminals.create("s1-claude", cwd: folder, env: ["SB_SESSION_ID": "s1"], command: "sleep 60")
      _ = terminals.isDead("s1-claude")
      _ = try b.site.readSnapshot(claudeProgram: "sleep")
      // A stop.
      try b.site.stopClaude(claude.child, below: claude.pane, program: "sleep")
      // A resume: the transcript lookup and the pane again.
      _ = try b.site.confirmed("the transcript") { $0.list("\(facts.home)/.claude/projects") }
      try terminals.create("s1-claude", cwd: folder, env: ["SB_SESSION_ID": "s1"], command: "sleep 60")
      _ = try terminals.checkedPanes()

      let runs = b.sent.runs
      #expect(runs.count >= 12, "the recording machine saw \(runs.count) runs")
      let untimed = runs.filter { $0.timeout == nil }
      #expect(untimed.isEmpty, "\(untimed.map { [$0.executable] + $0.args.prefix(4) })")
      #expect(runs.allSatisfy { ($0.timeout ?? 0) > 0 && ($0.timeout ?? 0).isFinite })
      let tmux = runs.filter { $0.executable == facts.tmux }
      #expect(!tmux.isEmpty)
      #expect(tmux.allSatisfy { $0.timeout == 5 })
      #expect(runs.filter { $0.executable == facts.git }.allSatisfy { $0.timeout == 30 })
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func theSitesMachineKeepsACallersTimeout() throws {
    try withSite { b in
      try b.ready()
      let before = b.sent.runs.count

      _ = try b.site.machine.run("/usr/bin/true", [], env: nil, input: nil, timeout: 600)

      #expect(b.sent.runs.dropFirst(before).map(\.timeout) == [600])
    }
  }

  /// A command waits for the host's shell while a long one runs, as the tick's reads wait behind a `git worktree
  /// remove`. Its deadline passes before it is sent, so it got no answer, and the link stays on its connection.
  @Test(.timeLimit(.minutes(1)))
  func aCommandWhoseDeadlinePassesBehindALongOneThrowsHostUnreadAndKeepsTheConnection() throws {
    try withSite { b in
      let facts = try b.ready()
      let started = "\(b.home)/long-started"
      let lock = NSLock()
      var long: Result<CommandResult, any Error>?
      let finished = DispatchSemaphore(value: 0)
      Thread.detachNewThread {
        let r = Result {
          try b.site.machine.run(
            "/bin/sh", ["-c", #": >"$1"; sleep 6; echo long"#, "sb", started], env: nil, input: nil, timeout: 30)
        }
        lock.withLock { long = r }
        finished.signal()
      }
      try #require(waitUntil(seconds: 20) { FileManager.default.fileExists(atPath: started) })

      #expect {
        try b.site.confirmed("a short command") {
          try $0.run("/bin/echo", ["short"], env: nil, input: nil, timeout: 0.5)
        }
      } throws: { isUnread($0) }

      #expect(finished.wait(timeout: .now() + 20) == .success)
      #expect(try lock.withLock { long }?.get().stdout == "long\n")
      #expect(b.link.status.state == .connected)
      #expect(b.link.status.connection == facts.epoch)
      #expect(try b.site.confirmed("the next command") { try $0.run("/bin/echo", ["next"]) }.stdout == "next\n")
    }
  }
}

// MARK: The service's sites

/// A `Service` with the host `mini` in config.json, whose ssh is the stub. The service is not loaded and has no
/// sessions but the ones a test adds.
func withHostService(
  hosts: [String: JSON] = ["mini": ["kind": "ssh", "destination": .string(LinkBench.destination)]],
  ssh: String = LinkBench.stub, config extra: [String: JSON] = [:],
  _ body: (Service, Home) throws -> Void
) throws {
  let home = Home(path: try makeShortTempFolder())
  defer { try? FileManager.default.removeItem(atPath: home.path) }
  let config: [String: JSON] = ["ssh": .string(ssh), "hosts": .object(hosts)].merging(extra) { $1 }
  try JSON.object(config).text.write(toFile: home.config, atomically: true, encoding: .utf8)
  let service = try Service(home: home, sbPath: "/usr/bin/true")
  defer { for link in service.hostLinks.values { link.disconnect() } }
  try body(service, home)
}

private func session(_ id: String, host: String?) -> Session {
  var s = Session(id: id, name: id, cwd: "/srv/repo", claudeSessionId: "u-\(id)", created: 5)
  s.host = host
  s.started = true
  return s
}

@Suite struct ServiceRemoteSitesTests {
  @Test(.timeLimit(.minutes(1)))
  func aSessionWithNoHostRunsAtThisMac() throws {
    try withHostService { service, _ in
      let site = service.queue.sync { service.site(for: session("s1", host: nil)) }

      #expect(site.hostName == nil)
      #expect(site === service.mac)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func aSessionOnAHostRunsAtThatHostsRemoteSite() throws {
    try withHostService { service, _ in
      let site = service.queue.sync { service.site(for: session("s1", host: "mini")) }
      let again = service.queue.sync { service.site(for: session("s2", host: "mini")) }

      #expect(site.hostName == "mini")
      #expect(site is RemoteSite)
      #expect(site === again)
      #expect(site === service.remoteSites["mini"])
    }
  }

  /// A site that fell back to this Mac would run the session's git and kill here.
  @Test(.timeLimit(.minutes(1)), arguments: ["gone", "boxes", "typo"])
  func aSessionWhoseHostHasNoLinkGetsASiteThatAnswersNothingAndNeverThisMac(host: String) throws {
    let hosts: [String: JSON] = [
      "mini": ["kind": "ssh", "destination": .string(LinkBench.destination)],
      "boxes": ["kind": "hogli", "layout": "perSession"], "typo": ["kind": "hogli"],
    ]
    try withHostService(hosts: hosts) { service, home in
      let site = service.queue.sync { service.site(for: session("s1", host: host)) }

      #expect(site.hostName == host)
      #expect(!(site === service.mac))
      #expect(throws: HostUnread.self) { try site.terminals() }
      #expect(throws: HostUnread.self) { try site.git() }
      #expect(throws: HostUnread.self) { try site.worktreeRoot() }
      #expect(throws: HostUnread.self) { try site.sessionFolder("s1") }
      #expect(throws: HostUnread.self) { try site.confirmed("a read") { $0.exists(home.path) } }
      #expect(throws: HostUnread.self) { try site.readSnapshot(claudeProgram: "claude") }
      #expect(throws: HostUnread.self) { try site.alive([Int(getpid())]) }
      #expect(throws: HostUnread.self) { try site.folderUsers(home.path) }
      #expect(throws: HostUnread.self) { try site.samePath(home.path, home.path) }
      #expect(throws: HostUnread.self) { try site.realPath(home.path) }
      #expect(throws: HostUnread.self) { try site.folderGone("\(home.path)/missing") }
      #expect(throws: HostUnread.self) { try site.stopClaude(Int(getpid()), below: 1, program: "claude") }
      #expect(throws: (any Error).self) { try site.machine.run("/usr/bin/true", []) }
      #expect(!site.machine.exists(home.path))
      #expect(site.machine.text(home.config) == nil)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func theClaudeOfARemoteSessionIsUnknownUntilItsHostAnsweredASnapshot() throws {
    try withHostService { service, _ in
      service.queue.sync {
        service.entries["s1"] = Service.Entry(session: session("s1", host: "mini"))
        service.entries["s2"] = Service.Entry(session: session("s2", host: nil))
      }

      let remote = service.queue.sync { service.claudeState("s1") }
      let local = service.queue.sync { service.claudeState("s2") }

      #expect(remote == .unknown)
      #expect(remote != .stopped)
      #expect(local == .stopped)
      #expect(service.queue.sync { service.claudePid("s1") } == nil)
    }
  }

  /// The Mac's snapshot holds a pane with the remote session's name. The remote session must not read it.
  @Test(.timeLimit(.minutes(1)))
  func aRemoteSessionNeverReadsThisMacsSnapshot() throws {
    try withHostService { service, _ in
      service.queue.sync {
        service.entries["s1"] = Service.Entry(session: session("s1", host: "mini"))
        service.mac.snapshot.panes["s1-claude"] = PaneRow(pid: 4242, dead: false, clients: 0)
        service.mac.snapshot.claudePids["s1"] = 4243
      }

      #expect(service.queue.sync { service.claudePid("s1") } == nil)
      #expect(service.queue.sync { service.paneRow("s1", .claude) } == nil)
      #expect(service.queue.sync { service.claudeState("s1") } == .unknown)
    }
  }

  /// A read that began before sbd started a pane would show the session stopped, and sbd would start it again.
  @Test(.timeLimit(.minutes(1)))
  func aHostSnapshotThatBeganBeforeSbdStartedAPaneIsNotInstalledAndAnUnansweredReadClearsIt() throws {
    try withHostService { service, _ in
      service.queue.sync {
        service.entries["s1"] = Service.Entry(session: session("s1", host: "mini"))
        var early = Service.Snapshot()
        early.taken = nowMs() - 60_000
        var late = Service.Snapshot()
        late.taken = nowMs() + 60_000

        service.markStarting("s1-claude")
        service.install(early, onHost: "mini")
        let afterEarly = service.remoteSnapshots["mini"]
        service.install(late, onHost: "mini")
        let afterLate = service.remoteSnapshots["mini"]
        service.install(nil, onHost: "mini")

        #expect(afterEarly == nil)
        #expect(afterLate?.taken == late.taken)
        #expect(service.remoteSnapshots["mini"] == nil)
        #expect(service.mac.snapshot.panes["s1-claude"] == nil)
      }
    }
  }

  /// The tick's read can end after a request's read that began later.
  @Test(.timeLimit(.minutes(1)))
  func aHostSnapshotThatWasReadBeforeTheInstalledOneDoesNotReplaceIt() throws {
    try withHostService { service, _ in
      service.queue.sync {
        var fresh = Service.Snapshot()
        fresh.taken = 2_000
        fresh.claudePids["s1"] = 7
        var stale = Service.Snapshot()
        stale.taken = 1_000

        service.install(fresh, onHost: "mini")
        service.install(stale, onHost: "mini")

        #expect(service.remoteSnapshots["mini"]?.taken == 2_000)
        #expect(service.remoteSnapshots["mini"]?.claudePids["s1"] == 7)

        var newer = Service.Snapshot()
        newer.taken = 3_000
        service.install(newer, onHost: "mini")

        #expect(service.remoteSnapshots["mini"]?.taken == 3_000)
      }
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func stoppingARemoteSessionWhoseHostIsDownSignalsNothingOnThisMac() throws {
    try withSleepingChild { child in
      try withHostService { service, _ in
        let pid = Int(child.processIdentifier)
        service.queue.sync {
          service.entries["s1"] = Service.Entry(session: session("s1", host: "mini"))
          service.mac.snapshot.panes["s1-claude"] = PaneRow(pid: Int(getpid()), dead: false, clients: 0)
          service.mac.snapshot.claudePids["s1"] = pid
        }

        #expect(throws: HostUnread.self) { try service.queue.sync { try service.stopClaude("s1", pid) } }

        Thread.sleep(forTimeInterval: 0.3)
        #expect(child.isRunning)
      }
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func theLauncherOfARemoteSessionIsWrittenOnTheBoxAndNotOnThisMac() throws {
    try withSite { b in
      try withHostService { service, home in
        let facts = try b.ready()

        try service.queue.sync { try service.writeLauncher("exec claude\n", for: "s1", at: b.site) }

        let onBox = "\(facts.home)/.sb/sessions/s1/claude.sh"
        #expect(try String(contentsOfFile: onBox, encoding: .utf8) == "exec claude\n")
        #expect(!FileManager.default.fileExists(atPath: home.sessionFolder("s1")))
        #expect(b.sent.runs.allSatisfy { $0.timeout != nil })
      }
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func theLauncherWriteThrowsWhenTheHostIsDownAndWritesNothingOnThisMac() throws {
    try withSite { b in
      try withHostService { service, home in
        #expect(throws: HostUnread.self) {
          try service.queue.sync { try service.writeLauncher("exec claude\n", for: "s1", at: b.site) }
        }

        #expect(!FileManager.default.fileExists(atPath: home.sessionFolder("s1")))
        #expect(!FileManager.default.fileExists(atPath: "\(b.boxHome)/.sb/sessions/s1"))
      }
    }
  }
}

// MARK: Processes on the host, for a removal

/// `alive` and `folderUsers` read the host's processes while sbd waits for a remote session's panes to stop before
/// it removes the worktree. Each answers only from a command that the host answered on the current connection. A
/// failed read never answers "exited" or "no users", because either one lets the removal go on.
///
/// These tests assume that both members run `/bin/sh -c` on the host, so that the bench's `script-status` file ends
/// them.
@Suite struct RemoteSiteProcessTests {
  /// Puts this Mac's lsof on the box's PATH, which holds only `box-bin`, /usr/bin, and /bin. macOS keeps lsof in
  /// /usr/sbin.
  private func addLsof(_ b: SiteBench) throws {
    let path = "\(b.home)/box-bin/lsof"
    try Data("#!/bin/sh\nexec /usr/sbin/lsof \"$@\"\n".utf8).write(to: URL(fileURLWithPath: path))
    chmod(path, 0o755)
  }

  private func exitedPid() throws -> Int {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    try p.run()
    p.waitUntilExit()
    return Int(p.processIdentifier)
  }

  /// A `sleep` whose working folder is `folder`. The box is this Mac.
  private func sleeper(in folder: String) throws -> Process {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sleep")
    p.arguments = ["30"]
    p.currentDirectoryURL = URL(fileURLWithPath: folder)
    try p.run()
    return p
  }

  private func folder(_ b: SiteBench) throws -> String {
    let path = "\(b.home)/work"
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
  }

  @Test(.timeLimit(.minutes(1)))
  func aliveNamesThePidsThatStillRunOnTheHost() throws {
    try withSite { b in
      try b.ready()
      let running = try b.tree()
      let gone = try exitedPid()

      let alive = try b.site.alive([running.child, running.pane, gone])

      #expect(alive == [running.child, running.pane])
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func aliveOfNoPidsIsEmpty() throws {
    try withSite { b in
      try b.ready()

      #expect(try b.site.alive([]).isEmpty)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func aliveAnswersAsThisMacDoes() throws {
    try withSite { b in
      try b.ready()
      let running = try b.tree()
      let gone = try exitedPid()
      let pids: Set<Int> = [running.child, running.pane, gone, Int(getpid())]

      // `MacSite.alive` is this filter.
      #expect(try b.site.alive(pids) == pids.filter(Processes.exists))
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func aliveSendsOneCommandWithATimeout() throws {
    try withSite { b in
      try b.ready()
      let running = try b.tree()
      let before = b.sent.runs.count

      _ = try b.site.alive([running.child, running.pane])

      let runs = Array(b.sent.runs.dropFirst(before))
      #expect(runs.count == 1, "\(runs)")
      #expect(runs.allSatisfy { $0.timeout != nil })
      #expect(b.sent.calls.filter { $0.hasPrefix("signal") }.isEmpty, "alive signalled through the machine")
    }
  }

  @Test(
    .timeLimit(.minutes(1)), arguments: ["a dropped link", "script-status 143", "a connection whose setup has not run"])
  func aliveThatGotNoAnswerThrowsHostUnread(shape: String) throws {
    try withSite(scripts: shape.hasPrefix("script")) { b in
      try b.ready()
      let running = try b.tree()
      switch shape {
      case "a dropped link":
        let master = try #require(b.bench.masters().last)
        b.bench.drop(master)
        try b.bench.waitFor(.unreachable)
      case "a connection whose setup has not run":
        try b.reconnect()
      default:
        try b.set("script-status", String(shape.split(separator: " ")[1]))
      }

      #expect { try b.site.alive([running.child]) } throws: { isUnread($0) }
    }
  }

  /// An `alive` that answered an empty set from a failed command would say that every process exited.
  @Test(.timeLimit(.minutes(1)), arguments: [1, 2, 126, 127])
  func aliveWhoseCommandFailedThrows(status: Int) throws {
    try withSite(scripts: true) { b in
      try b.ready()
      let running = try b.tree()
      try b.set("script-status", String(status))

      #expect(throws: (any Error).self) { try b.site.alive([running.child]) }
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func folderUsersFindsAProcessWhoseWorkingFolderIsInTheFolderOnTheHost() throws {
    try withSite { b in
      try b.ready()
      try addLsof(b)
      let folder = try folder(b)
      let user = try sleeper(in: folder)
      defer { user.terminate() }
      try b.bench.wait("lsof to list the sleeper") {
        Processes.using(folder).contains { $0.pid == Int(user.processIdentifier) }
      }

      let users = try b.site.folderUsers(folder)

      let found = try #require(users.first { $0.pid == Int(user.processIdentifier) })
      #expect(found.use == .workingFolder)
      #expect(users.allSatisfy { $0.pid != Int(getpid()) })
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func folderUsersOfAFolderThatNoProcessUsesIsEmpty() throws {
    try withSite { b in
      try b.ready()
      try addLsof(b)

      #expect(try b.site.folderUsers(try folder(b)).isEmpty)
    }
  }

  /// The bench's box is macOS, with no /proc, and its PATH has no lsof unless a test adds one.
  @Test(.timeLimit(.minutes(1)))
  func folderUsersOnAHostWithNeitherProcNorLsofThrowsThatItCantCheck() throws {
    try withSite { b in
      try b.ready()
      let folder = try folder(b)

      #expect { try b.site.folderUsers(folder) } throws: {
        "\($0)".contains("can't check which processes use \(folder) on mini")
      }
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func folderUsersWhoseScriptSaysItCantCheckThrowsThatItCantCheck() throws {
    try withSite(scripts: true) { b in
      try b.ready()
      try addLsof(b)
      let folder = try folder(b)
      try b.set("script-status", "97")

      #expect { try b.site.folderUsers(folder) } throws: {
        "\($0)".contains("can't check which processes use \(folder) on mini")
      }
    }
  }

  @Test(
    .timeLimit(.minutes(1)), arguments: ["a dropped link", "script-status 143", "a connection whose setup has not run"])
  func folderUsersThatGotNoAnswerThrowsHostUnread(shape: String) throws {
    try withSite(scripts: shape.hasPrefix("script")) { b in
      try b.ready()
      try addLsof(b)
      let folder = try folder(b)
      switch shape {
      case "a dropped link":
        let master = try #require(b.bench.masters().last)
        b.bench.drop(master)
        try b.bench.waitFor(.unreachable)
      case "a connection whose setup has not run":
        try b.reconnect()
      default:
        try b.set("script-status", String(shape.split(separator: " ")[1]))
      }

      #expect { try b.site.folderUsers(folder) } throws: { isUnread($0) }
    }
  }

  @Test(.timeLimit(.minutes(1)), arguments: [1, 2, 127])
  func folderUsersWhoseScriptFailedThrows(status: Int) throws {
    try withSite(scripts: true) { b in
      try b.ready()
      try addLsof(b)
      let folder = try folder(b)
      try b.set("script-status", String(status))

      #expect(throws: (any Error).self) { try b.site.folderUsers(folder) }
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func folderUsersRunsWithATimeout() throws {
    try withSite { b in
      try b.ready()
      try addLsof(b)
      let before = b.sent.runs.count

      _ = try b.site.folderUsers(try folder(b))

      let runs = Array(b.sent.runs.dropFirst(before))
      #expect(!runs.isEmpty)
      #expect(runs.allSatisfy { $0.timeout != nil })
    }
  }
}

// MARK: The session's launcher folder on the host

/// After sbd forgets a remote session, it removes the session's launcher folder on the host with `rm -rf`, only for
/// a path that equals `<home>/.sb/sessions/<id>` with an id that matches `^s[a-z0-9]+$`. Each refusal leaves every
/// folder in place.
///
/// These tests assume `RemoteSite.removeSessionFolder(_ path:, of id:)`.
@Suite struct RemoteSessionFolderRemovalTests {
  /// Creates the folder with a file in it and returns the file.
  @discardableResult
  private func filled(_ folder: String) throws -> String {
    try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    let file = "\(folder)/claude.sh"
    try Data("exec claude\n".utf8).write(to: URL(fileURLWithPath: file))
    return file
  }

  private func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

  @Test(.timeLimit(.minutes(1)))
  func theLauncherFolderOfTheSessionIsRemovedAndNoOtherOne() throws {
    try withSite { b in
      let facts = try b.ready()
      let sessions = "\(facts.folder)/sessions"
      try filled("\(sessions)/s1abc")
      let other = try filled("\(sessions)/s2xyz")

      try b.site.removeSessionFolder("\(sessions)/s1abc", of: "s1abc")

      #expect(!exists("\(sessions)/s1abc"))
      #expect(exists(other))
      #expect(exists(sessions))
      #expect(b.sent.runs.allSatisfy { $0.timeout != nil })
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func aLauncherFolderThatIsAlreadyGoneIsNoError() throws {
    try withSite { b in
      let facts = try b.ready()

      try b.site.removeSessionFolder("\(facts.folder)/sessions/s1abc", of: "s1abc")

      #expect(exists("\(facts.folder)/sessions"))
    }
  }

  @Test(
    .timeLimit(.minutes(1)),
    arguments: [
      "", "s", "S1", "s1/x", "s1/..", "../x", "..", ".", "-rf", "s1\n", "s1 ", " s1", "x1", "s-1", "s_1", "s1.", "s1*",
      "s1abc/../s2xyz", "sé1",
    ])
  func anIdThatIsNotASessionIdIsRefusedAndRemovesNothing(id: String) throws {
    try withSite { b in
      let facts = try b.ready()
      let sessions = "\(facts.folder)/sessions"
      var canaries = [
        try filled("\(sessions)/s1abc"), try filled("\(sessions)/s2xyz"), try filled("\(sessions)/s1"),
        try filled("\(facts.folder)/x"), try filled("\(facts.home)/x"),
      ]
      let path = "\(sessions)/\(id)"
      if let file = try? filled(path) { canaries.append(file) }

      #expect(throws: (any Error).self) { try b.site.removeSessionFolder(path, of: id) }

      for canary in canaries { #expect(exists(canary), "\(canary)") }
      #expect(exists(sessions))
    }
  }

  @Test(
    .timeLimit(.minutes(1)),
    arguments: [
      "the box's Switchboard folder", "the sessions folder", "the box's home", "another session's folder",
      "a folder of the id outside sessions", "a path through a dot-dot", "a relative path", "a path with a tilde",
      "this Mac's launcher folder of the session",
    ])
  func aPathOtherThanTheSessionsOwnFolderIsRefusedAndRemovesNothing(shape: String) throws {
    try withSite { b in
      let facts = try b.ready()
      let sessions = "\(facts.folder)/sessions"
      var canaries = [try filled("\(sessions)/s1abc"), try filled("\(sessions)/s2xyz")]
      let path: String
      switch shape {
      case "the box's Switchboard folder": path = facts.folder
      case "the sessions folder": path = sessions
      case "the box's home": path = facts.home
      case "another session's folder": path = "\(sessions)/s2xyz"
      case "a folder of the id outside sessions": path = "\(facts.folder)/other/s1abc"
      case "a path through a dot-dot": path = "\(sessions)/s1abc/../s2xyz"
      case "a relative path": path = "sessions/s1abc"
      case "a path with a tilde": path = "~/.sb/sessions/s1abc"
      default: path = "\(b.home)/sessions/s1abc"
      }
      for folder in ["\(facts.folder)/other/s1abc", "\(facts.home)/sessions/s1abc", "\(b.home)/sessions/s1abc"] {
        canaries.append(try filled(folder))
      }

      #expect(throws: (any Error).self) { try b.site.removeSessionFolder(path, of: "s1abc") }

      for canary in canaries { #expect(exists(canary), "\(canary)") }
    }
  }

  /// `rm -rf` of a link removes the link. The folder that it points at, here one outside the box's Switchboard
  /// folder, keeps its files whether sbd refuses or removes the link.
  @Test(.timeLimit(.minutes(1)))
  func aLauncherFolderThatIsALinkNeverRemovesWhatItPointsAt() throws {
    try withSite { b in
      let facts = try b.ready()
      let precious = try filled("\(b.home)/precious")
      try FileManager.default.createDirectory(atPath: "\(facts.folder)/sessions", withIntermediateDirectories: true)
      try FileManager.default.createSymbolicLink(
        atPath: "\(facts.folder)/sessions/s1abc", withDestinationPath: "\(b.home)/precious")

      try? b.site.removeSessionFolder("\(facts.folder)/sessions/s1abc", of: "s1abc")

      #expect(exists(precious))
    }
  }

  /// `.sb` or `.sb/sessions` is a link to a folder elsewhere that holds a folder of the session's id. The removal
  /// refuses, and that folder keeps its files.
  @Test(.timeLimit(.minutes(1)), arguments: [".sb", ".sb/sessions"])
  func aLinkAboveTheLauncherFolderIsRefusedAndRemovesNothingWhereItLeads(linked: String) throws {
    try withSite { b in
      let facts = try b.ready()
      let target = "\(b.home)/elsewhere"
      let precious = try filled(linked == ".sb" ? "\(target)/sessions/s1abc" : "\(target)/s1abc")
      try replaceWithLink("\(facts.home)/\(linked)", to: target, keeping: "\(b.home)/moved")

      #expect(throws: (any Error).self) {
        try b.site.removeSessionFolder("\(facts.folder)/sessions/s1abc", of: "s1abc")
      }

      #expect(exists(precious))
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func aSessionsFolderThatIsAFileIsRefusedAndKeepsTheFile() throws {
    try withSite { b in
      let facts = try b.ready()
      let sessions = "\(facts.folder)/sessions"
      try FileManager.default.removeItem(atPath: sessions)
      try Data("keep\n".utf8).write(to: URL(fileURLWithPath: sessions))

      #expect(throws: (any Error).self) { try b.site.removeSessionFolder("\(sessions)/s1abc", of: "s1abc") }

      #expect(FileManager.default.contents(atPath: sessions) == Data("keep\n".utf8))
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func aSessionsFolderThatIsGoneIsNoError() throws {
    try withSite { b in
      let facts = try b.ready()
      try FileManager.default.removeItem(atPath: "\(facts.folder)/sessions")

      try b.site.removeSessionFolder("\(facts.folder)/sessions/s1abc", of: "s1abc")
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func theRemovalThrowsHostUnreadWhenTheLinkDroppedAndRemovesNothing() throws {
    try withSite { b in
      let facts = try b.ready()
      let file = try filled("\(facts.folder)/sessions/s1abc")
      let master = try #require(b.bench.masters().last)
      b.bench.drop(master)
      try b.bench.waitFor(.unreachable)

      #expect { try b.site.removeSessionFolder("\(facts.folder)/sessions/s1abc", of: "s1abc") } throws: {
        isUnread($0)
      }

      #expect(exists(file))
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func theRemovalThrowsHostUnreadOnAConnectionWhoseSetupHasNotRunAndRemovesNothing() throws {
    try withSite { b in
      let facts = try b.ready()
      let file = try filled("\(facts.folder)/sessions/s1abc")
      try b.reconnect()

      #expect { try b.site.removeSessionFolder("\(facts.folder)/sessions/s1abc", of: "s1abc") } throws: {
        isUnread($0)
      }

      #expect(exists(file))
    }
  }
}

// MARK: One scope of a removal

/// A removal runs its checks and its git commands in one `scoped` call. The scope's machine refuses each command
/// once a command of the scope got no answer or the link left the scope's connection, so no command, a destructive
/// one included, runs on what a missing answer or a later connection would decide.
@Suite struct RemoteSiteScopeTests {
  @Test(.timeLimit(.minutes(1)))
  func aScopeWhoseCommandsWereAnsweredReturnsTheBodysResult() throws {
    try withSite { b in
      try b.ready()

      let out = try b.site.scoped("a test") { scope in
        try scope.require()
        return try scope.site.machine.run("/bin/echo", ["hi"]).stdout
      }

      #expect(out == "hi\n")
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func aCommandAfterOneThatGotNoAnswerIsNotSentAndTheScopeThrowsHostUnread() throws {
    try withSite(scripts: true) { b in
      try b.ready()
      try b.set("script-status", "143")
      var refused = false
      var sentAfter = 0

      #expect {
        try b.site.scoped("a test") { scope in
          _ = try scope.site.machine.run("/bin/sh", ["-c", "true"])
          let before = b.sent.runs.count
          do {
            _ = try scope.site.machine.run("/bin/echo", ["hi"])
          } catch {
            refused = isUnread(error)
          }
          #expect(!scope.site.machine.exists("/"), "a file read after a missing answer read as an answer")
          sentAfter = b.sent.runs.count - before + b.sent.calls.count
        }
      } throws: { isUnread($0) }

      #expect(refused)
      #expect(sentAfter == 0, "the scope sent \(sentAfter) commands after one got no answer")
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func aScopeWhoseLinkReconnectedRefusesTheNextCommandAndThrowsHostUnread() throws {
    try withSite { b in
      try b.ready()
      var refused = false

      #expect {
        try b.site.scoped("a test") { scope in
          try b.reconnect()
          _ = try b.site.prepare()
          do {
            _ = try scope.site.machine.run("/bin/echo", ["hi"])
          } catch {
            refused = isUnread(error)
          }
          #expect(throws: (any Error).self) { try scope.require() }
        }
      } throws: { isUnread($0) }

      #expect(refused, "a command ran on a connection that the scope did not begin on")
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func aScopeOnAConnectionWhoseSetupHasNotRunThrowsBeforeItsBodyRuns() throws {
    try withSite { b in
      try b.ready()
      try b.reconnect()
      var ran = false

      #expect { try b.site.scoped("a test") { _ in ran = true } } throws: { isUnread($0) }

      #expect(!ran)
    }
  }
}
