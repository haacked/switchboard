import SwiftUI
import SwitchboardCore

/// The Inbox message of a session, in three sections that never change their
/// order: the Summary (what it did and needs, and what to read before
/// deciding), the Action (the buttons), and the Details (behind a disclosure).
struct DecisionCard: View {
  @EnvironmentObject var model: BoardModel
  let session: SessionSummary
  let item: TriageItem

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      header
      VStack(alignment: .leading, spacing: 8) {
        SectionTitle(text: Self.sectionTitles[0])
        if !item.summary.isEmpty {
          Text(item.summary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        ForEach(Array(item.callouts.enumerated()), id: \.offset) { CalloutView(callout: $1) }
      }
      VStack(alignment: .leading, spacing: 8) {
        SectionTitle(text: Self.sectionTitles[1])
        actions
      }
      // A new item starts with its own open or closed Details.
      CardDetails(session: session, details: item.details).id(item.ref)
    }
  }

  /// The names of the three sections, in the order the card draws them.
  static let sectionTitles = ["Summary", "Action", "Details"]

  private var header: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(item.title).font(.title3.bold()).textSelection(.enabled)
      Text(item.kind.rawValue).font(.caption.bold()).padding(.horizontal, 6).padding(.vertical, 2)
        .background(Capsule().fill(session.state.color.opacity(0.18)))
        .foregroundStyle(session.state.color)
        .accessibilityLabel("Kind: \(item.kind.rawValue)")
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
      // Details holds this session's own call and message text.
      ForEach(cards) { CardView(card: $0, draft: model.draft(for: $0), compact: $0.session == session.id) }
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

/// The heading of one of a message's sections.
struct SectionTitle: View {
  let text: String

  var body: some View {
    Text(text).font(.headline).accessibilityAddTraits(.isHeader)
  }
}

/// The tool call or group message, the PR and its checks, notes, waits, the
/// full last reply, and the newest events. They stay collapsed until the user
/// opens them, except for a permission call that the Summary shows in part.
struct CardDetails: View {
  @EnvironmentObject var model: BoardModel
  let session: SessionSummary
  let details: TriageDetails
  @State private var open: Bool

  init(session: SessionSummary, details: TriageDetails) {
    self.session = session
    self.details = details
    _open = State(initialValue: details.openByDefault)
  }

  var body: some View {
    DisclosureGroup(isExpanded: $open) {
      VStack(alignment: .leading, spacing: 12) {
        if let input = details.toolInput {
          section(session.cards.first?.send == nil ? "Tool call: \(input.tool)" : "Message") {
            Text(verbatim: input.text).font(.body.monospaced()).textSelection(.enabled)
          }
        }
        if !details.targets.isEmpty {
          section("Sends to") { ForEach(details.targets, id: \.self) { Text(verbatim: $0) } }
        }
        if let pr = session.pr {
          section("Pull request") {
            if let url = pr.link { Link("\(pr.line): \(pr.title)", destination: url) } else { Text(pr.line) }
          }
        }
        if !session.waits.isEmpty {
          section("Waits") { ForEach(session.waits, id: \.id) { Text($0.line) } }
        }
        if !session.notes.isEmpty {
          section("Notes") { ForEach(session.notes, id: \.id) { Text($0.text).textSelection(.enabled) } }
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
      SectionTitle(text: DecisionCard.sectionTitles[2])
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
