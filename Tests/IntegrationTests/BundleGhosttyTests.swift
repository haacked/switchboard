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

  @Test(arguments: ["ghostty/themes", "ghostty/shell-integration", "terminfo"])
  func refusesAnIncompleteShare(missing: String) throws {
    let dir = try scratch()
    defer { try? FileManager.default.removeItem(at: dir) }
    let share = dir.appendingPathComponent("share")
    for part in ["ghostty/themes", "ghostty/shell-integration", "terminfo"] where part != missing {
      try touch(share, "\(part)/f")
    }
    let resources = dir.appendingPathComponent("Resources")
    let r = try run(share: share, into: resources)
    #expect(r.status != 0)
    #expect(r.stderr.contains(missing))
    #expect(!exists(resources, "ghostty"))
  }
}
