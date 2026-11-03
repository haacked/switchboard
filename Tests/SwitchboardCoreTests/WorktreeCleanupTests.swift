import Foundation
import Testing

@testable import SwitchboardCore

private func prEvent(_ t: Int64, _ pr: PullRequest) throws -> Event {
  event("pr", t, ["pr": try JSON(encoding: pr)])
}

/// A `worktree` event. A nil `cleanup` leaves the key out, and `.null` says every check passed.
private func countEvent(_ t: Int64, dirty: Int?, gone: Bool = false, cleanup: JSON? = nil) -> Event {
  var fields: [String: JSON] = ["dirty": dirty.map { .number(Double($0)) } ?? .null, "gone": .bool(gone)]
  if let cleanup { fields["cleanup"] = cleanup }
  return event("worktree", t, fields)
}

private func cleanupEvent(_ t: Int64) -> Event {
  event("cleanup", t, ["worktree": "/tmp/worktrees/repo/feature", "branch": "feature"])
}

private let runningTurn = [event("UserPromptSubmit", 9, ["prompt": "keep going"])]
private let ready = CleanupStatus(state: .ready)

/// The facts of a session whose turn ended, whose PR was open, and whose PR then finished with
/// `state`. The poller records its count of the folder before the finished PR's `pr` event, so
/// `countFirst` puts the count between the open and the finished PR. Otherwise it comes after both.
private func cleanupFacts(
  _ state: PRState = .merged, dirty: Int? = 0, cleanup: JSON? = .null, countFirst: Bool = true, then: [Event] = []
) throws -> SessionFacts {
  var events = [
    event("UserPromptSubmit", 0, ["prompt": "go"]), event("Stop", 1, ["last_assistant_message": "Pushed."]),
    try prEvent(2, samplePR()),
  ]
  let count = countEvent(3, dirty: dirty, cleanup: cleanup)
  let finished = try prEvent(4, samplePR(state: state))
  events += countFirst ? [count, finished] : [finished, count]
  return facts(events + then)
}

private func verdict(_ f: SessionFacts) -> Verdict { Attention.evaluate(session(), f, now: 20) }

@Suite struct WorktreeCleanupTests {
  @Suite struct Facts {
    @Test(arguments: [true, false])
    func nullCleanupInTheCountIsReady(_ countFirst: Bool) throws {
      let f = try cleanupFacts(cleanup: .null, countFirst: countFirst)

      #expect(f.cleanup == ready)
    }

    @Test(arguments: [true, false])
    func messageInTheCountIsBlockedWithThatReason(_ countFirst: Bool) throws {
      let f = try cleanupFacts(cleanup: "the worktree is locked", countFirst: countFirst)

      #expect(f.cleanup == CleanupStatus(state: .blocked, reason: "the worktree is locked"))
    }

    @Test(arguments: [true, false])
    func countWithoutTheCleanupKeyLeavesCleanupNil(_ countFirst: Bool) throws {
      let f = try cleanupFacts(cleanup: nil, countFirst: countFirst)

      #expect(f.cleanup == nil)
    }

    @Test(arguments: [(JSON.null, true), (JSON.null, false), ("not merged", true), ("not merged", false)])
    func closedPRLeavesCleanupNil(_ cleanup: JSON, _ countFirst: Bool) throws {
      let f = try cleanupFacts(.closed, cleanup: cleanup, countFirst: countFirst)

      #expect(f.cleanup == nil)
    }

    @Test(arguments: [true, false])
    func openPRLeavesCleanupNil(_ countFirst: Bool) throws {
      let f = try cleanupFacts(.open, cleanup: .null, countFirst: countFirst)

      #expect(f.cleanup == nil)
    }

    @Test(arguments: [(JSON.null, true), (JSON.null, false), ("uncommitted", true), ("uncommitted", false)])
    func dirtyCountLeavesCleanupNil(_ cleanup: JSON, _ countFirst: Bool) throws {
      let f = try cleanupFacts(dirty: 2, cleanup: cleanup, countFirst: countFirst)

      #expect(f.cleanup == nil)
    }

    @Test func prWithoutACountLeavesCleanupNil() throws {
      let f = facts([try prEvent(1, samplePR(state: .merged))])

      #expect(f.cleanup == nil)
    }

    @Test func laterCountWithUncommittedFilesClearsReady() throws {
      let f = try cleanupFacts(then: [countEvent(5, dirty: 1)])

      #expect(f.cleanup == nil)
    }

    @Test func laterCountWithAMessageReplacesReady() throws {
      let f = try cleanupFacts(then: [countEvent(5, dirty: 0, cleanup: "not in its merged PR")])

      #expect(f.cleanup == CleanupStatus(state: .blocked, reason: "not in its merged PR"))
    }

    @Test func laterCountWithANullCleanupReplacesBlocked() throws {
      let f = try cleanupFacts(cleanup: "not in its merged PR", then: [countEvent(5, dirty: 0, cleanup: .null)])

      #expect(f.cleanup == ready)
    }

    @Test func goneFolderClearsReady() throws {
      let f = try cleanupFacts(then: [countEvent(5, dirty: nil, gone: true)])

      #expect(f.cleanup == nil)
    }

    @Test func cleanupEventMarksTheWorktreeRemoved() throws {
      let f = try cleanupFacts(then: [cleanupEvent(5)])

      #expect(f.cleanup?.state == .removed)
    }

    @Test(arguments: [
      countEvent(6, dirty: 0, cleanup: .null), countEvent(6, dirty: nil, gone: true), countEvent(6, dirty: 0),
    ])
    func laterCountKeepsTheWorktreeRemoved(_ count: Event) throws {
      let f = try cleanupFacts(then: [cleanupEvent(5), count])

      #expect(f.cleanup?.state == .removed)
    }

    @Test func cleanupEventIsAnObservedKind() {
      #expect(SessionFacts.observedKinds.contains("cleanup"))
    }
  }

  @Suite struct Verdicts {
    @Test(arguments: [true, false])
    func readyCleanupIsDone(_ countFirst: Bool) throws {
      let f = try cleanupFacts(cleanup: .null, countFirst: countFirst)

      #expect(verdict(f) == Verdict(state: .done, reason: "#42 merged; ready for `sb cleanup`"))
    }

    @Test func readyCleanupWhileATurnRunsSaysOnceItStops() throws {
      let f = try cleanupFacts(cleanup: .null, then: runningTurn)

      #expect(verdict(f) == Verdict(state: .done, reason: "#42 merged; ready for `sb cleanup` once it stops"))
    }

    @Test func blockedCleanupKeepsTheArchiveReason() throws {
      let f = try cleanupFacts(cleanup: "the worktree is locked")

      #expect(verdict(f) == Verdict(state: .done, reason: "#42 merged; archive the worktree"))
    }

    @Test func blockedCleanupWhileATurnRunsKeepsTheArchiveReason() throws {
      let f = try cleanupFacts(cleanup: "a turn is running", then: runningTurn)

      #expect(verdict(f) == Verdict(state: .done, reason: "#42 merged; archive the worktree once it stops"))
    }

    @Test func countWithoutTheCleanupKeyKeepsTheArchiveReason() throws {
      let f = try cleanupFacts(cleanup: nil)

      #expect(verdict(f) == Verdict(state: .done, reason: "#42 merged; archive the worktree"))
    }

    @Test(arguments: [JSON.null, "not merged"])
    func closedPRNeverOffersCleanup(_ cleanup: JSON) throws {
      let f = try cleanupFacts(.closed, cleanup: cleanup)

      #expect(verdict(f) == Verdict(state: .done, reason: "#42 closed; archive the worktree"))
    }

    @Test func dirtyFolderNeedsYouEvenWhenTheCountSaysReady() throws {
      let f = try cleanupFacts(dirty: 2, cleanup: .null)

      #expect(
        verdict(f) == Verdict(state: .needsYou, reason: "#42 merged; commit or discard the uncommitted changes"))
    }

    @Test func uncommittedFilesAfterReadyNeedYou() throws {
      let f = try cleanupFacts(then: [countEvent(5, dirty: 1)])

      #expect(
        verdict(f) == Verdict(state: .needsYou, reason: "#42 merged; commit or discard the uncommitted changes"))
    }

    @Test func removedWorktreeIsDone() throws {
      let f = try cleanupFacts(then: [cleanupEvent(5)])

      #expect(verdict(f) == Verdict(state: .done, reason: "#42 merged; worktree and branch removed"))
    }

    @Test func removedWinsOverAFolderGoneAfterTheCleanup() throws {
      let f = try cleanupFacts(then: [cleanupEvent(5), countEvent(6, dirty: nil, gone: true)])

      #expect(verdict(f) == Verdict(state: .done, reason: "#42 merged; worktree and branch removed"))
    }

    @Test func removedWinsOverAFolderGoneBeforeTheCleanup() throws {
      let f = try cleanupFacts(then: [countEvent(5, dirty: nil, gone: true), cleanupEvent(6)])

      #expect(verdict(f) == Verdict(state: .done, reason: "#42 merged; worktree and branch removed"))
    }

    @Test func removedWinsOverALaterReadyCount() throws {
      let f = try cleanupFacts(then: [cleanupEvent(5), countEvent(6, dirty: 0, cleanup: .null)])

      #expect(verdict(f) == Verdict(state: .done, reason: "#42 merged; worktree and branch removed"))
    }

    @Test func folderGoneWithoutACleanupKeepsTheGoneReason() throws {
      let f = try cleanupFacts(then: [countEvent(5, dirty: nil, gone: true)])

      #expect(verdict(f) == Verdict(state: .done, reason: "#42 merged; its folder is gone"))
    }
  }

  @Suite struct Coding {
    @Test(arguments: [
      (CleanupStatus.State.ready, "ready"), (.blocked, "blocked"), (.removed, "removed"),
    ])
    func stateEncodesAsItsName(_ state: CleanupStatus.State, _ name: String) throws {
      #expect(try JSON(encoding: CleanupStatus(state: state))["state"] == .string(name))
    }

    @Test func blockedStatusEncodesItsReason() throws {
      let json = try JSON(encoding: CleanupStatus(state: .blocked, reason: "not in its merged PR"))

      #expect(json["reason"] == "not in its merged PR")
    }

    @Test func statusDecodesWithoutAReason() throws {
      let json: JSON = ["state": "removed"]
      let status = try JSONCoding.convert(json, to: CleanupStatus.self)

      #expect(status == CleanupStatus(state: .removed))
    }

    @Test func summaryCarriesCleanupUnderItsKey() throws {
      var summary = SessionSummary(
        id: "s1", name: "test", cwd: "/tmp", repo: "/tmp/repo", branch: "feature", claudeSessionId: "uuid",
        state: .done, reason: "#42 merged; ready for `sb cleanup`", since: 0, lastActivity: 0, live: false,
        claudePid: nil, attached: false, lastReply: nil, waits: [], notes: [])
      summary.cleanup = CleanupStatus(state: .blocked, reason: "the worktree is locked")

      let json = try JSON(encoding: summary)

      #expect(json["cleanup"] == ["state": "blocked", "reason": "the worktree is locked"])
    }
  }
}

@Suite struct RebuildableIgnoredPathTests {
  @Test(arguments: [
    "node_modules/", "frontend/node_modules/", ".venv/", "rust/target/", "pkg/__pycache__/", "pkg/c.pyc", ".DS_Store",
    ".build/",
  ])
  func buildOutputIsRebuildable(_ path: String) {
    #expect(BuildOutput.contains(path))
  }

  @Test(arguments: [".env", "notes/", "frontend/.env.local", "my-node_modules/", "target.txt", ".idea/", ""])
  func otherIgnoredPathsAreNot(_ path: String) {
    #expect(!BuildOutput.contains(path))
  }
}
