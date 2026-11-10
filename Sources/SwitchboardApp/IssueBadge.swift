import SwiftUI
import SwitchboardCore

/// The first issue that a session works on, as `#174`, and how many more.
struct IssueBadge: View {
  let session: SessionSummary
  /// False on a Board card, whose whole label is a button.
  var linked = true

  static func label(for issues: [SessionIssue], prRepo: String?) -> String {
    guard let first = issues.first else { return "" }
    let label = first.label(from: prRepo)
    return issues.count > 1 ? "\(label) +\(issues.count - 1)" : label
  }

  static func tooltip(for issues: [SessionIssue], prRepo: String?) -> String {
    issues.map { "Issue \($0.label(from: prRepo)) (\($0.via.title))" }.joined(separator: "\n")
  }

  static func link(for issues: [SessionIssue]) -> URL? { issues.first?.link }

  var body: some View {
    let issues = session.issues ?? []
    let prRepo = session.pr?.repo
    if !issues.isEmpty {
      let label = Self.label(for: issues, prRepo: prRepo)
      Group {
        if linked, let url = Self.link(for: issues) {
          Link(destination: url) { Text(verbatim: label) }
        } else {
          Text(verbatim: label)
        }
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize()
      .help(Self.tooltip(for: issues, prRepo: prRepo))
      .accessibilityLabel("Issue \(label)")
    }
  }
}
