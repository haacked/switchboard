import Foundation
import Testing

@testable import SwitchboardApp

@Suite struct SessionLinkTests {
  @Test func urlForAnIdIsTheSchemeAndTheId() {
    #expect(SessionLink.url(for: "seb4ec").absoluteString == "switchboard-session:seb4ec")
  }

  @Test(arguments: ["seb4ec", "sgcctv", "s23456", "szzzzz"])
  func idFromTheURLForAnIdGivesTheId(_ id: String) {
    #expect(SessionLink.id(from: SessionLink.url(for: id)) == id)
  }

  @Test func idFromAParsedSessionURLGivesTheId() throws {
    let url = try #require(URL(string: "switchboard-session:seb4ec"))

    #expect(SessionLink.id(from: url) == "seb4ec")
  }

  /// The window's URL handler passes each of these to the system, so a PR
  /// link or a Markdown link that names a session id keeps opening the browser.
  @Test(arguments: [
    "https://github.com/haacked/switchboard/pull/309",
    "https://example.com/seb4ec",
    "https://switchboard-session/seb4ec",
    "http://example.com/?session=seb4ec",
    "file:///tmp/seb4ec",
    "file:///Users/me/.sb/sessions/seb4ec/claude.sh",
    "mailto:seb4ec@example.com",
    "other:seb4ec",
    "switchboard:seb4ec",
    "session:seb4ec",
  ])
  func aURLWithAnotherSchemeIsNotASessionLink(_ string: String) throws {
    let url = try #require(URL(string: string))

    #expect(SessionLink.id(from: url) == nil)
  }

  @Test func aFileURLMadeFromAPathIsNotASessionLink() {
    #expect(SessionLink.id(from: URL(fileURLWithPath: "/tmp/seb4ec")) == nil)
  }

  @Test(arguments: [
    "switchboard-session:",
    "switchboard-session://seb4ec",
    "switchboard-session:seb4ec/claude.sh",
    "switchboard-session:/seb4ec",
    "switchboard-session:seb4ec?x=1",
    "switchboard-session:seb4ec#top",
    "switchboard-session:seb4ec%20",
    "switchboard-session:%20seb4ec",
  ])
  func aMalformedSessionURLIsNotASessionLink(_ string: String) throws {
    let url = try #require(URL(string: string))

    #expect(SessionLink.id(from: url) == nil)
  }

  /// Assumes that `id(from:)` accepts only the session id format
  /// `s[a-km-np-z2-9]{5}` that `shortId` generates.
  @Test(arguments: [
    "switchboard-session:seb4ecx",
    "switchboard-session:seb4e",
    "switchboard-session:SEB4EC",
    "switchboard-session:g4rvrf",
    "switchboard-session:w3k9ap",
    "switchboard-session:sl0o1x",
  ])
  func aSessionURLWhoseIdIsNotASessionIdIsNotASessionLink(_ string: String) throws {
    let url = try #require(URL(string: string))

    #expect(SessionLink.id(from: url) == nil)
  }
}
