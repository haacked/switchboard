import SwiftUI
import SwitchboardCore

/// The open GitHub issues from the configured sources, in buckets, with the selected issue on the right.
struct IssuesView: View {
  @EnvironmentObject var model: BoardModel

  var body: some View {
    VStack(spacing: 0) {
      if let list = model.issueList { IssueBanners(list: list) }
      content
    }
    .overlay(alignment: .bottom) { StartedIssueNotice() }
    .onAppear { model.refreshIssues() }
    .sheet(isPresented: $model.showingIssueSetup) { IssueSetupView().environmentObject(model) }
  }

  @ViewBuilder private var content: some View {
    if let list = model.issueList {
      if list.sources.isEmpty {
        ContentUnavailableView {
          Label("Pick the repositories you work in", systemImage: "smallcircle.filled.circle")
        } description: {
          Text("Issues lists open issues from the orgs and repositories you choose.")
        } actions: {
          Button("Add Sources…") { model.showingIssueSetup = true }
        }
      } else {
        // Computing the sections filters, groups, and sorts every issue. Each render computes them once.
        let sections = model.issueSections
        ListDetailSplit {
          VStack(spacing: 0) {
            IssueListHeader()
            Divider()
            if sections.isEmpty { IssuesNothingMatches(list: list) } else { IssueRows(sections: sections) }
          }
        } detail: {
          if let row = model.currentIssue {
            IssueDetail(row: row).id(row.id)
          } else {
            Text("Pick an issue").foregroundStyle(.secondary)
          }
        }
      }
    } else {
      IssueSkeleton()
    }
  }
}

/// The error and rate limit banners. The list below keeps the issues from the last good poll.
private struct IssueBanners: View {
  @EnvironmentObject var model: BoardModel
  let list: IssueList

  var body: some View {
    if let until = list.pausedUntil {
      WarningBanner(
        "GitHub's rate limit is spent. The next try is at \(clock(until)). Showing issues from \(list.polledAt.map(clock) ?? "the last poll")."
      )
    } else if let error = list.error {
      WarningBanner(error) { Button("Retry") { model.pollIssueSources() } }
    }
    if !list.sourceErrors.isEmpty {
      WarningBanner(
        list.sourceErrors.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: " ")
      ) {
        Button("Edit Sources…") { model.showingIssueSetup = true }
      }
    }
  }
}

/// The time of day of a time in ms, such as 14:00.
private func clock(_ ms: Int64) -> String {
  Date(timeIntervalSince1970: Double(ms) / 1000).formatted(date: .omitted, time: .shortened)
}

/// Mine, Team, and All, the sort and grouping menu, and the setup button.
private struct IssueListHeader: View {
  @EnvironmentObject var model: BoardModel

  var body: some View {
    HStack(spacing: 6) {
      Picker("Show", selection: $model.issueScope) {
        ForEach(IssueScope.allCases, id: \.self) { Text($0.title).tag($0) }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .help("Show issues assigned to you, your team's, or all of them")
      Menu {
        Picker("Sort", selection: $model.issueSort) {
          ForEach(IssueSort.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .pickerStyle(.inline)
        Toggle("Group by Repo", isOn: $model.issuesByRepo)
      } label: {
        Image(systemName: "arrow.up.arrow.down")
      }
      .menuIndicator(.hidden)
      .fixedSize()
      .help("Sort the issues, or group them by repository")
      .accessibilityLabel("Sort and group")
      Button {
        model.showingIssueSetup = true
      } label: {
        Image(systemName: "gearshape")
      }
      .buttonStyle(.borderless)
      .help("Choose the sources, your team, and the start preset")
      .accessibilityLabel("Issue sources")
    }
    .padding(8)
  }
}

/// The sections and their rows. j and k move around the ends, ↓ and ↑ stop at them, and Return starts the issue
/// with the last preset.
private struct IssueRows: View {
  @EnvironmentObject var model: BoardModel
  @FocusState private var focused: Bool
  let sections: [IssueSection]

  var body: some View {
    let current = model.currentIssue?.id
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 2) {
          ForEach(sections) { section in
            let collapsed = model.collapsedIssueSections.contains(section.id)
            Button {
              model.toggleIssueSection(section.id)
            } label: {
              ListSectionHeader(title: section.title, count: section.issues.count, collapsed: collapsed)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(section.title), \(section.issues.count), \(collapsed ? "collapsed" : "expanded")")
            if !collapsed {
              ForEach(section.issues) { row in
                IssueRow(row: row, current: row.id == current).id(row.id)
                  .simultaneousGesture(TapGesture().onEnded { focused = true })
              }
            }
          }
        }
        .padding(.vertical, 6)
      }
      .listKeys(.issues, $focused, model: model) {
        model.moveIssue(by: $0, wrap: $1)
      } open: {
        if let row = model.currentIssue { model.startIssue(row) }
      }
      .onChange(of: model.issueJumps) {
        if let id = model.currentIssue?.id { withAnimation { proxy.scrollTo(id) } }
      }
    }
  }
}

private struct IssueRow: View {
  @EnvironmentObject var model: BoardModel
  let row: ListedIssue
  let current: Bool

  var body: some View {
    let issue = row.issue
    let worked = row.bucket == .workedOn
    HStack(alignment: .top, spacing: 8) {
      VStack(alignment: .leading, spacing: 2) {
        Text(issue.title).fontWeight(.medium).lineLimit(2)
        Text([issue.ref, ago(isoMs(issue.updatedAt))].joined(separator: " · "))
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        if !issue.labels.isEmpty {
          Text(issue.labels.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
      }
      Spacer(minLength: 0)
      if let assignee = issue.assignees.first {
        Text(initials(assignee))
          .font(.caption2.bold())
          .frame(width: 22, height: 22)
          .background(Circle().fill(.quaternary))
          .help(issue.assignees.joined(separator: ", "))
      }
    }
    .opacity(worked ? 0.55 : 1)
    .listRowChrome(current: current)
    .onTapGesture {
      model.issueFocus = row.id
      if worked, let session = row.session { model.selection = session }
    }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(current ? .isSelected : [])
  }

  private func initials(_ login: String) -> String {
    let parts = login.split(whereSeparator: { $0 == "-" || $0 == "_" })
    return String(parts.prefix(2).compactMap(\.first)).uppercased()
  }
}

/// The time in ms of an ISO 8601 time from GitHub, or 0 when it doesn't parse.
private func isoMs(_ text: String) -> Int64 { Transcript.milliseconds(text) ?? 0 }

/// The selected issue: its title, labels, assignees, body, and Start.
private struct IssueDetail: View {
  @EnvironmentObject var model: BoardModel
  let row: ListedIssue

  var body: some View {
    let issue = row.issue
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 6) {
        Text(issue.title).font(.title3.bold()).textSelection(.enabled)
        HStack(spacing: 8) {
          if let url = URL(string: issue.url) {
            Link(destination: url) { Text(verbatim: issue.ref) }
          }
          Text("opened \(ago(isoMs(issue.createdAt))) ago · updated \(ago(isoMs(issue.updatedAt))) ago")
            .foregroundStyle(.secondary)
        }
        .font(.caption)
        if !issue.labels.isEmpty || !issue.assignees.isEmpty {
          Text(
            (issue.labels + issue.assignees.map { "@\($0)" }).joined(separator: " · ")
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
        if row.bucket == .workedOn, let session = row.session {
          Button("Open Session") { model.selection = session }
        } else {
          IssueStart(row: row)
        }
      }
      .padding(12)
      Divider()
      ScrollView {
        if issue.body.isEmpty {
          Text("No description").foregroundStyle(.secondary).padding(12)
        } else {
          MarkdownView(text: issue.body).padding(12)
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}

/// The Start split button, its menu, the group popup, and the error of the last Start.
struct IssueStart: View {
  @EnvironmentObject var model: BoardModel
  /// Read only so the button's title follows a Start from the list.
  @AppStorage(BoardModel.lastIssuePresetKey) private var lastPreset = ""
  let row: ListedIssue

  /// The last preset the user ran while it still exists, else config.json's default, else the first.
  static func preset(_ list: IssueList?, last: String) -> IssuePreset? {
    let presets = list?.presets ?? []
    return presets.first { $0.name == last } ?? presets.first { $0.name == list?.defaultPreset } ?? presets.first
  }

  var body: some View {
    let starting = model.startingIssues.contains(row.id)
    let presets = model.issueList?.presets ?? []
    let current = Self.preset(model.issueList, last: lastPreset)
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        Menu {
          ForEach(presets.filter { $0.name != current?.name }, id: \.name) { preset in
            Button("Start: \(preset.name)") { model.startIssue(row, preset: preset) }
          }
          Divider()
          Button("Edit the Prompt First…") {
            if let current { model.editIssuePrompt(row, preset: current) }
          }
          Button("Make a Follow-up Instead") { model.followUpIssue(row) }
          Button("Not Mine") { model.dismissIssue(row) }
        } label: {
          Label("Start: \(current?.name ?? "none")", systemImage: "play.fill")
        } primaryAction: {
          model.startIssue(row)
        }
        .fixedSize()
        .disabled(starting || current == nil)
        .keyboardShortcut(.return, modifiers: .command)
        .help("Start a session on the issue with this preset (⌘Return). The arrow offers the others")
        Picker("Group", selection: Binding(get: { model.issueGroup(row) }, set: { model.issueGroupPicks[row.id] = $0 }))
        {
          Text("No Group").tag(String?.none)
          ForEach(model.groups) { Text($0.name).tag(Optional($0.id)) }
        }
        .fixedSize()
        if starting { ProgressView().controlSize(.small) }
      }
      if let error = model.issueErrors[row.id] {
        VStack(alignment: .leading, spacing: 4) {
          Text(error).foregroundStyle(.red).font(.caption).textSelection(.enabled)
          if error.contains(Followup.missingCheckout) {
            HStack {
              Button("Clone \(row.issue.repo)") { model.cloneAndStart(row) }
              Button("Choose Folder…") {
                if let path = chooseFolder(message: "Choose the checkout of \(row.issue.repo)") {
                  model.startIssue(row, path: path)
                }
              }
            }
          }
        }
      }
    }
  }
}

/// After a Start, offers to open the new session for 8 seconds.
private struct StartedIssueNotice: View {
  @EnvironmentObject var model: BoardModel

  var body: some View {
    if let started = model.startedIssue {
      HStack(spacing: 12) {
        Text("Started \(started.name)")
        Button("Open Session") {
          model.startedIssue = nil
          model.selection = started.session
        }
        Button {
          model.startedIssue = nil
        } label: {
          Image(systemName: "xmark")
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Dismiss")
      }
      .padding(10)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
      .shadow(radius: 4)
      .padding(16)
      .task(id: started) {
        try? await Task.sleep(for: .seconds(8))
        if model.startedIssue == started { model.startedIssue = nil }
      }
    }
  }
}

/// The empty state when no issue matches the scope.
private struct IssuesNothingMatches: View {
  @EnvironmentObject var model: BoardModel
  let list: IssueList

  var body: some View {
    let teamUnassigned = model.issues.filter { $0.bucket == .teamUnassigned }.count
    let checked =
      list.polledAt.map { "\(list.sources.count) sources checked \(ago($0)) ago." }
      ?? "Checking \(list.sources.count) sources."
    VStack(spacing: 8) {
      Text(model.issueScope == .mine ? "Nothing assigned to you." : "No open issues.").font(.headline)
      Text(checked).foregroundStyle(.secondary)
      if model.issueScope == .mine, teamUnassigned > 0 {
        Text("Team has \(teamUnassigned) unassigned.").foregroundStyle(.secondary)
        Button("Show Team") { model.issueScope = .team }
      }
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

/// Rows of placeholder text while the first read of the issues runs.
private struct IssueSkeleton: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      ForEach(0..<6, id: \.self) { _ in
        VStack(alignment: .leading, spacing: 4) {
          Text("An open issue's title").fontWeight(.medium)
          Text("owner/name#1234 · 2d").font(.caption)
        }
      }
    }
    .redacted(reason: .placeholder)
    .padding(16)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .accessibilityLabel("Loading issues")
  }
}
