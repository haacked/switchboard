import CryptoKit
import Foundation
import SwitchboardCore

extension Service {
  var activitySwitch: SwitchFile { SwitchFile(home.activityLog, label: "the activity log") }

  /// Sets the switch when the request names `enabled`, and returns the status. With `counts` false, the
  /// status leaves out the row count and the oldest row, which the app's frequent reads don't need.
  func activityRequest(_ args: JSON) throws -> JSON {
    if let on = try activitySwitch.apply(args) { activityOn = on }
    guard args["counts"]?.bool != false else {
      return try JSON(encoding: ActivityStatus(enabled: activityOn, events: 0, oldest: nil))
    }
    let summary = try store.activitySummary()
    return try JSON(encoding: ActivityStatus(enabled: activityOn, events: summary.count, oldest: summary.oldest))
  }

  func activityClear() throws -> JSON {
    try store.clearActivity()
    return try activityRequest([:])
  }

  /// `durationMs` limits the report to the rows from that many milliseconds before now onward.
  func activityReport(_ args: JSON) throws -> JSON {
    var since: Int64?
    if let duration = args["durationMs"] {
      guard let ms = duration.int, ms >= 0 else { throw APIError("durationMs is a whole number of milliseconds") }
      since = nowMs() - Int64(ms)
    }
    let events = try store.activity(since: since ?? 0)
    return try JSON(encoding: ActivityReport.build(events, enabled: activityOn, since: since))
  }

  /// Logs how long the last resume took to reach this SessionStart, while the log is on. `facts` are the
  /// session's facts before the SessionStart, so only the first SessionStart after a resume counts.
  func recordResumeReady(_ id: String, _ facts: SessionFacts, at t: Int64) {
    guard activityOn, let trigger = facts.lastResumeTrigger, let launch = facts.lastLaunch,
      !facts.startedSinceLaunch
    else { return }
    let event = ActivityEvent(
      t: t, kind: "resume.ready", session: id,
      data: ["trigger": .string(trigger.rawValue), "ms": .number(Double(t - launch))])
    do { try store.append(activity: event) } catch { logLine("can't store resume.ready for \(id): \(error)") }
  }

  /// Stores the app's events that `ActivityKinds` accepts and that name no session or a session sbd knows,
  /// while the log is on. It drops the rest.
  func activityRecord(_ args: JSON) throws -> JSON {
    let events = try JSONCoding.convert(args["events"] ?? .array([]), to: [ActivityEvent].self)
    guard activityOn else { return ["stored": 0, "refused": .number(Double(events.count))] }
    let accepted = events.filter { ActivityKinds.accepts($0) && $0.session.map { entries[$0] != nil } != false }
    try store.transaction {
      for e in accepted {
        try store.append(activity: e)
      }
    }
    return ["stored": .number(Double(accepted.count)), "refused": .number(Double(events.count - accepted.count))]
  }

  /// Logs a message that the user wrote, while the log is on. The row holds a keyed hash of the normalized
  /// text, so the report can count repeats without the text.
  func recordSendActivity(_ session: String?, _ text: String, via: String, _ delivery: Delivery?, targets: Int? = nil) {
    guard activityOn else { return }
    // A message with images ends with the paths of their copies, which differ each time.
    let text = session.flatMap { Attachments.split(text, folder: home.attachmentsFolder($0))?.text } ?? text
    do {
      var data: [String: JSON] = [
        "via": .string(via), "length": .number(Double(text.count)), "textHash": .string(try textHash(text)),
      ]
      if let delivery { data["delivery"] = .string(delivery.rawValue) }
      if let targets { data["targets"] = .number(Double(targets)) }
      try store.append(activity: ActivityEvent(t: nowMs(), kind: "send", session: session, data: .object(data)))
    } catch {
      logLine("can't store a send in the activity log: \(error)")
    }
  }

  /// Where a `send` request came from: the app's message field, the Inbox's reply, an Inbox option's canned
  /// text, or else the CLI.
  static func sendVia(_ via: String?) -> String {
    ["field", "inbox", "option"].contains(via ?? "") ? via! : "cli"
  }

  /// The first 16 hex digits of an HMAC-SHA256 of the text, after the text is lowercased and each run of white
  /// space becomes one space.
  func textHash(_ text: String) throws -> String {
    let normalized = text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    let code = HMAC<SHA256>.authenticationCode(for: Data(normalized.utf8), using: try loadActivityKey())
    return code.prefix(8).map { String(format: "%02x", $0) }.joined()
  }

  /// Reads the key, or makes one that only the user can read.
  private func loadActivityKey() throws -> SymmetricKey {
    if let activityKey { return activityKey }
    let path = home.activityKey
    var data = FileManager.default.contents(atPath: path) ?? Data()
    if data.count != 32 {
      data = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
      guard FileManager.default.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600])
      else { throw APIError("can't write \(path)") }
    }
    let key = SymmetricKey(data: data)
    activityKey = key
    return key
  }

  func pruneActivityIfDue(now: Int64) {
    guard now - activityPruned >= ActivityLog.pruneEveryMs else { return }
    activityPruned = now
    do { try store.pruneActivity(before: now - ActivityLog.retentionMs) } catch {
      logLine("can't prune the activity log: \(error)")
    }
  }
}
