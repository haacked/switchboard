import Foundation
import Testing

@testable import SwitchboardCore

private func config(_ text: String) throws -> Config { try JSONCoding.decode(Config.self, from: text) }

/// config.json's top-level `model`, the model that new work sessions start on. sbd passes it to claude as `--model`.
/// Decoding drops a value that claude would read as an option or as two words, and keeps opus.
@Suite struct ConfigModelTests {
  @Test(arguments: ["{}", #"{"model": null}"#])
  func configWithoutAModelRunsOpus(_ text: String) throws {
    #expect(try config(text).model == "opus")
  }

  @Test(arguments: ["haiku", "sonnet", "claude-opus-5-5", "opus[1m]", "default"])
  func configReadsTheModel(_ model: String) throws {
    #expect(try config(#"{"model": "\#(model)"}"#).model == model)
  }

  @Test(arguments: ["", " ", "-p", "--model", "a b", " haiku", "haiku\\n"])
  func aBadModelNameFallsBackToOpus(_ model: String) throws {
    #expect(try config(#"{"model": "\#(model)"}"#).model == "opus")
  }

  @Test(arguments: ["5", "true", "[]", #"{"name": "haiku"}"#])
  func aModelThatIsNotAStringFallsBackToOpus(_ value: String) throws {
    #expect(try config(#"{"model": \#(value)}"#).model == "opus")
  }

  @Test func aBadModelKeepsTheRestOfTheConfig() throws {
    let c = try config(#"{"model": "-p", "manager": {"model": "haiku"}, "branchPrefix": "haacked/"}"#)

    #expect(c.manager.model == "haiku")
    #expect(c.branchPrefix == "haacked/")
  }

  @Test func theModelRoundTripsThroughConfig() throws {
    var c = Config()
    c.model = "haiku"

    let decoded = try JSONCoding.decode(Config.self, from: try JSON(encoding: c).text)

    #expect(decoded.model == "haiku")
  }
}
