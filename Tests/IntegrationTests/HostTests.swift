import Foundation
import SwitchboardCore
import Testing

private let miniDestination = "haacked@mini.local"
private let refusal = "ssh: connect to host mini.local port 22: Operation timed out"
private let workspaceProblem = "a hogli host with the shared layout needs a workspace"

/// One host of each sort: a valid ssh host, a valid shared hogli host, a perSession host, and an invalid host.
private let everySortOfHost: [String: JSON] = [
  "mini": Instance.sshHost(miniDestination),
  "devbox": ["kind": "hogli", "workspace": "devbox-haacked"],
  "boxes": ["kind": "hogli", "layout": "perSession"],
  "typo": ["kind": "hogli"],
]

private let oneHost = Instance.hostsConfig(["mini": Instance.sshHost(miniDestination)])

/// Whether the process exited. A process that its parent has not waited for yet counts.
private func ended(_ pid: pid_t) -> Bool {
  if kill(pid, 0) != 0 { return true }
  let state = (try? runCommand("/bin/ps", ["-o", "stat=", "-p", String(pid)]).stdout) ?? ""
  return state.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("Z")
}

/// The line's fields, with each run of spaces as one separator.
private func fields(_ line: Substring) -> [String] {
  line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
}

/// The object without `since`, which holds the time of the run.
private func withoutSince(_ value: JSON) -> JSON {
  var object = value.object ?? [:]
  object["since"] = nil
  return .object(object)
}

@Suite(.blocking(timeLimit: .seconds(120))) struct HostTests {
  // MARK: sb host ls

  @Test func listsNoHostsAsAnEmptyArrayAndAsAHint() throws {
    let sbd = try Instance(config: ["ssh": .string(Instance.sshStub)])

    let json = try sbd.sb("host", "ls", "--json")
    let text = try sbd.sb("host", "ls")
    let bare = try sbd.sb("host")

    #expect(JSON.parse(json) == [])
    #expect(text == "No hosts. Add them under hosts in \(sbd.home.config).\n")
    #expect(bare == text)
  }

  @Test func listsValidInvalidAndPerSessionHostsAsJSONSortedByName() throws {
    let sbd = try Instance(config: Instance.hostsConfig(everySortOfHost))
    let started = try sbd.now()

    let rows = try #require(JSON.parse(try sbd.sb("host", "ls", "--json"))?.array)

    #expect(
      rows.map(withoutSince) == [
        ["name": "boxes", "kind": "hogli"],
        [
          "name": "devbox", "kind": "hogli", "destination": "coder.devbox-haacked", "link": "disconnected",
          "failures": 0,
        ],
        [
          "name": "mini", "kind": "ssh", "destination": .string(miniDestination), "link": "disconnected", "failures": 0,
        ],
        ["name": "typo", "kind": "hogli", "problem": .string(workspaceProblem)],
      ])
    #expect(rows[0]["since"] == nil)
    #expect(rows[3]["since"] == nil)
    for row in rows[1...2] {
      let since = try #require(row["since"]?.int)
      #expect(Int64(since) <= started)
    }
  }

  @Test func theHostsRequestAnswersTheSameRowsAsTheCommand() throws {
    let sbd = try Instance(config: Instance.hostsConfig(everySortOfHost))

    let hosts = try sbd.hosts()

    #expect(hosts.map(\.name) == ["boxes", "devbox", "mini", "typo"])
    #expect(hosts.map(\.link) == [nil, .disconnected, .disconnected, nil])
    #expect(hosts.map(\.destination) == [nil, "coder.devbox-haacked", miniDestination, nil])
    #expect(hosts.map(\.problem) == [nil, nil, nil, workspaceProblem])
    #expect(try JSONCoding.decode([HostStatus].self, from: sbd.sb("host", "ls", "--json")) == hosts)
  }

  @Test func listsTheSameHostsAsText() throws {
    let sbd = try Instance(config: Instance.hostsConfig(everySortOfHost))

    let bare = try sbd.sb("host")
    let text = try sbd.sb("host", "ls")

    let lines = text.split(separator: "\n")
    let rows = Dictionary(lines.map { (fields($0).first ?? "", $0) }) { first, _ in first }
    #expect(bare == text)
    #expect(lines.count == 4)
    #expect(rows["boxes"].map(fields) == ["boxes", "hogli", "-", "a", "box", "per", "session"])
    #expect(rows["devbox"].map(fields) == ["devbox", "hogli", "disconnected", "coder.devbox-haacked"])
    #expect(rows["mini"].map(fields) == ["mini", "ssh", "disconnected", miniDestination])
    #expect(
      rows["typo"].map(fields) == ["typo", "hogli", "invalid"] + workspaceProblem.split(separator: " ").map(String.init)
    )
    #expect(lines.map { fields($0).first } == ["boxes", "devbox", "mini", "typo"])
    // The names are padded to the longest one, "devbox", and two spaces follow.
    for (name, line) in rows {
      #expect(line.prefix(8) == name.padding(toLength: 8, withPad: " ", startingAt: 0), "\(line)")
      #expect(line.dropFirst(8).first != " ", "\(line)")
    }
  }

  @Test func sbHelpListsTheHostCommands() throws {
    let sbd = try Instance()

    let usage = try sbd.sb("help")

    #expect(usage.contains("\n  host [ls]  "))
    #expect(usage.contains("\n  host connect <host>  "))
    #expect(usage.contains("\n  host disconnect <host>  "))
    #expect(usage.contains("open link keeps a devbox running"))
  }

  // MARK: Links

  @Test func sbdOpensNoLinkWhenItStarts() throws {
    let sbd = try Instance(config: Instance.hostsConfig(everySortOfHost))

    try sbd.advanceClock(120_000)
    let hosts = try sbd.hosts()

    #expect(hosts.compactMap(\.link) == [.disconnected, .disconnected])
    #expect(sbd.sshStubLog.isEmpty)
  }

  @Test func connectReachesConnectedAndDisconnectLeavesNoStubProcess() throws {
    let sbd = try Instance(config: oneHost)

    let answer = try #require(JSON.parse(try sbd.sb("host", "connect", "mini", "--json")))
    let connected = try sbd.waitForLink("mini", .connected)
    let pid = try #require(try sbd.sshStubPid(miniDestination))
    let listed = try sbd.sb("host", "ls")
    let closed = try #require(JSON.parse(try sbd.sb("host", "disconnect", "mini", "--json")))

    #expect(answer["name"] == "mini")
    #expect(answer["destination"] == .string(miniDestination))
    #expect(["connecting", "connected"].contains(answer["link"]?.string))
    #expect(connected.failures == 0)
    #expect(connected.retryAt == nil)
    #expect(connected.error == nil)
    #expect(connected.problem == nil)
    #expect(fields(listed.split(separator: "\n")[0]) == ["mini", "ssh", "connected", miniDestination])
    #expect(sbd.sshStubMasters().count == 1)
    #expect(closed["name"] == "mini")
    #expect(closed["link"] == "disconnected")
    #expect(closed["retryAt"] == nil)
    try sbd.waitFor("the stub's process to exit", timeout: 5) { ended(pid) }
    #expect(try sbd.hosts().first?.link == .disconnected)
  }

  @Test func connectAndDisconnectPrintTheHostsRowAsText() throws {
    let sbd = try Instance(config: oneHost)

    let connecting = try sbd.sb("host", "connect", "mini")
    try sbd.waitForLink("mini", .connected)
    let again = try sbd.sb("host", "connect", "mini")
    let closed = try sbd.sb("host", "disconnect", "mini")

    let first = fields(try #require(connecting.split(separator: "\n").first))
    #expect(first.count == 4)
    #expect(first[0] == "mini" && first[1] == "ssh" && first[3] == miniDestination)
    #expect(["connecting", "connected"].contains(first[2]))
    #expect(fields(try #require(again.split(separator: "\n").first)) == ["mini", "ssh", "connected", miniDestination])
    #expect(
      fields(try #require(closed.split(separator: "\n").first)) == ["mini", "ssh", "disconnected", miniDestination])
    #expect(sbd.sshStubMasters().count == 1)
  }

  @Test func aSharedHogliHostConnectsToItsCoderDestination() throws {
    let sbd = try Instance(config: Instance.hostsConfig(everySortOfHost))

    try sbd.sb("host", "connect", "devbox")
    let devbox = try sbd.waitForLink("devbox", .connected)

    let master = try #require(sbd.sshStubMasters().last)
    let dashes = try #require(master.firstIndex(of: "--"))
    #expect(devbox.destination == "coder.devbox-haacked")
    #expect(master[dashes + 1] == "coder.devbox-haacked")
    #expect(try sbd.hosts().first { $0.name == "mini" }?.link == .disconnected)
    #expect(sbd.sshStubMasters().count == 1)
  }

  @Test func reconnectsWithANewControlSocketAfterTheLinkDrops() throws {
    let sbd = try Instance(config: oneHost)
    try sbd.sb("host", "connect", "mini")
    try sbd.waitForLink("mini", .connected)

    let first = try sbd.dropLink("mini")
    let second = try sbd.waitFor(
      "a new master", fetch: { try sbd.sshStubPid(miniDestination) }, until: { $0 != first && !ended($0) })
    let connected = try sbd.waitForLink("mini", .connected)

    #expect(second != first)
    #expect(connected.error == nil)
    #expect(connected.retryAt == nil)
    #expect(!sbd.sshStubLog.contains("multiplexing disabled"))
    #expect(sbd.sshStubMasters().count == 2)
  }

  @Test func aRefusedLinkFollowsTheBackoffScheduleAndConnectsOnceTheRefusalIsGone() throws {
    // Without ticks of its own, sbd retries only on the tick that `clock` runs.
    let sbd = try Instance(config: oneHost.merging(["tickSeconds": 3600]) { $1 })
    try sbd.setSSHStub("refuse", refusal + "\n")
    try sbd.sb("host", "connect", "mini")

    for failures in 1...9 {
      let host = try sbd.waitForHost("mini", "failure \(failures)") {
        $0.link == .unreachable && $0.failures == failures
      }

      let since = try #require(host.since)
      let retryAt = try #require(host.retryAt)
      #expect(retryAt - since == retryDelayMs(failuresInARow: failures), "failures \(failures)")
      #expect(host.error == refusal)
      #expect(sbd.sshStubMasters().count == failures)
      // The `clock` request refuses an advance of 0, which is the first delay.
      try sbd.advanceClock(max(1, retryDelayMs(failuresInARow: failures)))
    }

    let down = try sbd.waitForHost("mini", "failure 10") { $0.link == .unreachable && $0.failures == 10 }
    let text = try sbd.sb("host", "ls").split(separator: "\n").map(String.init)
    try sbd.clearSSHStub("refuse")
    try sbd.sb("host", "connect", "mini")
    let connected = try sbd.waitForLink("mini", .connected)

    #expect(down.retryAt.map { $0 - (down.since ?? 0) } == 60_000)
    #expect(fields(text[0][...]) == ["mini", "ssh", "unreachable", miniDestination])
    #expect(text.contains("    \(refusal)"))
    #expect(text.contains { $0.range(of: #"^    Tries again in \d+ s$"#, options: .regularExpression) != nil })
    #expect(connected.failures == 0)
    #expect(connected.retryAt == nil)
    #expect(connected.error == nil)
    #expect(!sbd.sshStubLog.contains("multiplexing disabled"))
  }

  /// sbd's clock keeps running between two advances, so the test leaves the seventh delay,
  /// 32 s, a wide margin on both sides.
  @Test func aRefusedLinkDoesNotRetryBeforeItsTime() throws {
    let sbd = try Instance(config: oneHost.merging(["tickSeconds": 3600]) { $1 })
    try sbd.setSSHStub("refuse", refusal + "\n")
    try sbd.sb("host", "connect", "mini")
    for failures in 1...7 {
      try sbd.waitForHost("mini", "failure \(failures)") { $0.link == .unreachable && $0.failures == failures }
      if failures < 7 { try sbd.advanceClock(max(1, retryDelayMs(failuresInARow: failures))) }
    }

    try sbd.advanceClock(2_000)
    usleep(300_000)
    let early = try #require(try sbd.hosts().first)
    try sbd.advanceClock(retryDelayMs(failuresInARow: 7))
    let late = try sbd.waitForHost("mini", "failure 8") { $0.link == .unreachable && $0.failures == 8 }

    #expect(early.link == .unreachable)
    #expect(early.failures == 7)
    #expect(late.failures == 8)
    #expect(sbd.sshStubMasters().count == 8)
  }

  @Test func linksAreDisconnectedAfterSbdRestarts() throws {
    let sbd = try Instance(config: oneHost)
    try sbd.sb("host", "connect", "mini")
    try sbd.waitForLink("mini", .connected)
    let pid = try #require(try sbd.sshStubPid(miniDestination))

    sbd.stopSbd()
    try sbd.startSbd()
    try sbd.advanceClock(120_000)

    #expect(try sbd.hosts().first?.link == .disconnected)
    try sbd.waitFor("the stub's process to exit", timeout: 5) { ended(pid) }
    #expect(sbd.sshStubMasters().count == 1)
  }

  @Test func theStubExitsWithinFiveSecondsAfterSbdIsKilled() throws {
    let sbd = try Instance(config: oneHost)
    try sbd.sb("host", "connect", "mini")
    try sbd.waitForLink("mini", .connected)
    let pid = try #require(try sbd.sshStubPid(miniDestination))
    let alive = !ended(pid)

    sbd.killSbd()
    let killed = Date()
    while !ended(pid), Date().timeIntervalSince(killed) < 5 { usleep(50_000) }

    #expect(alive)
    #expect(ended(pid), "the stub's process \(pid) outlived sbd by 5 s")
  }

  // MARK: Refusals

  @Test(arguments: ["connect", "disconnect"])
  func refusesAnUnknownAnInvalidAndAPerSessionHost(verb: String) throws {
    let sbd = try Instance(config: Instance.hostsConfig(everySortOfHost))

    let unknown = try sbd.run("host", verb, "nope")
    let invalid = try sbd.run("host", verb, "typo")
    let perSession = try sbd.run("host", verb, "boxes")
    let noName = try sbd.run("host", verb)

    #expect(unknown.status == 1)
    #expect(unknown.stderr.contains("nope"))
    #expect(unknown.stdout.isEmpty)
    #expect(invalid.status == 1)
    #expect(invalid.stderr.contains("typo is not usable: \(workspaceProblem)"))
    #expect(perSession.status == 1)
    #expect(perSession.stderr.contains("boxes has a link per box, which this version does not open"))
    #expect(noName.status != 0)
    #expect(sbd.sshStubLog.isEmpty)
    #expect(try sbd.hosts().compactMap(\.link) == [.disconnected, .disconnected])
  }

  @Test func theLocalNameIsNotAHost() throws {
    let sbd = try Instance(config: Instance.hostsConfig(["local": Instance.sshHost(miniDestination)]))

    let listed = try sbd.hosts()
    let connect = try sbd.run("host", "connect", "local")

    #expect(listed.map(\.name) == ["local"])
    #expect(listed.first?.link == nil)
    #expect(listed.first?.problem?.contains("can't be local") == true)
    #expect(connect.status == 1)
    #expect(sbd.sshStubLog.isEmpty)
  }

  // MARK: Local sessions

  @Test func aLocalSessionRunsAsBeforeWithHostsInConfig() throws {
    let sbd = try Instance(config: Instance.hostsConfig(everySortOfHost))

    let s = try sbd.new(prompt: "hello there")
    let done = try sbd.waitFor(s.id, "the first turn's reply") { $0.lastReply == "Done: hello there" }

    #expect(done.live)
    #expect(done.state == .needsYou)
    #expect(
      sbd.stubArgs().first == "--session-id \(s.claudeSessionId) --settings \(sbd.home.claudeSettings) -- hello there")
    #expect(try sbd.sb("screen", s.id).contains("⏺ Done: hello there"))
    #expect(sbd.sshStubLog.isEmpty)
  }
}
