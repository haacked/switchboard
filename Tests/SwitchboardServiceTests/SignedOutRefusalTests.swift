import SwitchboardCore
import Testing

@testable import SwitchboardService

/// `account-use` and `account-move` refuse a target only when its reading
/// found no login.
@Suite struct SignedOutRefusal {
  func reading(_ fail: Error) -> AccountUsage {
    var usage = AccountUsage(name: "B", folder: "/accounts/B")
    usage.fail(with: fail)
    return usage
  }

  @Test func aSignedOutReadingIsRefusedWithTheAccountAndItsLoginCommand() {
    let login = SignedOut(login: ClaudeAccount.command("claude", in: "/accounts/B"))

    #expect(Service.signedOutRefusal(reading(login)) == "B is \(login)")
  }

  @Test(arguments: [
    "could not read the login from the keychain: security exited with status 51: locked",
    "the usage endpoint answered HTTP 500",
    "the access token expired and claude could not refresh it; run `claude` and /login",
  ])
  func aReadThatFailedForAnotherReasonIsNotRefused(_ message: String) {
    #expect(Service.signedOutRefusal(reading(APIError(message))) == nil)
  }

  @Test func noReadingAndASignedInReadingAreNotRefused() {
    #expect(Service.signedOutRefusal(nil) == nil)
    #expect(Service.signedOutRefusal(AccountUsage(name: "B", folder: "/accounts/B", checked: 1)) == nil)
  }
}
