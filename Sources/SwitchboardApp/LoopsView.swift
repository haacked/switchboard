import SwiftUI
import SwitchboardCore

/// Every shown session's loops, with the current loop's prompt, status, and history on the right.
struct LoopsView: View {
  @EnvironmentObject var model: BoardModel

  var body: some View {
    // A loop turns overdue with the time alone, while sbd's `ls` answer stays the same.
    TimelineView(.everyMinute) { context in
      let now = nowMs()
      VStack(spacing: 0) {
        loops(now: now)
        Divider()
        BackgroundActivitySection(now: now)
          .task(id: ActivityLoad(tick: context.date, operatorID: model.operatorSession?.id)) {
            model.loadBackgroundActivity()
          }
      }
    }
  }

  /// When the activity list reads the operator's events again: on each minute, and when the operator first appears.
  private struct ActivityLoad: Equatable {
    var tick: Date
    var operatorID: String?
  }

  @ViewBuilder private func loops(now: Int64) -> some View {
    let rows = model.loopRows(now: now)
    if rows.isEmpty {
      let hidden = model.hiddenLoopCount
      ContentUnavailableView {
        Label("No loops", systemImage: MainView.loops.symbol)
      } description: {
        if hidden > 0 {
          Text("The filter hides \(hidden) loop\(hidden == 1 ? "" : "s"). They keep running.")
        } else {
          Text("A loop sends a prompt to a session on an interval. New Loop… or `sb schedule` adds one.")
        }
      } actions: {
        if hidden > 0 { Button("Show All") { model.showAll() } }
        NewLoopButton()
      }
    } else {
      ListDetailSplit(widthKey: "listWidth.loops") {
        VStack(spacing: 0) {
          LoopListHeader()
          Divider()
          LoopRows(rows: rows, now: now)
        }
      } detail: {
        if let row = model.currentLoop(in: rows) {
          // The pane focuses the loop it shows. A pause that moves the loop in the order then keeps it here.
          LoopDetail(row: row, now: now).id(row.id)
            .onAppear { if model.loopFocus != row.id { model.loopFocus = row.id } }
        }
      }
    }
  }
}

/// Opens the loop editor for a new loop.
private struct NewLoopButton: View {
  @EnvironmentObject var model: BoardModel

  var body: some View {
    Button("New Loop…") { model.loopEditor = .new }
      .help("Add a loop that sends a prompt to a session on an interval")
  }
}

/// The session filter, the sort menu, and New Loop….
private struct LoopListHeader: View {
  @EnvironmentObject var model: BoardModel

  var body: some View {
    HStack(spacing: 6) {
      Picker("Session", selection: Binding(get: { model.loopSessionChoice }, set: { model.loopSessionFilter = $0 })) {
        Text("All Sessions").tag(String?.none)
        Divider()
        ForEach(model.loopSessions) { Text($0.nameWithHost).tag(Optional($0.id)) }
      }
      .pickerStyle(.menu)
      .labelsHidden()
      .help("Show the loops of one session, or of every session")
      Menu {
        Picker("Sort", selection: $model.loopSort) {
          ForEach(LoopSort.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .pickerStyle(.inline)
      } label: {
        Image(systemName: "arrow.up.arrow.down")
      }
      .menuIndicator(.hidden)
      .fixedSize()
      .help("Sort the loops by status or by session. The loops that need attention stay on top")
      .accessibilityLabel("Sort")
      Spacer(minLength: 0)
      NewLoopButton().fixedSize()
    }
    .padding(.horizontal, Design.listInset)
    .padding(.vertical, 8)
  }
}

/// The loops, one row each. j and k move around the ends, ↓ and ↑ stop at them, and Return opens the loop's
/// session.
private struct LoopRows: View {
  @EnvironmentObject var model: BoardModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @FocusState private var focused: Bool
  let rows: [LoopRow]
  let now: Int64

  var body: some View {
    let current = model.currentLoop(in: rows)?.id
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 2) {
          ForEach(rows) { row in
            LoopListRow(row: row, now: now, current: row.id == current).id(row.id)
              .simultaneousGesture(TapGesture().onEnded { focused = true })
          }
        }
        .padding(.vertical, 6)
      }
      .listKeys(.loops, $focused, model: model) {
        model.moveLoop(by: $0, wrap: $1)
      } open: {
        if let row = model.currentLoop { model.showLoopSession(row.session) }
      }
      .onChange(of: model.loopJumps) {
        if let id = model.currentLoop?.id { proxy.scrollTo(id, reduceMotion: reduceMotion) }
      }
    }
  }
}

private struct LoopListRow: View {
  @EnvironmentObject var model: BoardModel
  let row: LoopRow
  let now: Int64
  let current: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      LoopSessionLink(row: row)
      ScheduleItem(schedule: row.schedule, caption: row.caption(now: now))
    }
    .listRowChrome(current: current)
    .onTapGesture { model.loopFocus = row.id }
    .accessibilityAddTraits(current ? .isSelected : [])
  }
}

/// The loop's session name, and its host when it has one, as a link that selects the session. The operator's link
/// opens its transcript.
private struct LoopSessionLink: View {
  @EnvironmentObject var model: BoardModel
  let row: LoopRow

  var body: some View {
    Button(row.session.nameWithHost) { model.showLoopSession(row.session) }
      .buttonStyle(.link)
      .font(.caption)
      .lineLimit(1)
      .help(row.session.kind == .operator ? "Open the operator's transcript" : "Open \(row.session.name)")
      .accessibilityLabel("\(row.session.nameWithHost), session of loop: \(oneLine(row.schedule.prompt))")
  }
}

/// The current loop: its session, status, actions, whole prompt, and recent runs, newest first.
private struct LoopDetail: View {
  let row: LoopRow
  let now: Int64

  var body: some View {
    let caption = row.caption(now: now)
    let history = row.schedule.history
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 6) {
        LoopSessionLink(row: row)
        ScheduleTiming(caption: caption)
        ScheduleActions(schedule: row.schedule, caption: caption)
      }
      .padding(12)
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          Text(row.schedule.prompt).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
          VStack(alignment: .leading, spacing: 4) {
            ListSectionHeader(title: "Recent Runs", count: history.count, inset: false)
            if history.isEmpty {
              Text("never ran").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(history.enumerated()), id: \.offset) { _, run in
              Text(run.text(now: now)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
          }
        }
        .padding(12)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}

/// The operator's work under the loops, newest first, with a button that opens its transcript. It has a fixed
/// height, so the loops keep most of the pane.
private struct BackgroundActivitySection: View {
  @EnvironmentObject var model: BoardModel
  let now: Int64

  static let height: CGFloat = 180

  var body: some View {
    let entries = model.backgroundActivity
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 6) {
        ListSectionHeader(title: "Background Activity", count: entries.count)
        Spacer(minLength: 0)
        Button("Transcript") { model.openOperator() }
          .fixedSize()
          .help("Open the operator's transcript")
          .padding(.trailing, 12)
      }
      if entries.isEmpty {
        Text("No background activity yet. Waits that your conversations hand off show here when they resolve.")
          .font(.caption).foregroundStyle(.secondary)
          .padding(.horizontal, 12)
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 6) {
            ForEach(entries) { BackgroundActivityRow(entry: $0, now: now) }
          }
          .padding(.horizontal, 12)
          .padding(.bottom, 8)
        }
      }
    }
    .frame(maxWidth: .infinity, minHeight: Self.height, maxHeight: Self.height, alignment: .topLeading)
  }
}

/// One activity entry: its time and text, and a link to the session that it is about while that session shows.
private struct BackgroundActivityRow: View {
  @EnvironmentObject var model: BoardModel
  let entry: BackgroundActivity.Entry
  let now: Int64

  var body: some View {
    let subject = entry.subject.flatMap { id in model.allSessions.first { $0.id == id && !$0.isBeingRemoved } }
    // A session that the filter hides would not open, so its name is plain text.
    let opens = subject.map { s in s.kind == .operator || model.sessions.contains { $0.id == s.id } } ?? false
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(verbatim: "\(ago(entry.t, now: now)) ago").font(.caption).foregroundStyle(.secondary)
        .monospacedDigit()
        .frame(width: 64, alignment: .trailing)
      InlineText(plain: entry.text).font(.callout).lineLimit(3).textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
      if let subject, opens {
        Button(subject.nameWithHost) { model.showLoopSession(subject) }
          .buttonStyle(.link)
          .font(.caption)
          .lineLimit(1)
          .frame(maxWidth: 200, alignment: .trailing)
          .help("Open \(subject.name)")
      } else if let subject {
        Text(subject.nameWithHost).font(.caption).foregroundStyle(.secondary).lineLimit(1)
          .frame(maxWidth: 200, alignment: .trailing)
          .help("The filter hides \(subject.name)")
      }
    }
  }
}

/// The Output… sheet: the log of one run of a headless or script loop, with a picker for the loop's other kept runs.
/// The picker names each run by its time, which names its log, so a run that lands while the sheet is open doesn't
/// move the selection to another run. A command can print escape sequences, so the log shows each control character
/// as an escape.
struct LoopOutputSheet: View {
  @EnvironmentObject var model: BoardModel
  let output: LoopOutput
  /// The loop, or nil when it is gone.
  let schedule: Schedule?

  var body: some View {
    let history = schedule?.history ?? []
    let gone = output.t != nil && output.shownRun(in: history) == nil
    VStack(alignment: .leading, spacing: 12) {
      Text("Output").font(.title2.bold())
      if let schedule {
        Text(verbatim: schedule.whatText.printable).foregroundStyle(.secondary).lineLimit(2)
      }
      Picker(
        "Run",
        selection: Binding(
          get: { output.t },
          set: { t in
            if let i = history.firstIndex(where: { $0.t == t }) { model.loadScheduleLog(output.schedule, run: i + 1) }
          })
      ) {
        ForEach(Array(history.enumerated()), id: \.offset) { _, run in Text(verbatim: run.text()).tag(Optional(run.t)) }
        if gone { Text("A run that the loop no longer keeps").tag(output.t) }
      }
      .help("The loop keeps the logs of its newest runs")
      .clickAnchor("loop-output-run")
      LoopOutputLog(output: output)
        .frame(maxWidth: .infinity, minHeight: 240, maxHeight: 420, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
        .clickAnchor("loop-output-text")
      if gone {
        Text("The loop no longer keeps this run. The log shows what the sheet read before.")
          .font(.caption).foregroundStyle(.secondary)
      }
      if output.truncated {
        Text("The run printed more than the log keeps, so the log stops at its cap.")
          .font(.caption).foregroundStyle(.secondary)
      }
      HStack {
        Spacer()
        Button("Done") { model.loopOutput = nil }
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(width: 640)
    .announcesRefusal(output.error)
  }

}

/// The log of one run in the Output… sheet. It reads only the output, so a change elsewhere in the model doesn't draw
/// the log again.
struct LoopOutputLog: View {
  let output: LoopOutput
  /// A log with more lines draws only the lines that scroll into view, and each line is selected on its own.
  static let wholeTextLines = 500

  var body: some View {
    if let error = output.error {
      Text(error).foregroundStyle(.red).textSelection(.enabled).padding(8)
    } else if let text = output.text {
      ScrollView {
        Group {
          if text.isEmpty {
            Text("The run printed nothing.")
          } else if output.lines.count <= Self.wholeTextLines {
            Text(verbatim: output.lines.joined(separator: "\n"))
          } else {
            LazyVStack(alignment: .leading, spacing: 0) {
              ForEach(output.lines.indices, id: \.self) { i in
                // An empty Text has no height, so a blank line holds a space.
                Text(verbatim: output.lines[i].isEmpty ? " " : output.lines[i])
              }
            }
          }
        }
        .font(.body.monospaced())
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
      }
    } else {
      ProgressView().padding(8).accessibilityLabel("Reading the log")
    }
  }
}
