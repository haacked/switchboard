import Foundation
import SwitchboardCore

/// The row of Settings ▸ General ▸ GitHub that says where sbd learns of PR changes, from `sb sources`.
enum PRUpdatesRow {
  /// What the app knows of sbd's sources.
  enum Read: Equatable {
    /// No answer yet.
    case loading
    /// sbd has no `sources` op, or answers in a form that this app can't read.
    case olderSbd
    case report(PRSources)
  }

  struct Text: Equatable {
    var title: String
    var detail: String?
  }

  static func text(_ read: Read, now: Int64) -> Text {
    switch read {
    case .loading:
      return Text(title: "PR updates: asking sbd…")
    case .olderSbd:
      return Text(
        title: pollingTitle(nil),
        detail:
          "This sbd is older than the app and doesn't report where PR updates come from. `sb service install` restarts it on the app's build."
      )
    case .report(let sources):
      return text(sources, now: now)
    }
  }

  private static func text(_ sources: PRSources, now: Int64) -> Text {
    let pollingTitle = pollingTitle(sources.pollSeconds)
    guard let s = sources.providers.first(where: { $0.id == GitHubEventStream.provider }) else {
      return Text(
        title: pollingTitle,
        detail: "GitHub Event Streams is off. Set `github.events.mode` to `read` in config.json to turn it on.")
    }
    switch s.state {
    case "live" where s.shadow:
      return Text(
        title: pollingTitle,
        detail: s.wanted == 0
          ? "GitHub Event Streams runs in shadow mode and has no open PRs to follow."
          : "GitHub Event Streams runs in shadow mode: it follows \(s.covered) of \(s.wanted) PRs and counts their events, but only polling updates them."
      )
    case "live":
      guard s.wanted > 0 else {
        return Text(title: "PR updates: live from GitHub Event Streams", detail: "It has no open PRs to follow yet.")
      }
      return Text(
        title: "PR updates: live from GitHub Event Streams for \(s.covered) of \(s.wanted) PRs",
        detail: "sbd still polls GitHub\(interval(sources.pollSeconds)), so a missed event only delays an update."
      )
    case "unavailable":
      var detail = s.reason.flatMap(sentence) ?? "GitHub Event Streams is unavailable."
      if let at = s.retryAt, at > now { detail += " sbd tries again \(fromNow(at, now: now))." }
      return Text(title: pollingTitle, detail: detail)
    case "off":
      return Text(title: pollingTitle, detail: "GitHub Event Streams is off.")
    default:
      return Text(title: pollingTitle, detail: "GitHub Event Streams is \(s.state).")
    }
  }

  /// The title that says how often sbd polls a pending PR.
  private static func pollingTitle(_ seconds: Double?) -> String { "PR updates: polling GitHub" + interval(seconds) }

  /// The end of the polling phrase. An sbd that doesn't report its interval gets none.
  private static func interval(_ seconds: Double?) -> String {
    guard let seconds else { return "" }
    guard seconds > 0 else { return " only when `sb poll` runs" }
    return " every \(String(format: "%g", seconds)) s"
  }

  /// GitHub's reason, ended as a sentence. nil when the reason is blank.
  private static func sentence(_ reason: String) -> String? {
    let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : Wait.sentence(trimmed)
  }
}
