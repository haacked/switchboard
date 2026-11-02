import Foundation
import Testing

@Suite struct BinDir {
  @Test func followsTheConfigurationTheTestsWereBuiltWith() {
    let release = "/repo/.build/arm64-apple-macosx/release/SwitchboardPackageTests.xctest"
    #expect(Instance.binDir(testBundle: release, override: nil) == "/repo/.build/arm64-apple-macosx/release")
  }

  @Test func overrideWins() {
    let debug = "/repo/.build/arm64-apple-macosx/debug/SwitchboardPackageTests.xctest"
    #expect(Instance.binDir(testBundle: debug, override: "/custom") == "/custom")
  }

  @Test func findsSbAndSbdNextToTheTestBundle() {
    if ProcessInfo.processInfo.environment["SB_BIN_DIR"] == nil {
      #expect(Bundle(for: Instance.self).bundlePath.hasPrefix(Instance.bin + "/"))
    }
    #expect(FileManager.default.isExecutableFile(atPath: "\(Instance.bin)/sb"))
    #expect(FileManager.default.isExecutableFile(atPath: "\(Instance.bin)/sbd"))
  }
}
