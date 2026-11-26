import Foundation
import SwitchboardCore

/// Script schedules that a session proposed. sbd stores one only after the user allows its card from outside every
/// session: in the app, or with `sb allow` in a terminal.
extension Service {
  /// Opens a `script` card on `proposer` for `schedule`, which `addSchedule` or `editSchedule` checked as it would
  /// store it on `target`, and stores nothing. `before` is the schedule that an edit changes. A session has at most
  /// one open `script` card, and the card shows the whole command, so a command longer than
  /// `ScriptProposal.maxCommand` is refused.
  func openScriptProposal(
    from proposer: String, target: String, schedule: Schedule, before: Schedule?, reason: String?
  ) throws -> JSON {
    if let open = entries[proposer]?.facts.cards.first(where: { $0.kind == .script }) {
      throw APIError(
        "card \(open.id) already proposes a script that waits for the user. Read its decision with: sb schedule --pending \(open.id) --timeout 0. End your turn."
      )
    }
    let length = schedule.prompt.count
    guard length <= ScriptProposal.maxCommand else {
      throw APIError(
        "the command has \(length) characters. The user's card shows the whole command, so a proposed script has at most \(ScriptProposal.maxCommand)"
      )
    }
    let hidden: Set<Unicode.GeneralCategory> = [.format, .lineSeparator, .paragraphSeparator]
    let isHidden = { (text: String) in text.unicodeScalars.contains { hidden.contains($0.properties.generalCategory) } }
    guard !isHidden(schedule.prompt), !isHidden(reason ?? "") else {
      throw APIError(
        "the command or the reason holds a right-to-left override, a zero-width character, or a line or paragraph separator. The user's card can't show those, so a proposed script has none"
      )
    }
    let session = entries[target]!.session
    let proposal = ScriptProposal(
      target: target, targetName: session.name, folder: session.cwd, every: schedule.every, command: schedule.prompt,
      timeout: schedule.timeout, reason: oneLine(reason ?? "", max: TriageCard.lineLength), schedule: before?.id,
      before: before.map { .init(command: $0.prompt, timeout: $0.timeout, every: $0.every) },
      expires: nowMs() + ScriptProposal.expirySeconds * 1000)
    let event = record(proposer, "script_proposed", try JSON(encoding: proposal))
    return try JSON(encoding: ScriptProposalStatus(pending: event.id, decision: .pending))
  }

  /// Answers a `script` card. A deny closes it, from wherever it comes, because it stores nothing. An allow needs
  /// the user, as `scriptAuthority` decides, so neither sbd's own code nor a Manager conversation approves for the
  /// user. A card past its expiry closes as expired, and an edit whose schedule no longer holds what the card showed
  /// closes as stale. Otherwise the allow stores the card's values through the same checks as an add or an edit, and
  /// closes the card in the same step. A failed check leaves the card open with the reason. It runs on the state
  /// queue, after `install` of a fresh snapshot.
  func decideScriptProposal(_ card: Card, allow: Bool, args: JSON, origin: RequestOrigin, caller: Caller) throws
    -> JSON
  {
    guard let proposal = card.scriptProposal?.value else {
      throw APIError("card \(card.id) has no script proposal")
    }
    guard allow else { return try closeScriptProposal(card, .denied) }
    guard try scriptAuthority(args, origin: origin, caller: caller) == .user else {
      throw APIError("only you can allow a script, from the app or from sb in a terminal outside Switchboard")
    }
    guard nowMs() < proposal.expires else {
      _ = try closeScriptProposal(card, .expired)
      throw APIError("card \(card.id) expired, so no script was stored")
    }
    let stored: String
    if let id = proposal.schedule {
      guard let found = entries[proposal.target]?.session.schedule(id), holds(found, proposal) else {
        _ = try closeScriptProposal(card, .stale)
        throw APIError(
          "schedule \(id) changed or was removed since card \(card.id) opened, so nothing was changed. The session can propose the change again"
        )
      }
      let schedule = try found.edited(
        every: proposal.every == found.every ? nil : Schedule.intervalText(proposal.every),
        prompt: proposal.command == found.prompt ? nil : proposal.command,
        timeout: proposal.timeout == found.timeout ? nil : proposal.timeout.map(Schedule.intervalText), now: nowMs())
      _ = try storeEdit(proposal.target, schedule, before: found)
      stored = id
    } else {
      var request: [String: JSON] = [
        "session": .string(proposal.target), "every": .string(Schedule.intervalText(proposal.every)),
        "prompt": .string(proposal.command), "by": .string(Author.claude.rawValue), "runner": "script",
      ]
      if let timeout = proposal.timeout { request["timeout"] = .string(Schedule.intervalText(timeout)) }
      let (id, schedule, _) = try newSchedule(.object(request), origin: origin, caller: caller, approved: true)
      _ = try storeNewSchedule(id, schedule)
      stored = schedule.id
    }
    return try closeScriptProposal(card, .approved, schedule: stored)
  }

  /// Whether an edit's schedule is still a script that holds the command, the timeout, and the interval that the card
  /// showed as before the edit. A removed schedule's id can come back on a schedule that runs otherwise.
  private func holds(_ schedule: Schedule, _ proposal: ScriptProposal) -> Bool {
    guard let before = proposal.before, schedule.runner == .script else { return false }
    return schedule.prompt == before.command && schedule.timeout == before.timeout
      && schedule.every == before.every
  }

  /// The proposal that the card id names: pending while its card is open, else the decision that closed it.
  func scriptProposalStatus(_ args: JSON) throws -> ScriptProposalStatus {
    guard let id = args["card"]?.int.map(Int64.init) else { throw APIError("name a proposal by its card number") }
    switch try decisionCard(id, kind: .script, opened: "script_proposed", decided: "script_decided") {
    case .open?: return ScriptProposalStatus(pending: id, decision: .pending)
    case .decided(_, let decided)?:
      if let decision = decided.data["decision"]?.string.flatMap(ScriptDecision.init(rawValue:)) {
        return ScriptProposalStatus(pending: id, decision: decision, schedule: decided.data["schedule"]?.string)
      }
    case nil: break
    }
    throw APIError("no script proposal \(id)")
  }

  /// Records `expired` for each proposal whose time ran out.
  func expireScriptProposals(now: Int64) {
    let due = entries.values.flatMap { e in
      e.facts.cards.filter { $0.kind == .script && $0.scriptProposal.map { now >= $0.expires } == true }
    }
    for card in due { _ = try? closeScriptProposal(card, .expired) }
  }

  /// Records the `script_decided` event that closes the card, and returns the proposal's status.
  private func closeScriptProposal(_ card: Card, _ decision: ScriptDecision, schedule: String? = nil) throws -> JSON {
    var data: [String: JSON] = ["card": .number(Double(card.id)), "decision": .string(decision.rawValue)]
    if let schedule { data["schedule"] = .string(schedule) }
    record(card.session, "script_decided", .object(data))
    return try JSON(encoding: ScriptProposalStatus(pending: card.id, decision: decision, schedule: schedule))
  }
}
