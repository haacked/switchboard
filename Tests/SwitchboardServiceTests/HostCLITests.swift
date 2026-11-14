import Foundation
import Testing

@testable import SwitchboardCore
@testable import SwitchboardService

private final class BundleMarker {}

/// The `sb` that SwiftPM built next to the test bundle, with its symlinks resolved. `SB_BIN_DIR` overrides the
/// folder, as it does for the integration tests. The sandbox's exec rule names a real path, so a test runs this one.
let builtSb: String = {
  let folder =
    ProcessInfo.processInfo.environment["SB_BIN_DIR"]
    ?? URL(fileURLWithPath: Bundle(for: BundleMarker.self).bundlePath).deletingLastPathComponent().path
  let path = "\(folder)/sb"
  guard let resolved = realpath(path, nil) else { return path }
  defer { free(resolved) }
  return String(cString: resolved)
}()

private func real(_ path: String) -> String {
  guard let resolved = realpath(path, nil) else { return path }
  defer { free(resolved) }
  return String(cString: resolved)
}

private let mib = 1024 * 1024

// MARK: The request

/// The fields of a `cli` request that parse, with the extra keys merged in and the named keys left out.
private func cliArgs(_ more: [String: JSON] = [:], without: Set<String> = []) -> JSON {
  var fields: [String: JSON] = ["argv": ["ls", "--json"], "cwd": "/home/u/worktrees/x"]
  fields.merge(more) { $1 }
  for key in without { fields[key] = nil }
  return .object(fields)
}

private func words(_ items: [String]) -> JSON { .array(items.map(JSON.string)) }

private func base64(_ data: Data) -> JSON { .string(data.base64EncodedString()) }

/// Each shape that `HostCLIRequest.parse` refuses, by name. The shapes are built on demand, because some hold
/// megabytes.
private func refusedShape(_ name: String) -> JSON {
  switch name {
  case "args is an array": return .array([words(["ls"])])
  case "args is a string": return "ls --json"
  case "args is null": return .null
  case "an env key": return cliArgs(["env": ["SB_HOME": "/Users/u/.sb"]])
  case "an SB_HOME key": return cliArgs(["SB_HOME": "/Users/u/.sb"])
  case "a home key": return cliArgs(["home": "/Users/u/.sb"])
  case "a host key": return cliArgs(["host": "other"])
  case "no argv": return cliArgs(without: ["argv"])
  case "an empty argv": return cliArgs(["argv": []])
  case "argv is a string": return cliArgs(["argv": "ls --json"])
  case "argv holds a number": return cliArgs(["argv": ["ls", 1]])
  case "argv holds null": return cliArgs(["argv": ["ls", .null]])
  case "argv holds an object": return cliArgs(["argv": ["ls", ["a": "b"]]])
  case "a NUL in a word": return cliArgs(["argv": words(["send", "s1", "a\u{0}b"])])
  case "a NUL as a word": return cliArgs(["argv": words(["ls", "\u{0}"])])
  case "1,001 words": return cliArgs(["argv": words(Array(repeating: "w", count: 1_001))])
  case "1 MiB and 1 byte in one word": return cliArgs(["argv": words([String(repeating: "x", count: mib + 1)])])
  case "1 MiB and 1 byte across words":
    return cliArgs(["argv": words(["send", String(repeating: "x", count: mib + 1 - 4)])])
  // Two bytes each, so the count of characters is under 1 MiB and the count of bytes is over it.
  case "1 MiB and 2 bytes of two-byte characters":
    return cliArgs(["argv": words([String(repeating: "é", count: mib / 2 + 1)])])
  case "no cwd": return cliArgs(without: ["cwd"])
  case "a relative cwd": return cliArgs(["cwd": "worktrees/x"])
  case "an empty cwd": return cliArgs(["cwd": ""])
  case "a cwd that starts with ~": return cliArgs(["cwd": "~/worktrees/x"])
  case "a NUL in the cwd": return cliArgs(["cwd": "/home/u\u{0}/x"])
  case "a newline in the cwd": return cliArgs(["cwd": "/home/u\n/x"])
  case "a cwd of 4,097 bytes": return cliArgs(["cwd": .string("/" + String(repeating: "x", count: 4_096))])
  case "a cwd of 4,097 bytes in two-byte characters":
    return cliArgs(["cwd": .string("/" + String(repeating: "é", count: 2_048))])
  case "a cwd that is a number": return cliArgs(["cwd": 7])
  case "a session with a slash": return cliArgs(["session": "s1/../l1"])
  case "a session with a space": return cliArgs(["session": "s1 l1"])
  case "a session of 65 bytes": return cliArgs(["session": .string(String(repeating: "a", count: 65))])
  case "an empty session": return cliArgs(["session": ""])
  case "a session of a dot": return cliArgs(["session": "."])
  case "a session with é": return cliArgs(["session": "sé1"])
  case "a session with an Arabic-Indic digit": return cliArgs(["session": "s\u{0663}"])
  case "a session with a newline": return cliArgs(["session": "s1\n"])
  case "a session with a NUL": return cliArgs(["session": "s1\u{0}"])
  case "a session that is a number": return cliArgs(["session": 1])
  case "a claudecode with a newline": return cliArgs(["claudecode": "1\n"])
  case "a claudecode of 17 bytes": return cliArgs(["claudecode": .string(String(repeating: "1", count: 17))])
  case "a claudecode of 18 bytes in nine characters":
    return cliArgs(["claudecode": .string(String(repeating: "é", count: 9))])
  case "a claudecode with an escape": return cliArgs(["claudecode": "1\u{1B}[2J"])
  case "a claudecode with a tab": return cliArgs(["claudecode": "1\t"])
  case "a claudecode with DEL": return cliArgs(["claudecode": "1\u{7F}"])
  case "a claudecode with a NUL": return cliArgs(["claudecode": "1\u{0}"])
  case "a claudecode that is a number": return cliArgs(["claudecode": 1])
  case "stdin that is not base64": return cliArgs(["stdin": "not base64!"])
  case "stdin that is a number": return cliArgs(["stdin": 1])
  case "stdin of 16 MiB and 1 byte": return cliArgs(["stdin": base64(Data(count: 16 * mib + 1))])
  default: fatalError("no shape \(name)")
  }
}

private let refusedShapes = [
  "args is an array", "args is a string", "args is null", "an env key", "an SB_HOME key", "a home key",
  "a host key", "no argv", "an empty argv", "argv is a string", "argv holds a number", "argv holds null",
  "argv holds an object", "a NUL in a word", "a NUL as a word", "1,001 words", "1 MiB and 1 byte in one word",
  "1 MiB and 1 byte across words", "1 MiB and 2 bytes of two-byte characters", "no cwd", "a relative cwd",
  "an empty cwd", "a cwd that starts with ~", "a NUL in the cwd", "a newline in the cwd", "a cwd of 4,097 bytes",
  "a cwd of 4,097 bytes in two-byte characters", "a cwd that is a number", "a session with a slash",
  "a session with a space", "a session of 65 bytes", "an empty session", "a session of a dot", "a session with é",
  "a session with an Arabic-Indic digit", "a session with a newline", "a session with a NUL",
  "a session that is a number", "a claudecode with a newline", "a claudecode of 17 bytes",
  "a claudecode of 18 bytes in nine characters", "a claudecode with an escape", "a claudecode with a tab",
  "a claudecode with DEL", "a claudecode with a NUL", "a claudecode that is a number", "stdin that is not base64",
  "stdin that is a number", "stdin of 16 MiB and 1 byte",
]

/// Each shape at a limit that `HostCLIRequest.parse` takes, by name.
private func takenShape(_ name: String) -> JSON {
  switch name {
  case "1,000 words": return cliArgs(["argv": words(Array(repeating: "w", count: 1_000))])
  case "1 MiB in one word": return cliArgs(["argv": words([String(repeating: "x", count: mib)])])
  case "a cwd of 4,096 bytes": return cliArgs(["cwd": .string("/" + String(repeating: "x", count: 4_095))])
  case "a session of 64 bytes": return cliArgs(["session": .string(String(repeating: "a", count: 64))])
  case "a session of every allowed kind of character": return cliArgs(["session": "aZ09_-"])
  case "a claudecode of 16 bytes": return cliArgs(["claudecode": .string(String(repeating: "1", count: 16))])
  case "stdin of 16 MiB": return cliArgs(["stdin": base64(Data(count: 16 * mib))])
  case "empty stdin": return cliArgs(["stdin": ""])
  default: fatalError("no shape \(name)")
  }
}

private let takenShapes = [
  "1,000 words", "1 MiB in one word", "a cwd of 4,096 bytes", "a session of 64 bytes",
  "a session of every allowed kind of character", "a claudecode of 16 bytes", "stdin of 16 MiB", "empty stdin",
]

/// What sbd takes from a host's `cli` request: an argv, the box's folder, and the optional session, `CLAUDECODE`,
/// and stdin. Every other key, and every field outside its limits, fails the request before anything runs.
@Suite struct HostCLIRequestTests {
  @Test func aRequestWithEveryFieldParsesToThoseFields() throws {
    let stdin = Data([0xFF, 0x00, 0x7B, 0x0A])

    let request = try HostCLIRequest.parse(
      cliArgs(["session": "s1a2b3", "claudecode": "1", "stdin": base64(stdin)]))

    #expect(request.argv == ["ls", "--json"])
    #expect(request.cwd == "/home/u/worktrees/x")
    #expect(request.session == "s1a2b3")
    #expect(request.claudecode == "1")
    #expect(request.stdin == stdin)
  }

  @Test func aRequestWithOnlyArgvAndCwdHasNoSessionNoClaudecodeAndNoStdin() throws {
    let request = try HostCLIRequest.parse(cliArgs())

    #expect(request.session == nil)
    #expect(request.claudecode == nil)
    #expect(request.stdin.isEmpty)
  }

  /// argv reaches `execve` as words, so a word that a shell would read stays one word, as sent.
  @Test(arguments: [
    ";", "a; rm -rf ~", "$(touch /tmp/pwned)", "`id`", "a\nb", "SB_HOME=/Users/u/.sb", "--json", "", " ", "é ✓ 🎉",
    "'", "\"", "\\", "*", "-",
  ])
  func aWordThatAShellWouldReadIsKeptAsOneWord(word: String) throws {
    let request = try HostCLIRequest.parse(cliArgs(["argv": words(["send", "s1", word, "tail"])]))

    #expect(request.argv == ["send", "s1", word, "tail"])
  }

  @Test(.timeLimit(.minutes(1)), arguments: refusedShapes)
  func aRequestOutsideItsFieldsOrLimitsIsRefused(shape: String) {
    let args = refusedShape(shape)

    #expect(throws: (any Error).self, "\(shape)") { try HostCLIRequest.parse(args) }
  }

  @Test(.timeLimit(.minutes(1)), arguments: takenShapes)
  func aRequestAtALimitIsTaken(shape: String) throws {
    _ = try HostCLIRequest.parse(takenShape(shape))
  }
}

// MARK: The environment

/// The subprocess's environment is built from nothing, so neither sbd's environment nor the request can set a
/// variable that changes its socket, home, or identity.
@Suite struct HostCLIEnvironmentTests {
  @Test func theEnvironmentOfARequestWithASessionAndClaudecodeIsExactlyTheseVariables() {
    let env = HostCLI.environment(
      hostHome: "/Users/u/.sb/hosts/mini", host: "mini", cwd: "/home/u/worktrees/x", session: "s1a2b3",
      claudecode: "1")

    #expect(
      env == [
        "SB_HOME": "/Users/u/.sb/hosts/mini", "HOME": "/Users/u/.sb/hosts/mini", "SB_CLI_HOST": "mini",
        "SB_CLI_CWD": "/home/u/worktrees/x", "PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8",
        "SB_SESSION_ID": "s1a2b3", "CLAUDECODE": "1",
      ])
  }

  @Test func theEnvironmentOfARequestWithNeitherHasNoSessionAndNoClaudecode() {
    let env = HostCLI.environment(
      hostHome: "/Users/u/.sb/hosts/mini", host: "mini", cwd: "/home/u/worktrees/x", session: nil, claudecode: nil)

    #expect(
      env == [
        "SB_HOME": "/Users/u/.sb/hosts/mini", "HOME": "/Users/u/.sb/hosts/mini", "SB_CLI_HOST": "mini",
        "SB_CLI_CWD": "/home/u/worktrees/x", "PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8",
      ])
  }
}

// MARK: The profile

/// A folder under /tmp, whose real path starts with /private/tmp, holding a file that stands in for `sb` and a
/// socket that stands in for the host's.
private func withProfileFolder(_ body: (_ root: String, _ sb: String, _ socket: String) throws -> Void) throws {
  let root = try makeShortTempFolder()
  defer { try? FileManager.default.removeItem(atPath: root) }
  try FileManager.default.createDirectory(atPath: "\(root)/bin", withIntermediateDirectories: true)
  try FileManager.default.createDirectory(atPath: "\(root)/hosts/mini", withIntermediateDirectories: true)
  FileManager.default.createFile(atPath: "\(root)/bin/sb", contents: Data("#!/bin/sh\n".utf8))
  let socket = "\(root)/hosts/mini/sbd.sock"
  let fd = try UnixSocket.listen(path: socket)
  defer { close(fd) }
  try body(root, "\(root)/bin/sb", socket)
}

/// The characters that the profile can't quote. The profile names each path in a string literal.
private let unquotable = ["\"", "\\", "\n", "\u{1}", "\u{1B}", "\u{7F}"]

/// The sandbox profile that the `cli` subprocess runs under. It names the real paths of `sb` and of the host's
/// socket, and it refuses a path that it can't write as a string literal.
@Suite struct HostCLIProfileTests {
  @Test(.timeLimit(.minutes(1)))
  func theProfileDeniesByDefault() throws {
    try withProfileFolder { _, sb, socket in
      let profile = try HostCLI.profile(sb: sb, socket: socket)

      #expect(profile.contains("(deny default)"), "\(profile)")
      #expect(!profile.contains("(allow default)"), "\(profile)")
    }
  }

  /// /tmp is a link to /private/tmp. A rule that names a path through a link matches nothing.
  @Test(.timeLimit(.minutes(1)))
  func theProfileNamesTheRealPathsOfSbAndOfTheSocket() throws {
    try withProfileFolder { root, sb, socket in
      try #require(real(root).hasPrefix("/private/tmp/"), "\(real(root))")

      let profile = try HostCLI.profile(sb: sb, socket: socket)

      #expect(profile.contains("\"\(real(sb))\""), "\(profile)")
      #expect(profile.contains("\"\(real(socket))\""), "\(profile)")
      #expect(!profile.contains("\"\(root)"), "the profile names a path through /tmp: \(profile)")
    }
  }

  /// SwiftPM's `.build/debug` is a link, and a spike found that an exec rule through it fails.
  @Test(.timeLimit(.minutes(1)))
  func theProfileNamesTheRealPathOfAnSbReachedThroughALink() throws {
    try withProfileFolder { root, sb, socket in
      try FileManager.default.createSymbolicLink(atPath: "\(root)/linked", withDestinationPath: "\(root)/bin")

      let profile = try HostCLI.profile(sb: "\(root)/linked/sb", socket: socket)

      #expect(profile.contains("\"\(real(sb))\""), "\(profile)")
      #expect(!profile.contains("linked"), "\(profile)")
    }
  }

  @Test(.timeLimit(.minutes(1)), arguments: unquotable)
  func anSbPathWithACharacterTheProfileCantQuoteIsRefused(character: String) throws {
    try withProfileFolder { root, _, socket in
      let sb = "\(root)/bin/s\(character)b"
      try #require(FileManager.default.createFile(atPath: sb, contents: Data()), "can't create \(sb)")

      #expect(throws: (any Error).self) { try HostCLI.profile(sb: sb, socket: socket) }
    }
  }

  @Test(.timeLimit(.minutes(1)), arguments: unquotable)
  func aSocketPathWithACharacterTheProfileCantQuoteIsRefused(character: String) throws {
    try withProfileFolder { root, sb, _ in
      let socket = "\(root)/hosts/mini/s\(character)k"
      try #require(FileManager.default.createFile(atPath: socket, contents: Data()), "can't create \(socket)")

      #expect(throws: (any Error).self) { try HostCLI.profile(sb: sb, socket: socket) }
    }
  }

  /// The path that the caller passes is clean, and its real path is not.
  @Test(.timeLimit(.minutes(1)))
  func aCleanLinkToAFolderWhoseNameHoldsAQuoteIsRefused() throws {
    try withProfileFolder { root, _, socket in
      let quoted = "\(root)/q\"uoted"
      try FileManager.default.createDirectory(atPath: quoted, withIntermediateDirectories: true)
      FileManager.default.createFile(atPath: "\(quoted)/sb", contents: Data())
      try FileManager.default.createSymbolicLink(atPath: "\(root)/clean", withDestinationPath: quoted)

      #expect(throws: (any Error).self) { try HostCLI.profile(sb: "\(root)/clean/sb", socket: socket) }
    }
  }

  /// The read rule covers sb's folder, so a folder that holds sbd's state would let sb read it.
  @Test(.timeLimit(.minutes(1)))
  func anSbWhoseFolderHoldsTheHostsSocketIsRefused() throws {
    try withProfileFolder { root, _, socket in
      let sb = "\(root)/sb"
      FileManager.default.createFile(atPath: sb, contents: Data())

      #expect {
        try HostCLI.profile(sb: sb, socket: socket)
      } throws: { error in
        "\(error)".contains("would let sb read")
      }
    }
  }

  /// The read rule covers sb's folder, so a folder that holds the user's home would let sb read the user's files.
  @Test(.timeLimit(.minutes(1)), arguments: ["", "/u"])
  func anSbWhoseFolderHoldsTheUsersHomeIsRefused(under: String) throws {
    try withProfileFolder { root, sb, socket in
      let home = "\(root)/bin\(under)"
      try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)

      #expect {
        try HostCLI.profile(sb: sb, socket: socket, home: home)
      } throws: { error in
        "\(error)".contains("would let sb read")
      }
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func anSbWhoseFolderIsBesideTheUsersHomeIsTaken() throws {
    try withProfileFolder { root, sb, socket in
      _ = try HostCLI.profile(sb: sb, socket: socket, home: "\(root)/hosts")
    }
  }

  @Test(.timeLimit(.minutes(1)), arguments: ["sb", "socket"])
  func aPathThatDoesNotExistIsRefused(missing: String) throws {
    try withProfileFolder { root, sb, socket in
      let gone = "\(root)/gone/\(missing)"

      #expect(throws: (any Error).self) {
        try HostCLI.profile(sb: missing == "sb" ? gone : sb, socket: missing == "socket" ? gone : socket)
      }
    }
  }
}

// MARK: The runner

/// A profile that allows everything, so a runner test checks the runner and not the profile.
private let allowAll = "(version 1)(allow default)"

/// The stand-in for `sb`. Its first word picks what it does. Each mode that runs a program `exec`s it, so the
/// program is the one process that the runner started and no child holds its pipes.
private let standInScript = #"""
  #!/bin/sh
  mode=$1
  shift
  case $mode in
  args) for a in "$@"; do printf '[%s]' "$a"; done ;;
  status) printf out; printf err >&2; exit "$1" ;;
  printed71) printf out; exit 71 ;;
  stdout) exec /usr/bin/head -c "$1" /dev/zero ;;
  stderr) exec /usr/bin/head -c "$1" /dev/zero >&2 ;;
  cat) exec /bin/cat ;;
  pwd) pwd -P ;;
  partial) printf before; printf before-err >&2; exec /bin/sleep 30 ;;
  stubborn) trap '' TERM; printf before; exec /bin/sleep 30 ;;
  hold) : >"$1"; while [ ! -e "$2" ]; do /bin/sleep 0.05; done; printf held ;;
  quick) printf ok ;;
  flood) trap '' PIPE; /usr/bin/head -c "$1" /dev/zero; exec /bin/sleep 30 ;;
  esac
  """#

/// A folder with the stand-in at `prog`, executable.
private func withStandIn(_ body: (_ folder: String, _ program: String) throws -> Void) throws {
  let folder = try makeShortTempFolder()
  defer { try? FileManager.default.removeItem(atPath: folder) }
  let program = "\(folder)/prog"
  try Data(standInScript.utf8).write(to: URL(fileURLWithPath: program))
  chmod(program, 0o755)
  try body(folder, program)
}

private func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

extension HostCLIRunner {
  /// Runs the stand-in's mode with the arguments under the allow-all profile.
  fileprivate func standIn(
    _ mode: String, _ args: [String] = [], host: String = "mini", cwd: String = "/", stdin: Data = Data(),
    cancelled: @escaping () -> Bool = { false }
  ) throws -> HostCLIOutput {
    try run(
      host: host, profile: allowAll, argv: [mode] + args, environment: ["PATH": "/usr/bin:/bin"], cwd: cwd,
      stdin: stdin, cancelled: cancelled)
  }
}

/// The subprocess runner: `sandbox-exec -p <profile> <program> <argv…>` with a deadline, a cancel, a cap on each
/// stream, and at most 8 runs per host at once. Each test runs a `/bin/sh` stand-in under the real `sandbox-exec`.
@Suite struct HostCLIRunnerTests {
  // MARK: What reaches the program

  @Test(.timeLimit(.minutes(1)))
  func theProgramsOutputAndExitStatusComeBackAsTheyWere() throws {
    try withStandIn { _, program in
      let output = try HostCLIRunner(program: program).standIn("status", ["3"])

      #expect(output.status == 3)
      #expect(text(output.stdout) == "out")
      #expect(text(output.stderr) == "err")
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func eachWordReachesTheProgramAsOneArgumentAndNoShellReadsIt() throws {
    try withStandIn { folder, program in
      let sent = [
        ";", "$(touch \(folder)/pwned)", "`touch \(folder)/pwned`", "a\nb", "SB_HOME=/x", "--json", "", "é ✓",
      ]

      let output = try HostCLIRunner(program: program).standIn("args", sent)

      #expect(text(output.stdout) == sent.map { "[\($0)]" }.joined())
      #expect(!FileManager.default.fileExists(atPath: "\(folder)/pwned"))
    }
  }

  /// `/usr/bin/env` runs in place of the stand-in, because `/bin/sh` adds PWD, SHLVL, and `_`. This process has
  /// many variables, such as HOME, that are not in the given set.
  @Test(.timeLimit(.minutes(1)))
  func theProgramGetsExactlyTheEnvironmentItIsGiven() throws {
    let given = ["SB_HOME": "/Users/u/.sb/hosts/mini", "SB_CLI_HOST": "mini", "PATH": "/usr/bin:/bin", "A": "x y"]

    let output = try HostCLIRunner(program: "/usr/bin/env").run(
      host: "mini", profile: allowAll, argv: [], environment: given, cwd: "/", stdin: Data(), cancelled: { false })

    let lines = text(output.stdout).split(separator: "\n").map(String.init)
    #expect(Set(lines) == Set(given.map { "\($0.key)=\($0.value)" }), "\(lines)")
  }

  @Test(.timeLimit(.minutes(1)))
  func theProgramRunsInTheFolderItIsGiven() throws {
    try withStandIn { folder, program in
      let output = try HostCLIRunner(program: program).standIn("pwd", cwd: folder)

      #expect(text(output.stdout) == real(folder) + "\n")
    }
  }

  /// A stdin larger than a pipe's buffer, with bytes that are not UTF-8.
  @Test(.timeLimit(.minutes(1)))
  func theProgramReadsTheWholeStdin() throws {
    try withStandIn { _, program in
      let stdin = Data((0..<(3 * mib)).map { UInt8(truncatingIfNeeded: $0 &* 31) })

      let output = try HostCLIRunner(program: program).standIn("cat", stdin: stdin)

      #expect(output.status == 0)
      #expect(output.stdout == stdin)
    }
  }

  // MARK: The deadline and the cancel

  @Test(.timeLimit(.minutes(1)))
  func aProgramThatOutlivesTheDeadlineIsEndedWithStatus1AndTheReasonOnStderr() throws {
    try withStandIn { _, program in
      let started = Date()

      let output = try HostCLIRunner(program: program, deadline: 0.5).standIn("partial")

      let seconds = Date().timeIntervalSince(started)
      #expect(output.status == 1)
      #expect(seconds >= 0.4 && seconds < 5, "the run took \(seconds) s")
      #expect(text(output.stdout) == "before")
      #expect(text(output.stderr).hasPrefix("before-err"))
      #expect(output.stderr.count > "before-err".utf8.count, "the runner added no reason to stderr")
    }
  }

  /// SIGTERM is ignored, so only the SIGKILL 2 s later ends the program.
  @Test(.timeLimit(.minutes(1)))
  func aProgramThatIgnoresSIGTERMIsKilledAbout2SecondsLater() throws {
    try withStandIn { _, program in
      let started = Date()

      let output = try HostCLIRunner(program: program, deadline: 0.5).standIn("stubborn")

      let seconds = Date().timeIntervalSince(started)
      #expect(output.status == 1)
      #expect(seconds >= 2.3 && seconds < 8, "the run took \(seconds) s")
      #expect(text(output.stdout) == "before")
      #expect(!output.stderr.isEmpty, "the runner added no reason to stderr")
    }
  }

  /// The cancel stands in for the box's client closing its connection.
  @Test(.timeLimit(.minutes(1)))
  func aCancelEndsTheProgramWithStatus1AndTheReasonOnStderr() throws {
    try withStandIn { _, program in
      let started = Date()

      let output = try HostCLIRunner(program: program).standIn("partial") {
        Date().timeIntervalSince(started) > 0.3
      }

      let seconds = Date().timeIntervalSince(started)
      #expect(output.status == 1)
      #expect(seconds >= 0.3 && seconds < 4, "the run took \(seconds) s")
      #expect(text(output.stdout) == "before")
      #expect(text(output.stderr).hasPrefix("before-err"))
      #expect(output.stderr.count > "before-err".utf8.count, "the runner added no reason to stderr")
    }
  }

  // MARK: The output caps

  @Test(.timeLimit(.minutes(1)), arguments: ["stdout", "stderr"])
  func aStreamOf16MiBComesBackWhole(stream: String) throws {
    try withStandIn { _, program in
      let output = try HostCLIRunner(program: program, deadline: 30).standIn(stream, [String(16 * mib)])

      #expect(output.status == 0)
      #expect((stream == "stdout" ? output.stdout : output.stderr).count == 16 * mib)
    }
  }

  @Test(.timeLimit(.minutes(1)), arguments: ["stdout", "stderr"])
  func aStreamOf16MiBAnd1ByteEndsTheProgramWithStatus1(stream: String) throws {
    try withStandIn { _, program in
      let output = try HostCLIRunner(program: program, deadline: 30).standIn(stream, [String(16 * mib + 1)])

      #expect(output.status == 1)
      #expect(output.stdout.count <= 16 * mib)
      // The reason follows what the program wrote to stderr.
      #expect(output.stderr.count < 16 * mib + 4_096)
      #expect(!output.stderr.isEmpty, "the runner added no reason to stderr")
    }
  }

  // MARK: The slots

  /// Eight runs hold mini's slots until the gate file appears. Each test makes its own runner, so no other test
  /// holds a slot of its hosts.
  @Test(.timeLimit(.minutes(1)))
  func aNinthRunOnOneHostIsRefusedWhileEightRunAndAnotherHostStillRuns() throws {
    try withStandIn { folder, program in
      let runner = HostCLIRunner(program: program)
      let gate = "\(folder)/gate"
      defer { FileManager.default.createFile(atPath: gate, contents: nil) }
      let lock = NSLock()
      var held: [Result<HostCLIOutput, any Error>] = []
      let done = DispatchGroup()
      for n in 0..<8 {
        done.enter()
        Thread.detachNewThread {
          let result = Result { try runner.standIn("hold", ["\(folder)/started-\(n)", gate]) }
          lock.withLock { held.append(result) }
          done.leave()
        }
      }
      let started = waitUntil(seconds: 20) {
        (0..<8).allSatisfy { FileManager.default.fileExists(atPath: "\(folder)/started-\($0)") }
      }
      try #require(started, "the eight runs did not all start")

      #expect {
        try runner.standIn("quick")
      } throws: { error in
        "\(error)".contains("too many sb commands from mini are running")
      }
      let other = try runner.standIn("quick", host: "other")
      FileManager.default.createFile(atPath: gate, contents: nil)
      #expect(done.wait(timeout: .now() + 20) == .success, "the held runs did not end after the gate")
      let freed = try runner.standIn("quick")

      #expect(text(other.stdout) == "ok")
      #expect(
        lock.withLock { held.compactMap { try? $0.get() }.map { text($0.stdout) } }
          == Array(repeating: "held", count: 8))
      #expect(text(freed.stdout) == "ok")
    }
  }

  /// A run that ended at its deadline gives its slot back.
  @Test(.timeLimit(.minutes(1)))
  func aRunThatEndsAtItsDeadlineFreesItsSlot() throws {
    try withStandIn { _, program in
      let runner = HostCLIRunner(program: program, deadline: 0.2)
      for _ in 0..<9 { _ = try runner.standIn("partial") }

      let output = try runner.standIn("quick")

      #expect(text(output.stdout) == "ok")
    }
  }

  /// The program ignores SIGPIPE and outlives the end of its output, so only the cap's SIGTERM ends it before
  /// the deadline.
  @Test(.timeLimit(.minutes(1)))
  func aStreamPastTheCapEndsAProgramThatKeepsRunning() throws {
    try withStandIn { _, program in
      let started = Date()

      let output = try HostCLIRunner(program: program, deadline: 30).standIn("flood", [String(16 * mib + 1)])

      let seconds = Date().timeIntervalSince(started)
      #expect(output.status == 1)
      #expect(seconds < 15, "the run took \(seconds) s")
      #expect(output.stdout.count == 16 * mib)
      #expect(text(output.stderr).contains("stdout passed 16 MiB"), "\(text(output.stderr))")
    }
  }

  /// The sandbox checks opens and connects, not a descriptor that the program inherits. A socket that this
  /// process holds open must not reach the program.
  @Test(.timeLimit(.minutes(1)))
  func theProgramInheritsNoDescriptorButItsThreeStreams() throws {
    let folder = try makeShortTempFolder()
    defer { try? FileManager.default.removeItem(atPath: folder) }
    let held = try UnixSocket.listen(path: "\(folder)/held.sock")
    defer { close(held) }

    let output = try HostCLIRunner(program: "/bin/ls").run(
      host: "mini", profile: allowAll, argv: ["-l", "/dev/fd/"], environment: [:], cwd: "/", stdin: Data(),
      cancelled: { false })

    // `ls` opens folders of its own to list /dev/fd. Each other descriptor past the three streams was inherited.
    let rows = text(output.stdout).split(separator: "\n").filter { Int($0.split(separator: " ").last ?? "") != nil }
    let inherited = rows.filter { Int($0.split(separator: " ").last!)! > 2 && !$0.hasPrefix("d") }
    try #require(rows.count >= 3, "\(text(output.stdout))")
    #expect(inherited.isEmpty, "\(inherited) with \(held) held")
  }

  // MARK: Every way out frees the slot

  /// Each run ends its own way, and none of the nine is refused for want of a slot.
  @Test(
    .timeLimit(.minutes(1)),
    arguments: ["cancel", "cap", "missing sandbox-exec", "spawn failure", "missing folder", "sandbox exits 71"])
  func everyWayARunEndsFreesItsSlot(way: String) throws {
    try withStandIn { folder, program in
      let fake = "\(folder)/fake-sandbox-exec"
      try Data((way == "spawn failure" ? "\u{7F}garbage" : "#!/bin/sh\nexit 71\n").utf8)
        .write(to: URL(fileURLWithPath: fake))
      chmod(fake, 0o755)
      let runner =
        switch way {
        case "missing sandbox-exec": HostCLIRunner(program: program, sandboxExec: "\(folder)/none")
        case "spawn failure", "sandbox exits 71": HostCLIRunner(program: program, sandboxExec: fake)
        default: HostCLIRunner(program: program)
        }

      for run in 1...9 {
        let outcome = Result {
          switch way {
          case "cancel": try runner.standIn("partial") { true }
          case "cap": try runner.standIn("stdout", [String(16 * mib + 1)])
          case "missing folder": try runner.standIn("quick", cwd: "\(folder)/gone")
          default: try runner.standIn("quick")
          }
        }

        switch outcome {
        case .success(let output): #expect(output.status == 1, "run \(run)")
        case .failure(let error): #expect(!"\(error)".contains("too many"), "run \(run): \(error)")
        }
      }
    }
  }

  // MARK: Without the sandbox

  @Test(.timeLimit(.minutes(1)))
  func aMissingSandboxExecFailsTheRequestAndRunsNothing() throws {
    try withStandIn { folder, program in
      let runner = HostCLIRunner(program: program, sandboxExec: "\(folder)/no-sandbox-exec")

      #expect {
        try runner.standIn("args", ["\(folder)/ran"])
      } throws: { error in
        "\(error)".contains("sbd can't run sb for mini without its sandbox")
      }
    }
  }

  /// A sandbox-exec that exits 71 with no output from the program, as it does when its exec is denied.
  @Test(.timeLimit(.minutes(1)))
  func aSandboxExecThatExits71WithNoOutputFailsTheRequest() throws {
    try withStandIn { folder, program in
      let fake = "\(folder)/sandbox-exec"
      try Data(
        "#!/bin/sh\nprintf \"sandbox-exec: execvp() of '%s' failed: Operation not permitted\\n\" \"$3\" >&2\nexit 71\n"
          .utf8
      ).write(to: URL(fileURLWithPath: fake))
      chmod(fake, 0o755)

      #expect {
        try HostCLIRunner(program: program, sandboxExec: fake).standIn("quick")
      } throws: { error in
        "\(error)".contains("sbd can't run sb for mini without its sandbox")
      }
    }
  }

  /// The real sandbox-exec exits 71 when the profile denies the exec of the program.
  @Test(.timeLimit(.minutes(1)))
  func aProfileThatDeniesTheProgramsExecFailsTheRequest() throws {
    try withStandIn { _, program in
      #expect {
        try HostCLIRunner(program: program).run(
          host: "mini", profile: "(version 1)(deny default)", argv: ["quick"], environment: [:], cwd: "/",
          stdin: Data(), cancelled: { false })
      } throws: { error in
        "\(error)".contains("sbd can't run sb for mini without its sandbox")
      }
    }
  }

  /// The real sandbox-exec exits 65 for a profile that it can't read, and the program never runs.
  @Test(.timeLimit(.minutes(1)))
  func aProfileThatSandboxExecCantReadFailsTheRequest() throws {
    try withStandIn { _, program in
      #expect {
        try HostCLIRunner(program: program).run(
          host: "mini", profile: "(version 1)(allow default", argv: ["quick"], environment: [:], cwd: "/",
          stdin: Data(), cancelled: { false })
      } throws: { error in
        "\(error)".contains("sbd can't run sb for mini without its sandbox")
      }
    }
  }

  /// A program that wrote output ran, so its exit status 71 is its own.
  @Test(.timeLimit(.minutes(1)))
  func aProgramThatPrintsAndExits71IsRelayedAsItsOwnStatus() throws {
    try withStandIn { _, program in
      let output = try HostCLIRunner(program: program).standIn("printed71")

      #expect(output.status == 71)
      #expect(text(output.stdout) == "out")
    }
  }
}
