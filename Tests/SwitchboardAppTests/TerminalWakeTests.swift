import AppKit
import SwitchboardCore
import Testing

@testable import SwitchboardApp

/// A stopped session's Claude terminal resumes the session on a plain key or a click. ⌘ keys stay menu
/// shortcuts and copies, ⌘-click opens a link, and a drag selects text to copy.
struct TerminalWakeTests {
  /// Every combination of Shift, Control, Option, and Command.
  static let allModifiers: [NSEvent.ModifierFlags] = (0..<16).map { bits in
    [NSEvent.ModifierFlags.shift, .control, .option, .command].enumerated()
      .filter { bits & (1 << $0.offset) != 0 }
      .reduce(into: NSEvent.ModifierFlags()) { $0.insert($1.element) }
  }

  /// Flags that must not change the result. An arrow key carries the function and numeric pad flags. A real
  /// event also carries device-dependent bits below the device-independent mask, such as 0x10 for a right ⌘.
  static let otherFlags: [NSEvent.ModifierFlags] = [
    [], .capsLock, [.function, .numericPad], .help, NSEvent.ModifierFlags(rawValue: 0x10),
  ]

  // MARK: Keys

  @Suite struct TerminalWakeKeys {
    @Test(arguments: TerminalWakeTests.allModifiers, TerminalWakeTests.otherFlags)
    func onlyAKeyWithoutCommandWakes(modifiers: NSEvent.ModifierFlags, extra: NSEvent.ModifierFlags) {
      #expect(TerminalWake.wakes(key: modifiers.union(extra)) == !modifiers.contains(.command))
    }

    @Test(arguments: [NSEvent.ModifierFlags(), .shift, .option, .control])
    func aPlainShiftOptionOrControlKeyWakes(_ modifiers: NSEvent.ModifierFlags) {
      #expect(TerminalWake.wakes(key: modifiers))
    }

    @Test func aCommandKeyDoesNotWake() {
      #expect(!TerminalWake.wakes(key: .command))
    }
  }

  // MARK: Clicks

  @Suite struct TerminalWakeClicks {
    static let down = CGPoint(x: 100, y: 100)

    /// Mouse-up offsets from the mouse-down that are a click. The spec names no metric for a diagonal, so the
    /// diagonal here stays under 4 pt by either measure.
    static let clicks: [CGSize] = [
      .zero, CGSize(width: 1, height: 0), CGSize(width: 3, height: 0), CGSize(width: 4, height: 0),
      CGSize(width: -4, height: 0), CGSize(width: 0, height: 4), CGSize(width: 0, height: -4),
      CGSize(width: 2, height: 2),
    ]

    /// Mouse-up offsets that are a drag. The diagonal is over 5 pt by either measure.
    static let drags: [CGSize] = [
      CGSize(width: 5, height: 0), CGSize(width: -5, height: 0), CGSize(width: 0, height: 5),
      CGSize(width: 0, height: -5), CGSize(width: 5, height: 5), CGSize(width: 40, height: 0),
      CGSize(width: 0, height: -40),
    ]

    static func up(_ offset: CGSize) -> CGPoint { CGPoint(x: down.x + offset.width, y: down.y + offset.height) }

    @Test(arguments: clicks)
    func aMouseUpWithinFourPointsIsAClick(_ offset: CGSize) {
      #expect(TerminalWake.isClick(down: Self.down, up: Self.up(offset), modifiers: []))
    }

    @Test(arguments: drags)
    func aMouseUpFiveOrMorePointsAwayIsADrag(_ offset: CGSize) {
      #expect(!TerminalWake.isClick(down: Self.down, up: Self.up(offset), modifiers: []))
    }

    /// A ⌘-click opens a link.
    @Test(arguments: TerminalWakeTests.allModifiers, TerminalWakeTests.otherFlags)
    func onlyAClickWithoutCommandWakes(modifiers: NSEvent.ModifierFlags, extra: NSEvent.ModifierFlags) {
      let click = TerminalWake.isClick(down: Self.down, up: Self.down, modifiers: modifiers.union(extra))

      #expect(click == !modifiers.contains(.command))
    }

    /// The ⌘ test above holds the points still, so a drag with ⌘ checks that neither rule wins alone.
    @Test func aCommandDragDoesNotWake() {
      #expect(!TerminalWake.isClick(down: Self.down, up: Self.up(CGSize(width: 40, height: 0)), modifiers: .command))
    }
  }

  // MARK: Sessions

  @Suite struct TerminalWakeSessions {
    /// A work session whose claude has stopped.
    static func stopped(_ id: String = "a") -> SessionSummary {
      var s = needsItem(id, state: .waiting)
      s.live = false
      s.claudePid = nil
      return s
    }

    enum Waking: CaseIterable {
      case work, notQueued, chat, manager

      var session: SessionSummary {
        var s = TerminalWakeSessions.stopped()
        switch self {
        case .work: break
        case .notQueued: s.queued = false
        case .chat:
          s.chat = "g1"
          s.kind = .chat
        case .manager:
          s.manager = true
          s.kind = .manager
        }
        return s
      }
    }

    enum Sleeping: CaseIterable {
      case live, queued, cleanedUp, docketRow, followupNotStarted, unstartedFollowupWithFolder

      var session: SessionSummary {
        var s = TerminalWakeSessions.stopped()
        switch self {
        case .live:
          s.live = true
          s.claudePid = 42
        case .queued:
          s.queued = true
        case .cleanedUp:
          s.cleanup = CleanupStatus(state: .removed)
        case .docketRow:
          s = docketSession("a")
          s.live = false
        case .followupNotStarted:
          s = unstartedFollowup("a")
          s.live = false
        case .unstartedFollowupWithFolder:
          s.followup = Followup(prompt: "p")
        }
        return s
      }
    }

    /// A stopped chat or Manager shows its Claude terminal in its own view.
    @Test(arguments: Waking.allCases)
    func aStoppedSessionWithAClaudeTerminalWakes(_ kind: Waking) {
      #expect(kind.session.wakesOnTerminalInput)
    }

    /// A queued session waits for a live slot, and `open` would jump the queue. A session with no Claude
    /// terminal has nothing to type into.
    @Test(arguments: Sleeping.allCases)
    func aSessionThatIsLiveQueuedOrHasNoClaudeTerminalDoesNotWake(_ kind: Sleeping) {
      #expect(!kind.session.wakesOnTerminalInput)
    }
  }
}
