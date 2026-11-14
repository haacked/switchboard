import Foundation
import Testing

@testable import SwitchboardCore

/// `SessionHost.choose(named:parent:origin:)` for a request from this Mac. `named` is the `host` of the request as
/// sent, and `parent` is the host of the new session's parent, nil when it has no parent or a parent on this Mac.
/// The result is the host that the new session runs on, nil for this Mac. The rows for a request from a host wait
/// for stage 3.
@Suite struct SessionHostChooseTests {
  @Test func noHostAndNoParentOnAHostRunsOnThisMac() throws {
    #expect(try SessionHost.choose(named: nil, parent: nil, origin: .mac) == nil)
  }

  @Test func noHostAndAParentOnAHostRunsOnTheParentsHost() throws {
    #expect(try SessionHost.choose(named: nil, parent: "mini", origin: .mac) == "mini")
  }

  @Test(arguments: [nil, "mini"] as [String?])
  func localRunsOnThisMacWhereverTheParentRuns(parent: String?) throws {
    #expect(try SessionHost.choose(named: "local", parent: parent, origin: .mac) == nil)
  }

  @Test(arguments: [nil, "mini", "other"] as [String?])
  func aNamedHostWinsOverTheParentsHost(parent: String?) throws {
    #expect(try SessionHost.choose(named: "mini", parent: parent, origin: .mac) == "mini")
  }

  /// Only `local` names this Mac. `LOCAL` is a host name, which config.json then doesn't hold.
  @Test(arguments: [nil, "mini"] as [String?])
  func localInAnotherCaseIsAHostNameAndNotThisMac(parent: String?) throws {
    #expect(try SessionHost.choose(named: "LOCAL", parent: parent, origin: .mac) == "LOCAL")
  }

  /// The spec gives no result for an empty name. It either throws or names no host, and it never returns the empty
  /// string as a host.
  @Test(arguments: [nil, "mini"] as [String?])
  func anEmptyHostNameIsNeverReturnedAsAHost(parent: String?) {
    let chosen = try? SessionHost.choose(named: "", parent: parent, origin: .mac)

    #expect(chosen != "")
  }

  /// No record holds `local`, so the rule maps it to nil for every input.
  @Test(
    arguments: [nil, "local", "LOCAL", "", "mini"] as [String?],
    [nil, "mini", "other"] as [String?])
  func theChosenHostIsNeverLocal(named: String?, parent: String?) {
    let chosen = try? SessionHost.choose(named: named, parent: parent, origin: .mac)

    #expect(chosen != "local")
  }
}

/// `sb spawn`, `sb new`, and the MCP `spawn` tool pass a path as typed only when the host is a remote one.
@Suite struct SessionHostNamesRemoteTests {
  @Test(arguments: [nil, "", "  ", "local", " local "] as [String?])
  func noHostOrLocalNamesThisMac(named: String?) {
    #expect(!SessionHost.namesRemote(named))
  }

  @Test(arguments: ["mini", "LOCAL", " mini "])
  func anyOtherNameNamesARemoteHost(named: String) {
    #expect(SessionHost.namesRemote(named))
  }
}
