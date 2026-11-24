import Foundation
import SwitchboardCore

extension Service {
  /// Answers a one-off question from a snapshot of the state, with a `claude`
  /// turn that has no tools, so the turn can't change anything. It records
  /// no event, only a `quickAsk` headless call. It runs off the state queue and takes that queue only to read
  /// the snapshot. The turn ends when `clientGone` turns true.
  func quickAsk(_ args: JSON, clientGone: @escaping @Sendable () -> Bool) throws -> JSON {
    let question = args["question"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !question.isEmpty else { throw APIError("ask a question") }
    guard question.count <= QuickAsk.maxQuestion else {
      throw APIError("a question is at most \(QuickAsk.maxQuestion) characters")
    }
    let (sessions, accounts, groups, account, env) = queue.sync {
      (summaries(), accountList(), groupList().groups, activeAccount, headlessEnv(session: nil, account: activeAccount))
    }
    let input = QuickAsk.input(
      question: question, sessions: sessions, inbox: Triage.order(sessions), accounts: accounts, groups: groups)
    try requireSignedIn(["account": .string(account.folder)])
    if clientGone() { throw APIError("cancelled") }
    let model = config.quickAsk.model
    let call = headlessCall(
      .quickAsk, session: nil, arguments: QuickAsk.arguments(model: model), input: input, env: env, folder: home.path,
      timeout: min(config.quickAsk.timeoutSeconds, QuickAsk.maxTimeout), cancelled: clientGone, parse: QuickAsk.parse)
    do {
      return try JSON(encoding: QuickAskAnswer(answer: call.result.get(), model: model))
    } catch {
      logLine("quick ask failed: \(error)")
      throw error
    }
  }
}
