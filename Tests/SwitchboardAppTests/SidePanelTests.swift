import AppKit
import SwiftUI
import SwitchboardCore
import Testing

@testable import SwitchboardApp

func waitFixture(
  _ id: String, _ kind: Wait.Kind = .ci, pr: Int? = nil, who: String? = nil, until: Int64? = nil, note: String? = nil,
  by: Author = .you, created: Int64 = 0, then: Wait.Then = .resume
) -> Wait {
  Wait(
    id: id, kind: kind, pr: pr.map { Wait.PullRequest(number: $0) }, who: who, until: until, note: note, by: by,
    created: created, then: then)
}

func waitingSession(_ waits: [Wait], notes: [Note] = [], markedDone: Bool = false) -> SessionSummary {
  var s = notedSession(notes, state: markedDone ? .done : .waiting)
  s.waits = waits
  s.markedDone = markedDone
  return s
}

@Suite struct SidePanelWaits {
  @Test(arguments: [
    (Wait.Kind.ci, Author.claude, Wait.Then.resume, "5m", "ci · claude · 5m ago · resumes claude"),
    (.ci, .you, .resume, "5m", "ci · you · 5m ago · resumes claude"),
    (.manual, .you, .notify, "2h", "manual · you · 2h ago · moves to Needs you"),
    (.manual, .claude, .notify, "2h", "manual · claude · 2h ago · moves to Needs you"),
    (.date, .claude, .notify, "40s", "date · claude · 40s ago · moves to Needs you"),
    (.manual, .you, .resume, "3d", "manual · you · 3d ago · resumes claude"),
    (.botReview, .claude, .resume, "1m", "bot-review · claude · 1m ago · resumes claude"),
  ])
  func captionNamesTheKindTheAuthorTheAgeAndTheOutcome(
    _ kind: Wait.Kind, _ by: Author, _ then: Wait.Then, _ age: String, _ caption: String
  ) {
    #expect(waitFixture("w1", kind, by: by, then: then).caption(age: age) == caption)
  }
}

@Suite struct SidePanelTitles {
  @Test(arguments: [0, 1, 2])
  func countsTheOpenWaitsInTheTitle(_ count: Int) {
    let waits = (0..<count).map { waitFixture("w\($0)") }

    #expect(SidePanel(waitingSession(waits)).waitsCount == count)
  }

  @Test func countsNoNoteWhenThereIsNoNote() {
    #expect(SidePanel(notedSession([])).notesCount == 0)
  }

  @Test func countsEveryNoteInTheTitleIncludingResolvedTodos() {
    let notes = [
      todoFixture("o1", "tell Alex in #flags"), noteFixture("p1", "plain"),
      todoFixture("r1", "done already", resolved: true),
    ]

    #expect(SidePanel(notedSession(notes)).notesCount == 3)
  }
}

@Suite struct SidePanelEmptyState {
  @Test func hasNotesForASessionWithANote() {
    #expect(SidePanel(notedSession([noteFixture("p1", "plain")])).hasNotes)
  }

  @Test func hasNoNotesForASessionWithOnlyWaits() {
    #expect(!SidePanel(waitingSession([waitFixture("w1")])).hasNotes)
  }
}

@Suite struct SidePanelDoneCaption {
  static let text = "Waits and schedules don't run on their own while the session is marked Done."

  @Test func saysThatWaitsDontRunOnASessionMarkedDoneWithOnlyAnOpenWait() {
    let panel = SidePanel(waitingSession([waitFixture("w1")], markedDone: true))

    #expect(panel.doneCaption == SidePanelDoneCaption.text)
  }

  @Test func saysNothingWhenTheSessionIsNotMarkedDone() {
    let panel = SidePanel(waitingSession([waitFixture("w1")], markedDone: false))

    #expect(panel.doneCaption == nil)
  }

  @Test func saysNothingWhenASessionMarkedDoneHasNoOpenWait() {
    let panel = SidePanel(waitingSession([], notes: [noteFixture("p1", "plain")], markedDone: true))

    #expect(panel.doneCaption == nil)
  }

  /// A merged PR puts a session in Done without `markedDone`. sbd still resolves the waits of such a session.
  @Test func saysNothingWhenTheSessionIsInDoneWithoutBeingMarkedDone() {
    var session = waitingSession([waitFixture("w1")])
    session.state = .done

    #expect(SidePanel(session).doneCaption == nil)
  }
}

@Suite struct SidePanelFits {
  static let claude = SessionView.claudeMinWidth
  static let shell = SessionView.shellMinWidth
  static let panel = SidePanel.width

  /// The detail pane of the Inbox and the Issues view at its narrowest.
  static let inboxMinimum = ListDetailSplit<EmptyView, EmptyView>.detailMinWidth
  /// The window's minimum width less the sidebar's minimum width.
  static let sessionViewMinimum = ContentView.windowMinWidth - ContentView.sidebarMinWidth

  static func session(shellClosed: Bool? = nil, terminals: Bool = true) -> SessionSummary {
    var s = notedSession([])
    s.shellClosed = shellClosed
    if !terminals { s.cwd = "" }
    return s
  }

  @Test func theTerminalsNeedBothMinimumsWhileTheShellIsOpen() {
    #expect(SessionView.terminalsMinWidth(Self.session()) == Self.claude + Self.shell)
    #expect(SessionView.terminalsMinWidth(Self.session(shellClosed: false)) == Self.claude + Self.shell)
  }

  @Test func theTerminalsNeedOnlyTheClaudeMinimumWhileTheShellIsClosed() {
    #expect(SessionView.terminalsMinWidth(Self.session(shellClosed: true)) == Self.claude)
  }

  @Test(arguments: [nil, true, false] as [Bool?])
  func aSessionWithoutTerminalsNeedsNoWidthForThem(_ shellClosed: Bool?) {
    #expect(SessionView.terminalsMinWidth(Self.session(shellClosed: shellClosed, terminals: false)) == 0)
  }

  @Test(arguments: [nil, true] as [Bool?], [true, false])
  func showsAtTheTerminalsMinimumPlusThePanelAndHidesOnePointBelow(_ shellClosed: Bool?, _ terminals: Bool) {
    let beside = SessionView.terminalsMinWidth(Self.session(shellClosed: shellClosed, terminals: terminals))

    #expect(SidePanel.fits(width: beside + Self.panel, beside: beside))
    #expect(!SidePanel.fits(width: beside + Self.panel - 1, beside: beside))
  }

  @Test(arguments: [nil, true] as [Bool?])
  func hidesInTheInboxsNarrowestTerminalView(_ shellClosed: Bool?) {
    let beside = SessionView.terminalsMinWidth(Self.session(shellClosed: shellClosed))

    #expect(!SidePanel.fits(width: Self.inboxMinimum, beside: beside))
  }

  @Test func hidesInTheNarrowestSessionViewWithTheShellOpen() {
    #expect(!SidePanel.fits(width: Self.sessionViewMinimum, beside: SessionView.terminalsMinWidth(Self.session())))
  }

  @Test func showsInTheNarrowestSessionViewWithTheShellClosed() {
    let beside = SessionView.terminalsMinWidth(Self.session(shellClosed: true))

    #expect(SidePanel.fits(width: Self.sessionViewMinimum, beside: beside))
  }
}

@Suite struct SidePanelSchedules {
  @Test(arguments: [nil, []] as [[Schedule]?])
  func hidesTheSchedulesSectionForASessionWithoutSchedules(_ schedules: [Schedule]?) {
    #expect(!SidePanel(scheduledSession(schedules)).showsSchedules)
  }

  @Test func showsTheSchedulesSectionForASessionWithASchedule() {
    #expect(SidePanel(scheduledSession([scheduleFixture("r1")])).showsSchedules)
  }

  @Test func showsTheSchedulesSectionWhenEveryScheduleIsPaused() {
    #expect(SidePanel(scheduledSession([scheduleFixture("r1", paused: true)])).showsSchedules)
  }

  @Test(arguments: [nil, []] as [[Schedule]?])
  func countsNoScheduleWhenThereIsNoSchedule(_ schedules: [Schedule]?) {
    #expect(SidePanel(scheduledSession(schedules)).schedulesCount == 0)
  }

  @Test(arguments: [1, 2])
  func countsTheSchedulesInTheTitle(_ count: Int) {
    let schedules = (0..<count).map { scheduleFixture("r\($0)") }

    #expect(SidePanel(scheduledSession(schedules)).schedulesCount == count)
  }

  @Test func countsAPausedScheduleInTheTitle() {
    let schedules = [scheduleFixture("r1"), scheduleFixture("r2", paused: true)]

    #expect(SidePanel(scheduledSession(schedules)).schedulesCount == 2)
  }
}

@Suite struct SidePanelDoneCaptionWithSchedules {
  @Test func saysThatSchedulesDontRunOnASessionMarkedDoneWithOnlySchedules() {
    let panel = SidePanel(scheduledSession([scheduleFixture("r1")], markedDone: true))

    #expect(panel.doneCaption == SidePanelDoneCaption.text)
  }

  @Test func saysTheSameOnASessionMarkedDoneWithWaitsAndSchedules() {
    let panel = SidePanel(scheduledSession([scheduleFixture("r1")], waits: [waitFixture("w1")], markedDone: true))

    #expect(panel.doneCaption == SidePanelDoneCaption.text)
  }

  @Test func saysNothingWhenASessionWithSchedulesIsNotMarkedDone() {
    let panel = SidePanel(scheduledSession([scheduleFixture("r1")], markedDone: false))

    #expect(panel.doneCaption == nil)
  }

  @Test func saysNothingWhenASessionMarkedDoneHasAnEmptyScheduleList() {
    let panel = SidePanel(scheduledSession([], markedDone: true))

    #expect(panel.doneCaption == nil)
  }

  /// A merged PR puts a session in Done without `markedDone`. sbd still runs the schedules of such a session.
  @Test func saysNothingWhenASessionWithSchedulesIsInDoneWithoutBeingMarkedDone() {
    var session = scheduledSession([scheduleFixture("r1")])
    session.state = .done

    #expect(SidePanel(session).doneCaption == nil)
  }
}

@Suite struct SidePanelTests {
  static let now: Int64 = 1_800_000_000_000
  static let minute: Int64 = 60_000
  static let hour: Int64 = 60 * minute

  static func session(_ artifacts: [SessionArtifact]?) -> SessionSummary {
    var s = notedSession([])
    s.artifacts = artifacts
    return s
  }

  @Test func countsNoArtifactWhenThereIsNoArtifact() {
    #expect(SidePanel(Self.session(nil)).artifactsCount == 0)
  }

  @Test func countsOnlyTheArtifactsThatAreNotRemovedInTheTitle() {
    let artifacts = [artifactFixture("a"), artifactFixture("b", removed: 5), artifactFixture("c")]

    #expect(SidePanel(Self.session(artifacts)).artifactsCount == 2)
  }

  @Test func countsNoArtifactWhenEveryArtifactIsRemoved() {
    let artifacts = [artifactFixture("a", removed: 5), artifactFixture("b", removed: 6)]

    #expect(SidePanel(Self.session(artifacts)).artifactsCount == 0)
  }

  @Test func hasNoArtifactsForASessionWithoutAnArtifact() {
    #expect(!SidePanel(Self.session(nil)).hasArtifacts)
  }

  /// Removed artifacts still show as rows, so the empty text stays hidden.
  @Test func hasArtifactsWhenEveryArtifactIsRemoved() {
    #expect(SidePanel(Self.session([artifactFixture("a", removed: 5)])).hasArtifacts)
  }

  @Test func theEmptyTextSaysThereAreNoArtifacts() {
    #expect(SidePanel.noArtifacts == "No artifacts.")
  }

  /// sbd lists a session's artifacts in first-publish order. The panel shows the newest update first.
  @Test func sortsTheArtifactsByTheirLastUpdateNewestFirst() {
    let artifacts = [
      artifactFixture("a", published: 1, updated: 1),
      artifactFixture("b", published: 2, updated: 9),
      artifactFixture("c", published: 3, updated: 5),
    ]

    #expect(SidePanel(Self.session(artifacts)).artifacts.map(\.title) == ["b", "c", "a"])
  }

  /// Equal updates sort by URL, the order that sbd gives a group's list.
  @Test func sortsArtifactsWithTheSameUpdateByTheirLink() {
    let artifacts = [artifactFixture("b", updated: 5), artifactFixture("a", updated: 5)]

    #expect(SidePanel(Self.session(artifacts)).artifacts.map(\.title) == ["a", "b"])
  }

  @Test func listsNoArtifactsForASessionWithoutAnArtifact() {
    #expect(SidePanel(Self.session(nil)).artifacts.isEmpty)
  }

  @Test func captionSaysWhenALiveArtifactWasLastUpdated() {
    let artifact = artifactFixture("a", published: Self.now - Self.hour, updated: Self.now - 5 * Self.minute)

    #expect(artifact.caption(now: Self.now) == "updated 5m ago")
  }

  @Test func captionSaysWhenARemovedArtifactWasRemoved() {
    let artifact = artifactFixture(
      "a", published: Self.now - 3 * Self.hour, updated: Self.now - 2 * Self.hour, removed: Self.now - 5 * Self.minute)

    #expect(artifact.caption(now: Self.now) == "removed 5m ago")
  }
}

extension SidePanelTests {
  @Suite struct Links {
    static func session(_ links: [ExternalLink]?) -> SessionSummary {
      var s = notedSession([], id: "s1")
      s.links = links
      return s
    }

    static func link(_ id: String, t: Int64) -> ExternalLink {
      ExternalLink(id: id, title: "Link \(id)", url: "https://example.com/\(id)", by: .you, t: t)
    }

    @Test(arguments: [nil, []] as [[ExternalLink]?])
    func countsNoLinkWhenThereIsNoLink(_ links: [ExternalLink]?) {
      #expect(SidePanel(Self.session(links)).links.count == 0)
    }

    @Test(arguments: [1, 2])
    func countsTheLinksInTheTitle(_ count: Int) {
      let links = (0..<count).map { Self.link("l\($0)", t: Int64($0)) }

      #expect(SidePanel(Self.session(links)).links.count == count)
    }

    @Test func theEmptyTextSaysThereAreNoLinks() {
      #expect(SidePanel.noLinks == "No links.")
    }

    /// sbd lists a session's links oldest first. The panel shows the newest first, with ids that hold the session.
    @Test func listsTheSessionsLinkRowsNewestFirst() {
      let links = [Self.link("l1", t: 1), Self.link("l2", t: 3), Self.link("l3", t: 2)]

      #expect(SidePanel(Self.session(links)).links.map(\.id) == ["s1/l2", "s1/l3", "s1/l1"])
    }
  }
}
