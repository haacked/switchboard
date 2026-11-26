import Foundation
import Testing

@testable import SwitchboardCore

/// The `github.events` settings in config.json.
@Suite struct EventSettingsTests {
  @Test func theDefaultModeIsOff() {
    #expect(EventSettings().mode == .off)
  }

  @Test func theDefaultLimitIsEightySubscriptions() {
    #expect(EventSettings().maxSubscriptions == 80)
  }

  @Test func theGitHubSettingsHoldTheDefaultEventSettings() {
    #expect(GitHubSettings().events == EventSettings())
  }

  @Test func aConfigWithoutEventsUsesTheDefaults() throws {
    let c = try JSONCoding.decode(Config.self, from: #"{"github": {"pollSeconds": 0}}"#)

    #expect(c.github.events == EventSettings())
  }

  @Test func shadowModeDecodesInsideTheGitHubSettings() throws {
    let c = try JSONCoding.decode(Config.self, from: #"{"github": {"events": {"mode": "shadow"}}}"#)

    #expect(c.github.events.mode == .shadow)
    #expect(c.github.events.maxSubscriptions == 80)
  }

  @Test func theGitHubSettingsDecodeTheirEventsKey() throws {
    let s = try JSONCoding.decode(GitHubSettings.self, from: #"{"events": {"mode": "shadow", "maxSubscriptions": 12}}"#)

    #expect(s.events.mode == .shadow)
    #expect(s.events.maxSubscriptions == 12)
  }

  @Test func readModeDecodesInsideTheGitHubSettings() throws {
    let c = try JSONCoding.decode(Config.self, from: #"{"github": {"events": {"mode": "read"}}}"#)

    #expect(c.github.events.mode == .read)
    #expect(c.github.events.maxSubscriptions == 80)
  }

  @Test func readModeDecodesOnItsOwn() throws {
    #expect(try JSONCoding.decode(EventSettings.Mode.self, from: #""read""#) == .read)
  }

  @Test func anEmptyEventsObjectUsesTheDefaults() throws {
    #expect(try JSONCoding.decode(EventSettings.self, from: "{}") == EventSettings())
  }

  /// A mode that this sbd doesn't know, such as one a later sbd adds, turns the source off and leaves the rest of
  /// the config as written.
  @Test(arguments: ["auto", "bogus", "", "SHADOW", "READ"])
  func anUnknownModeDecodesAsOffAndTheRestStillDecodes(_ mode: String) throws {
    let text = #"""
      {"idleStopSeconds": 30,
       "github": {"pollSeconds": 0, "url": "http://127.0.0.1:9",
                  "events": {"mode": "\#(mode)", "maxSubscriptions": 5}}}
      """#

    let c = try JSONCoding.decode(Config.self, from: text)

    #expect(c.github.events.mode == .off)
    #expect(c.github.events.maxSubscriptions == 5)
    #expect(c.github.pollSeconds == 0)
    #expect(c.github.url == "http://127.0.0.1:9")
    #expect(c.idleStopSeconds == 30)
  }

  @Test(arguments: ["auto", "bogus"])
  func anUnknownModeOnItsOwnDecodesAsOff(_ mode: String) throws {
    #expect(try JSONCoding.decode(EventSettings.Mode.self, from: "\"\(mode)\"") == .off)
  }

  @Test func shadowModeSurvivesARoundTrip() throws {
    var s = GitHubSettings()
    s.events.mode = .shadow
    s.events.maxSubscriptions = 40

    #expect(try JSONCoding.convert(s, to: GitHubSettings.self) == s)
  }

  @Test func readModeSurvivesARoundTrip() throws {
    var s = GitHubSettings()
    s.events.mode = .read
    s.events.maxSubscriptions = 40

    #expect(try JSONCoding.convert(s, to: GitHubSettings.self) == s)
  }
}
