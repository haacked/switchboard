import SwiftUI
import SwitchboardCore

/// The sessions that need you, oldest first. A session with a permission
/// prompt or a question shows its card. The others show their last reply and
/// a field for a reply.
struct QueueView: View {
  @EnvironmentObject var model: BoardModel

  var body: some View {
    if model.needsYou.isEmpty {
      VStack(spacing: 12) {
        Image(systemName: "checkmark.circle").font(.system(size: 40)).foregroundStyle(.secondary)
        Text("Nothing needs you").foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      let current = model.currentQueueItem
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(model.needsYou) { s in
              QueueItem(session: s, current: s.id == current).id(s.id)
            }
          }
          .padding()
        }
        .onChange(of: model.queueJumps) {
          if let id = model.currentQueueItem { withAnimation { proxy.scrollTo(id, anchor: .top) } }
        }
      }
    }
  }
}

struct QueueItem: View {
  @EnvironmentObject var model: BoardModel
  let session: SessionSummary
  /// The item that ⌘J moves on from.
  let current: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .top) {
        SessionRow(session: session)
        Button("Open") { model.selection = session.id }
      }
      if session.isNotStarted {
        // A follow-up whose trigger fired has no claude to message yet.
        Button("Start") { model.startFollowup(session.id) }
      } else if !session.cards.isEmpty {
        ForEach(session.cards) { CardView(card: $0, draft: model.draft(for: $0)) }
      } else if session.openPrompt {
        // A message would only queue behind the open dialog.
        Text("Claude Code's dialog waits in the terminal. Open the session to answer it.")
          .foregroundStyle(.secondary)
      } else {
        if let last = session.lastReply {
          Text(last).font(.callout).lineLimit(8).textSelection(.enabled)
        }
        MessageField(session: session.id)
      }
    }
    .padding(12)
    .background(RoundedRectangle(cornerRadius: 10).fill(current ? Color.accentColor.opacity(0.06) : Color.clear))
    .overlay(
      RoundedRectangle(cornerRadius: 10)
        .stroke(current ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: current ? 2 : 1)
    )
    .contentShape(Rectangle())
    .simultaneousGesture(TapGesture().onEnded { model.queueFocus = session.id })
  }
}
