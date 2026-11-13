import Foundation
import Testing

@testable import SwitchboardCore

private let sshHost: [String: JSON] = ["kind": "ssh", "destination": "haacked@mini.local"]
private let sharedHost: [String: JSON] = ["kind": "hogli", "workspace": "devbox-haacked"]

private func parsed(_ base: [String: JSON], _ changes: [String: JSON] = [:]) -> (host: HostConfig?, problem: String?) {
  let result = HostConfig.parse(["h": .object(base.merging(changes) { $1 })])
  return (result.valid["h"], result.invalid["h"]?.problem)
}

/// A host's `claude`, `tmux`, and `shell` keys, which mean what the top-level keys of the same names mean.
@Suite struct RemoteHostConfigTests {
  @Test func aHostWithoutTheKeysHasNone() throws {
    let host = try #require(parsed(sshHost).host)

    #expect(host.claude == nil)
    #expect(host.tmux == nil)
    #expect(host.shell == nil)
  }

  @Test(arguments: ["ssh", "hogli"])
  func aHostHoldsItsClaudeTmuxAndShell(kind: String) throws {
    let base = kind == "ssh" ? sshHost : sharedHost

    let host = try #require(
      parsed(base, ["claude": "/opt/claude/bin/claude", "tmux": "/usr/local/bin/tmux", "shell": "/bin/zsh"]).host)

    #expect(host.claude == "/opt/claude/bin/claude")
    #expect(host.tmux == "/usr/local/bin/tmux")
    #expect(host.shell == "/bin/zsh")
  }

  @Test func aKeyKeepsItsTextAsWritten() throws {
    let host = try #require(parsed(sshHost, ["claude": "claude --verbose", "shell": "~/bin/my shell"]).host)

    #expect(host.claude == "claude --verbose")
    #expect(host.shell == "~/bin/my shell")
  }

  @Test(arguments: ["claude", "tmux", "shell"])
  func aNullKeyReadsAsAbsent(key: String) throws {
    let host = try #require(parsed(sshHost, [key: .null]).host)

    #expect(host.claude == nil && host.tmux == nil && host.shell == nil)
  }

  @Test(arguments: ["claude", "tmux", "shell"])
  func anEmptyKeyMakesTheHostInvalid(key: String) throws {
    let result = parsed(sshHost, [key: ""])

    #expect(result.host == nil)
    #expect(result.problem?.contains("its \(key) ") == true, "\(result.problem ?? "nil")")
  }

  @Test(arguments: ["claude", "tmux", "shell"])
  func aKeyThatIsNotAStringMakesTheHostInvalid(key: String) throws {
    for value: JSON in [7, true, ["claude"], ["path": "claude"]] {
      let result = parsed(sshHost, [key: value])

      #expect(result.host == nil, "\(value.text)")
      #expect(result.problem == "its \(key) must be a string", "\(value.text)")
    }
  }

  @Test func oneBadKeyDoesNotHideAnotherHost() throws {
    let result = HostConfig.parse(["bad": .object(sshHost.merging(["tmux": ""]) { $1 }), "good": .object(sharedHost)])

    #expect(result.valid.keys.sorted() == ["good"])
    #expect(result.invalid.keys.sorted() == ["bad"])
  }

  @Test func theKeysReachTheConfigThatSbdLoads() throws {
    let config = try JSONCoding.decode(
      Config.self,
      from: #"""
        {"claude": "claude", "shell": "/bin/zsh", "hosts": {
          "mini": {"kind": "ssh", "destination": "haacked@mini.local", "claude": "/box/claude", "shell": "/bin/sh"}
        }}
        """#)

    let host = try #require(config.hosts["mini"])
    #expect(host.claude == "/box/claude")
    #expect(host.shell == "/bin/sh")
    #expect(host.tmux == nil)
    #expect(config.claude == "claude")
    #expect(config.shell == "/bin/zsh")
    #expect(config.invalidHosts.isEmpty)
  }

  @Test func twoHostsThatDifferOnlyInAKeyAreNotEqual() throws {
    let plain = try #require(parsed(sshHost).host)
    let withClaude = try #require(parsed(sshHost, ["claude": "/box/claude"]).host)

    #expect(plain != withClaude)
  }
}

/// The `host` field of a session and of the requests and answers that carry it. Nil means this Mac, and a nil
/// field is absent from JSON, so a record and an answer for a local session read as they do on main.
@Suite struct SessionHostTests {
  /// A session record as an sbd without remote hosts stored it.
  private let stored = #"""
    {"id": "s1", "name": "one", "cwd": "/a", "claudeSessionId": "u1", "created": 5, "started": true, "done": false}
    """#

  @Test func aSessionRecordWithoutAHostDecodesWithNoHost() throws {
    let session = try JSONCoding.decode(Session.self, from: stored)

    #expect(session.host == nil)
    #expect(session.id == "s1")
    #expect(session.cwd == "/a")
    #expect(session.started)
  }

  @Test func aNewSessionHasNoHost() {
    #expect(Session(id: "s1", name: "one", cwd: "/a", claudeSessionId: "u1", created: 5).host == nil)
  }

  @Test func aLocalSessionEncodesWithNoHostKey() throws {
    let session = Session(id: "s1", name: "one", cwd: "/a", claudeSessionId: "u1", created: 5)

    let json = try JSON(encoding: session)

    #expect(json.object?.keys.contains("host") == false)
    #expect(try JSONCoding.convert(json, to: Session.self) == session)
  }

  @Test func aSessionsHostSurvivesItsRecord() throws {
    var session = Session(id: "s1", name: "one", cwd: "/home/haacked/repo", claudeSessionId: "u1", created: 5)
    session.host = "mini"

    let json = try JSON(encoding: session)
    let back = try JSONCoding.convert(json, to: Session.self)

    #expect(json["host"] == "mini")
    #expect(back.host == "mini")
    #expect(back == session)
    #expect(back != Session(id: "s1", name: "one", cwd: "/home/haacked/repo", claudeSessionId: "u1", created: 5))
  }

  @Test func aNewRequestCarriesItsHostAndItsFolderAsTyped() throws {
    let request = try JSONCoding.decode(NewSession.self, from: #"{"path": "~/repo", "host": "mini"}"#)

    #expect(request.host == "mini")
    #expect(request.path == "~/repo")
  }

  @Test func aNewRequestWithoutAHostHasNone() throws {
    let request = try JSONCoding.decode(NewSession.self, from: #"{"path": "/a"}"#)

    #expect(request.host == nil)
    #expect(try JSON(encoding: request).object?.keys.contains("host") == false)
  }

  @Test func terminalsWithoutAHostDecodeAndEncodeAsOnMain() throws {
    let local = Terminals(
      tmux: "/opt/homebrew/bin/tmux", socket: "/Users/h/.sb/tmux.sock", claude: "s1-claude", shell: "s1-shell")

    let json = try JSON(encoding: local)
    let decoded = try JSONCoding.decode(
      Terminals.self,
      from:
        #"{"tmux": "/opt/homebrew/bin/tmux", "socket": "/Users/h/.sb/tmux.sock", "claude": "s1-claude", "shell": "s1-shell"}"#
    )

    #expect(local.host == nil)
    #expect(json.object?.keys.sorted() == ["claude", "shell", "socket", "tmux"])
    #expect(decoded == local)
  }

  @Test func terminalsCarryTheHostOfARemoteSession() throws {
    let remote = try JSONCoding.decode(
      Terminals.self,
      from:
        #"{"tmux": "/usr/bin/tmux", "socket": "/home/h/.sb/tmux.sock", "claude": "s1-claude", "shell": "s1-shell", "host": "mini"}"#
    )

    #expect(remote.host == "mini")
    #expect(try JSON(encoding: remote)["host"] == "mini")
    #expect(
      remote
        != Terminals(tmux: "/usr/bin/tmux", socket: "/home/h/.sb/tmux.sock", claude: "s1-claude", shell: "s1-shell"))
  }
}
