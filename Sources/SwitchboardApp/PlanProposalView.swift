import SwiftUI
import SwitchboardCore

/// The plan updates and new plan rows that wait for the user, each with its
/// diff and Apply and Reject.
struct PlanProposalList: View {
  @EnvironmentObject var model: BoardModel
  let proposals: [PlanProposal]

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 8) {
        ForEach(proposals) { PlanProposalCard(proposal: $0) }
      }
      .padding(8)
    }
    .frame(maxHeight: 320)
    .fixedSize(horizontal: false, vertical: true)
  }
}

struct PlanProposalCard: View {
  @EnvironmentObject var model: BoardModel
  let proposal: PlanProposal

  private var verbs: (apply: String, reject: String) {
    proposal.kind == .update ? ("Apply", "Reject") : ("Accept", "Decline")
  }

  private var groupName: String? {
    proposal.group.map { id in model.groups.first { $0.id == id }?.name ?? id }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        Image(systemName: proposal.kind == .update ? "doc.text" : "plus.rectangle.on.rectangle")
          .foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 2) {
          Text(proposal.title).fontWeight(.medium)
          Text([groupName, proposal.source.text].compactMap { $0 }.joined(separator: " · "))
            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
        Spacer()
        Button(verbs.apply) { model.applyProposal(proposal.id) }
          .accessibilityLabel("\(verbs.apply): \(proposal.title) in \(proposal.source.text)")
        Button(verbs.reject) { model.rejectProposal(proposal.id) }
          .accessibilityLabel("\(verbs.reject): \(proposal.title) in \(proposal.source.text)")
      }
      VStack(alignment: .leading, spacing: 2) {
        ForEach(Array(proposal.edits.enumerated()), id: \.offset) { _, edit in
          if let old = edit.old { line("- " + old, .red) }
          line("+ " + edit.new, .green)
        }
      }
    }
    .padding(10)
    .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    .disabled(model.answeringProposals.contains(proposal.id))
    .accessibilityElement(children: .contain)
    .accessibilityLabel(proposal.title)
    .accessibilityIdentifier("proposal-\(proposal.id)")
  }

  private func line(_ text: String, _ color: Color) -> some View {
    Text(text)
      .font(.system(.caption, design: .monospaced))
      .foregroundStyle(color)
      .textSelection(.enabled)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}
