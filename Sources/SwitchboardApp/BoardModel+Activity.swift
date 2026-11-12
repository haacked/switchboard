import AppKit
import SwitchboardCore

/// The app's side of the opt-in activity log. Events wait in `buffer` and go to sbd in one request every 5 s.
/// sbd stores only the events that `ActivityKinds` accepts, and none while the log is off.
struct ActivityState {
  /// nil until the app reads the switch from sbd. Events wait in the buffer until then.
  var enabled: Bool?
  var buffer: [ActivityEvent] = []
  var lastFlush = Date.distantPast
  var flushing = false
  /// How the navigation in progress started, when a command, Back, Forward, Recent Places, search, or a
  /// notification started it.
  var navVia: String?
  /// The place that the last `nav` event recorded.
  var place: ActivityPlace?
  /// A place that hasn't stayed on screen for `settleMs` yet.
  var pendingNav: PendingNav?
  /// Counts up with each pending place, so an old settle timer can't settle a newer place.
  var navTokens = 0
  /// The timer that settles `pendingNav`. A newer navigation cancels it.
  var settleTimer: Task<Void, Never>?
  var terminalWaits: [String: TerminalWait] = [:]

  struct PendingNav {
    var place: ActivityPlace
    var via: String
    var t: Int64
    var token: Int
  }

  struct TerminalWait {
    var start: Int64
    var wasLive: Bool
    var attached = false
    var live: Bool
    /// The loop that asks sbd whether claude is live. Ending the wait cancels it.
    var poll: Task<Void, Never>?
  }

  static let bufferCap = 500
  static let flushEvery: TimeInterval = 5
}

/// A place as the activity log names it: its kind, and the session for a session place.
struct ActivityPlace: Equatable {
  var kind: String
  var session: String?

  /// Places with a session are the same when their session is. A session that a refresh hasn't listed yet
  /// reads as `session`, and the next refresh can show it is the Manager or a chat.
  func isSame(as other: ActivityPlace) -> Bool {
    session != nil || other.session != nil ? session == other.session : kind == other.kind
  }
}

extension BoardModel {
  /// A place counts once it stays on screen this long, so arrowing through the sidebar records only where the
  /// user stopped.
  static let settleMs: Int64 = 1000
  /// The longest that a terminal wait polls sbd for claude to go live.
  static let terminalWaitLimitMs: Int64 = 30_000

  func recordActivity(_ kind: String, session: String? = nil, at t: Int64 = nowMs(), _ data: [String: JSON]) {
    guard activity.enabled != false else { return }
    activity.buffer.append(ActivityEvent(t: t, kind: kind, session: session, data: .object(data)))
    activity.buffer = Array(activity.buffer.suffix(ActivityState.bufferCap))
  }

  /// Applies the switch that sbd reported. Turning off drops the events that waited for it.
  func activityEnabled(_ enabled: Bool) {
    activity.enabled = enabled
    guard !enabled else { return }
    activity.settleTimer?.cancel()
    for wait in activity.terminalWaits.values { wait.poll?.cancel() }
    activity = ActivityState(enabled: false, navTokens: activity.navTokens)
  }

  /// Sends the buffer to sbd every `flushEvery` seconds, or now with `force`. A failure, such as an sbd from
  /// before the activity log, keeps the events for the next try and shows nothing.
  func flushActivity(force: Bool = false) {
    guard activity.enabled == true, !activity.flushing, !activity.buffer.isEmpty,
      force || Date().timeIntervalSince(activity.lastFlush) >= ActivityState.flushEvery
    else { return }
    let batch = activity.buffer
    activity.buffer = []
    activity.flushing = true
    activity.lastFlush = Date()
    let send = send
    DispatchQueue.global(qos: .utility).async {
      let ok = Self.post(batch, send)
      Task { @MainActor in
        self.activity.flushing = false
        guard !ok, self.activity.enabled == true else { return }
        self.activity.buffer = Array((batch + self.activity.buffer).suffix(ActivityState.bufferCap))
      }
    }
  }

  /// Sends the buffer before the app quits. The request gives up after 1 s, so a busy sbd can't hold the quit.
  func flushActivityNow() {
    guard activity.enabled == true, !activity.buffer.isEmpty else { return }
    let client = client
    _ = Self.post(activity.buffer) { try client.call($0, $1, timeout: 1) }
    activity.buffer = []
  }

  nonisolated static func post(_ batch: [ActivityEvent], _ send: (String, [String: JSON]) throws -> JSON) -> Bool {
    (try? send("activity-record", ["events": try JSON(encoding: batch)])) != nil
  }

  // MARK: Commands

  /// Records the command and the input that ran it, then runs `action`. Without `input`, the input comes from
  /// the event that AppKit is handling. A command that changes the place
  /// marks the navigation with `command`, or with `back` or `forward`.
  func track(_ command: ActivityCommand, input: String? = nil, _ action: () -> Void) {
    let via = input ?? Self.input(NSApp?.currentEvent)
    recordActivity("command", ["name": .string(command.rawValue), "via": .string(via)])
    guard let via = command.navVia else { return action() }
    withNavVia(via, action)
  }

  /// The input that an event came from. A launch hook runs with no current event.
  static func input(_ event: NSEvent?) -> String {
    guard let event else { return "launch" }
    switch event.type {
    case .keyDown, .keyUp: return "key"
    case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp: return "click"
    case .otherMouseDown, .otherMouseUp: return "mouse-button"
    case .swipe, .scrollWheel, .gesture, .beginGesture, .endGesture: return "swipe"
    default: return "other"
    }
  }

  /// Runs `action` as a navigation that `via` started, unless an outer call already named one.
  func withNavVia(_ via: String?, _ action: () -> Void) {
    let outer = activity.navVia
    if outer == nil { activity.navVia = via }
    action()
    activity.navVia = outer
  }

  // MARK: Navigation

  /// Called each time `navigate` records a location. A push is the user's navigation. A replace counts only
  /// when a user entry point named it, because a refresh replaces the location too. The place counts once it
  /// stays on screen for `settleMs`.
  func noteNavigation(_ mode: NavRecord) {
    guard activity.enabled != false else { return }
    let via = activity.navVia
    guard mode == .push || via != nil else { return }
    let place = activityPlace(location)
    if let recorded = activity.place, place.isSame(as: recorded) {
      activity.pendingNav = nil
      return
    }
    activity.navTokens += 1
    let token = activity.navTokens
    activity.pendingNav = ActivityState.PendingNav(place: place, via: via ?? "list", t: nowMs(), token: token)
    activity.settleTimer?.cancel()
    activity.settleTimer = Task { @MainActor in
      try? await Task.sleep(nanoseconds: UInt64(Self.settleMs) * 1_000_000)
      if !Task.isCancelled { self.settleNavigation(token) }
    }
  }

  func settleNavigation(_ token: Int) {
    guard let pending = activity.pendingNav, pending.token == token else { return }
    activity.pendingNav = nil
    let place = activityPlace(location)
    guard place.isSame(as: pending.place) else { return }
    var data: [String: JSON] = ["to": .string(place.kind), "via": .string(pending.via)]
    if let from = activity.place { data["from"] = .string(from.kind) }
    if let state = place.session.flatMap(summary)?.state { data["state"] = .string(state.rawValue) }
    activity.place = place
    recordActivity("nav", session: place.session, at: pending.t, data)
  }

  func activityPlace(_ location: NavLocation) -> ActivityPlace {
    switch location.place {
    case .board: return ActivityPlace(kind: "board")
    case .inbox: return ActivityPlace(kind: "inbox")
    case .session(let id):
      switch summary(id)?.kind {
      case .manager: return ActivityPlace(kind: "manager", session: id)
      case .chat: return ActivityPlace(kind: "chat", session: id)
      default: return ActivityPlace(kind: "session", session: id)
      }
    }
  }

  // MARK: Terminal waits

  /// Starts timing how long the session's terminals take to become usable: the terminals have attached and
  /// claude is live. The connection calls it once the selection rests. While claude isn't live, it asks sbd for the
  /// session every 200 ms, for at most `terminalWaitLimitMs`.
  func beginTerminalWait(_ id: String) {
    guard activity.enabled == true, activity.terminalWaits[id] == nil else { return }
    let live = summary(id)?.live ?? false
    let start = nowMs()
    var wait = ActivityState.TerminalWait(start: start, wasLive: live, live: live)
    if !live {
      let send = send
      wait.poll = Task { @MainActor in
        while !Task.isCancelled, nowMs() - start < Self.terminalWaitLimitMs {
          try? await Task.sleep(nanoseconds: 200_000_000)
          let live = await Task.detached { (try? send("get", ["session": .string(id)]))?["live"]?.bool ?? false }
            .value
          if live, !Task.isCancelled { return self.terminalWaitProgressed(id) { $0.live = true } }
        }
        if !Task.isCancelled { self.timeOutTerminalWait(id) }
      }
    }
    activity.terminalWaits[id] = wait
  }

  /// Times the session's terminal wait from a `TerminalConnection`'s progress.
  func terminalObserver(_ id: String) -> TerminalConnection.Observer {
    TerminalConnection.Observer(
      opening: { [weak self] in self?.beginTerminalWait(id) },
      opened: { [weak self] in self?.terminalsAttached(id) },
      failed: { [weak self] in self?.recordError("open", $0) })
  }

  func terminalsAttached(_ id: String) {
    terminalWaitProgressed(id) { $0.attached = true }
  }

  /// Records a wait that the user left before the terminals were usable.
  func endTerminalWait(_ id: String) {
    guard let wait = activity.terminalWaits.removeValue(forKey: id) else { return }
    wait.poll?.cancel()
    recordTerminalReady(id, wait, left: true)
  }

  /// Records a wait whose claude didn't go live within `terminalWaitLimitMs`, and stops timing it.
  func timeOutTerminalWait(_ id: String) {
    guard let wait = activity.terminalWaits.removeValue(forKey: id) else { return }
    recordTerminalReady(id, wait, left: false, timedOut: true)
  }

  private func terminalWaitProgressed(_ id: String, _ change: (inout ActivityState.TerminalWait) -> Void) {
    guard var wait = activity.terminalWaits[id] else { return }
    change(&wait)
    guard wait.attached, wait.live else {
      activity.terminalWaits[id] = wait
      return
    }
    activity.terminalWaits[id] = nil
    wait.poll?.cancel()
    recordTerminalReady(id, wait, left: false)
  }

  private func recordTerminalReady(
    _ id: String, _ wait: ActivityState.TerminalWait, left: Bool, timedOut: Bool = false
  ) {
    var data: [String: JSON] = [
      "ms": .number(Double(nowMs() - wait.start)), "wasLive": .bool(wait.wasLive), "left": .bool(left),
    ]
    if timedOut { data["timedOut"] = true }
    recordActivity("terminal.ready", session: id, data)
  }

  // MARK: App and window

  /// Records the app's launch, its moves to and from the background, its quit, and the main window's size
  /// after each resize and full-screen change.
  func observeActivity() {
    recordActivity("app", ["event": "launch"])
    withNavVia("launch") { noteNavigation(.replace) }
    recordWindow(NSApp?.switchboardWindow)
    let center = NotificationCenter.default
    let app: [(Notification.Name, String)] = [
      (NSApplication.didBecomeActiveNotification, "activate"),
      (NSApplication.didResignActiveNotification, "deactivate"),
    ]
    for (name, event) in app {
      center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.recordActivity("app", ["event": .string(event)]) }
      }
    }
    center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) {
      [weak self] _ in
      MainActor.assumeIsolated {
        self?.recordActivity("app", ["event": "quit"])
        self?.flushActivityNow()
      }
    }
    for name in [
      NSWindow.didEndLiveResizeNotification, NSWindow.didEnterFullScreenNotification,
      NSWindow.didExitFullScreenNotification,
    ] {
      center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
        let window = note.object as? NSWindow
        MainActor.assumeIsolated { self?.recordWindow(window) }
      }
    }
  }

  func recordWindow(_ window: NSWindow?) {
    guard let window, window === NSApp?.switchboardWindow else { return }
    recordWindowSize(window.contentLayoutRect.size, fullScreen: window.styleMask.contains(.fullScreen))
  }

  func recordWindowSize(_ size: CGSize, fullScreen: Bool) {
    recordActivity(
      "window",
      [
        "width": .number(Double(Int(size.width))), "height": .number(Double(Int(size.height))),
        "fullScreen": .bool(fullScreen),
      ])
  }

  /// Records a failed request by its name and the kind of failure. The error's message stays out of the log.
  func recordError(_ op: String, _ error: Error) {
    let place = ActivityKinds.requests.contains(op) ? op : "other"
    recordActivity("error", ["where": .string(place), "code": .string(ActivityKinds.errorCode(error))])
  }
}
