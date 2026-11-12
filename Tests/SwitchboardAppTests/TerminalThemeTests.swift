import AppKit
import SwiftTerm
import Testing

@testable import SwitchboardApp

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
