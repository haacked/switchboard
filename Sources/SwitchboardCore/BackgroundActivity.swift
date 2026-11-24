import Foundation

/// The Loops tab's Background Activity list: the Operator's reports, the actions it ran, and its judgments, built from
/// the Operator's own events only (Decision 44 in the notes repo's `plans/410-invisible-operator.md`).
public enum BackgroundActivity {
  /// The event kinds that the list reads from the Operator.
  public static let kinds = [OperatorReport.event, "wait-resolved", "judge"]
  /// How many of the Operator's newest events the list reads.
  public static let limit = 100

  public struct Entry: Identifiable, Equatable, Sendable {
    /// The id of the event that the entry shows.
    public var id: Int64
    public var t: Int64
    public var text: String
    /// The id of the session that the entry is about.
    public var subject: String?
  }

  /// The entries of `events`, newest first. A `wait-resolved` event without an action, or one whose wait a report
  /// names, gives no entry. A `judge` event without a `kind` or an `answer` gives none either.
  public static func entries(_ events: [Event]) -> [Entry] {
    let reported = Set(events.compactMap { $0.kind == OperatorReport.event ? $0.data["wait"]?.string : nil })
    return events.compactMap { entry($0, reported: reported) }.sorted { ($0.t, $0.id) > ($1.t, $1.id) }
  }

  private static func entry(_ event: Event, reported: Set<String>) -> Entry? {
    let data = event.data
    switch event.kind {
    case OperatorReport.event:
      guard let report = OperatorReport(event) else { return nil }
      let text = report.needsYou ? "Asked: \(report.text)" : report.text
      return Entry(id: event.id, t: event.t, text: text, subject: report.about)
    case "wait-resolved":
      guard let detail = data["action"]?["detail"]?.string, let waitData = data["wait"],
        let wait = try? JSONCoding.convert(waitData, to: Wait.self), !reported.contains(wait.id)
      else { return nil }
      return Entry(id: event.id, t: event.t, text: detail, subject: wait.actionSubject?.id)
    case "judge":
      guard let kind = data["kind"]?.string, let answer = data["answer"]?.string else { return nil }
      return Entry(id: event.id, t: event.t, text: "Judge \(kind): \(answer)", subject: data["session"]?.string)
    default:
      return nil
    }
  }
}
