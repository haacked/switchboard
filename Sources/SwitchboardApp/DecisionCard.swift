import SwiftUI
import SwitchboardCore

/// The Inbox card of a session: what it did and needs, the buttons that act
/// on it, what to read before deciding, and the details behind a disclosure.
struct DecisionCard: View {
  @EnvironmentObject var model: BoardModel
  let session: SessionSummary
  let item: TriageItem

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      header
      if !item.summary.isEmpty {
        Text(item.summary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
      }
      if !item.callouts.isEmpty {
        VStack(alignment: .leading, spacing: 8) {
          ForEach(Array(item.callouts.enumerated()), id: \.offset) { CalloutView(callout: $1) }
        }
      }
      actions
      CardDetails(session: session)
    }
  }

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
    if session.state == .readyToMerge {
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

  /// Whether the option's row shows `effect` beside its button. A session
  /// writes the label, so the row shows what a click does unless the label is
  /// the text that a click sends.
  var showsEffect: Bool { action != .send || (message ?? label) != label }

  /// What VoiceOver reads after the label: the option's detail and what a
  /// click does.
  var accessibilityHint: String {
    OptionRow.join(detail, effect) ?? effect
  }
}

/// An option's compact button. A click runs the option's action. The primary
/// one is filled and answers ⌘⇧Return.
struct OptionButton: View {
  @EnvironmentObject var model: BoardModel
  let session: SessionSummary
  let ref: String
  let number: Int
  let option: TriageOption
  let title: OptionTitle
  let primary: Bool

  static let primaryShortcut = KeyboardShortcut(.return, modifiers: [.command, .shift])

  var body: some View {
    let button = Button {
      model.choose(session.id, ref: ref, option: number, action: option.action)
    } label: {
      title
    }
    .disabled(
      model.choosing.contains("\(session.id)/\(number)")
        || (option.action.isMerge && model.merging.contains(session.id))
    )
    .help(option.effect)
    .accessibilityLabel(option.accessibilityLabel(pr: session.pr?.number))
    .accessibilityHint(option.accessibilityHint)
    if primary {
      button.buttonStyle(.borderedProminent).keyboardShortcut(Self.primaryShortcut)
    } else {
      button.buttonStyle(.bordered)
    }
  }
}

/// A choice that needs typing: a short field and a Send button. The option's
/// row shows its title beside them.
struct ReplyOption: View {
  @EnvironmentObject var model: BoardModel
  let session: SessionSummary
  let ref: String
  let number: Int
  let option: TriageOption
  @Binding var text: String

  private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

  var body: some View {
    HStack {
      TextField(option.placeholder ?? option.label, text: $text)
        .textFieldStyle(.roundedBorder)
        .onSubmit(send)
        .accessibilityLabel(option.label)
        .accessibilityHint(option.detail ?? "")
      Button("Send", action: send)
        .disabled(trimmed.isEmpty || model.choosing.contains("\(session.id)/\(number)"))
        .accessibilityLabel("Send: \(option.label)")
    }
  }

  private func send() {
    guard !trimmed.isEmpty else { return }
    model.choose(session.id, ref: ref, option: number, action: .reply, text: trimmed)
    text = ""
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

/// The full last reply, the PR and its checks, notes, waits, and the newest
/// events, collapsed until the user opens them.
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
