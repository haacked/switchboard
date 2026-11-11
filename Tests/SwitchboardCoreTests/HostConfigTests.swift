import Foundation
import Testing

@testable import SwitchboardCore

private let nameMessage = "its name may hold only lowercase letters, digits, _ and -, at most 32, and can't be local"
private let workspaceMessage = "a hogli host with the shared layout needs a workspace"

private let sshHost: [String: JSON] = ["kind": "ssh", "destination": "haacked@mini.local"]
private let sharedHost: [String: JSON] = ["kind": "hogli", "workspace": "devbox-haacked"]
private let perSessionHost: [String: JSON] = ["kind": "hogli", "layout": "perSession"]

/// The host with these keys set. A `.null` value removes its key.
private func with(_ base: [String: JSON], _ changes: [String: JSON]) -> JSON {
  var host = base
  for (key, value) in changes {
    host[key] = value == .null ? nil : value
  }
  return .object(host)
}

/// The host as `parse` reads it alone, under a valid name.
private func parsed(_ value: JSON, name: String = "h") -> (host: HostConfig?, problem: String?) {
  let result = HostConfig.parse([name: value])
  return (result.valid[name], result.invalid[name]?.problem)
}

/// A case of a rule: the base host and the keys that break the rule.
struct BrokenHost: CustomTestStringConvertible, Sendable {
  var label: String
  var value: JSON

  var testDescription: String { label }
}

private func broken(_ label: String, _ base: [String: JSON], _ changes: [String: JSON]) -> BrokenHost {
  BrokenHost(label: label, value: with(base, changes))
}

@Suite struct HostConfigTests {
  // MARK: Valid hosts

  @Test func theApprovedExampleParses() throws {
    let c = try JSONCoding.decode(
      Config.self,
      from: #"""
        {"hosts": {
          "devbox": {
            "kind": "hogli",
            "layout": "shared",
            "workspace": "devbox-haacked",
            "repos": { "PostHog/posthog": "~/posthog" },
            "worktreeRoot": "~/worktrees",
            "liveCap": 12,
            "account": "default",
            "autoStart": true,
            "linkIdleSeconds": 1800
          }
        }}
        """#)

    let devbox = try #require(c.hosts["devbox"])

    #expect(c.invalidHosts.isEmpty)
    #expect(Array(c.hosts.keys) == ["devbox"])
    #expect(devbox.name == "devbox")
    #expect(devbox.kind == .hogli)
    #expect(devbox.layout == .shared)
    #expect(devbox.workspace == "devbox-haacked")
    #expect(devbox.destination == nil)
    #expect(devbox.region == nil)
    #expect(devbox.repos == ["PostHog/posthog": "~/posthog"])
    #expect(devbox.worktreeRoot == "~/worktrees")
    #expect(devbox.liveCap == 12)
    #expect(devbox.account == "default")
    #expect(devbox.autoStart == true)
    #expect(devbox.linkIdleSeconds == 1800)
    #expect(devbox.sshDestination == "coder.devbox-haacked")
  }

  @Test func anSshHostParsesWithDefaults() throws {
    let r = parsed(.object(sshHost), name: "mini")

    let mini = try #require(r.host)

    #expect(r.problem == nil)
    #expect(mini.name == "mini")
    #expect(mini.kind == .ssh)
    #expect(mini.destination == "haacked@mini.local")
    #expect(mini.workspace == nil)
    #expect(mini.region == nil)
    #expect(mini.layout == .shared)
    #expect(mini.repos == [:])
    #expect(mini.worktreeRoot == "~/worktrees")
    #expect(mini.autoStart == true)
    #expect(mini.linkIdleSeconds == 1800)
    #expect(mini.liveCap == nil)
    #expect(mini.account == nil)
  }

  @Test func anSshHostTakesEveryKeyThatItsKindAllows() throws {
    let r = parsed(
      with(
        sshHost,
        [
          "layout": "shared", "repos": ["haacked/switchboard": "~/dev/switchboard"], "worktreeRoot": "/srv/trees",
          "liveCap": 1, "account": "work", "autoStart": false, "linkIdleSeconds": 1,
        ]))

    let host = try #require(r.host, "\(r.problem ?? "")")

    #expect(host.repos == ["haacked/switchboard": "~/dev/switchboard"])
    #expect(host.worktreeRoot == "/srv/trees")
    #expect(host.liveCap == 1)
    #expect(host.account == "work")
    #expect(host.autoStart == false)
    #expect(host.linkIdleSeconds == 1)
  }

  @Test(arguments: ["us-east-1", "eu-central-1", nil] as [String?])
  func aPerSessionHostParsesWithAnAllowedRegionOrNone(region: String?) throws {
    let r = parsed(with(perSessionHost, ["region": region.map(JSON.string) ?? .null]), name: "boxes")

    let boxes = try #require(r.host, "\(r.problem ?? "")")

    #expect(boxes.kind == .hogli)
    #expect(boxes.layout == .perSession)
    #expect(boxes.region == region)
    #expect(boxes.workspace == nil)
    #expect(boxes.destination == nil)
    #expect(boxes.sshDestination == nil)
  }

  @Test func autoStartAndLinkIdleSecondsAreAcceptedOnEveryKind() {
    let extra: [String: JSON] = ["autoStart": false, "linkIdleSeconds": 60]

    for base in [sshHost, sharedHost, perSessionHost] {
      let r = parsed(with(base, extra))
      #expect(r.problem == nil)
      #expect(r.host?.autoStart == false)
      #expect(r.host?.linkIdleSeconds == 60)
    }
  }

  @Test func anUnknownKeyIsIgnored() {
    let r = parsed(with(sshHost, ["colour": "blue", "Destination": 5]))

    #expect(r.problem == nil)
    #expect(r.host?.destination == "haacked@mini.local")
  }

  @Test func sshDestinationFollowsTheKindAndLayout() {
    #expect(parsed(.object(sshHost)).host?.sshDestination == "haacked@mini.local")
    #expect(parsed(.object(sharedHost)).host?.sshDestination == "coder.devbox-haacked")
    #expect(parsed(with(sharedHost, ["layout": "shared"])).host?.sshDestination == "coder.devbox-haacked")
    #expect(parsed(.object(perSessionHost)).host.map { $0.sshDestination == nil } == true)
  }

  @Test(arguments: ["a", "0", "0box", "a_b-c", "devbox", String(repeating: "a", count: 32), "locals", "my-local"])
  func aNameWithinTheRuleIsValid(name: String) {
    let r = parsed(.object(sshHost), name: name)

    #expect(r.problem == nil)
    #expect(r.host?.name == name)
  }

  // MARK: Rules 1 to 12

  @Test(arguments: [
    "local", "Devbox", "DEVBOX", "", "-box", "_box", "a.b", "a b", "a/b", "a:b", "box\n", "bóx", "../x",
    String(repeating: "a", count: 33),
  ])
  func rule1RefusesANameOutsideTheRule(name: String) {
    let r = parsed(.object(sshHost), name: name)

    #expect(r.host == nil)
    #expect(r.problem == nameMessage)
  }

  @Test func rule1ComesBeforeEveryOtherRule() {
    let r = parsed(["kind": "hogli"], name: "Typo")

    #expect(r.problem == nameMessage)
  }

  @Test(arguments: ["a string", 5, true, .null, ["kind", "ssh"]] as [JSON])
  func rule2RefusesAValueThatIsNotAnObject(value: JSON) {
    let r = parsed(value)

    #expect(r.host == nil)
    #expect(r.problem?.isEmpty == false)
  }

  @Test(arguments: [
    broken("no kind", sshHost, ["kind": .null]),
    broken("an unknown kind", sshHost, ["kind": "docker"]),
    broken("a kind in capitals", sshHost, ["kind": "SSH"]),
    broken("an empty kind", sshHost, ["kind": ""]),
    broken("a kind that is a number", sshHost, ["kind": 5]),
  ])
  func rule3RefusesAMissingOrUnknownKind(host: BrokenHost) {
    let r = parsed(host.value)

    #expect(r.host == nil)
    #expect(r.problem?.isEmpty == false)
  }

  @Test(arguments: [
    ("destination", broken("destination", sshHost, ["destination": 5])),
    ("workspace", broken("workspace", sharedHost, ["workspace": 5])),
    ("region", broken("region", perSessionHost, ["region": 5])),
    ("layout", broken("layout", sshHost, ["layout": 5])),
    ("repos", broken("repos as an array", sshHost, ["repos": ["a/b"]])),
    ("repos", broken("repos as a string", sshHost, ["repos": "a/b"])),
    ("repos", broken("a repo that is a number", sshHost, ["repos": ["a/b": 5]])),
    ("worktreeRoot", broken("worktreeRoot", sshHost, ["worktreeRoot": 5])),
    ("liveCap", broken("liveCap as a string", sshHost, ["liveCap": "3"])),
    ("liveCap", broken("liveCap as a bool", sshHost, ["liveCap": true])),
    ("account", broken("account", sshHost, ["account": 5])),
    ("autoStart", broken("autoStart as a string", sshHost, ["autoStart": "yes"])),
    ("autoStart", broken("autoStart as a number", sshHost, ["autoStart": 1])),
    ("linkIdleSeconds", broken("linkIdleSeconds", sshHost, ["linkIdleSeconds": "1800"])),
  ])
  func rule4RefusesAKnownKeyOfTheWrongTypeAndNamesTheKey(key: String, host: BrokenHost) {
    let r = parsed(host.value)

    #expect(r.host == nil)
    #expect(r.problem?.contains(key) == true, "\(r.problem ?? "no problem")")
  }

  @Test(arguments: ["both", "Shared", "persession", ""])
  func rule5RefusesAnUnknownLayout(layout: String) {
    for base in [sshHost, sharedHost] {
      let r = parsed(with(base, ["layout": .string(layout)]))

      #expect(r.host == nil)
      #expect(r.problem?.isEmpty == false)
    }
  }

  @Test(arguments: [
    broken("no destination", sshHost, ["destination": .null]),
    broken("an empty destination", sshHost, ["destination": ""]),
    broken("a destination that is an option", sshHost, ["destination": "-oProxyCommand=touch /tmp/x"]),
    broken("a destination that is a lone dash", sshHost, ["destination": "-"]),
    broken("a destination with a space", sshHost, ["destination": "mini.local exec"]),
    broken("a destination with a leading space", sshHost, ["destination": " mini.local"]),
    broken("a destination with a tab", sshHost, ["destination": "mini\t.local"]),
    broken("a destination with a newline", sshHost, ["destination": "mini.local\n"]),
    broken("a destination with a carriage return", sshHost, ["destination": "mini.local\r"]),
    broken("a destination with a NUL", sshHost, ["destination": "mini\u{0}.local"]),
    broken("a destination with an escape", sshHost, ["destination": "mini\u{1B}[0m.local"]),
    broken("a destination with a DEL", sshHost, ["destination": "mini\u{7F}.local"]),
    broken("the perSession layout", sshHost, ["layout": "perSession"]),
    broken("a workspace", sshHost, ["workspace": "devbox-haacked"]),
    broken("a region", sshHost, ["region": "us-east-1"]),
  ])
  func rule6RefusesAnSshHostWithABadDestinationOrAHogliKey(host: BrokenHost) {
    let r = parsed(host.value)

    #expect(r.host == nil)
    #expect(r.problem?.isEmpty == false)
  }

  @Test func rule7SaysThatASharedHogliHostNeedsAWorkspace() {
    #expect(parsed(["kind": "hogli"]).problem == workspaceMessage)
    #expect(parsed(["kind": "hogli", "layout": "shared"]).problem == workspaceMessage)
  }

  @Test(arguments: [
    broken("an empty workspace", sharedHost, ["workspace": ""]),
    broken("a workspace that starts with a dash", sharedHost, ["workspace": "-devbox"]),
    broken("a workspace with an underscore", sharedHost, ["workspace": "devbox_haacked"]),
    broken("a workspace with a dot", sharedHost, ["workspace": "devbox.haacked"]),
    broken("a workspace with a space", sharedHost, ["workspace": "devbox haacked"]),
    broken("a workspace with a newline", sharedHost, ["workspace": "devbox\n"]),
    broken("a workspace of 33 characters", sharedHost, ["workspace": .string(String(repeating: "a", count: 33))]),
    broken("a destination", sharedHost, ["destination": "haacked@mini.local"]),
    broken("a region", sharedHost, ["region": "us-east-1"]),
    broken("a region with the layout named", sharedHost, ["layout": "shared", "region": "eu-central-1"]),
  ])
  func rule7RefusesASharedHogliHostWithABadWorkspaceOrAnSshKey(host: BrokenHost) {
    let r = parsed(host.value)

    #expect(r.host == nil)
    #expect(r.problem?.isEmpty == false)
  }

  @Test func rule7AcceptsAWorkspaceAtTheEdgesOfItsPattern() {
    for workspace in ["a", "A", "0", "Devbox-Haacked-2", String(repeating: "a", count: 32)] {
      let r = parsed(with(sharedHost, ["workspace": .string(workspace)]))
      #expect(r.problem == nil, "\(workspace)")
      #expect(r.host?.sshDestination == "coder.\(workspace)")
    }
  }

  @Test(arguments: [
    broken("a workspace", perSessionHost, ["workspace": "devbox-haacked"]),
    broken("a worktreeRoot", perSessionHost, ["worktreeRoot": "~/worktrees"]),
    broken("a destination", perSessionHost, ["destination": "haacked@mini.local"]),
    broken("a region outside the list", perSessionHost, ["region": "us-west-2"]),
    broken("an empty region", perSessionHost, ["region": ""]),
    broken("a region in capitals", perSessionHost, ["region": "US-EAST-1"]),
  ])
  func rule8RefusesAPerSessionHostWithASharedKeyOrAnUnknownRegion(host: BrokenHost) {
    let r = parsed(host.value)

    #expect(r.host == nil)
    #expect(r.problem?.isEmpty == false)
  }

  @Test(arguments: [
    broken("a repo with no owner", sshHost, ["repos": ["posthog": "~/posthog"]]),
    broken("a repo with an empty owner", sshHost, ["repos": ["/posthog": "~/posthog"]]),
    broken("a repo with an empty name", sshHost, ["repos": ["PostHog/": "~/posthog"]]),
    broken("a repo with three parts", sshHost, ["repos": ["PostHog/posthog/x": "~/posthog"]]),
    broken("an empty repo key", sshHost, ["repos": ["": "~/posthog"]]),
    broken("an empty checkout", sshHost, ["repos": ["PostHog/posthog": ""]]),
    broken("one bad repo among good ones", sharedHost, ["repos": ["PostHog/posthog": "~/posthog", "bad": "~/bad"]]),
  ])
  func rule9RefusesARepoKeyThatIsNotOwnerNameOrAnEmptyCheckout(host: BrokenHost) {
    let r = parsed(host.value)

    #expect(r.host == nil)
    #expect(r.problem?.isEmpty == false)
  }

  @Test(arguments: [
    broken("liveCap 0", sshHost, ["liveCap": 0]),
    broken("liveCap -1", sshHost, ["liveCap": -1]),
    broken("linkIdleSeconds 0", sshHost, ["linkIdleSeconds": 0]),
    broken("linkIdleSeconds -5", sshHost, ["linkIdleSeconds": -5]),
    broken("liveCap 0 on a perSession host", perSessionHost, ["liveCap": 0]),
  ])
  func rule10RefusesALiveCapOrLinkIdleSecondsBelowOne(host: BrokenHost) {
    let r = parsed(host.value)

    #expect(r.host == nil)
    #expect(r.problem?.isEmpty == false)
  }

  @Test func rule11RefusesAnEmptyAccount() {
    for base in [sshHost, sharedHost, perSessionHost] {
      let r = parsed(with(base, ["account": ""]))

      #expect(r.host == nil)
      #expect(r.problem?.isEmpty == false)
    }
  }

  @Test func rule12RefusesTheLaterOfTwoHostsWithOneDestination() {
    let r = HostConfig.parse([
      "a": ["kind": "ssh", "destination": "coder.devbox-haacked"],
      "b": ["kind": "hogli", "workspace": "devbox-haacked"],
      "c": ["kind": "ssh", "destination": "haacked@mini.local"],
    ])

    #expect(Set(r.valid.keys) == ["a", "c"])
    #expect(
      r.invalid.mapValues(\.problem) == ["b": "its destination coder.devbox-haacked is also the destination of a"])
  }

  @Test func rule12OrdersHostsByNameNotByTheirOrderInTheFile() {
    let r = HostConfig.parse([
      "zeta": sshHost.jsonObject, "alpha": sshHost.jsonObject, "mid": sshHost.jsonObject,
    ])

    #expect(Array(r.valid.keys) == ["alpha"])
    #expect(Set(r.invalid.keys) == ["mid", "zeta"])
    #expect(r.invalid["mid"]?.problem == "its destination haacked@mini.local is also the destination of alpha")
  }

  @Test func rule12LetsAValidHostTakeTheDestinationOfAnInvalidHost() {
    let r = HostConfig.parse([
      "a": with(sshHost, ["workspace": "devbox-haacked"]),
      "b": .object(sshHost),
      "c": .object(sshHost),
    ])

    #expect(Array(r.valid.keys) == ["b"])
    #expect(r.invalid["a"]?.problem == "an ssh host can't have a workspace")
    #expect(r.invalid["c"]?.problem == "its destination haacked@mini.local is also the destination of b")
  }

  @Test func rule12LeavesPerSessionHostsAlone() {
    let r = HostConfig.parse(["boxes": perSessionHost.jsonObject, "more-boxes": perSessionHost.jsonObject])

    #expect(Set(r.valid.keys) == ["boxes", "more-boxes"])
    #expect(r.invalid.isEmpty)
  }

  @Test func parseReturnsEveryHostOnExactlyOneSide() {
    let r = HostConfig.parse([
      "mini": sshHost.jsonObject, "devbox": sharedHost.jsonObject, "boxes": perSessionHost.jsonObject,
      "typo": ["kind": "hogli"], "Bad": sshHost.jsonObject, "text": "ssh",
    ])

    #expect(Set(r.valid.keys) == ["mini", "devbox", "boxes"])
    #expect(Set(r.invalid.keys) == ["typo", "Bad", "text"])
    #expect(r.invalid["typo"]?.problem == workspaceMessage)
    #expect(r.valid.allSatisfy { $0.key == $0.value.name })
  }

  // MARK: Config

  @Test func configDefaultsToSshOnThePathAndNoHosts() throws {
    let c = try JSONCoding.decode(Config.self, from: "{}")

    #expect(c.ssh == "ssh")
    #expect(c.hosts.isEmpty)
    #expect(c.invalidHosts.isEmpty)
    #expect(Config().ssh == "ssh")
    #expect(Config().hosts.isEmpty)
  }

  @Test func configReadsTheSshCommand() throws {
    let c = try JSONCoding.decode(Config.self, from: #"{"ssh": "/tmp/ssh-stub"}"#)

    #expect(c.ssh == "/tmp/ssh-stub")
  }

  @Test func anInvalidHostLeavesTheOtherHostsAndTheRestOfTheConfig() throws {
    let c = try JSONCoding.decode(
      Config.self,
      from: #"""
        {"env": {"CLAUDE_CONFIG_DIR": "/x"}, "liveCap": 3, "ssh": "/tmp/ssh-stub",
         "mcpServers": {"db": {"type": "sse", "command": "/bin/db"}},
         "hosts": {
           "mini": {"kind": "ssh", "destination": "haacked@mini.local"},
           "typo": {"kind": "hogli"},
           "text": "haacked@mini.local",
           "boxes": {"kind": "hogli", "layout": "perSession", "region": "eu-central-1"}}}
        """#)

    #expect(c.env == ["CLAUDE_CONFIG_DIR": "/x"])
    #expect(c.liveCap == 3)
    #expect(c.ssh == "/tmp/ssh-stub")
    #expect(Array(c.mcpServers.keys) == ["db"])
    #expect(Set(c.hosts.keys) == ["mini", "boxes"])
    #expect(Set(c.invalidHosts.keys) == ["typo", "text"])
    #expect(c.invalidHosts["typo"]?.problem == workspaceMessage)
    #expect(c.hosts["boxes"]?.region == "eu-central-1")
  }

  @Test(arguments: [#"["mini"]"#, #""mini""#, "5", "true", "null"])
  func hostsThatIsNotAnObjectLoadsAsNoHostsAndKeepsTheRest(hosts: String) throws {
    let c = try JSONCoding.decode(Config.self, from: #"{"env": {"A": "b"}, "liveCap": 3, "hosts": \#(hosts)}"#)

    #expect(c.hosts.isEmpty)
    #expect(c.invalidHosts.isEmpty)
    #expect(c.env == ["A": "b"])
    #expect(c.liveCap == 3)
  }

  @Test func invalidHostsIsNotAKeyOfTheEncodedConfig() throws {
    let c = try JSONCoding.decode(
      Config.self, from: #"{"hosts": {"mini": {"kind": "ssh", "destination": "m"}, "typo": {"kind": "hogli"}}}"#)

    let encoded = try #require(JSON.parse(try JSONCoding.encode(c))?.object)

    #expect(c.invalidHosts.count == 1)
    #expect(encoded["invalidHosts"] == nil)
    #expect(encoded["hosts"]?["mini"]?["destination"] == "m")
    #expect(encoded["ssh"] == "ssh")
  }

  @Test func configKeepsTheKindOfAnInvalidHostOnlyWhenItIsAKnownKind() throws {
    let c = try JSONCoding.decode(
      Config.self,
      from: #"{"hosts": {"typo": {"kind": "hogli"}, "odd": {"kind": "docker"}, "text": "ssh", "Bad": {"kind": "ssh"}}}"#
    )

    #expect(c.invalidHosts.mapValues(\.kind) == ["typo": .hogli, "odd": nil, "text": nil, "Bad": .ssh])
  }

  @Test func homeKeepsControlSocketsInItsSshFolder() {
    #expect(Home(path: "/tmp/sb-home").sshFolder == "/tmp/sb-home/ssh")
  }

  // MARK: HostStatus

  @Test func hostStatusLeavesOutAKeyWithNoValue() throws {
    let rows = [
      #"{"kind":"hogli","name":"boxes"}"#,
      #"{"destination":"coder.devbox-haacked","failures":0,"kind":"hogli","link":"connected","name":"devbox","since":1794377410000}"#,
      #"{"destination":"haacked@mini.local","error":"ssh: connect to host mini.local port 22: Operation timed out","failures":3,"kind":"ssh","link":"unreachable","name":"mini","retryAt":1794377502000,"since":1794377500000}"#,
      #"{"kind":"hogli","name":"typo","problem":"a hogli host with the shared layout needs a workspace"}"#,
    ]

    for row in rows {
      let status = try JSONCoding.decode(HostStatus.self, from: row)
      #expect(try JSONCoding.encode(status) == row)
    }
  }

  @Test func hostStatusDecodesTheDocumentedRow() throws {
    let mini = try JSONCoding.decode(
      HostStatus.self,
      from: #"""
        {"name": "mini", "kind": "ssh", "destination": "haacked@mini.local", "link": "unreachable",
         "since": 1794377500000, "failures": 3, "retryAt": 1794377502000,
         "error": "ssh: connect to host mini.local port 22: Operation timed out"}
        """#)

    #expect(mini.name == "mini")
    #expect(mini.kind == "ssh")
    #expect(mini.destination == "haacked@mini.local")
    #expect(mini.link == .unreachable)
    #expect(mini.since == 1_794_377_500_000)
    #expect(mini.failures == 3)
    #expect(mini.retryAt == 1_794_377_502_000)
    #expect(mini.error == "ssh: connect to host mini.local port 22: Operation timed out")
    #expect(mini.problem == nil)
  }

  @Test func linkStatesHaveTheDocumentedNames() {
    #expect(
      [LinkState.disconnected, .connecting, .connected, .unreachable].map(\.rawValue) == [
        "disconnected", "connecting", "connected", "unreachable",
      ])
    #expect([HostKind.hogli, .ssh].map(\.rawValue) == ["hogli", "ssh"])
    #expect([HostLayout.shared, .perSession].map(\.rawValue) == ["shared", "perSession"])
  }
}

@Suite struct RetryDelayTests {
  private let schedule: [Int64] = [0, 0, 1000, 2000, 4000, 8000, 16000, 32000, 60000, 60000, 60000]

  @Test func retryDelayDoublesFromOneSecondUpToAMinute() {
    #expect((0...10).map { retryDelayMs(failuresInARow: $0) } == schedule)
  }

  @Test(arguments: [11, 64, 65, 1000, Int.max])
  func retryDelayStaysAtAMinuteForAnyLongerRun(failures: Int) {
    #expect(retryDelayMs(failuresInARow: failures) == 60000)
  }

  @Test func retryDelayIsZeroBelowOneFailure() {
    #expect(retryDelayMs(failuresInARow: -1) == 0)
  }

  @Test func theMCPRestartDelayStillFollowsTheSameSchedule() {
    #expect((0...10).map { MCPServer.restartDelayMs(exitsInARow: $0) } == schedule)
    #expect(MCPServer.restartDelayMs(exitsInARow: 1000) == 60000)
    #expect((0...70).allSatisfy { MCPServer.restartDelayMs(exitsInARow: $0) == retryDelayMs(failuresInARow: $0) })
  }
}

extension [String: JSON] {
  fileprivate var jsonObject: JSON { .object(self) }
}
