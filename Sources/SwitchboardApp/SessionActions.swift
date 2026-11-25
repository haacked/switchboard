import SwitchboardCore

/// The one button that starts or stops claude in a session.
enum SessionRunControl: Equatable {
  /// The session is paused. Resume ends the pause.
  case resumePaused
  case stop
  /// The session waits in the queue for a free slot.
  case startNow
  /// claude is stopped. Resume starts it again on the same conversation.
  case restart

  static func of(_ s: SessionSummary) -> SessionRunControl {
    if s.pause != nil { return .resumePaused }
    if s.live { return .stop }
    if s.queued == true { return .startNow }
    return .restart
  }
}

/// An action on the session that a session view shows.
enum SessionAction: Hashable {
  case run(SessionRunControl)
  case pause
  case done(marked: Bool)
  case notes
  case sidePanel
  case cleanUp
  case delete
}

enum SessionActions {
  /// The actions that `s`'s view offers, in the order the view shows them.
  static func list(for s: SessionSummary) -> [SessionAction] {
    var actions: [SessionAction] = [.run(.of(s))]
    if s.canPause { actions.append(.pause) }
    actions += [.done(marked: s.markedDone), .notes, .sidePanel]
    if CleanupOffer.canCleanUp(s) { actions.append(.cleanUp) }
    actions.append(.delete)
    return actions
  }
}
