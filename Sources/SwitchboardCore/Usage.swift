import CryptoKit
import Foundation

/// The `usage` object in config.json.
public struct UsageSettings: Codable, Equatable, Sendable {
  /// The endpoint that claude's `/usage` reads. It reports the account's use
  /// and runs no model.
  public var url: String = "https://api.anthropic.com/api/oauth/usage"
  /// How often sbd reads every account's usage. 0 turns off the timer, and
  /// only `sb usage` reads it.
  public var pollSeconds: Double = 300
  /// Whether sbd reads the credentials from the login keychain before the
  /// account's .credentials.json. Tests turn it off, so they never read the
  /// user's logins.
  public var keychain = true

  public init() {}

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let d = UsageSettings()
    url = try c.decodeIfPresent(String.self, forKey: .url) ?? d.url
    pollSeconds = try c.decodeIfPresent(Double.self, forKey: .pollSeconds) ?? d.pollSeconds
    keychain = try c.decodeIfPresent(Bool.self, forKey: .keychain) ?? d.keychain
  }
}

/// One limit of a Claude plan, such as the 5-hour session or the week.
public struct UsageLimit: Codable, Equatable, Sendable {
  /// `session`, `weekly_all`, or `weekly_scoped`, as the endpoint names it.
  public var kind: String
  public var label: String
  public var percent: Double
  /// When the limit resets, in ms since the epoch, or nil when no window is open.
  public var resetsAt: Int64?
  /// `normal`, `warning`, or `critical`, when the endpoint reports one.
  public var severity: String?

  /// Whether the limit is at `limit` percent or more. A limit whose reset is
  /// at or before `now` counts as unused, because the reading can be older
  /// than the reset.
  public func isSpent(limit: Double = 100, now: Int64 = nowMs()) -> Bool {
    percent >= limit && (resetsAt ?? .max) > now
  }

  public init(kind: String, label: String, percent: Double, resetsAt: Int64? = nil, severity: String? = nil) {
    self.kind = kind
    self.label = label
    self.percent = percent
    self.resetsAt = resetsAt
    self.severity = severity
  }
}

/// The last reading of one account's usage.
public struct AccountUsage: Codable, Equatable, Sendable {
  public var name: String
  public var folder: String
  public var email: String?
  public var limits: [UsageLimit]
  /// When sbd last read the limits, in ms since the epoch.
  public var checked: Int64?
  /// Why the last read failed. `limits` then holds the reading before it.
  public var error: String?
  /// True when the account holds no login, so claude would ask for /login.
  /// nil means signed in, or a reading from an sbd that does not report it.
  public var signedOut: Bool?

  public init(
    name: String, folder: String, email: String? = nil, limits: [UsageLimit] = [], checked: Int64? = nil,
    error: String? = nil, signedOut: Bool? = nil
  ) {
    self.name = name
    self.folder = folder
    self.email = email
    self.limits = limits
    self.checked = checked
    self.error = error
    self.signedOut = signedOut
  }

  /// Whether the last read failed and no earlier reading has limits to show.
  public var failedWithoutLimits: Bool { limits.isEmpty && error != nil }

  /// Whether the account can take more work: `.spent` when any limit is
  /// spent by `UsageLimit.isSpent`, with the latest reset among those limits.
  public func budget(limit: Double = 100, now: Int64 = nowMs()) -> UsageBudget {
    if limits.isEmpty { return .unknown(error ?? "no reading yet") }
    let spent = limits.filter { $0.isSpent(limit: limit, now: now) }
    if spent.isEmpty { return .left }
    return .spent(resetsAt: spent.compactMap(\.resetsAt).max())
  }
}

/// Whether an account has room under its plan's limits.
public enum UsageBudget: Equatable, Sendable {
  case left
  /// A limit is spent. It resets at `resetsAt`, in ms since the epoch.
  case spent(resetsAt: Int64?)
  /// sbd has no reading of the account, for the reason given.
  case unknown(String)

  public var isSpent: Bool {
    if case .spent = self { return true }
    return false
  }
}

public enum Usage {
  /// The limits in a response from the usage endpoint. It reads `limits`, or
  /// the older `five_hour` and `seven_day` fields when `limits` is missing.
  /// An account with no open 5-hour window reports no session limit, so this
  /// adds one at 0%.
  public static func parse(_ data: Data) throws -> [UsageLimit] {
    guard let root = try? JSONCoding.decoder.decode(JSON.self, from: data), root.object != nil else {
      throw APIError("the usage endpoint answered something other than a JSON object")
    }
    var limits: [UsageLimit]
    if let list = root["limits"]?.array {
      limits = list.compactMap(limit)
    } else {
      limits = [("five_hour", "session"), ("seven_day", "weekly_all")].compactMap { key, kind in
        guard let window = root[key], let percent = window["utilization"]?.double else { return nil }
        return UsageLimit(
          kind: kind, label: label(kind, scope: nil), percent: percent,
          resetsAt: window["resets_at"]?.string.flatMap(Transcript.milliseconds))
      }
    }
    if !limits.contains(where: { $0.kind == "session" }) {
      limits.insert(UsageLimit(kind: "session", label: label("session", scope: nil), percent: 0), at: 0)
    }
    return limits
  }

  private static func limit(_ entry: JSON) -> UsageLimit? {
    guard let kind = entry["kind"]?.string else { return nil }
    return UsageLimit(
      kind: kind, label: label(kind, scope: entry["scope"]), percent: entry["percent"]?.double ?? 0,
      resetsAt: entry["resets_at"]?.string.flatMap(Transcript.milliseconds), severity: entry["severity"]?.string)
  }

  private static func label(_ kind: String, scope: JSON?) -> String {
    switch kind {
    case "session": return "Session (5h)"
    case "weekly_all": return "Week (all models)"
    case "weekly_scoped":
      let name = scope?["model"]?["display_name"]?.string ?? scope?["surface"]?.string ?? "scoped"
      return "Week (\(name))"
    default: return kind.replacingOccurrences(of: "_", with: " ")
    }
  }

  /// The access token and its expiry, in ms since the epoch, from the JSON
  /// that claude keeps in the keychain or in .credentials.json.
  public static func credentials(from data: Data) -> (token: String, expiresAt: Int64?)? {
    guard let oauth = (try? JSONCoding.decoder.decode(JSON.self, from: data))?["claudeAiOauth"],
      let token = oauth["accessToken"]?.string, !token.isEmpty
    else { return nil }
    return (token, oauth["expiresAt"]?.double.map { Int64($0) })
  }

  /// How long until `ms`, such as "in 2h 5m" or "in 3d 4h".
  public static func until(_ ms: Int64, now: Int64 = nowMs()) -> String {
    let s = (ms - now) / 1000
    if s < 60 { return "now" }
    if s < 3600 { return "in \(s / 60)m" }
    if s < 86400 { return "in \(s / 3600)h \(s % 3600 / 60)m" }
    return "in \(s / 86400)d \(s % 86400 / 3600)h"
  }
}

extension ClaudeAccount {
  /// The keychain service under which claude keeps the account's credentials.
  /// With CLAUDE_CONFIG_DIR set, claude adds the first 8 hex digits of the
  /// SHA-256 of its value. This hashes the value that `apply` sets.
  public static func keychainService(_ folder: String) -> String {
    let base = "Claude Code-credentials"
    var env: [String: String] = [:]
    apply(folder, to: &env)
    guard let dir = env["CLAUDE_CONFIG_DIR"] else { return base }
    return base + "-" + SHA256.hash(data: Data(dir.utf8)).map { String(format: "%02x", $0) }.joined().prefix(8)
  }

  /// The .credentials.json that claude writes when it has no keychain.
  public static func credentialsFile(_ folder: String) -> String {
    "\(normalize(folder))/.credentials.json"
  }
}
