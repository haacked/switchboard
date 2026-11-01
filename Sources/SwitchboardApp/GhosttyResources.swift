import Foundation
import SwitchboardCore

/// Finds the folder that GHOSTTY_RESOURCES_DIR must name. Ghostty reads themes and shell integration from that
/// folder and finds terminfo in a sibling folder named `terminfo`.
enum GhosttyResources {
  /// The folder is usable when it holds `themes` and the sibling `terminfo` folder holds the xterm-ghostty entry.
  /// Pointing GHOSTTY_RESOURCES_DIR at a folder without that entry makes the child start with an unknown TERM.
  static func isResourcesDir(_ url: URL) -> Bool {
    let entry = url.deletingLastPathComponent().appendingPathComponent("terminfo/78/xterm-ghostty").path
    return isDirectory(url.appendingPathComponent("themes").path)
      && FileManager.default.fileExists(atPath: entry) && !isDirectory(entry)
  }

  /// A bundled app uses only its own Contents/Resources/ghostty, so an unrelated `.build` above the app never
  /// supplies it. A development build searches upward from the executable for `.build/ghostty/share/ghostty`.
  static func locate(resourceURL: URL?, executableURL: URL?, inBundle: Bool) -> URL? {
    if inBundle {
      let bundled = resourceURL?.appendingPathComponent("ghostty")
      return bundled.flatMap { isResourcesDir($0) ? $0 : nil }
    }
    var dir = executableURL?.deletingLastPathComponent()
    for _ in 0..<6 {
      guard let current = dir else { break }
      let candidate = current.appendingPathComponent(".build/ghostty/share/ghostty")
      if isResourcesDir(candidate) { return candidate }
      dir = current.deletingLastPathComponent()
    }
    return nil
  }
}
