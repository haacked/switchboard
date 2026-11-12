import AppKit
import SwiftTerm

/// The colors of a SwiftTerm pane in one appearance. The initializer resolves the system colors to fixed
/// sRGB values. SwiftTerm copies the foreground and background into the terminal as RGB when the view sets
/// them. Programs read that copy when they ask the terminal for its colors.
struct TerminalTheme {
  let foreground: NSColor
  let background: NSColor
  let selection: NSColor
  let ansi: [SwiftTerm.Color]
  let scheme: TerminalColorScheme

  init(appearance: NSAppearance) {
    var colors: [NSColor] = []
    appearance.performAsCurrentDrawingAppearance {
      colors = [NSColor.textColor, .textBackgroundColor, .selectedTextBackgroundColor].map {
        $0.usingColorSpace(.sRGB) ?? $0
      }
    }
    foreground = colors[0]
    background = colors[1]
    selection = colors[2]
    let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    ansi = isDark ? Self.dark : Self.light
    scheme = isDark ? .dark : .light
  }

  func apply(to view: TerminalView) {
    view.nativeForegroundColor = foreground
    view.nativeBackgroundColor = background
    view.selectedTextBackgroundColor = selection
    view.selectedTextForegroundColor = foreground
    view.installColors(ansi)
    // SwiftTerm reports .dark until told otherwise. Programs that subscribed with mode 2031, such as tmux,
    // read the new colors again when this call notifies them.
    view.updateColorScheme(scheme)
  }

  // Both palettes start from GitHub's Primer terminal colors. The light palette darkens some of them so that
  // every color except bright white reaches 4.5:1 against white.
  private static let light = palette([
    0x24292f, 0xc4261d, 0x116329, 0x7a5200, 0x0550ae, 0x8231a8, 0x0b6e78, 0x6e7781,
    0x57606a, 0xa40e26, 0x1a7f37, 0x8a5d00, 0x0969da, 0xa230b4, 0x1b7c83, 0x8c959f,
  ])

  private static let dark = palette([
    0x484f58, 0xff7b72, 0x3fb950, 0xd29922, 0x58a6ff, 0xbc8cff, 0x39c5cf, 0xb1bac4,
    0x6e7681, 0xffa198, 0x56d364, 0xe3b341, 0x79c0ff, 0xd2a8ff, 0x56d4dd, 0xffffff,
  ])

  private static func palette(_ rgb: [UInt32]) -> [SwiftTerm.Color] {
    rgb.map {
      SwiftTerm.Color(red8: UInt16($0 >> 16 & 0xff), green8: UInt16($0 >> 8 & 0xff), blue8: UInt16($0 & 0xff))
    }
  }
}

/// A SwiftTerm view that recolors itself when the app or system switches between light and dark. With
/// `newlineOnShiftReturn` set, Shift+Return sends ESC CR instead of CR.
final class ThemedTerminalView: LocalProcessTerminalView {
  /// Shift+Return sends `TerminalReturnKey.newline` instead of CR.
  var newlineOnShiftReturn = false

  // SwiftTerm's keyDown is not open. Without the kitty keyboard protocol, it passes Return to
  // interpretKeyEvents, which it does not override. Its doCommand then sends CR.
  override func interpretKeyEvents(_ eventArray: [NSEvent]) {
    if newlineOnShiftReturn, let event = eventArray.first, eventArray.count == 1, event.type == .keyDown,
      TerminalReturnKey.sendsNewline(
        keyCode: event.keyCode, modifiers: event.modifierFlags, composing: hasMarkedText(),
        kittyKeyboard: !keyboardEnhancementFlags.isEmpty)
    {
      send(TerminalReturnKey.newline)
      return
    }
    super.interpretKeyEvents(eventArray)
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    TerminalTheme(appearance: effectiveAppearance).apply(to: self)
    // Programs choose truecolor text for either a light or a dark background. A Claude Code theme set to
    // dark, for example, sends light text that is unreadable on a light pane. SwiftTerm lightens or darkens
    // text whose contrast falls below this ratio. VS Code's terminal uses the same default.
    minimumContrastRatio = 4.5
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    TerminalTheme(appearance: effectiveAppearance).apply(to: self)
  }
}
