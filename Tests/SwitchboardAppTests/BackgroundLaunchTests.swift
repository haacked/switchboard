import AppKit
import Testing

@testable import SwitchboardApp

@MainActor
struct BackgroundLaunchTests {
  @Test(arguments: ["SB_SNAPSHOT", "SB_TERMINAL_TEST", "SB_DRAFT_TEST", "SB_QUIT_FILE"])
  func scriptedHookRunsInTheBackground(hook: String) {
    #expect(BackgroundLaunch.applies(to: [hook: "/tmp/x"]))
  }

  @Test func plainLaunchIsNotInTheBackground() {
    #expect(!BackgroundLaunch.applies(to: [:]))
    #expect(!BackgroundLaunch.applies(to: ["HOME": "/Users/me", "SB_HOME": "/tmp/sb"]))
  }

  @Test(arguments: ["SB_SELECT", "SB_INBOX", "SB_BOARD_CLICK", "SB_JUMP", "SB_SHEET"])
  func hookThatOnlyChoosesWhatToShowIsNotInTheBackground(hook: String) {
    #expect(!BackgroundLaunch.applies(to: [hook: "s1"]))
  }

  @Test func testVisibleShowsAScriptedLaunch() {
    #expect(!BackgroundLaunch.applies(to: ["SB_SNAPSHOT": "/tmp/x.png", "SB_TEST_VISIBLE": "1"]))
    #expect(BackgroundLaunch.applies(to: ["SB_SNAPSHOT": "/tmp/x.png", "SB_TEST_VISIBLE": "0"]))
  }

  private func window(_ style: NSWindow.StyleMask = [.titled]) -> NSWindow {
    _ = NSApplication.shared
    return NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: style, backing: .buffered, defer: true)
  }

  @Test func hiddenWindowIsTransparentAndIgnoresTheMouse() {
    let window = window()
    BackgroundLaunch.hide(window)
    #expect(window.alphaValue == 0)
    #expect(window.ignoresMouseEvents)
  }

  @Test func hiddenSheetIsTransparentAndIgnoresTheMouse() {
    let parent = window()
    let sheet = window()
    parent.beginSheet(sheet)
    defer { parent.endSheet(sheet) }
    #expect(sheet.sheetParent === parent)
    BackgroundLaunch.hide(sheet)
    #expect(sheet.alphaValue == 0)
    #expect(sheet.ignoresMouseEvents)
  }

  @Test func sheetOpenedAfterLaunchIsHiddenOnItsFirstUpdate() {
    let center = NotificationCenter()
    let observer = BackgroundLaunch.hideWindowsAsTheyUpdate(center)
    defer { center.removeObserver(observer) }
    let parent = window()
    let sheet = window()
    parent.beginSheet(sheet)
    defer { parent.endSheet(sheet) }
    #expect(sheet.alphaValue == 1)
    center.post(name: NSWindow.didUpdateNotification, object: sheet)
    #expect(sheet.alphaValue == 0)
    #expect(sheet.ignoresMouseEvents)
  }

  @Test func statusItemWindowStaysVisible() {
    let window = window([.borderless])
    window.level = .statusBar
    BackgroundLaunch.hide(window)
    #expect(window.alphaValue == 1)
    #expect(!window.ignoresMouseEvents)
  }
}
