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
      VStack(spacing: 12) {
        Image(systemName: "checkmark.circle").font(.system(size: 40)).foregroundStyle(.secondary)
        Text(model.planProposals.isEmpty ? "Nothing needs you" : "No session needs you").foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      HSplitView {
        TriageList()
          .frame(minWidth: 200, idealWidth: 280, maxWidth: 420)
        if let id = model.currentInboxItem, let session = model.sessions.first(where: { $0.id == id }) {
          TriageDetail(session: session).id(session.id)
            .frame(minWidth: 340, maxWidth: .infinity)
        } else {
          Text("Pick an item").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
    }
  }
}

/// One row for each session that needs you, then one for each that Claude
/// can continue. No Claude output appears here, only what the user does.
/// While the list has focus, j and k move to the next and previous item.
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
              Text("\(state.title) (\(group.count))")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 4)
              ForEach(group) { s in
                TriageRow(session: s, repo: repos[s.id], current: s.id == current).id(s.id)
                  .simultaneousGesture(TapGesture().onEnded { focused = true })
              }
            }
          }
        }
        .padding(.vertical, 6)
      }
      .focusable()
      .focused($focused)
      .focusEffectDisabled()
      .onKeyPress(characters: CharacterSet(charactersIn: "jk"), phases: .down) { press in
        model.moveInbox(by: press.characters == "j" ? 1 : -1)
        return .handled
      }
      .onAppear { focused = true }
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
    let item = session.triage
    HStack(alignment: .top, spacing: 8) {
      Circle()
        .fill(session.state.color)
        .frame(width: 8, height: 8)
        .padding(.top, 5)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(item?.title ?? session.reason).fontWeight(.medium).lineLimit(2)
        Text(
          [repo, session.name, ago(session.since)]
            .compactMap { $0 }.joined(separator: " · ")
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: 8).fill(current ? Color.accentColor.opacity(0.14) : Color.clear))
    .padding(.horizontal, 6)
    .contentShape(Rectangle())
    .onTapGesture { model.inboxFocus = session.id }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(current ? .isSelected : [])
  }
}
