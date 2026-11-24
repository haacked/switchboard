import Foundation
import Testing

@testable import SwitchboardCore

/// `conversationHintTokens` in config.json: the context size at which a Manager conversation's header suggests
/// ending it. 0 turns that hint off. A bad value keeps the default 120000 and leaves the other keys alone.
@Suite struct ConversationHintConfigTests {
  func config(_ tokens: String) throws -> Config {
    try JSONCoding.decode(Config.self, from: #"{"liveCap": 7, "conversationHintTokens": \#(tokens)}"#)
  }

  @Test func withoutTheKeyTheThresholdIs120000() throws {
    let config = try JSONCoding.decode(Config.self, from: #"{"liveCap": 7}"#)

    #expect(config.conversationHintTokens == 120_000)
  }

  @Test(arguments: [("0", 0), ("250000", 250_000), ("10000000", 10_000_000), ("null", 120_000)])
  func aWholeNumberInRangeSetsTheThreshold(_ text: String, _ expected: Int) throws {
    #expect(try config(text).conversationHintTokens == expected)
  }

  @Test(arguments: ["2.5", "-1", "10000001", "\"120000\"", "true", "[]"])
  func aBadValueKeepsTheDefaultAndTheRestOfTheConfig(_ text: String) throws {
    let config = try config(text)

    #expect(config.conversationHintTokens == 120_000)
    #expect(config.liveCap == 7)
  }
}
