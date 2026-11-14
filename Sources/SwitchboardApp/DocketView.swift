import SwiftUI
import SwitchboardCore

/// A docket row, which has no terminal: its review's state and the log of
/// what sbd read from docket, newest first.
struct DocketView: View {
  @EnvironmentObject var model: BoardModel
  let session: SessionSummary
  let docket: DocketSummary
  @State private var removal: TodoDeletion?
  @State private var log: [Event] = []

  private var isConfirmingRemove: Binding<Bool> {
    Binding(get: { removal != nil }, set: { if !$0 { removal = nil } })
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 8) {
            Text(session.name).font(.title3.bold()).textSelection(.enabled)
            StateBadge(state: session.state)
          }
          InlineText(plain: session.reason).foregroundStyle(.secondary)
        }
        Spacer()
        if let url = docket.link {
          Button("Open PR") { NSWorkspace.shared.open(url) }
        }
        if let notes = docket.review?.notesPath, FileManager.default.fileExists(atPath: notes) {
          Button("Open Notes") { NSWorkspace.shared.open(URL(fileURLWithPath: notes)) }
        }
        Button(session.markedDone ? "Not Done" : "Done") { model.setDone(session.id, !session.markedDone) }
          .help(
            session.markedDone
              ? "Mark the row not done. sbd asks docket about it again"
              : "Mark the row done. It leaves the Inbox, and sbd stops asking docket about it")
        Button(role: .destructive) {
          removal = TodoDeletion(session)
        } label: {
          Image(systemName: "trash")
        }
        .help("Remove the row. docket keeps the review")
      }
      Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
        DetailRow(label: "Pull request", value: docket.pullRequest)
        if let title = docket.review?.title { DetailRow(label: "Title", value: title) }
        if let author = docket.review?.author { DetailRow(label: "Author", value: author) }
        if let notes = docket.review?.notesPath { DetailRow(label: "Notes", value: notes) }
        if let error = docket.review?.error, !error.isEmpty { DetailRow(label: "Error", value: error) }
      }
      .font(.callout)
      Divider()
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 4) {
          ForEach(log.reversed(), id: \.id) { event in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
              Text(ago(event.t) + " ago").foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
              InlineText(plain: DocketView.line(event.data)).textSelection(.enabled)
            }
          }
        }
        .font(.callout.monospaced())
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .padding(16)
    .task(id: docket) { await loadLog() }
    .confirmationDialog("Remove \(session.name)?", isPresented: isConfirmingRemove, presenting: removal) { todos in
      Button(todos.button("Remove Row"), role: .destructive) { model.remove(session.id, resolve: todos.ids) }
    } message: { todos in
      Text(
        model.sessionNames.replacingIDs(
          in: todos.message(before: "docket keeps the review. Open docket to abandon it.")))
    }
  }

  /// One `docket` event as a log line.
  static func line(_ data: JSON) -> String {
    var status = DocketStatus()
    status.apply(data)
    if let problem = status.problem { return "can't read docket: \(problem)" }
    if status.closed { return "docket closed the review" }
    let state = status.review?.state ?? "?"
    guard let detail = status.review?.progress?.detail, !detail.isEmpty else { return state }
    return "\(state) · \(detail)"
  }

  private func loadLog() async {
    log = await model.events(session.id, kind: "docket")
  }
}
