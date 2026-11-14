import Foundation
import SwitchboardCore
import Testing

private let refusal = "ssh: connect to host mini.local port 22: Connection refused"

/// `sb` on a remote host, end to end over the ssh stub: the box's `~/.sb/bin/sb` runs the shim's `cli`, the
/// forward carries the request to the host's socket, and sbd runs this Mac's `sb` in its sandbox as a client of
/// that socket. `BoxShimTests`, `HostCLITests`, and `CLISandboxTests` cover each part's shapes.
@Suite(.blocking(timeLimit: .seconds(180))) struct RemoteCLITests {
  /// One instance walks every step, because each step needs the real forward and listener, and each new instance
  /// would start the box again.
  @Test func aSessionOnTheBoxRunsSbThroughTheShim() throws {
    let sbd = try Instance.remote(config: Instance.shortHostWait)
    let local = try sbd.new()
    let s = try sbd.startOnHost()
    let box = ["SB_SESSION_ID": s.id]
    let claude = ["SB_SESSION_ID": s.id, "CLAUDECODE": "1"]
    #expect(FileManager.default.isExecutableFile(atPath: "\(sbd.boxSB)/bin/sb"), "setup wrote no ~/.sb/bin/sb")

    let ls = try sbd.boxSb(["ls", "--json"], env: box)
    #expect(ls.status == 0, "\(text(ls))")
    let listed = (JSON.parse(ls.stdout)?.array ?? []).compactMap { $0["id"]?.string }
    #expect(listed == [s.id], "\(ls.stdout)")

    let sentBefore = try sbd.events(local.id, kind: "sent").count
    let send = try sbd.boxSb(["send", local.id, "hi"], env: box)
    #expect(send.status == 1, "\(text(send))")
    #expect(send.stderr.contains("that session is not on mini"), "\(send.stderr)")
    #expect(try sbd.events(local.id, kind: "sent").count == sentBefore)

    let marker = "card-\(UUID().uuidString)"
    let card = Data(JSON.object(["summary": .string(marker)]).text.utf8)
    let summary = try sbd.boxSb(["summary", "set"], env: claude, stdin: card)
    #expect(summary.status == 0, "\(text(summary))")
    let cards = try sbd.events(s.id, kind: Triage.sessionEvent)
    #expect(cards.contains { $0.data["summary"]?.string == marker }, "\(cards.map(\.data))")

    let allow = try sbd.boxSb(["allow", s.id], env: claude)
    #expect(allow.status == 1, "\(text(allow))")
    #expect(allow.stderr.contains("allow answers for you, so it doesn't run inside Claude Code"), "\(allow.stderr)")

    let named = try sbd.macCalls(holding: sbd.namesOfRemoteSession(s.id, cwd: s.cwd) + [s.claudeSessionId])
    #expect(
      named.isEmpty, "this Mac's machine log holds \(named.count) calls for the remote session: \(named.prefix(3))")

    try sbd.dropLinkAndRefuse(refusal)
    let started = Date()
    let down = try sbd.boxSb(["ls"], env: box)
    let seconds = Date().timeIntervalSince(started)
    #expect(down.status == 1, "\(text(down))")
    #expect(seconds < 3, "the box's sb took \(seconds) s with the link down")
    #expect(down.stderr.contains("can't reach Switchboard on the Mac"), "\(down.stderr)")
  }

  /// A child that a session on the box starts runs on the box, with that session as its parent, whether `sb spawn`
  /// or `sb new` starts it. It is the one end-to-end proof of host inheritance through the shim.
  @Test func aChildStartedFromTheBoxRunsOnTheBox() throws {
    let sbd = try Instance.remote(config: Instance.shortHostWait)
    let repo = try Repos.create("\(sbd.boxHome)/sb-box-repo", origin: "https://github.com/o/n.git")
    try sbd.restart(
      setting: "hosts",
      to: ["mini": Instance.remoteHost(Instance.boxDestination, ["repos": ["o/n": .string(repo)]])])
    let parent = try sbd.startOnHost()
    try sbd.makeBoxFolder("repo2")
    try sbd.makeBoxFolder("repo3")
    let claude = ["SB_SESSION_ID": parent.id, "CLAUDECODE": "1"]

    let spawned = try sbd.boxSb(["spawn", "--repo", "o/n", "--branch", "b", "--prompt", "p", "--json"], env: claude)
    let made = try sbd.boxSb(["new", "~/repo2", "--json"], env: claude)
    let toMac = try sbd.boxSb(["new", "~/repo2", "--host", "local", "--json"], env: claude)
    let relative = try sbd.boxSb(["new", "repo3", "--json"], env: claude)

    #expect(spawned.status == 0, "\(text(spawned))")
    #expect(made.status == 0, "\(text(made))")
    for child in [spawned, made] {
      let summary = try #require(JSON.parse(child.stdout), "\(child.stdout)")
      let id = try sbd.id(of: summary)
      let saved = try sbd.summaryJSON(id)
      #expect(saved["host"] == "mini", "\(saved.text)")
      #expect(saved["parent"]?.string == parent.id, "\(saved.text)")
    }
    let madeCwd = JSON.parse(made.stdout)?["cwd"]?.string
    #expect(madeCwd.map(real) == real("\(sbd.boxHome)/repo2"), "\(madeCwd ?? "")")
    #expect(relative.status == 0, "\(text(relative))")
    let relativeCwd = JSON.parse(relative.stdout)?["cwd"]?.string
    #expect(relativeCwd.map(real) == real("\(sbd.boxHome)/repo3"), "\(relativeCwd ?? "")")
    #expect(toMac.status == 1, "\(text(toMac))")
    #expect(toMac.stderr.contains("a session on mini can start sessions only on mini"), "\(toMac.stderr)")
  }
}
