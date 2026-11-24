import Foundation
import Testing

@testable import SwitchboardCore

private func entry(_ name: String, hash: String? = nil, origin: ManagerSkillRow.Origin = .user) -> CatalogEntry {
  CatalogEntry(
    name: name, origin: origin, path: origin == .listing ? nil : "/a/skills/\(name)/SKILL.md",
    description: "The \(name) skill.", hash: hash ?? "hash-\(name)")
}

private func catalog(_ entries: CatalogEntry...) -> [String: CatalogEntry] {
  Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })
}

/// A cache that holds each label under the key of its hash for the model.
private func labels(_ pairs: [String: SkillLabel], model: String = "haiku") -> SkillLabelCache {
  var cache = SkillLabelCache()
  for (hash, label) in pairs {
    cache.labels[SkillLabelCache.key(hash: hash, model: model)] = .init(
      label: label, reason: "It runs a pipeline.", model: model, t: 1)
  }
  return cache
}

private func settings(work: [String] = [], safe: [String] = [], model: String = "haiku") -> ManagerSkillSettings {
  var s = ManagerSkillSettings()
  s.work = work
  s.safe = safe
  s.model = model
  return s
}

private func failure(_ category: SkillFailure.Category) -> SkillFailure {
  SkillFailure(category: category, message: "claude failed: \(category.rawValue)", t: 1)
}

private func key(_ hash: String, model: String = "haiku") -> String { SkillLabelCache.key(hash: hash, model: model) }

private func decide(
  _ name: String?, _ catalog: [String: CatalogEntry] = [:], labels: SkillLabelCache = SkillLabelCache(),
  failures: [String: SkillFailure] = [:], settings: ManagerSkillSettings = ManagerSkillSettings(),
  bypass: SkillBypass? = nil
) -> ManagerSkillGate.Decision {
  ManagerSkillGate.decide(
    name: name, catalog: catalog, labels: labels, failures: failures, settings: settings, bypass: bypass)
}

private func blocks(_ decision: ManagerSkillGate.Decision) -> Bool {
  if case .blocked = decision { return true }
  return false
}

/// `ManagerSkillGate.decide` is the one decision that the hook, the `slash-commands` label, and `manager-skills`
/// share. Its order is D15 of the plan: no name or a built-in, then a bypass, then config.json, then the cached
/// label of the entry's current key, then fail-open.
@Suite struct ManagerSkillGateTests {
  private let go = catalog(entry("go"))
  private let goWork = labels(["hash-go": .work])
  private let goSafe = labels(["hash-go": .safe])

  // MARK: No name and built-ins

  @Test func noNameIsIgnored() {
    #expect(decide(nil, go, labels: goWork, settings: settings(work: ["go"])) == .ignored)
  }

  @Test(arguments: SlashCommand.builtIns.map(\.name))
  func aBuiltInIsIgnoredEvenWhenConfigAndALabelSayWork(_ name: String) {
    let d = decide(
      name, catalog(entry(name)), labels: labels(["hash-\(name)": .work]), settings: settings(work: [name]))

    #expect(d == .ignored)
  }

  @Test func clearWithAnArmedBypassIsStillIgnored() {
    #expect(decide("clear", bypass: .armed("clear")) == .ignored)
  }

  // MARK: config.json

  @Test func aConfigWorkNameIsBlockedByConfig() {
    #expect(decide("go", go, settings: settings(work: ["go"])) == .blocked(by: .config))
  }

  @Test func aConfigSafeNameIsAllowedByConfig() {
    #expect(decide("go", go, settings: settings(safe: ["go"])) == .allowed(by: .config))
  }

  @Test func aConfigSafeNameBeatsACachedWorkLabel() {
    #expect(decide("go", go, labels: goWork, settings: settings(safe: ["go"])) == .allowed(by: .config))
  }

  @Test func aConfigWorkNameBeatsACachedSafeLabel() {
    #expect(decide("go", go, labels: goSafe, settings: settings(work: ["go"])) == .blocked(by: .config))
  }

  /// An override applies by name, so it covers a bundled skill that discovery never found.
  @Test func aConfigWorkNameThatDiscoveryDidNotFindIsBlocked() {
    #expect(decide("code-review", go, settings: settings(work: ["code-review"])) == .blocked(by: .config))
  }

  @Test func aConfigWorkNameBeatsAFailure() {
    let d = decide("go", go, failures: [key("hash-go"): failure(.timeout)], settings: settings(work: ["go"]))

    #expect(d == .blocked(by: .config))
  }

  // MARK: Cached labels

  @Test func aCachedWorkLabelBlocksByHaiku() {
    #expect(decide("go", go, labels: goWork) == .blocked(by: .haiku))
  }

  @Test func aCachedSafeLabelAllowsByHaiku() {
    #expect(decide("go", go, labels: goSafe) == .allowed(by: .haiku))
  }

  @Test(arguments: [ManagerSkillRow.Origin.user, .project, .command, .plugin, .listing])
  func aWorkLabelBlocksAnEntryOfEachOrigin(_ origin: ManagerSkillRow.Origin) {
    let d = decide("p:s", catalog(entry("p:s", origin: origin)), labels: labels(["hash-p:s": .work]))

    #expect(d == .blocked(by: .haiku))
  }

  @Test func aWorkLabelBlocksEvenWithAFailureOfTheSameKey() {
    let d = decide("go", go, labels: goWork, failures: [key("hash-go"): failure(.timeout)])

    #expect(d == .blocked(by: .haiku))
  }

  @Test func theLabelOfTheFilesOldKeyDoesNotApplyAfterAnEdit() {
    let edited = catalog(entry("go", hash: "hash-go-edited"))

    #expect(decide("go", edited, labels: goWork) == .unchecked(nil))
  }

  // MARK: Fail-open

  @Test func aNeverClassifiedEntryIsUncheckedAndUnlabeled() {
    #expect(decide("go", go) == .unchecked(nil))
  }

  @Test func anUnknownNameIsUncheckedAndUnlabeled() {
    #expect(decide("nope", go, labels: goWork) == .unchecked(nil))
  }

  @Test func aListingOnlyNameWithoutADescriptionHasNoKeyAndIsUnlabeled() {
    let bare = CatalogEntry(name: "bare", origin: .listing, path: nil, description: nil, hash: nil)

    #expect(decide("bare", catalog(bare), labels: goWork) == .unchecked(nil))
  }

  @Test(arguments: [SkillFailure.Category.signedOut, .noQuota, .timeout, .failed, .badAnswer])
  func aFailureOfTheCurrentKeyIsUncheckedWithIt(_ category: SkillFailure.Category) {
    let failed = failure(category)

    #expect(decide("go", go, failures: [key("hash-go"): failed]) == .unchecked(failed))
  }

  @Test func aFailureOfAnOldKeyLeavesTheEditedEntryUnlabeled() {
    let edited = catalog(entry("go", hash: "hash-go-edited"))

    #expect(decide("go", edited, failures: [key("hash-go"): failure(.failed)]) == .unchecked(nil))
  }

  @Test func aLabelUnderAnOlderClassifierVersionDoesNotApply() {
    var old = SkillLabelCache()
    old.labels["\(SkillClassifier.version - 1)/haiku/hash-go"] = .init(
      label: .work, reason: "x", model: "haiku", t: 1)

    #expect(decide("go", go, labels: old) == .unchecked(nil))
  }

  @Test func aLabelOfAnotherModelDoesNotApply() {
    let sonnet = labels(["hash-go": .work], model: "sonnet")

    #expect(decide("go", go, labels: sonnet) == .unchecked(nil))
    #expect(decide("go", go, labels: sonnet, settings: settings(model: "sonnet")) == .blocked(by: .haiku))
  }

  /// A skill can block only when config.json forces `work` or a `work` label exists for its current key.
  @Test(arguments: FailOpen.allCases)
  func noInputWithoutAWorkLabelOrAConfigWorkNameBlocks(_ input: FailOpen) {
    #expect(!blocks(input.decision), "\(input) gave \(input.decision)")
  }

  enum FailOpen: CaseIterable {
    case neverClassified, unknownName, signedOut, noQuota, timeout, failed, badAnswer, editedAfterLabeling
    case versionBump, modelChange, safeLabel, configSafe, noHash

    var decision: ManagerSkillGate.Decision {
      let go = catalog(entry("go"))
      let failures = { (c: SkillFailure.Category) in [key("hash-go"): failure(c)] }
      switch self {
      case .neverClassified: return decide("go", go)
      case .unknownName: return decide("other", go, labels: labels(["hash-go": .work]))
      case .signedOut: return decide("go", go, failures: failures(.signedOut))
      case .noQuota: return decide("go", go, failures: failures(.noQuota))
      case .timeout: return decide("go", go, failures: failures(.timeout))
      case .failed: return decide("go", go, failures: failures(.failed))
      case .badAnswer: return decide("go", go, failures: failures(.badAnswer))
      case .editedAfterLabeling:
        return decide("go", catalog(entry("go", hash: "hash-go-2")), labels: labels(["hash-go": .work]))
      case .versionBump:
        var old = SkillLabelCache()
        old.labels["0/haiku/hash-go"] = .init(label: .work, reason: "x", model: "haiku", t: 1)
        return decide("go", go, labels: old)
      case .modelChange: return decide("go", go, labels: labels(["hash-go": .work], model: "opus"))
      case .safeLabel: return decide("go", go, labels: labels(["hash-go": .safe]))
      case .configSafe: return decide("go", go, labels: labels(["hash-go": .work]), settings: settings(safe: ["go"]))
      case .noHash:
        return decide(
          "go", catalog(CatalogEntry(name: "go", origin: .listing, path: nil, description: nil, hash: nil)),
          labels: labels(["hash-go": .work]))
      }
    }
  }

  // MARK: Bypass

  @Test func anArmedBypassForTheNameAllowsAWorkSkill() {
    #expect(decide("go", go, labels: goWork, bypass: .armed("go")) == .bypassed)
  }

  @Test func anArmedBypassForTheNameAllowsAConfigWorkSkill() {
    #expect(decide("go", go, settings: settings(work: ["go"]), bypass: .armed("go")) == .bypassed)
  }

  @Test func anArmedBypassForAnotherNameDoesNotCoverTheSkill() {
    let both = catalog(entry("go"), entry("deploy"))
    let work = labels(["hash-go": .work, "hash-deploy": .work])

    #expect(decide("deploy", both, labels: work, bypass: .armed("go")) == .blocked(by: .haiku))
  }

  @Test func anArmedBypassMatchesTheNameCaseSensitively() {
    #expect(decide("go", go, labels: goWork, bypass: .armed("GO")) == .blocked(by: .haiku))
  }

  /// A Run-here `/go` may call its own sub-skills until its turn ends.
  @Test func aTurnBypassAllowsEveryWorkSkill() {
    let both = catalog(entry("go"), entry("deploy"))
    let work = labels(["hash-go": .work, "hash-deploy": .work])

    #expect(decide("deploy", both, labels: work, bypass: .turn) == .bypassed)
    #expect(decide("code-review", both, settings: settings(work: ["code-review"]), bypass: .turn) == .bypassed)
  }

  @Test func noBypassBlocksTheSameSkill() {
    #expect(decide("go", go, labels: goWork, bypass: nil) == .blocked(by: .haiku))
  }

  // MARK: Bare plugin names

  @Test func aBareNameOfOnePluginWorkSkillIsBlocked() {
    let entries = catalog(entry("p:s", origin: .plugin))

    #expect(decide("s", entries, labels: labels(["hash-p:s": .work])) == .blocked(by: .haiku))
  }

  @Test func aBareNameOfAnUnlabeledPluginSkillIsUncheckedWithItsFailure() {
    let entries = catalog(entry("p:s", origin: .plugin))

    #expect(decide("s", entries, failures: [key("hash-p:s"): failure(.timeout)]) == .unchecked(failure(.timeout)))
  }

  @Test func aNonPluginEntryOfTheBareNameWins() {
    let entries = catalog(entry("s"), entry("p:s", origin: .plugin))
    let cache = labels(["hash-s": .safe, "hash-p:s": .work])

    #expect(decide("s", entries, labels: cache) == .allowed(by: .haiku))
  }

  @Test func aBareNameOfTwoPluginsStaysUnknown() {
    let entries = catalog(entry("p:s", origin: .plugin), entry("q:s", origin: .plugin))
    let cache = labels(["hash-p:s": .work, "hash-q:s": .work])

    #expect(decide("s", entries, labels: cache) == .unchecked(nil))
  }

  @Test func aConfigNameBeatsAPluginSkillOfTheSameBareName() {
    let entries = catalog(entry("p:s", origin: .plugin))

    #expect(
      decide("s", entries, labels: labels(["hash-p:s": .work]), settings: settings(safe: ["s"]))
        == .allowed(by: .config))
  }

  @Test func aConfigWorkNameOfThePluginSkillBlocksItsBareName() {
    let entries = catalog(entry("p:s", origin: .plugin))

    #expect(decide("s", entries, settings: settings(work: ["p:s"])) == .blocked(by: .config))
  }

  @Test func aBuiltInNameIsIgnoredEvenWithAPluginCommandOfThatName() {
    let entries = catalog(entry("p:clear", origin: .plugin))

    #expect(decide("clear", entries, labels: labels(["hash-p:clear": .work])) == .ignored)
  }

  // MARK: Row lines

  @Test func eachRowPrintsItsLabelNameOriginAndWhy() {
    #expect(
      ManagerSkillRow(name: "go", origin: .user, label: .work, by: .haiku, reason: "It runs.").line
        == "work  go  user  haiku: It runs.")
    #expect(ManagerSkillRow(name: "go", origin: .user, label: .work, by: .config).line == "work  go  user  config")
    #expect(ManagerSkillRow(name: "go", origin: .config, label: .safe, by: .config).line == "safe  go  config  config")
    #expect(ManagerSkillRow(name: "go", origin: .user, error: "boom", pending: true).line == "-  go  user  queued")
    #expect(ManagerSkillRow(name: "go", origin: .user, pending: true).line == "-  go  user  queued")
    #expect(ManagerSkillRow(name: "go", origin: .user, error: "boom").line == "-  go  user  unlabeled: boom")
    #expect(ManagerSkillRow(name: "go", origin: .user).line == "-  go  user  unlabeled")
  }

  // MARK: Parity with manager-skills

  /// The hook blocks a name exactly when its `manager-skills` row shows `work`, because both read one decision.
  @Test func decideBlocksExactlyTheRowsLabeledWork() {
    let entries = catalog(
      entry("go"), entry("notes"), entry("p:s", origin: .plugin), entry("code-review", origin: .listing),
      entry("forced", origin: .command), entry("pending"), entry("flaky"),
      CatalogEntry(name: "bare", origin: .listing, path: nil, description: nil, hash: nil))
    let cache = labels([
      "hash-go": .work, "hash-notes": .safe, "hash-p:s": .work, "hash-code-review": .work, "hash-forced": .work,
    ])
    let config = settings(work: ["cfg-only"], safe: ["forced"])
    let failures = [key("hash-flaky"): failure(.failed)]

    let rows = ManagerSkillRow.rows(entries, settings: config, labels: cache, failures: failures, queued: [])

    #expect(rows.count == entries.count + 1)
    for row in rows {
      let d = decide(row.name, entries, labels: cache, failures: failures, settings: config)
      #expect(blocks(d) == (row.label == .work), "\(row.name): row \(row.label?.rawValue ?? "-"), decide \(d)")
    }
  }

  // MARK: Reasons

  @Test func thePromptReasonIsTheTextOfD17() {
    let reason = ManagerSkillGate.promptReason(skill: "go", session: "swb_ab12c")

    #expect(
      reason
        == "Switchboard blocked /go in this Manager conversation. /go is a work skill, and a Manager rereads "
        + "everything it loads on every later turn. Start a session for it instead: send it again from the "
        + "conversation's Message Claude field in Switchboard (⇧⌘E) and pick Spawn a session with this, or run "
        + "sb spawn --repo <owner/name> --branch <branch> --prompt \"/go …\". To run it here once, pick Run here "
        + "anyway, or run sb send swb_ab12c --run-here \"/go …\" in a terminal. sb manager skills lists the labels.")
  }

  @Test func theToolReasonIsTheTextOfD17() {
    let reason = ManagerSkillGate.toolReason(skill: "go")

    #expect(
      reason
        == "Switchboard denied the go skill. It is a work skill, and this Manager conversation rereads everything "
        + "it loads on every later turn. Start a session for the work instead, with the spawn tool or sb new <repo> "
        + "--branch <branch> --prompt \"/go <args>\", and follow it with a wait. Don't load the skill's text "
        + "another way, such as by reading its SKILL.md.")
  }

  @Test func bothReasonsNameThePluginSkillThatTheyRefuse() {
    let prompt = ManagerSkillGate.promptReason(skill: "p:s", session: "swb_op001")
    let tool = ManagerSkillGate.toolReason(skill: "p:s")

    #expect(prompt.hasPrefix("Switchboard blocked /p:s in this Manager conversation. /p:s is a work skill"))
    #expect(prompt.contains("sb send swb_op001 --run-here \"/p:s …\""))
    #expect(tool.hasPrefix("Switchboard denied the p:s skill."))
    #expect(tool.contains("--prompt \"/p:s <args>\""))
  }

  /// The reasons take only the name, so neither the skill's file nor the classifier's reason can reach them.
  @Test func neitherReasonHoldsTheClassifiersReason() {
    let haiku = goWork.labels.values.first!.reason

    #expect(!ManagerSkillGate.promptReason(skill: "go", session: "c").contains(haiku))
    #expect(!ManagerSkillGate.toolReason(skill: "go").contains(haiku))
  }
}
