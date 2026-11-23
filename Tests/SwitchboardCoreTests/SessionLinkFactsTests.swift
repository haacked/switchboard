import CryptoKit
import Foundation
import Testing

@testable import SwitchboardCore

/// A UserPromptSubmit hook, as sbd stores its payload.
private func linkPrompt(_ t: Int64, _ text: String, agent: String? = nil) -> Event {
  var fields: [String: JSON] = [
    "hook_event_name": "UserPromptSubmit", "session_id": "uuid", "prompt": .string(text), "cwd": "/tmp",
    "permission_mode": "default",
  ]
  if let agent { fields["agent_id"] = .string(agent) }
  return event("UserPromptSubmit", t, fields)
}

/// A send whose result names the message at `link` in `channel` with ts `ts`.
private func slackSend(
  _ t: Int64, _ link: String, channel: String, ts: String, input: [String: JSON]? = nil, agent: String? = nil
) -> Event {
  let response = slackSendResponse(link: link, channel: channel, ts: ts)
  if let input { return slackSendHook(t, input: input, response: response, agent: agent) }
  return slackSendHook(t, response: response, agent: agent)
}

/// D14's id rule, written out: `f`, then for each of 5 characters, byte i of the SHA-256 of the seed modulo 32
/// picks character i of `ShortId.alphabet`.
private func hashedFoundId(_ seed: String) -> String {
  let alphabet = Array(ShortId.alphabet)
  let digest = Array(SHA256.hash(data: Data(seed.utf8)))
  return "f" + String((0..<5).map { alphabet[Int(digest[$0]) % 32] })
}

private let rootURL = LinkFixtures.slackRoot
private let replyURL = LinkFixtures.slackReply
private let ch = LinkFixtures.channel
private let rootTs = LinkFixtures.rootTs
private let replyTs = LinkFixtures.replyTs

/// How `SessionFacts.apply` folds prompts and Slack sends into `links`: one entry per target key, in first-sighting
/// order, each with the first sighting's URL and time.
@Suite struct SessionLinkFactsTests {
  @Test func aNewSessionHasNoLinks() {
    #expect(SessionFacts().links.isEmpty)
  }

  // MARK: Prompts

  @Test func aPromptLinkAddsAFoundEntry() throws {
    let f = facts([linkPrompt(1000, "Review \(rootURL) please")])

    let link = try #require(f.links.first)
    #expect(f.links.count == 1)
    #expect(link.url == rootURL)
    #expect(link.title == "Slack thread in \(ch)")
    #expect(link.by == .found)
    #expect(link.t == 1000)
    #expect(link.kind == .slack)
    #expect(link.linkTarget?.channel == ch)
    #expect(link.linkTarget?.thread == rootTs)
  }

  @Test func aFoundEntrysIdComesFromItsKey() {
    let f = facts([linkPrompt(1000, "Review \(rootURL)")])

    #expect(f.links.map(\.id) == [hashedFoundId(LinkFixtures.slackRootKey)])
  }

  @Test func grafanaDashboardsOnTwoPortsAreTwoEntries() {
    let f = facts([
      linkPrompt(
        1000, "Compare https://grafana.example.com:3000/d/abc123 and https://grafana.example.com:4000/d/abc123")
    ])

    #expect(f.links.count == 2)
  }

  @Test(arguments: ["**", "~~", "_", "__"])
  func aLinkAtTheEndOfAnEmphasizedPhraseIsFound(_ marker: String) {
    let linear = "https://linear.app/example/issue/ENG-123"

    let f = facts([linkPrompt(1000, "\(marker)Review \(linear)\(marker)")])

    #expect(f.links.map(\.url) == [linear])
  }

  @Test func aGrafanaUidThatEndsInAnUnderscoreKeepsIt() {
    let f = facts([linkPrompt(1000, "[dashboard](https://grafana.example.com/d/api_)")])

    #expect(f.links.map(\.url) == ["https://grafana.example.com/d/api_"])
  }

  @Test func theTextAroundALinkIsNotPartOfItsURL() {
    let f = facts([linkPrompt(1000, "Can you look at <\(replyURL)|this thread>?")])

    #expect(f.links.map(\.url) == [replyURL])
  }

  @Test func twoPromptsWithOneThreadKeepTheFirstURLAndTime() throws {
    let later = "\(rootURL)?cid=\(ch)"

    let f = facts([linkPrompt(1000, "Review \(rootURL)"), linkPrompt(5000, "Again: \(later)")])

    let link = try #require(f.links.first)
    #expect(f.links.count == 1)
    #expect(link.url == rootURL)
    #expect(link.t == 1000)
  }

  @Test func aRootLinkThenAReplyLinkOfItsThreadListOneEntry() {
    let f = facts([linkPrompt(1000, "Review \(rootURL)"), linkPrompt(5000, "See the reply \(replyURL)")])

    #expect(f.links.map(\.url) == [rootURL])
    #expect(f.links.map(\.t) == [1000])
  }

  @Test func aReplyLinkThenItsRootListOneEntryWithTheReplysURL() {
    let f = facts([linkPrompt(1000, "See the reply \(replyURL)"), linkPrompt(5000, "Review \(rootURL)")])

    #expect(f.links.map(\.url) == [replyURL])
    #expect(f.links.map(\.linkTarget?.thread) == [rootTs])
  }

  /// The workspace in a key is lowercased, so the case of the host makes no second entry.
  @Test func linksThatDifferOnlyInTheCaseOfTheHostListOneEntry() {
    let shouted = "HTTPS://EXAMPLE.SLACK.COM/archives/\(ch)/\(LinkFixtures.rootP)"

    let f = facts([linkPrompt(1000, rootURL), linkPrompt(2000, shouted)])

    #expect(f.links.map(\.url) == [rootURL])
  }

  @Test func linksInOnePromptKeepThePromptsOrder() {
    let text =
      "Plan: \(LinkFixtures.notion), issue \(LinkFixtures.linear), doc <\(LinkFixtures.google)|doc>, and "
      + "[dashboard](\(LinkFixtures.grafana)). Thread: \(rootURL)."

    let f = facts([linkPrompt(1000, text)])

    #expect(
      f.links.map(\.url) == [
        LinkFixtures.notion, LinkFixtures.linear, LinkFixtures.google, LinkFixtures.grafana, rootURL,
      ])
    #expect(f.links.map(\.kind) == [.notion, .linear, .google, .grafana, .slack])
    #expect(f.links.allSatisfy { $0.t == 1000 && $0.by == .found })
  }

  @Test func aPromptWithTheSameLinkTwiceListsItOnce() {
    let f = facts([linkPrompt(1000, "\(rootURL) and again \(rootURL)")])

    #expect(f.links.count == 1)
  }

  @Test(arguments: [LinkFixtures.githubPR, "https://example.com/doc", artifactShortURL, "http://example.slack.com/x"])
  func aLinkOfNoKnownKindAddsNothing(_ url: String) {
    let f = facts([linkPrompt(1000, "See \(url)")])

    #expect(f.links.isEmpty)
  }

  @Test(arguments: [
    "https://example.slack.com.evil.example/archives/\(LinkFixtures.channel)/\(LinkFixtures.rootP)",
    "https://example.slack.com@evil.example/archives/\(LinkFixtures.channel)/\(LinkFixtures.rootP)",
    "https://linear.app.evil.example/example/issue/ENG-123",
  ])
  func aLinkThatTheParserRefusesAddsNothing(_ url: String) {
    let f = facts([linkPrompt(1000, "See \(url)")])

    #expect(f.links.isEmpty)
  }

  /// A subagent's result arrives as a prompt but is model output.
  @Test(arguments: [
    "<task-notification>\n<task-id>a1</task-id>\n<result>Found \(LinkFixtures.slackRoot)</result>\n</task-notification>",
    "<agent-message from=\"a1\">Found \(LinkFixtures.slackRoot)</agent-message>",
  ])
  func aSubagentsResultPromptAddsNothing(_ text: String) {
    let f = facts([linkPrompt(1000, text)])

    #expect(f.links.isEmpty)
  }

  @Test func aUserPromptSubmitWithAnAgentIdAddsNothing() {
    let f = facts([linkPrompt(1000, "Review \(rootURL)", agent: "a1b2c3d4e5")])

    #expect(f.links.isEmpty)
  }

  @Test func aPeerMessageCounts() {
    let peer =
      "<cross-session-message from=\"uds:/tmp/cc-socks/86186.sock\" from-name=\"manager\" from-mode=\"prompting\">\n"
      + "Please reply in \(rootURL)\n</cross-session-message>"

    let f = facts([linkPrompt(1000, peer)])

    #expect(f.links.map(\.url) == [rootURL])
  }

  /// Only UserPromptSubmit carries prompt text that counts. A launch prompt reaches the list when claude takes it.
  @Test(arguments: ["started", "resumed", "sent", "Stop"])
  func anotherEventWithAPromptAddsNothing(_ kind: String) {
    let f = facts([event(kind, 1000, ["prompt": .string("Review \(rootURL)"), "text": .string("Review \(rootURL)")])])

    #expect(f.links.isEmpty)
  }

  @Test(arguments: [JSON.null, 7, .array([.string("Review \(LinkFixtures.slackRoot)")])])
  func aPromptThatIsNotAStringAddsNothing(_ prompt: JSON) {
    let f = facts([event("UserPromptSubmit", 1000, ["prompt": prompt])])

    #expect(f.links.isEmpty)
  }

  // MARK: Sends

  @Test func aSendAddsAFoundEntryWithTheResultsLink() throws {
    let f = facts([slackSend(1000, LinkFixtures.slackDM, channel: LinkFixtures.dmChannel, ts: replyTs)])

    let link = try #require(f.links.first)
    #expect(f.links.count == 1)
    #expect(link.url == LinkFixtures.slackDM)
    #expect(link.by == .found)
    #expect(link.t == 1000)
    #expect(link.linkTarget?.channel == LinkFixtures.dmChannel)
    #expect(link.linkTarget?.thread == replyTs)
  }

  @Test func aPromptLinkThenASendToItsThreadListOneEntry() {
    let f = facts([
      linkPrompt(1000, "Reply in \(rootURL)"),
      slackSend(5000, replyURL, channel: ch, ts: replyTs),
    ])

    #expect(f.links.map(\.url) == [rootURL])
    #expect(f.links.map(\.t) == [1000])
  }

  @Test func aSendThenAPromptLinkToItsThreadListOneEntryWithTheSendsLink() {
    let f = facts([
      slackSend(1000, replyURL, channel: ch, ts: replyTs),
      linkPrompt(5000, "Did you see \(rootURL)"),
    ])

    #expect(f.links.map(\.url) == [replyURL])
    #expect(f.links.map(\.t) == [1000])
  }

  /// Q3: the thread comes from the link alone. A reply whose link lacks `thread_ts` records itself as its own
  /// thread, even when the call's input names the thread, so it does not join the root's entry.
  @Test func aSendWhoseLinkLacksThreadTsIsItsOwnThreadWhateverTheInputSays() {
    let own = "https://example.slack.com/archives/\(ch)/\(LinkFixtures.replyP)"

    let f = facts([
      linkPrompt(1000, "Reply in \(rootURL)"),
      slackSend(
        5000, own, channel: ch, ts: replyTs,
        input: ["channel_id": .string(ch), "message": "Done", "thread_ts": .string(rootTs)]),
    ])

    #expect(f.links.map(\.url) == [rootURL, own])
    #expect(f.links.map(\.linkTarget?.thread) == [rootTs, replyTs])
  }

  @Test func aSubagentsSendCounts() {
    let f = facts([slackSend(1000, LinkFixtures.slackDM, channel: LinkFixtures.dmChannel, ts: replyTs, agent: "a1b2c3")]
    )

    #expect(f.links.map(\.url) == [LinkFixtures.slackDM])
  }

  @Test func aDraftAFailureAndAMismatchedContextAddNothing() {
    let f = facts([
      slackSendHook(1000, tool: "\(slackSendTool)_draft"),
      slackSendHook(2000, kind: "PostToolUseFailure"),
      slackSend(3000, LinkFixtures.slackDM, channel: "D0EXAMPLE02", ts: replyTs),
    ])

    #expect(f.links.isEmpty)
  }

  /// Only a prompt and a send add links. A Slack link in another tool's result, such as a search, adds nothing.
  @Test func aSlackLinkInAnotherToolsResultAddsNothing() {
    let f = facts([
      slackSendHook(1000, tool: "mcp__claude_ai_Slack__slack_search_public"),
      artifactHook(
        2000, tool: "Bash", input: ["command": "echo"], response: ["stdout": .string(rootURL), "stderr": ""]),
    ])

    #expect(f.links.isEmpty)
  }

  // MARK: Ids and keys

  @Test func idsStartWithFAndAreEqualAcrossTwoFolds() {
    let events = [
      linkPrompt(1000, "\(rootURL) \(LinkFixtures.linear) \(LinkFixtures.notion)"),
      slackSend(2000, LinkFixtures.slackDM, channel: LinkFixtures.dmChannel, ts: replyTs),
    ]

    let first = facts(events)
    let second = facts(events)

    #expect(first.links.count == 4)
    #expect(first.links.allSatisfy { $0.id.hasPrefix("f") })
    #expect(first.links.map(\.id) == second.links.map(\.id))
  }

  @Test func everyEntryHasADistinctId() {
    let f = facts([
      linkPrompt(
        1000, "\(rootURL) \(LinkFixtures.linear) \(LinkFixtures.notion) \(LinkFixtures.google) \(LinkFixtures.grafana)"),
      slackSend(2000, LinkFixtures.slackDM, channel: LinkFixtures.dmChannel, ts: replyTs),
    ])

    #expect(f.links.count == 6)
    #expect(Set(f.links.map(\.id)).count == f.links.count)
  }

  /// D10: an entry's key comes from its URL alone. Every entry parses, and no two share a key.
  @Test func everyEntrysKeyComesFromItsURLAndIsDistinct() throws {
    let f = facts([
      linkPrompt(1000, "\(replyURL) \(LinkFixtures.notion)"),
      slackSend(
        2000, "https://example.slack.com/archives/\(ch)/\(LinkFixtures.replyP)", channel: ch, ts: replyTs,
        input: ["channel_id": .string(ch), "message": "Done", "thread_ts": .string(rootTs)]),
      linkPrompt(3000, "https://notion.so/Renamed-\(LinkFixtures.hex) \(rootURL)"),
    ])

    let keys = try f.links.map { try #require(LinkTarget.parse($0.url)).key }
    #expect(Set(keys).count == f.links.count)
    #expect(f.links.count == 3)
  }

  // MARK: Encoding

  @Test func theLinksSurviveEncoding() throws {
    let f = facts([
      linkPrompt(1000, "\(replyURL) \(LinkFixtures.linear)"),
      slackSend(2000, LinkFixtures.slackDM, channel: LinkFixtures.dmChannel, ts: replyTs),
    ])

    let decoded = try JSONCoding.decode(SessionFacts.self, from: try JSONCoding.encode(f))

    #expect(decoded.links == f.links)
  }
}

/// D14: a found link's id is `f` and 5 characters from the SHA-256 of its key. When `taken` holds that id, the id
/// comes from the key with `#1`, then `#2`, and so on.
@Suite struct FoundIdTests {
  static let keys = [
    LinkFixtures.slackRootKey, "linear:example/ENG-123", "notion:\(LinkFixtures.hex)",
    "google:document/\(LinkFixtures.googleId)", "grafana:grafana.example.com/abc123",
  ]

  @Test(arguments: keys) func withNothingTakenTheIdComesFromTheKeysHash(_ key: String) {
    #expect(ExternalLink.foundId(key: key, taken: []) == hashedFoundId(key))
  }

  @Test(arguments: keys) func anIdIsFAndFiveCharactersOfTheShortIdAlphabet(_ key: String) {
    let id = ExternalLink.foundId(key: key, taken: [])

    #expect(id.count == 6)
    #expect(id.hasPrefix("f"))
    #expect(id.dropFirst().allSatisfy { ShortId.alphabet.contains($0) })
  }

  @Test(arguments: keys) func whenTheFirstIdIsTakenTheIdComesFromTheKeyWithHash1(_ key: String) {
    let first = hashedFoundId(key)

    #expect(ExternalLink.foundId(key: key, taken: [first]) == hashedFoundId("\(key)#1"))
  }

  @Test(arguments: keys) func whenTwoIdsAreTakenTheIdComesFromTheKeyWithHash2(_ key: String) {
    let first = hashedFoundId(key)
    let second = hashedFoundId("\(key)#1")

    #expect(ExternalLink.foundId(key: key, taken: [second, first]) == hashedFoundId("\(key)#2"))
  }

  @Test(arguments: keys) func takenIdsThatDoNotClashLeaveTheIdAlone(_ key: String) {
    #expect(ExternalLink.foundId(key: key, taken: ["l3k9ap", "fzzzzz"]) == hashedFoundId(key))
  }

  @Test func twoKeysGiveTwoIds() {
    #expect(
      ExternalLink.foundId(key: "linear:example/ENG-123", taken: [])
        != ExternalLink.foundId(key: "linear:example/ENG-124", taken: []))
  }
}

/// Startup builds facts from a snapshot and the events after it. For links, that gives the same replay as applying
/// the whole log, wherever the snapshot cuts it, so the ids are the same too.
@Suite struct SessionLinkSnapshotTests {
  let session = Session(id: "s1", name: "one", cwd: "/tmp/a", branch: "main", claudeSessionId: "u1", created: 5)

  func history() -> [Event] {
    [
      event("started", 500, ["prompt": .string("Review \(rootURL)")]),
      event("SessionStart", 600, ["transcript_path": "/tmp/t.jsonl"]),
      linkPrompt(700, "Review \(rootURL) and \(LinkFixtures.linear)"),
      artifactHook(800, tool: "Bash", input: ["command": "ls"], response: ["stdout": "", "stderr": ""]),
      linkPrompt(
        900,
        "<task-notification>\n<result>See https://example.slack.com/archives/C0EXAMPLE09/\(LinkFixtures.rootP)</result>\n</task-notification>"
      ),
      slackSend(1000, replyURL, channel: ch, ts: replyTs),
      slackSendHook(1100, tool: "\(slackSendTool)_draft"),
      linkPrompt(
        1200,
        "<cross-session-message from=\"uds:/tmp/cc-socks/1.sock\" from-name=\"manager\" from-mode=\"prompting\">\n"
          + "Plan: \(LinkFixtures.notion)\n</cross-session-message>"),
      event("Stop", 1300, ["last_assistant_message": "Replied."]),
      slackSend(1400, LinkFixtures.slackDM, channel: LinkFixtures.dmChannel, ts: replyTs),
      linkPrompt(1500, "Once more: \(rootURL)?cid=\(ch)"),
      linkPrompt(1600, "And the doc \(LinkFixtures.google)", agent: "a1b2"),
    ]
  }

  /// What the history leaves, so a parity check over two empty lists can't pass.
  var expectedURLs: [String] { [rootURL, LinkFixtures.linear, LinkFixtures.notion, LinkFixtures.slackDM] }
  var expectedTimes: [Int64] { [700, 700, 1200, 1400] }

  @Test func aFullReplayBuildsTheExpectedLinks() {
    let links = SessionReplay.replaying(history(), session: session).facts.links

    #expect(links.map(\.url) == expectedURLs)
    #expect(links.map(\.t) == expectedTimes)
    #expect(links.allSatisfy { $0.by == .found })
  }

  @Test func theSnapshotAndTheTailBuildWhatAFullReplayBuildsAtEveryCut() throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let store = try Store(path: "\(dir)/sb.db")
    let events = history()
    for cut in 1..<events.count {
      try store.delete(session: SessionRemoval(id: session.id, name: session.name))
      try store.save(session)
      for e in events[..<cut] { try store.append(e) }
      try Snapshots.refresh(store, session, build: "b1")
      for e in events[cut...] { try store.append(e) }

      let second = try Snapshots.refresh(store, session, build: "b1")

      let full = SessionReplay.replaying(try store.events(session: session.id), session: session)
      #expect(second.outcome == .snapshot(tail: events.count - cut), "cut \(cut)")
      #expect(second.snapshot.replay == full, "cut \(cut)")
      #expect(second.snapshot.replay.facts.links == full.facts.links, "cut \(cut)")
      #expect(second.snapshot.replay.facts.links.map(\.url) == expectedURLs, "cut \(cut)")
    }
  }

  /// A snapshot that another build saved is replayed in full, so its facts are rebuilt with the links.
  @Test func aSnapshotFromAnotherBuildIsReplayedWithItsLinks() throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let store = try Store(path: "\(dir)/sb.db")
    try store.save(session)
    for e in history() { try store.append(e) }
    let old = try Snapshots.refresh(store, session, build: "old")

    let refreshed = try Snapshots.refresh(store, session, build: "new")

    #expect(refreshed.outcome == .replay("snapshot is from another build", events: history().count))
    #expect(refreshed.snapshot.replay.facts.links.map(\.url) == expectedURLs)
    #expect(refreshed.snapshot.replay.facts.links.map(\.id) == old.snapshot.replay.facts.links.map(\.id))
  }
}

/// The suites nest under `SessionLinkFactsTests`, so its filter runs them.
extension SessionLinkFactsTests {
  /// A `link-opened` event records when the user opened a link from Switchboard, keyed by the link's page (H3).
  @Suite struct Opened {
    static let key = LinkFixtures.slackRootKey
    static let otherKey = LinkFixtures.otherThreadKey

    func opened(_ t: Int64, key: String = Self.key, link: String = "l1") -> Event {
      LinkFixtures.opened(t, key: key, link: link)
    }

    @Test func aNewSessionHasNoOpens() {
      #expect(SessionFacts().linkOpened.isEmpty)
    }

    @Test func anOpenRecordsItsTimeUnderItsKey() {
      let f = facts([linkPrompt(1000, "Review \(rootURL)"), opened(2000)])

      #expect(f.linkOpened == [Self.key: 2000])
    }

    @Test func aLaterOpenWins() {
      let f = facts([opened(2000), opened(3000)])

      #expect(f.linkOpened[Self.key] == 3000)
    }

    @Test func anOpenOfAnotherKeyLeavesThisKeyAlone() {
      let f = facts([opened(2000), opened(3000, key: Self.otherKey, link: "l2")])

      #expect(f.linkOpened == [Self.key: 2000, Self.otherKey: 3000])
    }

    @Test(arguments: [[String: JSON](), ["link": "l1"], ["link": "l1", "key": 7]])
    func anOpenWithoutAKeyRecordsNothing(_ data: [String: JSON]) {
      let f = facts([event("link-opened", 2000, data)])

      #expect(f.linkOpened.isEmpty)
    }

    @Test func anOpenAddsNoLink() {
      let f = facts([opened(2000)])

      #expect(f.links.isEmpty)
    }

    @Test func theOpensSurviveEncoding() throws {
      let f = facts([opened(2000), opened(3000, key: Self.otherKey, link: "l2")])

      let decoded = try JSONCoding.decode(SessionFacts.self, from: try JSONCoding.encode(f))

      #expect(decoded.linkOpened == f.linkOpened)
    }
  }

  /// The inputs of "last looked" come from replay, so a snapshot and the events after it give what a full replay
  /// gives, wherever the snapshot cuts the log.
  @Suite struct LookedAtSnapshot {
    let session = Session(id: "s1", name: "one", cwd: "/tmp/a", branch: "main", claudeSessionId: "u1", created: 5)
    static let key = LinkFixtures.slackRootKey

    func history() -> [Event] {
      let opened: [String: JSON] = ["link": .string(hashedFoundId(Self.key)), "key": .string(Self.key)]
      let ack: [String: JSON] = ["state": "needs_you", "reason": "read its last reply and decide what's next"]
      return [
        linkPrompt(700, "Review \(rootURL)"),
        event("link-opened", 800, opened),
        event("Stop", 900, ["last_assistant_message": "Done."]),
        event("ack", 1000, ack),
        event("ack", 1100, ack),
        event("unack", 1200),
        event("link-opened", 1300, opened),
        linkPrompt(1400, "Keep going"),
        event("Stop", 1500, ["last_assistant_message": "Done again."]),
      ]
    }

    /// What the history leaves, so a parity check over two empty values can't pass.
    @Test func aFullReplayBuildsTheExpectedOpensAndAcknowledgment() {
      let f = SessionReplay.replaying(history(), session: session).facts

      #expect(f.linkOpened == [Self.key: 1300])
      #expect(f.lastAcknowledged == 1000)
    }

    @Test func theSnapshotAndTheTailBuildWhatAFullReplayBuildsAtEveryCut() throws {
      let dir = try tempFolder()
      defer { try? FileManager.default.removeItem(atPath: dir) }
      let store = try Store(path: "\(dir)/sb.db")
      let events = history()
      for cut in 1..<events.count {
        try store.delete(session: SessionRemoval(id: session.id, name: session.name))
        try store.save(session)
        for e in events[..<cut] { try store.append(e) }
        try Snapshots.refresh(store, session, build: "b1")
        for e in events[cut...] { try store.append(e) }

        let second = try Snapshots.refresh(store, session, build: "b1")

        let full = SessionReplay.replaying(try store.events(session: session.id), session: session)
        #expect(second.snapshot.replay.facts.linkOpened == full.facts.linkOpened, "cut \(cut)")
        #expect(second.snapshot.replay.facts.lastAcknowledged == full.facts.lastAcknowledged, "cut \(cut)")
        #expect(second.snapshot.replay.facts.linkOpened == [Self.key: 1300], "cut \(cut)")
        #expect(second.snapshot.replay.facts.lastAcknowledged == 1000, "cut \(cut)")
      }
    }
  }
}
