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
      MergeBatch(sessions: session.mergeCards(all: model.sessions))
    }
    if item.source == .card {
      // The card shows the whole tool call, which an approval needs to see.
      let cards = Card.inbox(session, all: model.sessions)
      GroupMessageBatch(cards: cards.filter { $0.kind == .send })
      ForEach(cards) { CardView(card: $0, draft: model.draft(for: $0)) }
    } else if !item.options.isEmpty {
      // An option written twice is one main button.
      let primary = item.primary.flatMap { item.options.firstIndex(of: $0) }
      VStack(alignment: .leading, spacing: 8) {
        ForEach(Array(item.options.enumerated()), id: \.offset) { i, option in
          if option.action == .reply {
            ReplyOption(session: session, ref: item.ref, number: i + 1, option: option)
          } else {
            OptionButton(
              session: session, ref: item.ref, number: i + 1, option: option, primary: i == primary)
          }
        }
      }
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
}

/// An option's button. A click runs the option's action. The primary one is
/// filled and answers ⌘⇧Return.
struct OptionButton: View {
  @EnvironmentObject var model: BoardModel
  let session: SessionSummary
  let ref: String
  let number: Int
  let option: TriageOption
  let primary: Bool

  static let primaryShortcut = KeyboardShortcut(.return, modifiers: [.command, .shift])

  var body: some View {
    let effect = option.effect
    let button = Button {
      model.choose(session.id, ref: ref, option: number, action: option.action)
    } label: {
      VStack(alignment: .leading, spacing: 2) {
        Text(option.label).fontWeight(.medium)
        if let detail = option.detail { Text(detail).font(.caption).opacity(0.8) }
        // A click sends this text as the user, so the button shows it.
        if option.action == .send && option.message != option.label {
          Text(effect).font(.caption).opacity(0.8).lineLimit(3)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.vertical, 4)
    }
    .controlSize(.large)
    .disabled(model.choosing.contains("\(session.id)/\(number)"))
    .help(effect)
    .accessibilityLabel(option.accessibilityLabel(pr: session.pr?.number))
    .accessibilityHint(effect)
    if primary {
      button.buttonStyle(.borderedProminent).keyboardShortcut(Self.primaryShortcut)
    } else {
      button.buttonStyle(.bordered)
    }
  }
}

/// A choice that needs typing: a short field and a Send button.
struct ReplyOption: View {
  @EnvironmentObject var model: BoardModel
  let session: SessionSummary
  let ref: String
  let number: Int
  let option: TriageOption
  @State private var text = ""

  private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(option.label).fontWeight(.medium)
      HStack {
        TextField(option.placeholder ?? option.label, text: $text)
          .textFieldStyle(.roundedBorder)
          .onSubmit(send)
          .accessibilityLabel(option.label)
        Button("Send", action: send)
          .disabled(trimmed.isEmpty || model.choosing.contains("\(session.id)/\(number)"))
          .accessibilityLabel("Send: \(option.label)")
      }
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
