// swift-tools-version: 6.0
import PackageDescription

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
  targets: [
    .target(name: "SwitchboardCore", swiftSettings: swift5),
    .target(name: "SwitchboardService", dependencies: ["SwitchboardCore"], swiftSettings: swift5),
    .executableTarget(name: "sbd", dependencies: ["SwitchboardService"], swiftSettings: swift5),
    .executableTarget(name: "sb", dependencies: ["SwitchboardCore"], swiftSettings: swift5),
    .executableTarget(
      name: "SwitchboardApp",
      dependencies: ["SwitchboardCore", .product(name: "SwiftTerm", package: "SwiftTerm")],
      swiftSettings: swift5),
    .testTarget(name: "SwitchboardCoreTests", dependencies: ["SwitchboardCore"], swiftSettings: swift5),
    .testTarget(
      name: "IntegrationTests", dependencies: ["SwitchboardCore", "sbd", "sb"],
      exclude: ["Fixtures"], swiftSettings: swift5),
  ]
)
