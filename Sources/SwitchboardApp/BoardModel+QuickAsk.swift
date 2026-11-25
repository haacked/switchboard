import Foundation
import SwitchboardCore

/// The quick-ask panel's state. The answer lives only as long as the panel.
struct QuickAskState: Equatable {
  enum Phase: Equatable {
    case editing
    case asking
    case answered(String)
    case failed(String)

    var answer: String? {
      if case .answered(let text) = self { return text }
      return nil
    }
  }

  /// The question that the running ask or the shown answer belongs to.
  var asked: String?
  var phase = Phase.editing
}

extension BoardModel {
  func openQuickAsk() {
    if quickAsk == nil { quickAsk = QuickAskState() }
  }

  /// Asks the question. An ask that is still running is cancelled first.
  func submitQuickAsk(_ text: String) {
    guard var state = quickAsk else { return }
    let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !question.isEmpty else { return }
    quickAskCancel?.cancel()
    let cancel = CallCancel()
    quickAskCancel = cancel
    state.asked = question
    state.phase = .asking
    quickAsk = state
    let ask = ask
    quickAskWork.async {
      let result = Result { try JSONCoding.convert(ask(question, cancel), to: QuickAskAnswer.self).answer }
      Task { @MainActor in
        guard self.quickAskCancel === cancel else { return }
        switch result {
        case .success(let answer): self.quickAsk?.phase = .answered(answer)
        case .failure(let error): self.quickAsk?.phase = .failed("\(error)")
        }
      }
    }
  }

  /// Closes the panel, which discards the answer and ends a running ask.
  func closeQuickAsk() {
    quickAskCancel?.cancel()
    quickAskCancel = nil
    if quickAsk != nil { quickAsk = nil }
  }

  /// Starts a Manager conversation whose first prompt carries the asked question and, once it arrived, the answer.
  func continueQuickAskAsChat() {
    guard let state = quickAsk, let question = state.asked else { return }
    closeQuickAsk()
    let text = QuickAsk.chatPrompt(question: question, answer: state.phase.answer)
    performAndSelect("manager", ["new": true, "text": .string(text)])
  }
}
