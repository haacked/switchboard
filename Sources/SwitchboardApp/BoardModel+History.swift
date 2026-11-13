import SwitchboardCore

/// A place in the window that Back and Forward return to.
struct NavLocation: Hashable {
  enum Place: Hashable {
    /// The Inbox with its current item.
    case inbox(String?)
    case board
    case session(String)
  }

  var place: Place
  /// Whether the place shows the session's terminal instead of its overview. Only the Inbox, a chat,
  /// and a Manager conversation have a Terminal toggle. It is false everywhere else.
  var terminal: Bool
}

/// How `navigate` records the location after its change.
enum NavRecord {
  /// The user went somewhere new.
  case push
  /// The window changed without a navigation, or history is restoring an entry.
  case replace
}

extension BoardModel {
  /// What the window shows now.
  var location: NavLocation {
    if let selection {
      return NavLocation(
        place: .session(selection), terminal: showingTerminal && summary(selection)?.kind.showsAsChat == true)
    }
    if mainView == .board { return NavLocation(place: .board, terminal: false) }
    return NavLocation(place: .inbox(currentInboxItem), terminal: showingTerminal)
  }

  /// The session or follow-up `id`, whatever the org filter says.
  func summary(_ id: String?) -> SessionSummary? { allBoard.first { $0.id == id } }

  /// Maps a location to the place it shows now, or nil when its session is removed or the org filter hides
  /// it. A hidden session counts as unavailable, because selecting it would widen the filter.
  func resolver() -> (NavLocation) -> NavLocation? {
    let shown = Dictionary(board.map { ($0.id, $0.kind.showsAsChat) }, uniquingKeysWith: { a, _ in a })
    let pending = pendingSelection
    let inbox = Set(sessions.map(\.id))
    let first = triage.first?.id
    return { location in
      switch location.place {
      case .board:
        return NavLocation(place: .board, terminal: false)
      case .inbox(let item):
        let current = item.flatMap { inbox.contains($0) ? $0 : nil } ?? first
        return NavLocation(place: .inbox(current), terminal: location.terminal)
      case .session(let id):
        guard let chat = shown[id] ?? (id == pending ? false : nil) else { return nil }
        return NavLocation(place: .session(id), terminal: location.terminal && chat)
      }
    }
  }

  /// Runs `change` and records the location once when it ends. A nested call records nothing, so the
  /// outermost call's mode wins. Each property that `location` reads calls this, so a write outside a
  /// `navigate` call records a navigation.
  func navigate(_ mode: NavRecord = .push, _ change: () -> Void = {}) {
    guard !navigating else { return change() }
    navigating = true
    change()
    navigating = false
    record(mode)
  }

  /// Clears the selection when it is one of `ids`, because those sessions are gone. The user did not
  /// navigate, so the current history entry changes in place.
  func deselect(_ ids: some Sequence<String>) {
    guard let id = selection, ids.contains(id) else { return }
    navigate(.replace) { selection = nil }
  }

  /// `history` publishes only when it changes, because a refresh every second would otherwise redraw the
  /// window each time.
  private func record(_ mode: NavRecord) {
    var updated = history
    switch mode {
    case .push: updated.push(location, resolve: resolver())
    case .replace: updated.replace(location)
    }
    if updated != history { history = updated }
  }

  var canGoBack: Bool { history.canGo(.back, resolve: resolver()) }
  var canGoForward: Bool { history.canGo(.forward, resolve: resolver()) }
  var hasRecentPlaces: Bool { !recentPlaces.isEmpty }

  func goBack() { go(.back) }
  func goForward() { go(.forward) }

  func go(_ direction: NavDirection) {
    let resolve = resolver()
    guard let i = history.target(direction, resolve: resolve), let place = resolve(history.entries[i]) else { return }
    history.move(to: i)
    navigate(.replace) { restore(place) }
  }

  /// The places that Recent Places offers, newest first.
  var recentPlaces: [NavLocation] { history.recent(resolve: resolver()) }

  /// Goes to a place from Recent Places, as a new navigation.
  func go(to place: NavLocation) {
    showingRecentPlaces = false
    guard let place = resolver()(place) else { return }
    navigate { restore(place) }
  }

  private func restore(_ location: NavLocation) {
    switch location.place {
    case .session(let id):
      selection = id
      if summary(id)?.kind.showsAsChat == true { showingTerminal = location.terminal }
    case .inbox(let item):
      show(.inbox)
      inboxFocus = item
      showingTerminal = location.terminal
      inboxJumps += 1
    case .board:
      show(.board)
    }
  }

  /// The Recent Places text for a place.
  func label(for location: NavLocation) -> String {
    let name: (String?) -> String? = { self.summary($0)?.name }
    let text: String
    switch location.place {
    case .board: text = "Board"
    case .inbox(let item): text = name(item).map { "Inbox: \($0)" } ?? "Inbox"
    case .session(let id): text = name(id) ?? id
    }
    return location.terminal ? "\(text) (terminal)" : text
  }
}
