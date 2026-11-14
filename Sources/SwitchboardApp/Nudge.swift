import SwiftUI
import SwitchboardCore

/// The message that a Board card's Nudge button drafts, which asks the
/// reviewers to review the PR. It says what the PR does and why the
/// reviewers are the ones asked. It never says how long the PR waited.
enum Nudge {
  /// How long a PR waits in review before its card offers Nudge, in milliseconds.
  static let delay: Int64 = 4 * 3_600_000
  /// The most changed lines for which the nudge calls the PR a small one.
  static let smallLines = 100

  /// Whether the card offers Nudge: its PR has waited in review for `delay`,
  /// or its author answered the change requests `delay` ago.
  static func shows(_ s: SessionSummary, now: Int64) -> Bool {
    guard let board = s.board, let pr = s.pr, !MergeBoard.isDone(s) else { return false }
    switch board.column {
    case .inReview: return now - board.since >= delay
    case .waiting: return pr.rereview.map { now - $0.repliedAt >= delay } ?? false
    default: return false
    }
  }

  /// The nudge for the session's PR, or nil while the card offers no Nudge.
  static func text(for s: SessionSummary, now: Int64) -> String? {
    guard shows(s, now: now), let pr = s.pr, let board = s.board else { return nil }
    if board.column == .waiting, let rereview = pr.rereview { return rereviewText(pr: pr, rereview: rereview) }
    return text(pr: pr, reviewers: board.reviewers ?? [])
  }

  /// The ask, what the PR does, its size, and the code owner reason, then
  /// the link, because Slack does not link `#N`.
  static func text(pr: PRSummary, reviewers: [String]) -> String {
    let addressees = reviewers.map { mention($0, pr: pr) }
    let title = pr.gist == nil && !pr.title.isEmpty ? " (\(pr.title))" : ""
    let subject = "#\(pr.number)\(title)"
    let ask: String
    switch addressees.count {
    case 0: ask = "Could I get a review of \(subject)?"
    case 1 where addressees[0].contains("/"): ask = "Could someone from \(addressees[0]) review \(subject)?"
    case 1: ask = "\(addressees[0]) could you review \(subject)?"
    default: ask = "\(englishList(addressees)), could one of you review \(subject)?"
    }
    let parts = [
      ask, pr.gist, isSmall(pr) ? "This is a small one." : nil, codeOwnerSentence(addressees, pr: pr), pr.url,
    ]
    return parts.compactMap { $0 }.joined(separator: " ")
  }

  /// The nudge for reviewers who requested changes that the author answered.
  /// It says nothing about the PR itself, because those reviewers know it.
  static func rereviewText(pr: PRSummary, rereview: Rereview) -> String {
    let mentions = rereview.reviewers.map { mention($0, pr: pr) }
    let who = mentions.count > 1 ? "\(englishList(mentions))," : englishList(mentions)
    let ask = who.isEmpty ? "Could you" : "\(who) could you"
    return "\(ask) take another look at #\(pr.number)? Ready for a re-review (I replied to the feedback). \(pr.url)"
  }

  static func isSmall(_ pr: PRSummary) -> Bool {
    guard let additions = pr.additions, let deletions = pr.deletions else { return false }
    return additions + deletions <= smallLines
  }

  /// Says that the PR needs the addressees' approval as code owners, or nil
  /// when no addressee owns a group that still waits for approval.
  static func codeOwnerSentence(_ addressees: [String], pr: PRSummary) -> String? {
    let asked = addressees.filter { needsApproval(pr, from: $0) }
    guard !asked.isEmpty else { return nil }
    let groups = waitingOwnerGroups(pr).filter { g in asked.contains { g.contains($0.lowercased()) } }
    guard asked.count == addressees.count, groups.count == 1 else {
      return "It needs code-owner approval from \(englishList(asked))."
    }
    if asked.count > 1 { return "It needs a code-owner approval from one of you." }
    return asked[0].contains("/")
      ? "It needs a code-owner approval from your team." : "It needs your code-owner approval."
  }

  /// Whether a code owner group that `owner` belongs to still waits for approval.
  static func needsApproval(_ pr: PRSummary, from owner: String) -> Bool {
    waitingOwnerGroups(pr).contains { $0.contains(owner.lowercased()) }
  }

  /// The owners of each code owner group that still waits for approval, lowercased.
  private static func waitingOwnerGroups(_ pr: PRSummary) -> [Set<String>] {
    (pr.codeOwners?.groups ?? []).filter { !$0.approved }.map { Set($0.owners.map { $0.lowercased() }) }
  }

  /// The reviewer as GitHub mentions it. sbd does not record whether a bare
  /// name from a review request is a login or a team's slug. It counts as a
  /// team only when a code owner group names that team in the repo's org,
  /// because GitHub asks only teams of the repo's own org.
  static func mention(_ reviewer: String, pr: PRSummary) -> String {
    if reviewer.hasPrefix("@") { return reviewer }
    if reviewer.contains("/") { return "@\(reviewer)" }
    let org = pr.repo.split(separator: "/").first.map(String.init) ?? ""
    let team = "@\(org)/\(reviewer)".lowercased()
    let owners = pr.codeOwners?.groups.flatMap(\.owners) ?? []
    return owners.contains { $0.lowercased() == team } ? "@\(org)/\(reviewer)" : "@\(reviewer)"
  }

  /// Each team that two or more In review cards with Nudge ask to review, by
  /// mention, with those cards in board order.
  static func teams(_ sessions: [SessionSummary], now: Int64) -> [TeamNudge] {
    var teams: [TeamNudge] = []
    for s in MergeBoard.cards(sessions, in: .inReview) where shows(s, now: now) {
      guard let pr = s.pr else { continue }
      for reviewer in s.board?.reviewers ?? [] {
        let team = mention(reviewer, pr: pr)
        guard team.contains("/") else { continue }
        if let i = teams.firstIndex(where: { $0.id == team.lowercased() }) {
          if teams[i].sessions.last?.id != s.id { teams[i].sessions.append(s) }
        } else {
          teams.append(TeamNudge(mention: team, sessions: [s]))
        }
      }
    }
    return teams.filter { $0.sessions.count > 1 }.sorted { $0.id < $1.id }
  }

  /// One message that asks the team to review each of its PRs, with a line per PR.
  static func allText(_ team: TeamNudge) -> String {
    let needs = team.sessions.map { s in s.pr.map { needsApproval($0, from: team.mention) } ?? false }
    let everyOne = needs.allSatisfy { $0 }
    var intro = "Could someone from \(team.mention) review these \(team.sessions.count) PRs?"
    if everyOne { intro += " Each needs a code-owner approval from your team." }
    let lines = zip(team.sessions, needs).compactMap { s, need -> String? in
      guard let pr = s.pr else { return nil }
      let lead = pr.gist.map(MergeDetails.lead) ?? pr.title
      let note = need && !everyOne ? "Needs your code-owner approval." : nil
      return "- "
        + ["#\(pr.number):", lead, note, pr.url].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
    }
    return ([intro, ""] + lines).joined(separator: "\n")
  }
}

/// The In review cards that ask one team to review them.
struct TeamNudge: Identifiable {
  var mention: String
  var sessions: [SessionSummary]

  var id: String { mention.lowercased() }
}

extension SessionSummary {
  var nudgeButtonLabel: String { "Draft a nudge for \(prOfSession)" }
}

extension BoardLayout {
  /// Every card that a lane shows.
  var cards: [SessionSummary] { lanes.flatMap { $0.cells.joined() } }
}

/// A nudge that the user can edit before copying it. Each open starts from
/// the generated text.
struct NudgeDraftView: View {
  let title: String
  let generated: String
  @State private var text: String

  init(title: String, generated: String) {
    self.title = title
    self.generated = generated
    _text = State(initialValue: generated)
  }

  static func showsReset(text: String, generated: String) -> Bool { text != generated }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title).font(.caption.bold()).foregroundStyle(.secondary)
      DraftEditor(text: $text, editable: true, accessibilityLabel: title)
      if Self.showsReset(text: text, generated: generated) {
        Button("Use the generated text") { text = generated }
      }
    }
    .padding(12)
    .frame(width: 380)
  }
}

/// Opens the card's nudge for editing and copying.
struct NudgeButton: View {
  let session: SessionSummary
  @State private var presented = false

  var body: some View {
    Button {
      presented.toggle()
    } label: {
      Image(systemName: "hand.wave")
    }
    .buttonStyle(.borderless)
    .foregroundStyle(.secondary)
    .accessibilityLabel(session.nudgeButtonLabel)
    .help("Draft a message that asks the reviewers to take a look")
    .popover(isPresented: $presented, arrowEdge: .bottom) {
      if let text = Nudge.text(for: session, now: nowMs()), let pr = session.pr {
        NudgeDraftView(title: "Nudge for #\(pr.number)", generated: text)
      }
    }
  }
}

/// Offers one nudge per team for every In review PR that waits on it. It
/// shows nothing while no team has two such PRs.
struct NudgeAllMenu: View {
  let sessions: [SessionSummary]
  @State private var chosen: TeamNudge?

  var body: some View {
    // The model republishes only when a session changes, so the timeline
    // shows the menu once the 4 hours pass on a board where nothing else changes.
    TimelineView(.everyMinute) { _ in
      let teams = Nudge.teams(sessions, now: nowMs())
      if !teams.isEmpty {
        Menu {
          ForEach(teams) { team in
            Button("Nudge \(team.mention) (\(team.sessions.count) PRs)…") { chosen = team }
          }
        } label: {
          Image(systemName: "hand.wave")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(.secondary)
        .accessibilityLabel("Nudge a team")
        .help("Draft one message that asks a team to review every PR waiting on it")
      }
    }
    .popover(item: $chosen, arrowEdge: .bottom) { team in
      NudgeDraftView(title: "Nudge \(team.mention)", generated: Nudge.allText(team))
    }
  }
}
