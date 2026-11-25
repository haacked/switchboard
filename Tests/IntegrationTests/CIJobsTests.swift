import Foundation
import SwitchboardCore
import Testing

/// The source folder's name. bin/lib/test-selection.sh and bin/lib/ci-jobs treat a test file that finds the repo
/// through #filePath or Instance.root and quotes this name as one that reads the source folder at run time. This file
/// builds the name so that neither script treats this file that way.
private let srcDir = "Sour" + "ces"

/// The app's product name. bin/lib/ci-jobs runs the IntegrationTests parts for an app change when a file in the
/// IntegrationTests folder names this product as the last part of a path. This file builds the name so that a change
/// to the repo's own app still runs only the last part.
private let appProduct = "Switch" + "board"

private let readme = "README.md"

private let allParts = [1, 2, 3, 4]

private let appFile = "\(srcDir)/SwitchboardApp/App.swift"
private let coreFile = "\(srcDir)/SwitchboardCore/Core.swift"
private let unitTestFile = "Tests/SwitchboardCoreTests/FxCoreTests.swift"
private let integrationFile = "Tests/IntegrationTests/FxCLITests.swift"

private func byName(_ name: String) -> [String: Any] { ["byName": [name, NSNull()] as [Any]] }

private func targetDependency(_ name: String) -> [String: Any] { ["target": [name, NSNull()] as [Any]] }

private func product(_ name: String, _ package: String) -> [String: Any] {
  ["product": [name, package, NSNull(), NSNull()] as [Any]]
}

private func target(
  _ name: String, _ type: String, path: String? = nil, exclude: [String] = [], _ dependencies: [[String: Any]]
) -> [String: Any] {
  [
    "name": name, "type": type, "path": path.map { $0 as Any } ?? NSNull(), "exclude": exclude,
    "dependencies": dependencies, "resources": [Any](), "settings": [Any](),
  ]
}

/// The fake package's targets. IntegrationTests reaches SwitchboardCore directly and SwitchboardService through sbd.
/// No target that IntegrationTests reaches depends on SwitchboardApp or SwitchboardCoreKit.
/// `integrationDependencies` replaces the dependencies of IntegrationTests, and `extra` adds targets.
private func packageTargets(
  appPath: String? = nil, integrationDependencies: [[String: Any]]? = nil, extra: [[String: Any]] = []
) -> [[String: Any]] {
  [
    target(
      "SwitchboardCore", "regular",
      [product("cmark-gfm", "swift-cmark"), product("cmark-gfm-extensions", "swift-cmark")]),
    target("SwitchboardCoreKit", "regular", [byName("SwitchboardCore")]),
    target("SwitchboardService", "regular", [byName("SwitchboardCore")]),
    target("sbd", "executable", [byName("SwitchboardService")]),
    target("sb", "executable", [byName("SwitchboardCore")]),
    target(
      "SwitchboardApp", "executable", path: appPath,
      [byName("SwitchboardCore"), byName("SwitchboardCoreKit"), product("SwiftTerm", "SwiftTerm")]),
    target("SwitchboardCoreTests", "test", exclude: ["Fixtures"], [byName("SwitchboardCore")]),
    target("SwitchboardServiceTests", "test", [byName("SwitchboardService"), byName("SwitchboardCore")]),
    target("SwitchboardAppTests", "test", [byName("SwitchboardApp"), byName("SwitchboardCore")]),
    target(
      "IntegrationTests", "test", exclude: ["Fixtures"],
      integrationDependencies ?? [byName("SwitchboardCore"), byName("sbd"), byName("sb")]),
  ] + extra
}

private func executableProduct(_ name: String, _ target: String) -> [String: Any] {
  ["name": name, "targets": [target], "type": ["executable": NSNull()]]
}

/// The package as `swift package dump-package` prints it, with an executable product for each executable target.
private func packageJSON(_ targets: [[String: Any]]) throws -> Data {
  let products = [
    executableProduct(appProduct, "SwitchboardApp"), executableProduct("sbd", "sbd"), executableProduct("sb", "sb"),
  ]
  let package: [String: Any] = ["name": "Switchboard", "products": products, "targets": targets]
  return try JSONSerialization.data(withJSONObject: package, options: [.prettyPrinted, .sortedKeys])
}

private func suiteFile(_ type: String, _ tests: String...) -> String {
  "import Testing\n\nstruct \(type) {\n" + tests.map { "  @Test func \($0)() {}\n" }.joined() + "}\n"
}

/// The repo files that every test starts with. No file names another file's path. bin/test-gui builds the products
/// without the tests. bin/lib/swift-testing.sh defines build_tests, which bin/test-gui does not call.
private let baselineFiles: [String: String] = [
  "Package.swift": "// swift-tools-version: 6.0\n",
  readme: "# Fixture\n",
  "docs/x.md": "# X\n",
  "\(srcDir)/SwitchboardCore/Core.swift": "public func fxCore() -> Int { 1 }\n",
  "\(srcDir)/SwitchboardCoreKit/Kit.swift": "import SwitchboardCore\n\npublic func fxKit() -> Int { fxCore() }\n",
  "\(srcDir)/SwitchboardService/Service.swift":
    "import SwitchboardCore\n\npublic func fxService() -> Int { fxCore() }\n",
  "\(srcDir)/sbd/main.swift": "import SwitchboardService\n\nprint(fxService())\n",
  "\(srcDir)/sb/main.swift": "import SwitchboardCore\n\nprint(fxCore())\n",
  "\(srcDir)/SwitchboardApp/App.swift": "import SwitchboardCore\n\nlet fxLaunched = fxCore()\n",
  "\(srcDir)/SwitchboardApp/Info.plist": "<plist/>\n",
  "Tests/SwitchboardCoreTests/FxCoreTests.swift": suiteFile("FxCoreTests", "parses"),
  "Tests/SwitchboardCoreTests/Fixtures/sample.json": "{}\n",
  "Tests/SwitchboardServiceTests/FxServiceTests.swift": suiteFile("FxServiceTests", "starts"),
  "Tests/SwitchboardAppTests/FxAppTests.swift": suiteFile("FxAppTests", "opens"),
  "Tests/IntegrationTests/FxCLITests.swift": suiteFile("FxCLITests", "lists"),
  "Tests/IntegrationTests/Fixtures/reap": "#!/bin/sh\nexit 0\n",
  "Tests/smoke-suites": "# Smoke suites\nIntegrationTests.FxCLITests\n",
  "Tests/GUI/received-bytes-stub": "#!/bin/sh\ncat\n",
  "bin/test": "#!/bin/sh\nexit 0\n",
  "bin/test-gui": "#!/bin/bash\nsource bin/lib/swift-testing.sh\nswift build --product Switchboard\n",
  "bin/lib/swift-testing.sh": "build_tests() { swift build --build-tests \"$@\"; }\n",
  ".github/workflows/test.yml": "name: Test\n",
]

/// What one run of bin/lib/ci-jobs printed.
private struct CIJobs {
  let result: CommandResult

  var outputs: [String: String] {
    var found: [String: String] = [:]
    for line in result.stdout.split(separator: "\n") {
      guard let eq = line.firstIndex(of: "=") else { continue }
      found[String(line[..<eq])] = String(line[line.index(after: eq)...])
    }
    return found
  }

  var parts: [Int]? {
    outputs["parts"].flatMap { try? JSONDecoder().decode([Int].self, from: Data($0.utf8)) }
  }

  var gui: Bool? {
    switch outputs["gui"] {
    case "true": true
    case "false": false
    default: nil
    }
  }
}

/// A scratch repo with the baseline files, and a package JSON file outside it.
private final class CIJobsRepo {
  let repos: Repos
  let dir: String
  let packagePath: String

  init(files: [String: String] = [:], targets: [[String: Any]] = packageTargets()) throws {
    repos = try Repos()
    dir = "\(repos.root)/repo"
    packagePath = "\(repos.root)/package.json"
    for (path, text) in baselineFiles.merging(files, uniquingKeysWith: { $1 }) { try write(path, text) }
    try packageJSON(targets).write(to: URL(fileURLWithPath: packagePath))
  }

  func write(_ path: String, _ text: String) throws {
    let full = "\(dir)/\(path)"
    try FileManager.default.createDirectory(
      atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try text.write(toFile: full, atomically: true, encoding: .utf8)
  }

  /// Replaces the package JSON file with `text`, or removes it when `text` is nil.
  func setPackage(_ text: String?) throws {
    try? FileManager.default.removeItem(atPath: packagePath)
    if let text { try text.write(toFile: packagePath, atomically: true, encoding: .utf8) }
  }

  /// Runs bin/lib/ci-jobs from the repo with `paths` on stdin, one per line. `count` defaults to the number of
  /// non-empty paths. A nil `parts` leaves SB_CI_PARTS unset.
  func run(_ paths: [String], count: Int? = nil, parts: String? = "4") throws -> CIJobs {
    try run("pr", paths, count: count, parts: parts)
  }

  func run(_ mode: String, _ paths: [String], count: Int? = nil, parts: String? = "4") throws -> CIJobs {
    var env = ProcessInfo.processInfo.environment
    env.removeValue(forKey: "SB_CI_PARTS")
    if let parts { env["SB_CI_PARTS"] = parts }
    let script = Instance.root.appendingPathComponent("bin/lib/ci-jobs").path
    let listed = count ?? paths.filter { !$0.isEmpty }.count
    let input = Data(paths.map { "\($0)\n" }.joined().utf8)
    let result = try runCommand(
      "/bin/bash", [script, mode, String(listed), packagePath], env: env, input: input, timeout: 30, cwd: dir)
    return CIJobs(result: result)
  }
}

private func expectJobs(
  _ run: CIJobs, parts: [Int], gui: Bool, sourceLocation: SourceLocation = #_sourceLocation
) {
  #expect(run.result.status == 0, "\(run.result.stderr)", sourceLocation: sourceLocation)
  #expect(run.parts == parts, "\(run.result.stdout)\n\(run.result.stderr)", sourceLocation: sourceLocation)
  #expect(run.gui == gui, "\(run.result.stdout)\n\(run.result.stderr)", sourceLocation: sourceLocation)
}

private func expectEveryJob(_ run: CIJobs, sourceLocation: SourceLocation = #_sourceLocation) {
  expectJobs(run, parts: allParts, gui: true, sourceLocation: sourceLocation)
}

private func expectNoJob(_ run: CIJobs, sourceLocation: SourceLocation = #_sourceLocation) {
  expectJobs(run, parts: [], gui: false, sourceLocation: sourceLocation)
}

/// Paths that no package target holds.
private let pathsOutsideEveryTarget = [
  "Package.swift", "Package.resolved", ".github/workflows/test.yml", "bin/test", "bin/test-gui",
  "bin/lib/swift-testing.sh", "Tests/smoke-suites", "Tests/GUI/received-bytes-stub", "Tests/Shared.swift",
  "\(srcDir)/FxUnlisted/Thing.swift",
]

/// Paths that a target holds but that are not Swift sources it compiles.
private let pathsInsideATargetThatAreNotSources = [
  "\(srcDir)/SwitchboardApp/Info.plist", "\(srcDir)/SwitchboardApp/Notes.md",
  "Tests/SwitchboardCoreTests/Fixtures/sample.json", "Tests/SwitchboardCoreTests/Fixtures/Nested/Thing.swift",
  "Tests/IntegrationTests/Fixtures/reap", "Tests/IntegrationTests/Fixtures/Stub.swift",
]

private let rootMarkdown = [readme, "FxNotes.md", "-fxnotes.md"]

@Suite(.blocking(timeLimit: .seconds(60))) struct CIJobsTests {
  // MARK: Ready PRs

  /// IntegrationTests does not depend on SwitchboardApp, so an app change needs the last part and gui-test only.
  @Test func anAppSwiftFileRunsTheLastPartAndGuiTest() throws {
    let repo = try CIJobsRepo()

    expectJobs(try repo.run([appFile]), parts: [4], gui: true)
  }

  /// gui-test builds the products without the tests, so a unit test change does not need it.
  @Test(arguments: [
    unitTestFile, "Tests/SwitchboardServiceTests/FxServiceTests.swift", "Tests/SwitchboardAppTests/FxAppTests.swift",
  ])
  func aUnitTestSwiftFileRunsTheLastPartOnly(_ path: String) throws {
    let repo = try CIJobsRepo()

    expectJobs(try repo.run([path]), parts: [4], gui: false)
  }

  @Test func anIntegrationTestsSwiftFileRunsEveryPartWithoutGuiTest() throws {
    let repo = try CIJobsRepo()

    expectJobs(try repo.run([integrationFile]), parts: allParts, gui: false)
  }

  /// SwitchboardService reaches IntegrationTests only through sbd.
  @Test(arguments: [
    coreFile, "\(srcDir)/SwitchboardService/Service.swift", "\(srcDir)/sbd/main.swift", "\(srcDir)/sb/main.swift",
  ])
  func aSourceFileThatIntegrationTestsReachesRunsEveryJob(_ path: String) throws {
    let repo = try CIJobsRepo()

    expectEveryJob(try repo.run([path]))
  }

  /// SwitchboardCoreKit's folder starts with SwitchboardCore's folder name. Only the app depends on it.
  @Test func aTargetWhoseFolderStartsWithAnotherTargetsFolderNameMapsToItsOwnTarget() throws {
    let repo = try CIJobsRepo()

    expectJobs(try repo.run(["\(srcDir)/SwitchboardCoreKit/Kit.swift"]), parts: [4], gui: true)
  }

  @Test func anAppFileAndAnIntegrationFixtureRunEveryJob() throws {
    let repo = try CIJobsRepo()

    expectEveryJob(try repo.run([appFile, "Tests/IntegrationTests/Fixtures/reap"]))
  }

  @Test(arguments: [
    ([appFile, unitTestFile], [4], true),
    ([unitTestFile, integrationFile], allParts, false),
    ([appFile, integrationFile], allParts, true),
    ([appFile, readme], [4], true),
    ([unitTestFile, "docs/x.md"], allParts, true),
  ])
  func aChangeRunsTheUnionOfWhatItsPathsRun(_ paths: [String], _ parts: [Int], _ gui: Bool) throws {
    let repo = try CIJobsRepo()

    expectJobs(try repo.run(paths), parts: parts, gui: gui)
  }

  // MARK: Paths that no rule shows irrelevant

  @Test(arguments: pathsOutsideEveryTarget)
  func aPathOutsideEveryTargetRunsEveryJob(_ path: String) throws {
    let repo = try CIJobsRepo()

    expectEveryJob(try repo.run([path]))
  }

  /// A target's excluded Fixtures folder holds files that tests read at run time, Swift files included.
  @Test(arguments: pathsInsideATargetThatAreNotSources)
  func aNonSourceFileInsideATargetRunsEveryJob(_ path: String) throws {
    let repo = try CIJobsRepo()

    expectEveryJob(try repo.run([path]))
  }

  /// Only Markdown at the repo root can skip a job.
  @Test(arguments: [
    "docs/x.md", "docs/sub/y.md", ".github/FxNotes.md", "Tests/IntegrationTests/Fixtures/notes.md", "bin/FxNotes.md",
  ])
  func markdownOutsideTheRootRunsEveryJob(_ path: String) throws {
    let repo = try CIJobsRepo()

    expectEveryJob(try repo.run([path]))
  }

  // MARK: Markdown

  @Test(arguments: ["pr", "push", "draft"], rootMarkdown)
  func markdownAtTheRepoRootRunsNoJob(_ mode: String, _ path: String) throws {
    let repo = try CIJobsRepo()
    if mode != "pr" { try repo.setPackage(nil) }

    expectNoJob(try repo.run(mode, [path]))
  }

  @Test func rootMarkdownRunsNoJobWithAPackageThatJqCannotRead() throws {
    let repo = try CIJobsRepo()
    try repo.setPackage("not json")

    expectNoJob(try repo.run([readme]))
  }

  // MARK: Counts

  /// A rename lists its old path and its new path for a count of 1.
  @Test func aListLongerThanTheCountRunsEveryJob() throws {
    let repo = try CIJobsRepo()

    expectEveryJob(try repo.run([appFile, "\(srcDir)/SwitchboardApp/Old.swift"], count: 1))
  }

  @Test func aListShorterThanTheCountRunsEveryJob() throws {
    let repo = try CIJobsRepo()

    expectEveryJob(try repo.run([readme], count: 2))
  }

  @Test(arguments: [[appFile], [readme], [String]()])
  func aCountOfZeroRunsEveryJob(_ paths: [String]) throws {
    let repo = try CIJobsRepo()

    expectEveryJob(try repo.run(paths, count: 0))
  }

  @Test(arguments: [0, 2])
  func anEmptyListRunsEveryJob(_ count: Int) throws {
    let repo = try CIJobsRepo()

    expectEveryJob(try repo.run([], count: count))
  }

  @Test func blankLinesDoNotCountAsPaths() throws {
    let repo = try CIJobsRepo()

    expectJobs(try repo.run([appFile, ""], count: 1), parts: [4], gui: true)
  }

  // MARK: Drafts and pushes

  /// The workflow writes no package JSON for a draft.
  @Test(arguments: [[coreFile], [appFile], ["Package.swift"], [readme]])
  func aDraftRunsNoJob(_ paths: [String]) throws {
    let repo = try CIJobsRepo()
    try repo.setPackage(nil)

    expectNoJob(try repo.run("draft", paths))
  }

  @Test func aDraftWithACountMismatchRunsNoJob() throws {
    let repo = try CIJobsRepo()

    expectNoJob(try repo.run("draft", [coreFile], count: 0))
  }

  /// The workflow writes no package JSON for a push to main.
  @Test(arguments: [[appFile], [unitTestFile], [integrationFile], ["bin/test"], ["docs/x.md"], ["docs/x.md", readme]])
  func aPushRunsEveryJobForACodeChange(_ paths: [String]) throws {
    let repo = try CIJobsRepo()
    try repo.setPackage(nil)

    expectEveryJob(try repo.run("push", paths))
  }

  @Test func aPushOfMarkdownOnlyRunsNoJob() throws {
    let repo = try CIJobsRepo()
    try repo.setPackage(nil)

    expectNoJob(try repo.run("push", [readme, "FxNotes.md"]))
  }

  @Test func aPushOfMarkdownWithACountOfZeroRunsEveryJob() throws {
    let repo = try CIJobsRepo()
    try repo.setPackage(nil)

    expectEveryJob(try repo.run("push", [readme], count: 0))
  }

  // MARK: Package JSON

  @Test(arguments: [nil, "", "not json", "{}", "{\"targets\": 3}", "{\"targets\": []}"] as [String?])
  func aPackageThatDoesNotDescribeTheTargetsRunsEveryJob(_ text: String?) throws {
    let repo = try CIJobsRepo()
    try repo.setPackage(text)

    expectEveryJob(try repo.run([appFile]))
  }

  @Test(arguments: ["\(srcDir)/FxAppFolder", "\(srcDir)/FxAppFolder/"])
  func aTargetsExplicitPathHoldsItsFiles(_ appPath: String) throws {
    let repo = try CIJobsRepo(
      files: ["\(srcDir)/FxAppFolder/App.swift": "let fxApp = 1\n"], targets: packageTargets(appPath: appPath))

    expectJobs(try repo.run(["\(srcDir)/FxAppFolder/App.swift"]), parts: [4], gui: true)
  }

  /// With an explicit path, the app's default folder belongs to no target.
  @Test func aFileInATargetsDefaultFolderRunsEveryJobWhenTheTargetHasAnExplicitPath() throws {
    let repo = try CIJobsRepo(targets: packageTargets(appPath: "\(srcDir)/FxAppFolder"))

    expectEveryJob(try repo.run([appFile]))
  }

  /// FxBridge depends on SwitchboardApp, so IntegrationTests reaches the app through FxBridge.
  @Test(arguments: ["byName", "target"], ["byName", "target"])
  func anAppFileRunsEveryPartWhenIntegrationTestsReachesTheAppThroughAnotherTarget(
    _ integrationForm: String, _ bridgeForm: String
  ) throws {
    func dependency(_ form: String, _ name: String) -> [String: Any] {
      form == "byName" ? byName(name) : targetDependency(name)
    }
    let targets = packageTargets(
      integrationDependencies: [byName("SwitchboardCore"), dependency(integrationForm, "FxBridge")],
      extra: [target("FxBridge", "regular", [dependency(bridgeForm, "SwitchboardApp")])])
    let repo = try CIJobsRepo(targets: targets)

    expectEveryJob(try repo.run([appFile]))
  }

  // MARK: Files that IntegrationTests reads at run time

  @Test(
    arguments: [
      "Tests/IntegrationTests/FxPathTests.swift", "Tests/IntegrationTests/Fixtures/path-list",
    ],
    [appFile, unitTestFile, "\(srcDir)/SwitchboardCoreKit/Kit.swift", "Tests/SwitchboardCoreTests/Fx[1].Tests.swift"])
  func aPathThatAnIntegrationTestsFileNamesRunsEveryPart(_ namer: String, _ path: String) throws {
    let repo = try CIJobsRepo(files: [namer: "let fxPath = \"\(path)\"\n"])

    let run = try repo.run([path])

    #expect(run.result.status == 0, "\(run.result.stderr)")
    #expect(run.parts == allParts, "\(run.result.stdout)\n\(run.result.stderr)")
  }

  @Test(arguments: [
    "Instance.root.appendingPathComponent(\"\(srcDir)/SwitchboardApp\")",
    "URL(fileURLWithPath: #filePath).appendingPathComponent(\"../../\(srcDir)/\")",
  ])
  func anAppFileRunsEveryPartWhenAnIntegrationTestsFileReadsTheSourceFolder(_ expression: String) throws {
    let repo = try CIJobsRepo(files: [
      "Tests/IntegrationTests/FxSourceScanTests.swift": "import Foundation\n\nlet fxScan = \(expression)\n"
    ])

    expectEveryJob(try repo.run([appFile]))
    expectJobs(try repo.run([unitTestFile]), parts: [4], gui: false)
  }

  /// A test can run a product without depending on the target that builds it.
  @Test(
    arguments: [
      "Tests/IntegrationTests/FxAppRunTests.swift", "Tests/IntegrationTests/Fixtures/app-launcher",
    ],
    [
      "let fxApp = \"\\(Instance.bin)/\(appProduct)\"\n", "exec \"$BIN\"/\(appProduct) --self-test\n",
      "exec bin/\(appProduct)\n",
    ])
  func anAppFileRunsEveryPartWhenAnIntegrationTestsFileNamesTheAppProductAsAPath(
    _ namer: String, _ text: String
  ) throws {
    let repo = try CIJobsRepo(files: [namer: text])

    expectEveryJob(try repo.run([appFile]))
  }

  /// The app bundle's name puts a dot after the product name, so it does not name the product.
  @Test(arguments: [
    "let fxBundle = \"/Applications/\(appProduct).app\"\n", "let fxKit = \"\\(Instance.bin)/\(appProduct)Kit\"\n",
    "let fxName = \"\(appProduct)\"\n",
  ])
  func anIntegrationTestsFileThatNamesTheAppOnlyInOtherFormsLeavesAnAppFileToTheLastPart(_ text: String) throws {
    let repo = try CIJobsRepo(files: ["Tests/IntegrationTests/FxBundleTests.swift": text])

    expectJobs(try repo.run([appFile]), parts: [4], gui: true)
  }

  /// A made-up path that quotes the source folder's name does not find the repo, so it reads nothing.
  @Test func anIntegrationTestsFileWithAMadeUpSourcePathLeavesAnAppFileToTheLastPart() throws {
    let repo = try CIJobsRepo(files: [
      "Tests/IntegrationTests/FxRepoPathTests.swift": "let fxMadeUp = \"/tmp/x/\(srcDir)/deep\"\n"
    ])

    expectJobs(try repo.run([appFile]), parts: [4], gui: true)
  }

  // MARK: gui-test

  @Test(arguments: [
    ("bin/test-gui", "#!/bin/bash\nls \(unitTestFile)\n"),
    ("bin/lib/fx-gui-seed.sh", "cat \(unitTestFile)\n"),
  ])
  func aUnitTestFileRunsGuiTestWhenTheGuiScriptsNameIt(_ path: String, _ text: String) throws {
    let repo = try CIJobsRepo(files: [path: text])

    expectJobs(try repo.run([unitTestFile]), parts: [4], gui: true)
  }

  @Test(arguments: [
    "#!/bin/bash\nsource bin/lib/swift-testing.sh\nbuild_tests\n", "#!/bin/bash\nswift build --build-tests\n",
    "#!/bin/bash\nswift test --filter GUITests\n", "#!/bin/bash\nbin/lib/swiftpm test --filter GUITests\n",
  ])
  func aUnitTestFileRunsGuiTestWhenBinTestGuiBuildsTheTests(_ text: String) throws {
    let repo = try CIJobsRepo(files: ["bin/test-gui": text])

    let run = try repo.run([unitTestFile])

    #expect(run.result.status == 0, "\(run.result.stderr)")
    #expect(run.gui == true, "\(run.result.stdout)\n\(run.result.stderr)")
  }

  @Test(arguments: [
    ("bin/test-gui", "#!/bin/bash\nls \(integrationFile)\n"), ("bin/lib/fx-gui-seed.sh", "cat \(integrationFile)\n"),
  ])
  func anIntegrationTestsFileRunsGuiTestWhenTheGuiScriptsNameIt(_ path: String, _ text: String) throws {
    let repo = try CIJobsRepo(files: [path: text])

    expectEveryJob(try repo.run([integrationFile]))
  }

  // MARK: SB_CI_PARTS

  @Test(arguments: [nil, "", "0", "-1", "x", "1.5", "4x"] as [String?])
  func aMissingOrInvalidPartCountExitsTwo(_ parts: String?) throws {
    let repo = try CIJobsRepo()

    let run = try repo.run([appFile], parts: parts)

    #expect(run.result.status == 2, "\(run.result.stdout)\n\(run.result.stderr)")
    #expect(!run.result.stdout.contains("parts="), "\(run.result.stdout)")
  }

  @Test(arguments: [
    ("2", coreFile, [1, 2]), ("2", appFile, [2]), ("2", integrationFile, [1, 2]), ("1", coreFile, [1]),
    ("1", appFile, [1]), ("6", appFile, [6]), ("6", "bin/test", [1, 2, 3, 4, 5, 6]),
  ])
  func theLastPartIsThePartCount(_ count: String, _ path: String, _ parts: [Int]) throws {
    let repo = try CIJobsRepo()

    let run = try repo.run([path], parts: count)

    #expect(run.result.status == 0, "\(run.result.stderr)")
    #expect(run.parts == parts, "\(run.result.stdout)\n\(run.result.stderr)")
  }

  // MARK: Output

  @Test func stdoutHoldsOnlyThePartsAndGuiLines() throws {
    let repo = try CIJobsRepo()

    let run = try repo.run([appFile, unitTestFile])

    let keys = run.result.stdout.split(separator: "\n").map { $0.split(separator: "=", maxSplits: 1).first ?? "" }
    #expect(keys == ["parts", "gui"], "\(run.result.stdout)")
  }

  @Test func stderrNamesEveryChangedPath() throws {
    let repo = try CIJobsRepo()
    let paths = [appFile, unitTestFile, integrationFile, readme]

    let run = try repo.run(paths)

    for path in paths { #expect(run.result.stderr.contains(path), "\(path): \(run.result.stderr)") }
  }

  /// A run with an unknown mode must not skip a job.
  @Test(arguments: ["", "ready", "PR"])
  func anUnknownModeDoesNotSkipAJob(_ mode: String) throws {
    let repo = try CIJobsRepo()

    let run = try repo.run(mode, [readme])

    #expect(run.result.status == 2, "\(run.result.stdout)\n\(run.result.stderr)")
  }
}
