import SwiftUI
import SwitchboardCore

/// A permission prompt, a question, or a group message, answered without opening the session.
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
      switch card.kind {
      case .permission: permission
      case .question: questions
      case .send: groupMessage
      }
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
      textBox(card.details, maxHeight: 160)
      HStack {
        Button("Allow") { model.answer(card, behavior: "allow") }
          .buttonStyle(.borderedProminent)
        if card.offersAutoMode {
          Button(PermissionMode.approveLabel) { model.answer(card, behavior: "allow", autoMode: true) }
            .help(PermissionMode.autoModeNote)
            .accessibilityHint(PermissionMode.autoModeNote)
        }
        Button("Deny", action: deny)
        TextField("Message for Claude (optional)", text: $draft.message)
          .textFieldStyle(.roundedBorder)
          .onSubmit { if !draft.message.isEmpty { deny() } }
      }
      Text("Deny without a message stops the turn. With a message, Claude reads it and goes on.")
        .font(.caption)
        .foregroundStyle(.secondary)
      if card.offersAutoMode {
        Text(PermissionMode.autoModeNote).font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  /// The text verbatim, in a box that scrolls past `maxHeight`.
  private func textBox(_ text: String, maxHeight: CGFloat) -> some View {
    ScrollView {
      Text(verbatim: text)
        .font(.body.monospaced())
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(maxHeight: maxHeight)
    .fixedSize(horizontal: false, vertical: true)
    .padding(8)
    .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
  }

  private func deny() { model.answer(card, behavior: "deny", message: draft.message) }

  /// Claude wrote the text. It can quote PR comments or logs, so it shows
  /// verbatim and is never read as Markdown.
  @ViewBuilder
  private var groupMessage: some View {
    if let message = card.send {
      VStack(alignment: .leading, spacing: 8) {
        // The Inbox lists other sessions' send cards in this session's pane.
        let asker = model.sessions.first { $0.id == card.session }?.name ?? card.session
        Text(verbatim: "\(asker) wants to send \(message.summary)").font(.headline)
        VStack(alignment: .leading, spacing: 2) {
          ForEach(message.targets, id: \.id) { target in
            HStack(spacing: 6) {
              Image(systemName: "arrow.turn.down.right").foregroundStyle(.secondary).accessibilityHidden(true)
              Text(verbatim: target.name)
              Text(verbatim: target.id).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
          }
        }
        textBox(message.text, maxHeight: 200)
        HStack {
          Button("Send") { model.answer(card, behavior: "allow") }
            .buttonStyle(.borderedProminent)
          Button("Cancel") { model.answer(card, behavior: "deny") }
          Spacer()
          HStack(spacing: 4) {
            Text("Expires in")
            Text(Date(timeIntervalSince1970: Double(message.expires) / 1000), style: .relative)
          }
          .font(.caption)
          .foregroundStyle(.secondary)
        }
        Text(
          "Nothing is sent until you send it. The text can quote PR comments or logs, so read it before you send it."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
  }

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

/// The session's open cards above its other content, followed by a divider, or nothing without cards.
struct CardList: View {
  @EnvironmentObject var model: BoardModel
  let cards: [Card]

  var body: some View {
    if !cards.isEmpty {
      // A card with several questions would otherwise squeeze out the content below it.
      ScrollView {
        VStack(spacing: 8) {
          ForEach(cards) { CardView(card: $0, draft: model.draft(for: $0)) }
        }
        .padding(8)
      }
      .frame(maxHeight: 360)
      .fixedSize(horizontal: false, vertical: true)
      Divider()
    }
  }
}
