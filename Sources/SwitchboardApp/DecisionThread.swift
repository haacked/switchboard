import SwiftUI
import SwitchboardCore

/// What a decision's dot shows about the questions asked about it.
enum DecisionThreadMark: Equatable, Sendable {
  /// The user asked about the decision, and no question waits for its answer.
  case asked
  /// The session is answering a question about the decision.
  case answering
}

extension DecisionList {
  /// The questions about decision `number` and their answers, oldest first.
  func exchanges(about number: Int) -> [DecisionExchange] { exchanges.filter { $0.number == number } }

  /// The mark of each decision that the user asked about, by decision number.
  var threadMarks: [Int: DecisionThreadMark] {
    exchanges.reduce(into: [:]) { marks, x in
      if x.pending { marks[x.number] = .answering } else if marks[x.number] == nil { marks[x.number] = .asked }
    }
  }

  /// Why Ask is off, or nil. The answers, Submit, and Discard show `pendingAskReason`, which is sbd's refusal.
  /// sbd also refuses an ask about a stale list.
  var askOffReason: String? {
    if let pendingAsk { return "The session is still answering your question about decision \(pendingAsk)" }
    return stale ? "The session took a turn since these decisions. Send your question as a message instead" : nil
  }
}

/// One decision's questions to the session and its answers, with a field to ask another. sbd sends the question to
/// the session, and the answer comes from the turn it starts.
struct DecisionThread: View {
  enum Placement: Equatable, Sendable { case beside, under }

  /// The thread's column beside the options, with the gap and the divider before it.
  static let width: CGFloat = 300
  /// The narrowest the options get with the thread beside them.
  static let optionsMinWidth: CGFloat = 340
  static let caption = "The session answers in its own conversation."

  /// The thread goes beside the options when the step holds both at their widths, and under them otherwise.
  static func placement(width: CGFloat) -> Placement {
    width >= optionsMinWidth + Self.width ? .beside : .under
  }

  @EnvironmentObject var model: BoardModel
  let session: String
  let list: DecisionList
  let decision: Int
  @ObservedObject var draft: MessageField.Draft
  var focus: FocusState<DecisionFocus?>.Binding

  var body: some View {
    let reason = list.askOffReason
    VStack(alignment: .leading, spacing: 10) {
      Text("Ask about this decision").font(.subheadline.weight(.semibold)).accessibilityAddTraits(.isHeader)
      ForEach(list.exchanges(about: decision), id: \.askId) { exchange($0) }
      HStack(alignment: .bottom) {
        TextField("Ask the session a question", text: $draft.text, axis: .vertical)
          .textFieldStyle(.roundedBorder)
          .focused(focus, equals: .ask)
          .sendsOnReturn(send)
          .onExitCommand { focus.wrappedValue = .steps }
          .accessibilityLabel("Question about decision \(decision)")
        Button("Ask", action: send)
          .disabled(!canAsk)
          .help(reason ?? "Sends the question to the session (Return)")
          .accessibilityLabel("Ask the session about decision \(decision)")
          .accessibilityHint(reason ?? "")
      }
      if let reason {
        PendingAskNote(reason: reason, systemImage: list.pendingAsk == nil ? "info.circle" : "hourglass")
      }
      Text(Self.caption).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var canAsk: Bool {
    !ReplyOption.trimmed(draft.text).isEmpty && list.askOffReason == nil
      && !model.deciding.contains("\(session)/ask")
  }

  private func exchange(_ exchange: DecisionExchange) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      InlineText(plain: exchange.text).fontWeight(.medium).textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel("You asked: \(exchange.text)")
      if exchange.pending {
        HStack(spacing: 6) {
          ProgressView().controlSize(.small)
          Text("Claude is answering…").foregroundStyle(.secondary)
        }
      } else if let reply = exchange.reply {
        MarkdownView(text: reply).font(.callout)
      } else if let error = exchange.error {
        Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
      }
    }
    .padding(.leading, 10)
    .overlay(alignment: .leading) { QuoteBar() }
    .accessibilityElement(children: .contain)
  }

  /// Return sends too, so the checks of the Ask button apply here as well.
  private func send() {
    guard canAsk else { return }
    Self.submit($draft.text, session: session, ref: list.ref, decision: decision, to: model)
  }

  /// Asks the trimmed text, as a reply option sends its text.
  static func submit(_ text: Binding<String>, session: String, ref: String, decision: Int, to model: BoardModel) {
    ReplyOption.submit(text) { model.askDecision(session, ref: ref, number: decision, text: $0, asked: $1) }
  }
}

/// Why a control of the step view is off while a question about a decision waits for its answer.
struct PendingAskNote: View {
  let reason: String
  var systemImage = "hourglass"

  var body: some View {
    Label("\(reason).", systemImage: systemImage).font(.callout).foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
  }
}
