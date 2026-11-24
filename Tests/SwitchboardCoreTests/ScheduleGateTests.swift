import Foundation
import Testing

@testable import SwitchboardCore

private let now: Int64 = 1_800_000_000_000
private let minute: Int64 = 60_000
private let repo = "haacked/switchboard"
private let groupID = "g49tj7"
private let groupName = "Switchboard"
private let template = "Run /go on {url}\n\n{title}\n\n{body}"
private let rubric = "Bugs before features.\nSmall before large."

private func gate(target: Int = 5, repo gateRepo: String = repo, group: String = groupID) -> Schedule.Gate {
  Schedule.Gate(group: group, repo: gateRepo, target: target, template: template, rubric: rubric)
}

private func gateRequest(
  group: String = groupID, repo requestRepo: String = repo, target: Int = 5,
  template requestTemplate: String = template,
  rubric requestRubric: String = rubric
) -> ScheduleRequest.Gate {
  ScheduleRequest.Gate(
    group: group, repo: requestRepo, target: target, template: requestTemplate, rubric: requestRubric)
}

/// A schedule from a request. `makeSchedule` gets the group that sbd resolved from the request's group.
private func make(
  id: String = "rk3x9p", every: String? = "30m", prompt: String? = nil, gate: ScheduleRequest.Gate? = gateRequest()
) throws -> Schedule {
  try ScheduleRequest(every: every, prompt: prompt, by: nil, gate: gate).makeSchedule(
    id: id, now: now, group: (groupID, groupName))
}

private func plain(id: String = "rm76hh", prompt: String = "check the queue") -> Schedule {
  Schedule(id: id, prompt: prompt, every: 30 * minute, next: now + 30 * minute, by: .you, created: now)
}

private func gated(id: String = "tp4k2m", repo gateRepo: String = repo, group: String = groupID, prompt: String? = nil)
  -> Schedule
{
  var s = plain(id: id, prompt: prompt ?? "tick \(id)")
  s.gate = gate(repo: gateRepo, group: group)
  return s
}

private func run(_ t: Int64 = now, skipped: Int = 0) -> Schedule.Run {
  Schedule.Run(t: t, outcome: .pasted, skipped: skipped, error: nil)
}

/// The message of the error that the body throws, or "no error".
private func message(_ body: () throws -> Any) -> String {
  do {
    _ = try body()
    return "no error"
  } catch {
    return "\(error)"
  }
}

private func check(_ result: Schedule.Gate.Check.Result = .gated, t: Int64 = now - 2 * minute) -> Schedule.Gate.Check {
  Schedule.Gate.Check(
    t: t, result: result, active: 3, target: 5, started: ["s9", "s10"],
    skipped: [Schedule.Gate.Skip(ref: "#12", reason: "written by mallory, who isn't you or a teammate")],
    error: result == .failed ? "gh failed" : nil)
}

/// The suites nest under one name, so `--filter ScheduleGateTests` runs them all.
@Suite struct ScheduleGateTests {}

// MARK: - Coding

extension ScheduleGateTests {
  @Suite struct Coding {
    /// A row that an sbd from before the gate stored has no `gate` key.
    @Test func aStoredRowWithoutAGateDecodesWithNoGate() throws {
      let text = """
        {"id": "rm76hh", "prompt": "check the queue", "every": 1800000, "next": 1800000000000, "by": "you",
         "created": 1799998200000}
        """

      #expect(try JSONCoding.decode(Schedule.self, from: text).gate == nil)
    }

    @Test func aStoredRunWithoutGatedDecodesWithNoGatedCount() throws {
      let run = try JSONCoding.decode(Schedule.Run.self, from: #"{"t": 1, "outcome": "pasted", "skipped": 2}"#)

      #expect(run.gated == nil)
    }

    @Test func aScheduleWithoutAGateEncodesNoGateKey() throws {
      let object = try #require(JSON.parse(try JSONCoding.encode(plain()))?.object)

      #expect(object["gate"] == nil)
    }

    @Test func aRunWithoutAGatedCountEncodesNoGatedKey() throws {
      let object = try #require(JSON.parse(try JSONCoding.encode(run()))?.object)

      #expect(object["gated"] == nil)
    }

    @Test func aNewGateRoundTrips() throws {
      let g = gate()

      #expect(try JSONCoding.decode(Schedule.Gate.self, from: try JSONCoding.encode(g)) == g)
    }

    @Test func aGateWithStartedGatedAndLastRoundTrips() throws {
      var g = gate()
      g.started = ["s9", "s10"]
      g.gated = 4
      g.last = check(.started)

      #expect(try JSONCoding.decode(Schedule.Gate.self, from: try JSONCoding.encode(g)) == g)
    }

    @Test func aFailedCheckKeepsItsError() throws {
      let c = check(.failed)

      #expect(try JSONCoding.decode(Schedule.Gate.Check.self, from: try JSONCoding.encode(c)) == c)
    }

    @Test func aScheduleWithAGateRoundTrips() throws {
      var s = gated()
      s.gate?.last = check()

      #expect(try JSONCoding.decode(Schedule.self, from: try JSONCoding.encode(s)) == s)
    }

    @Test func aRunWithAGatedCountRoundTrips() throws {
      var r = run(skipped: 1)
      r.gated = 3

      #expect(try JSONCoding.decode(Schedule.Run.self, from: try JSONCoding.encode(r)) == r)
    }

    /// The Loops tab and `sb schedule ls --json` read these raw values.
    @Test(arguments: [
      (Schedule.Gate.Check.Result.gated, "gated"), (.started, "started"), (.prompted, "prompted"), (.failed, "failed"),
    ])
    func eachCheckResultHasItsWireName(_ result: Schedule.Gate.Check.Result, _ name: String) throws {
      #expect(try JSONCoding.encode(result) == "\"\(name)\"")
    }

    @Test func aScheduleRowWithAGateRoundTrips() throws {
      let row = ScheduleRow(session: "op1", name: "Operator", schedule: gated())

      #expect(try JSONCoding.decode(ScheduleRow.self, from: try JSONCoding.encode(row)).schedule == row.schedule)
    }
  }
}

// MARK: - Record

extension ScheduleGateTests {
  @Suite struct Record {
    @Test func recordFoldsThePendingGatedCountIntoTheRun() {
      var s = gated()
      s.gate?.gated = 3

      s.record(run())

      #expect(s.last?.gated == 3)
    }

    @Test func recordFoldsThePendingGatedCountIntoTheNewestOfTheRuns() {
      var s = gated()
      s.gate?.gated = 3

      s.record(run())

      #expect(s.runs?.first?.gated == 3)
    }

    @Test func recordResetsThePendingGatedCount() {
      var s = gated()
      s.gate?.gated = 3

      s.record(run())

      #expect((s.gate?.gated ?? 0) == 0)
    }

    @Test func aRunAfterTheResetCarriesNoGatedCount() {
      var s = gated()
      s.gate?.gated = 3
      s.record(run())

      s.record(run(now + minute))

      #expect(s.last?.gated == nil)
    }

    /// `Run.gated` is omitted when zero.
    @Test func aRunWithNoPendingGatedCountHasNoGatedCount() {
      var s = gated()

      s.record(run())

      #expect(s.last?.gated == nil)
    }

    @Test func aPendingCountOfZeroLeavesTheRunWithNoGatedCount() {
      var s = gated()
      s.gate?.gated = 0

      s.record(run())

      #expect(s.last?.gated == nil)
    }

    @Test func recordKeepsTheGatesOtherFields() {
      var s = gated()
      s.gate?.started = ["s9"]
      s.gate?.last = check()
      s.gate?.gated = 2

      s.record(run())

      #expect(s.gate?.started == ["s9"])
      #expect(s.gate?.last == check())
    }

    @Test func recordOnAScheduleWithoutAGateLeavesTheRunAsGiven() {
      var s = plain()

      s.record(run())

      #expect(s.last == run())
    }
  }
}

// MARK: - Run text

extension ScheduleGateTests {
  @Suite struct RunText {
    @Test func aRunWithGatedDueTimesSaysSo() {
      var r = run(now - 5 * minute)
      r.gated = 3

      #expect(r.text(now: now) == "pasted 5m ago · 3 gated")
    }

    @Test func theGatedCountComesAfterTheSkippedCount() {
      var r = run(now - 5 * minute, skipped: 2)
      r.gated = 3

      #expect(r.text(now: now) == "pasted 5m ago · 2 skipped · 3 gated")
    }

    @Test func aGatedCountOfZeroAddsNothing() {
      var r = run(now - 5 * minute)
      r.gated = 0

      #expect(r.text(now: now) == "pasted 5m ago")
    }
  }
}

// MARK: - Request

extension ScheduleGateTests {
  @Suite struct Request {
    @Test func theRequestReadsTheGateObjectFromTheWire() throws {
      let text = """
        {"every": "30m", "gate": {"group": "g49tj7", "repo": "haacked/switchboard", "target": 5,
         "template": "Run /go on {url}", "rubric": "Bugs first"}}
        """

      let request = try JSONCoding.decode(ScheduleRequest.self, from: text)

      #expect(request.gate == gateRequest(template: "Run /go on {url}", rubric: "Bugs first"))
    }

    @Test func aRequestWithoutAGateDecodesWithNoGate() throws {
      let request = try JSONCoding.decode(ScheduleRequest.self, from: #"{"every": "30m", "prompt": "check"}"#)

      #expect(request.gate == nil)
    }

    /// The group check comes before the interval check, so a request missing both names the group.
    @Test func aGatedRequestWithoutAResolvedGroupIsRefusedBeforeItsInterval() {
      let refusal = message {
        try ScheduleRequest(every: nil, prompt: nil, by: nil, gate: gateRequest()).makeSchedule(id: "rk3x9p", now: now)
      }

      #expect(refusal.contains("a top-up needs a group"))
    }

    @Test func aGatedScheduleStoresTheResolvedGroupId() throws {
      #expect(try make(gate: gateRequest(group: "Switchboard")).gate?.group == groupID)
    }

    @Test func aGatedScheduleStoresTheRepoTargetTemplateAndRubric() throws {
      let g = try #require(try make().gate)

      #expect(g.repo == repo)
      #expect(g.target == 5)
      #expect(g.template == template)
      #expect(g.rubric == rubric)
    }

    @Test func aNewGateHasNoStartedSessionsNoGatedCountAndNoCheck() throws {
      let g = try #require(try make().gate)

      #expect(g.started == nil)
      #expect(g.gated == nil)
      #expect(g.last == nil)
    }

    @Test func aRequestWithoutAGateMakesAScheduleWithoutAGate() throws {
      #expect(try make(prompt: "check the queue", gate: nil).gate == nil)
    }

    @Test(arguments: ["switchboard", "haacked/", "/switchboard", "a/b/c", "", "haacked/switch board", "../x", "./."])
    func refusesARepoThatIsNotOwnerSlashName(_ bad: String) {
      #expect(message { try make(gate: gateRequest(repo: bad)) } != "no error", "\(bad)")
    }

    @Test func theRepoRefusalNamesTheRepo() {
      #expect(message { try make(gate: gateRequest(repo: "switchboard")) }.contains("switchboard"))
    }

    @Test(arguments: [0, 21, -1, 100, Int.min, Int.max])
    func refusesATargetOutsideOneToTwenty(_ target: Int) {
      #expect(message { try make(gate: gateRequest(target: target)) } != "no error", "\(target)")
    }

    @Test(arguments: [1, 20])
    func acceptsATargetAtEachEndOfTheRange(_ target: Int) throws {
      #expect(try make(gate: gateRequest(target: target)).gate?.target == target)
    }

    @Test(arguments: ["", " ", " \n\t "])
    func refusesABlankTemplate(_ blank: String) {
      #expect(message { try make(gate: gateRequest(template: blank)) } != "no error")
    }

    @Test(arguments: ["", " ", " \n\t "])
    func refusesABlankRubric(_ blank: String) {
      #expect(message { try make(gate: gateRequest(rubric: blank)) } != "no error")
    }

    @Test func aGatedScheduleStillNeedsEvery() {
      #expect(message { try make(every: nil) } != "no error")
    }

    @Test(arguments: [nil, "", "   "] as [String?])
    func aGatedScheduleWithoutAPromptStoresTheDefaultPrompt(_ prompt: String?) throws {
      let s = try make(prompt: prompt)

      #expect(s.prompt == Schedule.Gate.defaultPrompt(groupName: groupName, repo: repo, target: 5))
    }

    @Test func aGatedScheduleKeepsTheGivenPromptTrimmed() throws {
      #expect(try make(prompt: "  work the queue  ").prompt == "work the queue")
    }

    /// Without a gate the prompt stays required, as before this PR.
    @Test(arguments: [nil, "", "   "] as [String?])
    func aScheduleWithoutAGateStillNeedsAPrompt(_ prompt: String?) {
      #expect(message { try make(prompt: prompt, gate: nil) } == "a schedule needs a prompt")
    }
  }
}

// MARK: - Duplicates

extension ScheduleGateTests {
  @Suite struct Duplicates {
    @Test func aSecondScheduleWithTheSamePromptIsRefused() {
      #expect(Schedule.duplicate(of: plain(id: "new111"), in: [plain(id: "rm76hh")]) != nil)
    }

    @Test func theRefusalForTheSamePromptNamesTheExistingSchedule() throws {
      let text = try #require(Schedule.duplicate(of: plain(id: "new111"), in: [plain(id: "rm76hh")]))

      #expect(text.contains("rm76hh"))
    }

    /// A request's prompt is trimmed before it is stored, so two prompts that differ only at their ends are the same.
    @Test func aSecondScheduleWhosePromptDiffersOnlyInSurroundingSpaceIsRefused() throws {
      let new = try ScheduleRequest(every: "30m", prompt: "  check the queue \n", by: nil, gate: nil).makeSchedule(
        id: "new111", now: now)

      #expect(Schedule.duplicate(of: new, in: [plain(id: "rm76hh")]) != nil)
    }

    @Test func aScheduleWithADifferentPromptIsAllowed() {
      #expect(Schedule.duplicate(of: plain(id: "new111", prompt: "audit"), in: [plain(id: "rm76hh")]) == nil)
    }

    @Test func aScheduleOnASessionWithNoSchedulesIsAllowed() {
      #expect(Schedule.duplicate(of: plain(), in: []) == nil)
    }

    @Test func aSecondGatedScheduleOnTheSameGroupAndRepoIsRefused() {
      #expect(Schedule.duplicate(of: gated(id: "new111"), in: [gated(id: "tp4k2m")]) != nil)
    }

    @Test func theRefusalForTheSameGateNamesTheExistingSchedule() throws {
      let text = try #require(Schedule.duplicate(of: gated(id: "new111"), in: [plain(), gated(id: "tp4k2m")]))

      #expect(text.contains("tp4k2m"))
    }

    @Test(arguments: ["Haacked/Switchboard", "HAACKED/SWITCHBOARD", "haacked/Switchboard"])
    func aSecondGatedScheduleOnTheSameRepoInAnotherCaseIsRefused(_ other: String) {
      #expect(Schedule.duplicate(of: gated(id: "new111", repo: other), in: [gated(id: "tp4k2m")]) != nil, "\(other)")
    }

    @Test func aGatedScheduleOnTheSameRepoInAnotherGroupIsAllowed() {
      #expect(Schedule.duplicate(of: gated(id: "new111", group: "zz11aa"), in: [gated(id: "tp4k2m")]) == nil)
    }

    @Test func aGatedScheduleOnAnotherRepoInTheSameGroupIsAllowed() {
      #expect(
        Schedule.duplicate(of: gated(id: "new111", repo: "haacked/dotfiles"), in: [gated(id: "tp4k2m")]) == nil)
    }

    /// Decision 44: the top-up schedule can be added while rm76hh, with its other prompt and no gate, exists.
    @Test func aGatedScheduleBesideAnUngatedOneWithAnotherPromptIsAllowed() {
      #expect(Schedule.duplicate(of: gated(id: "new111"), in: [plain(id: "rm76hh")]) == nil)
    }

    @Test func anUngatedScheduleBesideAGatedOneWithAnotherPromptIsAllowed() {
      #expect(Schedule.duplicate(of: plain(id: "new111"), in: [gated(id: "tp4k2m")]) == nil)
    }

    /// The prompt rule covers every schedule, so a gated schedule on another repo with the same prompt is refused.
    @Test func aGatedScheduleWithTheSamePromptOnAnotherRepoIsRefused() {
      let new = gated(id: "new111", repo: "haacked/dotfiles", prompt: "work the queue")

      #expect(Schedule.duplicate(of: new, in: [gated(id: "tp4k2m", prompt: "work the queue")]) != nil)
    }

    @Test func aGatedScheduleWithThePromptOfAnUngatedOneIsRefused() {
      #expect(Schedule.duplicate(of: gated(id: "new111", prompt: "check the queue"), in: [plain(id: "rm76hh")]) != nil)
    }
  }
}

// MARK: - Texts

extension ScheduleGateTests {
  @Suite struct Texts {
    @Test func theDefaultPromptNamesTheGroupRepoAndTarget() {
      #expect(
        Schedule.Gate.defaultPrompt(groupName: "Switchboard", repo: "haacked/switchboard", target: 5)
          == "Work queue tick for Switchboard in haacked/switchboard: merge and clean up what is finished, then top up to 5 working sessions from the open issues and follow-ups, most important first, by the rubric and template below."
      )
    }

    private func status() -> QueueStatus {
      let row = QueueStatus.Row(
        id: "m3", name: "session m3", kind: .work, group: groupID, repository: repo, repositoryRead: true,
        markedDone: false, paused: false, removing: false, state: .readyToMerge, unreadHost: false, prMerged: false,
        hasMergeAction: false, hasRemovalAction: false, started: true, startWaitingForSlot: false)
      return QueueStatus.compute([row], gate: gate())
    }

    private func fallback(failure: String? = nil) -> String {
      gate().fallbackMessage(status: status(), prompt: "Work the queue now.", failure: failure)
    }

    @Test func theFallbackMessageHoldsEachStatusLine() {
      let text = fallback()

      for line in status().lines { #expect(text.contains(line), "\(line)") }
    }

    @Test func theFallbackMessageHoldsThePrompt() {
      #expect(fallback().contains("Work the queue now."))
    }

    @Test func theFallbackMessageHoldsTheRubric() {
      #expect(fallback().contains(rubric))
    }

    @Test func theFallbackMessageHoldsTheTemplate() {
      #expect(fallback().contains(template))
    }

    @Test func theFallbackMessagePutsTheStatusBeforeThePrompt() throws {
      let text = fallback()
      let firstLine = try #require(status().lines.first)

      let statusAt = try #require(text.range(of: firstLine)).lowerBound
      let promptAt = try #require(text.range(of: "Work the queue now.")).lowerBound
      #expect(statusAt < promptAt)
    }

    @Test func theFallbackMessagePutsTheRubricAndTemplateAfterThePrompt() throws {
      let text = fallback()

      let promptAt = try #require(text.range(of: "Work the queue now.")).lowerBound
      #expect(try #require(text.range(of: rubric)).lowerBound > promptAt)
      #expect(try #require(text.range(of: template)).lowerBound > promptAt)
    }

    @Test func theFallbackMessageStartsWithTheFailure() {
      let text = fallback(failure: "gh issue list failed: rate limited")

      #expect(
        text.split(separator: "\n", omittingEmptySubsequences: false).first?.contains(
          "gh issue list failed: rate limited") == true)
    }

    @Test func theFallbackMessageWithoutAFailureStartsWithTheStatus() throws {
      let firstLine = try #require(status().lines.first)

      #expect(fallback().hasPrefix(firstLine))
    }

    @Test func theFallbackMessageWithAFailureStillHoldsTheStatusPromptRubricAndTemplate() throws {
      let text = fallback(failure: "the judge timed out")

      #expect(text.contains(try #require(status().lines.first)))
      #expect(text.contains("Work the queue now."))
      #expect(text.contains(rubric))
      #expect(text.contains(template))
    }

    /// `sb schedule ls` and the Loops tab show the gate's last check, so the row never shows a stale run.
    @Test func theListTextGivesTheGroupRepoCountsAndLastCheck() {
      var g = gate()
      g.last = check(.gated, t: now - 2 * minute)

      #expect(
        g.statusText(groupName: groupName, now: now)
          == "topup Switchboard haacked/switchboard 3/5 · checked 2m ago: gated")
    }
  }
}
