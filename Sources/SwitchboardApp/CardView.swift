import SwiftUI
import SwitchboardCore

/// A permission prompt or a question, answered without opening the session.
struct CardView: View {
  /// See SessionViewState for why this isn't `@State`.
  final class Draft: ObservableObject {
    @Published var message = ""
    /// The labels picked for each question, by the question's index.
    @Published var picks: [Int: Set<String>] = [:]
    /// Typed text for each question, which wins over its picks.
    @Published var typed: [Int: String] = [:]
  }

  @EnvironmentObject var model: BoardModel
  let card: Card
  @ObservedObject var draft: Draft

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if card.hookClosed {
        Label(
          card.kind == .permission
            ? "Claude Code stopped waiting on Switchboard. Your answer is typed into the terminal."
            : "Claude Code stopped waiting on Switchboard. Answering cancels the terminal's question and sends your answers as a message.",
          systemImage: "keyboard"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      if card.kind == .permission { permission } else { questions }
    }
    .disabled(model.answering.contains(card.id))
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: 8).fill(AttentionState.needsYou.color.opacity(0.07)))
    .overlay(RoundedRectangle(cornerRadius: 8).stroke(AttentionState.needsYou.color.opacity(0.35)))
  }

  private var permission: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Claude wants to use \(card.tool)").font(.headline)
      if let description = card.input["description"]?.string {
        Text(description).foregroundStyle(.secondary)
      }
      ScrollView {
        Text(card.details)
          .font(.body.monospaced())
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxHeight: 160)
      .fixedSize(horizontal: false, vertical: true)
      .padding(8)
      .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
      HStack {
        Button("Allow") { model.answer(card, behavior: "allow") }
          .buttonStyle(.borderedProminent)
        Button("Deny", action: deny)
        TextField("Message for Claude (optional)", text: $draft.message)
          .textFieldStyle(.roundedBorder)
          .onSubmit { if !draft.message.isEmpty { deny() } }
      }
      Text("Deny without a message stops the turn. With a message, Claude reads it and goes on.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private func deny() { model.answer(card, behavior: "deny", message: draft.message) }

  private var questions: some View {
    VStack(alignment: .leading, spacing: 14) {
      if card.deferred {
        Label("Claude stopped waiting for this answer. Answering resumes the session.", systemImage: "moon.zzz")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      ForEach(Array(card.questions.enumerated()), id: \.offset) { i, q in
        VStack(alignment: .leading, spacing: 6) {
          HStack(spacing: 6) {
            if let header = q.header {
              Text(header)
                .font(.caption.bold())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(AttentionState.needsYou.color.opacity(0.18)))
            }
            Text(q.question).fontWeight(.medium)
            if q.multiSelect { Text("pick any").font(.caption).foregroundStyle(.secondary) }
          }
          ForEach(q.options, id: \.label) { option in
            Button {
              pick(i, option.label, multiSelect: q.multiSelect)
            } label: {
              HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: icon(i, option.label, multiSelect: q.multiSelect))
                  .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                  Text(option.label)
                  if let description = option.description {
                    Text(description).font(.caption).foregroundStyle(.secondary)
                  }
                }
              }
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(draft.picks[i]?.contains(option.label) == true ? .isSelected : [])
          }
          TextField(
            "Or type an answer",
            text: Binding(get: { draft.typed[i] ?? "" }, set: { draft.typed[i] = $0 })
          )
          .textFieldStyle(.roundedBorder)
          .frame(maxWidth: 360)
        }
      }
      Button("Answer") { model.answer(card, answers: answers) }
        .buttonStyle(.borderedProminent)
        .disabled(answers.contains(where: \.isEmpty))
    }
  }

  private func pick(_ i: Int, _ label: String, multiSelect: Bool) {
    var picked = draft.picks[i] ?? []
    if multiSelect {
      if picked.remove(label) == nil { picked.insert(label) }
    } else {
      picked = [label]
    }
    draft.picks[i] = picked
    draft.typed[i] = nil
  }

  private func icon(_ i: Int, _ label: String, multiSelect: Bool) -> String {
    let on = draft.picks[i]?.contains(label) == true
    return multiSelect ? (on ? "checkmark.square.fill" : "square") : (on ? "largecircle.fill.circle" : "circle")
  }

  /// One answer per question: its typed text, or its picks in the options' order.
  private var answers: [String] {
    card.questions.enumerated().map { i, q in
      let typed = (draft.typed[i] ?? "").trimmingCharacters(in: .whitespaces)
      if !typed.isEmpty { return typed }
      let picked = draft.picks[i] ?? []
      return q.options.map(\.label).filter(picked.contains).joined(separator: ", ")
    }
  }
}
