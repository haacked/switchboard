import SwiftUI
import SwitchboardCore

/// The right pane of the Inbox: the session's decision card, and a field that
/// talks to the session itself. The terminals are behind a toggle.
struct TriageDetail: View {
  @EnvironmentObject var model: BoardModel
  let session: SessionSummary

  enum Pane { case terminal, summary }

  /// An unstarted follow-up and a docket row have no terminals, so they show their summary whatever the toggle says.
  /// A failed removal shows its summary too, because the summary holds Retry and Keep.
  static func pane(for session: SessionSummary, showingTerminal: Bool) -> Pane {
    showingTerminal && !session.waitsToStart && session.runsClaude && session.removal?.state != .failed
      ? .terminal : .summary
  }

  struct BarLink {
    /// The PR number, such as "#4812".
    var label: String
    /// The PR's status, title, and head branch, which the label leaves out.
    var help: String
    var status = ""
    var url: URL
    var owners: CodeOwnerStatus?
    /// The PR's branch when the folder is on another branch.
    var head: String?
  }

  /// The PR that the bar links to, with the code owners of that PR. A docket
  /// row links to the PR that docket reviews and ignores its `pr`. The bar
  /// therefore never shows one PR's link beside another PR's code owners.
  static func prLink(for session: SessionSummary) -> BarLink? {
    if let docket = session.docket {
      guard let url = docket.link else { return nil }
      let label = DocketRef(docket.pullRequest).map { "#\($0.number)" } ?? docket.pullRequest
      let title = docket.review?.title.flatMap { $0.isEmpty ? nil : $0 }
      return BarLink(
        label: label, help: [docket.pullRequest, title].compactMap { $0 }.joined(separator: ": "), url: url)
    }
    guard let pr = session.pr, let url = pr.link else { return nil }
    let head = pr.otherBranch(than: session.branch)
    var help = pr.line
    if !pr.title.isEmpty { help += " · \(pr.repo): \(pr.title)" }
    if let prBranch = pr.head, !prBranch.isEmpty { help += ". The PR's branch is \(prBranch)." }
    if head != nil { help += " This folder is on \(session.branch ?? "another branch")." }
    return BarLink(
      label: pr.numberLabel, help: help, status: pr.status.rawValue, url: url, owners: pr.codeOwners, head: head)
  }

  struct ReplyKey: Hashable {
    var session: String
    var reply: String?
    var since: Int64
  }

  /// When the pane reads the session's reply again: for each new `lastReply`, and on each change of state.
  static func replyKey(_ session: SessionSummary) -> ReplyKey {
    ReplyKey(session: session.id, reply: session.lastReply, since: session.since)
  }

  var body: some View {
    VStack(spacing: 0) {
      bar
      Divider()
      if Self.pane(for: session, showingTerminal: model.showingTerminal) == .terminal {
        SessionView(session: session)
      } else {
        DetailPane {
          VStack(alignment: .leading, spacing: 14) {
            if session.removal?.state == .failed {
              FailedRemovalActions(session: session)
              reply
            } else if let item = session.triage {
              if item.source == .report {
                Label("From background follow-through", systemImage: "gearshape.2")
                  .font(.caption).foregroundStyle(.secondary)
              }
              DecisionCard(session: session, item: item, step: step)
            } else {
              working
              reply
            }
          }
          .padding(16)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        if let list = session.stepList {
          Divider()
          DecisionStepBar(session: session, list: list, step: step)
        }
        Divider()
        if session.waitsToStart {
          // A follow-up has no claude to message yet.
          StartButton(session: session).padding(8)
        } else if session.runsClaude {
          MessageField(
            session: session.id, draft: model.inboxDraft(for: session),
            shortcut: .sendMessage, ref: session.triage?.ref
          )
          .padding(8)
        }
      }
    }
    .task(id: Self.replyKey(session)) { model.loadReply(session) }
    .referenceRepo(session)
  }

  /// The step that the card's decision view shows, which `BoardModel` keeps so that it survives leaving the item.
  private var step: Binding<DecisionStep?> {
    let id = session.id
    let ref = session.stepList?.ref
    return Binding(
      get: { ref.flatMap { model.decisionStep(session: id, ref: $0) } },
      set: { step in if let ref { model.setDecisionStep(step, session: id, ref: ref) } })
  }

  private var bar: some View {
    let name = model.inboxName(session)
    let link = Self.prLink(for: session)
    // When the pane is narrow, the branch drops out whole first, then the repo, then the PR's head branch. Only the
    // name truncates. The PR number and the buttons keep their full width.
    return HStack(spacing: 8) {
      ViewThatFits(in: .horizontal) {
        ForEach(0..<4) { leading(name: name, link: link, dropping: $0) }
      }
      Spacer(minLength: 0)
      Button("Open") { model.selection = session.id }
        .fixedSize()
        .help("Show the session in the sidebar, with its terminals")
      Toggle("Terminal", isOn: $model.showingTerminal)
        .toggleStyle(.button)
        .fixedSize()
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

  /// The bar's leading items. `dropping` leaves out that many of the branch, the repo, and the PR's head branch, in
  /// that order.
  private func leading(name: String, link: BarLink?, dropping: Int) -> some View {
    HStack(spacing: 8) {
      Text(name).fontWeight(.medium).lineLimit(1).help(name)
      if dropping < 2, let repo = session.repoFolder {
        Text(repo.split(separator: "/").last.map(String.init) ?? repo).foregroundStyle(.secondary).lineLimit(1)
      }
      if dropping < 1, let branch = session.branch {
        Text(branch).foregroundStyle(.secondary).lineLimit(1)
      }
      if let link {
        HStack(spacing: 4) {
          PRLink(text: link.label, url: link.url).font(.caption).foregroundStyle(.link).fixedSize()
            .help(link.help)
            .accessibilityValue(link.status)
          if let owners = link.owners { CodeOwnerShield(status: owners) }
          if dropping < 3, let head = link.head {
            Text("uses \(head)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
          }
        }
      }
    }
  }

  private var working: some View {
    HStack(spacing: 8) {
      if session.state == .working { ProgressView().controlSize(.small) }
      InlineText(plain: session.state == .working ? "Working: \(session.reason)" : session.reason)
        .foregroundStyle(.secondary)
      if session.acknowledged == true { AcknowledgeButton(session: session) }
    }
  }

  @ViewBuilder
  private var reply: some View {
    if let text = model.reply(for: session), !text.isEmpty {
      LastReplySection(text: text).padding(.top, 4)
    }
  }
}

/// The Inbox's detail pane, which scrolls the whole card. It puts its scroll proxy in the environment, so text boxes
/// in it drop their own height caps.
struct DetailPane<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView { content }
        .environment(\.detailScroll, proxy)
    }
  }
}
