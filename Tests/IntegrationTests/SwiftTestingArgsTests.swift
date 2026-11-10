import Foundation
import SwitchboardCore
import Testing

/// A developer folder for one test, built from empty files and folders at the
/// paths that bin/lib/swift-testing.sh checks. Its path has a space in it.
private final class FakeDeveloperDir {
  let root: String
  let path: String

  init(folders: [String] = [], files: [String] = []) throws {
    var template = Array("/tmp/sbx.XXXXXX".utf8CString)
    guard let dir = mkdtemp(&template) else { throw TestError(description: "mkdtemp failed") }
    root = String(cString: dir)
    path = "\(root)/Developer dir"
    let fm = FileManager.default
    try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
    for folder in folders {
      try fm.createDirectory(atPath: "\(path)/\(folder)", withIntermediateDirectories: true)
    }
    for file in files {
      let full = "\(path)/\(file)"
      try fm.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
      fm.createFile(atPath: full, contents: nil)
    }
  }

  deinit { try? FileManager.default.removeItem(atPath: root) }

  static let plugins = "usr/lib/swift/host/plugins/testing"
  static let frameworks = "Library/Developer/Frameworks"
  static let cltFramework = "\(frameworks)/Testing.framework"
  static let interopDylib = "Library/Developer/usr/lib/lib_TestingInterop.dylib"
  static let xcodeFramework = "Platforms/MacOSX.platform/Developer/Library/Frameworks/Testing.framework"

  enum Flag: Sendable { case plugin, framework, dylib }

  func flags(_ flag: Flag) -> [String] {
    switch flag {
    case .plugin: return ["-Xswiftc", "-plugin-path", "-Xswiftc", "\(path)/\(Self.plugins)"]
    case .framework:
      let dir = "\(path)/\(Self.frameworks)"
      return ["-Xswiftc", "-F", "-Xswiftc", dir, "-Xlinker", "-rpath", "-Xlinker", dir]
    case .dylib: return ["-Xlinker", "-rpath", "-Xlinker", "\(path)/Library/Developer/usr/lib"]
    }
  }
}

private struct Layout: Sendable, CustomTestStringConvertible {
  var name: String
  var folders: [String] = []
  var files: [String] = []
  var expected: [FakeDeveloperDir.Flag] = []

  var testDescription: String { name }
}

/// Runs a bash script that sources bin/lib/swift-testing.sh.
/// `developerDir` sets DEVELOPER_DIR, and nil removes it from the environment.
private func runHelper(_ body: String, developerDir: String?, errexit: Bool = true) throws -> CommandResult {
  let helper = Instance.root.appendingPathComponent("bin/lib/swift-testing.sh").path
  var env = ProcessInfo.processInfo.environment
  env["DEVELOPER_DIR"] = developerDir
  let options = errexit ? "set -euo pipefail" : "set -uo pipefail"
  return try runCommand("/bin/bash", ["-c", "\(options)\nsource \(shellQuote(helper))\n\(body)"], env: env, timeout: 30)
}

/// The `args` array that sourcing the helper sets, one element per line. The
/// script fails when `args` is not an array, so an unset `args` can't pass
/// as an empty one.
private func sourcedArgs(developerDir: String?) throws -> (result: CommandResult, args: [String]) {
  let body = """
    [[ "$(declare -p args 2>/dev/null)" == "declare -a"* ]] || { echo "args is not an array" >&2; exit 3; }
    printf "%s\\n" ${args[@]+"${args[@]}"}
    """
  let r = try runHelper(body, developerDir: developerDir)
  return (r, r.stdout.split(separator: "\n").map(String.init))
}

/// Runs `call` without `set -e`, so only an `exit` in `require_swift_testing`
/// stops the line after it. It checks first that sourcing defined the
/// function, so a missing helper or function can't pass as a refusal.
private func requireSwiftTesting(developerDir: String, call: String) throws -> CommandResult {
  let body = """
    declare -F require_swift_testing >/dev/null || { echo "require_swift_testing is not defined" >&2; exit 3; }
    echo sourced
    \(call)
    echo after
    """
  return try runHelper(body, developerDir: developerDir, errexit: false)
}

@Suite(.blocking(timeLimit: .seconds(60))) struct SwiftTestingArgsTests {
  @Test(arguments: [
    Layout(
      name: "Command Line Tools", folders: [FakeDeveloperDir.plugins, FakeDeveloperDir.cltFramework],
      files: [FakeDeveloperDir.interopDylib], expected: [.plugin, .framework, .dylib]),
    Layout(name: "plugins only", folders: [FakeDeveloperDir.plugins], expected: [.plugin]),
    Layout(name: "plugins path is a file", files: [FakeDeveloperDir.plugins]),
    Layout(name: "framework only", folders: [FakeDeveloperDir.cltFramework], expected: [.framework]),
    Layout(name: "framework is a file", files: [FakeDeveloperDir.cltFramework], expected: [.framework]),
    Layout(name: "Frameworks folder without Testing", folders: [FakeDeveloperDir.frameworks]),
    Layout(name: "dylib only", files: [FakeDeveloperDir.interopDylib], expected: [.dylib]),
    Layout(
      name: "plugins and dylib", folders: [FakeDeveloperDir.plugins], files: [FakeDeveloperDir.interopDylib],
      expected: [.plugin, .dylib]),
    Layout(name: "Xcode", folders: [FakeDeveloperDir.xcodeFramework]),
    Layout(name: "empty"),
  ])
  fileprivate func argsHoldTheFlagsForEachFileTheLayoutHas(_ layout: Layout) throws {
    let dev = try FakeDeveloperDir(folders: layout.folders, files: layout.files)

    let (r, args) = try sourcedArgs(developerDir: dev.path)

    #expect(r.status == 0, "\(r.stderr)")
    #expect(r.stderr == "")
    #expect(args == layout.expected.flatMap(dev.flags))
  }

  @Test func unsetDeveloperDirMatchesDeveloperDirSetToXcodeSelectPath() throws {
    var env = ProcessInfo.processInfo.environment
    env["DEVELOPER_DIR"] = nil
    let selected = try runCommand("/usr/bin/xcode-select", ["-p"], env: env)
    try #require(selected.status == 0, "\(selected.stderr)")
    let path = selected.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

    let unset = try sourcedArgs(developerDir: nil)
    let set = try sourcedArgs(developerDir: path)

    #expect(unset.result.status == 0, "\(unset.result.stderr)")
    #expect(unset.args == set.args)
  }

  /// Each layout lacks both Testing.framework paths, though some hold the other
  /// files. The caller ignores the status, so only an `exit` stops the script.
  @Test(arguments: [
    [],
    [FakeDeveloperDir.plugins],
    [FakeDeveloperDir.frameworks],
    [FakeDeveloperDir.plugins, FakeDeveloperDir.interopDylib],
    ["Platforms/MacOSX.platform/Developer/Library/Frameworks"],
    ["Platforms/iPhoneOS.platform/Developer/Library/Frameworks/Testing.framework"],
  ])
  func requireExitsWithoutEitherTestingFramework(_ folders: [String]) throws {
    let dev = try FakeDeveloperDir(folders: folders)

    let r = try requireSwiftTesting(developerDir: dev.path, call: "require_swift_testing || true")

    #expect(r.stdout == "sourced\n", "\(r.stderr)")
    #expect(r.status != 0)
  }

  @Test func requireNamesTheToolchainsAndTheFolderItLookedIn() throws {
    let dev = try FakeDeveloperDir()

    let r = try requireSwiftTesting(developerDir: dev.path, call: "require_swift_testing")

    #expect(r.stderr.contains("Xcode"), "\(r.stderr)")
    #expect(r.stderr.contains("Command Line Tools"), "\(r.stderr)")
    #expect(r.stderr.contains(dev.path), "\(r.stderr)")
  }

  @Test(arguments: [FakeDeveloperDir.cltFramework, FakeDeveloperDir.xcodeFramework])
  func requireReturnsZeroAndPrintsNothingWithATestingFramework(_ framework: String) throws {
    let dev = try FakeDeveloperDir(folders: [framework])

    let r = try requireSwiftTesting(developerDir: dev.path, call: "require_swift_testing || exit 4")

    #expect(r.status == 0, "\(r.stderr)")
    #expect(r.stdout == "sourced\nafter\n")
    #expect(r.stderr == "")
  }
}
