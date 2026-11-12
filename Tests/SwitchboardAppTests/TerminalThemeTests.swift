import AppKit
import SwiftTerm
import Testing

@testable import SwitchboardApp

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

@MainActor
@Suite struct TerminalThemeColors {
  func theme(_ mode: Mode) -> TerminalTheme { TerminalTheme(appearance: mode.appearance) }
  func background(_ mode: Mode) -> RGB { RGB(theme(mode).background) }
  func foreground(_ mode: Mode) -> RGB { RGB(theme(mode).foreground) }
  func selection(_ mode: Mode) -> RGB { RGB(theme(mode).selection, over: background(mode)) }

  // Text needs 4.5:1. In the light palette every color except bright white meets it. In the dark palette black
  // sits close to the background on purpose. Bright black is the muted gray for secondary text.
  nonisolated static let minimumContrast: [(Mode, Int, Double)] =
    (0...14).map { (Mode.light, $0, 4.5) }
    + [1, 2, 3, 4, 5, 6, 7, 9, 10, 11, 12, 13, 14, 15].map { (Mode.dark, $0, 4.5) }
    + [(Mode.dark, 8, 3.0)]

  @Test func lightAppearanceHasLightBackground() {
    #expect(background(.light).luminance > 0.5)
  }

  @Test func lightAppearanceHasDarkForeground() {
    #expect(foreground(.light).luminance < 0.2)
  }

  @Test func darkAppearanceHasDarkBackground() {
    #expect(background(.dark).luminance < 0.1)
  }

  @Test func darkAppearanceHasLightForeground() {
    #expect(foreground(.dark).luminance > 0.5)
  }

  @Test func lightAndDarkPalettesDiffer() {
    #expect(theme(.light).ansi != theme(.dark).ansi)
  }

  @Test(arguments: Mode.allCases)
  func paletteHasSixteenColors(mode: Mode) {
    #expect(theme(mode).ansi.count == 16)
  }

  @Test(arguments: minimumContrast)
  func ansiColorReadsOnBackground(mode: Mode, index: Int, minimum: Double) throws {
    let ansi = theme(mode).ansi
    try #require(ansi.count == 16)

    let ratio = RGB(ansi[index]).contrast(with: background(mode))

    #expect(ratio >= minimum, "ANSI \(index) in \(mode) has contrast \(ratio)")
  }

  // SGR 2 dims the foreground. The full foreground therefore needs headroom above 4.5:1.
  @Test(arguments: Mode.allCases)
  func foregroundHasHeadroomForDimText(mode: Mode) {
    let ratio = foreground(mode).contrast(with: background(mode))

    #expect(ratio >= 7, "foreground in \(mode) has contrast \(ratio)")
  }

  @Test(arguments: Mode.allCases)
  func foregroundReadsOnSelection(mode: Mode) {
    let ratio = foreground(mode).contrast(with: selection(mode))

    #expect(ratio >= 4.5, "foreground on selection in \(mode) has contrast \(ratio)")
  }

  @Test(arguments: Mode.allCases)
  func selectionIsVisibleOnBackground(mode: Mode) {
    #expect(selection(mode).contrast(with: background(mode)) >= 1.1)
  }
}

// SwiftTerm already redraws its default foreground and background in the new appearance. Its default
// selection color is a fixed teal. The selection therefore shows whether the view applied the theme
// after a switch.
@MainActor
@Suite struct ThemedTerminalViewAppearance {
  func makeView() -> ThemedTerminalView { ThemedTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200)) }
  func theme(_ mode: Mode) -> TerminalTheme { TerminalTheme(appearance: mode.appearance) }

  // The layer fills the view around the cells. A mismatch would show as a seam.
  @Test(arguments: Mode.allCases)
  func backgroundMatchesTheme(mode: Mode) {
    let view = makeView()

    view.appearance = mode.appearance

    let layer = RGB(NSColor(cgColor: view.layer!.backgroundColor!)!)
    #expect(layer.isClose(to: RGB(theme(mode).background)))
  }

  @Test(arguments: Mode.allCases)
  func switchingAppearanceChangesSelection(from mode: Mode) {
    let view = makeView()
    view.appearance = mode.appearance
    let before = RGB(view.selectedTextBackgroundColor)

    view.appearance = mode.other.appearance

    #expect(before.isClose(to: RGB(theme(mode).selection)))
    #expect(RGB(view.selectedTextBackgroundColor).isClose(to: RGB(theme(mode.other).selection)))
    #expect(RGB(view.nativeForegroundColor).isClose(to: RGB(theme(mode.other).foreground)))
    #expect(RGB(view.selectedTextForegroundColor).isClose(to: RGB(theme(mode.other).foreground)))
  }
}
