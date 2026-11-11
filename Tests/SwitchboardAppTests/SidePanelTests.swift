import AppKit
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
  @Test func listsTheWaitsInTheSummarysOrder() {
    let waits = [
      waitFixture("w3", .merge, pr: 1190, created: 300),
      waitFixture("w1", .ci, pr: 1204, created: 100),
      waitFixture("w2", .manual, note: "ask Alex", created: 200),
    ]

    let panel = SidePanel(waitingSession(waits))

    #expect(panel.waits.map(\.id) == ["w3", "w1", "w2"])
  }

  @Test func carriesEachWaitsCreationTime() {
    let panel = SidePanel(waitingSession([waitFixture("w1", created: 100), waitFixture("w2", created: 200)]))

    #expect(panel.waits.map(\.created) == [100, 200])
  }

  @Test func showsTheReasonLinesTextForAWait() throws {
    let wait = waitFixture("w1", .ci, pr: 1204, note: "merge when green")

    let row = try #require(SidePanel(waitingSession([wait])).waits.first)

    #expect(row.text == wait.line)
  }

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
  ) throws {
    let wait = waitFixture("w1", kind, by: by, then: then)

    let row = try #require(SidePanel(waitingSession([wait])).waits.first)

    #expect(row.caption(age: age) == caption)
  }
}

@Suite struct SidePanelTitles {
  @Test(arguments: [(0, "Waits"), (1, "Waits (1)"), (2, "Waits (2)")])
  func countsTheOpenWaitsInTheTitleAboveZero(_ count: Int, _ title: String) {
    let waits = (0..<count).map { waitFixture("w\($0)") }

    #expect(SidePanel(waitingSession(waits)).waitsTitle == title)
  }

  @Test func titlesTheNotesSectionWithoutACountWhenThereIsNoNote() {
    #expect(SidePanel(notedSession([])).notesTitle == "Notes")
  }

  @Test func countsEveryNoteInTheTitleIncludingResolvedTodos() {
    let notes = [
      todoFixture("o1", "tell Alex in #flags"), noteFixture("p1", "plain"),
      todoFixture("r1", "done already", resolved: true),
    ]

    #expect(SidePanel(notedSession(notes)).notesTitle == "Notes (3)")
  }
}

@Suite struct SidePanelEmptyState {
  @Test func hasNoWaitRowsForASessionWithOnlyNotes() {
    let panel = SidePanel(notedSession([noteFixture("p1", "plain")]))

    #expect(panel.waits.isEmpty)
    #expect(panel.hasNotes)
  }

  @Test func hasNoNotesForASessionWithOnlyWaits() {
    let panel = SidePanel(waitingSession([waitFixture("w1")]))

    #expect(!panel.waits.isEmpty)
    #expect(!panel.hasNotes)
  }
}

@Suite struct SidePanelDoneNote {
  static let text = "Waits don't resolve while the session is marked Done."

  @Test func saysThatWaitsDontResolveOnASessionMarkedDoneWithAnOpenWait() {
    let panel = SidePanel(waitingSession([waitFixture("w1")], markedDone: true))

    #expect(panel.doneNote == SidePanelDoneNote.text)
  }

  @Test func saysNothingWhenTheSessionIsNotMarkedDone() {
    let panel = SidePanel(waitingSession([waitFixture("w1")], markedDone: false))

    #expect(panel.doneNote == nil)
  }

  @Test func saysNothingWhenASessionMarkedDoneHasNoOpenWait() {
    let panel = SidePanel(waitingSession([], notes: [noteFixture("p1", "plain")], markedDone: true))

    #expect(panel.doneNote == nil)
  }

  /// A merged PR puts a session in Done without `markedDone`. sbd still resolves the waits of such a session.
  @Test func saysNothingWhenTheSessionIsInDoneWithoutBeingMarkedDone() {
    var session = waitingSession([waitFixture("w1")])
    session.state = .done

    #expect(SidePanel(session).doneNote == nil)
  }
}

@Suite struct SidePanelFits {
  static let claude = SessionView.claudeMinWidth
  static let shell = SessionView.shellMinWidth
  static let panel = SidePanel.width

  /// The Inbox's detail pane at its narrowest.
  static let inboxMinimum: CGFloat = 340
  /// The window's minimum width less the sidebar's minimum width.
  static let sessionViewMinimum: CGFloat = 900 - 240

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
