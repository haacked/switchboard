import Foundation
import SwitchboardCore
import Testing

/// `sb sources` lists the sources of PR changes that sbd runs. sbd registers none yet.
@Suite(.blocking(timeLimit: .seconds(120))) struct SourcesTests {
  @Test func sbSourcesListsNoProvider() throws {
    let sbd = try Instance.withGitHub(try FakeGitHub())

    let json = try #require(JSON.parse(try sbd.sb("sources", "--json")))
    let text = try sbd.sb("sources")

    #expect(json["providers"]?.array?.isEmpty == true, "\(json.text)")
    #expect(text.contains("no sources of PR changes"), "\(text)")
  }
}
