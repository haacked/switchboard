import Foundation
import SwitchboardCore
import Testing

/// The model of the operator and of its judges. `sb operator model` shows and sets `operator.model`, sbd passes it
/// with `--model` when the operator's claude starts, and `sb operator judge` runs one judgment on it or on the
/// model that `--model` names.
@Suite(.blocking(timeLimit: .seconds(120))) struct OperatorModelTests {
  let models = ManagerModelTests()

  func shown(_ sbd: Instance, env: [String: String] = [:]) throws -> JSON {
    try #require(JSON.parse(try sbd.sb(["operator", "model", "--json"], env: env)))
  }

  /// Stops the operator and opens it again, which resumes its conversation.
  func relaunch(_ sbd: Instance, _ op: SessionSummary) throws {
    try sbd.sb("stop", op.id)
    try sbd.waitFor(op.id, "the stop") { !$0.live }
    try sbd.sb("operator", "--json")
    try sbd.waitFor(op.id, "the resume") { $0.live }
  }

  @Test func aSetChangesTheOperatorsNextLaunchOnly() throws {
    let sbd = try Instance(config: ["model": "opus", "manager": ["model": "opus"]])
    let op = try models.live(sbd, "operator")
    let work = try models.liveWorkSession(sbd)
    #expect(try models.launchModel(sbd, op.id) == OperatorSettings.defaultModel)
    #expect(try shown(sbd, env: ["CLAUDECODE": "1"]) == ["model": .string(OperatorSettings.defaultModel)])

    let printed = try #require(JSON.parse(try sbd.sb("operator", "model", "haiku", "--json")))

    #expect(printed == ["model": "haiku"])
    #expect(try shown(sbd) == ["model": "haiku"])
    #expect(try sbd.config()["operator"] == ["model": "haiku"])
    #expect(try models.launchModel(sbd, op.id) == OperatorSettings.defaultModel)
    try relaunch(sbd, op)
    #expect(try models.launchModel(sbd, op.id) == "haiku")
    #expect(try models.launchModel(sbd, work.id) == "opus")
    let m = try models.liveManager(sbd)
    #expect(try models.launchModel(sbd, m.id) == "opus")

    sbd.stopSbd()
    try sbd.startSbd()
    #expect(try shown(sbd) == ["model": "haiku"])
  }

  @Test func theRequestKeepsTheOtherOperatorSettings() throws {
    let sbd = try Instance(config: ["operator": ["mergeRepos": ["a/b"], "holdRetrySeconds": 30]])

    #expect(try sbd.client.call("operator-model", ["model": "haiku"]) == ["model": "haiku"])

    #expect(
      try sbd.config()["operator"] == ["mergeRepos": ["a/b"], "holdRetrySeconds": 30, "model": "haiku"])
  }

  @Test func aLegacyJudgeModelIsTheModelUntilOneIsSet() throws {
    let sbd = try Instance(config: ["operator": ["judgeModel": "opus"]])
    #expect(try shown(sbd) == ["model": "opus"])

    _ = try sbd.sb("operator", "model", "haiku")

    #expect(try shown(sbd) == ["model": "haiku"])
  }

  @Test func aBadSetChangesNothing() throws {
    let sbd = try Instance()
    let config = try sbd.config()
    // `Args` reads a value that starts with `--` as a switch, so the command-line cases use one dash.
    let commands: [[String]] = [["-opus"], ["a b"], [""], ["hai", "ku"]]
    for words in commands {
      let r = try sbd.run(["operator", "model"] + words)
      #expect(r.status != 0, "\(words): \(text(r))")
    }
    let inside = try sbd.run(["operator", "model", "haiku"], env: ["CLAUDECODE": "1"])
    #expect(inside.status != 0, "\(text(inside))")
    let values: [JSON] = ["--opus", "a b", .number(1), ["name": "haiku"]]
    for value in values {
      #expect(throws: (any Error).self, "\(value.text)") { try sbd.client.call("operator-model", ["model": value]) }
    }

    #expect(try sbd.config() == config)
    #expect(try shown(sbd) == ["model": .string(OperatorSettings.defaultModel)])
  }

  // MARK: sb operator judge

  func write(_ sbd: Instance, _ name: String, _ input: JSON) throws -> String {
    let path = "\(sbd.home.path)/\(name)"
    try input.text.write(toFile: path, atomically: true, encoding: .utf8)
    return path
  }

  func ciCalls(_ sbd: Instance) -> [String] {
    let text = (try? String(contentsOfFile: "\(sbd.home.path)/ci-judge-calls.log", encoding: .utf8)) ?? ""
    return text.split(separator: "\n").map(String.init)
  }

  @Test func aReplyGateJudgmentRunsTheOverridingModelAndActsOnNothing() throws {
    let sbd = try Instance(config: ["operator": ["model": "opus"]])
    let input: JSON = [
      "repo": "haacked/switchboard", "number": 7, "title": "Add a thing", "session": "thing",
      "reply": "Done. All tests pass. Nothing is left for you.",
    ]
    let path = try write(sbd, "gate.json", input)
    try """
    {"answer":"merge","question":"","reason":"The work is finished."}
    """.write(toFile: "\(sbd.home.path)/judge-answer.json", atomically: true, encoding: .utf8)

    let answered = try #require(
      JSON.parse(
        try sbd.sb(["operator", "judge", "--kind", "reply-gate", "--input", path, "--model", "haiku", "--json"])))
    let defaulted = try #require(
      JSON.parse(try sbd.sb(["operator", "judge", "--kind", "reply-gate", "--input", path, "--json"])))

    #expect(answered["answer"] == "merge", Comment(rawValue: answered.text))
    #expect(answered["model"] == "haiku")
    #expect(defaulted["model"] == "opus")
    #expect(sbd.judgeCalls() == ["haiku", "opus"])
    #expect(sbd.judgeInput().contains("Nothing is left for you."))
    #expect(try sbd.sb("operator", "reports", "--all").isEmpty)
    // The call takes the active account, so it neither creates nor launches an operator.
    #expect(try sbd.run("get", "Operator").status != 0)
  }

  @Test func aCIFailureJudgmentAnswersTheCause() throws {
    let sbd = try Instance()
    let log = "build\tRun tests\t2026-01-01T00:00:00Z error: the test timed out after 45 minutes"
    let input: JSON = [
      "repo": "haacked/switchboard", "number": 7, "title": "Add a thing", "head": "abc1234",
      "jobs": [["workflow": "CI", "log": .string(log)]],
    ]
    let path = try write(sbd, "ci.json", input)

    let answered = try #require(
      JSON.parse(
        try sbd.sb(["operator", "judge", "--kind", "ci-failure", "--input", path, "--model", "haiku", "--json"])))

    #expect(answered["answer"] == "real", Comment(rawValue: answered.text))
    #expect(ciCalls(sbd) == ["haiku"])
  }

  @Test func aBadJudgmentRequestFails() throws {
    let sbd = try Instance()
    let path = try write(sbd, "x.json", ["repo": "a/b"])
    let complete = try write(
      sbd, "complete.json", ["repo": "a/b", "number": 7, "title": "t", "session": "s", "reply": "Done."])
    let calls: [[String]] = [
      ["operator", "judge"],
      ["operator", "judge", "--kind", "nope", "--input", path],
      ["operator", "judge", "--kind", "reply-gate", "--input", path],
      ["operator", "judge", "--kind", "reply-gate", "--input", "\(sbd.home.path)/missing.json"],
      ["operator", "judge", "--kind", "reply-gate", "--input", complete, "--model", "-p"],
    ]
    for words in calls {
      let r = try sbd.run(words)
      #expect(r.status != 0, "\(words): \(text(r))")
    }
    #expect(sbd.judgeCalls().isEmpty)
  }
}
