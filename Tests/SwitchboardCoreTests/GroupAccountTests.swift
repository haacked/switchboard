import Testing

@testable import SwitchboardCore

/// The account that a group names: how a stored group row decodes, how a
/// summary encodes it, and what a merge keeps.
@Suite struct GroupAccountTests {
  func group(_ id: String, _ name: String, account: String? = nil) -> SessionGroup {
    SessionGroup(id: id, name: name, created: 0, account: account)
  }

  // MARK: Stored rows

  /// A row that an sbd without group accounts saved has no `account` key.
  @Test func aStoredGroupWithoutAnAccountDecodesWithNone() throws {
    let row = #"{"id":"g1","name":"Flags","notes":[],"created":0}"#

    let decoded = try JSONCoding.decode(SessionGroup.self, from: row)

    #expect(decoded.account == nil)
    #expect(decoded.name == "Flags")
  }

  @Test func aStoredGroupKeepsItsAccount() throws {
    let saved = group("g1", "Flags", account: "/Users/me/.claude-work")

    let decoded = try JSONCoding.decode(SessionGroup.self, from: try JSONCoding.encode(saved))

    #expect(decoded.account == "/Users/me/.claude-work")
  }

  // MARK: Summary

  @Test func theSummaryCarriesTheGroupsAccount() {
    let summary = GroupSummary(group("g1", "Flags", account: "/Users/me/.claude-work"), sessions: [])

    #expect(summary.account == "/Users/me/.claude-work")
  }

  /// The wire format leaves the key out when the group names no account.
  @Test func aSummaryWithoutAnAccountHasNoAccountKey() throws {
    let summary = GroupSummary(group("g1", "Flags"), sessions: [])

    let json = try #require(JSON.parse(try JSONCoding.encode(summary)))

    #expect(json["account"] == nil)
  }

  // MARK: Absorbing

  @Test func absorbingKeepsTheSurvivorsAccount() {
    let kept = group("g1", "Flags", account: "/Users/me/.claude-work")
    let other = group("g2", "Docs", account: "/Users/me/.claude-personal")

    let merged = kept.absorbing(other, now: 30)

    #expect(merged.account == "/Users/me/.claude-work")
  }

  /// A merge never changes the account of the survivor's existing members.
  @Test func absorbingIntoAGroupWithoutAnAccountTakesNone() {
    let kept = group("g1", "Flags")
    let other = group("g2", "Docs", account: "/Users/me/.claude-personal")

    let merged = kept.absorbing(other, now: 30)

    #expect(merged.account == nil)
  }

  @Test func absorbingAGroupWithoutAnAccountKeepsTheSurvivorsAccount() {
    let kept = group("g1", "Flags", account: "/Users/me/.claude-work")
    let other = group("g2", "Docs")

    let merged = kept.absorbing(other, now: 30)

    #expect(merged.account == "/Users/me/.claude-work")
  }
}
