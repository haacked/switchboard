import Foundation
import SwitchboardCore
import Testing

private struct PlanLine: Equatable, CustomStringConvertible {
  var part: Int
  var slot: Int
  var filter: String

  var description: String { "\(part) \(slot) \(filter)" }
}

/// Runs bin/lib/shard-plan with `tests` on stdin and a weights file that
/// holds `weights`.
private func plan(_ args: [String], weights: [(Int, String)] = [], tests: [String]) throws -> CommandResult {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shard-plan-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: dir) }
  let file = dir.appendingPathComponent("weights").path
  try weights.map { "\($0.0) \($0.1)\n" }.joined().write(toFile: file, atomically: true, encoding: .utf8)
  let script = Instance.root.appendingPathComponent("bin/lib/shard-plan").path
  let input = Data(tests.map { "\($0)\n" }.joined().utf8)
  return try runCommand("/bin/bash", [script] + args + [file], input: input, timeout: 30)
}

private func lines(_ r: CommandResult) -> [PlanLine] {
  r.stdout.split(separator: "\n").map { line in
    let f = line.split(separator: " ", maxSplits: 2).map(String.init)
    return PlanLine(part: Int(f[0]) ?? -1, slot: Int(f[1]) ?? -1, filter: f[2])
  }
}

/// The filter that swift test --filter gets for these suites of IntegrationTests.
private func filter(_ suites: String...) -> String {
  "^(" + suites.map { "IntegrationTests\\.\($0)" }.joined(separator: "|") + ")/"
}

private func matches(_ filter: String, _ test: String) throws -> Bool {
  try NSRegularExpression(pattern: filter).firstMatch(in: test, range: NSRange(test.startIndex..., in: test)) != nil
}

private let measure = "IntegrationTests.MeasureTests/m()"

@Suite(.blocking(timeLimit: .seconds(60))) struct ShardPlanTests {
  /// With weights 100 to 30 and four shards in all, each shard ends with 130.
  @Test func twoPartsSplitTheSuitesByWeightAcrossTheShardsOfBothParts() throws {
    let suites = ["FxATests", "FxBTests", "FxCTests", "FxDTests", "FxETests", "FxFTests", "FxGTests", "FxHTests"]
    let weights = zip([100, 90, 80, 70, 60, 50, 40, 30], suites.map { "IntegrationTests.\($0)" }).map { ($0, $1) }
    let tests = suites.map { "IntegrationTests.\($0)/a()" } + ["SwitchboardCoreTests.FxUnitTests/u()", measure]

    let r = try plan(["2", "2"], weights: weights, tests: tests)

    #expect(r.status == 0, "\(r.stderr)")
    #expect(
      lines(r) == [
        PlanLine(part: 1, slot: 0, filter: filter("FxATests", "FxHTests")),
        PlanLine(part: 1, slot: 1, filter: filter("FxBTests", "FxGTests")),
        PlanLine(part: 1, slot: 2, filter: "^(SwitchboardCoreTests\\.FxUnitTests)/"),
        PlanLine(part: 2, slot: 0, filter: filter("FxCTests", "FxFTests")),
        PlanLine(part: 2, slot: 1, filter: filter("FxDTests", "FxETests")),
        PlanLine(part: 2, slot: 3, filter: filter("MeasureTests")),
      ])
  }

  @Test func everyTestMatchesExactlyOneFilterAcrossTheParts() throws {
    let tests =
      (1...9).flatMap { s in (1...3).map { "IntegrationTests.Fx\(s)Tests/t\($0)()" } }
      + ["IntegrationTests.FxOuter.Inner/n()", "SwitchboardAppTests.FxAppTests/a()", "SwitchboardCoreTests.FxCore/c()"]
      + [measure]

    let r = try plan(["3", "2"], tests: tests)

    #expect(r.status == 0, "\(r.stderr)")
    let filters = lines(r).map(\.filter)
    for test in tests {
      #expect(try filters.filter { try matches($0, test) }.count == 1, "\(test)")
    }
  }

  @Test func onePartRunsEveryProcessInPartOne() throws {
    let tests = [
      "IntegrationTests.FxATests/a()", "IntegrationTests.FxBTests/b()", "SwitchboardCoreTests.FxU/u()", measure,
    ]

    let r = try plan(
      ["2", "1"], weights: [(20, "IntegrationTests.FxATests"), (10, "IntegrationTests.FxBTests")], tests: tests)

    #expect(r.status == 0, "\(r.stderr)")
    #expect(
      lines(r) == [
        PlanLine(part: 1, slot: 0, filter: filter("FxATests")),
        PlanLine(part: 1, slot: 1, filter: filter("FxBTests")),
        PlanLine(part: 1, slot: 2, filter: "^(SwitchboardCoreTests\\.FxU)/"),
        PlanLine(part: 1, slot: 3, filter: filter("MeasureTests")),
      ])
  }

  /// FxATests and FxCTests give 45 s for 4 tests, so FxBTests' 5 tests weigh
  /// 56.25 s and FxBTests takes a shard alone. By test count alone, it would
  /// be the lightest suite.
  @Test func aSuiteTheWeightsDoNotListWeighsItsTestCountTimesTheMeanSecondsPerTest() throws {
    let tests =
      (1...3).map { "IntegrationTests.FxATests/a\($0)()" } + (1...5).map { "IntegrationTests.FxBTests/b\($0)()" }
      + ["IntegrationTests.FxCTests/c()", measure]

    let r = try plan(
      ["2", "1"], weights: [(30, "IntegrationTests.FxATests"), (15, "IntegrationTests.FxCTests")], tests: tests)

    #expect(r.status == 0, "\(r.stderr)")
    #expect(lines(r).first == PlanLine(part: 1, slot: 0, filter: filter("FxBTests")))
  }

  @Test func aListWithoutMeasureTestsExitsOne() throws {
    let r = try plan(["2", "2"], tests: ["IntegrationTests.FxATests/a()"])

    #expect(r.status == 1)
    #expect(r.stdout == "")
    #expect(r.stderr.contains("no IntegrationTests.MeasureTests suite"), "\(r.stderr)")
  }

  /// The "+" in the suite's name makes its filter match "FxTests" and
  /// "FxxTests", but not the suite itself.
  @Test func aTestThatNoFilterMatchesExitsOneAndNamesIt() throws {
    let r = try plan(["2", "2"], tests: ["IntegrationTests.Fx+Tests/a()", measure])

    #expect(r.status == 1)
    #expect(r.stdout == "")
    #expect(r.stderr.contains("0 filters match IntegrationTests.Fx+Tests/a()"), "\(r.stderr)")
  }

  @Test(arguments: [["0", "2"], ["2", "0"], ["x", "2"], ["2", "1.5"], ["2"]])
  func aBadArgumentExitsTwo(_ args: [String]) throws {
    let r = try plan(args, tests: [measure])

    #expect(r.status == 2)
    #expect(r.stdout == "")
  }
}
