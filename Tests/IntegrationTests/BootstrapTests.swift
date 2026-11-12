import Foundation
import SwitchboardCore
import Testing

/// A temp folder with an empty home and a folder of stub executables that goes first on PATH. `Repos` removes it.
private class StubMachine {
  let repos: Repos
  var root: String { repos.root }
  var home: String { "\(root)/home" }
  var stubs: String { "\(root)/stubs" }
  var fallback: String { "\(root)/fallback" }
  /// SB_TOOL_FOLDERS keeps check_prerequisites from finding the real tools in Homebrew's folders.
  var env: [String: String] { ["HOME": home, "PATH": "\(stubs):/usr/bin:/bin", "SB_TOOL_FOLDERS": fallback] }

  init(tools: [String]) throws {
    repos = try Repos()
    try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: stubs, withIntermediateDirectories: true)
    for tool in tools { try stub(tool) }
  }

  func stub(_ name: String, _ body: String = "exit 0") throws { try writeScript("\(stubs)/\(name)", body) }
}

private func writeScript(_ path: String, _ body: String) throws {
  try FileManager.default.createDirectory(
    atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
  try "#!/bin/bash\n\(body)\n".write(toFile: path, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
}

/// A new Mac with the Command Line Tools and a Switchboard repo to clone. The repo's bin/install and bin/start only
/// record that they ran in `<home>/calls`. bin/install also creates the app folder and reads stdin, the way a
/// build tool can.
private final class NewMachine: StubMachine {
  var source: String { "\(root)/source" }
  var checkout: String { "\(home)/dev/haacked/switchboard" }
  var app: String { "\(home)/Applications/Switchboard.app" }
  var cloned: Bool { FileManager.default.fileExists(atPath: checkout) }

  init() throws {
    try super.init(tools: [])
    try stub("xcode-select", "echo /Library/Developer/CommandLineTools")
    try Repos.create(source)
    try writeScript(
      "\(source)/bin/install",
      "cat >/dev/null\nmkdir -p \"$HOME/Applications/Switchboard.app\"\necho install >>\"$HOME/calls\"")
    try writeScript("\(source)/bin/start", "echo start >>\"$HOME/calls\"")
    try Repos.git(source, "add", ".")
    try Repos.commit(source, "bin")
  }

  /// Runs bin/bootstrap the way the one-liner does: bash reads the script from a pipe.
  func bootstrap(_ args: [String] = [], dir: String? = nil) throws -> CommandResult {
    let script = try Data(contentsOf: Instance.root.appendingPathComponent("bin/bootstrap"))
    var env = self.env
    env["SWITCHBOARD_REPO"] = source
    env["SWITCHBOARD_DIR"] = dir
    return try runCommand("/bin/bash", ["-s", "--"] + args, env: env, input: script, timeout: 60)
  }

  var calls: [String] {
    ((try? String(contentsOfFile: "\(home)/calls", encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
  }
}

@Suite(.blocking(timeLimit: .seconds(60))) struct BootstrapTests {
  @Test func aNewMachineClonesInstallsAndOpens() throws {
    let machine = try NewMachine()

    let r = try machine.bootstrap()

    #expect(r.status == 0, "\(r.stderr)")
    #expect(try Repos.git(machine.checkout, "remote", "get-url", "origin") == machine.source)
    #expect(machine.calls == ["install", "start"])
  }

  @Test func switchboardDirSetsTheCheckoutFolder() throws {
    let machine = try NewMachine()
    let dir = "\(machine.root)/elsewhere/switchboard"

    let r = try machine.bootstrap(dir: dir)

    #expect(r.status == 0, "\(r.stderr)")
    #expect(FileManager.default.fileExists(atPath: "\(dir)/bin/install"))
    #expect(!machine.cloned)
  }

  @Test func anInstalledAppIsLeftAlone() throws {
    let machine = try NewMachine()
    try FileManager.default.createDirectory(atPath: machine.app, withIntermediateDirectories: true)

    let r = try machine.bootstrap()

    #expect(r.status == 0, "\(r.stderr)")
    #expect(r.stdout.contains("already installed"), "\(r.stdout)")
    #expect(r.stdout.contains("bin/update"), "\(r.stdout)")
    #expect(!machine.cloned)
    #expect(machine.calls.isEmpty)
  }

  @Test func anExistingCheckoutInstallsWithoutCloning() throws {
    let machine = try NewMachine()
    try Repos.git(machine.root, "clone", "-q", machine.source, machine.checkout)
    let marker = "\(machine.checkout)/local-change"
    FileManager.default.createFile(atPath: marker, contents: nil)

    let r = try machine.bootstrap()

    #expect(r.status == 0, "\(r.stderr)")
    #expect(FileManager.default.fileExists(atPath: marker))
    #expect(machine.calls == ["install", "start"])
  }

  @Test func aFolderThatIsNotACheckoutIsRefused() throws {
    let machine = try NewMachine()
    try FileManager.default.createDirectory(atPath: machine.checkout, withIntermediateDirectories: true)

    let r = try machine.bootstrap()

    #expect(r.status == 1)
    #expect(r.stderr.contains("isn't a Switchboard checkout"), "\(r.stderr)")
    #expect(r.stderr.contains("SWITCHBOARD_DIR"), "\(r.stderr)")
    #expect(machine.calls.isEmpty)
  }

  @Test func missingCommandLineToolsAreRefusedBeforeCloning() throws {
    let machine = try NewMachine()
    try machine.stub("xcode-select", "exit 2")

    let r = try machine.bootstrap()

    #expect(r.status == 1)
    #expect(r.stderr.contains("xcode-select --install"), "\(r.stderr)")
    #expect(!machine.cloned)
  }

  @Test func anotherSystemIsRefused() throws {
    let machine = try NewMachine()
    try machine.stub("uname", "echo Linux")

    let r = try machine.bootstrap()

    #expect(r.status == 1)
    #expect(r.stderr.contains("macOS"), "\(r.stderr)")
    #expect(!machine.cloned)
  }

  @Test func aFailedInstallDoesNotOpenTheApp() throws {
    let machine = try NewMachine()
    try writeScript("\(machine.source)/bin/install", "exit 3")
    try Repos.git(machine.source, "add", ".")
    try Repos.commit(machine.source, "fail")

    let r = try machine.bootstrap()

    #expect(r.status == 3)
    #expect(machine.calls.isEmpty)
  }

  @Test func anArgumentIsAUsageError() throws {
    let machine = try NewMachine()

    let r = try machine.bootstrap(["--update"])

    #expect(r.status == 2)
    #expect(r.stderr.contains("usage"), "\(r.stderr)")
    #expect(!machine.cloned)
  }
}

@Suite(.blocking(timeLimit: .seconds(60))) struct PrerequisiteTests {
  static let tools = ["tmux", "gh", "claude"]

  private func check(_ machine: StubMachine) throws -> CommandResult {
    let helper = Instance.root.appendingPathComponent("bin/lib/prerequisites.sh").path
    let body = "set -euo pipefail\nsource \(shellQuote(helper))\ncheck_prerequisites"
    return try runCommand("/bin/bash", ["-c", body], env: machine.env, timeout: 30)
  }

  @Test func everyToolPresentPassesQuietly() throws {
    let r = try check(try StubMachine(tools: Self.tools))

    #expect(r.status == 0, "\(r.stderr)")
    #expect(r.stderr == "")
  }

  @Test(arguments: ["tmux", "gh"]) func aMissingToolIsRefused(tool: String) throws {
    let r = try check(try StubMachine(tools: Self.tools.filter { $0 != tool }))

    #expect(r.status == 1)
    #expect(r.stderr.contains("brew install \(tool)"), "\(r.stderr)")
  }

  @Test func everyMissingToolIsListed() throws {
    let r = try check(try StubMachine(tools: []))

    #expect(r.status == 1)
    #expect(r.stderr.contains("brew install tmux"), "\(r.stderr)")
    #expect(r.stderr.contains("brew install gh"), "\(r.stderr)")
  }

  @Test func aMissingClaudeAndASignedOutGhOnlyWarn() throws {
    let machine = try StubMachine(tools: ["tmux"])
    try machine.stub("gh", "exit 1")

    let r = try check(machine)

    #expect(r.status == 0, "\(r.stderr)")
    #expect(r.stderr.contains("claude is not on PATH"), "\(r.stderr)")
    #expect(r.stderr.contains("gh auth login"), "\(r.stderr)")
  }

  @Test func aToolOutsidePathInTheFoldersSbdSearchesPasses() throws {
    let machine = try StubMachine(tools: ["claude"])
    try writeScript("\(machine.fallback)/tmux", "exit 0")
    try writeScript("\(machine.fallback)/gh", "exit 0")

    let r = try check(machine)

    #expect(r.status == 0, "\(r.stderr)")
    #expect(r.stderr == "")
  }

  /// The swift stub fails loudly, so a bin/install that skips the check fails with the wrong message.
  @Test func binInstallChecksBeforeItBuilds() throws {
    let machine = try StubMachine(tools: ["gh", "claude"])
    try machine.stub("swift", "echo 'swift ran' >&2; exit 99")

    let r = try runCommand(
      Instance.root.appendingPathComponent("bin/install").path, [], env: machine.env, timeout: 30)

    #expect(r.status == 1)
    #expect(r.stderr.contains("brew install tmux"), "\(r.stderr)")
    #expect(!r.stderr.contains("swift ran"), "\(r.stderr)")
  }

  /// bin/update checks before it quits the app. Without the check, it refuses for another reason, such as the branch.
  @Test func binUpdateChecksBeforeItQuitsTheApp() throws {
    let machine = try StubMachine(tools: ["gh", "claude"])

    let r = try runCommand(
      Instance.root.appendingPathComponent("bin/update").path, [], env: machine.env, timeout: 30)

    #expect(r.status == 1)
    #expect(r.stderr.contains("brew install tmux"), "\(r.stderr)")
  }
}
