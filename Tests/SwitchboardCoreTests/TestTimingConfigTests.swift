import Foundation
import Testing

@testable import SwitchboardCore

/// The config.json keys that let a test shorten sbd's waits. Without them, sbd keeps the production waits.
@Suite struct TestTimingConfigTests {
  @Test func aConfigWithoutTheKeysKeepsTheProductionWaits() throws {
    let config = try JSONCoding.decode(Config.self, from: "{}")

    #expect(config.pasteSettleSeconds == 1.5)
    #expect(config.stopWaitSeconds == 5)
    #expect(config.reviewTimeoutSeconds == 60)
  }

  @Test func theKeysSetTheWaits() throws {
    let config = try JSONCoding.decode(
      Config.self, from: #"{"pasteSettleSeconds": 0.2, "stopWaitSeconds": 2, "reviewTimeoutSeconds": 5}"#)

    #expect(config.pasteSettleSeconds == 0.2)
    #expect(config.stopWaitSeconds == 2)
    #expect(config.reviewTimeoutSeconds == 5)
  }
}

/// sbd turns each wait into whole milliseconds or nanoseconds, so a value it can't hold keeps the default instead of
/// crashing sbd.
@Suite struct TestTimingConfigRangeTests {
  @Test(
    arguments: ["pasteSettleSeconds", "stopWaitSeconds", "reviewTimeoutSeconds"],
    ["1e16", "-1", "86401", "\"2\"", "true"])
  func aWaitOutOfRangeKeepsTheDefaultAndTheRestOfTheConfig(_ key: String, _ value: String) throws {
    let config = try JSONCoding.decode(Config.self, from: #"{"liveCap": 7, "\#(key)": \#(value)}"#)

    #expect(config.pasteSettleSeconds == 1.5)
    #expect(config.stopWaitSeconds == 5)
    #expect(config.reviewTimeoutSeconds == 60)
    #expect(config.liveCap == 7)
  }

  @Test(arguments: ["pasteSettleSeconds", "stopWaitSeconds", "reviewTimeoutSeconds"])
  func theEndsOfTheRangeSetTheWait(_ key: String) throws {
    let low = try JSONCoding.decode(Config.self, from: #"{"\#(key)": 0}"#)
    let high = try JSONCoding.decode(Config.self, from: #"{"\#(key)": 86400}"#)

    #expect([low.pasteSettleSeconds, low.stopWaitSeconds, low.reviewTimeoutSeconds].contains(0))
    #expect([high.pasteSettleSeconds, high.stopWaitSeconds, high.reviewTimeoutSeconds].contains(86_400))
  }
}
