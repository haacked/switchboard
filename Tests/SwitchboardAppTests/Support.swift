import AppKit
import SwiftTerm
import SwiftUI
import SwitchboardCore
import Testing
import os

@testable import SwitchboardApp

final class Counter: Sendable {
  private let count = OSAllocatedUnfairLock(initialState: 0)
  var value: Int { count.withLock { $0 } }
  @discardableResult func increment() -> Int {
    count.withLock {
      $0 += 1
      return $0
    }
  }
}

struct Boom: Error {}

struct Refusal: Error, CustomStringConvertible {
  var description: String
}

/// Waits for the main-actor work that `perform` queues after the request ends.
@MainActor func settle(_ done: () -> Bool) async {
  for _ in 0..<300 where !done() { try? await Task.sleep(nanoseconds: 10_000_000) }
}

// MARK: - Models

/// A client that finds no sbd, so a request fails at once. `Client()` reads
/// `SB_HOME`, which can name the user's running sbd. A refresh from that sbd
/// replaces the test's groups and sessions.
func offlineClient() -> Client {
  Client(home: Home(path: NSTemporaryDirectory() + "no-sbd-" + UUID().uuidString))
}

/// A model on `offlineClient()`. `apply` sets the Dock badge, which needs NSApp.
@MainActor
func offlineModel() -> BoardModel {
  _ = NSApplication.shared
  return BoardModel(client: offlineClient())
}

/// A model like `offlineModel`, built with an org filter and an optional store for it.
@MainActor
func orgFilterModel(_ filter: OrgFilter = OrgFilter(), store: UserDefaults? = nil) -> BoardModel {
  _ = NSApplication.shared
  return BoardModel(client: offlineClient(), orgFilterStore: store, orgFilter: filter)
}

let posthogOnly = OrgFilter(keys: ["posthog"])

/// A model that has applied `list`.
@MainActor
func appliedModel(_ list: [SessionSummary], followups: [SessionSummary]? = nil) -> BoardModel {
  let model = offlineModel()
  model.apply(.success(list), followups: followups)
  return model
}

/// Runs `action` on a model whose `send` counts requests, waits until sbd gets
/// the first one, and returns that request and the count at that moment.
@MainActor
func firstRequest(_ action: (BoardModel) -> Void) async -> (op: String, args: [String: JSON], count: Int) {
  let model = offlineModel()
  let sent = Counter()
  let (op, args) = await withCheckedContinuation { first in
    model.send = { op, args in
      if sent.increment() == 1 { first.resume(returning: (op, args)) }
      return .null
    }
    action(model)
  }
  return (op, args, sent.value)
}

@MainActor
final class Field {
  var text: String
  init(_ text: String) { self.text = text }
  var binding: Binding<String> { Binding(get: { self.text }, set: { self.text = $0 }) }
}

/// A model whose requests wait until the test signals the semaphore. The
/// counter counts the requests that reach sbd.
@MainActor
func heldModel() -> (BoardModel, DispatchSemaphore, Counter) {
  let model = offlineModel()
  let release = DispatchSemaphore(value: 0)
  let requests = Counter()
  model.send = { _, _ in
    requests.increment()
    release.wait()
    return .null
  }
  return (model, release, requests)
}

// MARK: - Sessions

/// A session whose triage item is a decision, or a card when `card` is true.
func needsItem(_ id: String, manager: Bool = false, state: AttentionState = .needsYou, card: Bool = false)
  -> SessionSummary
{
  var s = SessionSummary(
    id: id, name: id, cwd: "/tmp", repo: nil, branch: nil, claudeSessionId: id, state: state, reason: "",
    since: 0, lastActivity: 0, live: true, claudePid: nil, attached: false, lastReply: nil, waits: [], notes: [])
  s.triage = TriageItem(title: "Pick one", kind: .decision, summary: "", source: card ? .card : .summary)
  s.manager = manager ? true : nil
  if manager { s.kind = .manager }
  return s
}

/// The chat of group `group`, whose triage item is a decision.
func chatItem(_ id: String, group: String, state: AttentionState = .needsYou) -> SessionSummary {
  var s = needsItem(id, state: state)
  s.chat = group
  s.kind = .chat
  return s
}

/// A work session in its own folder whose remotes sbd has read, or not read when `read` is nil.
func orgSession(
  _ id: String, _ repository: String?, read: Bool? = true, state: AttentionState = .working, group: String? = nil
) -> SessionSummary {
  var s = needsItem(id, state: state)
  s.cwd = "/r/\(id)"
  s.repo = "/r/\(id)"
  s.repository = repository
  s.repositoryRead = read
  s.group = group
  return s
}

/// A follow-up that has not started. It shows in the sidebar's Not started section, which starts collapsed.
func unstartedFollowup(_ id: String, _ repository: String? = nil) -> SessionSummary {
  var s = needsItem(id, state: .notStarted)
  s.cwd = ""
  s.followup = Followup(prompt: "p", repository: repository)
  return s
}

/// A finished session that holds `notes`, in the worktree of branch haacked/fix.
func notedSession(_ notes: [Note], state: AttentionState = .done, id: String = "s1") -> SessionSummary {
  SessionSummary(
    id: id, name: "fix", cwd: "/worktrees/posthog/haacked/fix", repo: "/repos/posthog", branch: "haacked/fix",
    claudeSessionId: "c", state: state, reason: "", since: 0, lastActivity: 0, live: false, claudePid: nil,
    attached: false, lastReply: nil, waits: [], notes: notes)
}

// MARK: - Cards

/// A permission card that asks to run `ls` in the session.
func permissionCard(_ id: Int64, session: String, hookClosed: Bool = false) throws -> Card {
  let json: JSON = [
    "id": .number(Double(id)), "session": .string(session), "kind": "permission", "tool": "Bash", "summary": "`ls`",
    "input": [:], "questions": [], "since": 0, "deferred": false, "hookClosed": .bool(hookClosed),
  ]
  return try JSONCoding.convert(json, to: Card.self)
}

// MARK: - Notes and issues

/// A plain note, or a to-do when `kind` is `.todo`. A nil `kind` is a row that an older sbd stored.
func noteFixture(_ id: String, _ text: String, kind: Note.Kind? = .note, resolved: Bool = false, t: Int64 = 0) -> Note {
  var n = Note(id: id, text: text, by: .you, t: t, kind: kind)
  if resolved { n.resolved = Note.Resolution(t: t + 1, by: .you, how: "resolved") }
  return n
}

func todoFixture(_ id: String, _ text: String, resolved: Bool = false) -> Note {
  noteFixture(id, text, kind: .todo, resolved: resolved)
}

/// An issue that the session's PR body links.
func bodyIssue(_ number: Int, _ repo: String = "PostHog/posthog") -> SessionIssue {
  SessionIssue(repo: repo, number: number, via: .body, url: "https://github.com/\(repo)/issues/\(number)")
}

/// An issue that the session's branch name links.
let branchIssue = SessionIssue(repo: nil, number: 123, via: .branch, url: nil)

// MARK: - Keys and colors

extension EventModifiers {
  /// SwiftUI's `.function`, which macOS 12 deprecates. AppKit still sets the
  /// flag on arrow keys. SwiftUI passes it on in a key press's modifiers.
  static let functionKey = EventModifiers(rawValue: 64)
}

enum Mode: String, CaseIterable, CustomTestStringConvertible {
  case light, dark

  var appearance: NSAppearance { NSAppearance(named: self == .light ? .aqua : .darkAqua)! }
  var other: Mode { self == .light ? .dark : .light }
  var testDescription: String { rawValue }
}

struct RGB: Equatable {
  let red: Double
  let green: Double
  let blue: Double

  static let black = RGB(red: 0, green: 0, blue: 0)

  /// WCAG 2 relative luminance.
  var luminance: Double {
    func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
  }

  /// WCAG 2 contrast ratio, from 1 to 21.
  func contrast(with other: RGB) -> Double {
    let (high, low) = (max(luminance, other.luminance), min(luminance, other.luminance))
    return (high + 0.05) / (low + 0.05)
  }

  func isClose(to other: RGB) -> Bool {
    let tolerance = 1.0 / 255
    return abs(red - other.red) <= tolerance && abs(green - other.green) <= tolerance
      && abs(blue - other.blue) <= tolerance
  }
}

extension RGB {
  init(_ color: SwiftTerm.Color) {
    self.init(red: Double(color.red) / 65535, green: Double(color.green) / 65535, blue: Double(color.blue) / 65535)
  }

  /// Converts a color without resolving it under an appearance. A dynamic system color that
  /// `TerminalTheme` left unresolved therefore fails the tests instead of passing.
  init(_ color: NSColor, over backdrop: RGB = .black) {
    let srgb = color.usingColorSpace(.sRGB)!
    let alpha = Double(srgb.alphaComponent)
    // AppKit draws a translucent color over the backdrop. The reader sees the blend.
    self.init(
      red: Double(srgb.redComponent) * alpha + backdrop.red * (1 - alpha),
      green: Double(srgb.greenComponent) * alpha + backdrop.green * (1 - alpha),
      blue: Double(srgb.blueComponent) * alpha + backdrop.blue * (1 - alpha))
  }
}
