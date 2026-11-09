import Foundation
import SwitchboardCore
import Testing

/// `account use` and `account move` refuse a target account whose last usage
/// reading found no login. Only that reading refuses: any other failed read,
/// or no reading at all, lets the account through.
@Suite(.blocking(timeLimit: .seconds(120))) struct SignedOutAccountTests {
  func decode(_ text: String) throws -> SessionSummary { try JSONCoding.decode(SessionSummary.self, from: text) }

  func active(_ sbd: Instance) throws -> [String] {
    try JSONCoding.decode([AccountInfo].self, from: try sbd.sb("account", "--json")).filter(\.active).map(\.folder)
  }

  /// The wording of UsageReader's `SignedOut` error for the account.
  func login(_ sbd: Instance, _ account: String) -> String {
    "run `\(ClaudeAccount.command(Instance.stub, in: sbd.account(account)))` and /login"
  }

  /// Checks that the refusal gives the login command and names the account
  /// outside that command, which holds the account's folder.
  func expectNamesTheAccountAndTheLogin(_ sbd: Instance, _ text: String, _ account: String) {
    #expect(text.contains(login(sbd, account)), "\(text)")
    #expect(text.replacingOccurrences(of: login(sbd, account), with: "").contains(account), "\(text)")
  }

  /// A sbd with accounts A and B, A active and signed in, and B read as
  /// signed out.
  func signedOutB(_ fake: FakeUsage) throws -> Instance {
    let sbd = try Instance.withUsage(fake, accounts: ["A", "B"])
    try sbd.signIn("A", token: "token-a")
    let b = try sbd.usage(of: "B")
    #expect(b.signedOut == true)
    return sbd
  }

  /// A session under `account` that has answered one prompt and then stopped.
  func stoppedSession(_ sbd: Instance, on account: String, prompt: String) throws -> SessionSummary {
    let s = try decode(sbd.sb("new", "--json", "--account", account, "--prompt", prompt, sbd.work))
    try sbd.waitFor(s.id, "the first reply") { $0.lastReply == "Done: \(prompt)" }
    try sbd.sb("stop", s.id)
    return try sbd.waitFor(s.id, "the stop") { $0.claudePid == nil }
  }

  // MARK: Refusals

  /// A refusal changes nothing, so one sbd serves every way of naming B.
  @Test func everyRequestThatTargetsASignedOutAccountIsRefused() throws {
    let fake = try FakeUsage()
    let sbd = try signedOutB(fake)

    for args in [
      ["account", "use", "B"], ["account", "use", sbd.account("B")], ["account", "use", "B", "--move"],
      ["account", "move", "B"], ["account", "move", "B", "--dry-run"],
    ] {
      let r = try sbd.run(args)
      #expect(r.status != 0, "sb \(args.joined(separator: " ")) succeeded: \(r.stdout)")
      expectNamesTheAccountAndTheLogin(sbd, r.stderr, "B")
    }
    #expect(try active(sbd) == [sbd.account("A")])
  }

  // MARK: Accepted accounts

  @Test func useAcceptsAnAccountReadAsSignedIn() throws {
    let fake = try FakeUsage()
    let sbd = try Instance.withUsage(fake, accounts: ["A", "B"])
    try sbd.signIn("B", token: "token-b")
    #expect(try sbd.usage(of: "B").error == nil)

    try sbd.sb("account", "use", "B")

    #expect(try active(sbd) == [sbd.account("B")])
  }

  /// A locked keychain fails the same way: the read fails and `signedOut`
  /// stays unset. SignedOutRefusal covers the keychain's own error.
  @Test func useAcceptsAnAccountWhoseReadFailedForAnotherReason() throws {
    let fake = try FakeUsage()
    let sbd = try Instance.withUsage(fake, accounts: ["A", "B"])
    try sbd.signIn("B", token: "token-b")
    fake.reply("", status: 500)
    let b = try sbd.usage(of: "B")
    #expect(b.error?.contains("500") == true)
    #expect(b.signedOut == nil)

    try sbd.sb("account", "use", "B")

    #expect(try active(sbd) == [sbd.account("B")])
  }

  /// With pollSeconds 0 and no `sb usage`, sbd has no reading of B.
  @Test func useAcceptsAnAccountWithoutAReading() throws {
    let fake = try FakeUsage()
    let sbd = try Instance.withUsage(fake, accounts: ["A", "B"])

    try sbd.sb("account", "use", "B")

    #expect(try active(sbd) == [sbd.account("B")])
  }

  @Test func useAcceptsAnAccountThatSignedInAfterItsLastReading() throws {
    let fake = try FakeUsage()
    let sbd = try signedOutB(fake)
    try sbd.signIn("B", token: "token-b")

    try sbd.sb("account", "use", "B")

    #expect(try active(sbd) == [sbd.account("B")])
  }

  @Test func moveAcceptsATargetThatSignedInAfterItsLastReading() throws {
    let fake = try FakeUsage()
    let sbd = try signedOutB(fake)
    try sbd.signIn("B", token: "token-b")

    let result = try JSONCoding.decode(AccountMove.self, from: try sbd.sb("account", "move", "--json", "B"))

    #expect(result.account == sbd.account("B"))
  }

  // MARK: Accounts with sessions

  /// Sessions start on A and on B before any reading, so nothing refuses
  /// them. B then reads as signed out.
  func sessionsOnBothAccounts(_ fake: FakeUsage) throws -> (Instance, onA: SessionSummary, onB: SessionSummary) {
    let sbd = try Instance.withUsage(fake, accounts: ["A", "B"])
    try sbd.signIn("A", token: "token-a")
    let onA = try stoppedSession(sbd, on: "A", prompt: "on a")
    let onB = try stoppedSession(sbd, on: "B", prompt: "on b")
    #expect(try sbd.usage(of: "B").signedOut == true)
    #expect(try sbd.usage(of: "A").signedOut == nil)
    return (sbd, onA, onB)
  }

  @Test func aSignedOutAccountThatHoldsSessionsIsRefusedAndNothingMoves() throws {
    let fake = try FakeUsage()
    let (sbd, onA, onB) = try sessionsOnBothAccounts(fake)

    for args in [["account", "use", "B"], ["account", "move", "B", "--dry-run"], ["account", "move", "B"]] {
      let r = try sbd.run(args)
      #expect(r.status != 0, "sb \(args.joined(separator: " ")) succeeded: \(r.stdout)")
      expectNamesTheAccountAndTheLogin(sbd, r.stderr, "B")
    }

    #expect(try active(sbd) == [sbd.account("A")])
    #expect(try sbd.get(onA.id).account == sbd.account("A"))
    #expect(try sbd.get(onB.id).account == sbd.account("B"))
    #expect(try !sbd.events(onA.id).contains { $0.kind == "account-moved" })
  }

  @Test func sessionsMoveOffASignedOutAccountToASignedInOne() throws {
    let fake = try FakeUsage()
    let (sbd, _, onB) = try sessionsOnBothAccounts(fake)

    let result = try JSONCoding.decode(AccountMove.self, from: try sbd.sb("account", "move", "--json", "A"))

    #expect(result.moved == [onB.id])
    #expect(result.blocked.isEmpty)
    #expect(try sbd.get(onB.id).account == sbd.account("A"))
  }
}
