import Foundation
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

/// `codex login status` under a timeout. A codex that handles SIGTERM can exit 1, which alone means signed out.
@Suite struct UsageReaderCodexLogin {
  func failure(_ r: CommandResult) -> Error? {
    do {
      try UsageReader.checkCodexLogin(r, login: "codex login")
      return nil
    } catch {
      return error
    }
  }

  @Test func anExitOneAfterTheTimeoutIsATimeoutAndNotASignOut() {
    let error = failure(CommandResult(status: 1, stdout: "", stderr: "", timedOut: true))

    #expect(!(error is SignedOut))
    #expect("\(error.map { "\($0)" } ?? "")".contains("did not answer"))
  }

  @Test func anExitOneByItselfIsASignOut() {
    #expect(failure(CommandResult(status: 1, stdout: "", stderr: "Not logged in\n")) is SignedOut)
  }

  /// codex exits 1 for a config it can't load or a login it can't read, and logging in again fixes neither.
  @Test(arguments: [
    "Error loading configuration: config.toml: expected a table\n", "Error checking login status: permission denied\n",
  ])
  func anExitOneThatIsNotASignOutNamesTheProblem(_ stderr: String) {
    let error = failure(CommandResult(status: 1, stdout: "", stderr: stderr))

    #expect(error != nil)
    #expect(!(error is SignedOut))
    #expect("\(error.map { "\($0)" } ?? "")".contains(stderr.trimmingCharacters(in: .newlines)))
  }

  @Test func anotherStatusNamesTheProblem() {
    let error = failure(CommandResult(status: 2, stdout: "", stderr: "boom\n"))

    #expect("\(error.map { "\($0)" } ?? "")" == "`codex login status` failed: boom")
  }
}

/// A Codex reading whose rollout can't be read. `/usr/bin/true` stands for a signed-in codex.
@Suite struct UsageReaderCodexRollout {
  @Test(.timeLimit(.minutes(1)))
  func anUnreadableRolloutIsAnErrorThatKeepsTheLastLimits() throws {
    let home = Home(path: try makeShortTempFolder())
    defer { try? FileManager.default.removeItem(atPath: home.path) }
    let cx = "\(home.path)/cx"
    let day = "\(cx)/sessions/2026/11/20"
    try FileManager.default.createDirectory(atPath: day, withIntermediateDirectories: true)
    let rollout = "\(day)/rollout-2026-11-20T09-15-02-01941d3a-7c00-7000-8000-000000000001.jsonl"
    let line =
      #"{"timestamp":"2026-11-20T09:15:30.250Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":12.5,"window_minutes":300,"resets_at":1795209852},"secondary":null}}}"#
    try (line + "\n").write(toFile: rollout, atomically: true, encoding: .utf8)
    let config: [String: JSON] = [
      "claude": "/usr/bin/false", "codex": "/usr/bin/true", "tmux": "/usr/bin/true", "sessionNames": ["enabled": false],
      "claudeConfigDirs": [], "codexHomes": [.string(cx)],
    ]
    try JSON.object(config).text.write(toFile: home.config, atomically: true, encoding: .utf8)
    var settings = UsageSettings()
    settings.keychain = false
    let service = try Service(home: home, sbPath: "/usr/bin/true")
    let reader = UsageReader(service: service, settings: settings)
    let account = Account.codex(CodexAccount(folder: cx))
    let good = reader.read(account)
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: rollout)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: rollout) }

    let failed = reader.read(account)

    #expect(good.error == nil, "\(good.error ?? "")")
    #expect(good.limits.map(\.percent) == [12.5])
    #expect(failed.error?.contains(rollout) == true, "\(failed.error ?? "nil")")
    #expect(failed.signedOut == nil)
    #expect(failed.limits == good.limits)
    #expect(failed.checked == good.checked)
    withExtendedLifetime(service) {}
  }
}
