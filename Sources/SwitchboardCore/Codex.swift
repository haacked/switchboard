import Foundation

/// A Codex account is a CODEX_HOME folder, such as ~/.codex or
/// ~/.codex-work. Codex keeps its login, settings, and rollouts there. The
/// folder counts as an account even when it holds no login file, because a
/// keyring login leaves none.
public struct CodexAccount: Hashable, Sendable {
  /// The normalized folder.
  public let folder: String

  public init(folder: String) { self.folder = ClaudeAccount.normalize(folder) }

  /// The folder's name without its leading dot when it is named like a Codex
  /// folder, so ~/.codex is "codex" and ~/.codex-work is "codex-work". The
  /// agent stays in the name, so a Claude and a Codex folder with the same
  /// suffix get different names. Any other folder's name is its last path
  /// component.
  public var name: String {
    let last = (folder as NSString).lastPathComponent
    return Self.isNamedLikeCodex(folder) ? String(last.dropFirst()) : last
  }

  /// Sets CODEX_HOME to the folder.
  public func apply(to env: inout [String: String]) {
    env["CODEX_HOME"] = folder
  }

  /// The command that signs the account in, for the user to run. Login is
  /// interactive, so sbd never runs it.
  public var loginCommand: String { "CODEX_HOME=\(shellQuote(folder)) codex login" }

  /// Why the folder can't be a Codex account although something names it
  /// one: it holds a Claude login, or it is named like a Claude folder. Such
  /// a folder matches both kinds, so sbd refuses it instead of guessing its
  /// kind.
  public var clash: String? {
    if ClaudeAccount.isNamedLikeClaude(folder) {
      return "\(folder) is named like a Claude folder, so it is no Codex account"
    }
    if ClaudeAccount(folder: folder).holdsAccount {
      return "\(folder) holds a Claude login (.claude.json), so it is no Codex account"
    }
    return nil
  }

  /// Whether the folder is named ~/.codex or ~/.codex-<something>. A Mac's
  /// file system usually ignores case, so ~/.Codex-x can be the folder
  /// ~/.codex-x. A guard that keeps Claude out of Codex folders passes
  /// `ignoringCase`.
  public static func isNamedLikeCodex(_ folder: String, ignoringCase: Bool = false) -> Bool {
    let name = (ClaudeAccount.normalize(folder) as NSString).lastPathComponent
    let last = ignoringCase ? name.lowercased() : name
    return last == ".codex" || (last.hasPrefix(".codex-") && last.count > ".codex-".count)
  }

  /// Why a guard counts the folder as a Codex folder, or nil when it doesn't: the folder is named like a Codex
  /// folder in any case, or `codexHomes` lists it. A folder that also holds a Claude login counts.
  public static func whyCodex(_ folder: String, codexHomes: [String]?) -> String? {
    let folder = ClaudeAccount.normalize(folder)
    if isNamedLikeCodex(folder, ignoringCase: true) { return "\(folder) is named like a Codex folder" }
    let listed = codexHomes?.contains { home in
      let home = ClaudeAccount.normalize(home)
      return home == folder || (home.caseInsensitiveCompare(folder) == .orderedSame && sameFolder(home, folder))
    }
    if listed == true { return "codexHomes lists \(folder)" }
    return nil
  }

  /// Whether both paths name one folder on disk. A case-insensitive volume gives two paths that differ only in
  /// case one folder, and a case-sensitive volume gives them two.
  private static func sameFolder(_ a: String, _ b: String) -> Bool {
    func identity(_ path: String) -> [AnyHashable]? {
      guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
        let volume = attributes[.systemNumber] as? AnyHashable, let file = attributes[.systemFileNumber] as? AnyHashable
      else { return nil }
      return [volume, file]
    }
    guard let first = identity(a) else { return false }
    return first == identity(b)
  }

  /// Each ~/.codex and ~/.codex-* folder among `names`, by name. `names` holds the entries of the home folder.
  /// `Account.survey` leaves out the ones with a `clash`.
  static func discover(_ names: [String], in home: String) -> [CodexAccount] {
    names.filter { isNamedLikeCodex($0) }.sorted().map { "\(home)/\($0)" }.filter(isDirectory)
      .map(CodexAccount.init(folder:))
  }
}

/// Reads the plan limits that Codex writes into its rollouts, the JSONL
/// transcripts under $CODEX_HOME/sessions/YYYY/MM/DD.
public enum CodexRollout {
  /// The limits of the newest `token_count` event that carries
  /// `rate_limits`, and the time Codex wrote it in ms since the epoch.
  public struct Reading: Equatable, Sendable {
    public var limits: [UsageLimit]
    public var checked: Int64
  }

  /// What `sb usage` shows for a Codex account without a reading.
  public static let noReading = "no Codex limits seen yet; they appear after the account's next Codex turn"

  /// The newest reading in the home's newest day folder, or nil when it
  /// has none. Rollout names start with the local start time, so path order
  /// is age order. The reader walks that day's rollouts newest first and
  /// reads each from its end. It skips a compressed `.jsonl.zst` rollout,
  /// because Codex compresses only cold files. It throws when a rollout
  /// can't be read, because that rollout may hold limits.
  public static func rateLimits(home: String, on machine: any Machine) throws -> Reading? {
    guard let day = newestDay("\(home)/sessions", on: machine) else { return nil }
    let rollouts = machine.list(day).filter { $0.hasPrefix("rollout-") && $0.hasSuffix(".jsonl") }.sorted(by: >)
    for name in rollouts {
      if let reading = try lastReading("\(day)/\(name)", on: machine) { return reading }
    }
    return nil
  }

  /// The newest YYYY/MM/DD folder under `sessions`, by name.
  private static func newestDay(_ sessions: String, on machine: any Machine) -> String? {
    var folder = sessions
    for _ in 0..<3 {
      guard let newest = machine.list(folder).filter({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }).max() else {
        return nil
      }
      folder += "/\(newest)"
    }
    return folder
  }

  /// The rollout's newest reading. A rollout that went away after the listing, as when Codex compressed it,
  /// has none.
  private static func lastReading(_ path: String, on machine: any Machine) throws -> Reading? {
    var reading: Reading?
    let read = Transcript.eachLineFromEnd(path, on: machine) { data in
      reading = self.reading(data)
      return reading != nil
    }
    if !read, machine.exists(path) { throw APIError("can't read the Codex rollout \(path)") }
    return reading
  }

  private static let tokenCount = Data("token_count".utf8)

  /// The reading in one rollout line, or nil when the line is no complete
  /// `token_count` event with at least one limit window. It skips a line
  /// without the bytes `token_count` before the JSON decode.
  static func reading(_ data: Data) -> Reading? {
    guard data.range(of: tokenCount) != nil,
      let line = try? JSONCoding.decoder.decode(JSON.self, from: data), line["type"]?.string == "event_msg",
      let payload = line["payload"], payload["type"]?.string == "token_count",
      let limits = payload["rate_limits"], limits.object != nil,
      let checked = line["timestamp"]?.string.flatMap(Transcript.milliseconds)
    else { return nil }
    let windows = ["primary", "secondary"].compactMap { limits[$0] }.compactMap(limit)
    return windows.isEmpty ? nil : Reading(limits: windows, checked: checked)
  }

  /// The largest percent, window, and reset that a reading takes. A newer Codex could write a larger number in
  /// other units. Such a number would overflow a conversion to a whole number here or where `sb usage` prints it.
  private static let maxPercent = 10_000.0
  private static let maxWindowMinutes = 366.0 * 24 * 60
  private static let maxResetSeconds = 1e11

  /// One window, or nil when a number is missing or out of range. Codex reports `resets_at` in seconds since
  /// the epoch. It drops a reset that is out of range and keeps the window.
  private static func limit(_ window: JSON) -> UsageLimit? {
    guard let percent = window["used_percent"]?.double, percent >= 0, percent <= maxPercent,
      let minutes = window["window_minutes"]?.double, minutes > 0, minutes <= maxWindowMinutes
    else { return nil }
    let resets = window["resets_at"]?.double.flatMap { $0 > 0 && $0 < maxResetSeconds ? Int64($0) * 1000 : nil }
    return UsageLimit(
      kind: isSession(minutes) ? "session" : "weekly_all", label: label(minutes: minutes), percent: percent,
      resetsAt: resets)
  }

  /// Whether a window of this many minutes is a `session` limit: 24 hours or less.
  private static func isSession(_ minutes: Double) -> Bool { minutes <= 24 * 60 }

  /// The window's length, such as "5-hour" or "Weekly".
  private static func label(minutes: Double) -> String {
    if minutes == 7 * 24 * 60 { return "Weekly" }
    let (unit, size) = isSession(minutes) ? ("hour", 60.0) : ("day", 24 * 60.0)
    let count = minutes / size
    return count == count.rounded() ? "\(Int(count))-\(unit)" : "\(Int(minutes))-minute"
  }
}
