import SwiftUI
import SwitchboardCore

/// The Inbox message of a session, in sections that never change their
/// order: the Summary (what it did and needs, and what to read before
/// deciding), the Drafts when the session wrote a message for the user to
/// send, the Details (behind a disclosure), and the Action (the buttons).
/// An item with decisions shows them one step at a time in its Action. Its
/// Summary shrinks to its first line, and its callouts move into Details.
/// The step view owns ⌘⇧Return.
struct DecisionCard: View {
  @EnvironmentObject var model: BoardModel
  let session: SessionSummary
  let item: TriageItem
  @Binding var step: DecisionStep?

  static let rowSpacing: CGFloat = 14

  var body: some View {
    let list = session.stepList
    VStack(alignment: .leading, spacing: Self.rowSpacing) {
      header
      VStack(alignment: .leading, spacing: 8) {
        SectionTitle(text: "Summary")
        if list != nil {
          if let line = item.summary.split(separator: "\n").first { summary(String(line)) }
        } else if Self.splitsSummary(item) {
          SummaryCalloutColumns {
            summary(item.summary)
            callouts
          }
        } else {
          if !item.summary.isEmpty { summary(item.summary) }
          if !item.callouts.isEmpty { callouts }
        }
      }
      if !item.drafts.isEmpty { DraftsSection(session: session, item: item) }
      // A new item starts with its own open or closed Details.
      CardDetails(session: session, ref: item.ref, details: item.details, callouts: list == nil ? [] : item.callouts)
        .id(item.ref)
      VStack(alignment: .leading, spacing: 8) {
        SectionTitle(text: "Action")
        if let list {
          DecisionStepView(session: session, list: list, step: $step).id(list.ref)
        } else if session.decisionsSent == true, session.decisionsDelivery == .unknown {
          ResendDecisions(session: session)
        } else if session.decisionsSent == true {
          Text("Sent your answers. The session gets them as its next prompt.").foregroundStyle(.secondary)
        }
        actions
      }
    }
  }

  /// Whether the card shows its summary and its callouts as two columns
  /// when it is wide enough. A card without either one keeps a single stack.
  static func splitsSummary(_ item: TriageItem) -> Bool {
    !item.summary.isEmpty && !item.callouts.isEmpty
  }

  /// Whether the Action says that the item has no summary: a fallback item
  /// with no options whose reply gave no closing section.
  static func showsMissingSummary(_ item: TriageItem) -> Bool {
    item.source == .fallback && item.summary.isEmpty && item.options.isEmpty
  }

  private func summary(_ text: String) -> some View {
    MarkdownView(text: text)
  }

  private var callouts: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(Array(item.callouts.enumerated()), id: \.offset) { CalloutView(callout: $1) }
    }
  }

  private var header: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(item.title).font(.title3.bold()).textSelection(.enabled)
      Text(item.kind.rawValue).font(.caption.bold()).padding(.horizontal, 6).padding(.vertical, 2)
        .background(Capsule().fill(session.state.color.opacity(0.18)))
        .foregroundStyle(session.state.color)
        .accessibilityLabel("Kind: \(item.kind.rawValue)")
      NotesButton(session: session)
    }
  }

  @ViewBuilder
  private var actions: some View {
    if session.canMerge {
      MergeBatch(sessions: session.readyToMergeSessions(all: model.sessions))
    }
    if item.source == .card {
      // Every other card shows its whole tool call, which an approval needs to see.
      let inbox = Card.inbox(session, all: model.sessions)
      // A chat's item can be a later card than a group message, so the item's card leads.
      let own = { (card: Card) in card.session == session.id && card.ref == item.ref }
      let cards = inbox.filter(own) + inbox.filter { !own($0) }
      GroupMessageBatch(cards: cards.filter { $0.kind == .send })
      // Details holds the call and message text of the item's own card only.
      ForEach(cards) {
        CardView(card: $0, draft: model.draft(for: $0), compact: own($0), offersTerminal: true)
      }
    } else if !item.options.isEmpty {
      OptionList(session: session, item: item, takesShortcut: !item.hasDecisionList)
    } else if session.openPrompt {
      // A message would only queue behind the open dialog. The Summary says why the prompt has no card.
      OpenTerminalButton().disabled(!session.runsClaude)
    } else if Self.showsMissingSummary(item) {
      Text("No summary yet. Details shows the reply.").font(.caption).foregroundStyle(.secondary)
    }
    // A Ready to merge card offers Acknowledge as one of its options.
    if session.state != .readyToMerge {
      AcknowledgeButton(session: session, primary: session.isInformational, boxed: true)
    }
  }
}

/// What a decisions card shows when sbd can't tell whether the session got the answers.
struct ResendDecisions: View {
  @EnvironmentObject var model: BoardModel
  let session: SessionSummary

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(
        "sbd restarted while it was sending your answers, so it can't tell whether the session got them."
      )
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      RefusalLabel(refusal: model.decisionErrors[session.id])
      Button("Send again") { model.resendDecisions(session.id) }
        .disabled(model.deciding.contains("\(session.id)/resend"))
        .accessibilityLabel("Send the answers again")
        .accessibilityHint("Sends the same answers once more. The session may get them twice.")
    }
    .announcesRefusal(model.decisionErrors[session.id])
  }
}

/// Shows the Inbox session's Claude terminal in place of its summary.
struct OpenTerminalButton: View {
  @EnvironmentObject var model: BoardModel

  var body: some View {
    Button("Open Terminal") { model.openInboxTerminal() }
      .help("Show the session's Claude terminal in place of its summary")
  }
}

/// sbd's refusal of the user's last action, in red, or nothing without one.
/// The stack that holds it calls `announcesRefusal`, because a view gets no
/// `onChange` when it first appears.
struct RefusalLabel: View {
  let refusal: String?

  var body: some View {
    if let refusal {
      Label(refusal, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
    }
  }
}

extension View {
  /// Has VoiceOver read each new refusal. A refused action leaves the view as
  /// it was, so VoiceOver would say nothing.
  func announcesRefusal(_ refusal: String?) -> some View {
    onChange(of: refusal) {
      if let refusal { AccessibilityNotification.Announcement(refusal).post() }
    }
  }
}

extension TriageOption {
  /// What VoiceOver reads for the option's button. An option that acts on
  /// the PR also names the PR, because several cards show the same option.
  /// The label starts with the visible text, because Voice Control matches a
  /// spoken name against it.
  func accessibilityLabel(pr: Int?) -> String {
    guard action.needsClick, let pr, label.range(of: "#\(pr)(?![0-9])", options: .regularExpression) == nil else {
      return label
    }
    return action == .merge ? "\(label), merge #\(pr)" : "\(label), #\(pr)"
  }

  /// Whether the option's box shows `effect` under its description. A
  /// session writes the label, so the box shows what a click does unless the
  /// label is the text that a click sends.
  var showsEffect: Bool { action != .send || (message ?? label) != label }

  /// What VoiceOver reads after the label: the option's detail and what a
  /// click does.
  func accessibilityHint(mergeMethod: MergeMethod?) -> String {
    let effect = effect(mergeMethod: mergeMethod)
    guard let detail, !detail.isEmpty else { return effect }
    return detail.last.map(".?!".contains) == true ? "\(detail) \(effect)" : "\(detail). \(effect)"
  }
}

/// Places its two children, the summary and the callouts, side by side when
/// the callout column gets at least `minimumColumn`, and stacks them
/// otherwise. Both columns start at the top, and the taller one sets the
/// height. ViewThatFits measures wrapped text at its one-line width, so it
/// would stack every summary longer than the pane.
struct SummaryCalloutColumns: Layout {
  static let spacing: CGFloat = 16
  static let minimumColumn: CGFloat = 260
  static let summaryShare: CGFloat = 0.55

  /// The column widths for the width the card gets, or nil when the two stack.
  static func widths(for width: CGFloat) -> (summary: CGFloat, callouts: CGFloat)? {
    let shared = width - spacing
    let callouts = shared * (1 - summaryShare)
    guard callouts >= minimumColumn else { return nil }
    return (shared * summaryShare, callouts)
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    guard subviews.count == 2 else { return .zero }
    let width = proposal.width.flatMap { $0.isFinite ? $0 : nil }
    if let width, let columns = Self.widths(for: width) {
      let summary = subviews[0].sizeThatFits(ProposedViewSize(width: columns.summary, height: nil))
      let callouts = subviews[1].sizeThatFits(ProposedViewSize(width: columns.callouts, height: nil))
      return CGSize(width: width, height: max(summary.height, callouts.height))
    }
    let sizes = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)) }
    return CGSize(
      width: width ?? sizes.map(\.width).max() ?? 0,
      height: sizes[0].height + DecisionCard.rowSpacing + sizes[1].height)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    guard subviews.count == 2 else { return }
    if let columns = Self.widths(for: bounds.width) {
      subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(width: columns.summary, height: nil))
      subviews[1].place(
        at: CGPoint(x: bounds.minX + columns.summary + Self.spacing, y: bounds.minY),
        proposal: ProposedViewSize(width: columns.callouts, height: nil))
      return
    }
    let proposal = ProposedViewSize(width: bounds.width, height: nil)
    let summary = subviews[0].sizeThatFits(proposal)
    subviews[0].place(at: bounds.origin, proposal: proposal)
    subviews[1].place(
      at: CGPoint(x: bounds.minX, y: bounds.minY + summary.height + DecisionCard.rowSpacing), proposal: proposal)
  }
}

extension View {
  /// The tinted, outlined box that a callout sits in.
  func calloutChrome(_ color: Color) -> some View {
    background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.1)))
      .overlay(RoundedRectangle(cornerRadius: 8).stroke(color.opacity(0.35)))
  }
}

/// A callout: an icon and tint for its kind, a title, and a body.
struct CalloutView: View {
  let callout: Callout

  static func style(_ kind: Callout.Kind) -> (icon: String, color: Color) {
    switch kind {
    case .warning: return ("exclamationmark.triangle.fill", .orange)
    case .decision: return ("arrow.triangle.branch", .purple)
    case .info: return ("info.circle.fill", .blue)
    }
  }

  var body: some View {
    let style = Self.style(callout.kind)
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: style.icon).foregroundStyle(style.color).accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(callout.title).fontWeight(.semibold)
        if !callout.body.isEmpty {
          MarkdownView(text: callout.body).font(.callout).foregroundStyle(.secondary)
        }
      }
      .textSelection(.enabled)
      Spacer(minLength: 0)
    }
    .padding(10)
    .calloutChrome(style.color)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(callout.kind.rawValue.capitalized): \(callout.title). \(callout.body)")
  }
}

/// The heading of one of a message's sections.
struct SectionTitle: View {
  let text: String

  var body: some View {
    Text(text).font(.headline).accessibilityAddTraits(.isHeader)
  }
}

/// The tool call or group message, the callouts that the step view moves
/// here, the transcript steps that lead up to the item, the PR and its
/// checks, and waits. The last reply stands in for the steps when they don't
/// load. The newest events show only with the `showsRecentEvents` setting.
/// They stay collapsed until the user opens them, except for a permission
/// call that the Summary shows in part.
struct CardDetails: View {
  @EnvironmentObject var model: BoardModel
  let session: SessionSummary
  /// The item's ref. Steps read for another item don't show.
  let ref: String
  let details: TriageDetails
  /// The item's callouts, when the step view takes their place on the card.
  let callouts: [Callout]
  @State private var open: Bool
  /// How many steps before the item to read.
  @State private var steps = ItemContext.defaultSteps
  /// A debug setting with no menu item: `defaults write <bundle id> showsRecentEvents -bool true`.
  @AppStorage("showsRecentEvents") private var showsRecentEvents = false

  init(session: SessionSummary, ref: String, details: TriageDetails, callouts: [Callout] = []) {
    self.session = session
    self.ref = ref
    self.details = details
    self.callouts = callouts
    _open = State(initialValue: details.openByDefault || Snapshot.opensDetails)
  }

  /// The step count that "Show more" asks for next: 15, then 30, then 30 more each time, up to the most sbd reads.
  static func nextSteps(after steps: Int) -> Int {
    steps < 15 ? 15 : steps < 30 ? 30 : min(steps + 30, ItemContext.maxSteps)
  }

  /// The loaded steps when they belong to the item that `ref` names.
  static func context(for ref: String, in context: ItemContext?) -> ItemContext? {
    context?.ref == ref ? context : nil
  }

  /// The reply to show when the item's steps did not load or are empty.
  static func lastReply(context: ItemContext?, reply: String?) -> String? {
    guard context?.steps.isEmpty ?? true, let reply, !reply.isEmpty else { return nil }
    return reply
  }

  var body: some View {
    let context = Self.context(for: ref, in: model.itemContexts[session.id])
    DisclosureGroup(isExpanded: $open) {
      VStack(alignment: .leading, spacing: 12) {
        if let input = details.toolInput {
          section(details.targets.isEmpty ? "Tool call: \(input.tool)" : "Message") {
            CardView.textBox(input.text, maxHeight: 200)
          }
        }
        if !details.targets.isEmpty {
          section("Sends to") { ForEach(details.targets, id: \.self) { Text(verbatim: $0) } }
        }
        if !callouts.isEmpty {
          section("Callouts") {
            ForEach(Array(callouts.enumerated()), id: \.offset) { CalloutView(callout: $1) }
          }
        }
        if let context, !context.steps.isEmpty { transcript(context) }
        if let pr = session.pr {
          section("Pull request") {
            if let url = pr.link { Link("\(pr.line): \(pr.title)", destination: url) } else { Text(pr.line) }
          }
        }
        if !session.waits.isEmpty {
          section("Waits") { ForEach(session.waits, id: \.id) { Text($0.line) } }
        }
        if let text = Self.lastReply(context: context, reply: model.replies[session.id] ?? session.lastReply) {
          section("Last reply") { MarkdownView(text: text) }
        }
        if showsRecentEvents, let events = model.recentEvents[session.id], !events.isEmpty {
          section("Recent events") {
            ForEach(events, id: \.id) { e in
              Text("\(ago(e.t)) · \(e.kind)").font(.caption.monospaced()).foregroundStyle(.secondary)
            }
          }
        }
      }
      .padding(.top, 6)
    } label: {
      SectionTitle(text: "Details")
    }
    .onAppear { if open { load() } }
    .onChange(of: open) { if open { load() } }
  }

  private func load() {
    model.loadItemContext(session.id, steps: steps)
    if showsRecentEvents { model.loadEvents(session.id) }
  }

  /// The steps scroll in a box that starts at the bottom, so the item's own step shows first.
  private func transcript(_ context: ItemContext) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline) {
        Text(context.anchored ? "Transcript" : "Latest steps").font(.caption.bold()).foregroundStyle(.secondary)
        Spacer()
        if session.transcriptTarget != nil {
          Button("Open in transcript") { model.openTranscript(session) }.buttonStyle(.link).font(.caption)
        }
      }
      if let caption = context.caption {
        Text(caption).font(.caption).foregroundStyle(.secondary)
      }
      ScrollViewReader { proxy in
        ScrollView {
          VStack(alignment: .leading, spacing: 8) {
            if context.more {
              Button("Show more") {
                steps = Self.nextSteps(after: steps)
                model.loadItemContext(session.id, steps: steps)
              }
              .buttonStyle(.link).font(.caption)
            }
            ForEach(Array(context.steps.enumerated()), id: \.offset) { index, step in
              StepRow(step: step, isAnchor: index == context.anchorIndex).id(index)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Below a tool call box the steps get less room, so Allow and Deny stay in view in a 700 pt window.
        .frame(maxHeight: details.toolInput == nil ? 260 : 160)
        .fixedSize(horizontal: false, vertical: true)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
        .onAppear { proxy.scrollTo(context.steps.count - 1, anchor: .bottom) }
      }
    }
  }

  private func section(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).font(.caption.bold()).foregroundStyle(.secondary)
      content()
    }
  }
}

/// One of Claude's steps: its text as Markdown, or a tool call on one line.
/// The item's own step has an accent bar on its leading edge.
private struct StepRow: View {
  let step: TranscriptStep
  let isAnchor: Bool

  var body: some View {
    HStack(alignment: .top, spacing: 6) {
      RoundedRectangle(cornerRadius: 1).fill(isAnchor ? Color.accentColor : .clear).frame(width: 3)
      if step.kind == .tool {
        let line = step.summary ?? ""
        Text(verbatim: line).font(.caption.monospaced()).lineLimit(1).truncationMode(.tail).help(line)
          .textSelection(.enabled)
      } else {
        MarkdownView(text: step.text ?? "")
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityHint(isAnchor ? "The step this item came from" : "")
  }
}
