import SwiftUI
import SwitchboardCore
import Testing

@testable import SwitchboardApp

/// A work session in group `g1`, which sbd names `name`.
private func namedGroupSession(_ name: String?) -> SessionSummary {
  var s = needsItem("work")
  s.group = "g1"
  s.groupName = name
  return s
}

@Suite struct InboxRowGroupLabel {
  @Test func groupedWorkSessionShowsItsGroupName() {
    #expect(TriageRow.groupLabel(for: namedGroupSession("Billing")) == "Billing")
  }

  @Test func ungroupedSessionShowsNoGroup() {
    #expect(TriageRow.groupLabel(for: needsItem("work")) == nil)
  }

  /// A chat, the Manager, and the operator get no chip even if a later sbd change sends them a group name.
  @Test(arguments: [SessionKind.chat, .manager, .operator])
  func nonWorkSessionWithAGroupNameShowsNoGroup(_ kind: SessionKind) throws {
    var s = try #require(everyKind.first { $0.kind == kind })
    s.group = "g1"
    s.groupName = "Billing"

    #expect(TriageRow.groupLabel(for: s) == nil)
  }

  @Test func groupSetWithoutANameShowsNoGroup() {
    #expect(TriageRow.groupLabel(for: namedGroupSession(nil)) == nil)
  }

  @Test func emptyGroupNameShowsNoGroup() {
    #expect(TriageRow.groupLabel(for: namedGroupSession("")) == nil)
  }
}

@MainActor
@Suite struct InboxRowGroupLayout {
  static let longName = String(repeating: "Billing and invoices ", count: 3).trimmingCharacters(in: .whitespaces)
  /// The cap plus the small pill's 5 pt padding on each side.
  static let chipMaxWidth = GroupChip.maxTextWidth + 10

  func host(_ session: SessionSummary, width: CGFloat = 320) -> HostedView {
    HostedView(
      TriageRow(session: session, repo: "posthog", current: false)
        .environmentObject(offlineModel())
        .frame(width: width))
  }

  /// Whether some element's label contains `text`. The row combines its children for VoiceOver, so the chip's text
  /// reaches the row's label, not a static text of its own.
  func labels(_ hosted: HostedView, contain text: String) -> Bool {
    hosted.elements.contains { $0.label.contains(text) }
  }

  @Test(arguments: ["Billing", "*Billing*", "100% done"])
  func groupedRowNamesItsGroupVerbatim(_ name: String) {
    #expect(labels(host(namedGroupSession(name)), contain: "Group \(name)"))
  }

  @Test func ungroupedRowNamesNoGroup() {
    #expect(!labels(host(needsItem("work")), contain: "Group"))
  }

  @Test func longGroupNameTruncatesTheChip() {
    #expect(idealWidth(GroupChip(name: Self.longName)) <= Self.chipMaxWidth)
  }

  @Test func longGroupNameShrinksBelowTheCapInANarrowRow() {
    #expect(fittedWidth(of: GroupChip(name: Self.longName), offered: 60) <= 60)
  }

  @Test func shortGroupNameKeepsItsOwnWidth() {
    let full = idealWidth(Text(verbatim: "Billing").pill(.secondary))
    let chip = GroupChip(name: "Billing")

    #expect(idealWidth(chip) >= full - 1)
    #expect(fittedWidth(of: chip, offered: 300) <= full + 1)
  }

  @Test func longGroupNameStillNamesTheWholeGroup() {
    #expect(labels(host(namedGroupSession(Self.longName), width: 200), contain: "Group \(Self.longName)"))
  }
}
