import SwiftUI
import SwitchboardCore

/// The right pane of the Inbox: the session's decision card, and a field that
/// talks to the session itself. The terminals are behind a toggle.
struct TriageDetail: View {
  @EnvironmentObject var model: BoardModel
  let session: SessionSummary

  enum Pane { case terminal, summary }

  /// An unstarted follow-up and a docket row have no terminals, so they show their summary whatever the toggle says.
  static func pane(for session: SessionSummary, showingTerminal: Bool) -> Pane {
    showingTerminal && !session.waitsToStart && session.runsClaude ? .terminal : .summary
  }

  /// The PR that the bar links to, with the code owners of that PR. A docket
  /// row links to the PR that docket reviews and ignores its `pr`. The bar
  /// therefore never shows one PR's link beside another PR's code owners.
  static func prLink(for session: SessionSummary) -> (label: String, url: URL, owners: CodeOwnerStatus?)? {
    if let docket = session.docket { return docket.link.map { (docket.pullRequest, $0, nil) } }
    if let pr = session.pr, let url = pr.link { return (pr.line, url, pr.codeOwners) }
    return nil
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
              DecisionCard(session: session, item: item)
            } else {
              working
              reply
            }
          }
          .padding(16)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        Divider()
        if session.waitsToStart {
          // A follow-up has no claude to message yet.
          StartButton(session: session).padding(8)
        } else if session.runsClaude {
          MessageField(
            session: session.id, draft: model.messageDraft(for: session),
            shortcut: KeyboardShortcut(.return, modifiers: [.command])
          )
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
      if let link = Self.prLink(for: session) {
        HStack(spacing: 4) {
          Link(link.label, destination: link.url).font(.caption)
          if let owners = link.owners { CodeOwnerShield(status: owners) }
        }
      }
      Spacer()
      Button("Open") { model.selection = session.id }
        .help("Show the session in the sidebar, with its terminals")
      Toggle("Terminal", isOn: $model.showingTerminal)
        .toggleStyle(.button)
        .disabled(!session.runsClaude)
        .help(
          session.waitsToStart
            ? "A follow-up has no terminals until it starts"
            : !session.runsClaude
              ? "A docket review has no terminals"
              : "Show the session's Claude terminal and shell in place of its summary")
    }
    .padding(10)
  }

  private var working: some View {
    HStack(spacing: 8) {
      if session.state == .working { ProgressView().controlSize(.small) }
      Text(session.state == .working ? "Working: \(session.reason)" : session.reason).foregroundStyle(.secondary)
      if session.acknowledged == true { AcknowledgeButton(session: session) }
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
