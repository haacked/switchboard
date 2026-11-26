import Foundation
import Testing

@testable import SwitchboardCore

/// `PRSources` carries the poller's `github.pollSeconds`, so the app can say how often sbd polls.
@Suite struct PRSourcesPollSecondsTests {
  @Test func pollSecondsSurvivesARoundTrip() throws {
    let sources = PRSources(providers: [], pollSeconds: 30)

    #expect(try JSONCoding.convert(sources, to: PRSources.self).pollSeconds == 30)
  }

  /// 0 means only `sb poll` polls. It must not decode as nil, which means an sbd that doesn't report it.
  @Test func zeroPollSecondsSurvivesARoundTrip() throws {
    let sources = PRSources(providers: [], pollSeconds: 0)

    #expect(try JSONCoding.convert(sources, to: PRSources.self).pollSeconds == 0)
  }

  /// The app reads the key by this name from sbd's answer.
  @Test func pollSecondsIsSentUnderItsOwnKey() throws {
    let json = try JSON(encoding: PRSources(providers: [], pollSeconds: 30))

    #expect(json["pollSeconds"] == .number(30))
  }

  @Test func pollSecondsDefaultsToNil() {
    #expect(PRSources(providers: []).pollSeconds == nil)
  }

  /// An sbd from before this field sends no pollSeconds key.
  @Test func anAnswerFromAnOlderSbdDecodesWithoutPollSeconds() throws {
    let data = Data(#"{"providers":[],"pendingReads":0,"reviewOnlyReads":0}"#.utf8)

    let decoded = try JSONDecoder().decode(PRSources.self, from: data)

    #expect(decoded.pollSeconds == nil)
  }

  @Test func anOlderSbdsAnswerWithAProviderStillDecodes() throws {
    var object = try #require(
      try JSON(encoding: PRSources(providers: [PRSources.Source(id: "github-events", state: "live", wanted: 3)]))
        .object)
    object["pollSeconds"] = nil

    let decoded = try JSONCoding.convert(JSON.object(object), to: PRSources.self)

    #expect(decoded.providers.first?.wanted == 3)
    #expect(decoded.pollSeconds == nil)
  }
}
