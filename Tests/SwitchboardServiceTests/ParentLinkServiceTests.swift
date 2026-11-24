import Foundation
import Testing

@testable import SwitchboardCore
@testable import SwitchboardService

// A `try` inside `#expect` fails to compile in these closures. Each check therefore binds the thrown value first.

// MARK: Sessions

/// A started work session in a folder, so it runs claude.
private func work(_ id: String, name: String? = nil, parent: String? = nil, host: String? = nil, group: String? = nil)
  -> Session
{
  var s = Session(id: id, name: name ?? id, cwd: "/srv/repo", claudeSessionId: "u-\(id)", created: 5)
  s.started = true
  s.parent = parent
  s.host = host
  s.group = group
  return s
}

private func managerConversation(_ id: String, name: String? = nil) -> Session {
  var s = work(id, name: name)
  s.manager = true
  return s
}

private func groupChat(_ id: String, of group: String) -> Session {
  var s = work(id)
  s.chat = group
  return s
}

private func operatorSession(_ id: String) -> Session {
  var s = work(id)
  s.manager = true
  s.isOperator = true
  return s
}

/// A follow-up that `followup start` started. It has a folder and runs claude, and it keeps `followup` set.
private func startedFollowupSession(_ id: String, parent: String?) -> Session {
  var s = work(id, parent: parent)
  s.followup = Followup(prompt: "p")
  s.followup?.started = 1
  return s
}

/// A follow-up that has not started, which has no folder and no claude.
private func unstartedFollowupSession(_ id: String, name: String? = nil, parent: String?) -> Session {
  var s = work(id, name: name, parent: parent)
  s.cwd = ""
  s.started = false
  s.followup = Followup(prompt: "p")
  return s
}

/// A docket row, which has no folder and no claude.
private func docketRow(_ id: String, name: String? = nil, parent: String?) -> Session {
  var s = work(id, name: name, parent: parent)
  s.cwd = ""
  s.docket = DocketSession(pullRequest: "o/r#1", url: "https://github.com/o/r/pull/1")
  return s
}

// MARK: The service

private let miniHost: [String: JSON] = ["mini": ["kind": "ssh", "destination": .string(LinkBench.destination)]]

/// mini's `repos` name `Secret/Listed`, so a PR in `secret/vault` is one that mini may not see.
private let listedHosts: [String: JSON] = [
  "mini": ["kind": "ssh", "destination": .string(LinkBench.destination), "repos": ["Secret/Listed": "~/listed"]]
]

/// A service that holds `sessions`, in its entries and in its store. No link connects unless a request waits for its
/// host.
private func withParents(
  _ sessions: [Session], hosts: [String: JSON] = miniHost, _ body: (Service) throws -> Void
) throws {
  // A request that a missing guard lets through runs no claude or tmux on this Mac.
  let config: [String: JSON] = ["claude": "/usr/bin/true", "tmux": "/usr/bin/true"]
  try withHostService(hosts: hosts, config: config) { service, _ in
    try service.queue.sync {
      for s in sessions {
        service.entries[s.id] = Service.Entry(session: s)
        try service.store.save(s)
      }
    }
    try body(service)
  }
}

/// What a `parent` request can change: the log, each session's record in memory and in the store, and the notice
/// state.
private struct ParentLinkState: Equatable {
  var events: [Event]
  var sessions: [String: Session]
  var stored: [Session]
  var marks: [String: ChildMark]
}

extension Service {
  fileprivate func parent(_ args: [String: JSON]) -> Response {
    handle(Request(op: "parent", args: .object(args)))
  }

  fileprivate func linkState() throws -> ParentLinkState {
    try queue.sync {
      ParentLinkState(
        events: try store.events(), sessions: entries.mapValues(\.session),
        stored: try store.sessions().sorted { $0.id < $1.id }, marks: parentNotices.marks)
    }
  }

  fileprivate func rawParent(of id: String) -> String? { queue.sync { entries[id]?.session.parent } }

  fileprivate func storedParent(of id: String) throws -> String? {
    let stored = try queue.sync { try store.sessions().first { $0.id == id } }
    return try #require(stored, "the store has no \(id)").parent
  }

  fileprivate func linkEvents(_ id: String, _ kind: String) throws -> [Event] {
    try queue.sync { try store.events(session: id, kinds: [kind]) }
  }

  /// The kinds of the session's `unlinked` and `linked` events, oldest first.
  fileprivate func linkKinds(_ id: String) throws -> [String] {
    try queue.sync { try store.events(session: id) }.map(\.kind).filter { $0 == "unlinked" || $0 == "linked" }
  }

  /// Records a `pr` event for the session, as the poller does, after a first prompt and a reply. A child with no
  /// prompt and no reply shows `.fresh` to its parent, so it would queue nothing.
  fileprivate func openPR(_ id: String, number: Int = 77, repo: String = "secret/listed") throws {
    let pr = try JSON(
      encoding: PullRequest(
        id: "PR_\(number)", number: number, url: "https://github.com/\(repo)/pull/\(number)", repo: repo,
        title: "Title \(number)", reviewDecision: .approved, checks: "pass"))
    queue.sync {
      entries[id]?.facts.prompts = 1
      entries[id]?.facts.lastReply = "Done."
      _ = record(id, "pr", ["pr": pr, "comments": []])
    }
  }

  /// The child lines of the digest that `parent` gets with its next prompt. Reading it counts the lines as heard.
  fileprivate func digestLines(for parent: String) -> [String] {
    queue.sync {
      (digest(parent, now: nowMs()) ?? "").split(separator: "\n").map(String.init).filter { $0.hasPrefix("- ") }
    }
  }
}

// MARK: forgetChild (Stage 1)

@Suite struct ParentNoticeForgetChildTests {
  @Test(.timeLimit(.minutes(1)))
  func forgetChildDropsOnlyThatChildsMark() throws {
    try withParents([]) { service in
      let kept = ChildMark(state: .needsYou, pr: 2)
      let marks = service.queue.sync { () -> [String: ChildMark] in
        service.parentNotices.marks = ["kid": ChildMark(state: .readyToMerge, pr: 1), "sibling": kept]
        service.forgetChild("kid")
        return service.parentNotices.marks
      }

      #expect(marks == ["sibling": kept])
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func forgetChildOfAnUnknownIdChangesNothing() throws {
    try withParents([]) { service in
      let marks: [String: ChildMark] = ["kid": ChildMark(state: .needsYou, pr: nil)]
      let after = service.queue.sync { () -> [String: ChildMark] in
        service.parentNotices.marks = marks
        service.forgetChild("nosuch")
        return service.parentNotices.marks
      }

      #expect(after == marks)
    }
  }
}

// MARK: Clear

/// `parent` with `clear` unlinks a session from its parent: the field, the store, and an `unlinked` event on each end.
@Suite struct ParentLinkClearTests {
  static let family = [work("boss", name: "planner"), work("kid", parent: "boss")]

  @Test(.timeLimit(.minutes(1)))
  func clearSetsTheParentToNilInTheEntries() throws {
    try withParents(Self.family) { service in
      let answer = service.parent(["session": "kid", "clear": true])

      #expect(answer.ok, "\(answer.error ?? "")")
      #expect(service.rawParent(of: "kid") == nil)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func clearSetsTheParentToNilInTheStore() throws {
    try withParents(Self.family) { service in
      _ = service.parent(["session": "kid", "clear": true])

      let actual1 = try service.storedParent(of: "kid")
      #expect(actual1 == nil)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func clearReturnsTheChildsSummaryWithoutAParentKey() throws {
    try withParents(Self.family) { service in
      let answer = service.parent(["session": "kid", "clear": true])

      let result = try #require(answer.result)
      #expect(result["id"] == "kid")
      #expect(result["parent"] == nil, "\(result)")
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func clearRecordsUnlinkedOnTheChildWithTheOldParentAndBy() throws {
    try withParents(Self.family) { service in
      _ = service.parent(["session": "kid", "clear": true])

      let actual2 = try service.linkEvents("kid", "unlinked").map(\.data)
      #expect(actual2 == [["parent": "boss", "by": "you"]])
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func clearRecordsUnlinkedOnTheOldParentWithTheChildAndBy() throws {
    try withParents(Self.family) { service in
      _ = service.parent(["session": "kid", "clear": true])

      let actual3 = try service.linkEvents("boss", "unlinked").map(\.data)
      #expect(actual3 == [["child": "kid", "by": "you"]])
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func clearByClaudeRecordsClaudeOnBothEnds() throws {
    try withParents(Self.family) { service in
      _ = service.parent(["session": "kid", "clear": true, "by": "claude"])

      let actual4 = try service.linkEvents("kid", "unlinked").map { $0.data["by"] }
      #expect(actual4 == ["claude"])
      let actual5 = try service.linkEvents("boss", "unlinked").map { $0.data["by"] }
      #expect(actual5 == ["claude"])
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func clearRecordsNoLinkedEvent() throws {
    try withParents(Self.family) { service in
      _ = service.parent(["session": "kid", "clear": true])

      let check6 = try service.linkEvents("kid", "linked").isEmpty
      #expect(check6)
      let check7 = try service.linkEvents("boss", "linked").isEmpty
      #expect(check7)
    }
  }

  /// Group, account, host, waits, notes, and every other field stay as they were.
  @Test(.timeLimit(.minutes(1)))
  func clearChangesNoOtherFieldOfTheChild() throws {
    var kid = work("kid", parent: "boss", host: nil, group: "g1")
    kid.claudeConfigDir = "/Users/me/.claude-work"
    kid.placedByHand = false
    kid.notes = [Note(id: "n1", text: "stacked on #1190", by: .you, t: 1)]
    kid.highlighted = true
    try withParents([work("boss"), kid]) { service in
      _ = service.parent(["session": "kid", "clear": true])

      var expected = kid
      expected.parent = nil
      #expect(service.queue.sync { service.entries["kid"]?.session } == expected)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func clearChangesNothingOnTheOldParent() throws {
    try withParents(Self.family) { service in
      let before = service.queue.sync { service.entries["boss"]?.session }

      _ = service.parent(["session": "kid", "clear": true])

      #expect(service.queue.sync { service.entries["boss"]?.session } == before)
    }
  }

  /// A parent that sbd removed gets no event.
  @Test(.timeLimit(.minutes(1)))
  func clearWhenTheParentWasRemovedRecordsOnlyTheChildsEvent() throws {
    try withParents([work("kid", parent: "gone")]) { service in
      let answer = service.parent(["session": "kid", "clear": true])

      #expect(answer.ok, "\(answer.error ?? "")")
      #expect(service.rawParent(of: "kid") == nil)
      let actual8 = try service.linkEvents("kid", "unlinked").map(\.data)
      #expect(actual8 == [["parent": "gone", "by": "you"]])
      let check9 = try service.queue.sync { try service.store.events(session: "gone") }.isEmpty
      #expect(check9)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func clearFromTheCurrentParentIsAccepted() throws {
    try withParents([work("boss"), work("kid", parent: "boss")]) { service in
      let answer = service.parent(["session": "kid", "clear": true, "from": "boss"])

      #expect(answer.ok, "\(answer.error ?? "")")
      #expect(service.rawParent(of: "kid") == nil)
    }
  }

  @Test(.timeLimit(.minutes(1)), arguments: ["kid", "kidname", "ki"])
  func clearFindsTheChildByIdPrefixOrName(_ ref: String) throws {
    try withParents([work("boss"), work("kid", name: "kidname", parent: "boss")]) { service in
      let answer = service.parent(["session": .string(ref), "clear": true])

      #expect(answer.ok, "\(answer.error ?? "")")
      #expect(service.rawParent(of: "kid") == nil)
    }
  }
}

// MARK: Refusals that change nothing

/// Every refusal fails with its text and leaves the store, the log, and the notice state as they were.
@Suite struct ParentLinkRefusalTests {
  /// Runs the request on a service that holds `sessions` and returns its error. It records an issue when the request
  /// succeeds or changes anything.
  private func refusal(_ sessions: [Session], _ args: [String: JSON]) throws -> String {
    var error = ""
    try withParents(sessions) { service in
      let before = try service.linkState()

      let answer = service.parent(args)

      #expect(!answer.ok, "the request succeeded")
      let actual10 = try service.linkState()
      #expect(actual10 == before, "the refused request changed something")
      error = answer.error ?? ""
    }
    return error
  }

  @Test(.timeLimit(.minutes(1)))
  func clearOfASessionWithNoParentIsRefused() throws {
    let error = try refusal([work("boss"), work("kid", name: "kidname")], ["session": "kid", "clear": true])

    #expect(error.contains("kidname has no parent"), "\(error)")
  }

  @Test(.timeLimit(.minutes(1)))
  func clearOfAStartedFollowupIsRefused() throws {
    var f = startedFollowupSession("kid", parent: "boss")
    f.name = "kidname"
    let error = try refusal([work("boss"), f], ["session": "kid", "clear": true])

    #expect(error.contains("kidname is a follow-up, and its parent is the session that captured it"), "\(error)")
  }

  @Test(.timeLimit(.minutes(1)))
  func clearOfAnUnstartedFollowupIsRefused() throws {
    let error = try refusal(
      [work("boss"), unstartedFollowupSession("kid", name: "kidname", parent: "boss")],
      ["session": "kid", "clear": true])

    #expect(error.contains("kidname is a follow-up, and its parent is the session that captured it"), "\(error)")
  }

  @Test(.timeLimit(.minutes(1)))
  func setOnAFollowupIsRefused() throws {
    let error = try refusal(
      [work("boss"), work("other"), startedFollowupSession("kid", parent: "boss")],
      ["session": "kid", "parent": "other"])

    #expect(error.contains("is a follow-up"), "\(error)")
  }

  @Test(
    .timeLimit(.minutes(1)),
    arguments: [
      ["session": "kid", "parent": "boss", "clear": true], ["session": "kid"],
      ["session": "kid", "clear": false],
    ] as [[String: JSON]])
  func aRequestWithBothOrNeitherOfParentAndClearIsRefused(_ args: [String: JSON]) throws {
    let error = try refusal([work("boss"), work("other"), work("kid", parent: "other")], args)

    #expect(error.contains("parent needs a parent or clear, not both"), "\(error)")
  }

  @Test(.timeLimit(.minutes(1)))
  func aRequestThatNamesNoSessionIsRefused() throws {
    let error = try refusal([work("boss")], ["clear": true])

    #expect(!error.isEmpty)
  }

  @Test(.timeLimit(.minutes(1)))
  func aRequestForAnUnknownSessionIsRefused() throws {
    let error = try refusal([work("boss")], ["session": "nosuch", "clear": true])

    #expect(!error.isEmpty)
  }

  // MARK: The child can't change its own parent

  @Test(
    .timeLimit(.minutes(1)),
    arguments: [
      ["session": "kid", "clear": true, "caller": "kid"], ["session": "kid", "clear": true, "caller": "kidname"],
      ["session": "kidname", "clear": true, "caller": "kid"], ["session": "kid", "parent": "other", "caller": "kid"],
      ["session": "ki", "parent": "other", "caller": "kidname"],
    ] as [[String: JSON]])
  func theChildCantChangeItsOwnParent(_ args: [String: JSON]) throws {
    let error = try refusal([work("boss"), work("other"), work("kid", name: "kidname", parent: "boss")], args)

    #expect(error.contains("kidname can't change its own parent"), "\(error)")
  }

  // MARK: A scoped request stays in its group

  @Test(.timeLimit(.minutes(1)), arguments: [String?.none, "g2"])
  func aScopedClearOfAChildOutsideTheGroupIsRefused(_ group: String?) throws {
    let error = try refusal(
      [groupChat("c1", of: "g1"), work("boss", group: "g1"), work("kid", parent: "boss", group: group)],
      ["session": "kid", "clear": true, "by": "claude", "scope": "g1", "caller": "c1"])

    #expect(error.contains("is not in group"), "\(error)")
  }

  @Test(.timeLimit(.minutes(1)), arguments: [String?.none, "g2"])
  func aScopedSetToAParentOutsideTheGroupIsRefused(_ group: String?) throws {
    let error = try refusal(
      [groupChat("c1", of: "g1"), work("outsider", group: group), work("kid", group: "g1")],
      ["session": "kid", "parent": "outsider", "by": "claude", "scope": "g1", "caller": "c1"])

    #expect(error.contains("is not in group"), "\(error)")
  }

  /// A name that matches no session gets the same refusal as one outside the group, so a chat can't learn which
  /// names exist.
  /// The app sends the parent it showed as `from`. A move since then makes sbd refuse, so undo never restores a
  /// parent that the unlink didn't remove.
  @Test(.timeLimit(.minutes(1)))
  func aClearFromAParentTheSessionNoLongerHasIsRefused() throws {
    let error = try refusal(
      [work("old"), work("new"), work("kid", name: "kidname", parent: "new")],
      ["session": "kid", "clear": true, "from": "old"])

    #expect(error.contains("kidname is no longer under old"), "\(error)")
  }

  @Test(.timeLimit(.minutes(1)))
  func aScopedSetToANameThatMatchesNoSessionGetsTheScopeRefusal() throws {
    let error = try refusal(
      [groupChat("c1", of: "g1"), work("kid", group: "g1")],
      ["session": "kid", "parent": "nosuch", "by": "claude", "scope": "g1", "caller": "c1"])

    #expect(error.contains("nosuch is not in group"), "\(error)")
  }

  @Test(.timeLimit(.minutes(1)))
  func aScopedSetOfAChildOutsideTheGroupIsRefused() throws {
    let error = try refusal(
      [groupChat("c1", of: "g1"), work("member", group: "g1"), work("kid", group: "g2")],
      ["session": "kid", "parent": "member", "by": "claude", "scope": "g1", "caller": "c1"])

    #expect(error.contains("is not in group"), "\(error)")
  }

  // MARK: The rules of a set

  @Test(.timeLimit(.minutes(1)))
  func aSetToAnUnknownParentIsRefused() throws {
    let error = try refusal([work("kid")], ["session": "kid", "parent": "nosuch"])

    #expect(error.contains("nosuch"), "\(error)")
  }

  @Test(.timeLimit(.minutes(1)), arguments: ["kid", "kidname", "ki"])
  func aSetToTheChildItselfIsRefused(_ ref: String) throws {
    let error = try refusal([work("kid", name: "kidname")], ["session": "kid", "parent": .string(ref)])

    #expect(error.contains("kidname can't be its own parent"), "\(error)")
  }

  /// A self-parent is refused whether or not the child already has a parent.
  @Test(.timeLimit(.minutes(1)))
  func aSetOfALinkedChildToItselfIsRefused() throws {
    let error = try refusal(
      [work("boss"), work("kid", name: "kidname", parent: "boss")], ["session": "kid", "parent": "kid"])

    #expect(error.contains("kidname can't be its own parent"), "\(error)")
  }

  static let silentParents: [Session] = [
    unstartedFollowupSession("quiet", name: "quietname", parent: nil),
    docketRow("quiet", name: "quietname", parent: nil),
  ]

  @Test(.timeLimit(.minutes(1)), arguments: silentParents.indices)
  func aSetToAParentThatRunsNoClaudeIsRefused(_ i: Int) throws {
    let error = try refusal([Self.silentParents[i], work("kid")], ["session": "kid", "parent": "quiet"])

    #expect(error.contains("quietname runs no claude, so it can't hear about a child"), "\(error)")
  }

  static let nonWorkChildren: [Session] = [
    managerConversation("kid"), groupChat("kid", of: "g1"), operatorSession("kid"),
  ]

  @Test(.timeLimit(.minutes(1)), arguments: nonWorkChildren.indices)
  func aSetOfAChildThatIsNotWorkIsRefused(_ i: Int) throws {
    let error = try refusal([work("boss"), Self.nonWorkChildren[i]], ["session": "kid", "parent": "boss"])

    #expect(error.contains("only a work session can have a parent"), "\(error)")
  }

  /// The runs-claude refusal comes before the work-session refusal.
  @Test(.timeLimit(.minutes(1)))
  func aSetThatBreaksTwoRulesGetsTheRefusalListedFirst() throws {
    let error = try refusal(
      [docketRow("quiet", name: "quietname", parent: nil), groupChat("kid", of: "g1")],
      ["session": "kid", "parent": "quiet"])

    #expect(error.contains("quietname runs no claude"), "\(error)")
  }

  // MARK: Risk 1: the cycle guard

  @Test(.timeLimit(.minutes(1)), arguments: ["boss", "bossname", "bo"])
  func aSetToASessionThatIsTheChildsChildIsRefused(_ ref: String) throws {
    let error = try refusal(
      [work("kid", name: "kidname"), work("boss", name: "bossname", parent: "kid")],
      ["session": "kid", "parent": .string(ref)])

    #expect(error.contains("bossname is already under kidname"), "\(error)")
  }

  @Test(.timeLimit(.minutes(1)))
  func aSetToASessionThreeLevelsUnderTheChildIsRefused() throws {
    let error = try refusal(
      [work("kid"), work("a", parent: "kid"), work("b", parent: "a"), work("c", parent: "b")],
      ["session": "kid", "parent": "c"])

    #expect(error.contains("c is already under kid"), "\(error)")
  }

  /// The child's own parent does not matter. Only the new parent's chain is walked.
  @Test(.timeLimit(.minutes(1)))
  func aSetOfALinkedChildToItsOwnChildIsRefused() throws {
    let error = try refusal(
      [work("old"), work("kid", parent: "old"), work("grandkid", parent: "kid")],
      ["session": "kid", "parent": "grandkid"])

    #expect(error.contains("grandkid is already under kid"), "\(error)")
  }

  /// The walk reads raw `parent` fields, so it follows a follow-up's parent too. `parentOf` would stop at the
  /// follow-up, but the raw check may refuse more than it needs to.
  @Test(.timeLimit(.minutes(1)))
  func aSetToASessionWhoseChainPassesThroughAFollowupOfTheChildIsRefused() throws {
    let error = try refusal(
      [work("kid"), startedFollowupSession("f", parent: "kid"), work("boss", parent: "f")],
      ["session": "kid", "parent": "boss"])

    #expect(error.contains("boss is already under kid"), "\(error)")
  }
}

// MARK: Set

@Suite struct ParentLinkSetTests {
  @Test(.timeLimit(.minutes(1)))
  func setLinksASessionWithNoParent() throws {
    try withParents([work("boss"), work("kid")]) { service in
      let answer = service.parent(["session": "kid", "parent": "boss"])

      #expect(answer.ok, "\(answer.error ?? "")")
      #expect(service.rawParent(of: "kid") == "boss")
      let actual11 = try service.storedParent(of: "kid")
      #expect(actual11 == "boss")
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func setReturnsTheChildsSummaryWithTheNewParent() throws {
    try withParents([work("boss"), work("kid")]) { service in
      let answer = service.parent(["session": "kid", "parent": "boss"])

      let result = try #require(answer.result)
      #expect(result["id"] == "kid")
      #expect(result["parent"] == "boss")
    }
  }

  @Test(.timeLimit(.minutes(1)), arguments: ["boss", "bossname", "bo"])
  func setStoresTheParentsIdHoweverItIsNamed(_ ref: String) throws {
    try withParents([work("boss", name: "bossname"), work("kid")]) { service in
      _ = service.parent(["session": "kid", "parent": .string(ref)])

      #expect(service.rawParent(of: "kid") == "boss")
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func setRecordsLinkedOnTheChildAndTheNewParent() throws {
    try withParents([work("boss"), work("kid")]) { service in
      _ = service.parent(["session": "kid", "parent": "boss"])

      let actual12 = try service.linkEvents("kid", "linked").map(\.data)
      #expect(actual12 == [["parent": "boss", "by": "you"]])
      let actual13 = try service.linkEvents("boss", "linked").map(\.data)
      #expect(actual13 == [["child": "kid", "by": "you"]])
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func setOfASessionWithNoParentRecordsNoUnlinked() throws {
    try withParents([work("boss"), work("kid")]) { service in
      _ = service.parent(["session": "kid", "parent": "boss"])

      let check14 = try service.linkEvents("kid", "unlinked").isEmpty
      #expect(check14)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func setByClaudeRecordsClaude() throws {
    try withParents([work("boss"), work("kid")]) { service in
      _ = service.parent(["session": "kid", "parent": "boss", "by": "claude"])

      let actual15 = try service.linkEvents("kid", "linked").map { $0.data["by"] }
      #expect(actual15 == ["claude"])
      let actual16 = try service.linkEvents("boss", "linked").map { $0.data["by"] }
      #expect(actual16 == ["claude"])
    }
  }

  /// A double undo sends the same set twice, and the second changes nothing.
  @Test(.timeLimit(.minutes(1)))
  func setToTheCurrentParentSucceedsAndChangesNothing() throws {
    try withParents([work("boss"), work("kid", parent: "boss")]) { service in
      let before = try service.linkState()

      let answer = service.parent(["session": "kid", "parent": "boss"])

      #expect(answer.ok, "\(answer.error ?? "")")
      #expect(answer.result?["parent"] == "boss")
      let actual17 = try service.linkState()
      #expect(actual17 == before)
    }
  }

  // MARK: A move

  static let move = [work("old"), work("new"), work("kid", parent: "old")]

  @Test(.timeLimit(.minutes(1)))
  func aMoveRecordsUnlinkedThenLinkedOnTheChild() throws {
    try withParents(Self.move) { service in
      _ = service.parent(["session": "kid", "parent": "new"])

      let actual18 = try service.linkKinds("kid")
      #expect(actual18 == ["unlinked", "linked"])
      let actual19 = try service.linkEvents("kid", "unlinked").map(\.data)
      #expect(actual19 == [["parent": "old", "by": "you"]])
      let actual20 = try service.linkEvents("kid", "linked").map(\.data)
      #expect(actual20 == [["parent": "new", "by": "you"]])
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func aMoveRecordsUnlinkedOnTheOldParentOnly() throws {
    try withParents(Self.move) { service in
      _ = service.parent(["session": "kid", "parent": "new"])

      let actual21 = try service.linkKinds("old")
      #expect(actual21 == ["unlinked"])
      let actual22 = try service.linkEvents("old", "unlinked").map(\.data)
      #expect(actual22 == [["child": "kid", "by": "you"]])
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func aMoveRecordsLinkedOnTheNewParentOnly() throws {
    try withParents(Self.move) { service in
      _ = service.parent(["session": "kid", "parent": "new"])

      let actual23 = try service.linkKinds("new")
      #expect(actual23 == ["linked"])
      let actual24 = try service.linkEvents("new", "linked").map(\.data)
      #expect(actual24 == [["child": "kid", "by": "you"]])
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func aMoveFromARemovedParentRecordsNoEventForIt() throws {
    try withParents([work("new"), work("kid", parent: "gone")]) { service in
      let answer = service.parent(["session": "kid", "parent": "new"])

      #expect(answer.ok, "\(answer.error ?? "")")
      let actual25 = try service.linkKinds("kid")
      #expect(actual25 == ["unlinked", "linked"])
      let check26 = try service.queue.sync { try service.store.events(session: "gone") }.isEmpty
      #expect(check26)
    }
  }

  /// A move never re-inherits the new parent's group, account, or host.
  @Test(.timeLimit(.minutes(1)))
  func aMoveKeepsTheChildsGroupAccountAndHost() throws {
    var kid = work("kid", parent: "old", group: "g1")
    kid.claudeConfigDir = "/Users/me/.claude-work"
    var new = work("new", group: "g2")
    new.claudeConfigDir = "/Users/me/.claude-home"
    try withParents([work("old"), new, kid]) { service in
      _ = service.parent(["session": "kid", "parent": "new"])

      var expected = kid
      expected.parent = "new"
      #expect(service.queue.sync { service.entries["kid"]?.session } == expected)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func aScopedSetInsideTheGroupIsAccepted() throws {
    try withParents([groupChat("c1", of: "g1"), work("member", group: "g1"), work("kid", group: "g1")]) { service in
      let answer = service.parent(["session": "kid", "parent": "member", "by": "claude", "scope": "g1", "caller": "c1"])

      #expect(answer.ok, "\(answer.error ?? "")")
      #expect(service.rawParent(of: "kid") == "member")
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func aScopedClearInsideTheGroupIsAccepted() throws {
    try withParents([groupChat("c1", of: "g1"), work("boss"), work("kid", parent: "boss", group: "g1")]) { service in
      let answer = service.parent(["session": "kid", "clear": true, "by": "claude", "scope": "g1", "caller": "c1"])

      #expect(answer.ok, "\(answer.error ?? "")")
      #expect(service.rawParent(of: "kid") == nil)
    }
  }

  /// Any caller but the child may change its parent, such as the parent itself.
  @Test(.timeLimit(.minutes(1)))
  func theParentCanUnlinkItsChild() throws {
    try withParents([work("boss"), work("kid", parent: "boss")]) { service in
      let answer = service.parent(["session": "kid", "clear": true, "caller": "boss", "by": "claude"])

      #expect(answer.ok, "\(answer.error ?? "")")
      #expect(service.rawParent(of: "kid") == nil)
    }
  }

  /// A done parent or child is allowed.
  @Test(.timeLimit(.minutes(1)))
  func aSetToADoneParentIsAccepted() throws {
    var boss = work("boss")
    boss.done = true
    try withParents([boss, work("kid")]) { service in
      let answer = service.parent(["session": "kid", "parent": "boss"])

      #expect(answer.ok, "\(answer.error ?? "")")
      #expect(service.rawParent(of: "kid") == "boss")
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func aSetOfADoneChildIsAccepted() throws {
    var kid = work("kid")
    kid.done = true
    try withParents([work("boss"), kid]) { service in
      let answer = service.parent(["session": "kid", "parent": "boss"])

      #expect(answer.ok, "\(answer.error ?? "")")
      #expect(service.rawParent(of: "kid") == "boss")
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func aSetToAManagerConversationIsAccepted() throws {
    try withParents([managerConversation("m1"), work("kid")]) { service in
      let answer = service.parent(["session": "kid", "parent": "m1"])

      #expect(answer.ok, "\(answer.error ?? "")")
      #expect(service.rawParent(of: "kid") == "m1")
    }
  }

  // MARK: Risk 1: chains that do not reach the child

  /// The new parent's chain runs into a loop of two sessions that does not hold the child. The walk must stop.
  @Test(.timeLimit(.minutes(1)))
  func aSetToAChainThatRunsIntoAnUnrelatedLoopIsAccepted() throws {
    try withParents([work("kid"), work("boss", parent: "a"), work("a", parent: "b"), work("b", parent: "a")]) {
      service in
      let answer = service.parent(["session": "kid", "parent": "boss"])

      #expect(answer.ok, "\(answer.error ?? "")")
      #expect(service.rawParent(of: "kid") == "boss")
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func aSetToAParentThatNamesItselfIsAccepted() throws {
    try withParents([work("kid"), work("boss", parent: "boss")]) { service in
      let answer = service.parent(["session": "kid", "parent": "boss"])

      #expect(answer.ok, "\(answer.error ?? "")")
      #expect(service.rawParent(of: "kid") == "boss")
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func aSetToAChainThatEndsAtARemovedSessionIsAccepted() throws {
    try withParents([work("kid"), work("boss", parent: "a"), work("a", parent: "gone")]) { service in
      let answer = service.parent(["session": "kid", "parent": "boss"])

      #expect(answer.ok, "\(answer.error ?? "")")
      #expect(service.rawParent(of: "kid") == "boss")
    }
  }

  /// A sibling under the same parent is not under the child.
  @Test(.timeLimit(.minutes(1)))
  func aSetToASiblingIsAccepted() throws {
    try withParents([work("boss"), work("kid", parent: "boss"), work("sibling", parent: "boss")]) { service in
      let answer = service.parent(["session": "kid", "parent": "sibling"])

      #expect(answer.ok, "\(answer.error ?? "")")
      #expect(service.rawParent(of: "kid") == "sibling")
    }
  }
}

// MARK: Risk 3: the digest and the seed

/// After a `parent` request, no parent's digest holds a line about the child, and a new parent hears only what
/// changes after the link.
@Suite struct ParentLinkNoticeTests {
  static let family = [work("boss"), work("kid", parent: "boss"), work("sibling", parent: "boss")]

  /// Gives `kid` and `sibling` a PR that `boss` has not heard of.
  private func openBothPRs(_ service: Service) throws {
    try service.openPR("kid", number: 77)
    try service.openPR("sibling", number: 78)
  }

  @Test(.timeLimit(.minutes(1)))
  func aClearedChildLeavesTheDigestAndTheSiblingStays() throws {
    try withParents(Self.family) { service in
      try openBothPRs(service)

      _ = service.parent(["session": "kid", "clear": true])

      let lines = service.digestLines(for: "boss")
      #expect(lines.allSatisfy { !$0.contains("kid") }, "\(lines)")
      #expect(lines.contains { $0.contains("sibling") }, "\(lines)")
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func aClearDropsTheChildsMark() throws {
    try withParents(Self.family) { service in
      try openBothPRs(service)
      _ = service.digestLines(for: "boss")
      try #require(service.queue.sync { service.parentNotices.marks["kid"] } != nil, "the setup recorded no mark")

      _ = service.parent(["session": "kid", "clear": true])

      #expect(service.queue.sync { service.parentNotices.marks["kid"] } == nil)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func aMovedChildLeavesTheOldParentsDigest() throws {
    try withParents(Self.family + [work("new")]) { service in
      try openBothPRs(service)

      _ = service.parent(["session": "kid", "parent": "new"])

      let boss = service.digestLines(for: "boss")
      #expect(boss.allSatisfy { !$0.contains("kid") }, "\(boss)")
      #expect(boss.contains { $0.contains("sibling") })
    }
  }

  // MARK: A new parent hears only what changes after the link

  /// The child already has a PR, a reply, and a state its new parent never heard about. `.fresh` would hide a bare
  /// child, so the test gives it all three and then proves that, without the seed, a line would appear.
  @Test(.timeLimit(.minutes(1)), arguments: [String?.none, "old"])
  func aLinkedChildIsAbsentFromTheNewParentsDigestForWhatHappenedBefore(from old: String?) throws {
    try withParents([work("boss"), work("old"), work("kid", parent: old)]) { service in
      try service.openPR("kid")

      let answer = service.parent(["session": "kid", "parent": "boss"])
      try #require(answer.ok, "\(answer.error ?? "")")

      #expect(service.digestLines(for: "boss").isEmpty)
      service.queue.sync { service.parentNotices.marks["kid"] = nil }
      let unseeded = service.digestLines(for: "boss")
      #expect(unseeded.contains { $0.contains("kid") }, "the setup would show nothing without the seed")
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func aLinkSeedsTheChildsMarkWithEveryPRItHad() throws {
    try withParents([work("boss"), work("kid")]) { service in
      try service.openPR("kid", number: 77)

      _ = service.parent(["session": "kid", "parent": "boss"])

      let mark = try #require(service.queue.sync { service.parentNotices.marks["kid"] })
      #expect(mark.pr == 77)
      #expect(mark.heardPRs.contains(77))
    }
  }

  /// The seed reads the child as its new parent may see it, so it runs after the parent changes. The child is on
  /// mini, and its old parent there may not see the PR in `secret/vault`. A seed taken before the move would miss
  /// #4242, and the local new parent would hear "opened PR #4242".
  @Test(.timeLimit(.minutes(1)))
  func aMoveFromAHostParentSeedsWhatTheNewParentSees() throws {
    let sessions = [work("m1", host: "mini"), work("boss"), work("mkid", parent: "m1", host: "mini")]
    try withParents(sessions, hosts: listedHosts) { service in
      try service.openPR("mkid", number: 4242, repo: "secret/vault")
      let heardOnMini = service.digestLines(for: "m1")
      let markOnMini = service.queue.sync { service.parentNotices.marks["mkid"] }
      try #require(markOnMini != nil, "the setup gave m1 no mark of mkid")
      try #require(
        markOnMini?.pr == nil && heardOnMini.allSatisfy { !$0.contains("#4242") },
        "m1 on mini can see the PR, so the test proves nothing")

      let answer = service.parent(["session": "mkid", "parent": "boss"])
      try #require(answer.ok, "\(answer.error ?? "")")

      #expect(service.digestLines(for: "boss").isEmpty)
      service.queue.sync { service.parentNotices.marks["mkid"] = nil }
      let unseeded = service.digestLines(for: "boss")
      #expect(unseeded.contains { $0.contains("#4242") }, "the setup would show nothing without the seed: \(unseeded)")
    }
  }
}

// MARK: Risk 2: the shape table, sbd's half

/// The Risk 2 shapes. BoardModelParentTests.swift in SwitchboardAppTests holds the same rows for the app's half. A
/// row whose menu shows "Unlink from" must be a row whose clear sbd accepts.
enum ParentLinkShape: String, CaseIterable, Sendable, CustomTestStringConvertible {
  case workParent, managerParent, docketChild, startedFollowup, unstartedFollowup, removedParent, selfParent, noParent

  var testDescription: String { rawValue }

  /// Whether the app's menu offers "Unlink from <parent>".
  var shown: Bool {
    switch self {
    case .workParent, .managerParent, .docketChild: true
    case .startedFollowup, .unstartedFollowup, .removedParent, .selfParent, .noParent: false
    }
  }

  /// Whether sbd accepts a clear: any session that is not a follow-up and whose raw `parent` is set.
  var accepted: Bool {
    switch self {
    case .workParent, .managerParent, .docketChild, .removedParent, .selfParent: true
    case .startedFollowup, .unstartedFollowup, .noParent: false
    }
  }

  /// The sessions of the row. The child is `kid`, and its parent, when sbd holds it, is `boss`.
  var sessions: [Session] {
    switch self {
    case .workParent: [work("boss"), work("kid", parent: "boss")]
    case .managerParent: [managerConversation("boss"), work("kid", parent: "boss")]
    case .docketChild: [work("boss"), docketRow("kid", parent: "boss")]
    case .startedFollowup: [work("boss"), startedFollowupSession("kid", parent: "boss")]
    case .unstartedFollowup: [work("boss"), unstartedFollowupSession("kid", parent: "boss")]
    case .removedParent: [work("kid", parent: "boss")]
    case .selfParent: [work("boss"), work("kid", parent: "kid")]
    case .noParent: [work("boss"), work("kid")]
    }
  }
}

@Suite struct ParentLinkShapeTests {
  @Test(.timeLimit(.minutes(1)), arguments: ParentLinkShape.allCases)
  func sbdAcceptsTheClearExactlyForTheRowsThatExpectIt(_ shape: ParentLinkShape) throws {
    try withParents(shape.sessions) { service in
      let before = try service.linkState()

      let answer = service.parent(["session": "kid", "clear": true])

      #expect(answer.ok == shape.accepted, "\(answer.error ?? "accepted")")
      if answer.ok {
        #expect(service.rawParent(of: "kid") == nil)
      } else {
        let actual28 = try service.linkState()
        #expect(actual28 == before)
      }
    }
  }

  /// The test computes `shown` with `SessionTree.parentID`, the predicate behind the app's menu. A change to that
  /// predicate that shows the item on a row sbd refuses fails here.
  @Test(arguments: ParentLinkShape.allCases)
  func everyRowWhoseMenuShowsIsOneThatSbdAccepts(_ shape: ParentLinkShape) throws {
    let kid = try #require(shape.sessions.first { $0.id == "kid" })
    let ids = Set(shape.sessions.map(\.id))
    let parent = SessionTree.parentID(of: kid.id, parent: kid.parent, followup: kid.followup, isKnown: ids.contains)
    let shown = parent != nil

    #expect(shown == shape.shown)
    #expect(!shown || shape.accepted)
  }
}
