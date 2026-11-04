import SwiftUI
import SwitchboardCore

/// See SessionViewState for why this isn't `@State`.
final class DocketViewState: ObservableObject {
  @Published var confirmingRemove = false
  @Published var log: [Event] = []
}

/// A docket row, which has no terminal: its review's state and the log of
/// what sbd read from docket, newest first.
struct DocketView: View {
  @EnvironmentObject var model: BoardModel
  let session: SessionSummary
  let docket: DocketSummary
  @StateObject private var ui = DocketViewState()

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 8) {
            Text(session.name).font(.title3.bold()).textSelection(.enabled)
            StateBadge(state: session.state)
          }
          Text(session.reason).foregroundStyle(.secondary)
        }
        Spacer()
        if let url = URL(string: docket.url) {
          Button("Open PR") { NSWorkspace.shared.open(url) }
        }
        if let notes = docket.review?.notesPath, FileManager.default.fileExists(atPath: notes) {
          Button("Open Notes") { NSWorkspace.shared.open(URL(fileURLWithPath: notes)) }
        }
        Button(role: .destructive) {
          ui.confirmingRemove = true
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
          ForEach(ui.log.reversed(), id: \.id) { event in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
              Text(ago(event.t) + " ago").foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
              Text(DocketView.line(event.data)).textSelection(.enabled)
            }
          }
        }
        .font(.callout.monospaced())
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .padding(16)
    .task(id: docket) { await loadLog() }
    .confirmationDialog("Remove \(session.name)?", isPresented: $ui.confirmingRemove) {
      Button("Remove Row", role: .destructive) { model.remove(session.id) }
    } message: {
      Text("docket keeps the review. Open docket to abandon it.")
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
    let client = model.client
    let id = session.id
    let events = await Task.detached {
      (try? client.call("events", ["session": .string(id)], as: [Event].self)) ?? []
    }.value
    ui.log = events.filter { $0.kind == "docket" }
  }
}
