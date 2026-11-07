import SwitchboardCore
import Testing

@testable import SwitchboardService

@Suite struct UsageReaderFailures {
  @Test func aMissingKeychainItemOrASuccessIsNotAKeychainFailure() {
    #expect(UsageReader.keychainFailure(status: 0, stderr: "") == nil)
    #expect(UsageReader.keychainFailure(status: 44, stderr: "The specified item could not be found") == nil)
  }

  @Test func anyOtherKeychainStatusIsAKeychainFailureThatNamesTheStatus() {
    let failure = UsageReader.keychainFailure(status: 51, stderr: " User interaction is not allowed.\n")
    #expect(failure == "security exited with status 51: User interaction is not allowed.")
  }

  @Test func aKeychainFailureLeavesSignedOutUnset() {
    var usage = AccountUsage(name: "a", folder: "/a")

    usage.fail(with: APIError("could not read the login from the keychain: security exited with status 51: locked"))

    #expect(usage.error?.contains("keychain") == true)
    #expect(usage.signedOut == nil)
  }

  @Test func anAccountWithNoCredentialsIsSignedOut() {
    var usage = AccountUsage(name: "a", folder: "/a")

    usage.fail(with: SignedOut(login: "claude"))

    #expect(usage.error == "not signed in; run `claude` and /login")
    #expect(usage.signedOut == true)
  }
}
