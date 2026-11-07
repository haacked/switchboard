import Foundation
import SwitchboardCore
import Testing

@testable import SwitchboardApp

@Suite struct TriageDetailPane {
  func session(waitsToStart: Bool) -> SessionSummary {
    var s = needsItem("a")
    if waitsToStart { s.followup = Followup(prompt: "p") }
    return s
  }

  @Test func showsTheSummaryOfAnUnstartedFollowUpWhileTerminalIsOn() {
    let s = session(waitsToStart: true)
    #expect(s.waitsToStart)
    #expect(TriageDetail.pane(for: s, showingTerminal: true) == .summary)
  }

  @Test func showsTheTerminalOfAStartedFollowUpWhileTerminalIsOn() {
    var s = session(waitsToStart: true)
    s.followup?.started = 1
    #expect(!s.waitsToStart)
    #expect(TriageDetail.pane(for: s, showingTerminal: true) == .terminal)
  }

  @Test func showsTheSummaryOfADocketRowWhileTerminalIsOn() {
    #expect(TriageDetail.pane(for: docketRow(url: "https://github.com/o/r/pull/1"), showingTerminal: true) == .summary)
  }

  @Test func showsTheTerminalOfAStartedSessionWhileTerminalIsOn() {
    #expect(TriageDetail.pane(for: session(waitsToStart: false), showingTerminal: true) == .terminal)
  }

  @Test func showsTheSummaryWhileTerminalIsOff() {
    #expect(TriageDetail.pane(for: session(waitsToStart: false), showingTerminal: false) == .summary)
  }

  func docketRow(url: String) -> SessionSummary {
    var s = session(waitsToStart: false)
    s.cwd = ""
    s.docket = DocketSummary(DocketSession(pullRequest: "o/r#1", url: url), DocketStatus())
    // The bar must link a docket row to docket's URL and never to this `pr`.
    s.pr = PRSummary(
      PullRequest(id: "PR_5", number: 5, url: "https://github.com/o/r/pull/5", repo: "o/r"))
    return s
  }

  @Test func linksADocketRowToItsPullRequest() {
    let link = TriageDetail.prLink(for: docketRow(url: "https://github.com/o/r/pull/1"))
    #expect(link?.label == "o/r#1")
    #expect(link?.url == URL(string: "https://github.com/o/r/pull/1"))
  }

  @Test func refusesADocketUrlThatIsNotHttps() {
    #expect(TriageDetail.prLink(for: docketRow(url: "http://github.com/o/r/pull/1")) == nil)
  }

  @Test func linksASessionToItsPullRequest() {
    var s = session(waitsToStart: false)
    s.pr = PRSummary(
      PullRequest(id: "PR_5", number: 5, url: "https://github.com/o/r/pull/5", repo: "o/r"))
    let link = TriageDetail.prLink(for: s)
    #expect(link?.label == s.pr?.line)
    #expect(link?.url == URL(string: "https://github.com/o/r/pull/5"))
  }

  @Test func hasNoPullRequestLinkForASessionWithoutOne() {
    #expect(TriageDetail.prLink(for: session(waitsToStart: false)) == nil)
  }
}
