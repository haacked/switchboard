import SwiftUI
import SwitchboardCore

/// The Inbox message of a session, in sections that never change their
/// order: the Summary (what it did and needs, and what to read before
/// deciding), the Drafts when the session wrote a message for the user to
/// send, the Action (the buttons), and the Details (behind a disclosure).
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
      if !item.drafts.isEmpty { DraftsSection(drafts: item.drafts) }
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
      // A new item starts with its own open or closed Details.
      CardDetails(session: session, details: item.details, callouts: list == nil ? [] : item.callouts).id(item.ref)
    }
  }

  /// Whether the item's Details holds this card's call, so the card can
  /// leave it out. An item from an older sbd has no call in its Details, and
  /// its card then shows the call.
  static func detailsHoldCall(cardSession: String, cardRef: String, of item: TriageItem, session: String) -> Bool {
    cardSession == session && cardRef == item.ref && item.details.toolInput != nil
  }

  /// Whether the card shows its summary and its callouts as two columns
  /// when it is wide enough. A card without either one keeps a single stack.
  static func splitsSummary(_ item: TriageItem) -> Bool {
    !item.summary.isEmpty && !item.callouts.isEmpty
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
      // An approval needs to see the whole tool call. A card leaves it out only when the item's Details shows it.
      let cards = Card.inbox(session, all: model.sessions)
      GroupMessageBatch(cards: cards.filter { $0.kind == .send })
      ForEach(cards) {
        CardView(
          card: $0, draft: model.draft(for: $0),
          compact: Self.detailsHoldCall(cardSession: $0.session, cardRef: $0.ref, of: item, session: session.id))
      }
    } else if !item.options.isEmpty {
      OptionList(session: session, item: item, takesShortcut: !item.hasDecisionList)
    } else if session.openPrompt {
      // A message would only queue behind the open dialog.
      Text("Claude Code's dialog waits in the terminal. Open the Terminal to answer it.")
        .foregroundStyle(.secondary)
    } else if item.source == .fallback {
      Text("No summary yet. Details holds the last reply.").font(.caption).foregroundStyle(.secondary)
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
      if let error = model.decisionErrors[session.id] {
        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout)
          .fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
      }
      Button("Send again") { model.resendDecisions(session.id) }
        .disabled(model.deciding.contains("\(session.id)/resend"))
        .accessibilityLabel("Send the answers again")
        .accessibilityHint("Sends the same answers once more. The session may get them twice.")
    }
    // A refused resend leaves the button as it was, so VoiceOver would say nothing.
    .onChange(of: model.decisionErrors[session.id]) {
      if let error = model.decisionErrors[session.id] { AccessibilityNotification.Announcement(error).post() }
    }
  }
}

extension TriageOption {
  /// What VoiceOver reads for the option's button. It names the action, and a
  /// merge also names its PR.
  func accessibilityLabel(pr: Int?) -> String {
    guard action == .merge, let pr, label.range(of: "#\(pr)(?![0-9])", options: .regularExpression) == nil else {
      return label
    }
    return "\(label), merge #\(pr)"
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
/// here, the PR and its checks, waits, the full last reply, and the newest
/// events. They stay collapsed until the user opens them, except for a
/// permission call that the Summary shows in part.
struct CardDetails: View {
  @EnvironmentObject var model: BoardModel
  let session: SessionSummary
  let details: TriageDetails
  /// The item's callouts, when the step view takes their place on the card.
  let callouts: [Callout]
  @State private var open: Bool

  init(session: SessionSummary, details: TriageDetails, callouts: [Callout] = []) {
    self.session = session
    self.details = details
    self.callouts = callouts
    _open = State(initialValue: details.openByDefault || Snapshot.opensDetails)
  }

  var body: some View {
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
        if let pr = session.pr {
          section("Pull request") {
            if let url = pr.link { Link("\(pr.line): \(pr.title)", destination: url) } else { Text(pr.line) }
          }
        }
        if !session.waits.isEmpty {
          section("Waits") { ForEach(session.waits, id: \.id) { Text($0.line) } }
        }
        if let text = model.replies[session.id] ?? session.lastReply, !text.isEmpty {
          section("Last reply") { MarkdownView(text: text) }
        }
        if let events = model.recentEvents[session.id], !events.isEmpty {
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
    .onAppear { if open { model.loadEvents(session.id) } }
    .onChange(of: open) { if open { model.loadEvents(session.id) } }
  }

  private func section(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).font(.caption.bold()).foregroundStyle(.secondary)
      content()
    }
  }
}
