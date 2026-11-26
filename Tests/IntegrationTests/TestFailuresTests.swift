import Foundation
import SwitchboardCore
import Testing

private let script = Instance.root.appendingPathComponent("bin/lib/test-failures").path

private let annotation = "::error::"

/// A temp folder for one run of bin/lib/test-failures, with its fixture logs.
private final class FailureRig {
  let scratch: Repos
  var summary: String { "\(scratch.root)/summary.md" }

  init() throws { scratch = try Repos() }

  /// Writes the lines to a log in the temp folder and returns the log's path.
  func log(_ name: String, _ lines: [String]) throws -> String {
    try log(name, Data(lines.map { "\($0)\n" }.joined().utf8))
  }

  func log(_ name: String, _ data: Data) throws -> String {
    let path = "\(scratch.root)/\(name).log"
    try data.write(to: URL(fileURLWithPath: path))
    return path
  }

  /// Runs the script in the temp folder. The environment never holds the
  /// job's own GITHUB_STEP_SUMMARY. So a CI run never writes to the real job
  /// summary.
  func run(_ args: [String], summary withSummary: Bool = false) throws -> CommandResult {
    var env = ProcessInfo.processInfo.environment
    env["GITHUB_ACTIONS"] = nil
    env["GITHUB_STEP_SUMMARY"] = withSummary ? summary : nil
    return try runCommand(script, args, env: env, timeout: 30, cwd: scratch.root)
  }

  func summaryText() throws -> String { try String(contentsOfFile: summary, encoding: .utf8) }
}

/// The lines of `text`, split on LF scalars. Swift reads "\r\n" as one
/// Character, so a split on Characters would hide an unescaped CR.
private func lines(_ text: String) -> [String] {
  text.unicodeScalars.split(separator: "\n").map { String(String.UnicodeScalarView($0)) }
}

private func outputLines(_ r: CommandResult) -> [String] { lines(r.stdout) }

/// The GitHub error annotations that `text` holds.
func errorAnnotations(_ text: String) -> [String] { lines(text).filter { $0.hasPrefix(annotation) } }

private func annotations(_ r: CommandResult) -> [String] { errorAnnotations(r.stdout) }

private func payloads(_ r: CommandResult) -> [String] {
  annotations(r).map { String($0.dropFirst(annotation.count)) }
}

private func issue(_ name: String) -> String {
  "✘ Test \(name)() recorded an issue at \(name).swift:9:5: Expectation failed: (x → 1) == 2"
}

private let crashLines = [
  "error: Exited with unexpected signal code 11",
  "*** Terminating app due to uncaught exception 'NSInvalidArgumentException', reason: 'bad'",
  "Swift/Optional.swift:12: Fatal error: Unexpectedly found nil while unwrapping an Optional value",
]

private let quietLines = [
  "◇ Test a() started.",
  "✔ Test b() passed after 0.101 seconds.",
  "◇ Test case passing 1 argument line → \"Fatal error: boom\" to crash(_:) started.",
  "✔ Test crash(_:) with 1 test case passed after 0.1 seconds. Exited with unexpected signal code 11",
  "✘ Test k() recorded a known issue at K.swift:1:1: Known",
  "✘ Test a() failed after 0.2 seconds with 1 issue.",
  "Test run with 4 tests in 2 suites failed after 1.0 seconds with 1 issue.",
]

private struct Misuse: Sendable, CustomTestStringConvertible {
  var args: [String]
  var testDescription: String { args.joined(separator: " ") }
}

/// bin/lib/test-failures turns the failing lines of the shard logs into
/// GitHub error annotations and a job summary section.
@Suite(.blocking(timeLimit: .seconds(60))) struct TestFailuresTests {
  @Test func anIssueLineBecomesOneAnnotationPrefixedWithItsLabel() throws {
    let rig = try FailureRig()
    let log = try rig.log("0", ["◇ Test a() started.", issue("a")])

    let r = try rig.run(["0=\(log)"])

    #expect(r.status == 0, "\(r.stderr)")
    #expect(outputLines(r) == ["::error::[0] \(issue("a"))"], "\(r.stdout)")
  }

  @Test func anInvalidUTF8ByteDoesNotHideTheIssueLinesAfterIt() throws {
    let rig = try FailureRig()
    var data = Data("\(issue("a"))\n".utf8)
    data.append(contentsOf: [0xFF, 0xFE, 0x0A])
    data.append(Data("\(issue("b"))\n".utf8))
    let path = try rig.log("0", data)

    let r = try rig.run(["0=\(path)"])

    #expect(r.status == 0, "\(r.stderr)")
    #expect(payloads(r) == ["[0] \(issue("a"))", "[0] \(issue("b"))"], "\(r.stdout)")
  }

  @Test(arguments: crashLines)
  func aCrashLineBecomesAnAnnotation(_ line: String) throws {
    let rig = try FailureRig()
    let log = try rig.log("1", quietLines + [line])

    let r = try rig.run(["1=\(log)"])

    #expect(r.status == 0, "\(r.stderr)")
    #expect(payloads(r) == ["[1] \(line)"], "\(r.stdout)")
  }

  @Test func theMatchIgnoresCase() throws {
    let rig = try FailureRig()
    let lines = [
      "✘ Test a() RECORDED AN ISSUE at A.swift:1:1: x", "EXITED WITH UNEXPECTED SIGNAL CODE 6",
      "terminating app due to uncaught exception 'X'", "FATAL ERROR: boom",
    ]
    let log = try rig.log("0", lines)

    let r = try rig.run(["0=\(log)"])

    #expect(r.status == 0, "\(r.stderr)")
    #expect(payloads(r) == lines.map { "[0] \($0)" }, "\(r.stdout)")
  }

  @Test func startedPassedAndKnownIssueLinesMakeNoAnnotation() throws {
    let rig = try FailureRig()
    let log = try rig.log("0", quietLines)

    let r = try rig.run(["0=\(log)"])

    #expect(r.status == 0, "\(r.stderr)")
    #expect(r.stdout == "", "\(r.stdout)")
  }

  @Test func ansiEscapesAreStrippedBeforeTheMatch() throws {
    let rig = try FailureRig()
    let log = try rig.log(
      "0", ["\u{1B}[1;91m✘\u{1B}[0m Test a() \u{1B}[91mrecorded an issue\u{1B}[0m at a.swift:9:5: Expectation failed"])

    let r = try rig.run(["0=\(log)"])

    #expect(r.status == 0, "\(r.stderr)")
    #expect(payloads(r) == ["[0] ✘ Test a() recorded an issue at a.swift:9:5: Expectation failed"], "\(r.stdout)")
  }

  @Test func percentAndCarriageReturnAreEscaped() throws {
    let rig = try FailureRig()
    let log = try rig.log("0", ["✘ Test p() recorded an issue at P.swift:1:1: 100% sure\rstill the same line"])

    let r = try rig.run(["0=\(log)"])

    #expect(r.status == 0, "\(r.stderr)")
    #expect(
      outputLines(r) == ["::error::[0] ✘ Test p() recorded an issue at P.swift:1:1: 100%25 sure%0Dstill the same line"],
      "\(r.stdout)")
  }

  /// The script escapes % first, so a literal "%0A" in the text stays
  /// literal on the run page.
  @Test func aMessageIsEscapedWithPercentFirstAndLineFeedAsPercent0A() throws {
    let rig = try FailureRig()

    let r = try rig.run(["--message", "two\nlines", "--message", "50%0A done"])

    #expect(r.status == 0, "\(r.stderr)")
    #expect(outputLines(r) == ["::error::two%0Alines", "::error::50%250A done"], "\(r.stdout)")
  }

  @Test func theMessagesFollowTheShardLinesInOrder() throws {
    let rig = try FailureRig()
    let first = try rig.log("0", [issue("a")])
    let second = try rig.log("1", [issue("b")])

    let r = try rig.run(["--message", "bin/test: the shards ran 1 of 2 tests", "0=\(first)", "1=\(second)"])

    #expect(r.status == 0, "\(r.stderr)")
    #expect(
      payloads(r) == ["[0] \(issue("a"))", "[1] \(issue("b"))", "bin/test: the shards ran 1 of 2 tests"],
      "\(r.stdout)")
  }

  @Test func aLineRepeatedInOneLogMakesOneAnnotation() throws {
    let rig = try FailureRig()
    let log = try rig.log("0", [issue("a"), "◇ Test b() started.", issue("a"), issue("a")])

    let r = try rig.run(["0=\(log)"])

    #expect(r.status == 0, "\(r.stderr)")
    #expect(payloads(r) == ["[0] \(issue("a"))"], "\(r.stdout)")
  }

  @Test func aMissingLogIsSkipped() throws {
    let rig = try FailureRig()
    let log = try rig.log("1", [issue("b")])

    let r = try rig.run(["0=\(rig.scratch.root)/missing.log", "1=\(log)"])

    #expect(r.status == 0, "\(r.stderr)")
    #expect(payloads(r) == ["[1] \(issue("b"))"], "\(r.stdout)")
  }

  @Test func noLinesAndNoFailedShardPrintNothing() throws {
    let rig = try FailureRig()
    let log = try rig.log("0", quietLines)

    let r = try rig.run(["0=\(log)", "1=\(rig.scratch.root)/missing.log"])

    #expect(r.status == 0, "\(r.stderr)")
    #expect(r.stdout == "", "\(r.stdout)")
  }

  @Test func aLineLongerThan1000CharactersIsCut() throws {
    let rig = try FailureRig()
    let long = "✘ Test l() recorded an issue at L.swift:1:1: " + String(repeating: "x", count: 1500)
    let log = try rig.log("0", [long])

    let r = try rig.run(["0=\(log)"])

    #expect(r.status == 0, "\(r.stderr)")
    #expect(payloads(r).count == 1, "\(r.stdout)")
    let payload = try #require(payloads(r).first, "\(r.stdout)")
    #expect(payload.count == "[0] ".count + 1000, "\(payload.count)")
    #expect(payload.hasPrefix("[0] ✘ Test l() recorded an issue at L.swift:1:1: " + String(repeating: "x", count: 900)))
  }

  @Test func eightLinesPrintEightAnnotationsAndNoCount() throws {
    let rig = try FailureRig()
    let lines = (1...8).map { issue("t\($0)") }
    let log = try rig.log("0", lines)

    let r = try rig.run(["0=\(log)"])

    #expect(r.status == 0, "\(r.stderr)")
    #expect(payloads(r) == lines.map { "[0] \($0)" }, "\(r.stdout)")
  }

  /// GitHub keeps only 10 error annotations per step.
  @Test func moreThanEightLinesPrintTheFirstEightAndOneAnnotationWithTheCountLeft() throws {
    let rig = try FailureRig()
    let lines = (1...12).map { issue("t\($0)") }
    let log = try rig.log("0", lines)

    let r = try rig.run(["0=\(log)"])

    #expect(r.status == 0, "\(r.stderr)")
    #expect(outputLines(r).allSatisfy { $0.hasPrefix(annotation) }, "\(r.stdout)")
    let found = payloads(r)
    try #require(found.count == 9, "\(r.stdout)")
    #expect(Array(found.prefix(8)) == lines.prefix(8).map { "[0] \($0)" }, "\(r.stdout)")
    #expect(found[8].contains("4 more"), "\(found[8])")
  }

  @Test func aFailedShardWithNoMatchingLineGetsOneFallbackAnnotationThatNamesIt() throws {
    let rig = try FailureRig()
    let log = try rig.log("beta", quietLines)

    let r = try rig.run(["--failed", "beta", "beta=\(log)"])

    #expect(r.status == 0, "\(r.stderr)")
    let found = payloads(r)
    #expect(found.count == 1, "\(r.stdout)")
    #expect(found.first?.contains("beta") == true, "\(r.stdout)")
  }

  @Test func aFailedShardWithNoLogGetsOneFallbackAnnotationThatNamesIt() throws {
    let rig = try FailureRig()

    let r = try rig.run(["--failed", "gamma", "gamma=\(rig.scratch.root)/missing.log"])

    #expect(r.status == 0, "\(r.stderr)")
    let found = payloads(r)
    #expect(found.count == 1, "\(r.stdout)")
    #expect(found.first?.contains("gamma") == true, "\(r.stdout)")
  }

  @Test func aFailedShardWithAMatchingLineGetsNoFallback() throws {
    let rig = try FailureRig()
    let log = try rig.log("beta", quietLines + [issue("b")])

    let r = try rig.run(["--failed", "beta", "beta=\(log)"])

    #expect(r.status == 0, "\(r.stderr)")
    #expect(payloads(r) == ["[beta] \(issue("b"))"], "\(r.stdout)")
  }

  @Test func withoutGitHubStepSummaryNoFileIsWritten() throws {
    let rig = try FailureRig()
    let log = try rig.log("0", [issue("a")])
    let before = try FileManager.default.contentsOfDirectory(atPath: rig.scratch.root).sorted()

    let r = try rig.run(["--failed", "1", "0=\(log)"])

    #expect(r.status == 0, "\(r.stderr)")
    #expect(!annotations(r).isEmpty, "\(r.stdout)")
    #expect(try FileManager.default.contentsOfDirectory(atPath: rig.scratch.root).sorted() == before)
  }

  @Test func theSummaryAppendsTheLinesAfterWhatTheFileHeld() throws {
    let rig = try FailureRig()
    try "earlier step\n".write(toFile: rig.summary, atomically: true, encoding: .utf8)
    let log = try rig.log("0", quietLines + [issue("a")] + crashLines)

    let r = try rig.run(["--message", "bin/test: the shards ran 3 of 4 tests", "0=\(log)"], summary: true)

    #expect(r.status == 0, "\(r.stderr)")
    let text = try rig.summaryText()
    #expect(text.hasPrefix("earlier step\n"), "\(text)")
    for line in [issue("a")] + crashLines + ["bin/test: the shards ran 3 of 4 tests"] {
      #expect(text.contains(line), "\(line)\n\(text)")
    }
    for line in quietLines { #expect(!text.contains(line), "\(line)\n\(text)") }
  }

  @Test func theSummaryHoldsTheLinesWithoutWorkflowEscapes() throws {
    let rig = try FailureRig()
    let log = try rig.log("0", ["✘ Test p() recorded an issue at P.swift:1:1: 100% sure"])

    let r = try rig.run(["0=\(log)"], summary: true)

    #expect(r.status == 0, "\(r.stderr)")
    let text = try rig.summaryText()
    #expect(text.contains("100% sure"), "\(text)")
    #expect(!text.contains("%25"), "\(text)")
  }

  @Test func theSummaryHoldsAtMost100LinesAndCountsTheRest() throws {
    let rig = try FailureRig()
    let lines = (1...105).map { "✘ Test t() recorded an issue at F\($0).swift:1:1: x" }
    let log = try rig.log("0", lines)

    let r = try rig.run(["0=\(log)"], summary: true)

    #expect(r.status == 0, "\(r.stderr)")
    let text = try rig.summaryText()
    for i in 1...100 { #expect(text.contains(" at F\(i).swift:"), "F\(i)") }
    for i in 101...105 { #expect(!text.contains(" at F\(i).swift:"), "F\(i)") }
    #expect(text.contains("5 more"), "\(text)")
  }

  @Test func theSummaryHoldsTheLast20LinesOfAFallbackShardsLog() throws {
    let rig = try FailureRig()
    let log = try rig.log("beta", (1...30).map { "progress <L\($0 + 100)>" })

    let r = try rig.run(["--failed", "beta", "beta=\(log)"], summary: true)

    #expect(r.status == 0, "\(r.stderr)")
    let text = try rig.summaryText()
    for i in 11...30 { #expect(text.contains("<L\(i + 100)>"), "line \(i)\n\(text)") }
    for i in 1...10 { #expect(!text.contains("<L\(i + 100)>"), "line \(i)\n\(text)") }
  }

  @Test(arguments: [
    Misuse(args: ["--bogus"]), Misuse(args: ["--failed"]), Misuse(args: ["--message"]),
    Misuse(args: ["no-equals-sign"]),
  ])
  fileprivate func misuseExitsTwoWithoutAnnotations(_ c: Misuse) throws {
    let rig = try FailureRig()

    let r = try rig.run(c.args)

    #expect(r.status == 2, "\(r.stdout)\(r.stderr)")
    #expect(annotations(r).isEmpty, "\(r.stdout)")
  }
}
