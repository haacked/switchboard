import AppKit
import SwiftUI
import SwitchboardCore
import Testing

@testable import SwitchboardApp

private let toolStep = TranscriptStep(kind: .tool, tool: "Bash", summary: "`touch x`", id: "c1")

private func itemContext(
  ref: String?, anchor: ItemContext.Anchor = .tool, anchored: Bool = true, more: Bool = false,
  steps: [TranscriptStep] = [TranscriptStep(kind: .text, text: "I'll touch x."), toolStep]
) -> ItemContext {
  ItemContext(session: "s1", ref: ref, anchor: anchor, anchored: anchored, more: more, steps: steps)
}

private let bashCall = TriageDetails.ToolInput(tool: "Bash", text: "touch x")

/// A session with an open PR and one wait, or without either.
private func workSession(withPRAndWait has: Bool = true) -> SessionSummary {
  var s = needsItem("s1")
  if has {
    s.pr = PRSummary(
      PullRequest(id: "PR_a", number: 1, url: "https://github.com/acme/widgets/pull/1", repo: "acme/widgets"))
    s.waits = [Wait(id: "w1", kind: .ci, created: 0)]
  }
  return s
}

/// A follow-up that has started, so it has a folder and a claude like any work session.
private func startedFollowup(_ id: String) -> SessionSummary {
  var s = needsItem(id)
  s.followup = Followup(prompt: "p")
  s.followup?.started = 1
  return s
}

@MainActor
@Suite struct CardDetailsTests {
  // MARK: Show more

  @Test(arguments: [(5, 15), (15, 30), (30, 60), (60, 90), (90, 120), (120, 150), (150, 180), (180, 200), (200, 200)])
  func showMoreAsksForTheNextStepCount(_ steps: Int, _ next: Int) {
    #expect(CardDetails.nextSteps(after: steps) == next)
  }

  @Test func showMoreFromTheFirstCountClimbsToTheLimitAndStops() {
    var counts = [5]
    while counts.count < 20, counts.last != CardDetails.nextSteps(after: counts.last!) {
      counts.append(CardDetails.nextSteps(after: counts.last!))
    }

    #expect(counts == [5, 15, 30, 60, 90, 120, 150, 180, 200])
  }

  // MARK: Open in transcript

  @Test(arguments: ["c", "m", "op"])
  func aConversationOpensItsOwnSessionView(_ id: String) throws {
    #expect(try everyKindSession(id).transcriptTarget == .session)
  }

  @Test func aWorkSessionThatRunsClaudeOpensItsTerminal() {
    #expect(needsItem("a").transcriptTarget == .terminal)
  }

  @Test func aStartedFollowupOpensItsTerminal() {
    #expect(startedFollowup("f").transcriptTarget == .terminal)
  }

  /// A session without a terminal has nothing to open, so the button hides.
  @Test func anUnstartedFollowupHasNoTranscriptToOpen() {
    #expect(unstartedFollowup("f").transcriptTarget == nil)
  }

  @Test func aDocketRowHasNoTranscriptToOpen() {
    #expect(docketSession("d").transcriptTarget == nil)
  }

  // MARK: The item's own context

  @Test func aContextForTheItemsRefShows() {
    let context = itemContext(ref: "card:1")

    #expect(CardDetails.context(for: "card:1", in: context) == context)
  }

  /// A context read for the session's previous item must not show under the new one.
  @Test(arguments: ["card:2", "stop:1", "summary:1", ""])
  func aContextForAnotherRefIsIgnored(_ ref: String) {
    #expect(CardDetails.context(for: ref, in: itemContext(ref: "card:1")) == nil)
  }

  @Test func aContextOfASessionWithoutAnItemIsIgnored() {
    #expect(CardDetails.context(for: "card:1", in: itemContext(ref: nil, anchor: .end)) == nil)
  }

  @Test func noLoadedContextShowsNone() {
    #expect(CardDetails.context(for: "card:1", in: nil) == nil)
  }

  // MARK: Unanchored is visible

  @Test func anAnchoredContextHasNoCaption() {
    #expect(itemContext(ref: "card:1").caption == nil)
  }

  @Test func anAnchoredContextMarksItsLastStep() {
    #expect(itemContext(ref: "card:1").anchorIndex == 1)
  }

  /// A mark on the newest step of an unanchored context would point at a step that the item did not come from.
  @Test func anUnanchoredContextMarksNoStep() {
    #expect(itemContext(ref: "card:1", anchored: false).anchorIndex == nil)
  }

  @Test func aContextWithoutStepsMarksNoStep() {
    #expect(itemContext(ref: "card:1", steps: []).anchorIndex == nil)
  }

  @Test func aContextOfAnItemThatDidNotComeFromTheConversationSaysSo() {
    let context = itemContext(ref: "rule:Wait for CI", anchor: .unanchored, anchored: false)

    #expect(context.caption == "This item didn't come from the conversation.")
  }

  /// A silent fallback to the newest steps would bring back the bug that #302 describes.
  @Test(arguments: [ItemContext.Anchor.tool, .reply, .end])
  func aContextWhoseAnchorWasNotFoundSaysItIsNotTiedToTheItem(_ anchor: ItemContext.Anchor) {
    let context = itemContext(ref: "card:1", anchor: anchor, anchored: false)

    #expect(
      context.caption
        == "Not tied to this item: Switchboard couldn't find where it came from in the transcript.")
  }

  // MARK: The Last reply fallback (parity with today)

  /// Without loaded steps, Details shows "Last reply" exactly as before the context existed.
  @Test func withoutAContextTheLastReplyShows() {
    #expect(CardDetails.lastReply(context: nil, reply: "Ship it?") == "Ship it?")
  }

  @Test func aContextWithoutStepsShowsTheLastReply() {
    let context = itemContext(ref: "card:1", anchored: false, steps: [])

    #expect(CardDetails.lastReply(context: context, reply: "Ship it?") == "Ship it?")
  }

  /// The anchor message takes the place of "Last reply".
  @Test(arguments: [true, false])
  func aContextWithStepsHidesTheLastReply(_ anchored: Bool) {
    let context = itemContext(ref: "card:1", anchored: anchored)

    #expect(CardDetails.lastReply(context: context, reply: "Ship it?") == nil)
  }

  /// Today's section shows only a reply with text.
  @Test(arguments: [nil, ""] as [String?])
  func withoutAContextAnEmptyOrMissingReplyShowsNothing(_ reply: String?) {
    #expect(CardDetails.lastReply(context: nil, reply: reply) == nil)
  }

  /// The view passes the context for the item's ref, so another item's steps leave "Last reply" in place.
  @Test func aContextForAnotherItemLeavesTheLastReply() {
    let loaded = itemContext(ref: "card:1")

    let shown = CardDetails.lastReply(context: CardDetails.context(for: "card:2", in: loaded), reply: "Ship it?")

    #expect(shown == "Ship it?")
  }

  // MARK: The parts and their order

  /// The transcript and the last reply never show together, so two lists pin the whole order.
  @Test func everyPartWithLoadedStepsKeepsTodaysOrder() {
    let parts = CardDetails.parts(
      details: TriageDetails(toolInput: bashCall, targets: ["b (s2)"]), callouts: [Callout(kind: .info, title: "i")],
      context: itemContext(ref: "card:1"), reply: "Ship it?", session: workSession(), showsRecentEvents: true)

    #expect(parts == [.toolInput, .targets, .callouts, .transcript, .pullRequest, .waits, .recentEvents])
  }

  @Test func everyPartWithoutLoadedStepsKeepsTodaysOrder() {
    let parts = CardDetails.parts(
      details: TriageDetails(toolInput: bashCall, targets: ["b (s2)"]), callouts: [Callout(kind: .info, title: "i")],
      context: nil, reply: "Ship it?", session: workSession(), showsRecentEvents: true)

    #expect(parts == [.toolInput, .targets, .callouts, .pullRequest, .waits, .lastReply, .recentEvents])
  }

  @Test func aPermissionCardShowsItsCallThenItsTranscript() {
    let parts = CardDetails.parts(
      details: TriageDetails(openByDefault: true, toolInput: bashCall), callouts: [],
      context: itemContext(ref: "card:1"), reply: "Ship it?", session: workSession(withPRAndWait: false),
      showsRecentEvents: false)

    #expect(parts == [.toolInput, .transcript])
  }

  @Test func anAnchoredReplyShowsItsTranscriptAndNoLastReply() {
    let context = itemContext(ref: "stop:1", anchor: .reply)

    let parts = CardDetails.parts(
      details: TriageDetails(), callouts: [], context: context, reply: "Ship it?",
      session: workSession(withPRAndWait: false), showsRecentEvents: false)

    #expect(parts == [.transcript])
  }

  // MARK: Unanchored steps collapse

  /// The newest steps of a wait, rule, or report item can be about anything, so they go last behind a closed group.
  @Test func anUnanchoredRuleItemShowsItsStepsLastInAClosedGroup() {
    let context = itemContext(ref: "rule:Wait for CI", anchor: .unanchored, anchored: false)

    let parts = CardDetails.parts(
      details: TriageDetails(), callouts: [], context: context, reply: "Ship it?", session: workSession(),
      showsRecentEvents: false)

    #expect(parts == [.pullRequest, .waits, .latestSteps])
  }

  @Test(arguments: ["rule:CI on #1: still open after 3h", "report:7", "rule:Delete failed"])
  func everyUnanchoredItemCollapsesItsSteps(_ ref: String) {
    let context = itemContext(ref: ref, anchor: .unanchored, anchored: false)

    let parts = CardDetails.parts(
      details: TriageDetails(), callouts: [Callout(kind: .info, title: "i")], context: context, reply: "Ship it?",
      session: workSession(withPRAndWait: false), showsRecentEvents: false)

    #expect(parts == [.callouts, .latestSteps])
  }

  /// "Last" is after every other part, the debug list of recent events included.
  @Test func theClosedStepsComeAfterTheRecentEvents() {
    let context = itemContext(ref: "rule:Wait for CI", anchor: .unanchored, anchored: false)

    let parts = CardDetails.parts(
      details: TriageDetails(), callouts: [], context: context, reply: "Ship it?", session: workSession(),
      showsRecentEvents: true)

    #expect(parts == [.pullRequest, .waits, .recentEvents, .latestSteps])
  }

  /// A context whose anchor sbd could not find keeps its steps in today's place, open, with its own caption.
  @Test(arguments: [ItemContext.Anchor.tool, .reply, .end])
  func aContextWhoseAnchorWasNotFoundKeepsItsStepsInPlace(_ anchor: ItemContext.Anchor) {
    let context = itemContext(ref: "card:1", anchor: anchor, anchored: false)

    let parts = CardDetails.parts(
      details: TriageDetails(), callouts: [], context: context, reply: "Ship it?", session: workSession(),
      showsRecentEvents: false)

    #expect(parts == [.transcript, .pullRequest, .waits])
  }

  @Test func anUnanchoredContextWithoutStepsShowsTheLastReply() {
    let context = itemContext(ref: "rule:Wait for CI", anchor: .unanchored, anchored: false, steps: [])

    let parts = CardDetails.parts(
      details: TriageDetails(), callouts: [], context: context, reply: "Ship it?",
      session: workSession(withPRAndWait: false), showsRecentEvents: false)

    #expect(parts == [.lastReply])
  }

  @Test func theClosedStepsAreTitledLatestStepsInTheConversation() {
    #expect(CardDetails.latestStepsTitle == "Latest steps in the conversation")
  }

  @Test func aMissingContextShowsTheLastReply() {
    let parts = CardDetails.parts(
      details: TriageDetails(), callouts: [], context: nil, reply: "Ship it?",
      session: workSession(withPRAndWait: false),
      showsRecentEvents: false)

    #expect(parts == [.lastReply])
  }

  @Test func aContextWithoutStepsShowsTheLastReplyAndNoTranscript() {
    let context = itemContext(ref: "card:1", anchored: false, steps: [])

    let parts = CardDetails.parts(
      details: TriageDetails(), callouts: [], context: context, reply: "Ship it?",
      session: workSession(withPRAndWait: false), showsRecentEvents: false)

    #expect(parts == [.lastReply])
  }

  @Test(arguments: [nil, ""] as [String?])
  func anEmptyOrMissingReplyAddsNoLastReply(_ reply: String?) {
    let parts = CardDetails.parts(
      details: TriageDetails(), callouts: [], context: nil, reply: reply, session: workSession(withPRAndWait: false),
      showsRecentEvents: false)

    #expect(parts.isEmpty)
  }

  /// A message to a group names its targets after the message, with no transcript of its own steps yet.
  @Test func aGroupMessageShowsItsMessageThenItsTargets() {
    let parts = CardDetails.parts(
      details: TriageDetails(openByDefault: true, toolInput: bashCall, targets: ["b (s2)", "c (s3)"]), callouts: [],
      context: nil, reply: nil, session: workSession(withPRAndWait: false), showsRecentEvents: false)

    #expect(parts == [.toolInput, .targets])
  }

  /// Core's `TriageDetails.parts` reads the item's own PR, waits, and notes. Details reads the session's.
  @Test func thePRAndWaitsComeFromTheSessionNotTheItemsDetails() {
    let details = TriageDetails(
      pullRequest: TriageDetails.PR(line: "#1", title: "t", url: "https://github.com/acme/widgets/pull/1"),
      waits: ["ci on #1"], notes: ["a note"])

    let parts = CardDetails.parts(
      details: details, callouts: [], context: nil, reply: nil, session: workSession(withPRAndWait: false),
      showsRecentEvents: false)

    #expect(parts.isEmpty)
  }

  @Test func theSessionsPRAndWaitsShowWithEmptyDetails() {
    let parts = CardDetails.parts(
      details: TriageDetails(), callouts: [], context: nil, reply: nil, session: workSession(),
      showsRecentEvents: false)

    #expect(parts == [.pullRequest, .waits])
  }

  /// The caller passes true only when the setting is on and the events have loaded.
  @Test(arguments: [true, false])
  func recentEventsShowLastOnlyWhenAsked(_ shows: Bool) {
    let parts = CardDetails.parts(
      details: TriageDetails(), callouts: [], context: nil, reply: "Ship it?",
      session: workSession(withPRAndWait: false),
      showsRecentEvents: shows)

    let expected: [CardDetails.Part] = shows ? [.lastReply, .recentEvents] : [.lastReply]
    #expect(parts == expected)
  }
}

@MainActor
@Suite struct CardDetailsModelTests {
  @Test func loadItemContextAsksForTheSessionsStepsWithTheCount() async {
    let sent = await firstRequest { $0.loadItemContext("s1", steps: 15) }

    #expect(sent.op == "item-context")
    #expect(sent.args == ["session": "s1", "steps": 15])
  }

  @Test func loadItemContextStoresTheAnswerBySession() async throws {
    let model = offlineModel()
    let answer = try JSON(encoding: itemContext(ref: "card:1"))
    model.send = { _, _ in answer }

    model.loadItemContext("s1", steps: 5)
    await settle { model.itemContexts["s1"] != nil }

    #expect(model.itemContexts["s1"] == itemContext(ref: "card:1"))
  }

  /// An older sbd answers "unknown op". Details then shows "Last reply".
  @Test func aFailedReadStoresNothing() async {
    let model = offlineModel()
    let old = itemContext(ref: "card:1")
    model.itemContexts["s1"] = old
    let sent = Counter()
    model.send = { _, _ in
      sent.increment()
      throw Refusal(description: "unknown op item-context")
    }

    model.loadItemContext("s1", steps: 5)
    await settle { sent.value == 1 }
    try? await Task.sleep(nanoseconds: 200_000_000)

    #expect(model.itemContexts["s1"] == old)
    #expect(model.itemContexts.count == 1)
  }

  // MARK: Open in transcript

  /// The Terminal toggle belongs to the Inbox, so opening a conversation leaves it as it was.
  @Test(arguments: ["c", "m", "op"], [false, true])
  func openingAConversationsTranscriptSelectsIt(_ id: String, _ toggle: Bool) throws {
    let conversation = try everyKindSession(id)
    let model = appliedModel([conversation, needsItem("a")])
    model.show(.inbox)
    model.showingTerminal = toggle

    model.openTranscript(conversation)

    #expect(model.selection == id)
    #expect(model.showingTerminal == toggle)
  }

  @Test func openingAWorkSessionsTranscriptShowsItsTerminalInTheInbox() throws {
    let work = needsItem("a")
    let model = appliedModel([work, needsItem("other")])
    model.show(.inbox)
    model.inboxFocus = "a"
    model.showingTerminal = false
    try #require(model.currentInboxItem == "a")

    model.openTranscript(work)

    #expect(model.showingTerminal)
    #expect(model.terminalFocus == "a")
    #expect(model.visibleView == .inbox)
  }

  @Test func openingTheTranscriptOfASessionWithoutATerminalChangesNothing() throws {
    let followup = unstartedFollowup("f")
    let model = appliedModel([followup, needsItem("a")])
    model.show(.inbox)
    model.showingTerminal = false

    model.openTranscript(followup)

    #expect(model.selection == nil)
    #expect(!model.showingTerminal)
    #expect(model.terminalFocus == nil)
  }
}

/// `count` text steps of one short paragraph each.
private func textSteps(_ count: Int) -> [TranscriptStep] {
  (0..<count).map {
    TranscriptStep(kind: .text, text: "Step \($0): I read the file. Then I ran the tests and they passed.")
  }
}

/// `count` numbered lines.
private func lines(_ count: Int) -> String {
  (1...count).map { "line \($0)" }.joined(separator: "\n")
}

/// `count` Markdown list items. Each item is its own row in `MarkdownView`. Lines without a blank line between them
/// would join into one paragraph.
private func listItems(_ count: Int) -> String {
  (1...count).map { "- item \($0)" }.joined(separator: "\n")
}

/// An ExitPlanMode call whose plan is `plan`.
private func planInput(_ plan: String) -> TriageDetails.ToolInput {
  .init(tool: "ExitPlanMode", text: JSON.object(["plan": .string(plan)]).prettyText)
}

/// The height that `view` takes at `width`, hosted in a window that is never shown. The window is tall, so its
/// height can't be what stops a view from growing.
@MainActor
private func fittingHeight<V: View>(_ view: V, width: CGFloat = 500) -> CGFloat {
  _ = NSApplication.shared
  let host = NSHostingView(
    rootView: view.frame(width: width, alignment: .topLeading).fixedSize(horizontal: false, vertical: true))
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: width, height: 10_000), styleMask: [.titled], backing: .buffered,
    defer: false)
  window.isReleasedWhenClosed = false
  window.contentView = host
  host.layoutSubtreeIfNeeded()
  return withExtendedLifetime(window) { host.fittingSize.height }
}

/// `view` as the Inbox's detail pane holds it, with the pane's scroll proxy in the environment.
private func inDetailPane(_ view: some View) -> some View {
  ScrollViewReader { view.environment(\.detailScroll, $0) }
}

private let toolInputs: [TriageDetails.ToolInput?] = [nil, .init(tool: "Bash", text: "touch x")]

/// Details takes the height its content needs, so the Inbox's own scroll view is the only one on the card.
@MainActor
@Suite struct CardDetailsHeightTests {
  private let ref = "card:1"

  /// The height of an open Details whose loaded context has `count` steps.
  private func detailsHeight(steps count: Int, toolInput: TriageDetails.ToolInput? = nil) -> CGFloat {
    let model = offlineModel()
    // The load that Details starts on appear fails. A failed read leaves the context below in place.
    model.send = { _, _ in throw Refusal(description: "unknown op item-context") }
    let session = needsItem("s1")
    model.itemContexts[session.id] = itemContext(ref: ref, steps: textSteps(count))
    let details = TriageDetails(openByDefault: true, toolInput: toolInput)
    return fittingHeight(
      inDetailPane(CardDetails(session: session, ref: ref, details: details)).environmentObject(model))
  }

  /// The steps list has no height cap. A cap of 260 pt without a tool input, or 160 pt under one, held 40 and 80
  /// steps to one height. 1 against 40 is the control: when it fails, Details did not open or the steps did not show.
  @Test(arguments: toolInputs)
  func detailsGrowsWithEveryStep(_ toolInput: TriageDetails.ToolInput?) {
    let heights = [1, 40, 80].map { detailsHeight(steps: $0, toolInput: toolInput) }

    #expect(heights[0] < heights[1])
    #expect(heights[1] < heights[2])
  }

  /// The tool call box in Details has no height cap either. It scrolled past 200 pt.
  @Test func detailsGrowsWithTheToolInputsText() {
    let short = TriageDetails.ToolInput(tool: "Bash", text: lines(100))
    let long = TriageDetails.ToolInput(tool: "Bash", text: lines(200))

    #expect(detailsHeight(steps: 1, toolInput: long) > detailsHeight(steps: 1, toolInput: short))
  }

  /// A plan drawn as Markdown grows in Details the same way.
  @Test func detailsGrowsWithThePlansMarkdown() {
    let short = planInput(listItems(10))
    let long = planInput(listItems(20))

    #expect(detailsHeight(steps: 1, toolInput: long) > detailsHeight(steps: 1, toolInput: short))
  }

  // MARK: Text box

  /// In the Inbox's detail pane a box grows with its text instead of scrolling.
  @Test func aTextBoxInTheDetailPaneGrowsWithItsText() {
    #expect(
      fittingHeight(inDetailPane(CardView.textBox(lines(200), maxHeight: 200)))
        > fittingHeight(inDetailPane(CardView.textBox(lines(100), maxHeight: 200))))
  }

  /// Outside the pane, as in a session's card list, a box stops at its maximum height and scrolls the rest.
  @Test func aTextBoxOutsideTheDetailPaneStopsAtItsMaximumHeight() {
    let long = fittingHeight(CardView.textBox(lines(200), maxHeight: 200))

    #expect(long == fittingHeight(CardView.textBox(lines(100), maxHeight: 200)))
    #expect(long > 200 && long < 240)
  }

  /// A plan drawn as Markdown on a permission card stops at the same kind of maximum height.
  @Test func aPlanBoxOutsideTheDetailPaneStopsAtItsMaximumHeight() {
    let long = fittingHeight(ToolInputBox(text: "{}", markdown: listItems(40), maxHeight: 160))

    #expect(long == fittingHeight(ToolInputBox(text: "{}", markdown: listItems(20), maxHeight: 160)))
    #expect(long > 160 && long < 240)
  }

  // MARK: Pane

  /// The pane that TriageDetail draws puts its scroll proxy in the environment, which drops the caps above. Outside
  /// it is the control: when it fails, the probe was never drawn.
  @Test func theDetailPaneGivesItsContentTheScrollProxy() {
    let inside = DetailScrollProbe.Seen()
    let outside = DetailScrollProbe.Seen()
    _ = fittingHeight(DetailPane { DetailScrollProbe(seen: inside) })
    _ = fittingHeight(DetailScrollProbe(seen: outside))

    #expect(inside.proxy == true)
    #expect(outside.proxy == false)
  }
}

/// Records whether the environment held the detail pane's scroll proxy when SwiftUI drew the probe.
private struct DetailScrollProbe: View {
  final class Seen {
    /// Nil until SwiftUI draws the probe.
    var proxy: Bool?
  }

  @Environment(\.detailScroll) private var detailScroll
  let seen: Seen

  var body: some View {
    seen.proxy = detailScroll != nil
    return Color.clear.frame(height: 1)
  }
}
