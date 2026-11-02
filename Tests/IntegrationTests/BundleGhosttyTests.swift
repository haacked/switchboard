import Foundation
import SwitchboardCore
import Testing

@Suite struct BundleGhosttyResources {
  let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()

  func scratch() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("sb-bundle-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  func touch(_ root: URL, _ path: String) throws {
    let file = root.appendingPathComponent(path)
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("x".utf8).write(to: file)
  }

  func run(share: URL, into resources: URL) throws -> (status: Int32, stderr: String) {
    let r = try runCommand(
      "/usr/bin/env",
      ["SB_GHOSTTY_SHARE=\(share.path)", repo.appendingPathComponent("bin/bundle-ghostty").path, resources.path],
      timeout: 30)
    return (r.status, r.stderr)
  }

  func exists(_ root: URL, _ path: String) -> Bool {
    FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path)
  }

  @Test func copiesThemesShellIntegrationAndTerminfo() throws {
    let dir = try scratch()
    defer { try? FileManager.default.removeItem(at: dir) }
    let share = dir.appendingPathComponent("share")
    try touch(share, "ghostty/themes/Dark")
    try touch(share, "ghostty/shell-integration/zsh/ghostty-integration")
    try touch(share, "terminfo/78/xterm-ghostty")
    let resources = dir.appendingPathComponent("Resources")
    try touch(resources, "ghostty/stale")
    let r = try run(share: share, into: resources)
    #expect(r.status == 0)
    #expect(exists(resources, "ghostty/themes/Dark"))
    #expect(exists(resources, "ghostty/shell-integration/zsh/ghostty-integration"))
    #expect(exists(resources, "terminfo/78/xterm-ghostty"))
    #expect(!exists(resources, "ghostty/stale"))
  }

  @Test func changesNothingWithoutLibghostty() throws {
    let dir = try scratch()
    defer { try? FileManager.default.removeItem(at: dir) }
    let resources = dir.appendingPathComponent("Resources")
    try touch(resources, "AppIcon.icns")
    let r = try run(share: dir.appendingPathComponent("missing"), into: resources)
    #expect(r.status == 0)
    #expect(try FileManager.default.contentsOfDirectory(atPath: resources.path) == ["AppIcon.icns"])
  }

  @Test(arguments: ["ghostty/themes", "ghostty/shell-integration", "terminfo/78/xterm-ghostty"])
  func refusesAnIncompleteShare(missing: String) throws {
    let dir = try scratch()
    defer { try? FileManager.default.removeItem(at: dir) }
    let share = dir.appendingPathComponent("share")
    for part in ["ghostty/themes/Dark", "ghostty/shell-integration/f", "terminfo/78/xterm-ghostty"]
    where !part.hasPrefix(missing) {
      try touch(share, part)
    }
    if missing.hasPrefix("terminfo") {
      try FileManager.default.createDirectory(
        at: share.appendingPathComponent("terminfo"), withIntermediateDirectories: true)
    }
    let resources = dir.appendingPathComponent("Resources")
    let r = try run(share: share, into: resources)
    #expect(r.status != 0)
    #expect(r.stderr.contains(missing))
    #expect(!exists(resources, "ghostty"))
  }

  @Test func copiesTheFilesThatSymlinksPointTo() throws {
    let dir = try scratch()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = dir.appendingPathComponent("store")
    try touch(store, "ghostty/themes/Dark")
    try touch(store, "ghostty/shell-integration/f")
    try touch(store, "terminfo/78/xterm-ghostty")
    let share = dir.appendingPathComponent("share")
    try FileManager.default.createDirectory(at: share, withIntermediateDirectories: true)
    for name in ["ghostty", "terminfo"] {
      try FileManager.default.createSymbolicLink(
        at: share.appendingPathComponent(name), withDestinationURL: store.appendingPathComponent(name))
    }
    let resources = dir.appendingPathComponent("Resources")
    #expect(try run(share: share, into: resources).status == 0)
    for name in ["ghostty", "terminfo"] {
      let attributes = try FileManager.default.attributesOfItem(atPath: resources.appendingPathComponent(name).path)
      #expect(attributes[.type] as? FileAttributeType == .typeDirectory)
    }
    #expect(exists(resources, "terminfo/78/xterm-ghostty"))
  }

  @Test func refusesAnEmptyTerminfoFolder() throws {
    let dir = try scratch()
    defer { try? FileManager.default.removeItem(at: dir) }
    let share = dir.appendingPathComponent("share")
    try touch(share, "ghostty/themes/Dark")
    try touch(share, "ghostty/shell-integration/f")
    try touch(share, "terminfo/f")
    let r = try run(share: share, into: dir.appendingPathComponent("Resources"))
    #expect(r.status != 0)
  }
}
