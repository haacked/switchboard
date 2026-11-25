import SwiftUI
import SwitchboardCore

/// What has the keyboard in the step view: the view itself, whose keys
/// move through the steps, the Other answer field, or the thread's field.
enum DecisionFocus: Hashable {
  case steps, other, ask
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
  /// Where the thread goes, from the step view's width. Each decision's body has its own identity, so the
  /// placement lives here and survives a change of step.
  @State private var placement = DecisionThread.Placement.under

  private var steps: DecisionSteps { DecisionSteps(list) }
  private var current: DecisionStep { steps.resolve(step) }
  private var decision: PendingDecision? {
    guard case .decision(let n) = current else { return nil }
    return list.decisions.first { $0.number == n }
  }
  /// Why sbd refuses an answer, Submit, or Discard now, or nil.
  private var pendingAskReason: String? { list.pendingAskReason }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if !list.newer.isEmpty, !finishingFirst { newerBanner() }
      DecisionDots(list: list, current: current) { step = $0 }
      Divider()
      if let decision {
        decisionBody(decision)
      } else {
        review()
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .onGeometryChange(for: DecisionThread.Placement.self) {
      DecisionThread.placement(width: $0.size.width)
    } action: {
      placement = $0
    }
    .onChange(of: list.pendingAsk) { asked, now in
      // VoiceOver does not announce the answer that replaces the spinner on the next poll.
      guard let asked, now == nil, let done = list.exchanges.last(where: { $0.number == asked && !$0.pending })
      else { return }
      let text =
        done.reply.map { "Answer about decision \(asked): \(String($0.prefix(300)))" }
        ?? "Your question about decision \(asked) got no answer: \(done.error ?? "")"
      AccessibilityNotification.Announcement(text).post()
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
    guard
      let action = DecisionSteps.keyAction(
        press.key, modifiers: press.modifiers, onReview: current == .review, options: decision?.options.count ?? 0,
        focus: focus)
    else { return .ignored }
    switch action {
    case .pick, .skip, .submit:
      // A key reaches these actions while a pending question turns their buttons off.
      if pendingAskReason != nil { return .handled }
    default:
      break
    }
    switch action {
    case .next: step = steps.next(from: current)
    case .previous: step = steps.previous(from: current)
    case .review: step = .review
    case .pick(let n): if let decision { pick(decision, n) }
    case .focusOther: focus = .other
    case .focusAsk: focus = .ask
    case .skip: if let decision { skip(decision) }
    case .submit: submit()
    }
    return .handled
  }

  // MARK: One decision

  private func decisionBody(_ decision: PendingDecision) -> some View {
    let thread = DecisionThread(
      session: session.id, list: list, decision: decision.number,
      draft: model.askDraft(session: session.id, ref: list.ref, decision: decision.number), focus: $focus)
    return Group {
      switch placement {
      case .beside:
        HStack(alignment: .top, spacing: 0) {
          decisionColumn(decision).frame(maxWidth: .infinity, alignment: .leading)
          HStack(alignment: .top, spacing: 0) {
            Divider().padding(.horizontal, 12)
            thread
          }
          .frame(width: DecisionThread.width, alignment: .leading)
        }
      case .under:
        VStack(alignment: .leading, spacing: 12) {
          decisionColumn(decision)
          Divider()
          thread
        }
      }
    }
    .id(decision.number)
  }

  private func decisionColumn(_ decision: PendingDecision) -> some View {
    let answer = list.answer(decision.number)
    return VStack(alignment: .leading, spacing: 8) {
      InlineText(plain: decision.header).font(.headline).textSelection(.enabled)
      InlineText(plain: decision.question).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
      if let context = decision.context, !context.isEmpty {
        DisclosureGroup("More from the reply") {
          InlineText(plain: context).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
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
        disabledReason: pendingAskReason,
        draft: model.otherAnswerDraft(session: session.id, ref: list.ref, decision: decision.number),
        focus: $focus)
      HStack(alignment: .firstTextBaseline) {
        if let pendingAskReason { PendingAskNote(reason: pendingAskReason) }
        Spacer()
        let skipped = answer?.skip == true
        Button(skipped ? "Skipped" : "Skip for now") { skip(decision) }
          .disabled(skipped || pendingAskReason != nil)
          .help(pendingAskReason ?? "Answers \"\(DecisionList.skipText)\" (S)")
          .accessibilityLabel(
            skipped ? "Decision \(decision.number) is skipped" : "Skip decision \(decision.number) for now")
      }
    }
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
    .disabled(pendingAskReason != nil)
    .help(pendingAskReason ?? (i < 9 ? "Press \(i + 1)" : ""))
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

  private func review() -> some View {
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
        .disabled(pendingAskReason != nil)
        .help(pendingAskReason ?? "")
      }
      submitBox()
      if session.decisions != nil { discard() }
    }
  }

  private func reviewRow(_ d: PendingDecision) -> some View {
    let answer = list.answer(d.number).map {
      DecisionList.text(of: $0, for: d, skip: "Not decided", recommended: " (recommended)", period: false)
    }
    return HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text("\(d.number)").monospacedDigit().foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 2) {
        InlineText(plain: d.header).fontWeight(.medium)
        InlineText(plain: answer ?? "(unanswered)").font(.callout)
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

  private func submitBox() -> some View {
    let message = list.message
    let open = list.unanswered.map(String.init)
    let sendable = message != nil && pendingAskReason == nil
    let note =
      pendingAskReason.map { "\($0)." }
      ?? message.map { "Sends:\n\($0)" }
      ?? "Off until decision\(open.count == 1 ? "" : "s") \(englishList(open)) \(open.count == 1 ? "has" : "have") an answer."
    return VStack(alignment: .leading, spacing: 8) {
      Button(action: submit) {
        OptionCardLabel(mark: .go, title: "Submit", note: note, shortcut: sendable)
      }
      .buttonStyle(OptionCardStyle(prominent: sendable))
      .disabled(!sendable || model.deciding.contains("\(session.id)/submit"))
      .primaryShortcut(true)
      .accessibilityLabel("Submit the answers")
      .accessibilityHint(note)
      if confirmingStale {
        confirmation(
          "The session replied since these decisions. Send your answers anyway?", action: "Send Anyway",
          disabledReason: pendingAskReason
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
  private func discard() -> some View {
    if confirmingDiscard {
      confirmation(
        "Discard your answers to these decisions?", action: "Discard Answers", disabledReason: pendingAskReason
      ) {
        model.discardDecisions(session.id)
      } cancel: {
        confirmingDiscard = false
      }
    } else {
      Button("Discard answers…") { confirmingDiscard = true }
        .disabled(pendingAskReason != nil || model.deciding.contains("\(session.id)/discard"))
        .help(pendingAskReason ?? "")
        .accessibilityLabel("Discard answers")
        .accessibilityHint(pendingAskReason ?? "")
    }
  }

  // MARK: Newer decisions

  private func newerBanner() -> some View {
    let count = list.newer.count
    let style = CalloutView.style(.decision)
    return VStack(alignment: .leading, spacing: 8) {
      Label("The session replied with \(count) new decision\(count == 1 ? "" : "s").", systemImage: style.icon)
        .fontWeight(.medium)
      if confirmingNewer {
        confirmation(
          "Discard your answers to these decisions and answer the new ones?", action: "Discard Answers",
          disabledReason: pendingAskReason
        ) {
          model.discardDecisions(session.id)
        } cancel: {
          confirmingNewer = false
        }
      } else {
        WrappingRow(spacing: 8) {
          Button("Answer the new ones…") { confirmingNewer = true }
            .disabled(pendingAskReason != nil)
            .help(pendingAskReason ?? "")
          Button("Finish these first") { finishingFirst = true }
        }
      }
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .calloutChrome(style.color)
  }

  /// A question that the card asks inside itself, with a button that does the
  /// change and Cancel. `disabledReason` turns the change off and says why.
  private func confirmation(
    _ question: String, action: String, disabledReason: String? = nil, confirm: @escaping () -> Void,
    cancel: @escaping () -> Void
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(question).fixedSize(horizontal: false, vertical: true)
      HStack {
        Button(action) {
          cancel()
          confirm()
        }
        .disabled(disabledReason != nil)
        .help(disabledReason ?? "")
        Button("Cancel", action: cancel)
      }
      if let disabledReason { PendingAskNote(reason: disabledReason) }
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
    let marks = list.threadMarks
    WrappingRow(spacing: 8) {
      ForEach(Array(list.decisions.enumerated()), id: \.element.number) { i, d in
        dot(d, position: i + 1, mark: marks[d.number])
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

  private func dot(_ d: PendingDecision, position: Int, mark: DecisionThreadMark?) -> some View {
    let answer = list.answer(d.number)
    let here = current == .decision(d.number)
    var status = answer == nil ? "unanswered" : answer?.skip == true ? "skipped" : "answered"
    switch mark {
    case .asked: status += ", you asked about it"
    case .answering: status += ", the session is answering your question"
    case nil: break
    }
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
      .overlay(alignment: .topTrailing) { threadMark(mark).offset(x: 4, y: -2) }
      .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .help(d.header)
    .accessibilityLabel("Decision \(position) of \(list.decisions.count), \(d.header), \(status)")
    .accessibilityAddTraits(here ? .isSelected : [])
  }

  /// A speech mark on a decision that the user asked about, and a spinner while the session answers.
  @ViewBuilder
  private func threadMark(_ mark: DecisionThreadMark?) -> some View {
    switch mark {
    case .asked:
      Image(systemName: "bubble.left.fill").font(.system(size: 9)).foregroundStyle(.secondary)
        .padding(1).background(Circle().fill(.background))
    case .answering:
      ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14, height: 14)
        .background(Circle().fill(.background))
    case nil:
      EmptyView()
    }
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
      RefusalLabel(refusal: model.decisionErrors[session.id])
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
          .help(
            "\(next == .review ? "Review every answer" : "Next decision") (\(AppShortcut.glyphs(AppShortcut.decisionNext.keys[0])) or \(AppShortcut.primaryAction.glyphs))"
          )
          .accessibilityLabel(next == .review ? "Review" : "Next")
        }
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
    .announcesRefusal(model.decisionErrors[session.id])
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
  /// Why sbd refuses an answer now, or nil.
  let disabledReason: String?
  @ObservedObject var draft: MessageField.Draft
  var focus: FocusState<DecisionFocus?>.Binding

  var body: some View {
    let trimmed = ReplyOption.trimmed(draft.text)
    OptionCardChrome(ticked: answered != nil, interactive: false) {
      VStack(alignment: .leading, spacing: 8) {
        OptionCardLabel(mark: .none, title: "Other answer", note: answered.map { "Your answer: \($0)" })
          .accessibilityHidden(true)
        HStack {
          TextField("Type your own answer", text: $draft.text, axis: .vertical)
            .textFieldStyle(.roundedBorder)
            .focused(focus, equals: .other)
            .sendsOnReturn(send)
            .onExitCommand { focus.wrappedValue = .steps }
            .accessibilityLabel("Other answer to decision \(decision)")
            .accessibilityHint(answered.map { "Your answer: \($0)" } ?? "")
          Button("Answer", action: send)
            .disabled(trimmed.isEmpty || disabledReason != nil || model.deciding.contains("\(session)/\(decision)"))
            .help(disabledReason ?? "")
            .accessibilityLabel("Answer decision \(decision) with the typed text")
        }
      }
    }
  }

  /// Return sends too, so it checks the pending question that turns the Answer button off.
  private func send() {
    guard disabledReason == nil else { return }
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
