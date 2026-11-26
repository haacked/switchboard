import Foundation
import SwitchboardCore
import Testing

@testable import SwitchboardApp

private let now: Int64 = 1_000_000_000
private let notEnabled = "Event subscriptions are not enabled for this account."

/// The GitHub Event Streams provider as `sb sources` reports it.
private func github(
  _ state: String, reason: String? = nil, retryAt: Int64? = nil, wanted: Int = 0, covered: Int = 0,
  shadow: Bool = false
) -> PRSources.Source {
  PRSources.Source(
    id: "github-events", state: state, reason: reason, retryAt: retryAt, wanted: wanted, covered: covered,
    shadow: shadow)
}

/// sbd's answer with `source` as its only provider, or with none when `source` is nil.
private func report(_ source: PRSources.Source?, pollSeconds: Double? = 30) -> PRUpdatesRow.Read {
  .report(PRSources(providers: source.map { [$0] } ?? [], pollSeconds: pollSeconds))
}

private func text(_ read: PRUpdatesRow.Read) -> PRUpdatesRow.Text {
  PRUpdatesRow.text(read, now: now)
}

/// The Settings row that says where PR updates come from, for each state that sbd can report.
@Suite struct PRUpdatesRowTests {
  // MARK: Before an answer, and an older sbd

  /// The ellipsis is one character, not three dots.
  @Test func loadingSaysTheAppAsksSbd() {
    #expect(text(.loading) == PRUpdatesRow.Text(title: "PR updates: asking sbd\u{2026}", detail: nil))
  }

  @Test func anOlderSbdSaysItPollsAndHowToUpdateIt() {
    #expect(
      text(.olderSbd)
        == PRUpdatesRow.Text(
          title: "PR updates: polling GitHub",
          detail:
            "This sbd is older than the app and doesn't report where PR updates come from. `sb service install`"
            + " restarts it on the app's build."))
  }

  // MARK: Mode off

  @Test func modeOffSaysHowToTurnItOn() {
    #expect(
      text(report(nil))
        == PRUpdatesRow.Text(
          title: "PR updates: polling GitHub every 30 s",
          detail:
            "GitHub Event Streams is off. Set `github.events.mode` to `read` in config.json to turn it on."))
  }

  @Test func aProviderThatIsOffSaysItIsOff() {
    #expect(
      text(report(github("off")))
        == PRUpdatesRow.Text(title: "PR updates: polling GitHub every 30 s", detail: "GitHub Event Streams is off."))
  }

  // MARK: The polling phrase

  /// A whole number of seconds shows without a fraction.
  @Test(arguments: zip([30.0, 5, 120], ["every 30 s", "every 5 s", "every 120 s"]))
  func theTitleSaysHowOftenSbdPolls(_ pollSeconds: Double, _ every: String) {
    #expect(text(report(nil, pollSeconds: pollSeconds)).title == "PR updates: polling GitHub " + every)
  }

  @Test func noPollSecondsSaysPollingGitHub() {
    #expect(text(report(nil, pollSeconds: nil)).title == "PR updates: polling GitHub")
  }

  @Test func zeroPollSecondsSaysSbdPollsOnlyWhenSbPollRuns() {
    #expect(text(report(nil, pollSeconds: 0)).title == "PR updates: polling GitHub only when `sb poll` runs")
  }

  // MARK: Unavailable

  /// The plan's example.
  @Test func anUnavailableProviderShowsGitHubsReason() {
    #expect(
      text(report(github("unavailable", reason: notEnabled)))
        == PRUpdatesRow.Text(title: "PR updates: polling GitHub every 30 s", detail: notEnabled))
  }

  /// An unavailable provider is not live, whether or not sbd runs it in shadow mode.
  @Test(arguments: [false, true])
  func anUnavailableProviderSaysSbdPolls(_ shadow: Bool) {
    let row = text(report(github("unavailable", reason: notEnabled, wanted: 45, shadow: shadow)))

    #expect(row.title == "PR updates: polling GitHub every 30 s")
  }

  @Test(
    arguments: zip(
      ["Not enabled", "Not enabled.", "Not enabled!", "Not enabled?"],
      ["Not enabled.", "Not enabled.", "Not enabled!", "Not enabled?"]))
  func theReasonEndsInOneStop(_ reason: String, _ shown: String) {
    #expect(text(report(github("unavailable", reason: reason))).detail == shown)
  }

  @Test func anUnavailableProviderWithoutAReasonSaysItIsUnavailable() {
    #expect(text(report(github("unavailable"))).detail == "GitHub Event Streams is unavailable.")
  }

  @Test func aLaterRetrySaysWhenSbdTriesAgain() {
    let retryAt = now + 21_600_000

    let row = text(report(github("unavailable", reason: notEnabled, retryAt: retryAt)))

    #expect(row.detail == notEnabled + " sbd tries again " + fromNow(retryAt, now: now) + ".")
  }

  @Test func aRetryWithoutAReasonFollowsTheUnavailableSentence() {
    let retryAt = now + 60_000

    let row = text(report(github("unavailable", retryAt: retryAt)))

    #expect(row.detail == "GitHub Event Streams is unavailable. sbd tries again " + fromNow(retryAt, now: now) + ".")
  }

  /// A retry that is due already says nothing about when.
  @Test(arguments: [now, now - 1, now - 3_600_000])
  func aRetryThatIsDueSaysNothingOfIt(_ retryAt: Int64) {
    #expect(text(report(github("unavailable", reason: notEnabled, retryAt: retryAt))).detail == notEnabled)
  }

  // MARK: Shadow mode

  /// In shadow mode the source's signals update nothing, so the title must not say the updates are live.
  @Test func shadowModeSaysPollingUpdatesThePRs() {
    #expect(
      text(report(github("live", wanted: 45, covered: 42, shadow: true)))
        == PRUpdatesRow.Text(
          title: "PR updates: polling GitHub every 30 s",
          detail:
            "GitHub Event Streams runs in shadow mode: it follows 42 of 45 PRs and counts their events, but only"
            + " polling updates them."))
  }

  @Test func shadowModeWithNoPRsSaysItHasNoneToFollow() {
    #expect(
      text(report(github("live", shadow: true)))
        == PRUpdatesRow.Text(
          title: "PR updates: polling GitHub every 30 s",
          detail: "GitHub Event Streams runs in shadow mode and has no open PRs to follow."))
  }

  // MARK: Read mode

  /// The plan's example.
  @Test func readModeSaysHowManyPRsAreLive() {
    #expect(
      text(report(github("live", wanted: 45, covered: 42)))
        == PRUpdatesRow.Text(
          title: "PR updates: live from GitHub Event Streams for 42 of 45 PRs",
          detail: "sbd still polls GitHub every 30 s, so a missed event only delays an update."))
  }

  @Test func readModeWithEveryPRCoveredCountsThemAll() {
    #expect(
      text(report(github("live", wanted: 3, covered: 3))).title
        == "PR updates: live from GitHub Event Streams for 3 of 3 PRs")
  }

  @Test func readModeWithNoPRCoveredYetStillCountsTheWantedPRs() {
    #expect(
      text(report(github("live", wanted: 3, covered: 0))).title
        == "PR updates: live from GitHub Event Streams for 0 of 3 PRs")
  }

  @Test(
    arguments: zip(
      [Double?.none, 0],
      [
        "sbd still polls GitHub, so a missed event only delays an update.",
        "sbd still polls GitHub only when `sb poll` runs, so a missed event only delays an update.",
      ]))
  func readModeSaysHowSbdStillPolls(_ pollSeconds: Double?, _ detail: String) {
    #expect(text(report(github("live", wanted: 45, covered: 42), pollSeconds: pollSeconds)).detail == detail)
  }

  @Test func readModeWithNoPRsSaysItHasNoneToFollowYet() {
    #expect(
      text(report(github("live")))
        == PRUpdatesRow.Text(
          title: "PR updates: live from GitHub Event Streams", detail: "It has no open PRs to follow yet."))
  }

  // MARK: Every state

  /// Every user-facing text uses an ellipsis character, never three dots.
  @Test(arguments: [
    PRUpdatesRow.Read.loading, .olderSbd, report(nil), report(github("off")),
    report(github("unavailable", reason: notEnabled, retryAt: now + 60_000)),
    report(github("live", wanted: 45, covered: 42, shadow: true)), report(github("live", wanted: 45, covered: 42)),
  ])
  func noTextUsesThreeDots(_ read: PRUpdatesRow.Read) {
    let row = text(read)

    #expect(!row.title.contains("..."))
    #expect(!(row.detail ?? "").contains("..."))
  }
}
