import Foundation
import SwitchboardCore
import Testing

/// Runs sbd with a tmux whose `list-panes` fails while a flag file exists.
@Suite struct PaneListTests {
  private func failingListPanes() throws -> (tmux: String, flag: String) {
    let real = try #require(findExecutable("tmux"))
    var template = Array("/tmp/sbl.XXXXXX".utf8CString)
    let dir = String(cString: try #require(mkdtemp(&template)))
    let (script, flag) = ("\(dir)/tmux", "\(dir)/fail")
    let body = """
      #!/bin/sh
      if [ -e '\(flag)' ]; then
        for a in "$@"; do
          if [ "$a" = list-panes ]; then echo "server exited unexpectedly" >&2; exit 1; fi
        done
      fi
      exec '\(real)' "$@"

      """
    try body.write(toFile: script, atomically: true, encoding: .utf8)
    chmod(script, 0o755)
    return (script, flag)
  }

  @Test(.timeLimit(.minutes(1))) func aFailedPaneListDoesNotStartThePanesAgain() throws {
    let (tmux, flag) = try failingListPanes()
    defer { try? FileManager.default.removeItem(atPath: (flag as NSString).deletingLastPathComponent) }
    let sbd = try Instance(config: ["tmux": .string(tmux)])
    let s = try sbd.new()
    // A tick records `exited` only for a live claude, so the failure must start after claude is live.
    try sbd.waitFor(s.id, "claude to start") { $0.live }
    _ = try sbd.client.terminals(s.id)
    FileManager.default.createFile(atPath: flag, contents: nil)
    // The tick reads the panes every 0.2 s. A request that acts on processes reads them too.
    usleep(600_000)
    _ = try sbd.client.terminals(s.id)
    #expect(try sbd.get(s.id).live)
    try FileManager.default.removeItem(atPath: flag)
    _ = try sbd.client.terminals(s.id)
    #expect(try sbd.get(s.id).live)
    let kinds = try sbd.events(s.id).map(\.kind)
    #expect(!kinds.contains("exited"))
    #expect(kinds.filter { $0 == "started" || $0 == "resumed" }.count == 1)
  }
}
