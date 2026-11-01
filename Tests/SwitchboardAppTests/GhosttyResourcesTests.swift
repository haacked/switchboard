import Foundation
import Testing

@testable import SwitchboardApp

@Suite struct GhosttyResourcesLocation {
  func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("sb-ghostty-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  func makeResources(at url: URL, terminfoEntry: Bool = true) throws {
    try FileManager.default.createDirectory(
      at: url.appendingPathComponent("themes"), withIntermediateDirectories: true)
    let terminfo = url.deletingLastPathComponent().appendingPathComponent("terminfo/78")
    try FileManager.default.createDirectory(at: terminfo, withIntermediateDirectories: true)
    if terminfoEntry { try Data("x".utf8).write(to: terminfo.appendingPathComponent("xterm-ghostty")) }
  }

  @Test func bundledAppUsesItsResourcesFolder() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let resources = root.appendingPathComponent("App.app/Contents/Resources")
    try makeResources(at: resources.appendingPathComponent("ghostty"))
    let found = GhosttyResources.locate(
      resourceURL: resources, executableURL: root.appendingPathComponent("App.app/Contents/MacOS/App"),
      inBundle: true)
    #expect(found?.path == resources.appendingPathComponent("ghostty").path)
  }

  @Test func bundledAppWithoutTheFolderFindsNothing() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let resources = root.appendingPathComponent("App.app/Contents/Resources")
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    #expect(
      GhosttyResources.locate(
        resourceURL: resources,
        executableURL: resources.deletingLastPathComponent().appendingPathComponent("MacOS/App"),
        inBundle: true) == nil)
  }

  @Test func bundledAppIgnoresThemesThatIsAFile() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let resources = root.appendingPathComponent("App.app/Contents/Resources")
    try makeResources(at: resources.appendingPathComponent("ghostty"))
    try FileManager.default.removeItem(at: resources.appendingPathComponent("ghostty/themes"))
    try Data().write(to: resources.appendingPathComponent("ghostty/themes"))
    #expect(GhosttyResources.locate(resourceURL: resources, executableURL: nil, inBundle: true) == nil)
  }

  @Test func bundledAppDoesNotSearchForADevelopmentBuild() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    try makeResources(at: root.appendingPathComponent(".build/ghostty/share/ghostty"))
    let exe = root.appendingPathComponent("App.app/Contents/MacOS/App")
    #expect(GhosttyResources.locate(resourceURL: nil, executableURL: exe, inBundle: true) == nil)
  }

  @Test func developmentBuildSearchesUpwardFromTheExecutable() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let share = root.appendingPathComponent(".build/ghostty/share/ghostty")
    try makeResources(at: share)
    let exe = root.appendingPathComponent(".build/arm64-apple-macosx/debug/Switchboard")
    #expect(GhosttyResources.locate(resourceURL: nil, executableURL: exe, inBundle: false)?.path == share.path)
  }

  @Test func developmentBuildWithoutLibghosttyFindsNothing() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let exe = root.appendingPathComponent(".build/debug/Switchboard")
    #expect(GhosttyResources.locate(resourceURL: nil, executableURL: exe, inBundle: false) == nil)
  }

  @Test func bundledAppIgnoresResourcesWithoutTheTerminfoEntry() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let resources = root.appendingPathComponent("App.app/Contents/Resources")
    try makeResources(at: resources.appendingPathComponent("ghostty"), terminfoEntry: false)
    #expect(GhosttyResources.locate(resourceURL: resources, executableURL: nil, inBundle: true) == nil)
  }

  @Test func bundledAppIgnoresATerminfoEntryThatIsADirectory() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let resources = root.appendingPathComponent("App.app/Contents/Resources")
    try makeResources(at: resources.appendingPathComponent("ghostty"), terminfoEntry: false)
    try FileManager.default.createDirectory(
      at: resources.appendingPathComponent("terminfo/78/xterm-ghostty"), withIntermediateDirectories: true)
    #expect(GhosttyResources.locate(resourceURL: resources, executableURL: nil, inBundle: true) == nil)
  }

  @Test func developmentBuildIgnoresResourcesWithoutTheTerminfoEntry() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    try makeResources(at: root.appendingPathComponent(".build/ghostty/share/ghostty"), terminfoEntry: false)
    let exe = root.appendingPathComponent(".build/debug/Switchboard")
    #expect(GhosttyResources.locate(resourceURL: nil, executableURL: exe, inBundle: false) == nil)
  }
}
