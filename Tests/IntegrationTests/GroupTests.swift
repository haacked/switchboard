import Foundation
import SwitchboardCore
import Testing

@Suite(.timeLimit(.minutes(2))) struct GroupTests {
  func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T { try JSONCoding.decode(type, from: text) }

  /// The environment of a command that Claude runs inside the session.
  func inside(_ id: String) -> [String: String] { ["SB_SESSION_ID": id, "CLAUDECODE": "1"] }

  func list(_ sbd: Instance) throws -> GroupList { try decode(GroupList.self, sbd.sb("group", "ls", "--json")) }

  func add(_ sbd: Instance, _ name: String, _ sessions: String...) throws -> GroupSummary {
    try decode(GroupSummary.self, sbd.sb(["group", "add", "--json", name] + sessions))
  }

  func suggestions(_ sbd: Instance) throws -> [GroupSuggestion] {
    try decode([GroupSuggestion].self, sbd.sb("group", "suggest", "--json"))
  }

  /// A session in a new worktree of the repo on the branch.
  func branched(_ sbd: Instance, _ repo: String, _ branch: String) throws -> SessionSummary {
    try sbd.client.call("new", ["path": .string(repo), "branch": .string(branch)], as: SessionSummary.self)
  }

  /// The text of each message that reached the session.
  func sent(_ sbd: Instance, _ id: String) throws -> [String] {
    try sbd.events(id).filter { $0.kind == "sent" }.compactMap { $0.data["text"]?.string }
  }

  /// Runs sb on a pseudo-terminal that `script` opens, and types `answer`
  /// and Return. The answer waits 0.5 s, because script sends an end of file
  /// to the terminal at once when its own input is already closed.
  func onTerminal(_ sbd: Instance, _ args: [String], answer: String, env extra: [String: String] = [:]) throws
    -> CommandResult
  {
    let env = sbd.environment(["ANSWER": answer].merging(extra) { $1 })
    let pipeline = #"(sleep 0.5; printf '%s\n' "$ANSWER"; sleep 3) | /usr/bin/script -q /dev/null "$@""#
    return try runCommand(
      "/bin/sh", ["-c", pipeline, "sh", "\(Instance.bin)/sb"] + args, env: env, timeout: 30)
  }

  // MARK: add, ls, note

  @Test func addCreatesAGroupWithItsSessionsAndNote() throws {
    let sbd = try Instance()
    let a = try sbd.new(name: "alpha")
    let b = try sbd.new(name: "bravo")

    let g = try decode(
      GroupSummary.self,
      sbd.sb("group", "add", "--json", "Flags", a.id, b.id, "--note", "Ship by Friday"))

    #expect(g.name == "Flags")
    #expect(g.id.range(of: #"^g[a-z2-9]{5}$"#, options: .regularExpression) != nil)
    #expect(Set(g.sessions) == [a.id, b.id])
    #expect(g.notes.map(\.text) == ["Ship by Friday"])
    #expect(try sbd.get(a.id).group == g.id)
    #expect(try sbd.get(b.id).group == g.id)
  }

  @Test func addWithoutSessionsCreatesAnEmptyGroup() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "alpha")

    let g = try add(sbd, "Flags")

    #expect(g.sessions.isEmpty)
    #expect(try sbd.get(s.id).group == nil)
  }

  @Test func addRefusesANameThatAnotherGroupHas() throws {
    let sbd = try Instance()
    _ = try add(sbd, "Flags")

    let again = try sbd.run(["group", "add", "--json", "Flags"])

    #expect(again.status != 0)
    #expect(try list(sbd).groups.map(\.name) == ["Flags"])
  }

  @Test func lsListsTheGroupsByNameAndTheUngroupedSessions() throws {
    let sbd = try Instance()
    let a = try sbd.new(name: "alpha")
    let b = try sbd.new(name: "bravo")
    let u = try sbd.new(name: "loose")
    let zeta = try add(sbd, "Zeta", a.id)
    let alpha = try add(sbd, "Alpha", b.id)

    let groups = try list(sbd)

    #expect(groups.groups.map(\.id) == [alpha.id, zeta.id])
    #expect(groups.groups.map(\.sessions) == [[b.id], [a.id]])
    #expect(groups.ungrouped == [u.id])
  }

  @Test func groupsAndTheirNotesSurviveARestartOfSbd() throws {
    let sbd = try Instance()
    let a = try sbd.new(name: "alpha")
    let b = try sbd.new(name: "bravo")
    _ = try add(sbd, "Flags", a.id)
    _ = try sbd.sb("group", "note", "Flags", "Ship by Friday")

    let before = try list(sbd)
    sbd.stopSbd()
    try sbd.startSbd()

    #expect(try list(sbd) == before)
    #expect(before.groups.first?.notes.map(\.text) == ["Ship by Friday"])
    #expect(before.ungrouped == [b.id])
  }

  @Test func noteKeepsWordsThatLookLikeFlags() throws {
    let sbd = try Instance()
    _ = try add(sbd, "Flags")

    _ = try sbd.sb("group", "note", "Flags", "deploy", "--to", "staging", "first")

    #expect(try list(sbd).groups.first?.notes.map(\.text) == ["deploy --to staging first"])
  }

  @Test func lsPrintsEachGroupWithItsNotesThenUngrouped() throws {
    let sbd = try Instance()
    let a = try sbd.new(name: "alpha")
    let loose = try sbd.new(name: "loose")
    try sbd.sb("group", "add", "Flags", a.id, "--note", "Ship by Friday")

    let text = try sbd.sb("group", "ls")

    let flags = try #require(text.range(of: "Flags"))
    let ungrouped = try #require(text.range(of: "Ungrouped"))
    #expect(flags.lowerBound < ungrouped.lowerBound)
    #expect(text.contains("Ship by Friday"))
    #expect(try #require(text.range(of: a.id)).lowerBound < ungrouped.lowerBound)
    #expect(try #require(text.range(of: loose.id)).lowerBound > ungrouped.lowerBound)
  }

  @Test func noteAddsANoteToAGroupFoundByName() throws {
    let sbd = try Instance()
    let g = try add(sbd, "Flags")

    let noted = try decode(GroupSummary.self, sbd.sb("group", "note", "--json", "Flags", "Ask Ana first."))

    #expect(noted.id == g.id)
    #expect(noted.notes.map(\.text) == ["Ask Ana first."])
    #expect(noted.notes.map(\.by) == [.you])
    #expect(try list(sbd).groups.first?.notes.map(\.text) == ["Ask Ana first."])
  }

  @Test func aNoteThatClaudeAddsIsByClaude() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "alpha")
    _ = try add(sbd, "Flags")

    let noted = try decode(
      GroupSummary.self, sbd.sb(["group", "note", "--json", "Flags", "From Claude."], env: inside(s.id)))

    #expect(noted.notes.map(\.by) == [.claude])
  }

  // MARK: move

  @Test func moveMovesSessionsIntoAGroupFoundByNameOrIdPrefix() throws {
    let sbd = try Instance()
    let a = try sbd.new(name: "alpha")
    let b = try sbd.new(name: "bravo")
    let g = try add(sbd, "Flags")

    let byName = try decode([SessionSummary].self, sbd.sb("group", "move", "--json", a.id, "--to", "Flags"))
    let byPrefix = try decode(
      [SessionSummary].self, sbd.sb("group", "move", "--json", b.id, "--to", String(g.id.prefix(4))))

    #expect(byName.map(\.id) == [a.id])
    #expect(byName.map(\.group) == [g.id])
    #expect(byPrefix.map(\.group) == [g.id])
    #expect(Set(try list(sbd).groups.first?.sessions ?? []) == [a.id, b.id])
  }

  @Test func moveUngroupedTakesSessionsOutOfTheirGroup() throws {
    let sbd = try Instance()
    let a = try sbd.new(name: "alpha")
    let b = try sbd.new(name: "bravo")
    let g = try add(sbd, "Flags", a.id, b.id)

    let moved = try decode([SessionSummary].self, sbd.sb("group", "move", "--json", a.id, "--ungrouped"))

    #expect(moved.map(\.id) == [a.id])
    #expect(moved.map(\.group) == [nil])
    let groups = try list(sbd)
    #expect(groups.groups.map(\.id) == [g.id])
    #expect(groups.groups.first?.sessions == [b.id])
    #expect(groups.ungrouped == [a.id])
  }

  /// How a command can name the Manager: its id, a prefix of its id, or its name.
  enum ManagerName: CaseIterable { case id, idPrefix, name }

  func name(_ m: SessionSummary, _ how: ManagerName) -> String {
    switch how {
    case .id: m.id
    case .idPrefix: String(m.id.prefix(4))
    case .name: m.name
    }
  }

  @Test(arguments: ManagerName.allCases) func moveRefusesTheManagerHoweverItIsNamed(_ how: ManagerName) throws {
    let sbd = try Instance()
    let m = try decode(SessionSummary.self, sbd.sb("manager", "--json"))
    _ = try add(sbd, "Flags")

    let moved = try sbd.run(["group", "move", "--json", name(m, how), "--to", "Flags"])

    #expect(moved.status != 0)
    #expect(try sbd.get(m.id).group == nil)
  }

  @Test(arguments: ManagerName.allCases) func addLeavesTheManagerOutOfTheGroup(_ how: ManagerName) throws {
    let sbd = try Instance()
    let m = try decode(SessionSummary.self, sbd.sb("manager", "--json"))

    _ = try sbd.run(["group", "add", "--json", "Flags", name(m, how)])

    #expect(try sbd.get(m.id).group == nil)
    #expect(try list(sbd).groups.isEmpty)
  }

  @Test func moveRefusesAGroupItCantFind() throws {
    let sbd = try Instance()
    let a = try sbd.new(name: "alpha")
    _ = try add(sbd, "Flags")

    let moved = try sbd.run(["group", "move", "--json", a.id, "--to", "Nowhere"])

    #expect(moved.status != 0)
    #expect(try sbd.get(a.id).group == nil)
  }

  @Test func moveRefusesAnIdPrefixThatTwoGroupsShare() throws {
    let sbd = try Instance()
    let a = try sbd.new(name: "alpha")
    let one = try add(sbd, "Flags one")
    let two = try add(sbd, "Flags two")
    // Every group id starts with g, so the shared prefix is never empty.
    let shared = one.id.commonPrefix(with: two.id)

    let moved = try sbd.run(["group", "move", "--json", a.id, "--to", shared])

    #expect(moved.status != 0)
    #expect(try sbd.get(a.id).group == nil)
  }

  // MARK: rm

  @Test func rmDeletesTheGroupAndLeavesItsMembersUngrouped() throws {
    let sbd = try Instance()
    let a = try sbd.new(name: "alpha")
    let b = try sbd.new(name: "bravo")
    let g = try add(sbd, "Flags", a.id, b.id)

    let removed = try decode(JSON.self, sbd.sb("group", "rm", "--json", "Flags"))

    #expect(removed["removed"]?.string == g.id)
    #expect(Set(removed["ungrouped"]?.array?.compactMap(\.string) ?? []) == [a.id, b.id])
    let groups = try list(sbd)
    #expect(groups.groups.isEmpty)
    #expect(Set(groups.ungrouped) == [a.id, b.id])
    #expect(try sbd.get(a.id).group == nil)
  }

  @Test func rmKeepsHowEachMemberWasPlaced() throws {
    let sbd = try Instance()
    let repo = try sbd.makeRepo()
    let parent = try sbd.new(name: "parent")
    let byHand1 = try branched(sbd, repo, "haacked/billing-retry-one")
    let byHand2 = try branched(sbd, repo, "haacked/billing-retry-two")
    _ = try add(sbd, "Billing", byHand1.id, byHand2.id)
    _ = try add(sbd, "Flags", parent.id)
    let kids = try ["haacked/flag-evaluations-cache", "haacked/flag-evaluations-perf"].map { branch in
      try decode(
        SessionSummary.self, sbd.sb(["new", "--json", "--branch", branch, repo], env: inside(parent.id)))
    }

    try sbd.sb("group", "rm", "Billing")
    try sbd.sb("group", "rm", "Flags")

    let found = try suggestions(sbd)
    let suggested = Set(found.flatMap(\.sessions))
    #expect(!suggested.contains(byHand1.id))
    #expect(!suggested.contains(byHand2.id))
    #expect(!suggested.contains(parent.id))
    #expect(found.contains { Set($0.sessions) == Set(kids.map(\.id)) })
  }

  // MARK: suggest

  @Test func suggestFindsBranchesThatShareAPrefixAndAcceptCreatesTheGroup() throws {
    let sbd = try Instance()
    let repo = try sbd.makeRepo()
    let a = try branched(sbd, repo, "haacked/flag-evaluations-cache")
    let b = try branched(sbd, repo, "haacked/flag-evaluations-perf")
    let other = try branched(sbd, repo, "haacked/billing-retry")

    let found = try suggestions(sbd)

    let first = try #require(found.first)
    #expect(first.id == "prefix:flag-evaluations")
    #expect(first.name == "flag-evaluations")
    #expect(first.group == nil)
    #expect(Set(first.sessions) == [a.id, b.id])
    #expect(first.reason == "branches start with flag-evaluations")
    #expect(!found.contains { $0.sessions.contains(other.id) })

    let accepted = try decode(
      GroupSummary.self, sbd.sb("group", "suggest", "--json", "--accept", "prefix:flag-evaluations"))

    #expect(accepted.name == "flag-evaluations")
    #expect(Set(accepted.sessions) == [a.id, b.id])
    #expect(try sbd.get(a.id).group == accepted.id)
    #expect(try list(sbd).ungrouped == [other.id])
    let after = try suggestions(sbd)
    #expect(!after.contains { $0.sessions.contains(a.id) || $0.sessions.contains(b.id) })
  }

  @Test func suggestOffersToJoinAGroupAndAcceptMovesTheSessionIn() throws {
    let sbd = try Instance()
    let repo = try sbd.makeRepo()
    let member = try branched(sbd, repo, "haacked/flag-evaluations-cache")
    let g = try add(sbd, "Flags", member.id)
    let c = try branched(sbd, repo, "haacked/flag-evaluations-perf")

    let found = try suggestions(sbd)

    let join = try #require(found.first)
    #expect(join.id == "prefix:flag-evaluations:\(g.id)")
    #expect(join.group == g.id)
    #expect(join.sessions == [c.id])

    let accepted = try decode(GroupSummary.self, sbd.sb("group", "suggest", "--json", "--accept", join.id))

    #expect(accepted.id == g.id)
    #expect(Set(accepted.sessions) == [member.id, c.id])
    #expect(try sbd.get(c.id).group == g.id)
    #expect(try list(sbd).groups.count == 1)
  }

  @Test func suggestOffersToJoinAGroupWhoseNameMatchesTheBranch() throws {
    let sbd = try Instance()
    let repo = try sbd.makeRepo()
    let g = try add(sbd, "Flag evaluations")
    let c = try branched(sbd, repo, "haacked/flag-evaluations-perf")

    let join = try #require(try suggestions(sbd).first)

    #expect(join.group == g.id)
    #expect(join.sessions == [c.id])
  }

  @Test func suggestLeavesOutASessionPlacedInUngroupedByHand() throws {
    let sbd = try Instance()
    let repo = try sbd.makeRepo()
    let a = try branched(sbd, repo, "haacked/flag-evaluations-cache")
    let b = try branched(sbd, repo, "haacked/flag-evaluations-perf")
    let c = try branched(sbd, repo, "haacked/flag-evaluations-docs")
    try sbd.sb("group", "move", c.id, "--ungrouped")

    let found = try suggestions(sbd)

    #expect(!found.contains { $0.sessions.contains(c.id) })
    #expect(Set(try #require(found.first).sessions) == [a.id, b.id])
  }

  @Test func suggestLeavesOutTheManager() throws {
    let sbd = try Instance()
    let repo = try sbd.makeRepo()
    let m = try decode(SessionSummary.self, sbd.sb("manager", "--json"))
    _ = try branched(sbd, repo, "haacked/flag-evaluations-cache")
    _ = try branched(sbd, repo, "haacked/flag-evaluations-perf")

    let found = try suggestions(sbd)

    #expect(!found.isEmpty)
    #expect(!found.contains { $0.sessions.contains(m.id) })
  }

  @Test func acceptRefusesAnIdThatTheSuggestionsDontHave() throws {
    let sbd = try Instance()
    let repo = try sbd.makeRepo()
    let a = try branched(sbd, repo, "haacked/flag-evaluations-cache")
    _ = try branched(sbd, repo, "haacked/flag-evaluations-perf")

    let accepted = try sbd.run(["group", "suggest", "--json", "--accept", "prefix:nothing-like-it"])

    #expect(accepted.status != 0)
    #expect(try list(sbd).groups.isEmpty)
    #expect(try sbd.get(a.id).group == nil)
  }

  // MARK: The parent's group

  @Test func newInsideAGroupedSessionJoinsTheParentsGroup() throws {
    let sbd = try Instance()
    let parent = try sbd.new(name: "parent")
    let g = try add(sbd, "Flags", parent.id)

    let kid = try decode(
      SessionSummary.self, sbd.sb(["new", "--json", "--name", "kid", sbd.work], env: inside(parent.id)))

    #expect(kid.parent == parent.id)
    #expect(kid.group == g.id)
    #expect(Set(try list(sbd).groups.first?.sessions ?? []) == [parent.id, kid.id])
  }

  @Test func newInsideAnUngroupedSessionStaysUngrouped() throws {
    let sbd = try Instance()
    let parent = try sbd.new(name: "parent")
    _ = try add(sbd, "Flags")

    let kid = try decode(
      SessionSummary.self, sbd.sb(["new", "--json", "--name", "kid", sbd.work], env: inside(parent.id)))

    #expect(kid.parent == parent.id)
    #expect(kid.group == nil)
  }

  @Test func newTypedInTheShellPaneOfAGroupedSessionStaysUngrouped() throws {
    let sbd = try Instance()
    let parent = try sbd.new(name: "parent")
    _ = try add(sbd, "Flags", parent.id)

    let typed = try decode(
      SessionSummary.self,
      sbd.sb(["new", "--json", "--name", "typed", sbd.work], env: ["SB_SESSION_ID": parent.id]))

    #expect(typed.parent == nil)
    #expect(typed.group == nil)
  }

  @Test func followupAddInsideAGroupedSessionJoinsTheParentsGroup() throws {
    let sbd = try Instance()
    let parent = try sbd.new(name: "parent")
    let g = try add(sbd, "Flags", parent.id)

    let f = try decode(
      SessionSummary.self,
      sbd.sb(["followup", "add", "--json", "--repo", "acme/widgets", "Fix the cache."], env: inside(parent.id)))

    #expect(f.parent == parent.id)
    #expect(f.group == g.id)
    #expect(Set(try list(sbd).groups.first?.sessions ?? []) == [parent.id, f.id])
  }

  @Test func followupAddInsideAnUngroupedSessionStaysUngrouped() throws {
    let sbd = try Instance()
    let parent = try sbd.new(name: "parent")
    _ = try add(sbd, "Flags")

    let f = try decode(
      SessionSummary.self,
      sbd.sb(["followup", "add", "--json", "--repo", "acme/widgets", "Fix the cache."], env: inside(parent.id)))

    #expect(f.parent == parent.id)
    #expect(f.group == nil)
  }

  // MARK: send --group

  @Test func sendGroupWithYesSendsToEachMember() throws {
    let sbd = try Instance()
    let a = try sbd.new(name: "alpha")
    let b = try sbd.new(name: "bravo")
    let outside = try sbd.new(name: "outside")
    _ = try add(sbd, "Flags", a.id, b.id)

    let result = try decode(
      GroupSend.self, sbd.sb("send", "--json", "--group", "Flags", "--yes", "Rebase on main."))

    #expect(result.sent)
    #expect(Set(result.targets.map(\.id)) == [a.id, b.id])
    #expect(Set(result.targets.map(\.name)) == ["alpha", "bravo"])
    let deliveries = result.deliveries ?? []
    #expect(Set(deliveries.map(\.session)) == [a.id, b.id])
    #expect(deliveries.allSatisfy { $0.delivery != nil && $0.error == nil })
    #expect(try sent(sbd, a.id) == ["Rebase on main."])
    #expect(try sent(sbd, b.id) == ["Rebase on main."])
    #expect(try sent(sbd, outside.id).isEmpty)
  }

  @Test func sendGroupWithoutATerminalRefusesWithoutYesAndSendsNothing() throws {
    let sbd = try Instance()
    let a = try sbd.new(name: "alpha")
    let b = try sbd.new(name: "bravo")
    _ = try add(sbd, "Flags", a.id, b.id)

    let r = try sbd.run(["send", "--group", "Flags", "Rebase on main."])

    #expect(r.status != 0)
    let output = r.stdout + r.stderr
    #expect(output.contains("alpha") || output.contains(a.id))
    #expect(output.contains("bravo") || output.contains(b.id))
    #expect(try sent(sbd, a.id).isEmpty)
    #expect(try sent(sbd, b.id).isEmpty)
  }

  @Test(arguments: [false, true]) func sendGroupInsideClaudeOpensACardAndSendsNothing(withYes yes: Bool) throws {
    let sbd = try Instance()
    let sender = try sbd.new(name: "sender")
    let a = try sbd.new(name: "alpha")
    _ = try add(sbd, "Flags", a.id)

    let r = try sbd.run(
      ["send", "--group", "Flags"] + (yes ? ["--yes"] : []) + ["Rebase on main."], env: inside(sender.id))

    #expect(r.status == 0)
    #expect(r.stdout.contains("sb send --pending"))
    #expect(try sbd.get(sender.id).cards.map(\.kind) == [.send])
    #expect(try sent(sbd, a.id).isEmpty)
  }

  @Test func sendGroupInsideClaudeOpensACardEvenOnATerminal() throws {
    let sbd = try Instance()
    let sender = try sbd.new(name: "sender")
    let a = try sbd.new(name: "alpha")
    _ = try add(sbd, "Flags", a.id)

    let r = try onTerminal(
      sbd, ["send", "--group", "Flags", "Rebase on main."], answer: "y", env: inside(sender.id))

    #expect(!r.stdout.contains("[y/N]"))
    #expect(r.stdout.contains("sb send --pending"))
    #expect(try sbd.get(sender.id).cards.map(\.kind) == [.send])
    #expect(try sent(sbd, a.id).isEmpty)
  }

  @Test func sendGroupOnATerminalSendsWhenTheUserAnswersYes() throws {
    let sbd = try Instance()
    let a = try sbd.new(name: "alpha")
    let b = try sbd.new(name: "bravo")
    _ = try add(sbd, "Flags", a.id, b.id)

    let r = try onTerminal(sbd, ["send", "--group", "Flags", "Rebase on main."], answer: "y")

    #expect(r.status == 0)
    #expect(r.stdout.contains("Send to these 2 sessions?"))
    #expect(r.stdout.contains("[y/N]"))
    #expect(try sent(sbd, a.id) == ["Rebase on main."])
    #expect(try sent(sbd, b.id) == ["Rebase on main."])
  }

  @Test func sendGroupOnATerminalSendsNothingWhenTheUserAnswersNo() throws {
    let sbd = try Instance()
    let a = try sbd.new(name: "alpha")
    let b = try sbd.new(name: "bravo")
    _ = try add(sbd, "Flags", a.id, b.id)

    let r = try onTerminal(sbd, ["send", "--group", "Flags", "Rebase on main."], answer: "n")

    #expect(r.status != 0)
    #expect(r.stdout.contains("[y/N]"))
    #expect(try sent(sbd, a.id).isEmpty)
    #expect(try sent(sbd, b.id).isEmpty)
  }

  @Test func sendGroupLeavesADeferredQuestion() throws {
    let sbd = try Instance(idleStopSeconds: 1)
    let s = try sbd.new(prompt: "pick")
    try sbd.waitFor(s.id, "the deferred card") { $0.cards.first?.deferred == true }
    _ = try add(sbd, "Flags", s.id)

    _ = try sbd.sb("send", "--json", "--group", "Flags", "--yes", "Rebase on main.")

    try sbd.waitFor(s.id, "the group message's reply") { $0.lastReply == "Done: Rebase on main." }
    let after = try sbd.get(s.id)
    #expect(after.cards.map(\.deferred) == [true])
    #expect(after.reason == "answer: Which fruit?")
  }

  @Test func sendGroupSendsToTheOtherMembersWhenOneFails() throws {
    let sbd = try Instance()
    let a = try sbd.new(name: "alpha")
    let b = try sbd.worktreeSession(try sbd.repoWithOrigin())
    try sbd.sb("stop", b.id)
    try sbd.waitFor(b.id, "claude to stop") { !$0.live }
    try FileManager.default.removeItem(atPath: b.cwd)
    _ = try add(sbd, "Flags", a.id, b.id)

    let result = try decode(
      GroupSend.self, sbd.sb("send", "--json", "--group", "Flags", "--yes", "Rebase on main."))

    let bySession = Dictionary(uniqueKeysWithValues: (result.deliveries ?? []).map { ($0.session, $0) })
    #expect(bySession[a.id]?.delivery != nil)
    #expect(bySession[b.id]?.delivery == nil)
    #expect(bySession[b.id]?.error?.contains("is gone") == true)
    #expect(try sent(sbd, a.id) == ["Rebase on main."])
    #expect(try sent(sbd, b.id).isEmpty)
  }

  @Test func sendGroupLeavesOutTheSenderAndUnstartedFollowups() throws {
    let sbd = try Instance()
    let sender = try sbd.new(name: "sender")
    let a = try sbd.new(name: "alpha")
    _ = try add(sbd, "Flags", sender.id, a.id)
    let f = try decode(
      SessionSummary.self,
      sbd.sb(["followup", "add", "--json", "--repo", "acme/widgets", "Fix the cache."], env: inside(sender.id)))
    #expect(f.group != nil)

    let result = try decode(
      GroupSend.self,
      sbd.sb(["send", "--json", "--group", "Flags", "--yes", "Rebase on main."], env: inside(sender.id)))

    #expect(result.targets.map(\.id) == [a.id])
    #expect(!result.sent)
    #expect(try sent(sbd, a.id).isEmpty)
    let card = try #require(result.pending)
    try sbd.sb("allow", sender.id, "--card", String(card))
    #expect(try sent(sbd, a.id) == ["Rebase on main."])
    #expect(try sent(sbd, sender.id).isEmpty)
    #expect(try sent(sbd, f.id).isEmpty)
  }

  @Test func aDocketReviewStartedInsideASessionJoinsItsGroupAndAGroupSendLeavesItOut() throws {
    let docket = try DocketHome()
    let sbd = try Instance(config: docket.config)
    let sender = try sbd.new(name: "sender")
    let a = try sbd.new(name: "alpha")
    let flags = try add(sbd, "Flags", sender.id, a.id)
    let d = try decode(SessionSummary.self, sbd.sb(["docket", "--json", "o/r#1"], env: inside(sender.id)))
    #expect(d.parent == sender.id)
    #expect(d.group == flags.id)

    let result = try decode(
      GroupSend.self,
      sbd.sb(["send", "--json", "--group", "Flags", "--yes", "Rebase on main."], env: inside(sender.id)))

    #expect(result.targets.map(\.id) == [a.id])
    #expect(try sent(sbd, d.id).isEmpty)
  }

  @Test func sendGroupSendsToAFollowupThatHasStarted() throws {
    let sbd = try Instance()
    let repo = try sbd.makeRepo()
    let parent = try sbd.new(name: "parent")
    _ = try add(sbd, "Flags", parent.id)
    let f = try decode(
      SessionSummary.self,
      sbd.sb(["followup", "add", "--json", "Fix the cache."], env: inside(parent.id)))
    _ = try sbd.client.call(
      "followup-start", ["session": .string(f.id), "path": .string(repo), "branch": "b1"], as: SessionSummary.self)

    let result = try decode(
      GroupSend.self, sbd.sb("send", "--json", "--group", "Flags", "--yes", "Rebase on main."))

    #expect(Set(result.targets.map(\.id)) == [parent.id, f.id])
    #expect(try sent(sbd, f.id) == ["Rebase on main."])
  }

  @Test func sendGroupRequestWithoutConfirmedReturnsTheTargetsAndSendsNothing() throws {
    let sbd = try Instance()
    let a = try sbd.new(name: "alpha")
    let g = try add(sbd, "Flags", a.id)

    let result = try sbd.client.call(
      "send-group", ["group": .string(g.id), "text": "Rebase on main.", "confirmed": .bool(false), "by": "you"],
      as: GroupSend.self)

    #expect(!result.sent)
    #expect(result.targets.map(\.id) == [a.id])
    #expect(result.deliveries == nil)
    #expect(try sent(sbd, a.id).isEmpty)
  }

  @Test func confirmedSendRefusesWhenTheTargetsChangedSinceTheyWereListed() throws {
    let sbd = try Instance()
    let a = try sbd.new(name: "alpha")
    let b = try sbd.new(name: "bravo")
    let g = try add(sbd, "Flags", a.id)
    _ = try sbd.sb("group", "move", b.id, "--to", "Flags")

    for targets in [[a.id], []] {
      #expect(throws: (any Error).self) {
        try sbd.client.call(
          "send-group",
          [
            "group": .string(g.id), "text": "Rebase on main.", "confirmed": true,
            "targets": .array(targets.map(JSON.string)),
          ])
      }
    }
    #expect(throws: (any Error).self) {
      try sbd.client.call("send-group", ["group": .string(g.id), "text": "Rebase on main.", "confirmed": true])
    }
    #expect(try sent(sbd, a.id).isEmpty)
    #expect(try sent(sbd, b.id).isEmpty)
  }
}
