import SwiftUI
import SwitchboardCore

/// The Inbox card of a session: what it did and needs, the buttons that act
/// on it, what to read before deciding, and the details behind a disclosure.
struct DecisionCard: View {
  @EnvironmentObject var model: BoardModel
  let session: SessionSummary
  let item: TriageItem

  static let rowSpacing: CGFloat = 14

  var body: some View {
    VStack(alignment: .leading, spacing: Self.rowSpacing) {
      header
      if Self.splitsSummary(item) {
        SummaryCalloutColumns {
          summary
          callouts
        }
      } else {
        if !item.summary.isEmpty { summary }
        if !item.callouts.isEmpty { callouts }
      }
      VStack(alignment: .leading, spacing: 8) { actions }
      CardDetails(session: session)
    }
  }

  /// Whether the card shows its summary and its callouts as two columns
  /// when it is wide enough. A card without either one keeps a single stack.
  static func splitsSummary(_ item: TriageItem) -> Bool {
    !item.summary.isEmpty && !item.callouts.isEmpty
  }

  private var summary: some View {
    Text(item.summary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
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
      // The card shows the whole tool call, which an approval needs to see.
      let cards = Card.inbox(session, all: model.sessions)
      GroupMessageBatch(cards: cards.filter { $0.kind == .send })
      ForEach(cards) { CardView(card: $0, draft: model.draft(for: $0)) }
    } else if !item.options.isEmpty {
      OptionList(session: session, item: item)
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
          Text(callout.body).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
      }
      .textSelection(.enabled)
      Spacer(minLength: 0)
    }
    .padding(10)
    .background(RoundedRectangle(cornerRadius: 8).fill(style.color.opacity(0.1)))
    .overlay(RoundedRectangle(cornerRadius: 8).stroke(style.color.opacity(0.35)))
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(callout.kind.rawValue.capitalized): \(callout.title). \(callout.body)")
  }
}

/// The full last reply, the PR and its checks, waits, and the newest events,
/// collapsed until the user opens them.
struct CardDetails: View {
  @EnvironmentObject var model: BoardModel
  let session: SessionSummary
  @State private var open = false

  var body: some View {
    DisclosureGroup(isExpanded: $open) {
      VStack(alignment: .leading, spacing: 12) {
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
      Text("Details").font(.headline)
    }
    .onChange(of: open) { if open { model.loadEvents(session.id) } }
  }

  private func section(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).font(.caption.bold()).foregroundStyle(.secondary)
      content()
    }
  }
}
