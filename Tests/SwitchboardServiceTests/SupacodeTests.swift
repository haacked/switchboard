import Testing

@testable import SwitchboardService

@Suite struct SupacodeTests {
  @Test func readsSupacodesQuotedLockReason() {
    let reason =
      #" "{\"build\":\"1792934673\",\"createdAt\":1793889333,\"owner\":\"supacode\",\"version\":\"0.11.6\"}""#
    #expect(Service.isSupacodeLock(Substring(reason)))
  }

  @Test func readsAnUnquotedLockReason() {
    #expect(Service.isSupacodeLock(#" {"owner":"supacode"}"#))
  }

  @Test(arguments: ["", " Supacode", #" "{\"owner\":\"someone-else\"}""#, " not json"])
  func refusesEveryOtherLock(_ reason: String) {
    #expect(!Service.isSupacodeLock(Substring(reason)))
  }

  @Test func encodesTheWorktreePathAsSupacodesId() {
    #expect(
      Service.supacodeID("/Users/me/dev/worktrees/sb/haacked/a b")
        == "%2FUsers%2Fme%2Fdev%2Fworktrees%2Fsb%2Fhaacked%2Fa%20b%2F")
  }

  @Test func keepsOneTrailingSlash() {
    #expect(Service.supacodeID("/tmp/x/") == "%2Ftmp%2Fx%2F")
  }
}
