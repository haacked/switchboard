import SwiftUI
import SwitchboardCore

/// The overdue waits that raised an Inbox item, between the Summary and the
/// Drafts: what each wait is on, who set it and when, and its target's
/// current state, with Clear wait, Check now, and Open PR or Open thread.
struct WaitPanel: View {
  @EnvironmentObject var model: BoardModel
  @ObservedObject var store: ReferenceStore
  let session: SessionSummary
  /// The item's `overdueWaits`.
  let ids: [String]

  /// The state of a wait's target.
  enum Target: Equatable {
    case pullRequest(GitHubRef, ReferenceLoad)
    /// A PR kind whose repository the session gives no way to tell.
    case unresolved
    case session(AttentionState)
    /// The other session of a `session` wait is gone.
    case removed
    case time(Int64)
    /// A `reply` wait's Slack link and its thread's status, which is nil until sbd's poll reads or watches the thread.
    case thread(url: String, status: SlackThreadStatus?)
  }

  struct Row: Equatable, Identifiable {
    var id: String
    var kind: Wait.Kind
    var summary: String
    var then: Wait.Then
    var note: String?
    /// "Set 3h ago by you".
    var set: String
    /// When sbd rechecks the wait, or for a manual wait when it returns to Needs you.
    var recheck: Int64?
    var target: Target?
    var who: String?
    /// Whether GitHub still requests a review from `who`, or nil when the panel can't tell.
    var requested: Bool?
    var footnote: String?

    /// The PR that the panel reads for a PR kind.
    var pr: GitHubRef? {
      guard case .pullRequest(let pr, _)? = target else { return nil }
      return pr
    }

    /// The PR's pending review requests once it has loaded, with teams as slugs. Nil when GitHub's answer left
    /// them out.
    var reviewRequests: [String]? {
      guard case .pullRequest(_, .loaded(let details))? = target else { return nil }
      return details.reviewRequests
    }
  }

  static let deployFootnote = "sbd checks the deploy on its own"

  static let threadCheckHelp =
    "Read this thread first at sbd's next Slack poll. The wait resolves when the poll finds a reply from someone else."

  /// One row for each id that names a wait of `session`, in the order of `ids`. `reference` gives the loaded
  /// details of a PR by its ref. `sessions` holds every session, so a `session` wait's target can be found.
  static func rows(
    session: SessionSummary, ids: [String], sessions: [SessionSummary], reference: (GitHubRef) -> ReferenceLoad?,
    now: Int64
  ) -> [Row] {
    ids.compactMap { id in
      guard let wait = session.waits.first(where: { $0.id == id }) else { return nil }
      return row(wait, session: session, sessions: sessions, reference: reference, now: now)
    }
  }

  private static func row(
    _ wait: Wait, session: SessionSummary, sessions: [SessionSummary], reference: (GitHubRef) -> ReferenceLoad?,
    now: Int64
  ) -> Row {
    // A manual wait's summary is its note.
    var row = Row(
      id: wait.id, kind: wait.kind, summary: wait.summary, then: wait.then,
      note: wait.kind == .manual ? nil : wait.note,
      set: "Set \(ago(wait.created, now: now)) ago by \(wait.by.rawValue)",
      recheck: wait.kind == .manual ? wait.until : wait.recheck, who: wait.who)
    switch wait.kind {
    case .session:
      row.target = wait.session.map { target in
        sessions.first { $0.id == target.id }.map { .session($0.state) } ?? .removed
      }
    case .date, .manual:
      row.target = wait.until.map(Target.time)
    case .reply:
      row.target = wait.url.map { .thread(url: $0, status: wait.threadStatus) }
    case .ci, .review, .botReview, .approval, .queue, .merge, .deploy:
      guard let pr = pullRequest(of: wait, in: session) else {
        row.target = .unresolved
        break
      }
      let load = reference(pr) ?? .loading
      row.target = .pullRequest(pr, load)
      if case .loaded(let details) = load, wait.kind == .review || wait.kind == .approval {
        row.requested = wait.pendingReviewer(in: details.reviewRequests)
      }
      if wait.kind == .deploy { row.footnote = deployFootnote }
    }
    return row
  }

  /// The PR that a PR kind waits on: `wait.pr` in its own repository, or in the repository of the session's PR or
  /// the session's own, or the session's PR when the wait names none. Nil when no repository is known, because a
  /// guess would show another PR's state.
  private static func pullRequest(of wait: Wait, in session: SessionSummary) -> GitHubRef? {
    guard let pr = wait.pr else { return session.pr.flatMap { GitHubRef(repo: $0.repo, number: $0.number) } }
    guard let repo = pr.repository ?? session.pr?.repo ?? session.repository else { return nil }
    return GitHubRef(repo: repo, number: pr.number)
  }

  var body: some View {
    let rows = Self.rows(
      session: session, ids: ids, sessions: model.allSessions, reference: { store.details[$0.key] }, now: nowMs())
    // The user or sbd can clear every wait that the item names, and then the panel shows nothing, not even a refusal.
    if !rows.isEmpty {
      VStack(alignment: .leading, spacing: 8) {
        SectionTitle(text: rows.count == 1 ? "Overdue wait" : "Overdue waits")
        ForEach(rows) { WaitPanelRow(session: session, row: $0) }
        RefusalLabel(refusal: model.waitErrors[session.id])
      }
      .announcesRefusal(model.waitErrors[session.id])
    }
  }
}

/// One wait of the panel: its facts, its target's state, and its buttons.
private struct WaitPanelRow: View {
  @EnvironmentObject var model: BoardModel
  @Environment(\.openURL) private var openURL
  let session: SessionSummary
  let row: WaitPanel.Row

  var body: some View {
    let now = nowMs()
    VStack(alignment: .leading, spacing: 6) {
      InlineText(plain: (row.kind == .date ? "Waits " : "Waits on ") + row.summary).fontWeight(.semibold)
        .fixedSize(horizontal: false, vertical: true)
      Text(verbatim: WaitPanel.facts(row, now: now)).font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      if let note = row.note {
        InlineText(plain: "Note: \(note)").font(.callout).fixedSize(horizontal: false, vertical: true)
      }
      ForEach(WaitPanel.targetLines(row, now: now), id: \.self) { line in
        Text(verbatim: line).font(.callout).fixedSize(horizontal: false, vertical: true)
      }
      if case .pullRequest(_, .loading)? = row.target {
        HStack(spacing: 6) {
          ProgressView().controlSize(.small)
          Text("Loading the PR…").font(.caption).foregroundStyle(.secondary)
        }
      }
      if let footnote = row.footnote {
        Text(verbatim: footnote).font(.caption).foregroundStyle(.secondary)
      }
      WrappingRow(spacing: 8) {
        Button("Clear wait") { model.clearWait(session.id, wait: row.id) }
          .help("Ask sbd to drop this wait")
          .accessibilityLabel("Clear wait: \(row.summary)")
          .disabled(model.isClearingWait(session.id, row.id))
        if let pr = row.pr {
          Button("Check now") { model.checkReference(pr) }
            .help("Read the PR from GitHub again. The wait resolves at sbd's next poll.")
            .accessibilityLabel("Check now: \(pr.repo) #\(pr.number)")
          Button("Open PR") { openURL(pr.url) }
            .help("Open \(pr.repo) #\(pr.number) on GitHub")
        }
        if case .thread(let url, _)? = row.target {
          let title = LinkTarget.parse(url)?.title ?? "Slack thread"
          Button("Check now") { model.checkWait(session: session.id, wait: row.id) }
            .help(WaitPanel.threadCheckHelp)
            .accessibilityLabel("Check now: \(title)")
          if let link = URL(string: url) {
            Button("Open thread") { openURL(link) }
              .help("Open the thread in Slack")
              .accessibilityLabel("Open thread: \(title)")
          }
        }
      }
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .calloutChrome(.secondary)
    .task(id: row.pr?.key) { if let pr = row.pr { model.loadReference(pr) } }
  }
}

extension WaitPanel {
  /// Who set the wait and when, when its recheck is due, and what happens when it resolves.
  static func facts(_ row: Row, now: Int64) -> String {
    var parts = [row.set]
    if let recheck = row.recheck {
      let future = recheck > now
      let when = future ? fromNow(recheck, now: now) : "\(ago(recheck, now: now)) ago"
      let lead = row.kind == .manual ? "due" : future ? "rechecks" : "recheck was due"
      parts.append("\(lead) \(when)")
    }
    parts.append("\(row.then.outcome) when it resolves")
    return parts.joined(separator: " · ")
  }

  /// The state of the wait's target, one line each.
  static func targetLines(_ row: Row, now: Int64) -> [String] {
    switch row.target {
    case .pullRequest(let pr, let load)?:
      let content = ReferenceCardContent(pr, load: load, sessions: [], now: now)
      var lines: [String] = []
      if let chip = content.chip {
        lines.append(([chip.text] + content.prLines).joined(separator: " · "))
      }
      if let message = content.message { lines.append("\(pr.repo) #\(pr.number): \(message)") }
      if let requests = row.reviewRequests, !requests.isEmpty {
        lines.append("Pending review requests: \(requests.joined(separator: ", "))")
      }
      if let who = row.who.map(Wait.reviewerName), let requested = row.requested {
        lines.append(requested ? "Review still requested: \(who)" : "Review no longer requested: \(who)")
      }
      return lines
    case .unresolved?: return ["sbd can't tell which PR the wait is on."]
    case .session(let state)?: return ["Now in \(state.title)"]
    case .removed?: return ["The session was removed."]
    case .time(let t)?: return ["Due \(Wait.formatTime(t))"]
    case .thread(_, let status?)?: return [status.line(now: now)]
    case .thread(_, nil)?: return ["sbd hasn't read the thread yet"]
    case nil: return []
    }
  }
}
