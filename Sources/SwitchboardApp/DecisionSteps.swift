import SwiftUI
import SwitchboardCore

/// A step of the decision view: one decision by its number, or Review.
enum DecisionStep: Hashable {
  case decision(Int)
  case review
}

/// What the user answers a decision with. `options` holds 1-based option numbers.
enum DecisionReply: Equatable, Sendable {
  case options([Int])
  case text(String)
  case skip
}

enum DecisionKeyAction: Equatable, Sendable {
  case next, previous
  case pick(Int)
  case focusOther, skip, review, submit
}

extension SessionSummary {
  /// The list that the step view shows. Nil while the item doesn't carry the
  /// list, as a held prompt's item doesn't, even when a list is open.
  var stepList: DecisionList? { triage?.hasDecisionList == true ? shownDecisions : nil }
}

/// Which step Next, Back, an answer, and a key go to. The reply numbers its
/// decisions, and the numbers need not run 1, 2, 3, so the steps follow the
/// list's order.
struct DecisionSteps {
  let list: DecisionList
  private var numbers: [Int] { list.decisions.map(\.number) }

  init(_ list: DecisionList) { self.list = list }

  /// The step to show for `step`: the step itself while the list has it,
  /// else the first unanswered decision, else Review.
  func resolve(_ step: DecisionStep?) -> DecisionStep {
    if let step, step == .review || numbers.contains(where: { .decision($0) == step }) { return step }
    return list.unanswered.first.map(DecisionStep.decision) ?? .review
  }

  func next(from step: DecisionStep) -> DecisionStep {
    guard case .decision(let n) = step, let i = numbers.firstIndex(of: n), i + 1 < numbers.count else {
      return .review
    }
    return .decision(numbers[i + 1])
  }

  func previous(from step: DecisionStep) -> DecisionStep {
    guard let last = numbers.last else { return step }
    guard case .decision(let n) = step else { return .decision(last) }
    guard let i = numbers.firstIndex(of: n), i > 0 else { return step }
    return .decision(numbers[i - 1])
  }

  /// Where the view goes once sbd accepts the answer. A pick on a one-choice
  /// decision goes to the next unanswered decision, wrapping to an earlier
  /// one, and to Review when none is left. A pick on a multi-select decision,
  /// a typed answer, and a skip stay, so the user can tick more or read what
  /// they wrote. `list` is the list before the answer.
  func step(afterAnswering number: Int, with reply: DecisionReply) -> DecisionStep {
    let stay = DecisionStep.decision(number)
    guard case .options = reply, list.decisions.first(where: { $0.number == number })?.multiSelect != true else {
      return stay
    }
    let open = list.unanswered.filter { $0 != number }
    let i = numbers.firstIndex(of: number) ?? 0
    let after = open.first { numbers.firstIndex(of: $0)! > i }
    return (after ?? open.first).map(DecisionStep.decision) ?? .review
  }

  /// The action of a key pressed while the step view has focus and no text
  /// field does, or nil to leave the key alone. `options` is the number of
  /// options on the current decision. Only ⇧⌘Return takes a modifier. Command,
  /// Option, and Control leave every other key to the menus.
  static func keyAction(_ key: KeyEquivalent, modifiers: EventModifiers, onReview: Bool, options: Int)
    -> DecisionKeyAction?
  {
    let modifiers = modifiers.intersection([.shift, .command, .option, .control])
    if key == .return { return modifiers == [.command, .shift] ? (onReview ? .submit : .next) : nil }
    guard modifiers.isDisjoint(with: [.command, .option, .control]) else { return nil }
    switch key {
    case "]", .rightArrow: return .next
    case "[", .leftArrow: return .previous
    case "r": return .review
    case "o": return onReview ? nil : .focusOther
    case "s": return onReview ? nil : .skip
    default:
      guard !onReview, let n = Int(String(key.character)), n >= 1, n <= options else { return nil }
      return .pick(n)
    }
  }
}
