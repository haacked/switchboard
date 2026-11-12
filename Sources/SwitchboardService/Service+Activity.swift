import Foundation
import SwitchboardCore

extension Service {
  var activitySwitch: SwitchFile { SwitchFile(home.activityLog, label: "the activity log") }

  /// Sets the switch when the request names `enabled`, and returns the status.
  func activityRequest(_ args: JSON) throws -> JSON {
    if let on = try activitySwitch.apply(args) { activityOn = on }
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
      (facts.lastStart ?? 0) < launch
    else { return }
    let event = ActivityEvent(
      t: t, kind: "resume.ready", session: id,
      data: ["trigger": .string(trigger.rawValue), "ms": .number(Double(t - launch))])
    do { try store.append(activity: event) } catch { logLine("can't store resume.ready for \(id): \(error)") }
  }

  func pruneActivityIfDue(now: Int64) {
    guard now - activityPruned >= ActivityLog.pruneEveryMs else { return }
    activityPruned = now
    do { try store.pruneActivity(before: now - ActivityLog.retentionMs) } catch {
      logLine("can't prune the activity log: \(error)")
    }
  }
}
