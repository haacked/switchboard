import SwiftUI
import SwitchboardCore

/// What has the keyboard in the step view: the view itself, whose keys
/// move through the steps, or the Other answer field.
enum DecisionFocus: Hashable {
  case steps, other
}

/// The Inbox card's decisions, one step at a time, with a strip of dots that
/// works as tabs and a Review step that submits every answer in one message.
/// The answers live in sbd. The view sends each one as the user gives it.
struct DecisionStepView: View {
  @EnvironmentObject var model: BoardModel
  let session: SessionSummary
  let list: DecisionList
  @Binding var step: DecisionStep?
  @FocusState private var focus: DecisionFocus?
  @State private var confirmingStale = false
  @State private var confirmingDiscard = false
  @State private var confirmingNewer = false
  @State private var finishingFirst = false

  private var steps: DecisionSteps { DecisionSteps(list) }
  private var current: DecisionStep { steps.resolve(step) }
  private var decision: PendingDecision? {
    guard case .decision(let n) = current else { return nil }
    return list.decisions.first { $0.number == n }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if !list.newer.isEmpty, !finishingFirst { newerBanner }
      DecisionDots(list: list, current: current) { step = $0 }
      Divider()
      if let decision {
        decisionBody(decision)
      } else {
        review
      }
    }
    .background {
      Color.clear.contentShape(Rectangle()).onTapGesture { focus = .steps }
    }
    .focusable()
    .focused($focus, equals: .steps)
    .focusEffectDisabled()
    .onKeyPress(phases: .down, action: handle)
  }

  // MARK: Keys

  private func handle(_ press: KeyPress) -> KeyPress.Result {
    guard focus != .other else { return .ignored }
    guard
      let action = DecisionSteps.keyAction(
        press.key, modifiers: press.modifiers, onReview: current == .review, options: decision?.options.count ?? 0)
    else { return .ignored }
    switch action {
    case .next: step = steps.next(from: current)
    case .previous: step = steps.previous(from: current)
    case .review: step = .review
    case .pick(let n): if let decision { pick(decision, n) }
    case .focusOther: focus = .other
    case .skip: if let decision { skip(decision) }
    case .submit: submit()
    }
    return .handled
  }

  // MARK: One decision

  private func decisionBody(_ decision: PendingDecision) -> some View {
    let answer = list.answer(decision.number)
    return VStack(alignment: .leading, spacing: 8) {
      Text(decision.header).font(.headline).textSelection(.enabled)
      Text(decision.question).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
      if let context = decision.context, !context.isEmpty {
        DisclosureGroup("More from the reply") {
          Text(context).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        }
      }
      ForEach(decision.options.indices, id: \.self) { i in
        optionBox(decision, i, picked: answer?.labels?.contains(decision.options[i].label) == true)
      }
      OtherAnswer(
        session: session.id, ref: list.ref, decision: decision.number, answered: answer?.text,
        draft: model.otherAnswerDraft(session: session.id, decision: decision.number), focus: $focus)
      HStack {
        Spacer()
        let skipped = answer?.skip == true
        Button(skipped ? "Skipped" : "Skip for now") { skip(decision) }
          .disabled(skipped)
          .help("Answers \"\(DecisionList.skipText)\" (S)")
          .accessibilityLabel(
            skipped ? "Decision \(decision.number) is skipped" : "Skip decision \(decision.number) for now")
      }
    }
    .id(decision.number)
  }

  private func optionBox(_ decision: PendingDecision, _ i: Int, picked: Bool) -> some View {
    let option = decision.options[i]
    return Button {
      pick(decision, i + 1)
    } label: {
      OptionCardLabel(
        mark: decision.multiSelect ? .checkbox(picked) : .radio(picked), title: option.label,
        description: option.detail, tag: option.recommended ? "Recommended" : nil)
    }
    .buttonStyle(OptionCardStyle(ticked: picked))
    .help(i < 9 ? "Press \(i + 1)" : "")
    .accessibilityLabel(option.recommended ? "\(option.label), recommended" : option.label)
    .accessibilityHint(option.detail ?? "")
    .accessibilityAddTraits(picked ? .isSelected : [])
  }

  /// Picks the option, or on a multi-select decision ticks or unticks it.
  /// Unticking the last ticked option sends nothing, because sbd keeps an
  /// answer until another one replaces it.
  private func pick(_ decision: PendingDecision, _ number: Int) {
    var picks = [number]
    if decision.multiSelect {
      let labels = list.answer(decision.number)?.labels ?? []
      var ticked = Set(decision.options.indices.filter { labels.contains(decision.options[$0].label) }.map { $0 + 1 })
      if ticked.remove(number) == nil { ticked.insert(number) }
      guard !ticked.isEmpty else { return }
      picks = ticked.sorted()
    }
    let here = DecisionStep.decision(decision.number)
    let target = steps.step(afterAnswering: decision.number, with: .options(picks))
    step = here
    model.answerDecision(session.id, ref: list.ref, number: decision.number, .options(picks)) {
      guard target != here else { return }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
        // The user may have moved on in the meantime.
        if step == here { step = target }
      }
    }
  }

  private func skip(_ decision: PendingDecision) {
    model.answerDecision(session.id, ref: list.ref, number: decision.number, .skip)
  }

  // MARK: Review

  private var review: some View {
    let recommendable = list.decisions.filter { d in
      list.answer(d.number) == nil && d.options.contains(where: \.recommended)
    }
    return VStack(alignment: .leading, spacing: 10) {
      ForEach(list.decisions, id: \.number) { reviewRow($0) }
      if !recommendable.isEmpty {
        let count = recommendable.count
        Button("Use the recommendation for \(count) unanswered decision\(count == 1 ? "" : "s")") {
          for d in recommendable {
            guard let i = d.options.firstIndex(where: \.recommended) else { continue }
            model.answerDecision(session.id, ref: list.ref, number: d.number, .options([i + 1]))
          }
        }
      }
      submitBox
      if session.decisions != nil { discard }
    }
  }

  private func reviewRow(_ d: PendingDecision) -> some View {
    let answer = list.answer(d.number).map {
      DecisionList.text(of: $0, for: d, skip: "Not decided", recommended: " (recommended)", period: false)
    }
    return HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text("\(d.number)").monospacedDigit().foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 2) {
        Text(d.header).fontWeight(.medium)
        Text(answer ?? "(unanswered)").font(.callout)
          .foregroundStyle(answer == nil ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
          .fixedSize(horizontal: false, vertical: true)
      }
      .textSelection(.enabled)
      Spacer(minLength: 8)
      Button("Edit") { step = .decision(d.number) }
        .accessibilityLabel("Edit decision \(d.number), \(d.header)")
    }
    .accessibilityElement(children: .contain)
  }

  private var submitBox: some View {
    let message = list.message
    let open = list.unanswered.map(String.init)
    let note =
      message.map { "Sends:\n\($0)" }
      ?? "Off until decision\(open.count == 1 ? "" : "s") \(englishList(open)) \(open.count == 1 ? "has" : "have") an answer."
    return VStack(alignment: .leading, spacing: 8) {
      Button(action: submit) {
        OptionCardLabel(mark: .go, title: "Submit", note: note, shortcut: message != nil)
      }
      .buttonStyle(OptionCardStyle(prominent: message != nil))
      .disabled(message == nil || model.deciding.contains("\(session.id)/submit"))
      .primaryShortcut(true)
      .accessibilityLabel("Submit the answers")
      .accessibilityHint(note)
      if confirmingStale {
        confirmation(
          "The session replied since these decisions. Send your answers anyway?", action: "Send Anyway"
        ) {
          model.submitDecisions(session.id, stale: true)
        } cancel: {
          confirmingStale = false
        }
      }
    }
  }

  private func submit() {
    guard list.message != nil else { return }
    if list.stale { confirmingStale = true } else { model.submitDecisions(session.id) }
  }

  @ViewBuilder
  private var discard: some View {
    if confirmingDiscard {
      confirmation("Discard your answers to these decisions?", action: "Discard Answers") {
        model.discardDecisions(session.id)
      } cancel: {
        confirmingDiscard = false
      }
    } else {
      Button("Discard answers…") { confirmingDiscard = true }
        .disabled(model.deciding.contains("\(session.id)/discard"))
        .accessibilityLabel("Discard answers")
    }
  }

  // MARK: Newer decisions

  private var newerBanner: some View {
    let count = list.newer.count
    let style = CalloutView.style(.decision)
    return VStack(alignment: .leading, spacing: 8) {
      Label("The session replied with \(count) new decision\(count == 1 ? "" : "s").", systemImage: style.icon)
        .fontWeight(.medium)
      if confirmingNewer {
        confirmation("Discard your answers to these decisions and answer the new ones?", action: "Discard Answers") {
          model.discardDecisions(session.id)
        } cancel: {
          confirmingNewer = false
        }
      } else {
        WrappingRow(spacing: 8) {
          Button("Answer the new ones…") { confirmingNewer = true }
          Button("Finish these first") { finishingFirst = true }
        }
      }
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .calloutChrome(style.color)
  }

  /// A question that the card asks inside itself, with a button that does the
  /// change and Cancel.
  private func confirmation(
    _ question: String, action: String, confirm: @escaping () -> Void, cancel: @escaping () -> Void
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(question).fixedSize(horizontal: false, vertical: true)
      HStack {
        Button(action) {
          cancel()
          confirm()
        }
        Button("Cancel", action: cancel)
      }
    }
  }
}

/// The numbered dots, one per decision, and Review. A dot shows whether its
/// decision is unanswered, answered, or skipped, and a click goes to it. The
/// strip wraps when the pane is too narrow for it.
struct DecisionDots: View {
  let list: DecisionList
  let current: DecisionStep
  let go: (DecisionStep) -> Void

  static let size: CGFloat = 22

  var body: some View {
    WrappingRow(spacing: 8) {
      ForEach(Array(list.decisions.enumerated()), id: \.element.number) { i, d in
        dot(d, position: i + 1)
      }
      reviewButton
        .controlSize(.small)
        .help("Every answer and Submit (R)")
        .accessibilityAddTraits(current == .review ? .isSelected : [])
      if let title {
        Text(title).font(.callout).foregroundStyle(.secondary).padding(.leading, 4).accessibilityHidden(true)
      }
    }
  }

  /// The Review button is filled while Review shows. The current dot has a ring instead.
  @ViewBuilder
  private var reviewButton: some View {
    let button = Button("Review") { go(.review) }
    if current == .review { button.buttonStyle(.borderedProminent) } else { button.buttonStyle(.bordered) }
  }

  /// "Decision 2 of 6" on a decision's step. The filled Review button names the Review step.
  private var title: String? {
    guard case .decision(let n) = current, let i = list.decisions.firstIndex(where: { $0.number == n }) else {
      return nil
    }
    return "Decision \(i + 1) of \(list.decisions.count)"
  }

  private func dot(_ d: PendingDecision, position: Int) -> some View {
    let answer = list.answer(d.number)
    let here = current == .decision(d.number)
    let status = answer == nil ? "unanswered" : answer?.skip == true ? "skipped" : "answered"
    return Button {
      go(.decision(d.number))
    } label: {
      ZStack {
        if answer == nil {
          Circle().strokeBorder(Color.secondary, lineWidth: 1.5)
        } else if answer?.skip == true {
          Circle().strokeBorder(Color.secondary, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
        } else {
          Circle().fill(Color.accentColor)
        }
        Text("\(d.number)").font(.caption.bold()).monospacedDigit()
          .foregroundStyle(answer != nil && answer?.skip != true ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
      }
      .frame(width: Self.size, height: Self.size)
      .padding(3)
      .overlay(Circle().strokeBorder(here ? Color.accentColor : .clear, lineWidth: 2))
      .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .help(d.header)
    .accessibilityLabel("Decision \(position) of \(list.decisions.count), \(d.header), \(status)")
    .accessibilityAddTraits(here ? .isSelected : [])
  }
}

/// Back and Next under the card's scrolling body, so they stay in view on a
/// short window. sbd's refusal of an answer, Submit, or Discard shows here.
struct DecisionStepBar: View {
  @EnvironmentObject var model: BoardModel
  let session: SessionSummary
  let list: DecisionList
  @Binding var step: DecisionStep?

  var body: some View {
    let steps = DecisionSteps(list)
    let current = steps.resolve(step)
    VStack(alignment: .leading, spacing: 6) {
      if let error = model.decisionErrors[session.id] {
        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout)
          .fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
      }
      HStack {
        Button {
          step = steps.previous(from: current)
        } label: {
          Label("Back", systemImage: "chevron.left")
        }
        .disabled(steps.previous(from: current) == current)
        .help("Previous decision ([)")
        .accessibilityLabel("Back")
        Spacer()
        if current != .review {
          let next = steps.next(from: current)
          Button {
            step = next
          } label: {
            Label(next == .review ? "Review" : "Next", systemImage: "chevron.right").labelStyle(TrailingIcon())
          }
          .primaryShortcut(true)
          .help("\(next == .review ? "Review every answer" : "Next decision") (] or ⇧⌘↩)")
          .accessibilityLabel(next == .review ? "Review" : "Next")
        }
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
  }

  private struct TrailingIcon: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
      HStack(spacing: 4) {
        configuration.title
        configuration.icon
      }
    }
  }
}

/// The Other answer box of a decision: a field and an Answer button. A typed
/// answer replaces any picked option. The box shows the answer that sbd
/// recorded, because the field empties once sbd accepts it.
struct OtherAnswer: View {
  @EnvironmentObject var model: BoardModel
  let session: String
  let ref: String
  let decision: Int
  let answered: String?
  @ObservedObject var draft: MessageField.Draft
  var focus: FocusState<DecisionFocus?>.Binding

  var body: some View {
    let trimmed = ReplyOption.trimmed(draft.text)
    OptionCardChrome(ticked: answered != nil, interactive: false) {
      VStack(alignment: .leading, spacing: 8) {
        OptionCardLabel(mark: .none, title: "Other answer", note: answered.map { "Your answer: \($0)" })
          .accessibilityHidden(true)
        HStack {
          TextField("Type your own answer", text: $draft.text)
            .textFieldStyle(.roundedBorder)
            .focused(focus, equals: .other)
            .onSubmit(send)
            .onExitCommand { focus.wrappedValue = .steps }
            .accessibilityLabel("Other answer to decision \(decision)")
            .accessibilityHint(answered.map { "Your answer: \($0)" } ?? "")
          Button("Answer", action: send)
            .disabled(trimmed.isEmpty || model.deciding.contains("\(session)/\(decision)"))
            .accessibilityLabel("Answer decision \(decision) with the typed text")
        }
      }
    }
  }

  private func send() {
    Self.submit($draft.text, session: session, ref: ref, decision: decision, to: model)
  }

  /// Sends the trimmed text as the decision's answer, as a reply option sends its text.
  static func submit(_ text: Binding<String>, session: String, ref: String, decision: Int, to model: BoardModel) {
    ReplyOption.submit(text) { model.answerDecision(session, ref: ref, number: decision, .text($0), answered: $1) }
  }
}

/// Places its children in rows from the leading edge, and starts a new row
/// when the next child doesn't fit the width.
struct WrappingRow: Layout {
  var spacing: CGFloat = 8

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let rows = rows(subviews, width: proposal.width)
    let width = rows.map { $0.width }.max() ?? 0
    let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
    return CGSize(width: proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? width, height: height)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var y = bounds.minY
    for row in rows(subviews, width: bounds.width) {
      var x = bounds.minX
      for i in row.indices {
        let size = subviews[i].sizeThatFits(.unspecified)
        subviews[i].place(
          at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
        x += size.width + spacing
      }
      y += row.height + spacing
    }
  }

  private struct Row {
    var indices: [Int] = []
    var width: CGFloat = 0
    var height: CGFloat = 0
  }

  private func rows(_ subviews: Subviews, width: CGFloat?) -> [Row] {
    let limit = width.flatMap { $0.isFinite ? $0 : nil } ?? .infinity
    var rows: [Row] = []
    var row = Row()
    for i in subviews.indices {
      let size = subviews[i].sizeThatFits(.unspecified)
      var width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
      if !row.indices.isEmpty, width > limit {
        rows.append(row)
        row = Row()
        width = size.width
      }
      row.width = width
      row.height = max(row.height, size.height)
      row.indices.append(i)
    }
    if !row.indices.isEmpty { rows.append(row) }
    return rows
  }
}
