import Foundation
import SwitchboardCore
import Testing

private let posthog = "PostHog/posthog"
private let artifactId = "0f3c9a2e-6b1d-4c8e-9a7f-2d5e8b1c4a90"
private let artifactURL = "https://claude.ai/code/artifact/\(artifactId)"

private let start = "<!-- sb:status -->"
private let end = "<!-- /sb:status -->"
private let header = "| Session | State | Wait | PR |"

private func url(_ repo: String, _ number: Int) -> String { "https://github.com/\(repo)/pull/\(number)" }

private let breakerRow = "| 1 | Breaker counts | In review ([posthog#122953](\(url(posthog, 122953)))) |"
private let docsRow = "| 2 | Docs | Not started |"

/// A plan in the shape of the flag evaluations RFC: a prose link, an empty
/// generated block, and a work table whose one row with a PR link is `breakerRow`.
private let document = """
  # Flag evaluations

  Status as of 2026-11-01. The runbook is in \(url("PostHog/charts", 18303)).

  \(start)
  \(end)

  | # | Item | Status |
  | --- | --- | --- |
  \(breakerRow)
  \(docsRow)

  """

private let documentLinks = [PlanLink(repo: "PostHog/charts", number: 18303), PlanLink(repo: posthog, number: 122953)]

/// The row as the stub's fake chat rewrites it: with " updated" before its last `|`.
private func updated(_ row: String) -> String { String(row.dropLast(2)) + " updated |" }

/// The document as the stub's chat rewrites `breakerRow`.
private let proposed = document.replacingOccurrences(of: breakerRow, with: updated(breakerRow))

/// The docs row after someone else edited it in claude.ai.
private let draftedRow = "| 2 | Docs | In review ([posthog#122896](\(url(posthog, 122896)))) |"

/// The document as someone else edited it in claude.ai after the chat's read.
private let editedElsewhere = document.replacingOccurrences(of: docsRow, with: draftedRow)

private func crlf(_ text: String) -> String { text.replacingOccurrences(of: "\n", with: "\r\n") }

/// The text between the first marker pair.
private func between(_ text: String) -> String? {
  guard let s = text.range(of: start), let e = text.range(of: end, range: s.upperBound..<text.endIndex) else {
    return nil
  }
  return String(text[s.upperBound..<e.lowerBound])
}

/// The text before the first start marker and after the end marker that follows it.
private func outside(_ text: String) -> [String] {
  guard let s = text.range(of: start), let e = text.range(of: end, range: s.upperBound..<text.endIndex) else {
    return [text]
  }
  return [String(text[..<s.lowerBound]), String(text[e.upperBound...])]
}

extension Instance {
  /// The fake Artifact tool's store, which the stub chat reads and publishes.
  fileprivate var artifactFile: String { "\(home.path)/artifacts/\(artifactId)" }

  /// Sets the artifact's text and version in the fake store. A nil version removes it.
  fileprivate func storeArtifact(_ text: String, version: String?) throws {
    try FileManager.default.createDirectory(atPath: "\(home.path)/artifacts", withIntermediateDirectories: true)
    try text.write(toFile: artifactFile, atomically: true, encoding: .utf8)
    if let version {
      try version.write(toFile: "\(artifactFile).version", atomically: true, encoding: .utf8)
    } else {
      try? FileManager.default.removeItem(atPath: "\(artifactFile).version")
    }
  }

  fileprivate var storedArtifact: String? { try? String(contentsOfFile: artifactFile, encoding: .utf8) }

  fileprivate var storedVersion: String? { try? String(contentsOfFile: "\(artifactFile).version", encoding: .utf8) }

  /// Waits until the plan matches, and returns it.
  @discardableResult
  fileprivate func waitForPlan(_ id: String, _ what: String, _ match: (PlanDocument) -> Bool) throws -> PlanDocument {
    try waitFor(what, fetch: { try plan(id) }, until: match)
  }

  /// Stores the artifact, attaches it to the group, and waits for the chat's read.
  fileprivate func attachArtifact(group: String, text: String = document, version: String? = "1") throws -> String {
    try storeArtifact(text, version: version)
    let id = try attachPlan(artifactURL, group: group)
    try waitForPlan(id, "the chat's read") { $0.artifact?.copy == text }
    return id
  }

  /// The plan as `sb plan ls --json` lists it.
  fileprivate func planSummary(_ id: String) throws -> PlanSummary {
    let list = try JSONCoding.decode([PlanSummary].self, from: try sb("plan", "ls", "--json"))
    return try #require(list.first { $0.id == id })
  }

  /// Asks the chat to rewrite the rows, and waits for its proposal.
  @discardableResult
  fileprivate func proposeRewrite(_ id: String, rows: [String] = []) throws -> PlanDocument {
    try sb(["plan", "artifact", "rewrite", id] + rows)
    return try waitForPlan(id, "the chat's proposal") { $0.artifact?.proposal != nil }
  }

  /// The group's chat, which sbd created for the plan.
  fileprivate func chatOf(_ group: GroupSummary) throws -> SessionSummary {
    let sessions = try JSONCoding.decode([SessionSummary].self, from: try sb("ls", "--json"))
    return try #require(sessions.first { $0.chat == group.id })
  }

  /// Waits for the chat's reply to its last artifact task that starts with `prefix`.
  fileprivate func waitForChatReply(_ group: GroupSummary, _ prefix: String) throws {
    let chat = try chatOf(group)
    try waitFor(chat.id, "the chat's reply \(prefix)") { $0.lastReply?.hasPrefix(prefix) == true }
  }

  /// The text of each prompt that the group's chat got, oldest first.
  fileprivate func chatPrompts(_ group: String) throws -> [String] {
    try JSONCoding.decode([ChatMessage].self, from: try sb("chat", group, "--log", "--json"))
      .filter { $0.role == .user }.map(\.text)
  }

  /// Runs `sb plan artifact report`, as the chat does, with the text in a file.
  fileprivate func report(_ id: String, kind: String, text: String? = nil, version: String? = nil) throws
    -> CommandResult
  {
    var args = ["plan", "artifact", "report", id, "--kind", kind]
    if let text {
      let file = "\(home.path)/report-\(UUID().uuidString).md"
      try text.write(toFile: file, atomically: true, encoding: .utf8)
      args += ["--file", file]
    }
    if let version { args += ["--version", version] }
    return try run(args)
  }
}

@Suite(.timeLimit(.minutes(2))) struct ArtifactPlanTests {
  // MARK: attach and read

  static let attachForms: [[String]] = [
    ["plan", "attach", "--json", artifactURL, "--group", "Flags"],
    ["plan", "attach", "--json", "Flags", "--artifact", artifactURL],
  ]

  @Test(arguments: attachForms)
  func attachReadsTheArtifactIntoTheCopyThroughTheGroupsChat(_ args: [String]) throws {
    let sbd = try Instance()
    try sbd.addGroup("Flags")
    try sbd.storeArtifact(document, version: "1")

    let id = try #require(JSON.parse(try sbd.sb(args))?["id"]?.string)

    let plan = try sbd.waitForPlan(id, "the chat's read") { $0.artifact?.copy != nil }
    #expect(plan.source.kind == .artifact)
    #expect(plan.source.url == artifactURL)
    #expect(plan.artifact?.copy == document)
    #expect(plan.artifact?.version == "1")
  }

  @Test func rowsAndLinksComeFromTheCopy() throws {
    let sbd = try Instance()
    try sbd.addGroup("Flags")

    let id = try sbd.attachArtifact(group: "Flags")

    let plan = try sbd.plan(id)
    #expect(plan.rows.map(\.text) == [breakerRow, docsRow])
    #expect(plan.links == documentLinks)
    #expect(plan.error == nil)
  }

  @Test func attachCreatesTheGroupsChat() throws {
    let sbd = try Instance()
    let flags = try sbd.addGroup("Flags")

    _ = try sbd.attachArtifact(group: "Flags")

    let sessions = try JSONCoding.decode([SessionSummary].self, from: try sbd.sb("ls", "--json"))
    #expect(sessions.filter { $0.chat == flags.id }.count == 1)
  }

  @Test func readTurnNamesThePlanTheArtifactAndTheTask() throws {
    let sbd = try Instance()
    try sbd.addGroup("Flags")

    let id = try sbd.attachArtifact(group: "Flags")

    let prompt = try #require(try sbd.chatPrompts("Flags").first)
    let lines = prompt.components(separatedBy: "\n")
    #expect(lines.first == "Switchboard plan artifact task.")
    #expect(lines.contains("plan: \(id)"))
    #expect(lines.contains("artifact: \(artifactURL)"))
    #expect(lines.contains("task: read"))
  }

  @Test func readTurnHoldsNoTextOfTheArtifact() throws {
    let sbd = try Instance()
    try sbd.addGroup("Flags")
    let id = try sbd.attachArtifact(group: "Flags")
    try sbd.proposeRewrite(id, rows: ["1"])

    let prompts = try sbd.chatPrompts("Flags")

    #expect(prompts.count == 2)
    #expect(prompts.allSatisfy { !$0.contains("Flag evaluations") && !$0.contains(docsRow) })
  }

  @Test func artifactWithoutAVersionGivesACopyWithoutOne() throws {
    let sbd = try Instance()
    try sbd.addGroup("Flags")

    let id = try sbd.attachArtifact(group: "Flags", version: nil)

    let plan = try sbd.plan(id)
    #expect(plan.artifact?.copy == document)
    #expect(plan.artifact?.version == nil)
  }

  @Test func readTakesTheArtifactsNewTextAndVersion() throws {
    let sbd = try Instance()
    try sbd.addGroup("Flags")
    let id = try sbd.attachArtifact(group: "Flags")
    try sbd.storeArtifact(editedElsewhere, version: "2")

    try sbd.sb("plan", "artifact", "read", id)

    let plan = try sbd.waitForPlan(id, "the second read") { $0.artifact?.copy == editedElsewhere }
    #expect(plan.artifact?.version == "2")
    #expect(plan.rows.map(\.text) == [breakerRow, draftedRow])
  }

  @Test func pollNeverReadsAnArtifactPlan() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    try sbd.addGroup("Flags")
    let id = try sbd.attachArtifact(group: "Flags")
    try sbd.storeArtifact(editedElsewhere, version: "2")

    try sbd.poll(all: true)
    try sbd.poll(all: true)

    let plan = try sbd.plan(id)
    #expect(plan.artifact?.copy == document)
    #expect(plan.error == nil)
  }

  // MARK: out of date

  /// Flags with the artifact plan, after the poller read #122953 as open.
  func flagsWithArtifact(_ github: FakeGitHub) throws -> (Instance, String) {
    let sbd = try Instance.withGitHub(github)
    try sbd.addGroup("Flags")
    let id = try sbd.attachArtifact(group: "Flags")
    try sbd.poll(all: true)
    try sbd.poll(all: true)
    return (sbd, id)
  }

  @Test func rowOfTheCopyIsOutOfDateAfterARecordedMerge() throws {
    let github = try FakeGitHub()
    let (sbd, _) = try flagsWithArtifact(github)
    #expect(try sbd.outOfDate(group: "Flags").isEmpty)

    github.change(122953) { $0["state"] = "MERGED" }
    try sbd.poll(all: true)

    #expect(try sbd.outOfDate(group: "Flags") == [breakerRow])
  }

  @Test func rewriteWithoutRowsNamesTheOutOfDateRows() throws {
    let github = try FakeGitHub()
    let (sbd, id) = try flagsWithArtifact(github)
    github.change(122953) { $0["state"] = "MERGED" }
    try sbd.poll(all: true)

    let plan = try sbd.proposeRewrite(id)

    #expect(plan.artifact?.proposal?.rows == [breakerRow])
    #expect(plan.artifact?.proposal?.text == proposed)
  }

  @Test func publishedRewriteLeavesNoRowOutOfDate() throws {
    let github = try FakeGitHub()
    let (sbd, id) = try flagsWithArtifact(github)
    github.change(122953) { $0["state"] = "MERGED" }
    try sbd.poll(all: true)
    try sbd.proposeRewrite(id)

    try sbd.sb("plan", "artifact", "apply", id)
    try sbd.waitForPlan(id, "the publish") { $0.artifact?.copy == proposed }
    try sbd.poll(all: true)

    #expect(try sbd.outOfDate(group: "Flags").isEmpty)
  }

  // MARK: rewrite proposals

  @Test func rewriteProposesTheChatsTextForTheNamedRow() throws {
    let sbd = try Instance()
    try sbd.addGroup("Flags")
    let id = try sbd.attachArtifact(group: "Flags")

    let plan = try sbd.proposeRewrite(id, rows: ["1"])

    let proposal = try #require(plan.artifact?.proposal)
    #expect(proposal.rows == [breakerRow])
    #expect(proposal.base == document)
    #expect(proposal.text == proposed)
    #expect(proposal.state == .pending)
    #expect(!proposal.checked)
  }

  @Test func rewritePublishesNothing() throws {
    let sbd = try Instance()
    let flags = try sbd.addGroup("Flags")
    let id = try sbd.attachArtifact(group: "Flags")

    try sbd.proposeRewrite(id, rows: ["1"])
    try sbd.waitForChatReply(flags, "Artifact rewrite")

    #expect(sbd.storedArtifact == document)
    #expect(sbd.storedVersion == "1")
    #expect(try sbd.plan(id).artifact?.copy == document)
  }

  /// An artifact with CRLF line ends parses to the same rows as its LF
  /// copy, so the same rewrite must pass the check.
  @Test func crlfArtifactGetsTheSameProposalAsItsLFCopy() throws {
    let sbd = try Instance()
    try sbd.addGroup("Flags")
    let id = try sbd.attachArtifact(group: "Flags", text: crlf(document))

    let plan = try sbd.proposeRewrite(id, rows: ["1"])

    #expect(plan.artifact?.proposal?.rows == [breakerRow])
    #expect(plan.artifact?.proposal?.text == crlf(proposed))
  }

  @Test func planListShowsTheProposalsDiff() throws {
    let sbd = try Instance()
    try sbd.addGroup("Flags")
    let id = try sbd.attachArtifact(group: "Flags")

    try sbd.proposeRewrite(id, rows: ["1"])

    let summary = try sbd.planSummary(id)
    #expect(summary.proposal?.diff == ["- \(breakerRow)", "+ \(updated(breakerRow))"])
    #expect(summary.proposal?.state == .pending)
  }

  static let refusedWhileProposed: [[String]] = [
    ["plan", "artifact", "rewrite", "PLAN", "2"],
    ["plan", "update", "PLAN"],
  ]

  @Test(arguments: refusedWhileProposed)
  func newProposalIsRefusedWhileOneExists(_ args: [String]) throws {
    let sbd = try Instance()
    try sbd.addGroup("Flags")
    let id = try sbd.attachArtifact(group: "Flags")
    let before = try #require(try sbd.proposeRewrite(id, rows: ["1"]).artifact?.proposal)

    let r = try sbd.run(args.map { $0 == "PLAN" ? id : $0 })

    #expect(r.status != 0)
    #expect(try sbd.plan(id).artifact?.proposal == before)
  }

  @Test func updateProposesTheCopyWithTheGeneratedTable() throws {
    let sbd = try Instance()
    let flags = try sbd.addGroup("Flags")
    let id = try sbd.attachArtifact(group: "Flags")
    try sbd.waitForChatReply(flags, "Artifact read")

    try sbd.sb("plan", "update", id)

    let plan = try sbd.waitForPlan(id, "the table's proposal") { $0.artifact?.proposal != nil }
    let proposal = try #require(plan.artifact?.proposal)
    #expect(proposal.base == document)
    #expect(outside(proposal.text) == outside(document))
    #expect(try #require(between(proposal.text)).contains(header))
    #expect(sbd.storedArtifact == document)
  }

  @Test func autoUpdateIsRefusedForAnArtifactPlan() throws {
    let sbd = try Instance()
    try sbd.addGroup("Flags")
    let id = try sbd.attachArtifact(group: "Flags")

    let r = try sbd.run("plan", "auto", id, "on")

    #expect(r.status != 0)
    #expect(try !sbd.plan(id).autoUpdate)
  }

  // MARK: apply and reject

  @Test func applyRepublishesTheSameURLAndTheCopyTakesTheText() throws {
    let sbd = try Instance()
    try sbd.addGroup("Flags")
    let id = try sbd.attachArtifact(group: "Flags")
    try sbd.proposeRewrite(id, rows: ["1"])

    try sbd.sb("plan", "artifact", "apply", id)

    let plan = try sbd.waitForPlan(id, "the publish") { $0.artifact?.proposal == nil }
    #expect(sbd.storedArtifact == proposed)
    #expect(sbd.storedVersion == "2")
    #expect(plan.artifact?.copy == proposed)
    #expect(plan.artifact?.version == "2")
    #expect(plan.error == nil)
  }

  @Test func publishTurnNamesTheSameURL() throws {
    let sbd = try Instance()
    try sbd.addGroup("Flags")
    let id = try sbd.attachArtifact(group: "Flags")
    try sbd.proposeRewrite(id, rows: ["1"])

    try sbd.sb("plan", "artifact", "apply", id)
    try sbd.waitForPlan(id, "the publish") { $0.artifact?.proposal == nil }

    let publish = try #require(try sbd.chatPrompts("Flags").last)
    let lines = publish.components(separatedBy: "\n")
    #expect(lines.contains("task: publish"))
    #expect(lines.contains("artifact: \(artifactURL)"))
  }

  @Test func publishedRowsComeFromTheNewCopy() throws {
    let sbd = try Instance()
    try sbd.addGroup("Flags")
    let id = try sbd.attachArtifact(group: "Flags")
    try sbd.proposeRewrite(id, rows: ["1"])

    try sbd.sb("plan", "artifact", "apply", id)

    let plan = try sbd.waitForPlan(id, "the publish") { $0.artifact?.copy == proposed }
    #expect(plan.rows.map(\.text) == [updated(breakerRow), docsRow])
  }

  @Test func rejectDropsTheProposalAndPublishesNothing() throws {
    let sbd = try Instance()
    let flags = try sbd.addGroup("Flags")
    let id = try sbd.attachArtifact(group: "Flags")
    try sbd.proposeRewrite(id, rows: ["1"])
    try sbd.waitForChatReply(flags, "Artifact rewrite")

    try sbd.sb("plan", "artifact", "reject", id)

    let plan = try sbd.plan(id)
    #expect(plan.artifact?.proposal == nil)
    #expect(plan.artifact?.copy == document)
    #expect(sbd.storedArtifact == document)
    #expect(sbd.storedVersion == "1")
  }

  @Test func applyWithoutAProposalIsRefused() throws {
    let sbd = try Instance()
    try sbd.addGroup("Flags")
    let id = try sbd.attachArtifact(group: "Flags")

    let r = try sbd.run("plan", "artifact", "apply", id)

    #expect(r.status != 0)
    #expect(sbd.storedArtifact == document)
  }

  // MARK: conflicts

  /// How the artifact changed in claude.ai between the chat's read and the publish.
  enum Move: String, CaseIterable {
    case textAndVersion, textOnly, versionOnly, textWithoutVersions

    var copyVersion: String? { self == .textWithoutVersions ? nil : "1" }
    var text: String { self == .versionOnly ? document : editedElsewhere }
    var version: String? {
      switch self {
      case .textAndVersion, .versionOnly: "2"
      case .textOnly: "1"
      case .textWithoutVersions: nil
      }
    }
  }

  @Test(arguments: Move.allCases)
  func movedArtifactAbortsThePublishAndStaysAsItIs(_ move: Move) throws {
    let sbd = try Instance()
    let flags = try sbd.addGroup("Flags")
    let id = try sbd.attachArtifact(group: "Flags", version: move.copyVersion)
    try sbd.proposeRewrite(id, rows: ["1"])
    try sbd.storeArtifact(move.text, version: move.version)

    try sbd.sb("plan", "artifact", "apply", id)
    try sbd.waitForChatReply(flags, "Artifact publish")

    #expect(sbd.storedArtifact == move.text)
    #expect(sbd.storedVersion == move.version)
  }

  @Test(arguments: Move.allCases)
  func movedArtifactDropsTheProposalAndTheCopyTakesItsText(_ move: Move) throws {
    let sbd = try Instance()
    let flags = try sbd.addGroup("Flags")
    let id = try sbd.attachArtifact(group: "Flags", version: move.copyVersion)
    try sbd.proposeRewrite(id, rows: ["1"])
    try sbd.storeArtifact(move.text, version: move.version)

    try sbd.sb("plan", "artifact", "apply", id)
    try sbd.waitForChatReply(flags, "Artifact publish")

    let plan = try sbd.plan(id)
    #expect(plan.artifact?.proposal == nil)
    #expect(plan.artifact?.copy == move.text)
    #expect(plan.error?.isEmpty == false)
  }

  /// The copy has no version, so a version that the artifact shows now
  /// proves no move. Its text matches, so the publish goes ahead.
  @Test func versionOnTheArtifactAloneIsNoMove() throws {
    let sbd = try Instance()
    try sbd.addGroup("Flags")
    let id = try sbd.attachArtifact(group: "Flags", version: nil)
    try sbd.proposeRewrite(id, rows: ["1"])
    try sbd.storeArtifact(document, version: "5")

    try sbd.sb("plan", "artifact", "apply", id)

    try sbd.waitForPlan(id, "the publish") { $0.artifact?.copy == proposed }
    #expect(sbd.storedArtifact == proposed)
    #expect(sbd.storedVersion == "6")
  }

  // MARK: stale copy

  @Test func copyIsStaleOnceItIsOlderThanADay() throws {
    let sbd = try Instance()
    try sbd.addGroup("Flags")
    let id = try sbd.attachArtifact(group: "Flags")
    #expect(try sbd.planSummary(id).copyStale == false)

    try sbd.advanceClock(Plans.artifactCopyMaxAge + 60_000)

    #expect(try sbd.planSummary(id).copyStale == true)
    #expect(try sbd.groupNamed("Flags").plans?.first { $0.id == id }?.copyStale == true)
  }

  @Test func copyIsCurrentJustUnderADay() throws {
    let sbd = try Instance()
    try sbd.addGroup("Flags")
    let id = try sbd.attachArtifact(group: "Flags")

    try sbd.advanceClock(Plans.artifactCopyMaxAge - 60_000)

    #expect(try sbd.planSummary(id).copyStale == false)
  }

  @Test func readClearsTheStaleMarker() throws {
    let sbd = try Instance()
    try sbd.addGroup("Flags")
    let id = try sbd.attachArtifact(group: "Flags")
    try sbd.advanceClock(Plans.artifactCopyMaxAge + 60_000)
    #expect(try sbd.planSummary(id).copyStale == true)

    try sbd.sb("plan", "artifact", "read", id)

    try sbd.waitFor("the new copy", fetch: { try sbd.planSummary(id) }, until: { $0.copyStale == false })
  }

  @Test func planWithNoCopyIsStale() throws {
    let sbd = try Instance()
    let flags = try sbd.addGroup("Flags")

    let id = try sbd.attachPlan(artifactURL, group: "Flags")
    try sbd.waitForChatReply(flags, "Artifact read: no artifact")

    #expect(try sbd.plan(id).artifact?.copy == nil)
    #expect(try sbd.planSummary(id).copyStale == true)
  }

  @Test func otherPlanTypesHaveNoStaleMarker() throws {
    let sbd = try Instance()
    try sbd.addGroup("Flags")
    try sbd.writePlan(sbd.planFile, document)
    let id = try sbd.attachPlan(sbd.planFile, group: "Flags")

    try sbd.advanceClock(Plans.artifactCopyMaxAge + 60_000)

    #expect(try sbd.planSummary(id).copyStale == nil)
  }

  // MARK: refusals

  @Test func artifactPlanOnASessionIsRefused() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "owner")
    try sbd.storeArtifact(document, version: "1")

    let r = try sbd.run("plan", "attach", artifactURL, "--session", s.id)

    #expect(r.status != 0)
    #expect(try sbd.planIds().isEmpty)
  }

  @Test func proposalReportWithoutARewriteIsRefused() throws {
    let sbd = try Instance()
    try sbd.addGroup("Flags")
    let id = try sbd.attachArtifact(group: "Flags")

    let r = try sbd.report(id, kind: "proposal", text: proposed)

    #expect(r.status != 0)
    #expect(try sbd.plan(id).artifact?.proposal == nil)
  }

  /// A slow turn keeps the chat busy, so the rewrite stays pending while the
  /// test reports a proposal that changes a row it did not name.
  @Test func proposalThatChangesAnotherRowIsRefused() throws {
    let sbd = try Instance()
    try sbd.addGroup("Flags")
    let id = try sbd.attachArtifact(group: "Flags")
    try sbd.sb("chat", "Flags", "--send", "slow 30")
    try sbd.sb("plan", "artifact", "rewrite", id, "1")
    let rows = try #require(try sbd.plan(id).artifact?.rewrite)
    #expect(rows == [breakerRow])

    let r = try sbd.report(
      id, kind: "proposal", text: document.replacingOccurrences(of: docsRow, with: updated(docsRow)))

    #expect(r.status != 0)
    let plan = try sbd.plan(id)
    #expect(plan.artifact?.proposal == nil)
    #expect(plan.artifact?.rewrite == rows)
  }

  @Test func checkReportBeforeApplyIsRefused() throws {
    let sbd = try Instance()
    try sbd.addGroup("Flags")
    let id = try sbd.attachArtifact(group: "Flags")
    let before = try #require(try sbd.proposeRewrite(id, rows: ["1"]).artifact?.proposal)

    let r = try sbd.report(id, kind: "check", text: document, version: "1")

    #expect(r.status != 0)
    #expect(try sbd.plan(id).artifact?.proposal == before)
  }

  @Test func publishedReportBeforeApplyIsRefused() throws {
    let sbd = try Instance()
    try sbd.addGroup("Flags")
    let id = try sbd.attachArtifact(group: "Flags")
    try sbd.proposeRewrite(id, rows: ["1"])

    let r = try sbd.report(id, kind: "published", version: "9")

    #expect(r.status != 0)
    let plan = try sbd.plan(id)
    #expect(plan.artifact?.copy == document)
    #expect(plan.artifact?.version == "1")
    #expect(plan.artifact?.proposal != nil)
  }

  /// A slow turn keeps the chat busy, so the publish turn waits in its queue
  /// and the approved proposal stays unchecked.
  @Test func publishedReportBeforeTheCheckIsRefused() throws {
    let sbd = try Instance()
    try sbd.addGroup("Flags")
    let id = try sbd.attachArtifact(group: "Flags")
    try sbd.proposeRewrite(id, rows: ["1"])
    try sbd.sb("chat", "Flags", "--send", "slow 30")
    try sbd.sb("plan", "artifact", "apply", id)
    #expect(try sbd.plan(id).artifact?.proposal?.state == .publishing)

    let r = try sbd.report(id, kind: "published", version: "9")

    #expect(r.status != 0)
    let plan = try sbd.plan(id)
    #expect(plan.artifact?.copy == document)
    #expect(plan.artifact?.proposal?.checked == false)
  }

  @Test(arguments: ["update", "write", ""])
  func reportOfAnUnknownKindIsRefused(_ kind: String) throws {
    let sbd = try Instance()
    try sbd.addGroup("Flags")
    let id = try sbd.attachArtifact(group: "Flags")

    let r = try sbd.report(id, kind: kind, text: "hijacked")

    #expect(r.status != 0)
    #expect(try sbd.plan(id).artifact?.copy == document)
  }

  @Test func reportForAPlanThatIsNotAnArtifactIsRefused() throws {
    let sbd = try Instance()
    try sbd.addGroup("Flags")
    try sbd.writePlan(sbd.planFile, document)
    let id = try sbd.attachPlan(sbd.planFile, group: "Flags")

    let r = try sbd.report(id, kind: "read", text: "hijacked")

    #expect(r.status != 0)
    #expect(try sbd.plan(id).rows.map(\.text) == [breakerRow, docsRow])
  }

  // MARK: plan_artifact

  /// An MCP client of the switchboard server in the group's chat's --mcp-config.
  func chatServer(_ sbd: Instance, _ group: String) throws -> MCPClient {
    let c = try JSONCoding.decode(SessionSummary.self, from: try sbd.sb("chat", group, "--json"))
    try sbd.waitFor(c.id, "the chat") { $0.live }
    let launch = try #require(sbd.stubArgs().first { $0.contains(c.claudeSessionId) })
    let config = try #require(MCPToolServerTests.switchboardConfig(in: launch))
    return try MCPClient(server: try #require(config["mcpServers"]?["switchboard"]))
  }

  @Test func planArtifactFromAnotherGroupsChatIsRefused() throws {
    let sbd = try Instance()
    try sbd.addGroup("Flags")
    try sbd.addGroup("Billing")
    let billing = try sbd.attachArtifact(group: "Billing")
    let mcp = try chatServer(sbd, "Flags")

    let result = try mcp.call(
      "plan_artifact", ["plan": .string(billing), "kind": "read", "text": "hijacked", "version": "9"])

    #expect(result.isError)
    let plan = try sbd.plan(billing)
    #expect(plan.artifact?.copy == document)
    #expect(plan.artifact?.version == "1")
  }

  enum Carrier: CaseIterable { case text, file }

  @Test(arguments: Carrier.allCases)
  func planArtifactFromTheGroupsChatTakesTheRead(_ carrier: Carrier) throws {
    let sbd = try Instance()
    try sbd.addGroup("Flags")
    let id = try sbd.attachArtifact(group: "Flags")
    let mcp = try chatServer(sbd, "Flags")
    var args: [String: JSON] = ["plan": .string(id), "kind": "read", "version": "9"]
    switch carrier {
    case .text:
      args["text"] = .string(editedElsewhere)
    case .file:
      let file = "\(sbd.home.path)/read.md"
      try editedElsewhere.write(toFile: file, atomically: true, encoding: .utf8)
      args["file"] = .string(file)
    }

    let result = try mcp.call("plan_artifact", args)

    #expect(!result.isError, "\(result.text)")
    let plan = try sbd.plan(id)
    #expect(plan.artifact?.copy == editedElsewhere)
    #expect(plan.artifact?.version == "9")
  }
}
