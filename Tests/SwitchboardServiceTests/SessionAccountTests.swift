import Foundation
import SwitchboardCore
import Testing

@testable import SwitchboardService

/// The key that events, logs, and quota lookups record for a session's account.
@Suite struct SessionAccountKey {
  @Test func aLocalAccountIsKeyedByItsNormalizedFolder() {
    #expect(SessionAccount.local(ClaudeAccount(folder: "~/.claude-work/")).key == "\(NSHomeDirectory())/.claude-work")
  }

  @Test func theDefaultAccountIsKeyedByTheDefaultFolder() {
    #expect(SessionAccount.local(ClaudeAccount(folder: "~/.claude")).key == ClaudeAccount.defaultFolder)
  }

  @Test func aHostIsKeyedByItsLoginLabel() {
    #expect(SessionAccount.host("mini").key == "mini:~/.claude")
  }

  @Test func aHostLabelNeverEqualsALocalAccount() {
    #expect(SessionAccount.host("mini") != .local(ClaudeAccount(folder: "mini:~/.claude")))
  }
}

/// Risk 1: the host label reaches `headlessEnv` and quota lookups, which treat a Codex folder as no Claude
/// account. The label names the host's ~/.claude, so it never reads as a Codex folder, whatever the host's name.
@Suite struct SessionAccountHostLabel {
  @Test(.timeLimit(.minutes(1)), arguments: ["mini", "codex", ".codex", ".codex-x", "codex-work"])
  func aHostLabelIsNeverACodexFolder(_ host: String) throws {
    try withService { service, _ in
      #expect(service.queue.sync { service.codexName(SessionAccount.host(host).key) } == nil)
    }
  }
}
