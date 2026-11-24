import Foundation
import SwitchboardCore
import Testing

/// `sb link add` and `sb link rm`, and the `link-add` and `link-rm` requests behind them. The user adds and removes
/// any link on any session, and hides a link that sbd found. Claude adds links only to its own session and removes
/// only the links that Claude added. Every reader lists the found links that are not hidden, then the added ones,
/// ordered by time.
@Suite(.blocking(timeLimit: .seconds(180))) struct SessionLinkEditTests {
  static let rfc = "https://example.com/rfcs/flag-evaluations"
  static let doc = "https://example.com/docs/cache-design"
  static let linear = "https://linear.app/example/issue/ENG-123"

  /// The environment of a command that Claude runs inside the session.
  func inside(_ id: String) -> [String: String] { ["SB_SESSION_ID": id, "CLAUDECODE": "1"] }

  /// The session summary that `sb link add --json` prints.
  @discardableResult
  func linkAdd(_ sbd: Instance, _ session: String, _ url: String, title: String? = nil, env: [String: String] = [:])
    throws -> JSON
  {
    let flag = title.map { ["--title", $0] } ?? []
    return try #require(JSON.parse(try sbd.sb(["link", "add", "--json", session, url] + flag, env: env)))
  }

  /// The session summary that `sb link rm --json` prints.
  @discardableResult
  func linkRm(_ sbd: Instance, _ session: String, _ link: String, env: [String: String] = [:]) throws -> JSON {
    try #require(JSON.parse(try sbd.sb(["link", "rm", "--json", session, link], env: env)))
  }

  /// The `links` of `sb get --json`, or an empty list when the key is missing.
  func links(_ sbd: Instance, _ id: String) throws -> [JSON] { try sbd.sessionLinks(id) ?? [] }

  func urls(_ links: [JSON]) -> [String] { links.compactMap { $0["url"]?.string } }

  /// The id of the listed link with `url`.
  func linkId(_ sbd: Instance, _ session: String, _ url: String) throws -> String {
    try #require(try links(sbd, session).first { $0["url"]?.string == url }?["id"]?.string, "no link to \(url)")
  }

  /// A raw `link-add` by Claude from inside the session itself, which returns the session summary.
  @discardableResult
  func claudeAdds(_ sbd: Instance, _ session: String, _ url: String) throws -> JSON {
    try sbd.client.call(
      "link-add", ["session": .string(session), "url": .string(url), "by": "claude", "caller": .string(session)])
  }

  // MARK: add

  @Test func addListsAWebLinkByYouWithItsTitle() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "flags-cache")

    let summary = try linkAdd(sbd, s.id, "https://example.com/rfc", title: "Flag RFC")

    let listed = try #require(summary["links"]?.array)
    let link = try #require(listed.first)
    #expect(listed.count == 1)
    #expect(link["id"]?.string?.hasPrefix("l") == true)
    #expect(link["url"]?.string == "https://example.com/rfc")
    #expect(link["kind"]?.string == "web")
    #expect(link["by"]?.string == "you")
    #expect(link["title"]?.string == "Flag RFC")
    #expect(link["channel"] == nil)
    #expect(try sbd.sessionLinks(s.id) == listed)
  }

  @Test func addOfASlackLinkGetsItsKindAndThread() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "flags-cache")

    let summary = try linkAdd(sbd, s.id, SlackExample.reply)

    let link = try #require(summary["links"]?.array?.first)
    #expect(link["kind"]?.string == "slack")
    #expect(link["channel"]?.string == SlackExample.channel)
    #expect(link["thread"]?.string == SlackExample.rootTs)
    #expect(link["by"]?.string == "you")
  }

  @Test func addRefusesATitleOverTheLimitAndAddsNothing() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "flags-cache")
    let title = String(repeating: "a", count: ExternalLink.titleLimit + 1)

    let r = try sbd.run(["link", "add", "--json", s.id, Self.rfc, "--title", title])

    #expect(r.status != 0)
    #expect(r.stderr.contains("\(ExternalLink.titleLimit)"), "\(r.stderr)")
    #expect(try sbd.sessionLinks(s.id) == nil)
  }

  /// One sbd takes every URL, so the list costs one instance. Each expectation names its URL.
  @Test func addRefusesAURLThatIsNotHTTP() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "flags-cache")

    for url in GroupLinkTests.refusedURLs {
      let message = failure(sbd, "link-add", ["session": .string(s.id), "url": .string(url), "by": "you"])
      #expect(message != "no error", "\(url)")
    }

    #expect(try sbd.sessionLinks(s.id) == nil)
  }

  @Test func addRefusesAURLWithAUserOrPasswordPartWithItsReason() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "flags-cache")

    let r = try sbd.run(["link", "add", "--json", s.id, "https://example.slack.com@evil.example/archives/C0/p1"])

    #expect(r.status != 0)
    #expect(r.stderr.contains("user name or password"), "\(r.stderr)")
    #expect(try sbd.sessionLinks(s.id) == nil)
  }

  @Test func addRefusesTheURLOfAFoundLink() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "flags-cache")
    try sbd.postPromptHook(s.id, prompt: "Review \(SlackExample.root)")
    let before = try links(sbd, s.id)
    let id = try linkId(sbd, s.id, SlackExample.root)

    let r = try sbd.run(["link", "add", "--json", s.id, SlackExample.root, "--title", "Thread"])

    #expect(r.status != 0)
    #expect(r.stderr.contains("flags-cache already has a link to \(SlackExample.root) (\(id))"), "\(r.stderr)")
    #expect(try links(sbd, s.id) == before)
  }

  @Test func addRefusesTheURLOfAnAddedLink() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "flags-cache")
    try linkAdd(sbd, s.id, Self.rfc, title: "First")
    let before = try links(sbd, s.id)

    let r = try sbd.run(["link", "add", "--json", s.id, Self.rfc, "--title", "Second"])
    let artifact = try sbd.run(["link", "add", "--json", s.id, "\(artifactPageURL)#top"])
    let again = try sbd.run(["link", "add", "--json", s.id, "\(artifactPageURL)?tab=preview"])

    #expect(r.status != 0)
    #expect(r.stderr.contains("already has a link"), "\(r.stderr)")
    #expect(artifact.status == 0, "\(artifact.stderr)")
    #expect(again.status != 0, "a second form of the same artifact was added")
    #expect(try links(sbd, s.id).compactMap { $0["title"]?.string } == ["First", artifactPageURL])
    #expect(try links(sbd, s.id).first == before.first)
  }

  // MARK: rm

  @Test func rmDeletesAnAddedLink() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "flags-cache")
    try linkAdd(sbd, s.id, Self.rfc)
    try linkAdd(sbd, s.id, Self.doc)
    let id = try linkId(sbd, s.id, Self.rfc)

    let summary = try linkRm(sbd, s.id, id)

    #expect(urls(summary["links"]?.array ?? []) == [Self.doc])
    #expect(urls(try links(sbd, s.id)) == [Self.doc])
  }

  @Test func rmOfTheLastAddedLinkLeavesNoLinksKey() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "flags-cache")
    try linkAdd(sbd, s.id, Self.rfc)

    let summary = try linkRm(sbd, s.id, try linkId(sbd, s.id, Self.rfc))

    #expect(summary["links"] == nil)
    #expect(try sbd.sessionLinks(s.id) == nil)
  }

  /// Done when: a hidden found link stays hidden after a restart, and the other found link keeps its id.
  @Test func rmHidesAFoundLinkAndItStaysHiddenAfterARestart() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "flags-cache")
    try sbd.postPromptHook(s.id, prompt: "Review \(SlackExample.root) and \(Self.linear)")
    let kept = try #require(try links(sbd, s.id).first { $0["url"]?.string == Self.linear })
    let hidden = try linkId(sbd, s.id, SlackExample.root)

    let summary = try linkRm(sbd, s.id, hidden)
    sbd.stopSbd()
    try sbd.startSbd()

    #expect(summary["links"]?.array == [kept])
    #expect(try sbd.sessionLinks(s.id) == [kept])
  }

  /// The hidden URL is the reply's. The thread's root link has the same page, so the found link stays hidden.
  @Test func aHiddenLinkStaysHiddenWhenAPromptNamesItsThreadAgain() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "flags-cache")
    try sbd.postPromptHook(s.id, prompt: "Review \(SlackExample.reply)")
    try linkRm(sbd, s.id, try linkId(sbd, s.id, SlackExample.reply))

    try sbd.postPromptHook(s.id, prompt: "And the thread is \(SlackExample.root)")
    try sbd.postPromptHook(s.id, prompt: "Again \(SlackExample.reply)")

    #expect(try sbd.sessionLinks(s.id) == nil)
  }

  @Test func addOfAHiddenLinksURLUnhidesItWithItsId() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "flags-cache")
    try sbd.postPromptHook(s.id, prompt: "Review \(SlackExample.root)")
    let before = try links(sbd, s.id)
    try linkRm(sbd, s.id, try linkId(sbd, s.id, SlackExample.root))

    let summary = try linkAdd(sbd, s.id, SlackExample.root, title: "Ignored")

    #expect(summary["links"]?.array == before)
    #expect(try links(sbd, s.id) == before)
    #expect(before.first?["by"]?.string == "found")
  }

  @Test func rmOfAnUnknownIdAndOfAHiddenIdIsRefused() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "flags-cache")
    try sbd.postPromptHook(s.id, prompt: "Review \(SlackExample.root) and \(Self.linear)")
    let hidden = try linkId(sbd, s.id, SlackExample.root)
    try linkRm(sbd, s.id, hidden)
    let before = try links(sbd, s.id)

    for id in [hidden, "lnope2"] {
      let r = try sbd.run(["link", "rm", "--json", s.id, id])
      #expect(r.status != 0, "\(id)")
      #expect(r.stderr.contains("flags-cache has no link \(id)"), "\(id): \(r.stderr)")
    }

    #expect(try links(sbd, s.id) == before)
  }

  @Test func rmOfAnotherSessionsLinkIsRefusedAndKeepsBoth() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "flags-cache")
    let other = try sbd.new(name: "other")
    try linkAdd(sbd, s.id, Self.rfc)
    try linkAdd(sbd, other.id, Self.doc)
    try sbd.postPromptHook(other.id, prompt: "Review \(SlackExample.root)")
    let mine = try links(sbd, s.id)
    let theirs = try links(sbd, other.id)

    for id in theirs.compactMap({ $0["id"]?.string }) {
      let r = try sbd.run(["link", "rm", "--json", s.id, id])
      #expect(r.status != 0, "\(id)")
      #expect(r.stderr.contains("has no link"), "\(id): \(r.stderr)")
    }

    #expect(try links(sbd, s.id) == mine)
    #expect(try links(sbd, other.id) == theirs)
  }

  /// The hand link kept the found link off the list, so the user's rm hides the found link in the same step.
  @Test func yourRmOfAHandLinkThatAPromptAlsoFoundRemovesBoth() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "flags-cache")
    try linkAdd(sbd, s.id, SlackExample.root, title: "Thread")
    try sbd.postPromptHook(s.id, prompt: "Review \(SlackExample.root)")

    try linkRm(sbd, s.id, try linkId(sbd, s.id, SlackExample.root))

    #expect(try sbd.sessionLinks(s.id) == nil)
  }

  @Test func aLinkAddedByHandAndThenFoundListsOnce() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "flags-cache")
    try linkAdd(sbd, s.id, SlackExample.root, title: "Thread")

    try sbd.postPromptHook(s.id, prompt: "Review \(SlackExample.root)")

    let listed = try links(sbd, s.id)
    #expect(urls(listed) == [SlackExample.root])
    #expect(listed.first?["by"]?.string == "you")
    #expect(listed.first?["title"]?.string == "Thread")
    #expect(listed.first?["id"]?.string?.hasPrefix("l") == true)
  }

  // MARK: Claude

  /// Claude may title a link on its own session.
  @Test func claudeAddsALinkToItsOwnSession() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "flags-cache")

    try linkAdd(sbd, s.id, Self.rfc, title: "Flag RFC", env: inside(s.id))

    let link = try #require(try links(sbd, s.id).first)
    #expect(link["by"]?.string == "claude")
    #expect(link["title"]?.string == "Flag RFC")
    #expect(link["id"]?.string?.hasPrefix("l") == true)
  }

  @Test func claudeCantAddALinkToAnotherSession() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "flags-cache")
    let other = try sbd.new(name: "other")

    let r = try sbd.run(["link", "add", "--json", s.id, Self.rfc], env: inside(other.id))

    #expect(r.status != 0)
    #expect(r.stderr.contains("Claude can add or remove links only on its own session"), "\(r.stderr)")
    #expect(try sbd.sessionLinks(s.id) == nil)
    #expect(try sbd.sessionLinks(other.id) == nil)
  }

  @Test func claudeCantAddALinkWithoutSBSessionID() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "flags-cache")

    let r = try sbd.run(["link", "add", "--json", s.id, Self.rfc], env: ["CLAUDECODE": "1"])

    #expect(r.status != 0)
    #expect(r.stderr.contains("SB_SESSION_ID"), "\(r.stderr)")
    #expect(try sbd.sessionLinks(s.id) == nil)
  }

  /// The CLI then sends an empty `caller`. With one session, an empty prefix must not resolve to it.
  @Test func claudeCantAddALinkWithAnEmptySBSessionID() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "flags-cache")

    let r = try sbd.run(["link", "add", "--json", s.id, Self.rfc], env: ["CLAUDECODE": "1", "SB_SESSION_ID": ""])

    #expect(r.status != 0, "\(r.stdout)")
    #expect(try sbd.sessionLinks(s.id) == nil)
  }

  /// Done when: Claude's rm of a link that the user added is refused, and the link stays.
  @Test func claudeCantRemoveALinkYouAdded() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "flags-cache")
    try linkAdd(sbd, s.id, Self.rfc, title: "Flag RFC")
    let before = try links(sbd, s.id)

    let r = try sbd.run(["link", "rm", "--json", s.id, try linkId(sbd, s.id, Self.rfc)], env: inside(s.id))

    #expect(r.status != 0)
    #expect(r.stderr.contains("Only you can remove a link you added"), "\(r.stderr)")
    #expect(r.stderr.contains("sb link rm"), "\(r.stderr)")
    #expect(try links(sbd, s.id) == before)
  }

  @Test func claudeRemovesALinkClaudeAdded() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "flags-cache")
    try linkAdd(sbd, s.id, Self.rfc, env: inside(s.id))
    try linkAdd(sbd, s.id, Self.doc)

    try linkRm(sbd, s.id, try linkId(sbd, s.id, Self.rfc), env: inside(s.id))

    #expect(urls(try links(sbd, s.id)) == [Self.doc])
  }

  @Test func claudeCantAddAHiddenLinkBack() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "flags-cache")
    try sbd.postPromptHook(s.id, prompt: "Review \(SlackExample.root)")
    try linkRm(sbd, s.id, try linkId(sbd, s.id, SlackExample.root))

    for url in [SlackExample.root, SlackExample.reply] {
      let r = try sbd.run(["link", "add", "--json", s.id, url], env: inside(s.id))
      #expect(r.status != 0, "\(url)")
      #expect(r.stderr.contains("The user hid a link to this page"), "\(url): \(r.stderr)")
    }

    #expect(try sbd.sessionLinks(s.id) == nil)
  }

  // MARK: Who may ask

  /// `caller` resolves the way `session` does, so an id prefix or the name of the target passes.
  @Test func aRawRequestByClaudeTakesACallerThatNamesTheTargetAnyWay() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "flags-cache")
    _ = try sbd.new(name: "other")
    let callers = [s.id, String(s.id.dropLast()), "flags-cache"]

    for (i, caller) in callers.enumerated() {
      let url = "https://example.com/pages/\(i)"
      _ = try sbd.client.call(
        "link-add", ["session": .string(s.id), "url": .string(url), "by": "claude", "caller": .string(caller)])
      _ = try sbd.client.call(
        "link-rm",
        [
          "session": .string(s.id), "link": .string(try linkId(sbd, s.id, url)), "by": "claude",
          "caller": .string(caller),
        ])
    }

    #expect(try sbd.sessionLinks(s.id) == nil)
    #expect(try sbd.events(s.id, kind: "link-added").count == callers.count)
    #expect(try sbd.events(s.id, kind: "link-removed").count == callers.count)
  }

  /// Every `caller` that does not resolve to the target refuses a request by Claude, for both ops.
  @Test func aRawRequestByClaudeIsRefusedUnlessItsCallerIsTheTarget() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "flags-cache")
    let other = try sbd.new(name: "other")
    try claudeAdds(sbd, s.id, Self.rfc)
    let claudes = try linkId(sbd, s.id, Self.rfc)
    let before = try links(sbd, s.id)
    let shapes: [(label: String, caller: JSON?, refusal: String?)] = [
      ("no caller", nil, "SB_SESSION_ID"),
      ("a null caller", JSON.null, nil),
      ("another session's id", JSON.string(other.id), "only on its own session"),
      ("another session's name", JSON.string("other"), "only on its own session"),
      ("a name that no session has", JSON.string("nobody"), nil),
      ("an empty caller", JSON.string(""), nil),
      ("a number", JSON.number(7), nil),
      ("a list that holds the target", JSON.array([.string(s.id)]), nil),
    ]

    for shape in shapes {
      var add: [String: JSON] = ["session": .string(s.id), "url": .string(Self.doc), "by": "claude"]
      var rm: [String: JSON] = ["session": .string(s.id), "link": .string(claudes), "by": "claude"]
      add["caller"] = shape.caller
      rm["caller"] = shape.caller

      for (op, args) in [("link-add", add), ("link-rm", rm)] {
        let message = failure(sbd, op, args)
        #expect(message != "no error", "\(op) with \(shape.label)")
        if let refusal = shape.refusal { #expect(message.contains(refusal), "\(op) with \(shape.label): \(message)") }
      }
    }

    #expect(try links(sbd, s.id) == before)
    #expect(try sbd.sessionLinks(other.id) == nil)
  }

  /// The own-session rule binds only Claude. The user may name any session, whatever `caller` says.
  @Test func aRawRequestByYouTakesAnyCaller() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "flags-cache")
    let other = try sbd.new(name: "other")
    let o = JSON.string(other.id)

    _ = try sbd.client.call("link-add", ["session": .string(s.id), "url": .string(Self.rfc), "by": "you", "caller": o])
    _ = try sbd.client.call("link-add", ["session": .string(s.id), "url": .string(Self.doc), "caller": o])
    _ = try sbd.client.call(
      "link-rm", ["session": .string(s.id), "link": .string(try linkId(sbd, s.id, Self.rfc)), "caller": o])

    let listed = try links(sbd, s.id)
    #expect(urls(listed) == [Self.doc])
    #expect(listed.first?["by"]?.string == "you")
    #expect(try sbd.sessionLinks(other.id) == nil)
  }

  @Test func aRawRequestByAnUnknownAuthorIsRefused() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "flags-cache")
    try linkAdd(sbd, s.id, Self.rfc)
    let before = try links(sbd, s.id)
    let id = try linkId(sbd, s.id, Self.rfc)

    for by in ["robot", "Claude", "YOU", ""] {
      let add = failure(
        sbd, "link-add",
        ["session": .string(s.id), "url": .string(Self.doc), "by": .string(by), "caller": .string(s.id)])
      let rm = failure(
        sbd, "link-rm", ["session": .string(s.id), "link": .string(id), "by": .string(by), "caller": .string(s.id)])
      #expect(add != "no error", "add by \(by)")
      #expect(rm != "no error", "rm by \(by)")
    }

    #expect(try links(sbd, s.id) == before)
  }

  // MARK: Events

  @Test func eachChangeRecordsItsEvent() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "flags-cache")
    try sbd.postPromptHook(s.id, prompt: "Review \(SlackExample.root)")
    let found = try linkId(sbd, s.id, SlackExample.root)

    try linkAdd(sbd, s.id, Self.rfc)
    let added = try linkId(sbd, s.id, Self.rfc)
    try linkRm(sbd, s.id, added)
    try linkRm(sbd, s.id, found)
    try linkAdd(sbd, s.id, SlackExample.root)

    let addedEvent = try #require(try sbd.events(s.id, kind: "link-added").first)
    #expect(addedEvent.data["link"]?["id"]?.string == added)
    #expect(addedEvent.data["link"]?["url"]?.string == Self.rfc)
    #expect(try sbd.events(s.id, kind: "link-removed").map { $0.data["link"]?.string } == [added])
    let hidden = try #require(try sbd.events(s.id, kind: "link-hidden").first)
    #expect(hidden.data["link"]?.string == found)
    #expect(hidden.data["url"]?.string == SlackExample.root)
    #expect(try sbd.events(s.id, kind: "link-unhidden").map { $0.data["link"]?.string } == [found])
    #expect(try sbd.events(s.id, kind: "link-added").count == 1)
  }

  // MARK: Text output

  @Test func sbGetPrintsAnAddedLinkLine() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "flags-cache")
    try linkAdd(sbd, s.id, Self.rfc, title: "Flag RFC")
    let id = try linkId(sbd, s.id, Self.rfc)

    let text = try sbd.sb("get", s.id)

    let line = try #require(text.split(separator: "\n").map(String.init).first { $0.hasPrefix("  link: ") })
    #expect(line.hasPrefix("  link: \(id)  Flag RFC  \(Self.rfc)  (added by you "), "\(line)")
    #expect(line.hasSuffix(" ago)"), "\(line)")
  }

  @Test func sbGetSaysClaudeAddedALinkThatClaudeAdded() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "flags-cache")
    try linkAdd(sbd, s.id, Self.rfc, env: inside(s.id))

    let text = try sbd.sb("get", s.id)

    #expect(text.contains("\(Self.rfc)  (added by Claude "), "\(text)")
  }

  /// Without `--json`, `sb link` prints the session's link lines newest first, as `sb get` does.
  @Test func sbLinkWithoutJSONPrintsTheLinks() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "flags-cache")
    try sbd.sb("link", "add", s.id, Self.rfc, "--title", "Flag RFC")
    try sbd.advanceClock(60_000)

    let added = try sbd.sb("link", "add", s.id, Self.doc, "--title", "Cache design")
    let rfcId = try linkId(sbd, s.id, Self.rfc)
    let docId = try linkId(sbd, s.id, Self.doc)
    _ = try sbd.sb("link", "rm", s.id, rfcId)
    let none = try sbd.sb("link", "rm", s.id, docId)

    let lines = added.split(separator: "\n").map(String.init).filter { $0.hasPrefix("  link: ") }
    #expect(lines.count == 2, "\(added)")
    #expect(lines.first?.hasPrefix("  link: \(docId)  Cache design  \(Self.doc)  (added by you ") == true, "\(lines)")
    #expect(lines.last?.hasPrefix("  link: \(rfcId)  Flag RFC  \(Self.rfc)  (added by you ") == true, "\(lines)")
    #expect(none.contains("No links."), "\(none)")
    #expect(!none.contains("link: "), "\(none)")
  }

  /// One sbd runs every form, so the list costs one instance. Each expectation names its arguments.
  @Test func sbLinkWithoutAKnownSubcommandOrItsArgumentsFailsAndChangesNothing() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "flags-cache")

    let forms: [([String], String)] = [
      (["link"], "usage: sb link add"),
      (["link", "ls"], "usage: sb link add"),
      (["link", "add"], "link add needs a session and a URL"),
      (["link", "add", s.id], "link add needs a session and a URL"),
      (["link", "rm", s.id], "link rm needs a session and a link id"),
    ]
    for (args, message) in forms {
      let r = try sbd.run(args)
      #expect(r.status != 0, "\(args)")
      #expect(r.stderr.contains(message), "\(args): \(r.stderr)")
    }

    #expect(try sbd.sessionLinks(s.id) == nil)
  }

  // MARK: Every reader agrees

  /// A session with a listed found link, a hidden found link, an added artifact link stored in its normalized
  /// form with a title that JSON escapes, and an added link to the listed found link's page by another URL.
  func mixedLinks(_ sbd: Instance) throws -> SessionSummary {
    let s = try sbd.new(name: "flags-cache")
    _ = try sbd.new(name: "other")
    try sbd.postPromptHook(s.id, prompt: "Review \(SlackExample.reply) and \(Self.linear)")
    try linkRm(sbd, s.id, try linkId(sbd, s.id, Self.linear))
    try sbd.advanceClock(60_000)
    try linkAdd(sbd, s.id, "\(artifactPageURL)#top", title: #"Plan "v2" \ ✓"#)
    try linkAdd(sbd, s.id, SlackExample.root)
    return s
  }

  /// Risk 3: `sb get`, `sb ls`, and the MCP tools with `full` read one merged list.
  @Test func getLsAndMCPAgreeOnLinks() throws {
    let sbd = try Instance()
    let s = try mixedLinks(sbd)
    let mcp = try MCPClient(sbd)

    let got = try #require(try sbd.sessionLinks(s.id))
    let rows = try #require(JSON.parse(try sbd.sb("ls", "--json"))?.array)
    let listed = try #require(rows.first { $0["id"]?.string == s.id }?["links"]?.array)
    let mcpGot = try #require(
      try mcp.call("get_session", ["session": .string(s.id), "full": true]).json?["links"]?.array)
    let mcpRows = try #require(try mcp.call("list_sessions", ["full": true]).json?.array)
    let mcpListed = try #require(mcpRows.first { $0["id"]?.string == s.id }?["links"]?.array)

    #expect(urls(got) == [SlackExample.reply, artifactPageURL, SlackExample.root])
    #expect(got.compactMap { $0["by"]?.string } == ["found", "you", "you"])
    #expect(listed == got)
    #expect(mcpGot == got)
    #expect(mcpListed == got)
  }

  @Test func addedAndHiddenLinksSurviveARestartWithTheirIds() throws {
    let sbd = try Instance()
    let s = try mixedLinks(sbd)
    let before = try #require(try sbd.sessionLinks(s.id))

    sbd.stopSbd()
    try sbd.startSbd()

    #expect(try sbd.sessionLinks(s.id) == before)
  }
}
