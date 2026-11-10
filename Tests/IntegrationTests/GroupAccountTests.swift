import Foundation
import SwitchboardCore
import Testing

/// A group that names the Claude account its sessions run under: setting and
/// clearing it with `sb group account`, the account that new sessions in the
/// group record, the move to the group's account at a session's next launch,
/// and the moves that sbd skips.
@Suite(.blocking(timeLimit: .seconds(120))) struct GroupAccountTests {
  let accountTests = AccountTests()
  let signedOut = SignedOutAccountTests()
  let liveCap = LiveCapTests()

  func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T { try JSONCoding.decode(type, from: text) }

  /// The environment of a command that Claude runs inside the session.
  func inside(_ id: String) -> [String: String] { ["SB_SESSION_ID": id, "CLAUDECODE": "1"] }

  /// A sbd with accounts A and B and A active.
  func instance(_ extra: [String: JSON] = [:]) throws -> Instance {
    let sbd = try Instance(accounts: ["A", "B"], inheriting: .unset, config: extra)
    try sbd.sb("account", "use", "A")
    return sbd
  }

  func addGroup(_ sbd: Instance, _ name: String = "Flags", _ sessions: String...) throws -> GroupSummary {
    try decode(GroupSummary.self, sbd.sb(["group", "add", "--json", name] + sessions))
  }

  @discardableResult
  func setAccount(_ sbd: Instance, _ group: String, _ account: String) throws -> GroupSummary {
    try decode(GroupSummary.self, sbd.sb("group", "account", "--json", group, account))
  }

  func listed(_ sbd: Instance, _ id: String) throws -> GroupSummary {
    try #require(try decode(GroupList.self, sbd.sb("group", "ls", "--json")).groups.first { $0.id == id })
  }

  /// A new session in the group, made through the `new` request, which takes
  /// a group by reference.
  func newInGroup(_ sbd: Instance, _ group: String, prompt: String? = "hello", account: String? = nil) throws
    -> SessionSummary
  {
    var args: [String: JSON] = ["path": .string(sbd.work), "group": .string(group)]
    if let prompt { args["prompt"] = .string(prompt) }
    if let account { args["account"] = .string(account) }
    return try sbd.client.call("new", args, as: SessionSummary.self)
  }

  /// A session under `account`, outside any group, that answered one prompt and then stopped.
  func stoppedSession(_ sbd: Instance, on account: String, prompt: String = "hello") throws -> SessionSummary {
    let s = try decode(
      SessionSummary.self, sbd.sb("new", "--json", "--account", account, "--prompt", prompt, sbd.work))
    try sbd.waitFor(s.id, "the first reply") { $0.lastReply == "Done: \(prompt)" }
    try sbd.sb("stop", s.id)
    return try sbd.waitFor(s.id, "the stop") { $0.claudePid == nil }
  }

  func stop(_ sbd: Instance, _ s: SessionSummary) throws {
    try sbd.sb("stop", s.id)
    try sbd.waitFor(s.id, "the stop") { $0.claudePid == nil }
  }

  /// Sends a message to a stopped session, which launches its claude, and
  /// waits for the reply.
  func sendAndWait(_ sbd: Instance, _ s: SessionSummary, _ text: String = "again") throws {
    try sbd.sb("send", s.id, text)
    try sbd.waitFor(s.id, "the reply to \(text)") { $0.lastReply == "Done: \(text)" }
  }

  /// The last run of the stub claude for this session.
  func lastLaunch(_ sbd: Instance, _ s: SessionSummary) -> (account: String, agent: String, args: String)? {
    sbd.stubCalls().last { $0.args.contains(s.claudeSessionId) }
  }

  func events(_ sbd: Instance, _ s: SessionSummary, _ kind: String) throws -> [Event] {
    try sbd.events(s.id).filter { $0.kind == kind }
  }

  func removeLogin(_ sbd: Instance, _ account: String) throws {
    try FileManager.default.removeItem(atPath: "\(sbd.account(account))/.claude.json")
  }

  /// The account's folder written from the home folder with `~/` and `..`,
  /// which sbd expands with the HOME it inherited.
  func tildeForm(_ folder: String) -> String {
    let depth = (NSHomeDirectory() as NSString).pathComponents.count - 1
    return "~" + String(repeating: "/..", count: depth) + folder
  }

  // MARK: Setting the account

  @Test func setStoresTheAccountsFolderAndItSurvivesARestart() throws {
    let sbd = try instance()
    let g = try addGroup(sbd)

    let set = try setAccount(sbd, "Flags", "B")

    #expect(set.id == g.id)
    #expect(set.account == sbd.account("B"))
    sbd.stopSbd()
    try sbd.startSbd()
    #expect(try listed(sbd, g.id).account == sbd.account("B"))
  }

  /// sbd stores the normalized folder, whichever way the request names it.
  @Test func setFindsTheAccountHoweverItIsNamed() throws {
    let sbd = try instance()
    let g = try addGroup(sbd)
    let folder = sbd.account("B")

    for form in ["B", folder, folder + "/", tildeForm(folder)] {
      try sbd.sb("group", "account", "--json", "Flags", "--clear")

      let set = try setAccount(sbd, "Flags", form)

      #expect(set.account == folder, "\(form)")
      #expect(try listed(sbd, g.id).account == folder, "\(form)")
    }
  }

  /// The group keeps the active account it names when the active account changes.
  @Test func aGroupSetToTheActiveAccountKeepsItWhenTheActiveAccountChanges() throws {
    let sbd = try instance()
    let g = try addGroup(sbd)
    #expect(try setAccount(sbd, "Flags", "A").account == sbd.account("A"))

    try sbd.sb("account", "use", "B")
    let s = try newInGroup(sbd, "Flags", prompt: nil)

    #expect(try listed(sbd, g.id).account == sbd.account("A"))
    #expect(s.group == g.id)
    #expect(s.account == sbd.account("A"))
  }

  @Test func clearRemovesTheAccount() throws {
    let sbd = try instance()
    let g = try addGroup(sbd)
    try setAccount(sbd, "Flags", "B")

    let cleared = try decode(GroupSummary.self, sbd.sb("group", "account", "--json", "Flags", "--clear"))

    #expect(cleared.account == nil)
    #expect(try listed(sbd, g.id).account == nil)
  }

  @Test func setRefusesAnAccountWithoutALoginAndLeavesTheGroupAsItWas() throws {
    let sbd = try instance()
    let g = try addGroup(sbd)
    try setAccount(sbd, "Flags", "B")
    let empty = sbd.account("empty")
    try FileManager.default.createDirectory(atPath: empty, withIntermediateDirectories: true)

    for ref in ["nobody", empty] {
      let r = try sbd.run(["group", "account", "--json", "Flags", ref])
      #expect(r.status != 0, "sb group account Flags \(ref) succeeded: \(r.stdout)")
    }

    #expect(try listed(sbd, g.id).account == sbd.account("B"))
  }

  /// Without an account or clear, the request answers with the group as it is.
  @Test func theRequestShowsTheAccountAndRefusesAnEmptyOne() throws {
    let sbd = try instance()
    let g = try addGroup(sbd)
    try setAccount(sbd, "Flags", "B")

    let shown = try decode(GroupSummary.self, sbd.sb("group", "account", "--json", "Flags"))
    #expect(shown.account == sbd.account("B"))
    #expect(failure(sbd, "group-account", ["group": "Flags", "account": ""]) != "no error")

    #expect(try listed(sbd, g.id).account == sbd.account("B"))
  }

  @Test func setRefusesASignedOutAccountAndClearStillWorks() throws {
    let fake = try FakeUsage()
    let sbd = try signedOut.signedOutB(fake)
    let g = try addGroup(sbd)
    try setAccount(sbd, "Flags", "A")

    let r = try sbd.run(["group", "account", "--json", "Flags", "B"])

    #expect(r.status != 0, "sb group account Flags B succeeded: \(r.stdout)")
    #expect(r.stderr.contains(signedOut.login(sbd, "B")), "\(r.stderr)")
    #expect(try listed(sbd, g.id).account == sbd.account("A"))
    try sbd.sb("group", "account", "--json", "Flags", "--clear")
    #expect(try listed(sbd, g.id).account == nil)
  }

  /// `sb group ls` prints the account under the group, and `sb group
  /// account <group>` prints it without changing it.
  @Test func theTextOutputShowsTheAccount() throws {
    let sbd = try instance()
    let g = try addGroup(sbd)
    try setAccount(sbd, "Flags", "B")

    let ls = try sbd.sb("group", "ls")
    let shown = try sbd.sb("group", "account", "Flags")

    #expect(ls.contains("account: B (\(sbd.account("B")))"), "\(ls)")
    #expect(shown.contains(sbd.account("B")), "\(shown)")
    #expect(try listed(sbd, g.id).account == sbd.account("B"))
  }

  // MARK: New sessions in the group

  /// The account that a new session records is the one its first
  /// launch uses, so the launch moves nothing.
  @Test func aNewSessionInTheGroupRunsUnderItsAccountAndRecordsNoMove() throws {
    let sbd = try instance()
    let g = try addGroup(sbd)
    try setAccount(sbd, "Flags", "B")

    let s = try newInGroup(sbd, "Flags")

    #expect(s.group == g.id)
    #expect(s.account == sbd.account("B"))
    try sbd.waitFor(s.id, "the first reply") { $0.lastReply == "Done: hello" }
    #expect(lastLaunch(sbd, s)?.account == sbd.account("B"))
    #expect(try events(sbd, s, "account-moved").isEmpty)
    #expect(try events(sbd, s, "account-move-skipped").isEmpty)
  }

  /// The group's account wins over the parent's. The parent runs on A,
  /// because it was running when the group's account was set.
  @Test func sessionsStartedInsideAMemberTakeTheGroupsAccountOverTheParents() throws {
    let repos = try Repos()
    try repos.make("acme/widgets")
    let sbd = try instance(["repoRoots": [.string(repos.root)]])
    let parent = try decode(SessionSummary.self, sbd.sb("new", "--json", "--prompt", "hello", sbd.work))
    try sbd.waitFor(parent.id, "the parent's reply") { $0.lastReply == "Done: hello" }
    let g = try addGroup(sbd, "Flags", parent.id)
    try setAccount(sbd, "Flags", "B")
    #expect(try sbd.get(parent.id).account == sbd.account("A"))

    let kid = try decode(
      SessionSummary.self, sbd.sb(["new", "--json", "--prompt", "hello", sbd.work], env: inside(parent.id)))
    let spawned = try decode(
      SessionSummary.self,
      sbd.sb(
        ["spawn", "--json", "--repo", "acme/widgets", "--branch", "kid", "--prompt", "Go."], env: inside(parent.id)))

    #expect(kid.group == g.id)
    #expect(kid.account == sbd.account("B"))
    #expect(spawned.group == g.id)
    #expect(spawned.account == sbd.account("B"))
    try sbd.waitFor(kid.id, "the kid's reply") { $0.lastReply == "Done: hello" }
    try sbd.waitFor(spawned.id, "the spawned reply") { $0.lastReply == "Done: Go." }
    #expect(lastLaunch(sbd, kid)?.account == sbd.account("B"))
    #expect(lastLaunch(sbd, spawned)?.account == sbd.account("B"))
  }

  @Test func aFollowupAddedToTheGroupRecordsItsAccountAndStartsUnderIt() throws {
    let sbd = try instance()
    let repo = try sbd.makeRepo()
    let g = try addGroup(sbd)
    try setAccount(sbd, "Flags", "B")

    let f = try add(sbd, ["prompt": "Fix the cache.", "group": "Flags"])
    #expect(f.group == g.id)
    #expect(f.account == sbd.account("B"))
    _ = try sbd.client.call(
      "followup-start", ["session": .string(f.id), "path": .string(repo), "branch": "b1"], as: SessionSummary.self)

    try sbd.waitFor(f.id, "the follow-up's first turn") { $0.lastReply == "Done: Fix the cache." }
    #expect(try sbd.get(f.id).account == sbd.account("B"))
    #expect(lastLaunch(sbd, f)?.account == sbd.account("B"))
    #expect(try events(sbd, f, "account-moved").isEmpty)
  }

  /// Every path that creates a session refuses a named account that
  /// differs from the group's, names the group, and creates nothing. A refusal
  /// changes nothing, so one sbd serves every path.
  @Test func aNamedAccountThatDiffersFromTheGroupsIsRefused() throws {
    let repos = try Repos()
    let checkout = try repos.make("acme/widgets")
    let sbd = try instance(["repoRoots": [.string(repos.root)]])
    let member = try sbd.new(name: "member")
    _ = try addGroup(sbd, "Flags", member.id)
    try setAccount(sbd, "Flags", "B")
    let before = Set(try sbd.client.sessions().map(\.id))

    let cli = try sbd.run(["new", "--json", "--account", "A", sbd.work], env: inside(member.id))
    #expect(cli.status != 0, "sb new --account A inside a member succeeded: \(cli.stdout)")
    #expect(cli.stderr.contains("Flags"), "\(cli.stderr)")
    for (op, args) in [
      ("new", ["path": .string(sbd.work), "group": "Flags", "account": "A"]),
      ("followup-add", ["prompt": "Fix it.", "group": "Flags", "account": "A"]),
      ("spawn", ["repository": "acme/widgets", "branch": "kid", "prompt": "Go.", "group": "Flags", "account": "A"]),
    ] as [(String, [String: JSON])] {
      let refusal = failure(sbd, op, args)
      #expect(refusal.contains("Flags"), "\(op): \(refusal)")
    }

    #expect(Set(try sbd.client.sessions().map(\.id)) == before)
    #expect(try sbd.client.call("followup-ls", as: [SessionSummary].self).isEmpty)
    #expect(try !SpawnTests().branchExists(checkout, "kid"))
  }

  /// A name or folder that resolves to the group's own account is accepted.
  @Test func aNamedAccountThatIsTheGroupsIsAccepted() throws {
    let sbd = try instance()
    let member = try sbd.new(name: "member")
    let g = try addGroup(sbd, "Flags", member.id)
    try setAccount(sbd, "Flags", "B")
    let folder = sbd.account("B")

    for form in ["B", folder + "/", tildeForm(folder)] {
      let r = try sbd.run(["new", "--json", "--account", form, sbd.work], env: inside(member.id))
      #expect(r.status == 0, "sb new --account \(form) failed: \(r.stderr)")
      guard r.status == 0 else { continue }
      let s = try decode(SessionSummary.self, r.stdout)
      #expect(s.group == g.id, "\(form)")
      #expect(s.account == folder, "\(form)")
    }
  }

  /// The group's chat runs under the group's account.
  @Test func theGroupsChatRunsUnderItsAccount() throws {
    let sbd = try instance()
    _ = try addGroup(sbd)
    try setAccount(sbd, "Flags", "B")

    let chat = try ChatTests().chat(sbd, "Flags")

    #expect(chat.account == sbd.account("B"))
    try sbd.waitFor(chat.id, "the chat's claude") { $0.live }
    #expect(lastLaunch(sbd, chat)?.account == sbd.account("B"))
    #expect(try events(sbd, chat, "account-moved").isEmpty)
  }

  /// A new session uses the account it would use without the group,
  /// and the group keeps the stored folder for when the login comes back.
  @Test func aNewSessionFallsBackWhenTheGroupsAccountLostItsLogin() throws {
    let sbd = try instance()
    let g = try addGroup(sbd)
    try setAccount(sbd, "Flags", "B")
    try removeLogin(sbd, "B")

    let s = try newInGroup(sbd, "Flags", prompt: nil)

    #expect(s.group == g.id)
    #expect(s.account == sbd.account("A"))
    #expect(try listed(sbd, g.id).account == sbd.account("B"))
  }

  // MARK: Global moves

  /// `account move` leaves a session that its group binds to
  /// another account, and the dry run lists the same sessions as the move.
  /// A group whose folder lost its login still binds its sessions.
  @Test(arguments: [false, true]) func accountMoveLeavesABoundSessionAndTheDryRunAgrees(loginGone: Bool) throws {
    let sbd = try instance()
    let bound = try stoppedSession(sbd, on: "B", prompt: "bound")
    let loose = try stoppedSession(sbd, on: "B", prompt: "loose")
    _ = try addGroup(sbd, "Flags", bound.id)
    try setAccount(sbd, "Flags", "B")
    if loginGone { try removeLogin(sbd, "B") }

    let plan = try decode(AccountMove.self, sbd.sb("account", "move", "--json", "A", "--dry-run"))
    let result = try decode(AccountMove.self, sbd.sb("account", "move", "--json", "A"))

    #expect(plan.moved == [loose.id])
    #expect(plan.blocked.map(\.session) == [bound.id])
    #expect(plan.blocked.first?.reason.contains("Flags") == true, "\(plan.blocked)")
    #expect(result.moved == plan.moved)
    #expect(result.blocked.map(\.session) == plan.blocked.map(\.session))
    #expect(try sbd.get(bound.id).account == sbd.account("B"))
    #expect(try sbd.get(loose.id).account == sbd.account("A"))
  }

  // MARK: The move at the next launch

  @Test func aStoppedSessionMovedIntoTheGroupResumesUnderItsAccount() throws {
    let sbd = try instance()
    let s = try stoppedSession(sbd, on: "A")
    let old = try #require(accountTests.transcript(sbd, "A", s))
    _ = try addGroup(sbd)
    try setAccount(sbd, "Flags", "B")
    try sbd.sb("group", "move", s.id, "--to", "Flags")

    try sbd.sb("resume", s.id)
    try sbd.waitFor(s.id, "the resume") { $0.claudePid != nil }
    try sendAndWait(sbd, s)

    let copy = try #require(accountTests.transcript(sbd, "B", s))
    #expect((copy as NSString).lastPathComponent == (old as NSString).lastPathComponent)
    #expect(try sbd.get(s.id).account == sbd.account("B"))
    let moved = try events(sbd, s, "account-moved")
    #expect(moved.count == 1)
    #expect(moved.first?.data["from"]?.string == sbd.account("A"))
    #expect(moved.first?.data["to"]?.string == sbd.account("B"))
    let launch = try #require(lastLaunch(sbd, s))
    #expect(launch.account == sbd.account("B"))
    #expect(launch.args.contains("--resume \(s.claudeSessionId)"))
  }

  /// A running claude keeps its account. A send to the stopped session
  /// moves it and delivers the message, so a pending message does not block
  /// the move.
  @Test func aSessionRunningWhenTheAccountIsSetMovesAtItsNextLaunch() throws {
    let sbd = try instance()
    let s = try decode(SessionSummary.self, sbd.sb("new", "--json", "--prompt", "hello", sbd.work))
    try sbd.waitFor(s.id, "the first reply") { $0.lastReply == "Done: hello" }
    _ = try addGroup(sbd, "Flags", s.id)
    try setAccount(sbd, "Flags", "B")
    #expect(try sbd.get(s.id).account == sbd.account("A"))
    #expect(try events(sbd, s, "account-moved").isEmpty)

    try stop(sbd, s)
    try sendAndWait(sbd, s)

    #expect(try sbd.get(s.id).account == sbd.account("B"))
    #expect(try events(sbd, s, "account-moved").count == 1)
    let launch = try #require(lastLaunch(sbd, s))
    #expect(launch.account == sbd.account("B"))
    #expect(launch.args.contains("--resume \(s.claudeSessionId)"))
  }

  /// The occupant of the only slot is on screen, so sbd does not stop it to
  /// make room. The queued resume runs when the test stops it.
  @Test func aQueuedStartMovesWhenTheSlotFrees() throws {
    let sbd = try instance(["liveCap": 1])
    let s = try stoppedSession(sbd, on: "A")
    _ = try addGroup(sbd, "Flags", s.id)
    try setAccount(sbd, "Flags", "B")
    let (occupant, detach) = try liveCap.onScreenSession(sbd, name: "occupant")
    defer { detach() }
    try sbd.sb("resume", s.id)
    try liveCap.waitForQueued(sbd, s.id, cap: 1)
    #expect(try sbd.get(s.id).account == sbd.account("A"))

    try sbd.sb("stop", occupant.id)

    try sbd.waitFor(s.id, "the queued resume") { $0.claudePid != nil }
    #expect(try sbd.get(s.id).account == sbd.account("B"))
    #expect(try events(sbd, s, "account-moved").count == 1)
    #expect(lastLaunch(sbd, s)?.account == sbd.account("B"))
  }

  /// `followup-start` gives the follow-up its group's account before it
  /// launches, so the launch moves nothing.
  @Test func aFollowupMovedIntoTheGroupStartsUnderItsAccount() throws {
    let sbd = try instance()
    let repo = try sbd.makeRepo()
    let f = try add(sbd, ["prompt": "Fix the cache.", "account": "A"])
    #expect(f.account == sbd.account("A"))
    _ = try addGroup(sbd)
    try setAccount(sbd, "Flags", "B")
    try sbd.sb("group", "move", f.id, "--to", "Flags")

    _ = try sbd.client.call(
      "followup-start", ["session": .string(f.id), "path": .string(repo), "branch": "b1"], as: SessionSummary.self)

    try sbd.waitFor(f.id, "the follow-up's first turn") { $0.lastReply == "Done: Fix the cache." }
    #expect(try sbd.get(f.id).account == sbd.account("B"))
    #expect(lastLaunch(sbd, f)?.account == sbd.account("B"))
    #expect(try events(sbd, f, "account-move-skipped").isEmpty)
    #expect(try events(sbd, f, "account-moved").isEmpty)
  }

  /// A session stopped before its first prompt has no transcript, so the
  /// move changes only its account.
  @Test func aSessionWithoutATranscriptMovesByItsAccountAlone() throws {
    let sbd = try instance()
    let s = try decode(SessionSummary.self, sbd.sb("new", "--json", sbd.work))
    try sbd.waitFor(s.id, "the claude") { $0.claudePid != nil }
    try stop(sbd, s)
    #expect(accountTests.transcript(sbd, "A", s) == nil)
    _ = try addGroup(sbd, "Flags", s.id)
    try setAccount(sbd, "Flags", "B")

    try sendAndWait(sbd, s, "hello")

    #expect(try sbd.get(s.id).account == sbd.account("B"))
    let launch = try #require(lastLaunch(sbd, s))
    #expect(launch.account == sbd.account("B"))
    #expect(launch.args.contains("--session-id \(s.claudeSessionId)"))
    #expect(try events(sbd, s, "account-move-skipped").isEmpty)
  }

  // MARK: Leaving never moves

  enum Leaving: String, CaseIterable { case moveOut, clear, removeGroup }

  /// A session that leaves its group, or whose group's account goes,
  /// stays on the account it last ran under, not the active one.
  @Test(arguments: Leaving.allCases) func aSessionThatLeavesTheGroupStaysOnItsAccount(_ how: Leaving) throws {
    let sbd = try instance()
    let g = try addGroup(sbd)
    try setAccount(sbd, "Flags", "B")
    let s = try newInGroup(sbd, "Flags")
    #expect(s.group == g.id)
    #expect(s.account == sbd.account("B"))
    try sbd.waitFor(s.id, "the first reply") { $0.lastReply == "Done: hello" }
    try stop(sbd, s)

    switch how {
    case .moveOut: try sbd.sb("group", "move", s.id, "--ungrouped")
    case .clear: try sbd.sb("group", "account", "--json", "Flags", "--clear")
    case .removeGroup: try sbd.sb("group", "rm", "Flags")
    }
    try sendAndWait(sbd, s)

    #expect(try sbd.get(s.id).account == sbd.account("B"))
    #expect(lastLaunch(sbd, s)?.account == sbd.account("B"))
    #expect(try events(sbd, s, "account-moved").isEmpty)
  }

  // MARK: Moves that sbd skips

  /// The session launches under its own account, its
  /// conversation goes on, and an `account-move-skipped` event names the
  /// group's account and holds `cause` in its reason.
  func expectSkipped(_ sbd: Instance, _ s: SessionSummary, cause: String) throws {
    try sendAndWait(sbd, s)

    #expect(try sbd.get(s.id).account == sbd.account("A"))
    #expect(lastLaunch(sbd, s)?.account == sbd.account("A"))
    #expect(try events(sbd, s, "account-moved").isEmpty)
    let skipped = try #require(try events(sbd, s, "account-move-skipped").last)
    #expect(skipped.data["to"]?.string == sbd.account("B"))
    let reason = skipped.data["reason"]?.string ?? ""
    #expect(reason.contains(cause), "\(reason)")
  }

  @Test func aMoveToAnAccountThatLostItsLoginIsSkipped() throws {
    let sbd = try instance()
    let s = try stoppedSession(sbd, on: "A")
    _ = try addGroup(sbd)
    try setAccount(sbd, "Flags", "B")
    try removeLogin(sbd, "B")
    try sbd.sb("group", "move", s.id, "--to", "Flags")

    try expectSkipped(sbd, s, cause: sbd.account("B"))
  }

  /// B has no reading when the group's account is set, so the set is
  /// accepted. B then reads as signed out.
  @Test func aMoveToASignedOutAccountIsSkipped() throws {
    let fake = try FakeUsage()
    let sbd = try Instance.withUsage(fake, accounts: ["A", "B"])
    try sbd.signIn("A", token: "token-a")
    let s = try stoppedSession(sbd, on: "A")
    _ = try addGroup(sbd)
    try setAccount(sbd, "Flags", "B")
    #expect(try sbd.usage(of: "B").signedOut == true)
    try sbd.sb("group", "move", s.id, "--to", "Flags")

    try expectSkipped(sbd, s, cause: "/login")
  }

  @Test func aMoveToAnAccountThatHoldsAnotherTranscriptIsSkipped() throws {
    let sbd = try instance()
    let s = try stoppedSession(sbd, on: "A")
    let old = try #require(accountTests.transcript(sbd, "A", s))
    let folder = ((old as NSString).deletingLastPathComponent as NSString).lastPathComponent
    let dir = "\(sbd.account("B"))/projects/\(folder)"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try "{}\n".write(toFile: "\(dir)/\(s.claudeSessionId).jsonl", atomically: true, encoding: .utf8)
    _ = try addGroup(sbd)
    try setAccount(sbd, "Flags", "B")
    try sbd.sb("group", "move", s.id, "--to", "Flags")

    try expectSkipped(sbd, s, cause: "transcript")

    #expect(try String(contentsOfFile: "\(dir)/\(s.claudeSessionId).jsonl", encoding: .utf8) == "{}\n")
  }
}
