import SwiftUI
import SwitchboardCore

/// The right pane of the Queue: what the session needs, the buttons that
/// answer it, its last reply, and a field that talks to the session itself.
/// The terminals are behind a toggle.
struct TriageDetail: View {
  @EnvironmentObject var model: BoardModel
  let session: SessionSummary

  enum Pane { case terminal, summary }

  /// An unstarted follow-up has no terminals, so it shows its summary and Start button whatever the toggle says.
  static func pane(for session: SessionSummary, showingTerminal: Bool) -> Pane {
    showingTerminal && !session.waitsToStart ? .terminal : .summary
  }

  var body: some View {
    VStack(spacing: 0) {
      bar
      Divider()
      if Self.pane(for: session, showingTerminal: model.showingTerminal) == .terminal {
        SessionView(session: session)
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 14) {
            if let item = session.triage {
              summary(item)
            } else {
              working
            }
            reply
          }
          .padding(16)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        Divider()
        if session.waitsToStart {
          // A follow-up has no claude to message yet.
          StartButton(session: session).padding(8)
        } else {
          MessageField(session: session.id, shortcut: KeyboardShortcut(.return, modifiers: [.command]))
            .padding(8)
        }
      }
    }
    .task(id: "\(session.id)/\(session.lastReply?.count ?? 0)/\(session.since)") { model.loadReply(session.id) }
  }

  private var bar: some View {
    HStack(spacing: 8) {
      Text(session.name).fontWeight(.medium)
      if let repo = session.repo {
        Text(repo.split(separator: "/").last.map(String.init) ?? repo).foregroundStyle(.secondary)
      }
      if let branch = session.branch { Text(branch).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle) }
      if let pr = session.pr, let url = pr.link { Link(pr.line, destination: url).font(.caption) }
      Spacer()
      Button("Open") { model.selection = session.id }
        .help("Show the session in the sidebar, with its terminals")
      Toggle("Terminal", isOn: $model.showingTerminal)
        .toggleStyle(.button)
        .help("Show the session's Claude terminal and shell in place of its summary")
    }
    .padding(10)
  }

  @ViewBuilder
  private func summary(_ item: TriageItem) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Text(item.title).font(.title3.bold()).textSelection(.enabled)
        Text(item.kind.rawValue).font(.caption.bold()).padding(.horizontal, 6).padding(.vertical, 2)
          .background(Capsule().fill(session.state.color.opacity(0.18)))
          .foregroundStyle(session.state.color)
      }
      if !item.summary.isEmpty { Text(item.summary).textSelection(.enabled) }
      if item.source == .card {
        // The card shows the whole tool call, which an approval needs to see.
        ForEach(session.cards) { CardView(card: $0, draft: model.draft(for: $0)) }
      } else if !item.options.isEmpty {
        ForEach(Array(item.options.enumerated()), id: \.offset) { i, option in
          OptionButton(
            session: session.id, ref: item.ref, number: i + 1, option: option, showsMessage: item.source != .card)
        }
      } else if session.openPrompt {
        // A message would only queue behind the open dialog.
        Text("Claude Code's dialog waits in the terminal. Open the Terminal to answer it.")
          .foregroundStyle(.secondary)
      } else if item.source == .fallback {
        Text("No summary yet. The reply below is what the session said.").font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private var working: some View {
    HStack(spacing: 8) {
      if session.state == .working { ProgressView().controlSize(.small) }
      Text(session.state == .working ? "Working: \(session.reason)" : session.reason).foregroundStyle(.secondary)
    }
  }

  @ViewBuilder
  private var reply: some View {
    if let text = model.replies[session.id] ?? session.lastReply, !text.isEmpty {
      VStack(alignment: .leading, spacing: 6) {
        Text("Last reply").font(.caption.bold()).foregroundStyle(.secondary)
        MarkdownView(text: text)
      }
      .padding(.top, 4)
    }
  }
}

/// A choice of the item. A click sends its message to the session, or answers
/// the session's prompt.
struct OptionButton: View {
  @EnvironmentObject var model: BoardModel
  let session: String
  let ref: String
  let number: Int
  let option: TriageOption
  let showsMessage: Bool

  var body: some View {
    Button {
      model.choose(session, ref: ref, option: number)
    } label: {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 2) {
          Text(option.label).fontWeight(.medium)
          if let detail = option.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
          // A click sends this text as the user, so the button shows it.
          if showsMessage && option.message != option.label {
            Text("Sends: \(option.message)").font(.caption).foregroundStyle(.secondary)
          }
        }
        Spacer(minLength: 8)
        if option.recommended { Text("recommended").font(.caption).foregroundStyle(.secondary) }
      }
      .padding(10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .background(RoundedRectangle(cornerRadius: 8).fill(option.recommended ? Color.accentColor.opacity(0.1) : .clear))
    .overlay(
      RoundedRectangle(cornerRadius: 8).stroke(option.recommended ? Color.accentColor : Color.secondary.opacity(0.35))
    )
    .disabled(model.choosing.contains("\(session)/\(number)"))
    .help(option.message)
  }
}
