import Combine
import Foundation
import SwitchboardCore

/// A work skill's command that a Manager conversation's or the operator's pane held back in place of sending it.
struct WorkSkillOffer: Equatable {
  /// The command's name, without the `/`.
  let skill: String
  /// The trimmed draft.
  let text: String
}

extension BoardModel {
  /// Sends the draft, unless the session is a Manager conversation or the operator and the draft starts with a
  /// command whose `slash-commands` row is labeled `work`. Then it sets the session's offer and keeps the draft.
  /// It reads `slash-commands` again first, because labels can land after the user typed `/`. A failed read
  /// decides from the stored rows. Send stays disabled during the read. `then` runs once sbd accepts the send, and
  /// never when the offer shows.
  func submitChecked(session: String, draft: MessageField.Draft, then: (() -> Void)? = nil) {
    let text = draft.trimmed
    guard summary(session)?.kind.runsInManagerFolder == true, let skill = SkillCommand.name(inPrompt: text) else {
      draft.submit(session, to: self, then: then)
      return
    }
    guard sending.insert(session).inserted else { return }
    loadSlashCommands(session) { fresh in
      self.sending.remove(session)
      // A draft that the user changed during the read waits for the next Send.
      guard draft.trimmed == text else { return }
      let rows = fresh ?? self.slashCommands[session] ?? []
      let name = SkillCommand.resolve(skill, among: rows.map(\.name))
      if rows.contains(where: { $0.name == name && $0.label == .work }) {
        self.offer(WorkSkillOffer(skill: skill, text: text), for: session, draft: draft)
      } else {
        draft.submit(session, to: self, then: then)
      }
    }
  }

  /// Sets the offer and closes it when the user edits the draft.
  private func offer(_ offer: WorkSkillOffer, for session: String, draft: MessageField.Draft) {
    workSkillOffers[session] = offer
    workSkillOfferWatches[session] = draft.$text.dropFirst().sink { [weak self] text in
      if text.trimmingCharacters(in: .whitespacesAndNewlines) != offer.text { self?.dismissOffer(session) }
    }
  }

  func dismissOffer(_ session: String) {
    workSkillOfferWatches[session] = nil
    workSkillOffers[session] = nil
  }

  /// Sends the draft past the gate once, and empties it and hides the field once sbd accepts it.
  func runHereAnyway(_ session: String, draft: MessageField.Draft) {
    dismissOffer(session)
    draft.submit(session, to: self, runHere: true) { self.hideMessageFieldIfEmpty(session, draft: draft) }
  }

  /// Opens New Session with the offer's text as the prompt, the conversation as the parent, and the repository
  /// that the text names. Start empties the conversation's draft.
  func spawnFromOffer(_ session: String) {
    guard let offer = workSkillOffers[session] else { return }
    dismissOffer(session)
    newSession = NewSessionRequest(prompt: offer.text, parent: session, fromOffer: true)
  }

  /// Empties the session's draft unless the user changed it from `text`.
  func clearDraft(of session: String, ifStill text: String) {
    guard let summary = summary(session) else { return }
    messageDraft(for: summary).clear(ifStill: text)
  }
}
