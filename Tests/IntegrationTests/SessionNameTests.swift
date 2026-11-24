import Foundation
import SwitchboardCore
import Testing

/// The config of an instance that names unnamed sessions. The prefix makes the auto branch easy to spot.
private let namesOn: [String: JSON] = ["sessionNames": ["enabled": true], "branchPrefix": "haacked/"]

private let namingPrompt = "Fix the login redirect"

private func summary(_ text: String) throws -> SessionSummary { try JSONCoding.decode(SessionSummary.self, from: text) }

extension Instance {
  /// How many naming calls the stub saw.
  fileprivate func sessionNameCalls() -> Int {
    let text = (try? String(contentsOfFile: "\(home.path)/session-name-calls.log", encoding: .utf8)) ?? ""
    return text.split(separator: "\n").count
  }

  /// The input of the last naming call that the stub saw.
  fileprivate func sessionNameInput() -> String {
    (try? String(contentsOfFile: "\(home.path)/session-name-input.txt", encoding: .utf8)) ?? ""
  }

  /// The arguments of the last naming call. `--tools ""` and `--setting-sources ""` are empty arguments, so empty
  /// fields count.
  fileprivate func sessionNameArguments() throws -> [String] {
    let text = try String(contentsOfFile: "\(home.path)/session-name-args", encoding: .utf8)
    return text.split(separator: "\0", omittingEmptySubsequences: false).dropLast().map(String.init)
  }

  /// Makes the stub answer each naming call with the name.
  fileprivate func answerSessionName(_ name: String) throws {
    try JSON.object(["name": .string(name)]).text.write(
      toFile: "\(home.path)/session-name-answer.json", atomically: true, encoding: .utf8)
  }

  fileprivate func sessionNameEvents(_ id: String) throws -> [Event] {
    try events(id).filter { $0.kind == "session-name" }
  }

  /// The session's `session-name` event, once one exists.
  fileprivate func waitForSessionNameEvent(_ id: String) throws -> Event {
    try waitFor("the session-name event of \(id)", fetch: { try sessionNameEvents(id).first }, until: { _ in true })
  }

  /// The `session-name` events of every session, removed ones included.
  fileprivate func allSessionNameEvents() throws -> [Event] {
    try client.call("events", ["limit": 10_000, "full": true], as: [Event].self).filter { $0.kind == "session-name" }
  }

  /// The id that `sb get <key>` resolves.
  fileprivate func idOf(_ key: String) throws -> String { try summary(try sb("get", key, "--json")).id }

  /// Starts an unnamed session with a prompt in `work` and waits until its naming call answered. A call that an
  /// earlier request queued by mistake runs before this one, so the stub has logged it by then.
  fileprivate func startControlSession() throws -> SessionSummary {
    let control = try client.call("new", ["path": .string(work), "prompt": "Add dark mode"], as: SessionSummary.self)
    _ = try waitForSessionNameEvent(control.id)
    return control
  }
}

/// An unnamed work session with a prompt gets a short name from Haiku after it starts. The branch and the worktree
/// keep theirs.
@Suite(.blocking(timeLimit: .seconds(180))) struct SessionNameTests {
  @Test func aWorktreeSessionGetsTheModelsNameAndKeepsItsBranchAndFolder() throws {
    let sbd = try Instance(config: namesOn)
    let repo = try sbd.makeRepo("widgets", origin: "https://github.com/acme/widgets.git")
    try sbd.answerSessionName("fix-login-redirect")

    let s = try summary(try sbd.sb("new", repo, "--worktree", "--prompt", namingPrompt, "--json"))

    let branch = try #require(s.branch)
    #expect(branch.hasPrefix("haacked/session"))
    #expect(s.name == branch)
    let named = try sbd.waitFor(s.id, "the model's name") { $0.name == "fix-login-redirect" }
    #expect(named.branch == branch)
    #expect(named.cwd == s.cwd)
    #expect(try sbd.git(named.cwd, "branch", "--show-current") == branch)
    #expect(try sbd.idOf("fix-login-redirect") == s.id)
    let event = try sbd.waitForSessionNameEvent(s.id)
    #expect(event.data["name"]?.string == "fix-login-redirect")
    #expect(event.data["from"]?.string == s.name)
    #expect(headlessUsage(event.data["usage"]) == stubUsage)
    #expect(event.data["model"]?.string == "claude-haiku-5-5")
    let row = try sbd.waitForHeadlessUsageRow("sessionName", calls: 1)
    #expect(row["errors"]?.int == 0)
    #expect(row["models"]?.array?.compactMap(\.string) == ["claude-haiku-5-5"])
  }

  /// The call runs the configured model with no tools. A folder outside git has no repository or branch, so the
  /// input holds only the prompt.
  @Test func aFolderOutsideGitSendsOnlyThePromptToTheConfiguredModel() throws {
    let sbd = try Instance(config: ["sessionNames": ["enabled": true, "model": "haiku"]])

    let s = try sbd.client.call(
      "new", ["path": .string(sbd.work), "prompt": .string(namingPrompt)], as: SessionSummary.self)
    _ = try sbd.waitForSessionNameEvent(s.id)

    #expect(try sbd.sessionNameArguments() == SessionNamer.arguments(model: "haiku"))
    #expect(
      sbd.sessionNameInput() == SessionNamer.input(prompt: namingPrompt, repository: nil, branch: nil, issue: nil))
  }

  /// The folder's own branch and the session's issue go with the prompt. An issue without a repository takes the
  /// folder's.
  @Test func aSessionWithoutAWorktreeSendsTheFoldersBranchAndItsIssue() throws {
    let sbd = try Instance(config: namesOn)
    let repo = try sbd.makeRepo("widgets", origin: "https://github.com/acme/widgets.git")
    try sbd.git(repo, "switch", "-q", "-c", "feature/login-page")
    try sbd.answerSessionName("fix-login-redirect")

    let s = try sbd.client.call(
      "new", ["path": .string(repo), "prompt": .string(namingPrompt), "issue": ["number": 42]],
      as: SessionSummary.self)

    #expect(s.cwd == repo)
    _ = try sbd.waitFor(s.id, "the model's name") { $0.name == "fix-login-redirect" }
    #expect(
      sbd.sessionNameInput()
        == SessionNamer.input(
          prompt: namingPrompt, repository: "acme/widgets", branch: "feature/login-page", issue: "acme/widgets#42"))
  }

  /// An empty branch is no branch that the caller chose, so the session still gets a name.
  @Test func anEmptyBranchStillGetsAName() throws {
    let sbd = try Instance(config: namesOn)
    let repo = try sbd.makeRepo("widgets", origin: "https://github.com/acme/widgets.git")

    let s = try sbd.client.call(
      "new", ["path": .string(repo), "branch": "", "prompt": .string(namingPrompt)], as: SessionSummary.self)

    _ = try sbd.waitFor(s.id, "the stub's name") { $0.name == "stub-session-name" }
  }
}

// MARK: - The start doesn't wait for the call

extension SessionNameTests {
  @Test func newReturnsTheFallbackAndClaudeRepliesWhileTheAnswerIsHeld() throws {
    let sbd = try Instance(config: namesOn)
    let repo = try sbd.makeRepo("widgets", origin: "https://github.com/acme/widgets.git")
    sbd.hold("hold-session-name")

    let s = try summary(try sbd.sb("new", repo, "--worktree", "--prompt", namingPrompt, "--json"))

    #expect(s.name == s.branch)
    try sbd.waitFor(s.id, "the first reply") { $0.lastReply == "Done: \(namingPrompt)" }
    try sbd.waitFor("the naming call") { sbd.sessionNameCalls() == 1 }
    #expect(try sbd.sessionNameEvents(s.id).isEmpty)
    #expect(try sbd.get(s.id).name == s.name)
    try sbd.release("hold-session-name")
    _ = try sbd.waitFor(s.id, "the stub's name") { $0.name == "stub-session-name" }
  }
}

// MARK: - Requests that make no call

extension SessionNameTests {
  /// Each request that names the session, chooses a branch, or has no prompt keeps its name and makes no call.
  /// That covers `sb new --name`, `sb new --branch`, and `sb spawn`, which always passes a branch. A control session
  /// started after them makes the one call that the stub sees.
  @Test func aRequestThatNamesTheSessionOrItsBranchOrHasNoPromptMakesNoCall() throws {
    let repos = try Repos()
    try repos.make("acme/widgets")
    let sbd = try Instance(config: namesOn.merging(["repoRoots": [.string(repos.root)]]) { $1 })
    let repo = try sbd.makeRepo("widgets", origin: "https://github.com/acme/widgets.git")
    let shapes: [[String: JSON]] = [
      ["name": "mine"], ["name": ""], ["branch": "feature-x"], ["branch": "feature-y", "worktree": true],
      ["prompt": ""], ["prompt": "  \n\t"], ["prompt": .null],
    ]
    var started: [SessionSummary] = []
    for shape in shapes {
      let args = (["path": .string(repo), "prompt": .string(namingPrompt)] as [String: JSON]).merging(shape) { $1 }
      started.append(try sbd.client.call("new", args.filter { $0.value != .null }, as: SessionSummary.self))
    }
    started.append(
      try summary(try sbd.sb("new", repo, "--worktree", "--name", "Mine", "--prompt", namingPrompt, "--json")))
    started.append(try summary(try sbd.sb("new", repo, "--branch", "feature-z", "--prompt", namingPrompt, "--json")))
    started.append(
      try summary(
        try sbd.sb("spawn", "--json", "--repo", "acme/widgets", "--branch", "kid", "--prompt", namingPrompt)))

    _ = try sbd.startControlSession()

    #expect(sbd.sessionNameCalls() == 1)
    for s in started {
      #expect(try sbd.sessionNameEvents(s.id).isEmpty, "\(s.name)")
      #expect(try sbd.get(s.id).name == s.name)
    }
  }
}

// MARK: - Failures keep the fallback

extension SessionNameTests {
  /// FAIL-NAME exits 1, SLOW-NAME outlasts a 1 s timeout, and BAD-NAME answers a name that `validate` refuses.
  @Test func aFailedCallKeepsTheFallbackAndRecordsAnError() throws {
    let sbd = try Instance(config: ["sessionNames": ["enabled": true, "timeoutSeconds": 1]])

    let started = try ["FAIL-NAME", "SLOW-NAME", "BAD-NAME"].map { marker in
      try sbd.client.call(
        "new", ["path": .string(sbd.work), "prompt": .string("Handle \(marker) now")], as: SessionSummary.self)
    }

    for s in started {
      let event = try sbd.waitForSessionNameEvent(s.id)
      #expect(event.data["error"]?.string?.isEmpty == false, "\(event.data)")
      #expect(event.data["name"] == nil)
      #expect(try sbd.get(s.id).name == s.name)
    }
    let row = try sbd.waitForHeadlessUsageRow("sessionName", calls: 3)
    #expect(row["errors"]?.int == 3)
  }
}

// MARK: - Renames and removals before the answer (Risk 1)

extension SessionNameTests {
  /// A rename keeps its name, and so does a rename back to the fallback, because the user touched it.
  @Test func aRenameBeforeTheAnswerIsKept() throws {
    let sbd = try Instance(config: namesOn)
    sbd.hold("hold-session-name")
    let renamed = try sbd.client.call(
      "new", ["path": .string(sbd.work), "prompt": .string(namingPrompt)], as: SessionSummary.self)
    let renamedBack = try sbd.client.call(
      "new", ["path": .string(sbd.work), "prompt": .string(namingPrompt)], as: SessionSummary.self)
    try sbd.waitFor("the naming calls") { sbd.sessionNameCalls() == 2 }

    try sbd.sb("rename", renamed.id, "mine")
    try sbd.sb("rename", renamedBack.id, "other")
    try sbd.sb("rename", renamedBack.id, renamedBack.name)
    try sbd.release("hold-session-name")

    for (s, name) in [(renamed, "mine"), (renamedBack, renamedBack.name)] {
      let event = try sbd.waitForSessionNameEvent(s.id)
      #expect(event.data["skipped"]?.string == "renamed")
      #expect(try sbd.get(s.id).name == name)
    }
  }

  @Test func aRemovalBeforeTheAnswerLeavesSbdHealthyAndRecordsNoEvent() throws {
    let sbd = try Instance(config: namesOn)
    sbd.hold("hold-session-name")
    let s = try sbd.client.call(
      "new", ["path": .string(sbd.work), "prompt": .string(namingPrompt)], as: SessionSummary.self)
    try sbd.waitFor("the naming call") { sbd.sessionNameCalls() == 1 }

    try sbd.sb("rm", s.id)
    try sbd.waitFor("the removal") { try !sbd.client.sessions().contains { $0.id == s.id } }
    try sbd.release("hold-session-name")
    let control = try sbd.startControlSession()

    #expect(try sbd.allSessionNameEvents().allSatisfy { $0.session != s.id })
    #expect(try sbd.listedIds().contains(control.id))
    #expect(try !sbd.client.sessions().contains { $0.id == s.id })
  }
}

// MARK: - Duplicate answers (Risk 2)

extension SessionNameTests {
  /// Both answers apply on the state queue one after the other, and `sb get` resolves each name to its session.
  @Test func twoSessionsWithTheSameAnswerGetTheNameAndTwo() throws {
    let sbd = try Instance(config: namesOn)
    try sbd.answerSessionName("fix-login-redirect")

    let a = try sbd.client.call(
      "new", ["path": .string(sbd.work), "prompt": .string(namingPrompt)], as: SessionSummary.self)
    let b = try sbd.client.call(
      "new", ["path": .string(sbd.work), "prompt": "Fix the login redirect again"], as: SessionSummary.self)
    _ = try sbd.waitForSessionNameEvent(a.id)
    _ = try sbd.waitForSessionNameEvent(b.id)

    let names = Set([try sbd.get(a.id).name, try sbd.get(b.id).name])
    #expect(names == ["fix-login-redirect", "fix-login-redirect-2"])
    let first = try sbd.idOf("fix-login-redirect")
    let second = try sbd.idOf("fix-login-redirect-2")
    #expect(Set([first, second]) == [a.id, b.id])
  }
}

// MARK: - Outbound text (Risk 3)

extension SessionNameTests {
  /// The remote URL carries a token, and the paths name the user's folders. Only the prompt and owner/name leave.
  /// A worktree's branch is the auto branch, which tells the model nothing, so it is not sent either.
  @Test func theInputHoldsThePromptAndOwnerNameAndNoPathTokenOrAutoBranch() throws {
    let sbd = try Instance(config: namesOn)
    let remote = "https://user:secret-token@github.com/acme/widgets.git"
    let repo = try sbd.makeRepo("widgets", origin: remote)

    let s = try summary(try sbd.sb("new", repo, "--worktree", "--prompt", namingPrompt, "--json"))
    _ = try sbd.waitForSessionNameEvent(s.id)

    let input = sbd.sessionNameInput()
    #expect(
      input == SessionNamer.input(prompt: namingPrompt, repository: "acme/widgets", branch: nil, issue: nil),
      "\(input)")
    for leak in [
      "secret-token", "user:", "github.com", remote, sbd.home.path, real(sbd.home.path), repo, s.cwd, real(s.cwd),
      NSHomeDirectory(), s.id, s.claudeSessionId, try #require(s.branch),
    ] {
      #expect(!input.contains(leak), "the input holds \(leak): \(input)")
    }
    let args = try sbd.sessionNameArguments().joined(separator: " ")
    for leak in ["secret-token", sbd.home.path, real(sbd.home.path), s.cwd, s.id] {
      #expect(!args.contains(leak), "the arguments hold \(leak)")
    }
  }
}
