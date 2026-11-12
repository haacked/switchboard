import Foundation
import SwitchboardCore

/// Reads each Claude account's plan usage from the endpoint that claude's
/// `/usage` reads, on a timer and when `sb usage` asks. One read runs at a
/// time, on `queue`. The last reading of each account stays in `readings`,
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
    let accounts = service.queue.sync { service.accountList() }
    return lock.withLock {
      accounts.map { readings[$0.folder] ?? AccountUsage(name: $0.name, folder: $0.folder) }
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

  /// Reads one account now and returns the reading. The caller must not be on
  /// the service's queue.
  func read(_ folder: String) -> AccountUsage {
    queue.sync { keep([read(folder, name: ClaudeAccount.name(folder))])[0] }
  }

  private func readAll() -> [AccountUsage] {
    let accounts = service.queue.sync { service.accountList() }
    return keep(concurrentMap(accounts) { read($0.folder, name: $0.name) })
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

  private func read(_ folder: String, name: String) -> AccountUsage {
    let account = oauthAccount(folder)
    var usage = AccountUsage(name: name, folder: folder, email: account?["emailAddress"]?.string)
    do {
      let token = try accessToken(folder)
      usage.limits = try Usage.parse(try fetch(token), plan: account?["planDisplayName"]?.string)
      usage.checked = nowMs()
    } catch {
      usage.fail(with: error)
    }
    return usage
  }

  /// The account's access token. A token that expires within a minute is
  /// refreshed first, through claude.
  private func accessToken(_ folder: String) throws -> String {
    let login = ClaudeAccount.command(service.config.claude, in: folder)
    guard var creds = try credentials(folder) else { throw SignedOut(login: login) }
    if expiresSoon(creds.expiresAt) {
      refresh(folder)
      guard let fresh = try credentials(folder), !expiresSoon(fresh.expiresAt) else {
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
  private func credentials(_ folder: String) throws -> (token: String, expiresAt: Int64?)? {
    var keychainFailure: String?
    if settings.keychain {
      do {
        let r = try runCommand(
          "/usr/bin/security", ["find-generic-password", "-s", ClaudeAccount.keychainService(folder), "-w"],
          timeout: 10)
        if r.status == 0, let creds = Usage.credentials(from: Data(r.stdout.utf8)) { return creds }
        keychainFailure = Self.keychainFailure(status: r.status, stderr: r.stderr)
      } catch {
        keychainFailure = "\(error)"
      }
    }
    if let creds = FileManager.default.contents(atPath: ClaudeAccount.credentialsFile(folder)).flatMap(
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
  private func refresh(_ folder: String) {
    guard let claude = findExecutable(service.config.claude) else { return }
    var env = ProcessInfo.processInfo.environment
    ClaudeAccount.apply(folder, to: &env)
    _ = try? runCommand(claude, ["mcp", "get", "switchboard-usage-refresh"], env: env, timeout: 30)
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
  private func oauthAccount(_ folder: String) -> JSON? {
    let json = FileManager.default.contents(atPath: ClaudeAccount.configFile(folder)).flatMap {
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

/// The account has no credentials, so claude would ask for /login.
struct SignedOut: Error, CustomStringConvertible {
  var login: String
  var description: String { "not signed in; run `\(login)` and /login" }
}
