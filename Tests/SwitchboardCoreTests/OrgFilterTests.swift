import Testing

@testable import SwitchboardCore

private func session(
  _ id: String, repository: String? = nil, read: Bool? = nil, pr: String? = nil, followup: Followup? = nil,
  docket: String? = nil, kind: SessionKind = .work, state: AttentionState = .working
) -> SessionSummary {
  var s = SessionSummary(
    id: id, name: id, cwd: "/tmp/\(id)", repo: nil, branch: nil, claudeSessionId: id, state: state, reason: "",
    since: 0, lastActivity: 0, live: true, claudePid: nil, attached: false, lastReply: nil, waits: [], notes: [],
    pr: pr.map { PRSummary(PullRequest(id: $0, number: 1, url: "https://github.com/\($0)/pull/1", repo: $0)) })
  s.repository = repository
  s.repositoryRead = read
  s.followup = followup
  if followup != nil, followup?.started == nil { s.cwd = "" }
  if let docket {
    s.cwd = ""
    s.docket = DocketSummary(DocketSession(pullRequest: docket, url: docket), DocketStatus())
  }
  s.kind = kind
  switch kind {
  case .manager: s.manager = true
  case .chat: s.chat = "g1"
  case .work: break
  }
  return s
}

private func inFolder(_ s: SessionSummary) -> SessionSummary {
  var s = s
  s.checkout = s.cwd
  return s
}

private func started(_ f: Followup) -> Followup {
  var f = f
  f.started = 1
  return f
}

private let posthog = session("ph", repository: "PostHog/posthog", read: true)
private let haacked = session("hk", repository: "haacked/switchboard", read: true)
private let local = session("lo", read: true)
private let unread = session("un")
private let manager = session("m", repository: "PostHog/posthog", read: true, kind: .manager)
private let chat = session("c", kind: .chat)

@Suite struct OrgFilterTests {

  // MARK: key(of:)

  struct KeyCase: Sendable, CustomTestStringConvertible {
    var name: String
    var session: SessionSummary
    var key: String?
    var testDescription: String { name }
  }

  @Test(arguments: [
    KeyCase(
      name: "read GitHub repository", session: session("s", repository: "PostHog/posthog", read: true), key: "posthog"),
    KeyCase(name: "read, no repository, no PR", session: session("s", read: true), key: OrgFilter.localKey),
    KeyCase(name: "not read, no PR", session: session("s"), key: nil),
    KeyCase(name: "read false, no repository, no PR", session: session("s", read: false), key: nil),
    KeyCase(name: "not read, with a PR", session: session("s", pr: "PostHog/x"), key: "posthog"),
    KeyCase(name: "read, no repository, with a PR", session: session("s", read: true, pr: "PostHog/x"), key: "posthog"),
    KeyCase(
      name: "in a folder with no GitHub origin, with a PR",
      session: inFolder(session("s", read: true, pr: "PostHog/x")), key: OrgFilter.localKey),
    KeyCase(name: "in a folder, not read, with a PR", session: inFolder(session("s", pr: "PostHog/x")), key: nil),
    KeyCase(
      name: "repository wins over a different PR repo",
      session: session("s", repository: "haacked/fork", read: true, pr: "PostHog/fork"), key: "haacked"),
    KeyCase(
      name: "unstarted follow-up with a repository",
      session: session("s", followup: Followup(prompt: "p", repository: "PostHog/posthog")), key: "posthog"),
    KeyCase(
      name: "unstarted follow-up without a repository", session: session("s", followup: Followup(prompt: "p")),
      key: OrgFilter.localKey),
    KeyCase(
      name: "started follow-up with a repository, not read",
      session: session("s", followup: started(Followup(prompt: "p", repository: "PostHog/posthog"))), key: "posthog"),
    KeyCase(
      name: "started follow-up without a repository, not read",
      session: session("s", followup: started(Followup(prompt: "p"))), key: nil),
    KeyCase(name: "the Manager", session: manager, key: nil),
    KeyCase(name: "the Manager, not read", session: session("m", kind: .manager), key: nil),
    KeyCase(name: "a group chat", session: chat, key: nil),
    KeyCase(
      name: "a group chat with a repository",
      session: session("c", repository: "PostHog/posthog", read: true, kind: .chat), key: nil),
    KeyCase(name: "docket row, org/repo#N", session: session("d", docket: "PostHog/posthog#12"), key: "posthog"),
    KeyCase(
      name: "docket row, URL", session: session("d", docket: "https://github.com/PostHog/posthog/pull/12"),
      key: "posthog"),
    KeyCase(name: "docket row, unparsable ref", session: session("d", docket: "not a ref"), key: OrgFilter.localKey),
    KeyCase(name: "owner is lowercased", session: session("s", repository: "POSTHOG/x", read: true), key: "posthog"),
  ])
  func keyOfASessionFollowsTheDerivationOrder(_ c: KeyCase) {
    #expect(OrgFilter.key(of: c.session) == c.key)
  }

  @Test func aListDropsSpacesAndEmptyItems() {
    #expect(OrgFilter(list: " PostHog, haacked,, ").keys == ["posthog", "haacked"])
  }

  @Test func theLocalKeyIsNotAGitHubLogin() {
    #expect(OrgFilter.localKey == "(local)")
  }

  // MARK: shows

  @Test(arguments: [posthog, haacked, local, unread, manager, chat])
  func allOrgsShowsEverySession(_ s: SessionSummary) {
    #expect(OrgFilter().isAll)
    #expect(OrgFilter().shows(s))
  }

  @Test(arguments: [haacked, local])
  func posthogFilterHidesOtherOrgsAndLocal(_ s: SessionSummary) {
    #expect(!OrgFilter(keys: ["posthog"]).shows(s))
  }

  @Test(arguments: [posthog, unread, manager, chat])
  func posthogFilterShowsPosthogAndSessionsWithNoKey(_ s: SessionSummary) {
    #expect(OrgFilter(keys: ["posthog"]).shows(s))
  }

  @Test(arguments: [local, unread, manager, chat])
  func localFilterShowsLocalAndSessionsWithNoKey(_ s: SessionSummary) {
    #expect(OrgFilter(keys: [OrgFilter.localKey]).shows(s))
  }

  @Test(arguments: [posthog, haacked])
  func localFilterHidesEveryOrg(_ s: SessionSummary) {
    #expect(!OrgFilter(keys: [OrgFilter.localKey]).shows(s))
  }

  @Test(arguments: ["PostHog", "POSTHOG", "posthog"])
  func filterKeysMatchCaseInsensitively(_ key: String) {
    let filter = OrgFilter(keys: [key])

    #expect(filter.keys == ["posthog"])
    #expect(filter.shows(posthog))
    #expect(filter.shows(session("s", repository: "PoStHoG/other", read: true)))
  }

  // MARK: entries

  @Test func entriesCountSessionsAndThoseNeedingYou() {
    let sessions = [
      session("a", repository: "PostHog/a", read: true, state: .needsYou),
      session("b", repository: "PostHog/b", read: true, state: .working),
      session("c", repository: "PostHog/c", read: true, state: .readyToMerge),
      session("d", repository: "haacked/d", read: true, state: .done),
    ]

    let entries = OrgFilter().entries(sessions)

    #expect(entries.first { $0.key == "posthog" }.map { [$0.count, $0.needsYou] } == [3, 2])
    #expect(entries.first { $0.key == "haacked" }.map { [$0.count, $0.needsYou] } == [1, 0])
  }

  @Test func entriesAreAlphabeticalByTitleWithLocalLast() {
    let sessions = [
      session("l", read: true), session("z", repository: "zeta/z", read: true),
      session("p", repository: "PostHog/p", read: true), session("a", repository: "Acme/a", read: true),
    ]

    let entries = OrgFilter().entries(sessions)

    #expect(entries.map(\.title) == ["Acme", "PostHog", "zeta", "Local"])
    #expect(entries.map(\.key) == ["acme", "posthog", "zeta", OrgFilter.localKey])
  }

  @Test(arguments: [(["PostHog/a", "posthog/b"], "PostHog"), (["posthog/b", "PostHog/a"], "posthog")])
  func theFirstSeenCasingBecomesTheTitle(_ repositories: [String], _ title: String) {
    let sessions = repositories.enumerated().map { session("s\($0.offset)", repository: $0.element, read: true) }

    let entries = OrgFilter().entries(sessions)

    #expect(entries.map(\.title) == [title])
  }

  @Test func aSelectedKeyWithNoSessionsIsListedWithZero() {
    let entries = OrgFilter(keys: ["acme"]).entries([posthog])

    let acme = entries.first { $0.key == "acme" }
    #expect(acme?.count == 0)
    #expect(acme?.needsYou == 0)
  }

  @Test func sessionsWithNoKeyAreNotCounted() {
    let entries = OrgFilter().entries([unread, manager, chat, posthog])

    #expect(entries.map(\.key) == ["posthog"])
    #expect(entries.map(\.count) == [1])
  }

  @Test func theLocalEntryIsTitledLocal() {
    #expect(OrgFilter().entries([local]).map(\.title) == ["Local"])
  }

  // MARK: label

  private static let labelSessions = [
    session("p", repository: "PostHog/p", read: true), session("z", repository: "zed/z", read: true),
    session("l", read: true),
  ]

  @Test(arguments: [
    ([] as [String], "All Orgs"),
    (["posthog"], "PostHog"),
    (["posthog", OrgFilter.localKey], "PostHog, Local"),
    (["posthog", "zed", OrgFilter.localKey], "PostHog +2"),
  ])
  func labelNamesTheSelectedOrgs(_ keys: [String], _ label: String) {
    let filter = OrgFilter(keys: keys)

    #expect(filter.label(filter.entries(Self.labelSessions)) == label)
  }

  // MARK: toggle

  @Test func toggleFromAllOrgsSelectsOnlyThatKey() {
    var filter = OrgFilter()

    filter.toggle("posthog")

    #expect(filter.keys == ["posthog"])
    #expect(!filter.isAll)
  }

  @Test func togglingTheLastKeyGivesAllOrgs() {
    var filter = OrgFilter(keys: ["posthog"])

    filter.toggle("posthog")

    #expect(filter.isAll)
    #expect(filter == OrgFilter())
  }

  @Test func toggleAddsAndRemovesOneKeyAmongSeveral() {
    var filter = OrgFilter(keys: ["posthog"])

    filter.toggle(OrgFilter.localKey)
    #expect(filter.keys == ["posthog", OrgFilter.localKey])

    filter.toggle("posthog")
    #expect(filter.keys == [OrgFilter.localKey])
  }

  // MARK: insert

  @Test func insertFromAllOrgsSelectsOnlyThatKey() {
    var filter = OrgFilter()

    filter.insert("PostHog")

    #expect(filter.keys == ["posthog"])
  }

  @Test func insertingAKeyThatIsAlreadySelectedKeepsIt() {
    var filter = OrgFilter(keys: ["posthog", OrgFilter.localKey])

    filter.insert(OrgFilter.localKey)
    filter.insert("POSTHOG")

    #expect(filter.keys == ["posthog", OrgFilter.localKey])
  }

  // MARK: decoding

  @Test func aSummaryFromAnOlderSbdHasNoRepositoryFields() throws {
    var object = try #require(try JSON(encoding: posthog).object)
    object["repository"] = nil
    object["repositoryRead"] = nil

    let decoded = try JSONCoding.decode(SessionSummary.self, from: JSON.object(object).text)

    #expect(decoded.repository == nil)
    #expect(decoded.repositoryRead == nil)
    #expect(OrgFilter.key(of: decoded) == nil)
  }

  @Test func aSummaryCarriesItsRepositoryFields() throws {
    let json = try JSON(encoding: posthog)

    #expect(json["repository"] == .string("PostHog/posthog"))
    #expect(json["repositoryRead"] == .bool(true))
    let decoded = try JSONCoding.decode(SessionSummary.self, from: json.text)
    #expect(decoded.repository == "PostHog/posthog")
    #expect(decoded.repositoryRead == true)
  }
}
