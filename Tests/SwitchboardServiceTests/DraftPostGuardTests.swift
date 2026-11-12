import Foundation
import SwitchboardCore
import Testing

@testable import SwitchboardService

private let session = "s1"
private let other = "s2"
private let commentURL = "https://github.com/acme/widgets/pull/42#discussion_r1001"
private let draftText = "Good catch, fixed."
/// The item's ref: the session's card is event 2.
private let cardRef = "summary:2"

/// A gh that answers every call with a created comment and logs each call's
/// arguments to `gh-calls.log` beside it. config.json names it, so a test
/// never reaches the real gh.
private let fakeGh = """
  #!/bin/sh
  printf '%s\\n' "$*" >>"$(dirname "$0")/gh-calls.log"
  printf '%s\\n' '{"id": 5001, "html_url": "https://github.com/acme/widgets/pull/42#discussion_r5001"}'
  """

/// The facts of a session whose card has one draft that replies to review
/// comment 1001 on acme/widgets#42, which gh resolved, while the session's
/// PR is that PR. The draft is `ready`. The events end at `now`, so the
/// session is not stale.
private func readyFacts(now: Int64) throws -> SessionFacts {
  let card = TriageSummary(
    title: "Post the reply", kind: .decision, summary: "Drafted a reply to ann.\nPost it when it reads right.",
    drafts: [TriageDraft(label: "Reply to ann", text: draftText, replyTo: commentURL)])
  let target = ResolvedTarget(
    target: ReplyTarget(repo: "acme/widgets", pr: 42, kind: .reviewComment, id: 1001), root: 1001, author: "ann",
    path: "a.swift", line: 3, excerpt: "Why not use a guard?", url: commentURL)
  // A draft PR whose checks run, so no PR rule decides the session's state.
  let pr = PullRequest(
    id: "PR_42", number: 42, url: "https://github.com/acme/widgets/pull/42", repo: "acme/widgets", draft: true,
    checks: "PENDING")
  var facts = SessionFacts()
  for event in [
    Event(id: 1, session: session, t: now - 4, kind: "UserPromptSubmit", data: ["prompt": "go"]),
    Event(id: 2, session: session, t: now - 3, kind: "summary", data: try JSON(encoding: card)),
    Event(
      id: 3, session: session, t: now - 2, kind: "Stop", data: ["last_assistant_message": "I drafted a reply to ann."]),
    Event(
      id: 4, session: session, t: now - 1, kind: DraftReplies.targetEvent,
      data: try DraftReplies.targetData(ref: cardRef, number: 1, .resolved(target))),
    Event(id: 5, session: session, t: now, kind: "pr", data: ["pr": try JSON(encoding: pr)]),
  ] {
    facts.apply(event)
  }
  return facts
}

/// The pids in this test process's ancestry. A pane with one of them holds the test process.
private func ancestry() throws -> Set<Int> {
  try #require(Processes.ancestors(of: Int(getpid())))
}

/// Two pids outside this process's ancestry, for panes that hold no caller.
private func outsidePids() throws -> (Int, Int) {
  let mine = try ancestry()
  let free = (4242...9999).filter { !mine.contains($0) }
  return (free[0], free[1])
}

private func live(_ pid: Int) -> PaneRow { PaneRow(pid: pid, dead: false, clients: 0) }

/// A `Service` in a temporary home with two work sessions. s1 has a ready
/// draft. Each pane runs a pid outside the test's ancestry. The service never
/// loads, so it starts no tmux server and no claude. config.json points gh at
/// `fakeGh` and claude at /usr/bin/false.
private func withSessions(_ body: (Service, Home) throws -> Void) throws {
  let home = Home(path: try makeShortTempFolder())
  defer { try? FileManager.default.removeItem(atPath: home.path) }
  let gh = "\(home.path)/gh"
  try fakeGh.write(toFile: gh, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gh)
  let config: JSON = ["claude": "/usr/bin/false", "github": ["gh": .string(gh), "pollSeconds": 0]]
  try config.text.write(toFile: home.config, atomically: true, encoding: .utf8)
  let service = try Service(home: home, sbPath: "/usr/bin/true")
  let facts = try readyFacts(now: Int64(Date().timeIntervalSince1970 * 1000))
  let (first, second) = try outsidePids()
  try service.queue.sync {
    for id in [session, other] {
      let s = Session(id: id, name: id, cwd: home.path, claudeSessionId: "uuid-\(id)", created: 0)
      try service.store.save(s)
      var entry = Service.Entry(session: s)
      if id == session { entry.facts = facts }
      service.entries[id] = entry
      service.snapshot.panes[service.paneName(id, .claude)] = live(first)
      service.snapshot.panes[service.paneName(id, .shell)] = live(second)
    }
    // `draft-post` builds a snapshot from tmux, which has no server here. That snapshot is older than this one,
    // so `install` keeps these panes.
    service.snapshot.taken = .max
  }
  try body(service, home)
}

private func postRequest(text: String = draftText) -> Request {
  Request(
    op: "draft-post",
    args: ["session": .string(session), "ref": .string(cardRef), "draft": 1, "text": .string(text)])
}

/// The refusal that sbd sends a caller that runs below a pane of session `id`.
private func refusal(_ id: String) -> String {
  "`sb draft post` runs inside \(id). Posting needs your click, so run it from a terminal outside the sessions."
}

/// The refusal that sbd sends a caller that runs below its tmux server and outside every pane.
private let serverRefusal =
  "`sb draft post` runs in sbd's tmux server, where the sessions run. Posting needs your click, so run it from a terminal outside the sessions."

/// The gh calls that `fakeGh` logged.
private func ghCalls(_ home: Home) -> [String] {
  let text = (try? String(contentsOfFile: "\(home.path)/gh-calls.log", encoding: .utf8)) ?? ""
  return text.split(separator: "\n").map(String.init)
}

/// Requires that nothing was recorded or posted: no event in the store for
/// s1, no event folded into its facts, and no gh call.
private func expectNothingDone(_ service: Service, _ home: Home) throws {
  #expect(try service.store.events(session: session).isEmpty)
  #expect(service.queue.sync { service.entries[session]!.events } == 0)
  #expect(ghCalls(home).isEmpty, "\(ghCalls(home))")
}

/// sbd refuses `draft-post` from a socket client whose ancestry overlaps
/// the live Claude or shell pane of any session, or whose ancestry it can't
/// read. A refusal records nothing and runs no gh.
@Suite(.timeLimit(.minutes(1))) struct DraftPostGuardTests {
  @Test func theDraftIsReadyBeforeAnyPost() throws {
    try withSessions { service, _ in
      let post = service.queue.sync { service.summary(session).triage?.drafts.first?.post }

      guard case .ready = post else {
        Issue.record("the draft is \(String(describing: post)), not ready")
        return
      }
    }
  }

  /// The pane's pid is this process's parent, so this process runs below that pane.
  @Test(arguments: [(Pane.claude, session), (.shell, session), (.claude, other), (.shell, other)])
  func aCallerBelowAPaneOfAnySessionIsRefused(_ pane: Pane, _ owner: String) throws {
    try withSessions { service, home in
      service.queue.sync { service.snapshot.panes[service.paneName(owner, pane)] = live(Int(getppid())) }

      let response = service.handle(postRequest(), caller: .client(pid: Int(getpid())))

      #expect(response.ok == false)
      #expect(response.error == refusal(owner), "\(String(describing: response.error))")
      try expectNothingDone(service, home)
    }
  }

  /// The caller is the pane's own process, as `exec sb draft post` in the shell pane makes it.
  @Test func aCallerThatIsAPanesProcessIsRefused() throws {
    try withSessions { service, home in
      service.queue.sync { service.snapshot.panes[service.paneName(session, .shell)] = live(Int(getpid())) }

      let response = service.handle(postRequest(), caller: .client(pid: Int(getpid())))

      #expect(response.error == refusal(session), "\(String(describing: response.error))")
      try expectNothingDone(service, home)
    }
  }

  /// A session that runs `tmux new-session` or `tmux new-window` starts a
  /// program below sbd's tmux server and outside every pane that sbd names.
  /// The server is this process's parent here, and the new pane holds a pid
  /// outside this process's ancestry.
  @Test func aCallerBelowTheTmuxServerIsRefused() throws {
    try withSessions { service, home in
      let (outside, _) = try outsidePids()
      service.queue.sync {
        service.snapshot.panes["opened-by-a-session"] = PaneRow(
          pid: outside, dead: false, clients: 0, server: Int(getppid()))
      }

      let response = service.handle(postRequest(), caller: .client(pid: Int(getpid())))

      #expect(response.ok == false)
      #expect(response.error == serverRefusal, "\(String(describing: response.error))")
      try expectNothingDone(service, home)
    }
  }

  /// Every pane names the same server, which is not in this process's ancestry.
  @Test func aServerOutsideTheCallersAncestryDoesNotRefuseIt() throws {
    try withSessions { service, home in
      let (outside, _) = try outsidePids()
      service.queue.sync {
        for name in service.snapshot.panes.keys { service.snapshot.panes[name]?.server = outside }
      }

      let response = service.handle(postRequest(), caller: .client(pid: Int(getpid())))

      #expect(response.ok, "\(String(describing: response.error))")
      #expect(ghCalls(home).filter { $0.hasPrefix("api -X POST") }.count == 1, "\(ghCalls(home))")
    }
  }

  /// gh can't take an argument with a NUL. Foundation's Process would end
  /// sbd on one, so sbd refuses the text before it records the attempt. A
  /// NUL before a combining mark is one Character with the mark.
  @Test(arguments: ["Good\u{0}catch.", "\u{0}", "Good catch.\u{0}\u{301}"])
  func aTextWithANulIsRefused(_ text: String) throws {
    try withSessions { service, home in
      let response = service.handle(postRequest(text: text), caller: .inProcess)

      #expect(response.ok == false)
      #expect(response.error?.contains("NUL") == true, "\(String(describing: response.error))")
      try expectNothingDone(service, home)
    }
  }

  /// sbd can't show that such a caller runs outside every session, so it
  /// refuses. `Int32.max` passes `Processes.isValidPid` and names no process.
  @Test(arguments: [nil, 0, Int(Int32.max)] as [Int?])
  func aCallerWhosePidCantBeReadIsRefused(_ pid: Int?) throws {
    try withSessions { service, home in
      let response = service.handle(postRequest(), caller: .client(pid: pid))

      #expect(response.ok == false)
      let error = response.error ?? ""
      #expect(error.contains("can't tell"), "\(error)")
      #expect(error.contains("`sb draft post`"), "\(error)")
      try expectNothingDone(service, home)
    }
  }

  /// A dead pane keeps its last pid in tmux, and that pid no longer runs the pane.
  @Test func aDeadPaneDoesNotRefuseTheCaller() throws {
    try withSessions { service, home in
      service.queue.sync {
        service.snapshot.panes[service.paneName(other, .shell)] = PaneRow(
          pid: Int(getppid()), dead: true, clients: 0)
      }

      let response = service.handle(postRequest(), caller: .client(pid: Int(getpid())))

      #expect(response.ok, "\(String(describing: response.error))")
      #expect(ghCalls(home).filter { $0.hasPrefix("api -X POST") }.count == 1, "\(ghCalls(home))")
    }
  }

  @Test func aCallerOutsideEverySessionPosts() throws {
    try withSessions { service, home in
      let response = service.handle(postRequest(), caller: .client(pid: Int(getpid())))

      #expect(response.ok, "\(String(describing: response.error))")
      #expect(ghCalls(home).filter { $0.hasPrefix("api -X POST") }.count == 1, "\(ghCalls(home))")
    }
  }

  /// sbd itself, or a test that calls `handle` directly, has no ancestry to check.
  @Test func anInProcessCallerPosts() throws {
    try withSessions { service, home in
      let response = service.handle(postRequest(), caller: .inProcess)

      #expect(response.ok, "\(String(describing: response.error))")
      #expect(ghCalls(home).filter { $0.hasPrefix("api -X POST") }.count == 1, "\(ghCalls(home))")
    }
  }

  /// A failed attempt outranks the live PR check, so the item still shows
  /// `failed` after the session's PR changes or drops out. The post must
  /// still name the session's current PR, so sbd refuses it and runs no gh.
  @Test(arguments: [7, nil] as [Int?])
  func aFailedDraftWhosePRChangedIsRefused(_ number: Int?) throws {
    try withSessions { service, home in
      let target = ResolvedTarget(
        target: ReplyTarget(repo: "acme/widgets", pr: 42, kind: .reviewComment, id: 1001), root: 1001,
        author: "ann", path: "a.swift", line: 3, excerpt: "Why not use a guard?", url: commentURL)
      let now = Int64(Date().timeIntervalSince1970 * 1000)
      let attempt: [String: JSON] = ["ref": .string(cardRef), "number": 1]
      service.queue.sync {
        var facts = service.entries[session]!.facts
        facts.apply(
          Event(
            id: 6, session: session, t: now, kind: "draft_posting",
            data: .object(
              attempt.merging([
                "target": try! JSON(encoding: target), "root": 1001, "text": .string(draftText),
                "draftText": .string(draftText),
              ]) { $1 })))
        facts.apply(
          Event(
            id: 7, session: session, t: now, kind: "draft_post_failed",
            data: .object(attempt.merging(["error": "gh: Bad credentials (HTTP 401)"]) { $1 })))
        facts.pr = number.map {
          PullRequest(
            id: "PR_\($0)", number: $0, url: "https://github.com/acme/widgets/pull/\($0)", repo: "acme/widgets",
            draft: true, checks: "PENDING")
        }
        service.entries[session]!.facts = facts
      }

      let response = service.handle(postRequest(), caller: .inProcess)

      #expect(response.ok == false, "\(String(describing: response.result))")
      #expect(ghCalls(home).isEmpty, "\(ghCalls(home))")
    }
  }

  /// `draft-check` changes no GitHub state, so a caller inside a session may run it.
  @Test func draftCheckIsNotRefusedInsideASession() throws {
    try withSessions { service, _ in
      service.queue.sync { service.snapshot.panes[service.paneName(session, .claude)] = live(Int(getppid())) }

      let response = service.handle(
        Request(op: "draft-check", args: ["session": .string(session), "draft": 1]),
        caller: .client(pid: Int(getpid())))

      #expect(response.ok, "\(String(describing: response.error))")
    }
  }
}
