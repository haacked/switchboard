import Foundation

/// A developer folder for one test, built from empty files and folders at the
/// paths that bin/lib/swift-testing.sh checks. Its path has a space in it.
final class FakeDeveloperDir {
  let root: String
  let path: String

  init(folders: [String] = [], files: [String] = []) throws {
    var template = Array("/tmp/sbx.XXXXXX".utf8CString)
    guard let dir = mkdtemp(&template) else { throw TestError(description: "mkdtemp failed") }
    root = String(cString: dir)
    path = "\(root)/Developer dir"
    let fm = FileManager.default
    try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
    for folder in folders {
      try fm.createDirectory(atPath: "\(path)/\(folder)", withIntermediateDirectories: true)
    }
    for file in files {
      let full = "\(path)/\(file)"
      try fm.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
      fm.createFile(atPath: full, contents: nil)
    }
  }

  deinit { try? FileManager.default.removeItem(atPath: root) }

  static let plugins = "usr/lib/swift/host/plugins/testing"
  static let frameworks = "Library/Developer/Frameworks"
  static let cltFramework = "\(frameworks)/Testing.framework"
  static let interopDylib = "Library/Developer/usr/lib/lib_TestingInterop.dylib"
  static let xcodeFramework = "Platforms/MacOSX.platform/Developer/Library/Frameworks/Testing.framework"

  enum Flag: Sendable { case plugin, framework, dylib }

  func flags(_ flag: Flag) -> [String] {
    switch flag {
    case .plugin: return ["-Xswiftc", "-plugin-path", "-Xswiftc", "\(path)/\(Self.plugins)"]
    case .framework:
      let dir = "\(path)/\(Self.frameworks)"
      return ["-Xswiftc", "-F", "-Xswiftc", dir, "-Xlinker", "-rpath", "-Xlinker", dir]
    case .dylib: return ["-Xlinker", "-rpath", "-Xlinker", "\(path)/Library/Developer/usr/lib"]
    }
  }
}
