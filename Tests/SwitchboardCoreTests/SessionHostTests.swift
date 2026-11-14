import Foundation
import Testing

@testable import SwitchboardCore

/// `SessionHost.choose(named:parent:origin:)`. `named` is the `host` of the request as sent, and `parent` is the
/// host of the new session's parent, nil when it has no parent or a parent on this Mac. The result is the host that
/// the new session runs on, nil for this Mac.
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

  // MARK: A request from a host

  /// The scope of mini's requests refuses a parent off mini first, so the rule reads no parent for mini.
  @Test(arguments: [nil, "mini"] as [String?], [nil, "mini"] as [String?])
  func aRequestFromAHostThatNamesNoHostOrItselfRunsOnThatHost(named: String?, parent: String?) throws {
    #expect(try SessionHost.choose(named: named, parent: parent, origin: .host("mini")) == "mini")
  }

  @Test(arguments: ["local", "other", "", "LOCAL", "Mini", "mini "], [nil, "mini", "other"] as [String?])
  func aRequestFromAHostForAnotherMachineThrows(named: String, parent: String?) {
    do {
      let chosen = try SessionHost.choose(named: named, parent: parent, origin: .host("mini"))
      Issue.record("a request from mini chose \(chosen ?? "this Mac") for \(named)")
    } catch {
      #expect("\(error)" == "a session on mini can start sessions only on mini")
    }
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

/// `sb` on a host passes a folder as the host names it, because this Mac can't read the host's folders.
@Suite struct SessionHostFolderTests {
  @Test(arguments: ["/srv/repo", "~/repo", "~", "~u/repo", "/"])
  func anAbsoluteFolderOrOneThatStartsWithATildeIsKeptAsTyped(path: String) {
    #expect(SessionHost.hostFolder(path, cwd: "/home/u/work") == path)
  }

  @Test(arguments: [
    ("repo", "/home/u/work/repo"), (".", "/home/u/work"), ("./repo/", "/home/u/work/repo"),
    ("../repo", "/home/u/repo"), ("a/../../b", "/home/u/b"), ("../../../../x", "/x"), ("a//b", "/home/u/work/a/b"),
    ("x/./y", "/home/u/work/x/y"), ("a~/b", "/home/u/work/a~/b"),
  ])
  func aRelativeFolderIsJoinedToTheBoxsFolderLexically(path: String, joined: String) {
    #expect(SessionHost.hostFolder(path, cwd: "/home/u/work") == joined)
  }
}
