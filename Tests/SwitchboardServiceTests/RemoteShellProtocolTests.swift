import Foundation
import SwitchboardCore
import Testing

@testable import SwitchboardService

/// The plan names `bootScript(token:)`, `request(seq:argv:env:input:timeout:)`, `Header`, `Ready`,
/// `StatFormat`, and `parseStat`, and leaves the parsers' signatures open. Every test in this file
/// reaches the parsers through these functions, so a different signature changes only this block.
private func header(_ line: String, seq: Int = 7) throws -> (status: Int32, stdoutBytes: Int, stderrBytes: Int) {
  let h = try RemoteShellProtocol.parseHeader(line, seq: seq)
  return (h.status, h.stdoutBytes, h.stderrBytes)
}

private func ready(_ text: String) throws -> RemoteShellProtocol.StatFormat {
  try RemoteShellProtocol.parseReady(text).stat
}

private func stat(_ text: String) -> (size: UInt64, modified: Date)? {
  RemoteShellProtocol.parseStat(text)
}

private func requestText(
  seq: Int = 7, argv: [String] = ["/bin/echo", "hi"], env: [String: String]? = nil, input: Data? = nil,
  timeout: Double? = nil
) throws -> String {
  String(
    decoding: try RemoteShellProtocol.request(seq: seq, argv: argv, env: env, input: input, timeout: timeout),
    as: UTF8.self)
}

@Suite struct RemoteShellProtocolHeaderTests {
  @Test(arguments: [
    ("SB1 7 0 0 0", Int32(0), 0, 0),
    ("SB1 7 3 4 5", Int32(3), 4, 5),
    ("SB1 7 255 20971520 1", Int32(255), 20_971_520, 1),
    ("SB1 7 143 0 12", Int32(143), 0, 12),
  ])
  func parsesAValidHeader(line: String, status: Int32, stdoutBytes: Int, stderrBytes: Int) throws {
    let h = try header(line)

    #expect(h.status == status)
    #expect(h.stdoutBytes == stdoutBytes)
    #expect(h.stderrBytes == stderrBytes)
  }

  @Test func parsesTheSequenceNumberItWasGiven() throws {
    let h = try header("SB1 1234 0 2 0", seq: 1234)

    #expect(h.stdoutBytes == 2)
  }

  @Test(arguments: [
    "SB2 7 0 0 0",
    "sb1 7 0 0 0",
    "XSB1 7 0 0 0",
    " SB1 7 0 0 0",
    "noise SB1 7 0 0 0",
    "SB17 0 0 0",
    "",
  ])
  func refusesAWrongPrefix(line: String) {
    #expect(throws: (any Error).self) { try header(line) }
  }

  @Test(arguments: ["SB1 8 0 0 0", "SB1 6 0 0 0", "SB1 77 0 0 0", "SB1 07 0 0 0x", "SB1 -7 0 0 0", "SB1 seven 0 0 0"])
  func refusesAWrongSequenceNumber(line: String) {
    #expect(throws: (any Error).self) { try header(line) }
  }

  @Test(arguments: ["SB1 7 0 0", "SB1 7 0", "SB1 7", "SB1", "SB1 7 0 0 0 0", "SB1 7  0 0"])
  func refusesAMissingOrExtraField(line: String) {
    #expect(throws: (any Error).self) { try header(line) }
  }

  @Test(arguments: [
    "SB1 7 0 abc 0",
    "SB1 7 0 0 abc",
    "SB1 7 0 1.5 0",
    "SB1 7 0 0x10 0",
    "SB1 7 0 1e3 0",
    "SB1 7 0 99999999999999999999999999 0",
  ])
  func refusesACountThatIsNotAWholeNumber(line: String) {
    #expect(throws: (any Error).self) { try header(line) }
  }

  @Test(arguments: ["SB1 7 0 -1 0", "SB1 7 0 0 -1", "SB1 7 0 -0 -5"])
  func refusesANegativeCount(line: String) {
    #expect(throws: (any Error).self) { try header(line) }
  }

  @Test(arguments: ["SB1 7 abc 0 0", "SB1 7 1.5 0 0", "SB1 7 - 0 0"])
  func refusesAStatusThatIsNotAWholeNumber(line: String) {
    #expect(throws: (any Error).self) { try header(line) }
  }

  @Test func refusesALineOver256Bytes() {
    let long = "SB1 7 0 0 " + String(repeating: "0", count: 256) + "1"
    #expect(long.utf8.count > 256)

    #expect(throws: (any Error).self) { try header(long) }
  }

  @Test func reportsStatusXAsInputThatTheHostCouldNotDecode() {
    do {
      _ = try header("SB1 7 x 0 0")
      Issue.record("status x did not throw")
    } catch {
      #expect("\(error)".contains("the host could not decode the command's input"))
    }
  }
}

@Suite struct RemoteShellProtocolStatTests {
  /// `gstat -c '%s %.9Y' -- /` on GNU coreutils 9.
  @Test func parsesRecordedGNUOutput() throws {
    let r = try #require(stat("4096 1731196800.123456789\n"))

    #expect(r.size == 4096)
    #expect(abs(r.modified.timeIntervalSince1970 - 1_731_196_800.123456789) < 0.000_001)
  }

  /// `stat -f '%z %Fm' -- /` on macOS 15.
  @Test func parsesRecordedBSDOutput() throws {
    let r = try #require(stat("736 1792710643.000000000\n"))

    #expect(r.size == 736)
    #expect(r.modified == Date(timeIntervalSince1970: 1_792_710_643))
  }

  @Test func parsesOutputWithNoTrailingNewline() throws {
    let r = try #require(stat("0 1700000000.500000000"))

    #expect(r.size == 0)
    #expect(abs(r.modified.timeIntervalSince1970 - 1_700_000_000.5) < 0.000_001)
  }

  @Test func parsesASizeAboveInt32Max() throws {
    let r = try #require(stat("5000000000 1700000000.000000000\n"))

    #expect(r.size == 5_000_000_000)
  }

  @Test(arguments: [
    "",
    "\n",
    "garbage",
    "736",
    "736 ",
    "abc 1700000000.000000000",
    "-1 1700000000.000000000",
    "1.5 1700000000.000000000",
    "736 yesterday",
    "736 nan",
    "736 inf",
    "stat: illegal option -- c",
    "stat: cannot stat '/': No such file or directory",
    "%s %.9Y",
  ])
  func refusesGarbage(text: String) {
    #expect(stat(text) == nil)
  }

  @Test func theFormatsCarryTheArgumentsThatPrintBytesThenSeconds() {
    #expect(RemoteShellProtocol.StatFormat.gnu.arguments == ["-c", "%s %.9Y"])
    #expect(RemoteShellProtocol.StatFormat.bsd.arguments == ["-f", "%z %Fm"])
  }
}

@Suite struct RemoteShellProtocolReadyTests {
  @Test func readsTheStatFormatTheHostReported() throws {
    #expect(try ready("gnu 4096 1731196800.123456789") == .gnu)
    #expect(try ready("bsd 736 1792710643.000000000") == .bsd)
  }

  @Test func refusesAHostWithNoStatOrBase64() {
    do {
      _ = try ready("none 0 0")
      Issue.record("none did not throw")
    } catch {
      #expect("\(error)".contains("the host has no stat or base64 that Switchboard can use"))
    }
  }

  @Test(arguments: [
    "",
    "bsd",
    "bsd 736",
    "bsd garbage here",
    "gnu abc 1700000000.000000000",
    "bsd 736 yesterday",
    "solaris 736 1700000000.000000000",
    "gnu stat: illegal option -- c",
  ])
  func refusesAReadyLineWhoseStatOutputDoesNotParse(text: String) {
    #expect(throws: (any Error).self) { try ready(text) }
  }
}

@Suite struct RemoteShellProtocolRequestTests {
  /// The base64 lines between the heredoc's two delimiter lines.
  private func heredocLines(_ text: String) -> [String]? {
    let lines = text.components(separatedBy: "\n")
    guard let start = lines.firstIndex(where: { $0.hasSuffix("<<'_SB_'") }),
      let end = lines[(start + 1)...].firstIndex(of: "_SB_")
    else { return nil }
    return Array(lines[(start + 1)..<end])
  }

  @Test func aRequestWithNoInputEmptiesTheInputFileAndRunsTheWords() throws {
    let text = try requestText(seq: 7, argv: ["/bin/echo", "hi"], input: nil)

    #expect(text == ": >\"$sb_d/i\"\nsb_run 7 '' '/bin/echo' 'hi'\n")
  }

  @Test func aRequestWithEmptyInputGivesTheProgramAnEmptyFile() throws {
    let text = try requestText(seq: 7, argv: ["/bin/cat"], input: Data())

    #expect(text == ": >\"$sb_d/i\"\nsb_run 7 '' '/bin/cat'\n")
  }

  @Test func aRequestWithBinaryInputCarriesItAsBase64InAHeredoc() throws {
    let input = Data((0...255).map { UInt8($0) } + (0...255).reversed().map { UInt8($0) })

    let text = try requestText(seq: 12, argv: ["/bin/cat"], input: input)

    #expect(text.hasPrefix("if base64 -d >\"$sb_d/i\" <<'_SB_'\n"))
    let lines = try #require(heredocLines(text))
    #expect(lines.count > 1)
    #expect(lines.allSatisfy { $0.utf8.count <= 76 && !$0.isEmpty })
    #expect(Data(base64Encoded: lines.joined()) == input)
    #expect(text.contains("\n_SB_\nthen sb_run 12 '' '/bin/cat'\n"))
    #expect(text.hasSuffix("else printf 'SB1 %s x 0 0\\n' 12\nfi\n"))
  }

  @Test func theBase64OfInputNeverHoldsTheHeredocDelimiter() throws {
    let input = Data("_SB_\n_SB_\n'_SB_'\n".utf8)

    let lines = try #require(heredocLines(try requestText(argv: ["/bin/cat"], input: input)))

    #expect(!lines.contains { $0.contains("_") })
    #expect(Data(base64Encoded: lines.joined()) == input)
  }

  @Test(arguments: [
    "a b", "'", "it's", "\"", "`id`", "$HOME", "$(id)", ";", "a;b", "line\nbreak", "-n", "--", "", "héllo ✓ 日本",
    "\\", "*", "~", "_SB_", "a=b", "exit", "#", "!", "\t", "'\\''",
  ])
  func everyWordIsOneSingleQuotedShellWord(word: String) throws {
    let text = try requestText(seq: 3, argv: ["/bin/echo", word, "end"])

    #expect(text.hasSuffix("sb_run 3 '' '/bin/echo' \(shellQuote(word)) 'end'\n"))
  }

  @Test func word0IsQuotedLikeEveryOtherWord() throws {
    let text = try requestText(seq: 3, argv: ["/tmp/a dir/it's; exit", "x"])

    #expect(text.hasSuffix("sb_run 3 '' \(shellQuote("/tmp/a dir/it's; exit")) 'x'\n"))
  }

  @Test(arguments: [0.2, 1, 1.5, 30, 0.001, 600])
  func theTimeoutIsSecondsWithUpToThreeDecimals(timeout: Double) throws {
    let text = try requestText(seq: 9, argv: ["/bin/sleep", "30"], timeout: timeout)

    let line = try #require(text.components(separatedBy: "\n").first { $0.hasPrefix("sb_run 9 ") })
    let field = try #require(
      line.range(of: #"^sb_run 9 '([0-9]+(\.[0-9]{1,3})?)' '/bin/sleep' '30'$"#, options: .regularExpression).map {
        _ in line.components(separatedBy: "'")[1]
      })
    #expect(Double(field) == timeout)
  }

  @Test func aSetEnvRunsTheProgramUnderEnvIAndAnInnerShell() throws {
    let text = try requestText(seq: 4, argv: ["/bin/echo", "hi"], env: ["K": "a b'$c\nd"])

    let expected =
      "sb_run 4 '' '/usr/bin/env' '-i' \(shellQuote("K=a b'$c\nd")) '/bin/sh' '-c' "
      + "'exec \"$0\" \"$@\"' '/bin/echo' 'hi'\n"
    #expect(text.hasSuffix(expected))
  }

  @Test func anEmptySetEnvStillClearsTheEnvironment() throws {
    let text = try requestText(seq: 4, argv: ["/bin/echo"], env: [:])

    #expect(text.hasSuffix("sb_run 4 '' '/usr/bin/env' '-i' '/bin/sh' '-c' 'exec \"$0\" \"$@\"' '/bin/echo'\n"))
  }

  @Test func anExecutableWithAnEqualsSignUnderASetEnvIsNotAnAssignment() throws {
    let text = try requestText(seq: 4, argv: ["/tmp/a=b"], env: ["K": "v"])

    #expect(text.hasSuffix("'K=v' '/bin/sh' '-c' 'exec \"$0\" \"$@\"' '/tmp/a=b'\n"))
  }

  // The refusals of Risk 2.

  @Test(arguments: [
    ["/bin/echo", "a\0b"], ["/bin/ec\0ho"], ["/bin/echo", "ok", "\0"], ["\0"], ["/bin/echo", "\0\u{301}"],
  ])
  func refusesANulInAnyWord(argv: [String]) {
    #expect(throws: (any Error).self) { try requestText(argv: argv) }
  }

  @Test func refusesANulInAnEnvironmentValue() {
    #expect(throws: (any Error).self) { try requestText(env: ["K": "a\0b"]) }
  }

  @Test(arguments: [
    "", "1A", "A-B", "A B", "A=B", "A.B", "é", "A\nB", "A;id", "$A", "A'", "-i", "A\0", "A\n", "A\u{301}",
  ])
  func refusesAnEnvironmentNameThatIsNotAnIdentifier(name: String) {
    #expect(throws: (any Error).self) { try requestText(env: [name: "v"]) }
  }

  @Test(arguments: ["A", "_", "_a1", "PATH", "a_B_9"])
  func acceptsAnEnvironmentNameThatIsAnIdentifier(name: String) throws {
    #expect(try requestText(env: [name: "v"]).contains("'\(name)=v'"))
  }

  @Test func refusesAnEmptyExecutable() {
    #expect(throws: (any Error).self) { try requestText(argv: [""]) }
    #expect(throws: (any Error).self) { try requestText(argv: ["", "arg"]) }
    #expect(throws: (any Error).self) { try requestText(argv: []) }
    #expect(throws: (any Error).self) { try requestText(argv: [""], env: ["K": "v"]) }
  }

  @Test(arguments: [0, -1, -0.5, Double.nan, Double.infinity, -Double.infinity])
  func refusesATimeoutThatIsNotFiniteAndAboveZero(timeout: Double) {
    #expect(throws: (any Error).self) { try requestText(timeout: timeout) }
  }
}

@Suite struct RemoteShellProtocolBootScriptTests {
  @Test func theScriptEndsWithTheReadyLineThatHoldsTheToken() {
    let token = "0123456789abcdef0123456789abcdef"

    let script = RemoteShellProtocol.bootScript(token: token)

    #expect(script.hasSuffix("printf 'SB1 ready %s %s %s\\n' '\(token)' \"$sb_s\" \"$sb_p\"\n"))
    #expect(script.components(separatedBy: token).count == 2, "the token appears once")
  }

  @Test(.timeLimit(.minutes(1)), arguments: ["/bin/sh", "/bin/bash", "/bin/dash"])
  func aRealShellAnswersTheScriptWithAReadyLineThatParses(shell: String) throws {
    let token = "fedcba9876543210fedcba9876543210"
    let script = RemoteShellProtocol.bootScript(token: token)

    let r = try runCommand(shell, [], input: Data(script.utf8))

    #expect(r.status == 0)
    let prefix = "SB1 ready \(token) "
    let line = try #require(r.stdout.components(separatedBy: "\n").first { $0.hasPrefix(prefix) })
    #expect(try ready(String(line.dropFirst(prefix.count))) == .bsd)
    #expect(r.stdout == line + "\n", "the script prints nothing but the ready line")
  }

  @Test(.timeLimit(.minutes(1)), arguments: ["/bin/sh", "/bin/bash", "/bin/dash"])
  func theShellRemovesItsTemporaryFolderWhenItsInputEnds(shell: String) throws {
    let script = RemoteShellProtocol.bootScript(token: "00000000000000000000000000000000") + "printf '%s' \"$sb_d\"\n"

    let r = try runCommand(shell, [], input: Data(script.utf8))

    let folder = try #require(r.stdout.components(separatedBy: "\n").last)
    #expect(folder.contains("sb-sh."))
    #expect(!FileManager.default.fileExists(atPath: folder))
  }
}
