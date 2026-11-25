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
      let scope = model.filter.scope
      ContentUnavailableView {
        Label(
          Self.emptyTitle(hiddenNeedingYou: hidden, scope: scope, hasPlanProposals: !model.planProposals.isEmpty),
          systemImage: "checkmark.circle")
      } description: {
        Text(Self.emptyMessage(hiddenNeedingYou: hidden, scope: scope))
      } actions: {
        if hidden > 0 { Button("Show All") { model.showAll() } }
        Button("Show Board") { model.show(.board) }
      }
    } else {
      ListDetailSplit(widthKey: "listWidth.inbox") {
        // The list stays mounted under the empty state. A new list would take the focus from the detail's message
        // field when an item arrives, and ⌘L would have no list to focus.
        TriageList()
          .overlay {
            if model.triage.isEmpty {
              ContentUnavailableView(
                Self.emptyTitle(
                  hiddenNeedingYou: model.hiddenNeedingYou, scope: model.filter.scope,
                  hasPlanProposals: !model.planProposals.isEmpty),
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

  /// The empty Inbox's title. It adds "in these orgs", "in these groups", or "in these orgs and groups" when the
  /// filter hides sessions that need the user.
  static func emptyTitle(hiddenNeedingYou: Int, scope: SessionFilter.Scope?, hasPlanProposals: Bool) -> String {
    let subject = hasPlanProposals ? "No session" : "Nothing"
    guard hiddenNeedingYou > 0, let scope else { return "\(subject) needs you" }
    return "\(subject) in these \(scope.selection) needs you"
  }

  /// The line under the empty Inbox's title. With no hidden sessions that need the user, it says what the Inbox lists.
  /// Otherwise it gives how many of those sessions the filter hides.
  static func emptyMessage(hiddenNeedingYou n: Int, scope: SessionFilter.Scope?) -> String {
    guard n > 0, let scope else { return "Sessions show here when they need an answer, an approval, or a decision." }
    let sessions = n == 1 ? "1 session" : "\(n) sessions"
    let need = n == 1 ? "needs" : "need"
    return switch scope {
    case .orgs: "\(sessions) in \(n == 1 ? "an org" : "orgs") the filter hides \(need) you."
    case .groups: "\(sessions) in \(n == 1 ? "a group" : "groups") the filter hides \(need) you."
    case .both: "\(sessions) that the filters hide \(need) you."
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
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @FocusState private var focused: Bool

  var body: some View {
    let items = model.triage
    let current = model.currentInboxItem
    let repos = model.repoLabels
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 2) {
          ForEach(Triage.sections(items)) { section in
            ListSectionHeader(title: section.title, count: section.sessions.count)
            ForEach(section.sessions) { s in
              TriageRow(session: s, repo: repos[s.id], current: s.id == current).id(s.id)
                .simultaneousGesture(TapGesture().onEnded { focused = true })
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
          if let id = model.currentInboxItem { proxy.scrollTo(id, reduceMotion: reduceMotion) }
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
        .help(session.state.title)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        InlineText(plain: session.inboxTitle, links: false).fontWeight(.medium).lineLimit(2)
        HStack(spacing: Spacing.xSmall) {
          if let group = Self.groupLabel(for: session) {
            // The caption beside the chip truncates first.
            GroupChip(name: group).layoutPriority(1)
          }
          Text(
            [repo, model.inboxName(session), ago(session.since)]
              .compactMap { $0 }.joined(separator: " · ")
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        }
      }
      Spacer(minLength: 0)
      if session.hasNewReply { NewReplyMark() }
      IssueBadge(session: session)
      NotesButton(session: session)
    }
    .listRowChrome(current: current, highlighted: session.isHighlighted)
    .hoverCard(session, activeAccount: model.activeAccountFolder, card: model.hoverCard)
    .onTapGesture { model.inboxFocus = session.id }
    .contextMenu { SessionMenuItems(session: session) }
    .accessibilityElement(children: .combine)
    .accessibilityValue(session.state.title)
    .highlightAccessibility(session.isHighlighted)
    .accessibilityAddTraits(current ? .isSelected : [])
  }

  /// The name of the session's group, or nil when the session has no group or is not a work session. A group chat's
  /// name already names its group.
  static func groupLabel(for session: SessionSummary) -> String? {
    guard session.kind == .work, let name = session.groupName, !name.isEmpty else { return nil }
    return name
  }
}

/// A group's name in a gray capsule on an Inbox row. A long name truncates at `maxTextWidth`, or sooner in a narrow
/// row.
struct GroupChip: View {
  static let maxTextWidth: CGFloat = 140
  let name: String

  var body: some View {
    ShrinkingCapLayout(limit: Self.maxTextWidth) {
      Text(verbatim: name).lineLimit(1).truncationMode(.tail)
    }
    .pill(.secondary)
    .help("Group: \(name)")
    .accessibilityLabel("Group \(name)")
  }
}

/// Sizes its one child to the narrowest of the child's natural width, `limit`, and the width its parent proposes.
/// `frame(maxWidth:)` would instead take the whole proposed width up to `limit`, so a short name would sit in a wide
/// capsule.
private struct ShrinkingCapLayout: Layout {
  let limit: CGFloat

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    guard let child = subviews.first else { return .zero }
    let natural = child.sizeThatFits(.unspecified)
    let width = min(limit, proposal.width ?? .infinity)
    if natural.width <= width { return natural }
    return child.sizeThatFits(ProposedViewSize(width: width, height: proposal.height))
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
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
