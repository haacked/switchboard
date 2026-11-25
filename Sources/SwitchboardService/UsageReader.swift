import Foundation
import SwitchboardCore

/// Reads each account's plan usage on a timer and when `sb usage` asks. A
/// Claude account's usage comes from the endpoint that claude's `/usage`
/// reads. A Codex account's comes from its newest rollout. One read runs at
/// a time, on `queue`. The last reading of each account stays in `readings`,
/// which any thread may read. `lock` guards `readings`, so the reader is
/// Sendable.
final class UsageReader: @unchecked Sendable {
  unowned let service: Service
  let settings: UsageSettings
  let queue = DispatchQueue(label: "sbd.usage")
  private var timer: DispatchSourceTimer?
  private let lock = NSLock()
  private var readings: [String: AccountUsage] = [:]

  init(service: Service, settings: UsageSettings) {
    self.service = service
    self.settings = settings
  }

  /// Reads every account now, and again every `pollSeconds`.
  func start() {
    guard settings.pollSeconds > 0 else { return }
    let t = DispatchSource.makeTimerSource(queue: queue)
    t.schedule(deadline: .now(), repeating: settings.pollSeconds)
    t.setEventHandler { [self] in _ = readAll() }
    t.resume()
    timer = t
  }

  /// Reads every account and returns the readings. The caller must not be on
  /// the service's queue.
  func read() -> [AccountUsage] {
    queue.sync { readAll() }
  }

  /// The last reading of each account, in the order of `sb account`. An
  /// account that was never read has no limits.
  func latest() -> [AccountUsage] {
    let accounts = service.queue.sync { service.listedAccounts() }
    return lock.withLock {
      accounts.map { readings[$0.folder] ?? AccountUsage(name: $0.name, folder: $0.folder, agent: $0.agent) }
    }
  }

  /// The last reading of one account, from any thread.
  func latest(_ folder: String) -> AccountUsage? {
    lock.withLock { readings[ClaudeAccount.normalize(folder)] }
  }

  /// Whether the account in the config folder may spend more, from the last
  /// reading. Auto-continue calls it from the service's queue. It reads no
  /// network. Only a spent limit says no. An account that sbd has not read
  /// says yes.
  func hasBudget(account: String) -> Bool {
    latest(account)?.budget().isSpent != true
  }

  /// Whether a read of the account succeeded after `since`. A failed read keeps the last good read's `checked`,
  /// so only a reading without an error counts.
  func loginWorks(account: String, since: Int64) -> Bool {
    guard let reading = latest(account), reading.error == nil, let checked = reading.checked else { return false }
    return checked > since
  }

  /// Reads one account now and returns the reading. The caller must not be on
  /// the service's queue.
  func read(_ account: Account) -> AccountUsage {
    queue.sync { keep([reading(account)])[0] }
  }

  private func readAll() -> [AccountUsage] {
    let accounts = service.queue.sync { service.listedAccounts() }
    return keep(concurrentMap(accounts) { reading($0) })
  }

  private func keep(_ fresh: [AccountUsage]) -> [AccountUsage] {
    lock.withLock {
      fresh.map { reading in
        var reading = reading
        // A failed read keeps the limits of the last good one.
        if reading.error != nil, let old = readings[reading.folder] {
          reading.limits = old.limits
          reading.checked = old.checked
        }
        readings[reading.folder] = reading
        return reading
      }
    }
  }

  private func reading(_ account: Account) -> AccountUsage {
    switch account {
    case .claude(let claude): reading(claude)
    case .codex(let codex): reading(codex)
    }
  }

  private func reading(_ account: ClaudeAccount) -> AccountUsage {
    let oauth = oauthAccount(account)
    var usage = AccountUsage(name: account.name, folder: account.folder, email: oauth?["emailAddress"]?.string)
    do {
      let token = try accessToken(account)
      usage.limits = try Usage.parse(try fetch(token), plan: oauth?["planDisplayName"]?.string)
      usage.checked = nowMs()
    } catch {
      usage.fail(with: error)
    }
    return usage
  }

  /// The account's access token. A token that expires within a minute is
  /// refreshed first, through claude.
  private func accessToken(_ account: ClaudeAccount) throws -> String {
    let login = account.command(service.config.claude)
    guard var creds = try credentials(account) else { throw SignedOut(login: login) }
    if expiresSoon(creds.expiresAt) {
      refresh(account)
      guard let fresh = try credentials(account), !expiresSoon(fresh.expiresAt) else {
        throw APIError("the access token expired and claude could not refresh it; run `\(login)` and /login")
      }
      creds = fresh
    }
    return creds.token
  }

  /// A token this close to expiry could expire before the request arrives.
  private static let refreshMarginMs: Int64 = 60_000

  private func expiresSoon(_ expiresAt: Int64?) -> Bool {
    guard let expiresAt else { return false }
    return expiresAt < nowMs() + Self.refreshMarginMs
  }

  /// The credentials from the login keychain, else from .credentials.json,
  /// or nil when neither holds a login. It throws when the keychain read
  /// fails for a reason other than a missing item and the file holds no
  /// login, because a locked keychain does not mean the account signed out.
  private func credentials(_ account: ClaudeAccount) throws -> (token: String, expiresAt: Int64?)? {
    var keychainFailure: String?
    if settings.keychain {
      do {
        let r = try runCommand(
          "/usr/bin/security", ["find-generic-password", "-s", account.keychainService, "-w"],
          timeout: 10)
        if r.status == 0, let creds = Usage.credentials(from: Data(r.stdout.utf8)) { return creds }
        keychainFailure = Self.keychainFailure(status: r.status, stderr: r.stderr)
      } catch {
        keychainFailure = "\(error)"
      }
    }
    if let creds = FileManager.default.contents(atPath: account.credentialsFile).flatMap(
      Usage.credentials)
    {
      return creds
    }
    if let keychainFailure { throw APIError("could not read the login from the keychain: \(keychainFailure)") }
    return nil
  }

  /// The exit status of `security find-generic-password` when no item matches.
  private static let keychainItemNotFound: Int32 = 44

  /// Why `security find-generic-password` failed, or nil when it succeeded or
  /// found no item. A missing item means the account is signed out.
  static func keychainFailure(status: Int32, stderr: String) -> String? {
    guard status != 0, status != keychainItemNotFound else { return nil }
    return "security exited with status \(status): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
  }

  /// claude refreshes an expired token when `claude mcp get` looks up the
  /// claude.ai connectors. The server name does not need to exist.
  private func refresh(_ account: ClaudeAccount) {
    guard let claude = findExecutable(service.config.claude) else { return }
    var env = ProcessInfo.processInfo.environment
    account.apply(to: &env)
    _ = try? runCommand(claude, ["mcp", "get", "switchboard-usage-refresh"], env: env, timeout: 30)
  }

  /// The limits of the account's newest rollout, after `codex login status`
  /// says the account is signed in. A reading's `checked` is the time Codex
  /// reported the limits. Without a rollout that has them, the reading has
  /// no limits and no error. A rollout that can't be read is an error.
  private func reading(_ account: CodexAccount) -> AccountUsage {
    var usage = AccountUsage(name: account.name, folder: account.folder, agent: .codex)
    do {
      try requireCodexLogin(account)
      if let rollout = try CodexRollout.rateLimits(home: account.folder, on: service.mac.machine) {
        usage.limits = rollout.limits
        usage.checked = rollout.checked
      }
    } catch {
      usage.fail(with: error)
    }
    return usage
  }

  /// How long `codex login status` may take before the reading records an error.
  private static let codexLoginTimeout = 10.0

  /// Runs `codex login status` under the account. A keyring login leaves no
  /// auth.json, so only codex can tell whether the account is signed in.
  private func requireCodexLogin(_ account: CodexAccount) throws {
    let program = service.config.codex
    guard let codex = findExecutable(program) else {
      throw APIError("can't find \(program). Set \"codex\" in \(service.home.config) to its path")
    }
    var env = ProcessInfo.processInfo.environment
    account.apply(to: &env)
    try Self.checkCodexLogin(
      runCommand(codex, ["login", "status"], env: env, timeout: Self.codexLoginTimeout), login: account.loginCommand)
  }

  /// Throws `SignedOut` when `codex login status` exits 1 and says the account
  /// is not logged in, and another error when it fails otherwise or the timeout
  /// ends it. codex also exits 1 when it can't load its config or read its
  /// login, and logging in again fixes neither. A codex that SIGTERM ends may
  /// exit 1, so it checks the timeout first.
  static func checkCodexLogin(_ r: CommandResult, login: String) throws {
    if r.timedOut { throw APIError("`codex login status` did not answer within \(Int(codexLoginTimeout)) s") }
    switch r.status {
    case 0: return
    case 1 where (r.stderr + r.stdout).contains("Not logged in"): throw SignedOut(login: login, then: "")
    default: throw APIError("`codex login status` failed: \(r.problem)")
    }
  }

  private func fetch(_ token: String) throws -> Data {
    guard let url = URL(string: settings.url) else { throw APIError("usage.url \(settings.url) is not a URL") }
    var request = URLRequest(url: url, timeoutInterval: 15)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let (status, _, data): (Int, [String: String], Data)
    do {
      (status, _, data) = try httpRequest(request)
    } catch {
      throw APIError("the usage request failed: \(error.localizedDescription)")
    }
    guard status == 200 else { throw APIError("the usage endpoint answered HTTP \(status)") }
    return data
  }

  /// The account that claude records in the folder's .claude.json.
  private func oauthAccount(_ account: ClaudeAccount) -> JSON? {
    let json = FileManager.default.contents(atPath: account.configFile).flatMap {
      try? JSONCoding.decoder.decode(JSON.self, from: $0)
    }
    return json?["oauthAccount"]
  }
}

extension Service {
  func usageRequest(_ args: JSON) -> [AccountUsage] {
    guard let reader = usageReader else { return [] }
    return args["refresh"]?.bool == true ? reader.read() : reader.latest()
  }
}

extension UsageReader: QuotaBudget {}

extension AccountUsage {
  /// Records why the read failed. Only an account with no credentials is
  /// signed out: any other failure, such as a locked keychain, leaves
  /// `signedOut` unset.
  mutating func fail(with error: Error) {
    self.error = "\(error)"
    if error is SignedOut { signedOut = true }
  }
}

/// The account has no credentials, so its agent would ask for a login.
struct SignedOut: Error, CustomStringConvertible {
  /// The command that starts the login.
  var login: String
  /// What the user does once `login` runs. claude needs /login. codex login signs in by itself.
  var then = " and /login"
  var description: String { "not signed in; run `\(login)`\(then)" }
}
