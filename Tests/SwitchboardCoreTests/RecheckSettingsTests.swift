import Foundation
import Testing

@testable import SwitchboardCore

/// The default recheck times, written out so that a changed default fails here.
private let defaultSeconds: [String: Int] = [
  "ci": 7200, "bot-review": 3600, "review": 86400, "approval": 86400, "queue": 14400, "merge": 86400,
  "deploy": 14400, "session": 86400, "manual": 86400, "acknowledged": 3600,
]

/// The kinds that take a recheck time from the settings.
private let rechecked = Wait.Kind.allCases.filter { $0 != .date }

private func config(_ text: String) throws -> Config {
  try JSONCoding.decode(Config.self, from: text)
}

/// A config.json with `recheckSeconds` set to `value` and a sibling setting to check that it survives.
private func configWith(recheck value: String) throws -> Config {
  try config(#"{"idleStopSeconds": 77, "recheckSeconds": \#(value)}"#)
}

/// The suites nest under one name, so `--filter RecheckSettingsTests` runs them all.
@Suite struct RecheckSettingsTests {}

extension RecheckSettingsTests {
  @Suite struct Defaults {
    @Test func configHoldsTheDefaultRecheckTimes() {
      #expect(Config().recheck.seconds == defaultSeconds)
    }

    @Test func configWithoutRecheckSecondsHoldsTheDefaults() throws {
      #expect(try config(#"{"idleStopSeconds": 77}"#).recheck == RecheckSettings())
    }

    @Test func acknowledgedMsIsAnHour() {
      #expect(RecheckSettings().acknowledgedMs == 3_600_000)
    }
  }
}

extension RecheckSettingsTests {
  @Suite struct Overrides {
    @Test(arguments: defaultSeconds.keys.sorted())
    func eachKeyOverridesItsDefault(_ key: String) throws {
      let c = try configWith(recheck: #"{"\#(key)": 123}"#)

      var expected = defaultSeconds
      expected[key] = 123
      #expect(c.recheck.seconds == expected)
    }

    @Test func acknowledgedOverrideSetsAcknowledgedMs() throws {
      #expect(try configWith(recheck: #"{"acknowledged": 120}"#).recheck.acknowledgedMs == 120_000)
    }

    @Test func goodEntriesApplyBesideABadOne() throws {
      let c = try configWith(recheck: #"{"ci": "x", "review": 100}"#)

      #expect(c.recheck.seconds["ci"] == 7200)
      #expect(c.recheck.seconds["review"] == 100)
    }

    @Test func encodedSettingsDecodeToTheSameSettings() throws {
      let settings = try configWith(recheck: #"{"ci": 60, "acknowledged": 30}"#).recheck

      let text = try JSON(encoding: settings).text

      #expect(try configWith(recheck: text).recheck == settings)
    }
  }
}

/// Any value of `recheckSeconds` decodes, and the rest of config.json still loads.
extension RecheckSettingsTests {
  @Suite struct BadValues {
    /// Each whole value falls back to every default.
    @Test(arguments: ["null", "[]", "[1, 2]", "\"7200\"", "7200", "true"])
    func valueThatIsNotAnObjectKeepsTheDefaults(_ value: String) throws {
      let c = try configWith(recheck: value)

      #expect(c.recheck == RecheckSettings())
    }

    @Test(arguments: ["null", "[]", "[1, 2]", "\"7200\"", "7200", "true"])
    func valueThatIsNotAnObjectKeepsTheSiblingSettings(_ value: String) throws {
      #expect(try configWith(recheck: value).idleStopSeconds == 77)
    }

    /// `botReview` is the Swift case name, not the wire name. `date` takes no recheck time.
    @Test(arguments: ["bogus", "botReview", "date", "Acknowledged", ""])
    func unknownKeyIsSkipped(_ key: String) throws {
      let c = try configWith(recheck: #"{"\#(key)": 60}"#)

      #expect(c.recheck == RecheckSettings())
      #expect(c.idleStopSeconds == 77)
    }

    @Test(arguments: ["\"60\"", "0", "-1", "-7200", "1.5", "7199.9", "1e19", "null", "true", "{}", "[60]"])
    func entryThatIsNotAPositiveWholeNumberKeepsItsDefault(_ value: String) throws {
      let c = try configWith(recheck: #"{"ci": \#(value)}"#)

      #expect(c.recheck.seconds["ci"] == 7200)
      #expect(c.idleStopSeconds == 77)
    }

    @Test(arguments: ["\"60\"", "0", "-1", "1.5"])
    func badAcknowledgedEntryKeepsAnHour(_ value: String) throws {
      #expect(try configWith(recheck: #"{"acknowledged": \#(value)}"#).recheck.acknowledgedMs == 3_600_000)
    }
  }
}

extension RecheckSettingsTests {
  @Suite struct RecheckForAWait {
    static let created = fixedNow

    func wait(_ kind: Wait.Kind, until: Int64? = nil) -> Wait {
      Wait(id: "w1", kind: kind, until: until, created: Self.created)
    }

    /// The time that `stamped` sets: `until` for a manual wait, `recheck` for any other.
    func time(_ wait: Wait) -> Int64? { wait.kind == .manual ? wait.until : wait.recheck }

    @Test(arguments: [
      Wait(id: "w1", kind: .date, until: fixedNow + 1000, created: fixedNow),
      Wait(id: "w1", kind: .manual, until: fixedNow + 1000, created: fixedNow),
    ])
    func waitWithItsOwnTimeKeepsIt(_ wait: Wait) {
      #expect(RecheckSettings().stamped(wait, from: farFuture) == wait)
    }

    @Test(arguments: rechecked)
    func otherWaitRechecksItsDefaultAfterItWasSet(_ kind: Wait.Kind) throws {
      let seconds = try #require(defaultSeconds[kind.rawValue])

      #expect(time(RecheckSettings().stamped(wait(kind))) == Self.created + Int64(seconds) * 1000)
    }

    @Test func manualWaitGetsItsRecheckTimeAsItsUntil() {
      let stamped = RecheckSettings().stamped(wait(.manual))

      #expect(stamped.until == Self.created + 86_400_000)
      #expect(stamped.recheck == nil)
    }

    @Test(arguments: rechecked)
    func overriddenKindRechecksAfterItsOverride(_ kind: Wait.Kind) throws {
      let settings = try configWith(recheck: #"{"\#(kind.rawValue)": 60}"#).recheck

      #expect(time(settings.stamped(wait(kind))) == Self.created + 60_000)
    }

    /// `Service.upgraded` starts a legacy wait's clock at load time, not at `created`.
    @Test(arguments: rechecked)
    func recheckCountsFromTheGivenStart(_ kind: Wait.Kind) throws {
      let start = Self.created + 5 * Attention.dayMs
      let seconds = try #require(defaultSeconds[kind.rawValue])

      #expect(time(RecheckSettings().stamped(wait(kind), from: start)) == start + Int64(seconds) * 1000)
    }

    /// `Service.upgraded` stamps on every load, so a stamped wait must keep its time.
    @Test(arguments: rechecked)
    func stampedWaitKeepsItsTime(_ kind: Wait.Kind) {
      let once = RecheckSettings().stamped(wait(kind))

      #expect(RecheckSettings().stamped(once, from: farFuture) == once)
    }
  }
}
