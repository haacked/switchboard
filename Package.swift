// swift-tools-version: 6.0
import PackageDescription

// SB_GHOSTTY=1 links the app against libghostty, which bin/build-ghostty builds into .build/ghostty.
// Without it the app builds with SwiftTerm only. The environment variable, not a check for the
// file, decides, because SwiftPM caches the manifest's result and doesn't notice a new file.
let ghosttyPath = ".build/ghostty/GhosttyKit.xcframework"
let hasGhostty = Context.environment["SB_GHOSTTY"] == "1"

let swift5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
  name: "Switchboard",
  platforms: [.macOS(.v14)],
  products: [
    .executable(name: "sbd", targets: ["sbd"]),
    .executable(name: "sb", targets: ["sb"]),
    .executable(name: "Switchboard", targets: ["SwitchboardApp"]),
  ],
  dependencies: [
    .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.99.1")
  ],
  targets: (hasGhostty ? [.binaryTarget(name: "GhosttyKit", path: ghosttyPath)] : []) + [
    .target(name: "SwitchboardCore", swiftSettings: swift5),
    .target(name: "SwitchboardService", dependencies: ["SwitchboardCore"], swiftSettings: swift5),
    .executableTarget(name: "sbd", dependencies: ["SwitchboardService"], swiftSettings: swift5),
    .executableTarget(name: "sb", dependencies: ["SwitchboardCore"], swiftSettings: swift5),
    .executableTarget(
      name: "SwitchboardApp",
      dependencies: ["SwitchboardCore", .product(name: "SwiftTerm", package: "SwiftTerm")]
        + (hasGhostty ? ["GhosttyKit"] : []),
      swiftSettings: swift5 + (hasGhostty ? [.define("SB_GHOSTTY")] : []),
      linkerSettings: hasGhostty
        ? [
          .linkedLibrary("c++"),
          .linkedFramework("Metal"), .linkedFramework("MetalKit"), .linkedFramework("QuartzCore"),
          .linkedFramework("CoreText"), .linkedFramework("CoreGraphics"), .linkedFramework("CoreVideo"),
          .linkedFramework("IOSurface"), .linkedFramework("Carbon"), .linkedFramework("AppKit"),
        ] : []),
    .testTarget(
      name: "SwitchboardCoreTests", dependencies: ["SwitchboardCore"], exclude: ["Fixtures"], swiftSettings: swift5),
    .testTarget(
      name: "SwitchboardAppTests", dependencies: ["SwitchboardApp", "SwitchboardCore"], swiftSettings: swift5),
    .testTarget(
      name: "IntegrationTests", dependencies: ["SwitchboardCore", "sbd", "sb"],
      exclude: ["Fixtures"], swiftSettings: swift5),
  ]
)
