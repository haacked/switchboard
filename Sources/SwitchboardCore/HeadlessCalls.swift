import Foundation

/// The one-shot `claude -p` calls that sbd makes for itself.
public enum HeadlessKind: String, Codable, Sendable {
  case triage, mergeBrief, quickAsk, planUpdate, skillLabel, replyGate, ciFailure, topupPick, sessionName, slackThreads,
    slackSelf
  /// A headless schedule's run.
  case schedule
}

/// One `claude -p` call that sbd made for itself, as the `headless_calls` table stores it. `kind` is a
/// `HeadlessKind`. `session` is nil for a call that belongs to no session.
/// `error` says why the call gave no answer that sbd could use.
public struct HeadlessCall: Codable, Equatable, Sendable {
  public var id: Int64?
  public var t: Int64
  public var kind: String
  public var session: String?
  public var model: String?
  public var usage: HeadlessUsage?
  public var error: String?

  public init(
    id: Int64? = nil, t: Int64, kind: String, session: String? = nil, model: String? = nil,
    usage: HeadlessUsage? = nil, error: String? = nil
  ) {
    self.id = id
    self.t = t
    self.kind = kind
    self.session = session
    self.model = model
    self.usage = usage
    self.error = error
  }
}

/// What `sb usage headless` shows: the calls and their tokens for each day and kind.
public struct HeadlessUsageReport: Codable, Equatable, Sendable {
  public struct Row: Codable, Equatable, Sendable {
    /// The local day, as yyyy-MM-dd.
    public var day: String
    public var kind: String
    public var calls: Int
    public var errors: Int
    public var usage: HeadlessUsage
    public var models: [String]
  }

  public var since: Int64?
  public var rows: [Row]

  /// The rows of the calls, one per local day and kind, sorted by day and then kind. `since` is only reported.
  public static func build(_ calls: [HeadlessCall], since: Int64?, timeZone: TimeZone) -> HeadlessUsageReport {
    let format = Wait.formatter("yyyy-MM-dd", timeZone)
    var rows: [String: Row] = [:]
    for call in calls {
      let day = format.string(from: Date(timeIntervalSince1970: Double(call.t) / 1000))
      let key = day + "\t" + call.kind
      var row = rows[key] ?? Row(day: day, kind: call.kind, calls: 0, errors: 0, usage: HeadlessUsage(), models: [])
      row.calls += 1
      if call.error != nil { row.errors += 1 }
      row.usage = row.usage + (call.usage ?? HeadlessUsage())
      if let model = call.model, !row.models.contains(model) { row.models = (row.models + [model]).sorted() }
      rows[key] = row
    }
    return HeadlessUsageReport(since: since, rows: rows.values.sorted { ($0.day, $0.kind) < ($1.day, $1.kind) })
  }

  /// The lines that `sb usage headless` prints: a header, then one line per row.
  public var table: [String] {
    func left(_ text: String) -> String { text.padding(toLength: 12, withPad: " ", startingAt: 0) }
    func right(_ text: String) -> String { String(repeating: " ", count: max(0, 12 - text.count)) + text }
    let header = ["calls", "errors", "input", "output", "cache read", "cache write"]
    return [left("day") + left("kind") + header.map(right).joined() + "  models"]
      + rows.map { row in
        let counts = [
          row.calls, row.errors, row.usage.input, row.usage.output, row.usage.cacheRead, row.usage.cacheWrite,
        ]
        return left(row.day) + left(row.kind) + counts.map { right(String($0)) }.joined() + "  "
          + row.models.joined(separator: ", ")
      }
  }
}
