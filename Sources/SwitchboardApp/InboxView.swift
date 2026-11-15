import SwiftUI
import SwitchboardCore

struct InboxView: View {
  @EnvironmentObject var model: BoardModel

  var body: some View {
    VStack(spacing: 0) {
      if !model.planProposals.isEmpty {
        PlanProposalList(proposals: model.planProposals)
        Divider()
      }
      sessions
    }
  }

  @ViewBuilder
  private var sessions: some View {
    if model.triage.isEmpty && model.currentInboxItem == nil {
      let hidden = model.hiddenNeedingYou
      ContentUnavailableView {
        Label(
          Self.emptyTitle(hiddenNeedingYou: hidden, hasPlanProposals: !model.planProposals.isEmpty),
          systemImage: "checkmark.circle")
      } description: {
        Text(Self.emptyMessage(hiddenNeedingYou: hidden))
      } actions: {
        if hidden > 0 { Button("Show All Orgs") { model.orgFilter = OrgFilter() } }
        Button("Show Board") { model.show(.board) }
      }
    } else {
      ListDetailSplit {
        // The list stays mounted under the empty state. A new list would take the focus from the detail's message
        // field when an item arrives, and ⌘L would have no list to focus.
        TriageList()
          .overlay {
            if model.triage.isEmpty {
              ContentUnavailableView(
                Self.emptyTitle(
                  hiddenNeedingYou: model.hiddenNeedingYou, hasPlanProposals: !model.planProposals.isEmpty),
                systemImage: "checkmark.circle")
            }
          }
      } detail: {
        if let id = model.currentInboxItem, let session = model.sessions.first(where: { $0.id == id }) {
          VStack(spacing: 0) {
            // The detail keeps an answered item while Claude works on it, so the banner says that it left the list.
            if model.leftInboxItem != nil {
              LeftInboxBanner(session: session, hasNext: !model.triage.isEmpty)
              Divider()
            }
            TriageDetail(session: session).id(session.id)
          }
        } else {
          ContentUnavailableView("Select an item", systemImage: "tray")
        }
      }
    }
  }

  /// The empty Inbox's title. It adds "in these orgs" when the org filter hides sessions that need the user.
  static func emptyTitle(hiddenNeedingYou: Int, hasPlanProposals: Bool) -> String {
    let subject = hasPlanProposals ? "No session" : "Nothing"
    return hiddenNeedingYou > 0 ? "\(subject) in these orgs needs you" : "\(subject) needs you"
  }

  /// The line under the empty Inbox's title. With no hidden sessions that need the user, it says what the Inbox lists.
  /// Otherwise it gives how many of those sessions the org filter hides.
  static func emptyMessage(hiddenNeedingYou: Int) -> String {
    switch hiddenNeedingYou {
    case 0: "Sessions show here when they need an answer, an approval, or a decision."
    case 1: "1 session in an org the filter hides needs you."
    default: "\(hiddenNeedingYou) sessions in orgs the filter hides need you."
    }
  }
}

/// One row for each session that needs you, then one for each that Claude
/// can continue. No Claude output appears here, only what the user does.
/// While the list has focus, j and k move to the next and previous item
/// around the ends, ↓ and ↑ move and stop at the ends, and Return goes into
/// the item's Claude terminal.
struct TriageList: View {
  @EnvironmentObject var model: BoardModel
  @FocusState private var focused: Bool

  var body: some View {
    let items = model.triage
    let current = model.currentInboxItem
    let repos = model.repoLabels
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 2) {
          ForEach(AttentionState.inbox, id: \.self) { state in
            let group = items.filter { $0.state == state }
            if !group.isEmpty {
              ListSectionHeader(title: state.title, count: group.count)
              ForEach(group) { s in
                TriageRow(session: s, repo: repos[s.id], current: s.id == current).id(s.id)
                  .simultaneousGesture(TapGesture().onEnded { focused = true })
              }
            }
          }
        }
        .padding(.vertical, 6)
      }
      .listKeys(.inbox, $focused, model: model) {
        model.moveInbox(by: $0, wrap: $1)
      } open: {
        model.focusTerminal()
      }
      .onChange(of: model.inboxJumps, initial: true) {
        // The rows have no layout yet when the Inbox replaces the Board. A scroll
        // right away often does nothing, so this waits 0.3 s.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
          if let id = model.currentInboxItem { withAnimation { proxy.scrollTo(id) } }
        }
      }
    }
  }
}

struct TriageRow: View {
  @EnvironmentObject var model: BoardModel
  let session: SessionSummary
  let repo: String?
  let current: Bool

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Circle()
        .fill(session.state.color)
        .frame(width: 8, height: 8)
        .padding(.top, 5)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        InlineText(plain: session.inboxTitle, links: false).fontWeight(.medium).lineLimit(2)
        Text(
          [repo, model.inboxName(session), ago(session.since)]
            .compactMap { $0 }.joined(separator: " · ")
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
      }
      Spacer(minLength: 0)
      IssueBadge(session: session)
      NotesButton(session: session)
    }
    .listRowChrome(current: current)
    .hoverCard(session, activeAccount: model.activeAccountFolder, card: model.hoverCard)
    .onTapGesture { model.inboxFocus = session.id }
    .contextMenu { SnoozeMenuItems(session: session) }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(current ? .isSelected : [])
  }
}

/// The line above an Inbox item that is no longer in the Inbox, such as one Claude works on after an answer. The
/// header below it has the Open button.
struct LeftInboxBanner: View {
  @EnvironmentObject var model: BoardModel
  let session: SessionSummary
  let hasNext: Bool

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "arrow.uturn.right.circle").foregroundStyle(.secondary).accessibilityHidden(true)
      Text(Self.message(session.state)).foregroundStyle(.secondary).lineLimit(1)
      Spacer(minLength: 0)
      if hasNext {
        Button("Next Item") { model.moveInbox(by: 1) }.fixedSize()
          .help("Show the first item that still needs you")
      }
    }
    .font(.callout)
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
  }

  /// What the banner says for a session in `state`.
  static func message(_ state: AttentionState) -> String { "Left the Inbox: \(state.title)" }
}

extension BoardModel {
  /// The shown Inbox session when it is not in the Inbox list, such as one Claude works on after an answer.
  var leftInboxItem: SessionSummary? {
    guard let id = currentInboxItem, !triage.contains(where: { $0.id == id }) else { return nil }
    return sessions.first { $0.id == id }
  }
}
