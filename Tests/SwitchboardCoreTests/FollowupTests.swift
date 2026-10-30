import Foundation
import Testing

@testable import SwitchboardCore

func followup(_ f: Followup, done: Bool = false) -> Session {
  var s = Session(id: "s1", name: "a follow-up", cwd: "", claudeSessionId: "uuid", created: 0)
  s.followup = f
  s.done = done
  return s
}

@Suite struct FollowupItems {
  let file = """
    # Followups

    Intro text with - [ ] in it.

    ## Open

    - [ ] 2026-10-24 · [haacked/dotfiles · haacked/standup-archive-gate] Move the lookups into one script. More text.
    - [x] 2026-10-22 · [PostHog/posthog · haacked/done] A closed item.
    - [-] 2026-10-21 · [PostHog/posthog · haacked/dropped] A dropped item.
    - [ ] 2026-09-28 · [haacked/docket] Archived rows stay visible ([PR #21](https://github.com/haacked/docket/pull/21))
    - [ ] 2026-08-14 · [no-repo] Check the dashboards.
    - [ ] Should we have code protections on the flag service

    ## Archive

    - [ ] 2026-01-01 · [PostHog/posthog · old] An open line under Archive.
    """

  @Test func readsTheOpenItemsOnly() {
    let items = Followup.openItems(file, zone: utc)
    #expect(
      items.map(\.prompt) == [
        "Move the lookups into one script. More text.",
        "Archived rows stay visible ([PR #21](https://github.com/haacked/docket/pull/21))",
        "Check the dashboards.",
        "Should we have code protections on the flag service",
      ])
    #expect(items.map(\.repository) == ["haacked/dotfiles", "haacked/docket", nil, nil])
    #expect(items.map(\.sourceBranch) == ["haacked/standup-archive-gate", nil, nil, nil])
    #expect(items[0].added == 1_792_800_000_000)
    #expect(items[3].added == nil)
    #expect(
      items[0].key
        == "2026-10-24 · [haacked/dotfiles · haacked/standup-archive-gate] Move the lookups into one script. More text."
    )
    #expect(items[3].key == "Should we have code protections on the flag service")
  }

  @Test func readsADateWithoutAContext() {
    let item = Followup.openItems("## Open\n- [ ] 2026-10-24 · Check the logs.", zone: utc)[0]
    #expect(item.prompt == "Check the logs.")
    #expect(item.added == 1_792_800_000_000)
    #expect(item.repository == nil)
  }

  @Test func readsAFileWithWindowsLineEndings() {
    let items = Followup.openItems(
      "## Open\r\n- [ ] 2026-10-24 · [a/b] One.\r\n- [ ] Two.\r\n## Archive\r\n", zone: utc)
    #expect(items.map(\.prompt) == ["One.", "Two."])
  }

  @Test func aDateInOtherDigitsLeavesTheLineUndated() {
    let items = Followup.openItems("## Open\n- [ ] ２０２６-１０-２４ · [a/b] x\n- [ ] ٢٠٢٦-١٠-٢٤ · [a/b] y", zone: utc)
    #expect(items.map(\.added) == [nil, nil])
    #expect(items.map(\.repository) == [nil, nil])
  }

  @Test func aFileWithoutAnOpenSectionHasNoItems() {
    #expect(Followup.openItems("# Followups\n\n- [ ] 2026-10-24 · [a/b] text", zone: utc).isEmpty)
  }
}

@Suite struct FollowupText {
  @Test(arguments: [
    ("Move the lookups into one script. The gate checks more.", "Move the lookups into one script"),
    ("Is the cache safe? It reads twice.", "Is the cache safe?"),
    (
      "Check p99 after the rollout ([PR #37211](https://github.com/PostHog/posthog/pull/37211), `src/lib.rs:412`)",
      "Check p99 after the rollout (PR #37211, `src/lib.rs:412`)"
    ),
    (String(repeating: "word ", count: 30), String(repeating: "word ", count: 13) + "word…"),
    ("Line one\nline two.", "Line one line two"),
  ])
  func titles(_ prompt: String, _ title: String) {
    #expect(Followup.title(prompt) == title)
  }

  @Test func firstLinks() {
    #expect(
      Followup.firstLink("See ([PR #21](https://github.com/haacked/docket/pull/21)) and https://x.dev")
        == "https://github.com/haacked/docket/pull/21")
    #expect(
      Followup.firstLink("Read https://claude.ai/artifact/TqWK5kL5. Then decide.")
        == "https://claude.ai/artifact/TqWK5kL5")
    #expect(Followup.firstLink("no link here") == nil)
  }

  @Test func slugs() {
    #expect(Followup.slug("Fix the flaky `foo_test.py` test!") == "fix-the-flaky-foo-test-py-test")
    #expect(
      Followup.slug("Move the standup's mechanical PR lookups into one gather script")
        == "move-the-standup-s-mechanical-pr-lookups-into-one")
    #expect(
      Followup.slug("Move the standups mechanical PR lookups into one gathering script")
        == "move-the-standups-mechanical-pr-lookups-into-one")
    #expect(Followup.slug("…") == "")
  }

  @Test(arguments: [
    ("git@github.com:PostHog/posthog.git", "PostHog/posthog"),
    ("https://github.com/PostHog/posthog.git", "PostHog/posthog"),
    ("https://github.com/haacked/docket", "haacked/docket"),
    ("ssh://git@github.com/haacked/dotfiles.git", "haacked/dotfiles"),
    ("https://token@github.com/a/b/", "a/b"),
  ])
  func repositoriesFromRemotes(_ remote: String, _ repository: String) {
    #expect(Followup.repository(remote: remote) == repository)
  }

  @Test(arguments: [
    "https://gitlab.com/a/b.git", "https://github.com.evil.dev/a/b", "https://notgithub.com/a/b",
    "https://github.com/a", "/Users/me/repo", "https://evil.dev/github.com/acme/widgets.git",
    "https://git.corp/mirrors/github.com/acme/widgets", "/Users/me/src/github.com/acme/widgets",
    "git@evil.dev:github.com/acme/widgets.git", "https://github.com/../..", "https://github.com/a/b/c",
    "https://evil.dev#@github.com/a/b", "https://evil.dev?@github.com/a/b", "https://evil.dev\\@github.com/a/b",
  ])
  func remotesElsewhereHaveNoRepository(_ remote: String) {
    #expect(Followup.repository(remote: remote) == nil)
  }

  @Test func pullRequestsCompareRepositoriesWithoutCase() {
    let pr = Wait.PullRequest(repository: "PostHog/posthog", number: 5)
    #expect(pr.same(as: Wait.PullRequest(repository: "posthog/PostHog", number: 5)))
    #expect(!pr.same(as: Wait.PullRequest(repository: "PostHog/posthog", number: 6)))
  }
}

@Suite struct FollowupAttention {
  @Test func aManualFollowupIsNotStartedWithItsRepository() {
    let s = followup(Followup(prompt: "do it", repository: "PostHog/posthog"))
    #expect(Attention.evaluate(s, SessionFacts(), now: 1) == Verdict(state: .notStarted, reason: "PostHog/posthog"))
    #expect(
      Attention.evaluate(followup(Followup(prompt: "x")), SessionFacts(), now: 1).reason == "no repository")
  }

  @Test func aPendingTriggerShowsWhatItWaitsFor() {
    let pr = Wait.PullRequest(repository: "acme/widgets", number: 12)
    let s = followup(Followup(prompt: "x", repository: "acme/widgets", trigger: .merge(pr)))
    #expect(
      Attention.evaluate(s, SessionFacts(), now: 1)
        == Verdict(state: .notStarted, reason: "acme/widgets · ready when acme/widgets#12 merges"))
    let at = Wait.parseTime("2026-10-30 09:00", now: 0)!
    let dated = followup(Followup(prompt: "x", repository: "a/b", trigger: .date(at)))
    #expect(Attention.evaluate(dated, SessionFacts(), now: 1).reason == "a/b · ready at 2026-10-30 09:00")
  }

  @Test func aFiredTriggerNeedsYou() {
    var f = Followup(prompt: "x", trigger: .merge(Wait.PullRequest(repository: "acme/widgets", number: 12)))
    f.ready = 5
    #expect(
      Attention.evaluate(followup(f), SessionFacts(), now: 6)
        == Verdict(state: .needsYou, reason: "ready to start: acme/widgets#12 merged"))
    let at = Wait.parseTime("2026-10-30 09:00", now: 0)!
    var dated = Followup(prompt: "x", trigger: .date(at))
    dated.ready = at
    #expect(
      Attention.evaluate(followup(dated), SessionFacts(), now: at).reason == "ready to start: 2026-10-30 09:00 passed")
  }

  @Test func aFollowupMarkedDoneIsDone() {
    #expect(Attention.evaluate(followup(Followup(prompt: "x"), done: true), SessionFacts(), now: 1).state == .done)
  }

  @Test func aStartedFollowupFollowsTheSessionRules() {
    var f = Followup(prompt: "x")
    f.started = 1
    let s = followup(f)
    #expect(!s.waitsToStart)
    #expect(
      Attention.evaluate(s, SessionFacts(), now: 2) == Verdict(state: .needsYou, reason: "give it a first prompt"))
  }

  @Test func notStartedIsTheLastColumn() {
    #expect(AttentionState.allCases.last == .notStarted)
    #expect(AttentionState.notStarted.rawValue == "not_started")
  }
}

@Suite struct FollowupStore {
  @Test func importedLinesOutliveTheirSession() throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    var s = followup(Followup(prompt: "x", repository: "a/b", trigger: .date(9)))
    s.parent = "s0"
    do {
      let store = try Store(path: "\(dir)/sb.db")
      try store.save(s)
      try store.recordImport("2026-10-24 · [a/b] x")
      try store.recordImport("2026-10-24 · [a/b] x")
    }
    let store = try Store(path: "\(dir)/sb.db")
    #expect(try store.sessions() == [s])
    try store.delete(session: "s1")
    #expect(try store.importedLines() == ["2026-10-24 · [a/b] x"])
  }

  @Test func repoSettingsHaveDefaults() throws {
    let c = try JSONCoding.decode(Config.self, from: #"{"repos": {"haacked/dotfiles": "~/.dotfiles"}}"#)
    #expect(c.repos == ["haacked/dotfiles": "~/.dotfiles"])
    #expect(c.repoRoots == ["~/dev"])
    #expect(c.branchPrefix == "")
  }
}
