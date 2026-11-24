import Foundation
import Testing

@testable import SwitchboardCore

/// Which item sources reach the Inbox for each session kind (Risk D). The table records what `Triage.inInbox` gave
/// before `Triage.itemSourceAllowed` existed, except that a `.report` item reaches the Inbox on every kind (#410).
/// Each row lists a kind, a source (nil for no item), and the answer without and with a blocking prompt. The rows
/// are data. Neither function computes them, so a change to either function that changes an answer fails here.
struct SourceRow: CustomTestStringConvertible, Sendable {
  var kind: SessionKind
  var source: TriageSource?
  var unblocked: Bool
  var blocked: Bool

  func allowed(blocking: Bool) -> Bool { blocking ? blocked : unblocked }

  var testDescription: String { "\(kind.rawValue), \(source?.rawValue ?? "no item")" }
}

let itemSourceTable: [SourceRow] = [
  SourceRow(kind: .work, source: nil, unblocked: true, blocked: true),
  SourceRow(kind: .work, source: .card, unblocked: true, blocked: true),
  SourceRow(kind: .work, source: .session, unblocked: true, blocked: true),
  SourceRow(kind: .work, source: .rule, unblocked: true, blocked: true),
  SourceRow(kind: .work, source: .summary, unblocked: true, blocked: true),
  SourceRow(kind: .work, source: .fallback, unblocked: true, blocked: true),
  SourceRow(kind: .work, source: .report, unblocked: true, blocked: true),

  SourceRow(kind: .manager, source: nil, unblocked: false, blocked: false),
  SourceRow(kind: .manager, source: .card, unblocked: false, blocked: true),
  SourceRow(kind: .manager, source: .session, unblocked: false, blocked: true),
  SourceRow(kind: .manager, source: .rule, unblocked: false, blocked: true),
  SourceRow(kind: .manager, source: .summary, unblocked: false, blocked: true),
  SourceRow(kind: .manager, source: .fallback, unblocked: false, blocked: true),
  SourceRow(kind: .manager, source: .report, unblocked: true, blocked: true),

  SourceRow(kind: .chat, source: nil, unblocked: false, blocked: false),
  SourceRow(kind: .chat, source: .card, unblocked: false, blocked: true),
  SourceRow(kind: .chat, source: .session, unblocked: false, blocked: true),
  SourceRow(kind: .chat, source: .rule, unblocked: false, blocked: true),
  SourceRow(kind: .chat, source: .summary, unblocked: false, blocked: true),
  SourceRow(kind: .chat, source: .fallback, unblocked: false, blocked: true),
  SourceRow(kind: .chat, source: .report, unblocked: true, blocked: true),

  SourceRow(kind: .operator, source: nil, unblocked: false, blocked: false),
  SourceRow(kind: .operator, source: .card, unblocked: false, blocked: true),
  SourceRow(kind: .operator, source: .session, unblocked: false, blocked: false),
  SourceRow(kind: .operator, source: .rule, unblocked: true, blocked: true),
  SourceRow(kind: .operator, source: .summary, unblocked: false, blocked: false),
  SourceRow(kind: .operator, source: .fallback, unblocked: false, blocked: false),
  SourceRow(kind: .operator, source: .report, unblocked: true, blocked: true),
]

/// Every session kind. The switch has no default, so a new kind stops this file from compiling until it is listed.
let everyKind: [SessionKind] = [SessionKind.work, .manager, .chat, .operator].map {
  (kind: SessionKind) -> SessionKind in
  switch kind {
  case .work, .manager, .chat, .operator: kind
  }
}

/// Every item source and nil. The switch has no default, so a new source stops this file from compiling until it
/// is listed.
let everySource: [TriageSource?] =
  [nil]
  + [TriageSource.card, .session, .rule, .summary, .fallback, .report].map { (source: TriageSource) -> TriageSource? in
    switch source {
    case .card, .session, .rule, .summary, .fallback, .report: source
    }
  }

/// A way that a summary can show a blocking prompt or its absence. `hasBlockingPrompt` reads both the cards and the
/// open prompt flag, so the table runs against each way.
struct BlockingShape: CustomTestStringConvertible, Sendable {
  var cards: [Card.Kind]
  var openPrompt: Bool
  var blocking: Bool

  var testDescription: String { "cards \(cards.map(\.rawValue)), openPrompt \(openPrompt)" }
}

let blockingShapes: [BlockingShape] = [
  BlockingShape(cards: [], openPrompt: false, blocking: false),
  BlockingShape(cards: [.send], openPrompt: false, blocking: false),
  BlockingShape(cards: [], openPrompt: true, blocking: true),
  BlockingShape(cards: [.send], openPrompt: true, blocking: true),
  BlockingShape(cards: [.permission], openPrompt: false, blocking: true),
  BlockingShape(cards: [.question], openPrompt: false, blocking: true),
  BlockingShape(cards: [.trust], openPrompt: false, blocking: true),
  BlockingShape(cards: [.mcp], openPrompt: false, blocking: true),
  BlockingShape(cards: [.send, .permission], openPrompt: false, blocking: true),
]

@Suite struct ItemSourceTableTests {
  /// A summary of a session of `kind` whose item, if any, came from `source`.
  func summary(_ kind: SessionKind, _ source: TriageSource?, _ shape: BlockingShape) -> SessionSummary {
    var s = SessionSummary(
      id: "s1", name: "s1", cwd: "/", repo: nil, branch: nil, claudeSessionId: "s1", state: .needsYou, reason: "",
      since: 0, lastActivity: 0, live: true, claudePid: nil, attached: false, lastReply: nil, waits: [], notes: [],
      cards: shape.cards.map(TriageConversations.card), openPrompt: shape.openPrompt)
    s.triage = source.map { TriageItem(title: "t", kind: .question, summary: "", source: $0) }
    s.kind = kind
    s.manager = kind == .manager || kind == .operator ? true : nil
    s.chat = kind == .chat ? "g1" : nil
    return s
  }

  @Test func theTableHasOneRowForEachKindAndSource() {
    let rows = itemSourceTable.map { "\($0.kind.rawValue)/\($0.source?.rawValue ?? "nil")" }
    let combinations = everyKind.flatMap { kind in
      everySource.map { "\(kind.rawValue)/\($0?.rawValue ?? "nil")" }
    }

    #expect(rows.sorted() == combinations.sorted())
  }

  @Test func eachBlockingShapeIsWhatHasBlockingPromptReads() {
    for shape in blockingShapes {
      let cards = shape.cards.map(TriageConversations.card)

      #expect(Triage.hasBlockingPrompt(cards: cards, openPrompt: shape.openPrompt) == shape.blocking, "\(shape)")
    }
  }

  @Test(arguments: itemSourceTable, blockingShapes)
  func inInboxGivesTheTablesAnswer(_ row: SourceRow, _ shape: BlockingShape) {
    let s = summary(row.kind, row.source, shape)

    #expect(Triage.inInbox(s) == row.allowed(blocking: shape.blocking))
  }
}

extension ItemSourceTableTests {
  @Suite struct Allowed {
    @Test(arguments: itemSourceTable, [false, true])
    func itemSourceAllowedGivesTheTablesAnswer(_ row: SourceRow, _ blocking: Bool) {
      #expect(
        Triage.itemSourceAllowed(kind: row.kind, source: row.source, blocking: blocking)
          == row.allowed(blocking: blocking))
    }
  }

  /// The ask verdict takes the owner's routed items and reads no session, so any owner can show one.
  @Suite struct AskVerdict {
    let reports = [opReport(10, "Merge it?"), opReport(11, "Remove kid?")].compactMap(OperatorReport.init)

    @Test func noAsksGiveNoVerdict() {
      #expect(Attention.askVerdict(OperatorItems()) == nil)
    }

    @Test func asksGiveNeedsYou() {
      #expect(Attention.askVerdict(OperatorItems(asks: reports))?.state == .needsYou)
    }

    @Test func asksGiveTheOperatorAndTheLatestReportsReason() {
      #expect(
        Attention.askVerdict(OperatorItems(asks: reports))?.reason == "Operator: " + OperatorReport.reason(reports))
    }

    @Test func asksGiveAQuestion() {
      #expect(Attention.askVerdict(OperatorItems(asks: reports))?.kind == .question)
    }

    @Test func oneAskGivesItsTextAfterTheOperatorAsTheReason() throws {
      let one = try #require(OperatorReport(opReport(10, "Merge it?")))

      #expect(Attention.askVerdict(OperatorItems(asks: [one]))?.reason == "Operator: Merge it?")
    }
  }
}
