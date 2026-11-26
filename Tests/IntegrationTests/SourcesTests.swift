import Foundation
import SwitchboardCore
import Testing

/// `sb sources` lists the sources of PR changes that sbd runs. With Event
/// Streams off, sbd runs none.
@Suite(.blocking(timeLimit: .seconds(120))) struct SourcesTests {
  @Test func sbSourcesListsNoProvider() throws {
    let sbd = try Instance.withGitHub(try FakeGitHub(), events: "off")

    let json = try #require(JSON.parse(try sbd.sb("sources", "--json")))
    let text = try sbd.sb("sources")

    #expect(json["providers"]?.array?.isEmpty == true, "\(json.text)")
    #expect(text.contains("no sources of PR changes"), "\(text)")
  }

  /// The provider asks GitHub once the poll gives it a PR, and FakeGitHub
  /// refuses as GitHub does for an account without Event Streams.
  @Test func sbSourcesShowsEventStreamsUnavailableWithGitHubsMessage() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    _ = try sbd.session(in: "PostHog/charts", branch: "haacked/cdp-dlq-runbook-lookup-step")

    try sbd.poll()

    let providers = try sbd.waitFor(
      "github-events to be unavailable",
      fetch: { JSON.parse(try sbd.sb("sources", "--json"))?["providers"]?.array },
      until: { $0.first?["state"]?.string == "unavailable" })
    #expect(providers.map { $0["id"]?.string } == ["github-events"])
    #expect(providers.first?["reason"]?.string == FakeGitHub.eventsDisabledMessage)
  }
}
