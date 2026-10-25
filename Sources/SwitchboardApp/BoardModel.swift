import AppKit
import Foundation
import SwitchboardCore
import UserNotifications

/// The app's view of sbd. It polls `ls` once a second, because sbd keeps
/// state in memory and answers in a few milliseconds.
@MainActor
final class BoardModel: ObservableObject {
  @Published var sessions: [SessionSummary] = []
  /// Why sbd can't be reached, or nil while it answers.
  @Published var unreachable: String?
  /// The last failed action, shown until the next one succeeds.
  @Published var actionError: String?
  @Published var selection: String?
  @Published var showingNew = false

  let client = Client()
  /// Polls run apart from actions, because an action such as `open` or `new`
  /// can take seconds.
  private let poller = DispatchQueue(label: "switchboard.poll")
  private let worker = DispatchQueue(label: "switchboard.actions")
  private var timer: Timer?
  private var knownStates: [String: AttentionState] = [:]
  private var loaded = false

  var needsYou: [SessionSummary] { sessions.filter { $0.state == .needsYou } }

  var selected: SessionSummary? { sessions.first { $0.id == selection } }

  func start() {
    guard timer == nil else { return }
    if Bundle.main.bundleIdentifier != nil {
      UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
    refresh()
    timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.refresh() }
    }
  }

  func refresh() {
    let client = client
    poller.async {
      let result = Result { try client.sessions() }
      Task { @MainActor in self.apply(result) }
    }
  }

  private func apply(_ result: Result<[SessionSummary], Error>) {
    switch result {
    case .success(let list):
      unreachable = nil
      if loaded {
        for s in list where s.state == .needsYou && knownStates[s.id] != .needsYou && knownStates[s.id] != nil {
          notify(s)
        }
      }
      knownStates = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0.state) })
      loaded = true
      if sessions != list { sessions = list }
      NSApp.dockTile.badgeLabel = needsYou.isEmpty ? nil : "\(needsYou.count)"
    case .failure(let error):
      unreachable = "\(error)"
    }
  }

  private func notify(_ s: SessionSummary) {
    guard Bundle.main.bundleIdentifier != nil else { return }
    let content = UNMutableNotificationContent()
    content.title = "\(s.name) needs you"
    content.body = s.reason
    content.userInfo = ["session": s.id]
    UNUserNotificationCenter.current().add(
      UNNotificationRequest(identifier: "\(s.id)-\(s.since)", content: content, trigger: nil))
  }

  /// Runs a request off the main thread, then refreshes.
  func perform(_ op: String, _ args: [String: JSON], then: ((JSON) -> Void)? = nil) {
    let client = client
    worker.async {
      let result = Result { try client.call(op, args, timeout: 300) }
      Task { @MainActor in
        switch result {
        case .success(let value):
          self.actionError = nil
          then?(value)
        case .failure(let error):
          self.actionError = "\(op): \(error)"
        }
        self.refresh()
      }
    }
  }

  func open(_ id: String) { perform("open", ["session": .string(id)]) }
  func stop(_ id: String) { perform("stop", ["session": .string(id)]) }
  func resume(_ id: String) { perform("resume", ["session": .string(id)]) }
  func setDone(_ id: String, _ done: Bool) { perform("done", ["session": .string(id), "done": .bool(done)]) }
  func send(_ id: String, _ text: String) { perform("send", ["session": .string(id), "text": .string(text)]) }
  func remove(_ id: String) {
    if selection == id { selection = nil }
    perform("rm", ["session": .string(id)])
  }

  func create(_ args: NewSession) {
    guard let json = try? JSON(encoding: args).object else { return }
    perform("new", json) { value in
      if let id = value["id"]?.string { self.selection = id }
    }
  }

  /// Asks sbd for the session's tmux targets. It blocks, so it runs off the
  /// main thread.
  nonisolated func terminals(_ id: String) -> Result<Terminals, Error> {
    Result { try Client().terminals(id) }
  }

  /// Selects the next session that needs you, after the selected one.
  func selectNextNeedingYou() {
    let list = needsYou
    guard !list.isEmpty else { return }
    if let current = selection, let i = list.firstIndex(where: { $0.id == current }) {
      selection = list[(i + 1) % list.count].id
    } else {
      selection = list[0].id
    }
  }

  /// Starts sbd as a launchd agent with the `sb` that ships next to the app.
  func installService() {
    guard let sb = Self.sbPath else {
      actionError = "can't find sb next to the app"
      return
    }
    worker.async {
      let p = Process()
      p.executableURL = URL(fileURLWithPath: sb)
      p.arguments = ["service", "install"]
      let err = Pipe()
      p.standardError = err
      let result = Result { try p.run() }
      p.waitUntilExit()
      let message = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
      Task { @MainActor in
        if case .failure(let e) = result { self.actionError = "\(e)" }
        if p.terminationStatus != 0 { self.actionError = message }
        self.refresh()
      }
    }
  }

  /// The sb binary in the app bundle, or next to the app's executable in a
  /// build folder.
  static var sbPath: String? {
    let path = siblingExecutable("sb")
    return FileManager.default.isExecutableFile(atPath: path) ? path : nil
  }
}
